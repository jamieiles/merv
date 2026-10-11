// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// Multi-block data buffer between the data engine and the buffer data port.
//
// The buffer is a FIFO of 32-bit words in block RAM, the direction is fixed
// for each transfer: the data engine fills it and the CPU drains it for reads
// and vice versa for writes.  Several blocks are buffered so that the card
// can keep transferring while the CPU empties or fills the buffer, and so
// that the CPU can move more than one block per interrupt.  Block level
// status is derived here:
//
//   buf_rd_en: Buffer Read Enable, at least one received block has been
//              checked and is ready to be read.
//   buf_wr_en: Buffer Write Enable, there is space for a block and the CPU
//              still has blocks to write.
//   blk_space: there is space for the data engine to receive a block.
//   blk_avail: a whole block has been written by the CPU and can be sent.
//
// The RAM has a registered read port addressed by the next read pointer so
// that the head of the FIFO is always available without a read latency, a
// write to the location being read is bypassed.
module SDDataFifo #(
    parameter int order = 10
) (
    input  logic        clk,
    input  logic        reset,
    // Transfer configuration, latched on xfer_start
    input  logic        xfer_start,
    input  logic        tm_read,
    input  logic        tm_multi,
    input  logic        tm_bce,
    input  logic [15:0] blkcnt,
    input  logic [ 9:0] blksz,
    input  logic        read_active,
    input  logic        write_active,
    // Data engine
    input  logic        eng_push,
    input  logic [31:0] eng_wdata,
    input  logic        eng_pop,
    input  logic        eng_blk_done,
    // CPU
    input  logic        cpu_push,
    input  logic [31:0] cpu_wdata,
    input  logic        cpu_pop,
    output logic [31:0] rdata,
    // Status
    output logic        empty,
    output logic        blk_space,
    output logic        blk_avail,
    output logic        buf_rd_en,
    output logic        buf_wr_en
);

    localparam int depth = 1 << order;

    logic [   31:0] mem                 [depth];
    logic [order-1:0] wr_ptr;
    logic [order-1:0] rd_ptr;
    logic [order-1:0] rd_ptr_next;
    logic [  order:0] count;
    logic [  order:0] count_next;
    logic [  order:0] space;
    logic [    31:0] mem_q;
    logic [    31:0] bypass_data;
    logic            bypass;
    logic [    7:0] block_words;
    logic           x_read;
    logic           x_infinite;
    logic [   16:0] cpu_blocks_left;
    logic [  order:0] blocks_ready;
    logic [    7:0] cpu_words;
    logic           cpu_blk_done;
    logic           push;
    logic           pop;
    logic [   31:0] wdata;

    always_comb begin
        push = x_read ? eng_push : cpu_push;
        pop = x_read ? cpu_pop : eng_pop;
        wdata = x_read ? eng_wdata : cpu_wdata;

        // Never overflow or underflow: the engine only receives a block when
        // there is space for it and stray CPU accesses are dropped.
        if (count == (order + 1)'(depth)) push = 1'b0;
        if (~|count) pop = 1'b0;

        count_next = count + (order + 1)'(push) - (order + 1)'(pop);
        rd_ptr_next = pop ? rd_ptr + 1'b1 : rd_ptr;
        space = (order + 1)'(depth) - count;

        // The CPU side counts words so that block boundaries are known.
        cpu_blk_done = (x_read ? pop : push) && cpu_words == block_words - 1'b1;

        rdata = bypass ? bypass_data : mem_q;
        empty = ~|count;
        blk_space = space >= (order + 1)'(block_words);
        blk_avail = !x_read && count >= (order + 1)'(block_words);
        buf_rd_en = read_active && |blocks_ready;
        buf_wr_en = write_active && blk_space && (x_infinite || |cpu_blocks_left);
    end

    always_ff @(posedge clk) begin
        if (push) mem[wr_ptr] <= wdata;
        mem_q <= mem[rd_ptr_next];
    end

    always_ff @(posedge clk) begin
        bypass      <= push && wr_ptr == rd_ptr_next;
        bypass_data <= wdata;

        if (push) wr_ptr <= wr_ptr + 1'b1;
        rd_ptr <= rd_ptr_next;
        count  <= count_next;

        if (cpu_blk_done) cpu_words <= 8'b0;
        else if (x_read ? pop : push) cpu_words <= cpu_words + 1'b1;

        // Blocks become readable once the engine has checked them and are
        // consumed as the CPU reads the last word of each.
        blocks_ready <= blocks_ready + (order + 1)'(eng_blk_done && x_read) -
            (order + 1)'(cpu_blk_done && x_read);

        if (cpu_blk_done && !x_read && !x_infinite) cpu_blocks_left <= cpu_blocks_left - 1'b1;

        if (xfer_start) begin
            x_read          <= tm_read;
            x_infinite      <= tm_multi && !tm_bce;
            cpu_blocks_left <= tm_multi ? {1'b0, blkcnt} : 17'd1;
            block_words     <= 8'((11'(blksz) + 11'd3) >> 2);
        end

        if (reset || xfer_start) begin
            wr_ptr       <= '0;
            rd_ptr       <= '0;
            count        <= '0;
            cpu_words    <= 8'b0;
            blocks_ready <= '0;
            bypass       <= 1'b0;
        end

        if (reset) begin
            x_read          <= 1'b0;
            x_infinite      <= 1'b0;
            cpu_blocks_left <= 17'b0;
            block_words     <= 8'd128;
        end
    end

endmodule
