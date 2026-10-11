// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// SD command line engine.
//
// Transmits 48-bit commands with CRC7 and receives 48-bit or 136-bit
// responses, checking the CRC, end bit and command index as requested.  The
// response must start within 64 clocks of the end of the command or a
// timeout is reported.  At least 8 clocks (NCC) are inserted between the end
// of one command (or its response) and the start of the next.
//
// Auto-CMD12 is requested by the data engine: it is issued as an R1b CMD12
// with CRC and index checking and its response is stored in RESPONSE[127:96]
// as the SDHCI specification requires.
module SDCmdEngine (
    input  logic         clk,
    input  logic         reset,
    input  logic         drive,
    input  logic         sample,
    // Command from the register file
    input  logic         start,
    input  logic [  5:0] index,
    input  logic [ 31:0] arg,
    input  logic [  1:0] resp_type,
    input  logic         crc_check,
    input  logic         index_check,
    // Auto-CMD12 from the data engine
    input  logic         acmd12_req,
    output logic         acmd12_ack,
    output logic         busy,
    // Completion: errors are valid with done
    output logic         done,
    output logic         done_auto,
    output logic         err_timeout,
    output logic         err_crc,
    output logic         err_end,
    output logic         err_index,
    output logic [127:0] resp,
    // CMD line
    output logic         cmd_o,
    output logic         cmd_t,
    input  logic         cmd_i
);

    localparam logic [1:0] RESP_NONE = 2'b00;
    localparam logic [1:0] RESP_136 = 2'b01;

    localparam int NCR_MAX = 64;
    localparam int NCC_MIN = 8;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_PENDING,
        STATE_TX,
        STATE_WAIT_RESP,
        STATE_RX
    } state_t;

    state_t         state;
    state_t         state_next;

    logic   [ 39:0] tx_sr;
    logic   [ 39:0] tx_sr_next;
    logic   [  5:0] tx_count;
    logic   [  5:0] tx_count_next;
    logic   [  6:0] crc;
    logic   [  6:0] crc_next;
    logic   [133:0] rx_sr;
    logic   [133:0] rx_sr_next;
    logic   [  7:0] rx_count;
    logic   [  7:0] rx_count_next;
    logic   [  6:0] wait_count;
    logic   [  6:0] wait_count_next;
    logic   [  3:0] ncc_count;
    logic   [  3:0] ncc_count_next;
    logic           cmd_o_next;
    logic           cmd_t_next;
    logic   [  1:0] cur_resp_type;
    logic   [  1:0] cur_resp_type_next;
    logic   [  5:0] cur_index;
    logic   [  5:0] cur_index_next;
    logic           cur_crc_check;
    logic           cur_crc_check_next;
    logic           cur_index_check;
    logic           cur_index_check_next;
    logic           cur_auto;
    logic           cur_auto_next;
    logic   [127:0] resp_next;

    logic           tx_bit;
    logic           rx_long;
    logic   [  7:0] rx_last;
    logic           rx_crc_bit;
    // verilator lint_off UNUSEDSIGNAL
    logic   [134:0] rx_full;
    // verilator lint_on UNUSEDSIGNAL
    logic           rx_finish;

    function automatic logic [6:0] crc7(input logic [6:0] c, input logic b);
        logic fb;
        fb   = c[6] ^ b;
        crc7 = {c[5:3], c[2] ^ fb, c[1:0], fb};
    endfunction

    always_comb begin
        busy    = state != STATE_IDLE;
        rx_long = cur_resp_type == RESP_136;
        // Bits following the start bit, including the end bit.
        rx_last = rx_long ? 8'd134 : 8'd46;
        // R2 carries the CID/CSD CRC over bits [127:8], the other responses
        // cover everything following the start bit up to the CRC.
        rx_crc_bit = rx_long ? (rx_count >= 8'd7 && rx_count < 8'd134) : rx_count < 8'd46;
        rx_full = {rx_sr, cmd_i};
        rx_finish = state == STATE_RX && sample && rx_count == rx_last;

        if (tx_count < 6'd40) tx_bit = tx_sr[39];
        else if (tx_count < 6'd47) tx_bit = crc[6];
        else tx_bit = 1'b1;
    end

    always_comb begin
        state_next           = state;
        tx_sr_next           = tx_sr;
        tx_count_next        = tx_count;
        crc_next             = crc;
        rx_sr_next           = rx_sr;
        rx_count_next        = rx_count;
        wait_count_next      = wait_count;
        ncc_count_next       = ncc_count;
        cmd_o_next           = cmd_o;
        cmd_t_next           = cmd_t;
        cur_resp_type_next   = cur_resp_type;
        cur_index_next       = cur_index;
        cur_crc_check_next   = cur_crc_check;
        cur_index_check_next = cur_index_check;
        cur_auto_next        = cur_auto;
        resp_next            = resp;

        acmd12_ack           = 1'b0;
        done                 = 1'b0;
        done_auto            = cur_auto;
        err_timeout          = 1'b0;
        err_crc              = 1'b0;
        err_end              = 1'b0;
        err_index            = 1'b0;

        if (drive && ncc_count < 4'(NCC_MIN) && (state == STATE_IDLE || state == STATE_PENDING))
            ncc_count_next = ncc_count + 1'b1;

        case (state)
            STATE_IDLE: begin
                if (start) begin
                    cur_index_next       = index;
                    cur_resp_type_next   = resp_type;
                    cur_crc_check_next   = crc_check;
                    cur_index_check_next = index_check;
                    cur_auto_next        = 1'b0;
                    tx_sr_next           = {2'b01, index, arg};
                    state_next           = STATE_PENDING;
                end else if (acmd12_req) begin
                    acmd12_ack           = 1'b1;
                    cur_index_next       = 6'd12;
                    cur_resp_type_next   = 2'b11;
                    cur_crc_check_next   = 1'b1;
                    cur_index_check_next = 1'b1;
                    cur_auto_next        = 1'b1;
                    tx_sr_next           = {2'b01, 6'd12, 32'b0};
                    state_next           = STATE_PENDING;
                end
            end
            STATE_PENDING: begin
                tx_count_next = 6'd0;
                crc_next      = 7'b0;
                if (ncc_count >= 4'(NCC_MIN)) state_next = STATE_TX;
            end
            STATE_TX: begin
                if (drive) begin
                    tx_count_next = tx_count + 1'b1;
                    if (tx_count == 6'd48) begin
                        // Release the line after the end bit.
                        cmd_t_next      = 1'b1;
                        cmd_o_next      = 1'b1;
                        wait_count_next = 7'd0;
                        if (cur_resp_type == RESP_NONE) begin
                            done           = 1'b1;
                            ncc_count_next = 4'd0;
                            state_next     = STATE_IDLE;
                        end else begin
                            state_next = STATE_WAIT_RESP;
                        end
                    end else begin
                        cmd_t_next = 1'b0;
                        cmd_o_next = tx_bit;
                        if (tx_count < 6'd40) begin
                            tx_sr_next = {tx_sr[38:0], 1'b0};
                            crc_next   = crc7(crc, tx_bit);
                        end else if (tx_count < 6'd47) begin
                            crc_next = {crc[5:0], 1'b0};
                        end
                    end
                end
            end
            STATE_WAIT_RESP: begin
                if (sample) begin
                    if (!cmd_i) begin
                        rx_count_next = 8'd0;
                        crc_next      = 7'b0;
                        state_next    = STATE_RX;
                    end else if (wait_count == 7'(NCR_MAX - 1)) begin
                        done           = 1'b1;
                        err_timeout    = 1'b1;
                        ncc_count_next = 4'd0;
                        state_next     = STATE_IDLE;
                    end else begin
                        wait_count_next = wait_count + 1'b1;
                    end
                end
            end
            STATE_RX: begin
                if (sample) begin
                    rx_sr_next    = {rx_sr[132:0], cmd_i};
                    rx_count_next = rx_count + 1'b1;
                    if (rx_crc_bit) crc_next = crc7(crc, cmd_i);

                    if (rx_finish) begin
                        done           = 1'b1;
                        err_end        = !cmd_i;
                        err_crc        = cur_crc_check && |crc;
                        err_index      = cur_index_check && !rx_long && rx_full[45:40] != cur_index;
                        ncc_count_next = 4'd0;
                        state_next     = STATE_IDLE;

                        if (cur_auto) resp_next[127:96] = rx_full[39:8];
                        else if (rx_long) resp_next = {8'b0, rx_full[127:8]};
                        else resp_next[31:0] = rx_full[39:8];
                    end
                end
            end
            default: state_next = STATE_IDLE;
        endcase
    end

    always_ff @(posedge clk) begin
        state           <= state_next;
        tx_sr           <= tx_sr_next;
        tx_count        <= tx_count_next;
        crc             <= crc_next;
        rx_sr           <= rx_sr_next;
        rx_count        <= rx_count_next;
        wait_count      <= wait_count_next;
        ncc_count       <= ncc_count_next;
        cmd_o           <= cmd_o_next;
        cmd_t           <= cmd_t_next;
        cur_resp_type   <= cur_resp_type_next;
        cur_index       <= cur_index_next;
        cur_crc_check   <= cur_crc_check_next;
        cur_index_check <= cur_index_check_next;
        cur_auto        <= cur_auto_next;
        resp            <= resp_next;

        if (reset) begin
            state     <= STATE_IDLE;
            ncc_count <= 4'(NCC_MIN);
            cmd_o     <= 1'b1;
            cmd_t     <= 1'b1;
            cur_auto  <= 1'b0;
            resp      <= 128'b0;
        end
    end

endmodule
