// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Fully associative unified TLB, filled by the F mode firmware.  Lookups are
// pipelined over two cycles for Fmax:
//
//   lookup:  compare the VPN against all entries, register the hit vector
//   check:   select the hit entry and check the permissions, registered as
//            miss/fault, the physical address is valid (combinationally)
//            during this cycle for the core to register
//
// The firmware only fills on a miss so an address hits at most one entry
// unless the page tables were changed without the sfence.vma that the
// privileged spec requires, allowing an AND-OR select.
module MervTLB #(
    parameter int ENTRIES = 4
) (
    input  logic        clk,
    input  logic        reset,
    // Lookup, va must be stable for both cycles.
    input  logic        lookup,
    input  logic        check,
    input  logic [31:0] va,
    input  logic        is_fetch,
    input  logic        is_store,
    input  logic        eff_user,  // effective privilege is U
    input  logic        sum,
    input  logic        mxr,
    output logic [31:0] pa,
    output logic        miss,
    output logic        fault,
    // Maintenance from the F mode CSRs and sfence.vma: flush invalidates
    // every entry, flush_va the entries that translate va.
    input  logic        flush,
    input  logic        flush_va,
    input  logic        write,
    input  logic [ 3:0] write_idx,
    input  logic [21:0] write_hi,  // {VPN[19:0], SUPER, V}
    input  logic [23:0] write_lo   // {PPN[19:0], U, X, W, R}
);

    logic [ENTRIES-1:0] valid, is_super;
    logic [19:0] vpn[ENTRIES];
    logic [19:0] ppn[ENTRIES];
    logic [3:0] perm[ENTRIES];  // U X W R

    logic [ENTRIES-1:0] match, hit;

    always_comb begin
        for (int i = 0; i < ENTRIES; ++i)
            match[i] = vpn[i][19:10] == va[31:22] &&
                       (is_super[i] || vpn[i][9:0] == va[21:12]);
    end

    always_ff @(posedge clk) begin
        for (int i = 0; i < ENTRIES; ++i) begin
            if (write && write_idx == i[3:0]) begin
                valid[i] <= write_hi[0];
                is_super[i] <= write_hi[1];
                vpn[i]   <= write_hi[21:2];
                ppn[i]   <= write_lo[23:4];
                perm[i]  <= write_lo[3:0];
            end
        end
        if (flush_va) valid <= valid & ~match;
        if (flush || reset) valid <= '0;
    end

    always_ff @(posedge clk) begin
        if (lookup) begin
            hit <= valid & match;
        end
    end

    logic [19:0] sel_ppn;
    logic [ 3:0] sel_perm;
    logic        sel_super;

    always_comb begin
        sel_ppn   = '0;
        sel_perm  = '0;
        sel_super = 1'b0;
        for (int i = 0; i < ENTRIES; ++i) begin
            sel_ppn   = sel_ppn | (ppn[i] & {20{hit[i]}});
            sel_perm  = sel_perm | (perm[i] & {4{hit[i]}});
            sel_super = sel_super | (is_super[i] & hit[i]);
        end
    end

    logic allowed;

    always_comb begin
        if (is_fetch) allowed = sel_perm[2];
        else if (is_store) allowed = sel_perm[1];
        else allowed = sel_perm[0] | (mxr & sel_perm[2]);

        if (eff_user) allowed = allowed & sel_perm[3];
        else if (sel_perm[3]) allowed = allowed & ~is_fetch & sum;
    end

    always_ff @(posedge clk) begin
        if (check) begin
            miss  <= ~|hit;
            fault <= ~allowed;
        end
    end

    assign pa = {sel_ppn[19:10], sel_super ? va[21:12] : sel_ppn[9:0],
                 va[11:0]};

endmodule
