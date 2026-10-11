// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// SD data line engine.
//
// Transfers blocks between the DAT lines and the data buffer in 1-bit or
// 4-bit mode with a CRC16 on each data line:
//
// Reads: the start bit is accepted as soon as the command has been issued
// (data may begin before the response has been received).  Each block is
// written to the buffer as it is received and is marked ready once the CRC
// and end bit have been checked.  If the buffer has no space for another
// block SDCLK is stopped between blocks until the CPU has made space.
//
// Writes: once the command response has been received and a whole block is
// in the buffer the block is sent after NWR clocks, followed by the CRC and
// end bit.  The card's CRC status token and busy indication are then checked
// on DAT0.  SDCLK is stopped while waiting for the next block to be written.
//
// R1b commands without data wait for busy to be released on DAT0.  At the
// end of a multi-block transfer with Auto-CMD12 enabled CMD12 is requested
// from the command engine and its busy is waited for.  Transfer complete is
// signalled once everything has finished and, for reads, the last block has
// been drained from the buffer.
//
// The data timeout counts TMCLK (clk / tmclk_div) cycles while waiting for
// the card: for a read start bit, CRC status token or busy to be released.
module SDDataEngine #(
    parameter int tmclk_div = 81
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        drive,
    input  logic        sample,
    output logic        stop,
    // Transfer configuration, latched on xfer_start/busy_start
    input  logic        xfer_start,
    input  logic        busy_start,
    input  logic [ 9:0] blksz,
    input  logic [15:0] blkcnt,
    input  logic        tm_read,
    input  logic        tm_multi,
    input  logic        tm_bce,
    input  logic        tm_auto12,
    input  logic        wide,
    input  logic [ 3:0] timeout_ctrl,
    // Command engine
    input  logic        cmd_done,
    input  logic        cmd_done_auto,
    input  logic        cmd_err,
    output logic        acmd12_req,
    input  logic        acmd12_ack,
    // Data buffer
    output logic        fifo_push,
    output logic [31:0] fifo_wdata,
    output logic        fifo_pop,
    input  logic [31:0] fifo_rdata,
    input  logic        fifo_empty,
    // DMA still writing buffered data to memory
    input  logic        dma_busy,
    input  logic        blk_space,
    input  logic        blk_avail,
    output logic        blk_done,
    // Status
    output logic        active,
    output logic        dat_active,
    output logic        read_active,
    output logic        write_active,
    output logic        xfer_done,
    output logic        err_timeout,
    output logic        err_crc,
    output logic        err_end,
    // DAT lines
    output logic [ 3:0] dat_o,
    output logic [ 3:0] dat_t,
    input  logic [ 3:0] dat_i
);

    localparam int BUSY_GUARD = 4;
    localparam int NWR = 2;

    typedef enum logic [4:0] {
        STATE_IDLE,
        STATE_R_WAIT_START,
        STATE_R_DATA,
        STATE_R_CRC,
        STATE_R_END,
        STATE_W_WAIT_RESP,
        STATE_W_WAIT_BUF,
        STATE_W_NWR,
        STATE_W_DATA,
        STATE_W_CRC,
        STATE_W_END,
        STATE_W_RELEASE,
        STATE_W_STATUS,
        STATE_W_STATUS_BITS,
        STATE_B_WAIT_RESP,
        STATE_BUSY,
        STATE_END_XFER,
        STATE_A12_REQ,
        STATE_A12_WAIT,
        STATE_DRAIN,
        STATE_DONE
    } state_t;

    state_t        state;
    state_t        state_next;

    // Latched transfer configuration
    logic          x_read;
    logic          x_read_next;
    logic          x_xfer;
    logic          x_xfer_next;
    logic          x_wide;
    logic          x_wide_next;
    logic          x_auto12;
    logic          x_auto12_next;
    logic          x_infinite;
    logic          x_infinite_next;
    logic   [12:0] x_blk_bits;
    logic   [12:0] x_blk_bits_next;
    logic   [16:0] blocks_left;
    logic   [16:0] blocks_left_next;

    logic   [12:0] bit_count;
    logic   [12:0] bit_count_next;
    logic   [ 4:0] count;
    logic   [ 4:0] count_next;
    logic   [ 7:0] byte_sr;
    logic   [ 7:0] byte_sr_next;
    logic   [31:0] word;
    logic   [31:0] word_next;
    logic   [15:0] crc           [4];
    logic   [15:0] crc_next      [4];
    logic   [ 2:0] status;
    logic   [ 2:0] status_next;
    logic   [ 3:0] dat_o_next;
    logic   [ 3:0] dat_t_next;

    logic   [ 6:0] tmclk_count;
    logic          tmclk_tick;
    logic   [27:0] timeout_count;
    logic   [27:0] timeout_count_next;
    logic   [ 3:0] timeout_exp;
    logic          waiting;
    logic          timed_out;

    logic   [ 2:0] inc;
    logic   [12:0] bit_count_inc;
    logic   [ 3:0] lines;
    logic   [ 3:0] out_bits;
    logic   [31:0] rword_next;

    function automatic logic [15:0] crc16(input logic [15:0] c, input logic b);
        logic fb;
        fb    = c[15] ^ b;
        crc16 = {c[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
    endfunction

    function automatic logic [31:0] bswap(input logic [31:0] w);
        bswap = {w[7:0], w[15:8], w[23:16], w[31:24]};
    endfunction

    always_comb begin
        inc           = x_wide ? 3'd4 : 3'd1;
        bit_count_inc = bit_count + 13'(inc);
        lines         = x_wide ? 4'b1111 : 4'b0001;
        out_bits      = x_wide ? word[31:28] : {3'b111, word[31]};

        active        = state != STATE_IDLE;
        dat_active    = state != STATE_IDLE && state != STATE_DRAIN && state != STATE_DONE;
        read_active   = active && x_xfer && x_read;
        write_active  = active && x_xfer && !x_read;

        stop = (state == STATE_R_WAIT_START && !blk_space) ||
            (state == STATE_W_WAIT_BUF && !blk_avail);

        waiting = (state == STATE_R_WAIT_START && blk_space) || state == STATE_W_STATUS ||
            state == STATE_W_STATUS_BITS || state == STATE_BUSY;

        // 2^(13 + n) TMCLK cycles, 0xf is reserved so treat it as 0xe.
        timeout_exp = &timeout_ctrl ? 4'he : timeout_ctrl;
        timed_out = timeout_count[5'(timeout_exp)+5'd13];
    end

    always_comb begin
        state_next       = state;
        x_read_next      = x_read;
        x_xfer_next      = x_xfer;
        x_wide_next      = x_wide;
        x_auto12_next    = x_auto12;
        x_infinite_next  = x_infinite;
        x_blk_bits_next  = x_blk_bits;
        blocks_left_next = blocks_left;
        bit_count_next   = bit_count;
        count_next       = count;
        byte_sr_next     = byte_sr;
        word_next        = word;
        crc_next         = crc;
        status_next      = status;
        dat_o_next       = dat_o;
        dat_t_next       = dat_t;
        rword_next       = word;

        fifo_push        = 1'b0;
        fifo_wdata       = word;
        fifo_pop         = 1'b0;
        blk_done         = 1'b0;
        acmd12_req       = 1'b0;
        xfer_done        = 1'b0;
        err_timeout      = 1'b0;
        err_crc          = 1'b0;
        err_end          = 1'b0;

        case (state)
            STATE_IDLE: begin
                dat_t_next = 4'b1111;
                dat_o_next = 4'b1111;
                if (xfer_start || busy_start) begin
                    x_read_next      = tm_read;
                    x_xfer_next      = xfer_start;
                    x_wide_next      = wide;
                    x_auto12_next    = tm_auto12 && tm_multi;
                    x_infinite_next  = tm_multi && !tm_bce;
                    x_blk_bits_next  = {blksz, 3'b0};
                    blocks_left_next = tm_multi ? {1'b0, blkcnt} : 17'd1;
                    bit_count_next   = 13'd0;
                    count_next       = 5'd0;
                    crc_next         = '{default: 16'b0};
                    if (busy_start) state_next = STATE_B_WAIT_RESP;
                    else if (tm_read) state_next = STATE_R_WAIT_START;
                    else state_next = STATE_W_WAIT_RESP;
                end
            end
            // ----------------------------------------------------------------
            // Reads
            // ----------------------------------------------------------------
            STATE_R_WAIT_START: begin
                bit_count_next = 13'd0;
                count_next     = 5'd0;
                word_next      = 32'b0;
                crc_next       = '{default: 16'b0};
                if (sample && blk_space && !dat_i[0]) state_next = STATE_R_DATA;
                else if (cmd_done && !cmd_done_auto && cmd_err) state_next = STATE_IDLE;
            end
            STATE_R_DATA: begin
                if (sample) begin
                    for (int i = 0; i < 4; ++i)
                        if (lines[i]) crc_next[i] = crc16(crc[i], dat_i[i]);
                    byte_sr_next   = x_wide ? {byte_sr[3:0], dat_i} : {byte_sr[6:0], dat_i[0]};
                    bit_count_next = bit_count_inc;

                    if (bit_count_inc[2:0] == 3'b0) begin
                        // Bytes are packed little-endian into words.
                        rword_next                            = word;
                        rword_next[{bit_count[4:3], 3'b0}+:8] = byte_sr_next;
                        word_next                             = rword_next;
                        if (bit_count_inc[4:3] == 2'b0 || bit_count_inc == x_blk_bits) begin
                            fifo_push  = 1'b1;
                            fifo_wdata = rword_next;
                            word_next  = 32'b0;
                        end
                    end

                    if (bit_count_inc == x_blk_bits) begin
                        count_next = 5'd0;
                        state_next = STATE_R_CRC;
                    end
                end
            end
            STATE_R_CRC: begin
                if (sample) begin
                    for (int i = 0; i < 4; ++i)
                        if (lines[i]) crc_next[i] = crc16(crc[i], dat_i[i]);
                    count_next = count + 1'b1;
                    if (count == 5'd15) state_next = STATE_R_END;
                end
            end
            STATE_R_END: begin
                if (sample) begin
                    if ((dat_i & lines) != lines) begin
                        err_end    = 1'b1;
                        state_next = STATE_IDLE;
                    end else if (|crc[0] || |crc[1] || |crc[2] || |crc[3]) begin
                        err_crc    = 1'b1;
                        state_next = STATE_IDLE;
                    end else begin
                        blk_done         = 1'b1;
                        blocks_left_next = blocks_left - 1'b1;
                        if (x_infinite || blocks_left != 17'd1) state_next = STATE_R_WAIT_START;
                        else state_next = STATE_END_XFER;
                    end
                end
            end
            // ----------------------------------------------------------------
            // Writes
            // ----------------------------------------------------------------
            STATE_W_WAIT_RESP: begin
                if (cmd_done && !cmd_done_auto)
                    state_next = cmd_err ? STATE_IDLE : STATE_W_WAIT_BUF;
            end
            STATE_W_WAIT_BUF: begin
                count_next     = 5'd0;
                bit_count_next = 13'd0;
                crc_next       = '{default: 16'b0};
                if (blk_avail) state_next = STATE_W_NWR;
            end
            STATE_W_NWR: begin
                if (drive) begin
                    count_next = count + 1'b1;
                    if (count == 5'(NWR)) begin
                        // Start bit
                        dat_t_next = ~lines;
                        dat_o_next = 4'b0000;
                        word_next  = bswap(fifo_rdata);
                        fifo_pop   = 1'b1;
                        state_next = STATE_W_DATA;
                    end
                end
            end
            STATE_W_DATA: begin
                if (drive) begin
                    dat_o_next = out_bits;
                    for (int i = 0; i < 4; ++i)
                        if (lines[i]) crc_next[i] = crc16(crc[i], out_bits[i]);
                    word_next      = x_wide ? {word[27:0], 4'b0} : {word[30:0], 1'b0};
                    bit_count_next = bit_count_inc;
                    if (bit_count_inc == x_blk_bits) begin
                        count_next = 5'd0;
                        state_next = STATE_W_CRC;
                    end else if (bit_count_inc[4:0] == 5'b0) begin
                        word_next = bswap(fifo_rdata);
                        fifo_pop  = 1'b1;
                    end
                end
            end
            STATE_W_CRC: begin
                if (drive) begin
                    for (int i = 0; i < 4; ++i) begin
                        dat_o_next[i] = crc[i][15] | ~lines[i];
                        crc_next[i]   = {crc[i][14:0], 1'b0};
                    end
                    count_next = count + 1'b1;
                    if (count == 5'd15) state_next = STATE_W_END;
                end
            end
            STATE_W_END: begin
                if (drive) begin
                    dat_o_next = 4'b1111;
                    state_next = STATE_W_RELEASE;
                end
            end
            STATE_W_RELEASE: begin
                if (drive) begin
                    dat_t_next = 4'b1111;
                    state_next = STATE_W_STATUS;
                end
            end
            STATE_W_STATUS: begin
                count_next = 5'd0;
                if (sample && !dat_i[0]) state_next = STATE_W_STATUS_BITS;
            end
            STATE_W_STATUS_BITS: begin
                if (sample) begin
                    count_next = count + 1'b1;
                    if (count != 5'd3) status_next = {status[1:0], dat_i[0]};
                    if (count == 5'd3) begin
                        if (status != 3'b010 || !dat_i[0]) begin
                            err_crc    = 1'b1;
                            state_next = STATE_IDLE;
                        end else begin
                            count_next = 5'd0;
                            state_next = STATE_BUSY;
                        end
                    end
                end
            end
            // ----------------------------------------------------------------
            // R1b busy and end of transfer
            // ----------------------------------------------------------------
            STATE_B_WAIT_RESP: begin
                count_next = 5'd0;
                if (cmd_done && !cmd_done_auto) state_next = cmd_err ? STATE_IDLE : STATE_BUSY;
            end
            STATE_BUSY: begin
                if (sample) begin
                    if (count != 5'(BUSY_GUARD)) begin
                        count_next = count + 1'b1;
                    end else if (dat_i[0]) begin
                        if (!x_xfer) begin
                            state_next = STATE_DONE;
                        end else if (blocks_left == 17'd0 && !x_infinite) begin
                            // Auto-CMD12 busy following the last block.
                            state_next = x_read ? STATE_DRAIN : STATE_DONE;
                        end else begin
                            blk_done         = 1'b1;
                            blocks_left_next = blocks_left - 1'b1;
                            if (x_infinite || blocks_left != 17'd1) state_next = STATE_W_WAIT_BUF;
                            else state_next = STATE_END_XFER;
                        end
                    end
                end
            end
            STATE_END_XFER: begin
                count_next = 5'd0;
                if (x_auto12) state_next = STATE_A12_REQ;
                else state_next = x_read ? STATE_DRAIN : STATE_DONE;
            end
            STATE_A12_REQ: begin
                acmd12_req = 1'b1;
                if (acmd12_ack) state_next = STATE_A12_WAIT;
            end
            STATE_A12_WAIT: begin
                count_next = 5'd0;
                if (cmd_done && cmd_done_auto) begin
                    if (cmd_err) state_next = x_read ? STATE_DRAIN : STATE_DONE;
                    else state_next = STATE_BUSY;
                end
            end
            STATE_DRAIN: begin
                // Transfer complete once the data has left the buffer, with
                // DMA that is once it has been written to memory.
                if (fifo_empty && !dma_busy) state_next = STATE_DONE;
            end
            STATE_DONE: begin
                xfer_done  = 1'b1;
                state_next = STATE_IDLE;
            end
            default: state_next = STATE_IDLE;
        endcase

        if (waiting && timed_out) begin
            err_timeout = 1'b1;
            state_next  = STATE_IDLE;
        end
    end

    always_comb begin
        timeout_count_next = timeout_count;
        if (state_next != state || !waiting || stop) timeout_count_next = 28'b0;
        else if (tmclk_tick) timeout_count_next = timeout_count + 1'b1;
    end

    always_comb begin
        tmclk_tick = tmclk_count == 7'(tmclk_div - 1);
    end

    always_ff @(posedge clk) begin
        tmclk_count <= tmclk_tick ? 7'b0 : tmclk_count + 1'b1;

        state <= state_next;
        x_read <= x_read_next;
        x_xfer <= x_xfer_next;
        x_wide <= x_wide_next;
        x_auto12 <= x_auto12_next;
        x_infinite <= x_infinite_next;
        x_blk_bits <= x_blk_bits_next;
        blocks_left <= blocks_left_next;
        bit_count <= bit_count_next;
        count <= count_next;
        byte_sr <= byte_sr_next;
        word <= word_next;
        crc <= crc_next;
        status <= status_next;
        dat_o <= dat_o_next;
        dat_t <= dat_t_next;
        timeout_count <= timeout_count_next;

        if (reset) begin
            tmclk_count <= 7'b0;
            state       <= STATE_IDLE;
            x_xfer      <= 1'b0;
            x_read      <= 1'b0;
            word        <= 32'b0;
            dat_o       <= 4'b1111;
            dat_t       <= 4'b1111;
        end
    end

endmodule
