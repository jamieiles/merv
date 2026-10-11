// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// SD clock generator.
//
// SDCLK is generated from the system clock by an even divider: each phase
// lasts half_period cycles giving SDCLK = clk / (2 * half_period).  Rather
// than clocking any logic from SDCLK, single-cycle strobes are produced so
// that the command and data engines stay in the system clock domain:
//
//   drive:  asserted in the last cycle of the high phase, so registered
//           outputs change on the falling edge of SDCLK and are sampled by
//           the card half a period later on the rising edge.
//   sample: asserted in the high phase, sample_delay cycles after the rising
//           edge.  The input registers capture the pins on every system clock
//           edge so with a delay of 0 the engines consume the value captured
//           at the rising edge of SDCLK, larger delays sample later into the
//           high phase for more hold margin.  The delay is limited to the
//           length of the high phase.
//
// When stop is asserted the clock is held low by suppressing the next rising
// edge.  stop is sampled in the last cycle of the low phase so any state
// change caused by a sample strobe is always seen before the next rising
// edge, which lets the data engine freeze the card between blocks.
module SDClockGen (
    input  logic       clk,
    input  logic       reset,
    input  logic       enable,
    input  logic [7:0] half_period,
    input  logic [1:0] sample_delay,
    input  logic       stop,
    output logic       sdclk_pin,
    output logic       drive,
    output logic       sample
);

    logic [7:0] count;
    logic       sdclk;
    logic [7:0] count_next;
    logic       sdclk_next;
    logic [7:0] hp;
    logic [7:0] delay;
    logic       last;

    always_comb begin
        hp    = ~|half_period ? 8'd1 : half_period;
        delay = 8'(sample_delay) >= hp ? hp - 1'b1 : 8'(sample_delay);
        last  = count >= hp - 1'b1;

        drive = enable && sdclk && last;
        sample = enable && sdclk && count == delay;
    end

    always_comb begin
        count_next = count + 1'b1;
        sdclk_next = sdclk;

        if (!enable) begin
            count_next = 8'b0;
            sdclk_next = 1'b0;
        end else if (last) begin
            count_next = 8'b0;
            if (sdclk) sdclk_next = 1'b0;
            else if (!stop) sdclk_next = 1'b1;
            else count_next = count;
        end
    end

    MervDFF #(
        .width(8)
    ) count_dff (
        .clk  (clk),
        .reset(reset),
        .en   (1'b1),
        .d    (count_next),
        .q    (count)
    );

    MervDFF sdclk_dff (
        .clk  (clk),
        .reset(reset),
        .en   (1'b1),
        .d    (sdclk_next),
        .q    (sdclk)
    );

    // A copy of SDCLK that only drives the pin so that it can be packed into
    // the IOB.
    (* IOB = "TRUE" *)
    MervDFF sdclk_pin_dff (
        .clk  (clk),
        .reset(reset),
        .en   (1'b1),
        .d    (sdclk_next),
        .q    (sdclk_pin)
    );

endmodule
