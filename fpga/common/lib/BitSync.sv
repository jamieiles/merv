// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"
module BitSync (
    input  logic clk,
    input  logic reset,
    input  logic d,
    output logic q
);

    (* ASYNC_REG = "TRUE" *)logic p1;
    (* ASYNC_REG = "TRUE" *)logic p2;

    MervADFF p1_dff (
        .clk  (clk),
        .reset(reset),
        .en   (1'b1),
        .d    (d),
        .q    (p1)
    );

    MervADFF p2_dff (
        .clk  (clk),
        .reset(reset),
        .en   (1'b1),
        .d    (p1),
        .q    (p2)
    );

    always_comb begin
        q = p2;
    end

endmodule
