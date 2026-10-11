// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// The single ALU, shared by arithmetic, address generation, branch targets,
// PC increment, AMOs and moving values between registers.  It is structured
// as one adder/subtractor (add, sub and the comparisons), a per-bit logic
// function and a final select so that each part maps onto a single level of
// LUTs.  The control is pre-decoded (see alu_ctrl() in MervDefs.svh) and
// registered by the core so that no decoding sits on the datapath.
`include "MervDefs.svh"

module MervALU (
    input  logic [`ALU_CTRL_W-1:0] ctrl,
    input  logic [31:0]            a,
    input  logic [31:0]            b,
    output logic [31:0]            result,
    output logic                   eq,
    output logic                   lt,
    output logic                   ltu
);

    wire       sub      = ctrl[`ALU_C_SUB];
    wire       out_sum  = ctrl[`ALU_C_SUM];
    wire       out_set  = ctrl[`ALU_C_SET];
    wire       set_u    = ctrl[`ALU_C_SETU];
    wire [2:0] lop      = ctrl[`ALU_C_LOP+:3];

    logic [32:0] sum;
    logic [31:0] logic_out, a_rev;

    assign sum = {1'b0, a} + {1'b0, b ^ {32{sub}}} + {32'b0, sub};

    // a - b borrows when a < b (unsigned), the signed comparison corrects
    // for the operand signs.
    assign ltu = ~sum[32];
    assign lt  = (a[31] ^ b[31]) ? a[31] : sum[31];
    assign eq  = a == b;

    always_comb begin
        for (int i = 0; i < 32; ++i) a_rev[i] = a[31-i];
    end

    always_comb begin
        case (lop)
            `LOP_XOR:   logic_out = a ^ b;
            `LOP_OR:    logic_out = a | b;
            `LOP_AND:   logic_out = a & b;
            `LOP_ANDN:  logic_out = a & ~b;
            `LOP_PASSA: logic_out = a;
            `LOP_PASSB: logic_out = b;
            `LOP_REVA:  logic_out = a_rev;
            default:    logic_out = 32'b0;
        endcase
    end

    always_comb begin
        if (out_sum) result = sum[31:0];
        else if (out_set) result = {31'b0, set_u ? ltu : lt};
        else result = logic_out;
    end

endmodule
