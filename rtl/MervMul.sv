// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// 33x33 signed multiplier with registered inputs, product and output so that
// it maps onto DSP48E1 slices with their internal pipeline registers and no
// fabric logic.  The result is valid `LATENCY` cycles after start.
module MervMul (
    input  logic        clk,
    input  logic        start,
    input  logic [ 1:0] funct,   // funct3[1:0]: MUL, MULH, MULHSU, MULHU
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result,
    output logic        done
);

    localparam int LATENCY = 4;

    logic signed [32:0] a_q, b_q;
    // verilator lint_off UNUSEDSIGNAL
    logic signed [65:0] m_q, p_q;
    // verilator lint_on UNUSEDSIGNAL
    logic        [ 1:0] funct_q, funct_qq, funct_qqq;
    logic [LATENCY-1:0] busy;

    always_ff @(posedge clk) begin
        a_q       <= {funct != 2'b11 && a[31], a};
        b_q       <= {funct[1] == 1'b0 && b[31], b};
        m_q       <= a_q * b_q;
        p_q       <= m_q;
        funct_q   <= funct;
        funct_qq  <= funct_q;
        funct_qqq <= funct_qq;
        result    <= funct_qqq == 2'b00 ? p_q[31:0] : p_q[63:32];
        busy      <= {busy[LATENCY-2:0], start};
    end

    assign done = busy[LATENCY-1];

endmodule
