// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// SD host controller compatible with the SD Host Controller Simplified
// Specification version 2.00 with PIO and SDMA.
//
// For SDMA the controller is an AXI4 manager that only issues whole, line
// aligned bursts of dma_line_bytes (see SDHCIDMA) so that it can be connected
// directly to the DRAM controller's DMA port.
//
// Everything runs in the AXI clock domain.  The SD bus outputs (SDCLK, CMD
// and DAT with their tristate controls) are driven directly from registers
// and the CMD/DAT inputs are registered before use so that all of them can
// be packed into the IOBs.  The tristate controls are active-low (_t) so
// that the register drives the IOBUF T input with no inversion.
module SDHCI #(
    // Base clock / tmclk_div gives the ~1MHz data timeout clock.
    parameter int tmclk_div   = 81,
    // Card detect debounce in clock cycles (~3ms at 81MHz).
    parameter int debounce_bits = 18,
    // DMA burst size, the DRAM controller's line size.
    parameter int dma_line_bytes = 64
) (
    input  logic        clk,
    input  logic        resetn,
    // AXI4-Lite
    input  logic [15:0] s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [ 3:0] s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [ 1:0] s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [15:0] s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [ 1:0] s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,
    output logic        irq,
    output logic        activity,
    // AXI4 manager for SDMA
    output logic [31:0] m_axi_awaddr,
    output logic [ 7:0] m_axi_awlen,
    output logic [ 2:0] m_axi_awsize,
    output logic [ 1:0] m_axi_awburst,
    output logic [ 3:0] m_axi_awcache,
    output logic [ 2:0] m_axi_awprot,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [ 3:0] m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [ 1:0] m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [31:0] m_axi_araddr,
    output logic [ 7:0] m_axi_arlen,
    output logic [ 2:0] m_axi_arsize,
    output logic [ 1:0] m_axi_arburst,
    output logic [ 3:0] m_axi_arcache,
    output logic [ 2:0] m_axi_arprot,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [31:0] m_axi_rdata,
    input  logic [ 1:0] m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    // SD bus
    output logic        sd_clk,
    output logic        cmd_o,
    output logic        cmd_t,
    input  logic        cmd_i,
    output logic [ 3:0] dat_o,
    output logic [ 3:0] dat_t,
    input  logic [ 3:0] dat_i,
    input  logic        cd_n
);

    logic                     reset;

    (* IOB = "TRUE" *)logic         cmd_i_q;
    (* IOB = "TRUE" *)logic [  3:0] dat_i_q;

    logic                     rst_cmd;
    logic                     rst_dat;
    logic                     drive;
    logic                     sample;
    logic                     stop;
    logic                     dat_stop;

    logic                     cmd_start;
    logic         [      5:0] cmd_index;
    logic         [     31:0] cmd_arg;
    logic         [      1:0] cmd_resp_type;
    logic                     cmd_crc_check;
    logic                     cmd_index_check;
    logic                     cmd_data;
    logic                     cmd_busy;
    logic                     cmd_done;
    logic                     cmd_done_auto;
    logic                     cmd_err_timeout;
    logic                     cmd_err_crc;
    logic                     cmd_err_end;
    logic                     cmd_err_index;
    logic         [    127:0] resp;
    logic                     acmd12_req;
    logic                     acmd12_ack;

    logic         [      9:0] blksz;
    logic         [     15:0] blkcnt;
    logic                     tm_read;
    logic                     tm_multi;
    logic                     tm_bce;
    logic                     tm_auto12;
    logic                     wide;
    logic         [      3:0] timeout_ctrl;
    logic                     sdclk_en;
    logic         [      7:0] sdclk_div;
    logic         [      1:0] sample_delay;

    logic                     xfer_start;
    logic                     busy_start;
    logic                     dat_busy;
    logic                     dat_active;
    logic                     read_active;
    logic                     write_active;
    logic                     xfer_done;
    logic                     blk_done;
    logic                     dat_err_timeout;
    logic                     dat_err_crc;
    logic                     dat_err_end;

    logic                     fifo_eng_push;
    logic         [     31:0] fifo_eng_wdata;
    logic                     fifo_eng_pop;
    logic                     fifo_cpu_push;
    logic         [     31:0] fifo_cpu_wdata;
    logic                     fifo_cpu_pop;
    logic         [     31:0] fifo_rdata;
    logic                     fifo_empty;
    logic                     blk_space;
    logic                     blk_avail;
    logic                     buf_rd_en;
    logic                     buf_wr_en;

    logic                     regs_buf_push;
    logic         [     31:0] regs_buf_wdata;
    logic                     regs_buf_pop;
    logic                     tm_dma;
    logic         [      2:0] dma_boundary;
    logic         [     31:0] sdma_addr;
    logic                     sdma_restart;
    logic                     dma_active;
    logic                     dma_busy;
    logic                     dma_addr_update;
    logic         [     31:0] dma_addr_next;
    logic                     dma_boundary_irq;
    logic                     dma_bus_error;
    logic                     dma_fifo_push;
    logic         [     31:0] dma_fifo_wdata;
    logic                     dma_fifo_pop;

    logic                     cd_sync;
    logic                     card_inserted;
    logic                     card_valid;
    logic         [debounce_bits-1:0] debounce;

    always_comb begin
        reset      = ~resetn;
        // Freeze the card between blocks but never while a command is in
        // progress.
        stop       = dat_stop && !cmd_busy;
        xfer_start = cmd_start && cmd_data;
        busy_start = cmd_start && !cmd_data && &cmd_resp_type;
        activity   = cmd_busy || dat_busy;

        // The DMA engine replaces the buffer data port for DMA transfers
        fifo_cpu_push  = dma_active ? dma_fifo_push : regs_buf_push;
        fifo_cpu_wdata = dma_active ? dma_fifo_wdata : regs_buf_wdata;
        fifo_cpu_pop   = dma_active ? dma_fifo_pop : regs_buf_pop;
    end

    always_ff @(posedge clk) begin
        cmd_i_q <= cmd_i;
        dat_i_q <= dat_i;
    end

    // Card detect is active-low, debounced before it is reported.
    BitSync cd_bitsync (
        .clk  (clk),
        .reset(reset),
        .d    (~cd_n),
        .q    (cd_sync)
    );

    always_ff @(posedge clk) begin
        if (cd_sync != card_inserted || !card_valid) begin
            debounce <= debounce + 1'b1;
            if (&debounce) begin
                card_inserted <= cd_sync;
                card_valid    <= 1'b1;
            end
        end else begin
            debounce <= '0;
        end

        if (reset) begin
            debounce      <= '0;
            card_inserted <= 1'b0;
            card_valid    <= 1'b0;
        end
    end

    SDHCIRegs regs (
        .clk            (clk),
        .reset          (reset),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        .irq            (irq),
        .rst_cmd        (rst_cmd),
        .rst_dat        (rst_dat),
        .cmd_start      (cmd_start),
        .cmd_index      (cmd_index),
        .cmd_arg        (cmd_arg),
        .cmd_resp_type  (cmd_resp_type),
        .cmd_crc_check  (cmd_crc_check),
        .cmd_index_check(cmd_index_check),
        .cmd_data       (cmd_data),
        .blksz          (blksz),
        .blkcnt         (blkcnt),
        .tm_read        (tm_read),
        .tm_multi       (tm_multi),
        .tm_bce         (tm_bce),
        .tm_auto12      (tm_auto12),
        .wide           (wide),
        .timeout_ctrl   (timeout_ctrl),
        .sdclk_en       (sdclk_en),
        .sdclk_div      (sdclk_div),
        .sample_delay   (sample_delay),
        .cmd_busy       (cmd_busy),
        .cmd_done       (cmd_done),
        .cmd_done_auto  (cmd_done_auto),
        .cmd_err_timeout(cmd_err_timeout),
        .cmd_err_crc    (cmd_err_crc),
        .cmd_err_end    (cmd_err_end),
        .cmd_err_index  (cmd_err_index),
        .resp           (resp),
        .dat_busy       (dat_busy),
        .dat_active     (dat_active),
        .read_active    (read_active),
        .write_active   (write_active),
        .xfer_done      (xfer_done),
        .blk_done       (blk_done),
        .dat_err_timeout(dat_err_timeout),
        .dat_err_crc    (dat_err_crc),
        .dat_err_end    (dat_err_end),
        .buf_push       (regs_buf_push),
        .buf_wdata      (regs_buf_wdata),
        .buf_pop        (regs_buf_pop),
        .buf_rdata      (fifo_rdata),
        .buf_rd_en      (buf_rd_en),
        .buf_wr_en      (buf_wr_en),
        .tm_dma         (tm_dma),
        .dma_boundary   (dma_boundary),
        .sdma_addr_out  (sdma_addr),
        .sdma_restart   (sdma_restart),
        .dma_active     (dma_active),
        .dma_addr_update(dma_addr_update),
        .dma_addr_next  (dma_addr_next),
        .dma_boundary_irq(dma_boundary_irq),
        .dma_bus_error  (dma_bus_error),
        .card_inserted  (card_inserted),
        .card_stable    (card_valid && cd_sync == card_inserted),
        .dat_level      (dat_i_q),
        .cmd_level      (cmd_i_q)
    );

    SDClockGen clockgen (
        .clk         (clk),
        .reset       (reset),
        .enable      (sdclk_en),
        .half_period (sdclk_div),
        .sample_delay(sample_delay),
        .stop        (stop),
        .sdclk_pin   (sd_clk),
        .drive       (drive),
        .sample      (sample)
    );

    SDCmdEngine cmd_engine (
        .clk        (clk),
        .reset      (rst_cmd),
        .drive      (drive),
        .sample     (sample),
        .start      (cmd_start),
        .index      (cmd_index),
        .arg        (cmd_arg),
        .resp_type  (cmd_resp_type),
        .crc_check  (cmd_crc_check),
        .index_check(cmd_index_check),
        .acmd12_req (acmd12_req),
        .acmd12_ack (acmd12_ack),
        .busy       (cmd_busy),
        .done       (cmd_done),
        .done_auto  (cmd_done_auto),
        .err_timeout(cmd_err_timeout),
        .err_crc    (cmd_err_crc),
        .err_end    (cmd_err_end),
        .err_index  (cmd_err_index),
        .resp       (resp),
        .cmd_o      (cmd_o),
        .cmd_t      (cmd_t),
        .cmd_i      (cmd_i_q)
    );

    SDDataEngine #(
        .tmclk_div(tmclk_div)
    ) data_engine (
        .clk          (clk),
        .reset        (rst_dat),
        .drive        (drive),
        .sample       (sample),
        .stop         (dat_stop),
        .xfer_start   (xfer_start),
        .busy_start   (busy_start),
        .blksz        (blksz),
        .blkcnt       (blkcnt),
        .tm_read      (tm_read),
        .tm_multi     (tm_multi),
        .tm_bce       (tm_bce),
        .tm_auto12    (tm_auto12),
        .wide         (wide),
        .timeout_ctrl (timeout_ctrl),
        .cmd_done     (cmd_done),
        .cmd_done_auto(cmd_done_auto),
        .cmd_err      (cmd_err_timeout || cmd_err_crc || cmd_err_end || cmd_err_index),
        .acmd12_req   (acmd12_req),
        .acmd12_ack   (acmd12_ack),
        .fifo_push    (fifo_eng_push),
        .fifo_wdata   (fifo_eng_wdata),
        .fifo_pop     (fifo_eng_pop),
        .fifo_rdata   (fifo_rdata),
        .fifo_empty   (fifo_empty),
        .dma_busy     (dma_busy),
        .blk_space    (blk_space),
        .blk_avail    (blk_avail),
        .blk_done     (blk_done),
        .active       (dat_busy),
        .dat_active   (dat_active),
        .read_active  (read_active),
        .write_active (write_active),
        .xfer_done    (xfer_done),
        .err_timeout  (dat_err_timeout),
        .err_crc      (dat_err_crc),
        .err_end      (dat_err_end),
        .dat_o        (dat_o),
        .dat_t        (dat_t),
        .dat_i        (dat_i_q)
    );

    SDHCIDMA #(
        .line_bytes(dma_line_bytes)
    ) dma (
        .clk          (clk),
        .reset        (reset),
        .rst_dat      (rst_dat),
        .xfer_start   (xfer_start),
        .dma_en       (tm_dma),
        .tm_read      (tm_read),
        .tm_multi     (tm_multi),
        .tm_bce       (tm_bce),
        .blkcnt       (blkcnt),
        .blksz        (blksz),
        .boundary     (dma_boundary),
        .sdma_addr    (sdma_addr),
        .sdma_restart (sdma_restart),
        .addr_update  (dma_addr_update),
        .addr_next    (dma_addr_next),
        .active       (dma_active),
        .busy         (dma_busy),
        .boundary_irq (dma_boundary_irq),
        .bus_error    (dma_bus_error),
        .fifo_push    (dma_fifo_push),
        .fifo_wdata   (dma_fifo_wdata),
        .fifo_pop     (dma_fifo_pop),
        .fifo_rdata   (fifo_rdata),
        .buf_rd_en    (buf_rd_en),
        .buf_wr_en    (buf_wr_en),
        .m_axi_awaddr (m_axi_awaddr),
        .m_axi_awlen  (m_axi_awlen),
        .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot (m_axi_awprot),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata  (m_axi_wdata),
        .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),
        .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_bresp  (m_axi_bresp),
        .m_axi_bvalid (m_axi_bvalid),
        .m_axi_bready (m_axi_bready),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot (m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rresp  (m_axi_rresp),
        .m_axi_rlast  (m_axi_rlast),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rready (m_axi_rready)
    );

    SDDataFifo fifo (
        .clk         (clk),
        .reset       (rst_dat),
        .xfer_start  (xfer_start),
        .tm_read     (tm_read),
        .tm_multi    (tm_multi),
        .tm_bce      (tm_bce),
        .blkcnt      (blkcnt),
        .blksz       (blksz),
        .read_active (read_active),
        .write_active(write_active),
        .eng_push    (fifo_eng_push),
        .eng_wdata   (fifo_eng_wdata),
        .eng_pop     (fifo_eng_pop),
        .eng_blk_done(blk_done),
        .cpu_push    (fifo_cpu_push),
        .cpu_wdata   (fifo_cpu_wdata),
        .cpu_pop     (fifo_cpu_pop),
        .rdata       (fifo_rdata),
        .empty       (fifo_empty),
        .blk_space   (blk_space),
        .blk_avail   (blk_avail),
        .buf_rd_en   (buf_rd_en),
        .buf_wr_en   (buf_wr_en)
    );

endmodule
