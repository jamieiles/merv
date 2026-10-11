// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"
module MervADFF #(
    parameter width = 1,
    parameter reset_val = 0
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             en,
    input  logic [width-1:0] d,
    output logic [width-1:0] q
);

    (* ASYNC_REG = "TRUE" *) logic [width-1:0] out;

    always_ff @(posedge clk) begin
        if (en) out <= d;
        if (reset) out <= width'(reset_val);
    end

    always_comb q = out;

endmodule
