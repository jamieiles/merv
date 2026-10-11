// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// RISC-V Platform-Level Interrupt Controller for up to 31 level triggered
// sources (IDs 1 to num_sources) and num_contexts contexts, compatible with
// "sifive,plic-1.0.0":
//
//   0x000000 + 4 * id         source priority
//   0x001000                  pending bits
//   0x002000 + 0x80 * ctx     enable bits
//   0x200000 + 0x1000 * ctx   priority threshold
//   0x200004 + 0x1000 * ctx   claim/complete
//
// A source is pending while its input is high and it hasn't been claimed,
// once claimed it is not pending again until the claim is completed.
module PLIC #(
    parameter int num_sources   = 3,
    parameter int num_contexts  = 2,
    parameter int priority_bits = 3
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic [num_sources:1]    sources,
    output logic [num_contexts-1:0] irq,
    // Register interface (AXILiteRegs)
    input  logic                    reg_wr,
    input  logic [            21:0] reg_waddr,
    // verilator lint_off UNUSEDSIGNAL
    input  logic [            31:0] reg_wdata,
    input  logic [             3:0] reg_wstrb,
    // verilator lint_on UNUSEDSIGNAL
    input  logic                    reg_rd,
    input  logic [            21:0] reg_raddr,
    output logic [            31:0] reg_rdata
);

    localparam int id_bits = 5;

    initial assert (num_sources >= 1 && num_sources <= 31);
    initial assert (num_contexts >= 1 && num_contexts <= 8);

    logic [priority_bits-1:0] prio          [num_sources+1];
    logic [  num_sources:1]   pending;
    logic [  num_sources:1]   in_flight;
    logic [  num_sources:1]   enable        [num_contexts];
    logic [priority_bits-1:0] threshold     [num_contexts];
    logic [      id_bits-1:0] best_id       [num_contexts];
    logic [priority_bits-1:0] best_prio     [num_contexts];
    logic [num_contexts-1:0]  claim;
    logic [num_contexts-1:0]  complete;
    logic [      id_bits-1:0] claimed_id;
    logic [  num_sources:1]   claim_mask;
    logic [  num_sources:1]   complete_mask;

    // Highest priority enabled pending source for each context, the lowest
    // ID wins a tie.
    always_comb begin
        for (int c = 0; c < num_contexts; ++c) begin
            best_id[c]   = '0;
            best_prio[c] = '0;
            for (int i = num_sources; i >= 1; --i) begin
                if (pending[i] && enable[c][i] && prio[i] != '0 && prio[i] >= best_prio[c]) begin
                    best_id[c]   = id_bits'(i);
                    best_prio[c] = prio[i];
                end
            end
            irq[c] = best_id[c] != '0 && best_prio[c] > threshold[c];
        end
    end

    function automatic logic is_ctx_reg(input logic [21:0] a, input int c, input logic [11:0] off);
        is_ctx_reg = a == 22'h200000 + 22'(c * 'h1000) + 22'(off);
    endfunction

    always_comb begin
        reg_rdata  = '0;
        claim      = '0;
        claimed_id = '0;

        if (reg_raddr < 22'h001000) begin
            for (int i = 1; i <= num_sources; ++i)
                if (reg_raddr[11:2] == 10'(i)) reg_rdata = 32'(prio[i]);
        end else if (reg_raddr == 22'h001000) begin
            reg_rdata = 32'({pending, 1'b0});
        end

        for (int c = 0; c < num_contexts; ++c) begin
            if (reg_raddr == 22'h002000 + 22'(c * 'h80)) reg_rdata = 32'({enable[c], 1'b0});
            if (is_ctx_reg(reg_raddr, c, 12'h000)) reg_rdata = 32'(threshold[c]);
            if (is_ctx_reg(reg_raddr, c, 12'h004)) begin
                reg_rdata = 32'(best_id[c]);
                if (reg_rd) begin
                    claim[c]   = 1'b1;
                    claimed_id = best_id[c];
                end
            end
        end

        complete = '0;
        for (int c = 0; c < num_contexts; ++c)
            if (reg_wr && is_ctx_reg(reg_waddr, c, 12'h004)) complete[c] = 1'b1;

        claim_mask    = '0;
        complete_mask = '0;
        for (int i = 1; i <= num_sources; ++i) begin
            if (|claim && claimed_id == id_bits'(i)) claim_mask[i] = 1'b1;
            // Completing an ID that isn't enabled for the context is
            // ignored.
            for (int c = 0; c < num_contexts; ++c)
                if (complete[c] && reg_wdata[id_bits-1:0] == id_bits'(i) && enable[c][i])
                    complete_mask[i] = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        in_flight <= (in_flight | claim_mask) & ~complete_mask;
        pending   <= sources & ~(in_flight | claim_mask);

        if (reg_wr) begin
            if (reg_waddr < 22'h001000) begin
                for (int i = 1; i <= num_sources; ++i)
                    if (reg_waddr[11:2] == 10'(i)) prio[i] <= reg_wdata[priority_bits-1:0];
            end
            for (int c = 0; c < num_contexts; ++c) begin
                if (reg_waddr == 22'h002000 + 22'(c * 'h80))
                    enable[c] <= reg_wdata[num_sources:1];
                if (is_ctx_reg(reg_waddr, c, 12'h000))
                    threshold[c] <= reg_wdata[priority_bits-1:0];
            end
        end

        if (reset) begin
            in_flight <= '0;
            pending   <= '0;
            for (int i = 0; i <= num_sources; ++i) prio[i] <= '0;
            for (int c = 0; c < num_contexts; ++c) begin
                enable[c]    <= '0;
                threshold[c] <= '0;
            end
        end
    end

endmodule
