// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// SDMA engine for the SD host controller.
//
// When a data transfer is started with the Transfer Mode DMA Enable bit set
// the engine takes the place of the CPU on the buffer data port: for reads
// it moves each block from the data FIFO to memory once the block has been
// received and checked, for writes it fills the FIFO from memory a block at a
// time whenever there is space for one.
//
// Memory is accessed with whole, line aligned AXI4 INCR bursts of line_bytes
// so that the DMA can go straight to the DRAM controller like a cache line
// fill or write-back.  Words outside of the transfer are written with a zero
// strobe and are discarded on reads.  Only one burst is outstanding at a
// time, a line takes well under the time that the SD bus needs for it.
//
// The SDMA System Address register is the DMA address: the engine advances
// it after each burst (addr_update/addr_next) so that it reads back as the
// next system address.  When the address reaches an SDMA buffer boundary and
// the transfer isn't complete the engine stops and raises the DMA interrupt,
// it restarts once the upper byte of the address register is written.  The
// address must be word aligned and the block size a multiple of 4 bytes.
//
// A DAT line software reset, or a new transfer, while a burst is outstanding
// completes the burst with no effect on the FIFO so that the AXI protocol is
// never violated.  An error response stops the transfer and is reported with
// bus_error (a Data Timeout Error), the transfer then needs a DAT reset.
module SDHCIDMA #(
    parameter int line_bytes = 64
) (
    input  logic        clk,
    input  logic        reset,
    // Software reset of the DAT circuit
    input  logic        rst_dat,
    // Transfer configuration, latched on xfer_start
    input  logic        xfer_start,
    input  logic        dma_en,
    input  logic        tm_read,
    input  logic        tm_multi,
    input  logic        tm_bce,
    input  logic [15:0] blkcnt,
    input  logic [ 9:0] blksz,
    input  logic [ 2:0] boundary,
    // SDMA System Address register, word aligned
    // verilator lint_off UNUSEDSIGNAL
    input  logic [31:0] sdma_addr,
    // verilator lint_on UNUSEDSIGNAL
    input  logic        sdma_restart,
    output logic        addr_update,
    output logic [31:0] addr_next,
    // Status
    output logic        active,
    output logic        busy,
    output logic        boundary_irq,
    output logic        bus_error,
    // Data buffer
    output logic        fifo_push,
    output logic [31:0] fifo_wdata,
    output logic        fifo_pop,
    input  logic [31:0] fifo_rdata,
    input  logic        buf_rd_en,
    input  logic        buf_wr_en,
    // AXI4 manager
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
    output logic        m_axi_rready
);

    localparam int line_words = line_bytes / 4;
    localparam int word_bits = $clog2(line_words);
    localparam int line_bits = $clog2(line_bytes);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_WAIT_BLOCK,
        STATE_ISSUE,
        STATE_AW,
        STATE_W,
        STATE_B,
        STATE_AR,
        STATE_R
    } state_t;

    state_t               state;
    state_t               state_next;

    // Transfer
    logic                 x_dma;
    logic                 x_read;
    logic                 x_infinite;
    logic [         16:0] x_blocks_left;
    logic [          7:0] x_block_words;
    logic [          7:0] words_left;
    logic                 paused;

    // Burst
    logic [  31:line_bits] line_addr;
    logic [word_bits-1:0] first_word;
    logic [    word_bits:0] num_words;
    logic [word_bits-1:0] beat;
    logic                 in_range;
    logic                 aborting;
    logic                 bus_err;

    // verilator lint_off UNUSEDSIGNAL
    logic [          7:0] chunk_words;
    // verilator lint_on UNUSEDSIGNAL
    logic [    word_bits:0] words_to_line_end;
    logic                 burst_done;
    logic                 in_burst;
    logic                 resp_err;
    logic                 burst_ok;
    logic                 more_data;
    logic [         31:0] boundary_mask;
    logic [          7:0] words_left_next;
    logic [         16:0] blocks_left_next;

    always_comb begin
        // Bursts stay within a line so never cross a 4KB or SDMA boundary
        words_to_line_end = (word_bits + 1)'(line_words) - (word_bits + 1)'(sdma_addr[line_bits-1:2]);
        chunk_words = 8'(words_to_line_end) < words_left ? 8'(words_to_line_end) : words_left;

        in_range = !aborting && beat >= first_word &&
            (word_bits + 1)'(beat) < (word_bits + 1)'(first_word) + num_words;

        boundary_mask = (32'd4096 << boundary) - 1'b1;
        addr_next = {sdma_addr[31:2], 2'b00} + (32'(num_words) << 2);

        words_left_next = words_left - 8'(num_words);
        blocks_left_next = x_blocks_left - 17'(words_left_next == 8'd0);
        more_data = words_left_next != 8'd0 || x_infinite || |blocks_left_next;

        burst_done = (state == STATE_B && m_axi_bvalid) ||
            (state == STATE_R && m_axi_rvalid && m_axi_rlast);
        resp_err = bus_err || (state == STATE_B && |m_axi_bresp) ||
            (state == STATE_R && m_axi_rvalid && |m_axi_rresp);
        // A burst that completed normally for the current transfer
        burst_ok = burst_done && !aborting && !resp_err && !rst_dat && !xfer_start;

        // Once AW/AR has been presented the burst must run to completion
        in_burst = state == STATE_AW || state == STATE_W || state == STATE_B ||
            state == STATE_AR || state == STATE_R;
    end

    // ------------------------------------------------------------------
    // AXI
    // ------------------------------------------------------------------
    always_comb begin
        m_axi_awaddr  = {line_addr, line_bits'(0)};
        m_axi_awlen   = 8'(line_words - 1);
        m_axi_awsize  = 3'b010;
        m_axi_awburst = 2'b01;
        m_axi_awcache = 4'b0011;
        m_axi_awprot  = 3'b000;
        m_axi_awvalid = state == STATE_AW;

        m_axi_wdata   = in_range ? fifo_rdata : 32'b0;
        m_axi_wstrb   = in_range ? 4'hf : 4'h0;
        m_axi_wlast   = &beat;
        m_axi_wvalid  = state == STATE_W;

        m_axi_bready  = state == STATE_B;

        m_axi_araddr  = {line_addr, line_bits'(0)};
        m_axi_arlen   = 8'(line_words - 1);
        m_axi_arsize  = 3'b010;
        m_axi_arburst = 2'b01;
        m_axi_arcache = 4'b0011;
        m_axi_arprot  = 3'b000;
        m_axi_arvalid = state == STATE_AR;

        m_axi_rready  = state == STATE_R;

        fifo_pop      = state == STATE_W && m_axi_wready && in_range;
        fifo_push     = state == STATE_R && m_axi_rvalid && in_range;
        fifo_wdata    = m_axi_rdata;
    end

    // ------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------
    always_comb begin
        state_next   = state;
        addr_update  = 1'b0;
        boundary_irq = 1'b0;

        unique case (state)
            STATE_IDLE: if (x_dma && !aborting) state_next = STATE_WAIT_BLOCK;
            STATE_WAIT_BLOCK: begin
                // Stopped at an SDMA boundary until the address is written
                if (paused) state_next = STATE_WAIT_BLOCK;
                else if (words_left != 8'd0) state_next = STATE_ISSUE;
                else if (!x_infinite && x_blocks_left == 17'd0) state_next = STATE_IDLE;
                else if (x_read ? buf_rd_en : buf_wr_en) state_next = STATE_ISSUE;
            end
            STATE_ISSUE: state_next = x_read ? STATE_AW : STATE_AR;
            STATE_AW: if (m_axi_awready) state_next = STATE_W;
            STATE_W: if (m_axi_wready && m_axi_wlast) state_next = STATE_B;
            STATE_AR: if (m_axi_arready) state_next = STATE_R;
            STATE_B, STATE_R: begin
                if (burst_ok) begin
                    addr_update = 1'b1;
                    state_next  = more_data ? STATE_WAIT_BLOCK : STATE_IDLE;
                    // Stop at an SDMA buffer boundary unless the transfer is
                    // complete.
                    if (more_data && ~|(addr_next & boundary_mask)) boundary_irq = 1'b1;
                end else if (burst_done) begin
                    // An aborted burst resumes any transfer started since
                    state_next = aborting && x_dma ? STATE_WAIT_BLOCK : STATE_IDLE;
                end
            end
            default: state_next = STATE_IDLE;
        endcase
    end

    always_comb begin
        active = x_dma;
        busy   = in_burst || state == STATE_ISSUE;
    end

    always_ff @(posedge clk) begin
        state     <= state_next;
        bus_error <= 1'b0;

        if (state == STATE_ISSUE) begin
            line_addr  <= sdma_addr[31:line_bits];
            first_word <= sdma_addr[line_bits-1:2];
            num_words  <= (word_bits + 1)'(chunk_words);
            beat       <= '0;
        end

        if ((state == STATE_W && m_axi_wready) || (state == STATE_R && m_axi_rvalid))
            beat <= beat + 1'b1;

        if (state == STATE_R && m_axi_rvalid && |m_axi_rresp) bus_err <= 1'b1;

        if (state == STATE_WAIT_BLOCK && !paused && words_left == 8'd0 &&
            (x_read ? buf_rd_en : buf_wr_en) && (x_infinite || x_blocks_left != 17'd0))
            words_left <= x_block_words;

        if (state == STATE_WAIT_BLOCK && paused && sdma_restart) paused <= 1'b0;

        if (burst_ok) begin
            words_left    <= words_left_next;
            x_blocks_left <= blocks_left_next;
            paused        <= boundary_irq;
            if (!more_data) x_dma <= 1'b0;
        end else if (burst_done && !aborting && resp_err) begin
            // Error response: stop the transfer, a DAT reset is needed
            bus_error <= 1'b1;
            x_dma     <= 1'b0;
        end

        if (burst_done) begin
            aborting <= 1'b0;
            bus_err  <= 1'b0;
        end

        // A reset or new transfer while a burst is outstanding lets it
        // complete without touching the FIFO.
        if (rst_dat || xfer_start) begin
            if (in_burst && !burst_done) aborting <= 1'b1;
            if (!in_burst || burst_done) state <= STATE_IDLE;
            x_dma      <= 1'b0;
            paused     <= 1'b0;
            words_left <= 8'd0;
        end

        if (xfer_start && !rst_dat) begin
            x_dma         <= dma_en;
            x_read        <= tm_read;
            x_infinite    <= tm_multi && !tm_bce;
            x_blocks_left <= tm_multi ? {1'b0, blkcnt} : 17'd1;
            x_block_words <= 8'((11'(blksz) + 11'd3) >> 2);
        end

        if (reset) begin
            state         <= STATE_IDLE;
            x_dma         <= 1'b0;
            x_read        <= 1'b0;
            x_infinite    <= 1'b0;
            x_blocks_left <= 17'd0;
            x_block_words <= 8'd128;
            words_left    <= 8'd0;
            paused        <= 1'b0;
            aborting      <= 1'b0;
            bus_err       <= 1'b0;
            bus_error     <= 1'b0;
            beat          <= '0;
        end
    end

endmodule
