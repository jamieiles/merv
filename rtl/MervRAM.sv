// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// The core's private RAM: 8KB of true dual port block RAM holding the F mode
// firmware (F-RAM) with the GPR banks and the CSRs that are only accessed by
// software or on traps in the top 128 words.  Port A is read-only, port B is
// read/write with byte enables (write-first is not relied on).  Both ports
// use the BRAM output register so the read latency is two cycles: the
// address is sampled at the end of the cycle that it is presented in, and the
// data is valid two cycles later and held until the next read on that port.
module MervRAM #(
    parameter INIT_FILE = ""
) (
    input  logic        clk,
    input  logic        a_en,
    input  logic [10:0] a_addr,
    output logic [31:0] a_data,
    input  logic        b_en,
    input  logic [ 3:0] b_we,
    input  logic [10:0] b_addr,
    input  logic [31:0] b_wdata,
    output logic [31:0] b_data
);

    (* ram_style = "block" *)
    logic [31:0] mem[0:2047];
    logic [31:0] a_q, b_q;
    logic a_en_q, b_en_q;

    // The firmware image doesn't cover the register words, which must start
    // as zero (x0 in both banks is never written).
    initial begin
        for (int i = 0; i < 2048; ++i) mem[i] = 32'b0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always_ff @(posedge clk) begin
        if (a_en) a_q <= mem[a_addr];
        a_en_q <= a_en;
        if (a_en_q) a_data <= a_q;
    end

    always_ff @(posedge clk) begin
        if (b_en) begin
            for (int i = 0; i < 4; ++i)
                if (b_we[i]) mem[b_addr][i*8+:8] <= b_wdata[i*8+:8];
            b_q <= mem[b_addr];
        end
        b_en_q <= b_en & ~|b_we;
        if (b_en_q) b_data <= b_q;
    end

endmodule
