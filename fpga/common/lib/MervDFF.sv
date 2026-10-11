// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"
module MervDFF #(
    parameter width = 1,
    parameter reset_val = 0
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             en,
    input  logic [width-1:0] d,
    output logic [width-1:0] q
);

    always_ff @(posedge clk) begin
        if (en) q <= d;
        if (reset) q <= width'(reset_val);
    end

endmodule
