// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Iterative radix-2 restoring divider for unsigned division (DIVU/REMU, and
// DIV/REM with non-negative operands, the core sends signed division with a
// negative operand to F mode).  The operands must be held stable from start
// until done, the divisor is used directly rather than being registered.
module MervDiv (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic        want_rem,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result,
    output logic        done
);

    logic [31:0] quot, rem;
    logic [ 4:0] count;
    logic        busy;
    logic [32:0] diff;

    // (rem << 1 | next dividend bit) - divisor
    assign diff   = {rem, quot[31]} - {1'b0, b};
    assign result = want_rem ? rem : quot;

    always_ff @(posedge clk) begin
        done <= 1'b0;

        if (start) begin
            quot  <= a;
            rem   <= 32'b0;
            count <= 5'd0;
            busy  <= 1'b1;
        end else if (busy) begin
            if (!diff[32]) begin
                rem  <= diff[31:0];
                quot <= {quot[30:0], 1'b1};
            end else begin
                rem  <= {rem[30:0], quot[31]};
                quot <= {quot[30:0], 1'b0};
            end
            count <= count + 5'd1;
            if (count == 5'd31) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end

        if (reset) busy <= 1'b0;
    end

endmodule
