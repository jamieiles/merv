// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// SDHCI register file and AXI4-Lite subordinate.
//
// Implements the SD Host Controller Simplified Specification version 2.00
// register set for a single slot with SDMA.  Every register honours the
// AXI byte lanes so that drivers may use 8, 16 and 32-bit accesses.  The
// address is decoded within a 256 byte window that is aliased across the
// 64KB region.
module SDHCIRegs #(
    // Timeout clock in MHz reported in the capabilities.
    parameter int tmclk_mhz = 1
) (
    input  logic         clk,
    input  logic         reset,
    // AXI4-Lite
    // verilator lint_off UNUSEDSIGNAL
    input  logic [ 15:0] s_axi_awaddr,
    // verilator lint_on UNUSEDSIGNAL
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [ 31:0] s_axi_wdata,
    input  logic [  3:0] s_axi_wstrb,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [  1:0] s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready,
    // verilator lint_off UNUSEDSIGNAL
    input  logic [ 15:0] s_axi_araddr,
    // verilator lint_on UNUSEDSIGNAL
    input  logic         s_axi_arvalid,
    output logic         s_axi_arready,
    output logic [ 31:0] s_axi_rdata,
    output logic [  1:0] s_axi_rresp,
    output logic         s_axi_rvalid,
    input  logic         s_axi_rready,
    output logic         irq,
    // Resets
    output logic         rst_cmd,
    output logic         rst_dat,
    // Command issue
    output logic         cmd_start,
    output logic [  5:0] cmd_index,
    output logic [ 31:0] cmd_arg,
    output logic [  1:0] cmd_resp_type,
    output logic         cmd_crc_check,
    output logic         cmd_index_check,
    output logic         cmd_data,
    // Transfer configuration
    output logic [  9:0] blksz,
    output logic [ 15:0] blkcnt,
    output logic         tm_read,
    output logic         tm_multi,
    output logic         tm_bce,
    output logic         tm_auto12,
    output logic         wide,
    output logic [  3:0] timeout_ctrl,
    // Clock
    output logic         sdclk_en,
    output logic [  7:0] sdclk_div,
    output logic [  1:0] sample_delay,
    // Command engine
    input  logic         cmd_busy,
    input  logic         cmd_done,
    input  logic         cmd_done_auto,
    input  logic         cmd_err_timeout,
    input  logic         cmd_err_crc,
    input  logic         cmd_err_end,
    input  logic         cmd_err_index,
    input  logic [127:0] resp,
    // Data engine
    input  logic         dat_busy,
    input  logic         dat_active,
    input  logic         read_active,
    input  logic         write_active,
    input  logic         xfer_done,
    input  logic         blk_done,
    input  logic         dat_err_timeout,
    input  logic         dat_err_crc,
    input  logic         dat_err_end,
    // Data buffer
    output logic         buf_push,
    output logic [ 31:0] buf_wdata,
    output logic         buf_pop,
    input  logic [ 31:0] buf_rdata,
    input  logic         buf_rd_en,
    input  logic         buf_wr_en,
    // SDMA
    output logic         tm_dma,
    output logic [  2:0] dma_boundary,
    output logic [ 31:0] sdma_addr_out,
    output logic         sdma_restart,
    input  logic         dma_active,
    input  logic         dma_addr_update,
    input  logic [ 31:0] dma_addr_next,
    input  logic         dma_boundary_irq,
    input  logic         dma_bus_error,
    // Pin levels
    input  logic         card_inserted,
    input  logic         card_stable,
    input  logic [  3:0] dat_level,
    input  logic         cmd_level
);

    localparam logic [7:0] REG_SDMA_ADDR = 8'h00;
    localparam logic [7:0] REG_BLOCK = 8'h04;
    localparam logic [7:0] REG_ARGUMENT = 8'h08;
    localparam logic [7:0] REG_COMMAND = 8'h0c;
    localparam logic [7:0] REG_RESPONSE0 = 8'h10;
    localparam logic [7:0] REG_RESPONSE1 = 8'h14;
    localparam logic [7:0] REG_RESPONSE2 = 8'h18;
    localparam logic [7:0] REG_RESPONSE3 = 8'h1c;
    localparam logic [7:0] REG_BUFFER = 8'h20;
    localparam logic [7:0] REG_PRESENT = 8'h24;
    localparam logic [7:0] REG_HOST_CTRL = 8'h28;
    localparam logic [7:0] REG_CLOCK = 8'h2c;
    localparam logic [7:0] REG_INT_STATUS = 8'h30;
    localparam logic [7:0] REG_INT_ENABLE = 8'h34;
    localparam logic [7:0] REG_SIGNAL_ENABLE = 8'h38;
    localparam logic [7:0] REG_ACMD12_ERR = 8'h3c;
    localparam logic [7:0] REG_CAPABILITIES = 8'h40;
    localparam logic [7:0] REG_MAX_CURRENT = 8'h48;
    localparam logic [7:0] REG_VENDOR = 8'hf0;
    localparam logic [7:0] REG_VERSION = 8'hfc;

    // Version 2.00, 3.3V only, SDMA, high speed, 512 byte blocks, the base
    // clock is provided by the device tree.  ADMA2 is not supported: its
    // descriptors would need memory that is coherent with the CPU.
    localparam logic [31:0] CAPABILITIES = (32'd1 << 24) | (32'd1 << 22) | (32'd1 << 21) |
        (32'd1 << 7) | 32'(tmclk_mhz);
    // 200mA at 3.3V
    localparam logic [31:0] MAX_CURRENT = 32'd50;
    localparam logic [15:0] HOST_VERSION = 16'h0001;

    // Normal interrupt status bits
    localparam int INT_CMD_COMPLETE = 0;
    localparam int INT_XFER_COMPLETE = 1;
    localparam int INT_DMA = 3;
    localparam int INT_BUF_WR_READY = 4;
    localparam int INT_BUF_RD_READY = 5;
    localparam int INT_CARD_INSERT = 6;
    localparam int INT_CARD_REMOVE = 7;
    localparam int INT_ERROR = 15;
    localparam logic [15:0] NORMAL_MASK = 16'h00fb;

    // Error interrupt status bits
    localparam int ERR_CMD_TIMEOUT = 0;
    localparam int ERR_CMD_CRC = 1;
    localparam int ERR_CMD_END = 2;
    localparam int ERR_CMD_INDEX = 3;
    localparam int ERR_DAT_TIMEOUT = 4;
    localparam int ERR_DAT_CRC = 5;
    localparam int ERR_DAT_END = 6;
    localparam int ERR_ACMD12 = 8;
    localparam logic [15:0] ERROR_MASK = 16'h017f;

    logic [31:0] sdma_addr;
    logic [14:0] blksz_reg;
    logic [15:0] blkcnt_reg;
    logic [31:0] arg_reg;
    logic [ 5:0] tm_reg;
    logic [13:0] cmd_reg;
    logic [13:0] cmd_reg_wr;
    logic [ 7:0] host_ctrl;
    logic [ 3:0] power_ctrl;
    // verilator lint_off UNUSEDSIGNAL
    // Bit 1 (internal clock stable) is read-only.
    logic [ 2:0] clock_ctrl;
    // verilator lint_on UNUSEDSIGNAL
    logic [ 7:0] clock_div;
    logic [ 3:0] timeout_reg;
    logic [15:0] normal_status;
    logic [15:0] error_status;
    logic [15:0] normal_status_en;
    logic [15:0] error_status_en;
    logic [15:0] normal_signal_en;
    logic [15:0] error_signal_en;
    logic [ 7:0] acmd12_err;
    logic [ 1:0] vendor_reg;

    logic        wr_fire;
    logic        rd_fire;
    logic [ 7:0] waddr;
    logic [ 7:0] raddr;
    logic [31:0] wmask;
    logic [31:0] rdata_next;
    logic        reset_all;
    logic        cmd_issue;
    logic        cmd_issue_q;
    logic        buf_rd_en_q;
    logic        buf_wr_en_q;
    logic        card_inserted_q;
    logic [15:0] normal_events;
    logic [15:0] error_events;
    logic [15:0] normal_w1c;
    logic [15:0] error_w1c;
    logic [31:0] present_state;
    logic [15:0] normal_status_rd;

    function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] new_val,
                                          input logic [31:0] mask);
        merge = (old & ~mask) | (new_val & mask);
    endfunction

    // ------------------------------------------------------------------
    // AXI4-Lite: a write is accepted once both the address and data are
    // valid, a read is accepted once any previous read data has been taken.
    // ------------------------------------------------------------------
    always_comb begin
        s_axi_awready = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
        s_axi_wready  = s_axi_awready;
        s_axi_bresp   = 2'b00;
        wr_fire       = s_axi_awready;
        waddr         = {s_axi_awaddr[7:2], 2'b00};
        wmask         = {{8{s_axi_wstrb[3]}}, {8{s_axi_wstrb[2]}},
                         {8{s_axi_wstrb[1]}}, {8{s_axi_wstrb[0]}}};

        s_axi_arready = s_axi_arvalid && (!s_axi_rvalid || s_axi_rready);
        s_axi_rresp   = 2'b00;
        rd_fire       = s_axi_arready;
        raddr         = {s_axi_araddr[7:2], 2'b00};
    end

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    always_comb begin
        reset_all       = wr_fire && waddr == REG_CLOCK && s_axi_wstrb[3] && s_axi_wdata[24];
        rst_cmd         = reset || reset_all ||
            (wr_fire && waddr == REG_CLOCK && s_axi_wstrb[3] && s_axi_wdata[25]);
        rst_dat         = reset || reset_all ||
            (wr_fire && waddr == REG_CLOCK && s_axi_wstrb[3] && s_axi_wdata[26]);

        cmd_index       = cmd_reg[13:8];
        cmd_arg         = arg_reg;
        cmd_resp_type   = cmd_reg[1:0];
        cmd_crc_check   = cmd_reg[3];
        cmd_index_check = cmd_reg[4];
        cmd_data        = cmd_reg[5];

        blksz           = |blksz_reg[11:10] ? 10'd512 : blksz_reg[9:0];
        blkcnt          = blkcnt_reg;
        tm_dma          = tm_reg[0];
        tm_bce          = tm_reg[1];
        tm_auto12       = tm_reg[2];
        tm_read         = tm_reg[4];
        tm_multi        = tm_reg[5];
        wide            = host_ctrl[1];
        timeout_ctrl    = timeout_reg;

        // The SD clock only runs with bus power and both clock enables.
        sdclk_en        = power_ctrl[0] && clock_ctrl[0] && clock_ctrl[2];
        sdclk_div       = clock_div;
        sample_delay    = vendor_reg;

        dma_boundary    = blksz_reg[14:12];
        sdma_addr_out   = sdma_addr;

        buf_push        = wr_fire && waddr == REG_BUFFER;
        buf_wdata       = s_axi_wdata;
        buf_pop         = rd_fire && raddr == REG_BUFFER;

        // A command is issued by writing the upper byte of the command
        // register, it is started on the following cycle once the register
        // has been updated.  Commands that use the DAT lines (data or busy)
        // are dropped while the DAT lines are inhibited.
        cmd_reg_wr      = 14'(merge({18'b0, cmd_reg}, {18'b0, s_axi_wdata[29:16]},
                                {18'b0, wmask[29:16]}));
        cmd_issue       = wr_fire && waddr == REG_COMMAND && s_axi_wstrb[3] && !cmd_busy &&
            !((cmd_reg_wr[5] || &cmd_reg_wr[1:0]) && dat_busy);
        cmd_start       = cmd_issue_q;
    end

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------
    always_comb begin
        present_state = {
            7'b0,
            cmd_level,
            dat_level,
            1'b1,  // Write protect: write enabled
            card_inserted,
            card_stable,
            card_inserted,
            4'b0,
            buf_rd_en,
            buf_wr_en,
            read_active,
            write_active,
            5'b0,
            dat_active,
            dat_busy,
            cmd_busy || cmd_issue_q
        };

        normal_status_rd = normal_status;
        normal_status_rd[INT_ERROR] = |error_status;

        irq = |(normal_status & normal_signal_en & NORMAL_MASK) |
            |(error_status & error_signal_en & ERROR_MASK);
    end

    always_comb begin
        normal_events                    = 16'b0;
        normal_events[INT_CMD_COMPLETE]  = cmd_done && !cmd_done_auto &&
            !(cmd_err_timeout || cmd_err_crc || cmd_err_end || cmd_err_index);
        normal_events[INT_XFER_COMPLETE] = xfer_done;
        normal_events[INT_DMA]           = dma_boundary_irq;
        // The buffer is not accessed by the CPU for DMA transfers
        normal_events[INT_BUF_WR_READY]  = buf_wr_en && !buf_wr_en_q && !dma_active;
        normal_events[INT_BUF_RD_READY]  = buf_rd_en && !buf_rd_en_q && !dma_active;
        normal_events[INT_CARD_INSERT]   = card_stable && card_inserted && !card_inserted_q;
        normal_events[INT_CARD_REMOVE]   = card_stable && !card_inserted && card_inserted_q;

        error_events                     = 16'b0;
        error_events[ERR_CMD_TIMEOUT]    = cmd_done && !cmd_done_auto && cmd_err_timeout;
        error_events[ERR_CMD_CRC]        = cmd_done && !cmd_done_auto && cmd_err_crc;
        error_events[ERR_CMD_END]        = cmd_done && !cmd_done_auto && cmd_err_end;
        error_events[ERR_CMD_INDEX]      = cmd_done && !cmd_done_auto && cmd_err_index;
        // Version 2.00 has no SDMA error so a bus error is reported as a data
        // timeout.  Not ADMA Error: Linux dumps the ADMA descriptor table for
        // that, which doesn't exist with SDMA.
        error_events[ERR_DAT_TIMEOUT]    = dat_err_timeout || dma_bus_error;
        error_events[ERR_DAT_CRC]        = dat_err_crc;
        error_events[ERR_DAT_END]        = dat_err_end;
        error_events[ERR_ACMD12]         = cmd_done && cmd_done_auto &&
            (cmd_err_timeout || cmd_err_crc || cmd_err_end || cmd_err_index);

        normal_w1c = 16'b0;
        error_w1c  = 16'b0;
        if (wr_fire && waddr == REG_INT_STATUS) begin
            normal_w1c = s_axi_wdata[15:0] & wmask[15:0];
            error_w1c  = s_axi_wdata[31:16] & wmask[31:16];
        end
    end

    // ------------------------------------------------------------------
    // Read data
    // ------------------------------------------------------------------
    always_comb begin
        case (raddr)
            REG_SDMA_ADDR:     rdata_next = sdma_addr;
            REG_BLOCK:         rdata_next = {blkcnt_reg, 1'b0, blksz_reg};
            REG_ARGUMENT:      rdata_next = arg_reg;
            REG_COMMAND:       rdata_next = {2'b0, cmd_reg, 10'b0, tm_reg};
            REG_RESPONSE0:     rdata_next = resp[31:0];
            REG_RESPONSE1:     rdata_next = resp[63:32];
            REG_RESPONSE2:     rdata_next = resp[95:64];
            REG_RESPONSE3:     rdata_next = resp[127:96];
            REG_BUFFER:        rdata_next = buf_rdata;
            REG_PRESENT:       rdata_next = present_state;
            REG_HOST_CTRL:     rdata_next = {20'b0, power_ctrl, host_ctrl};
            REG_CLOCK:
            rdata_next = {12'b0, timeout_reg, clock_div, 5'b0, clock_ctrl[2], clock_ctrl[0],
                          clock_ctrl[0]};
            REG_INT_STATUS:    rdata_next = {error_status, normal_status_rd};
            REG_INT_ENABLE:    rdata_next = {error_status_en, normal_status_en};
            REG_SIGNAL_ENABLE: rdata_next = {error_signal_en, normal_signal_en};
            REG_ACMD12_ERR:    rdata_next = {24'b0, acmd12_err};
            REG_CAPABILITIES:  rdata_next = CAPABILITIES;
            REG_MAX_CURRENT:   rdata_next = MAX_CURRENT;
            REG_VENDOR:        rdata_next = {30'b0, vendor_reg};
            REG_VERSION:       rdata_next = {HOST_VERSION, 15'b0, irq};
            default:           rdata_next = 32'b0;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rd_fire) s_axi_rdata <= rdata_next;
        if (rd_fire) s_axi_rvalid <= 1'b1;
        else if (s_axi_rready) s_axi_rvalid <= 1'b0;

        if (wr_fire) s_axi_bvalid <= 1'b1;
        else if (s_axi_bready) s_axi_bvalid <= 1'b0;

        if (reset) begin
            s_axi_rvalid <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_rdata  <= 32'b0;
        end
    end

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        cmd_issue_q     <= cmd_issue;
        buf_rd_en_q     <= buf_rd_en;
        buf_wr_en_q     <= buf_wr_en;
        card_inserted_q <= card_stable ? card_inserted : card_inserted_q;
        // Writing the upper byte of the SDMA System Address restarts a DMA
        // transfer stopped at a buffer boundary.
        sdma_restart    <= wr_fire && waddr == REG_SDMA_ADDR && s_axi_wstrb[3];

        // The DMA engine advances the address, the CPU only writes it while
        // the DMA is stopped.
        if (dma_addr_update) sdma_addr <= dma_addr_next;

        if (wr_fire) begin
            case (waddr)
                REG_SDMA_ADDR: sdma_addr <= merge(sdma_addr, s_axi_wdata, wmask);
                REG_BLOCK: begin
                    blksz_reg  <= 15'(merge({17'b0, blksz_reg}, s_axi_wdata, wmask));
                    blkcnt_reg <= 16'(merge({16'b0, blkcnt_reg}, {16'b0, s_axi_wdata[31:16]},
                                            {16'b0, wmask[31:16]}));
                end
                REG_ARGUMENT: arg_reg <= merge(arg_reg, s_axi_wdata, wmask);
                REG_COMMAND: begin
                    tm_reg  <= 6'(merge({26'b0, tm_reg}, s_axi_wdata, wmask));
                    cmd_reg <= cmd_reg_wr;
                end
                REG_HOST_CTRL: begin
                    host_ctrl  <= 8'(merge({24'b0, host_ctrl}, s_axi_wdata, wmask));
                    power_ctrl <= 4'(merge({28'b0, power_ctrl}, {28'b0, s_axi_wdata[11:8]},
                                           {28'b0, wmask[11:8]}));
                end
                REG_CLOCK: begin
                    if (s_axi_wstrb[0]) clock_ctrl <= {s_axi_wdata[2], 1'b0, s_axi_wdata[0]};
                    if (s_axi_wstrb[1]) clock_div <= s_axi_wdata[15:8];
                    if (s_axi_wstrb[2]) timeout_reg <= s_axi_wdata[19:16];
                end
                REG_INT_ENABLE: begin
                    normal_status_en <= 16'(merge({16'b0, normal_status_en}, s_axi_wdata,
                                                  wmask)) & NORMAL_MASK;
                    error_status_en <= 16'(merge({16'b0, error_status_en},
                                                 {16'b0, s_axi_wdata[31:16]}, {16'b0, wmask[31:16]}))
                        & ERROR_MASK;
                end
                REG_SIGNAL_ENABLE: begin
                    normal_signal_en <= 16'(merge({16'b0, normal_signal_en}, s_axi_wdata,
                                                  wmask)) & NORMAL_MASK;
                    error_signal_en <= 16'(merge({16'b0, error_signal_en},
                                                 {16'b0, s_axi_wdata[31:16]}, {16'b0, wmask[31:16]}))
                        & ERROR_MASK;
                end
                REG_VENDOR: if (s_axi_wstrb[0]) vendor_reg <= s_axi_wdata[1:0];
                default: ;
            endcase
        end

        // Block count decrements as each block is transferred.
        if (blk_done && tm_bce && |blkcnt_reg) blkcnt_reg <= blkcnt_reg - 1'b1;

        normal_status <= ((normal_status & ~normal_w1c) | normal_events) & normal_status_en;
        error_status  <= ((error_status & ~error_w1c) | error_events) & error_status_en;

        if (cmd_done && cmd_done_auto)
            acmd12_err <= {3'b0, cmd_err_index, cmd_err_end, cmd_err_crc, cmd_err_timeout, 1'b0};

        // Software reset for the DAT circuit clears the data related status.
        if (rst_dat) begin
            normal_status[INT_XFER_COMPLETE] <= 1'b0;
            normal_status[INT_DMA]           <= 1'b0;
            normal_status[INT_BUF_WR_READY]  <= 1'b0;
            normal_status[INT_BUF_RD_READY]  <= 1'b0;
            buf_rd_en_q                      <= 1'b0;
            buf_wr_en_q                      <= 1'b0;
        end
        if (rst_cmd) begin
            normal_status[INT_CMD_COMPLETE] <= 1'b0;
            cmd_issue_q                     <= 1'b0;
        end

        if (reset || reset_all) begin
            sdma_addr        <= 32'b0;
            blksz_reg        <= 15'b0;
            blkcnt_reg       <= 16'b0;
            arg_reg          <= 32'b0;
            tm_reg           <= 6'b0;
            cmd_reg          <= 14'b0;
            host_ctrl        <= 8'b0;
            power_ctrl       <= 4'b0;
            clock_ctrl       <= 3'b0;
            clock_div        <= 8'b0;
            timeout_reg      <= 4'b0;
            normal_status    <= 16'b0;
            error_status     <= 16'b0;
            normal_status_en <= 16'b0;
            error_status_en  <= 16'b0;
            normal_signal_en <= 16'b0;
            error_signal_en  <= 16'b0;
            acmd12_err       <= 8'b0;
            vendor_reg       <= 2'b0;
            card_inserted_q  <= 1'b0;
            sdma_restart     <= 1'b0;
        end
    end

endmodule
