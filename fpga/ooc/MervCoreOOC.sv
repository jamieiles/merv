// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Out-of-context synthesis wrapper: the core with its AXI and interrupt
// ports, the reset vector tied off and the simulation trace outputs left
// unconnected so that they are optimized away.
module MervCoreOOC #(
    parameter int TLB_ENTRIES = 4,
    parameter int NATIVE_AMO  = 1,
    parameter int HW_DIV      = 1,
    parameter int BARREL_SHIFT = 0,
    parameter int AXI_EXCLUSIVE = 0
) (
    input  logic        clk,
    input  logic        reset,
    output logic [31:0] axi_awaddr,
    output logic [ 2:0] axi_awsize,
    output logic [ 2:0] axi_awprot,
    output logic        axi_awlock,
    output logic        axi_awvalid,
    input  logic        axi_awready,
    output logic [31:0] axi_wdata,
    output logic [ 3:0] axi_wstrb,
    output logic        axi_wvalid,
    input  logic        axi_wready,
    input  logic [ 1:0] axi_bresp,
    input  logic        axi_bvalid,
    output logic        axi_bready,
    output logic [31:0] axi_araddr,
    output logic [ 2:0] axi_arsize,
    output logic [ 2:0] axi_arprot,
    output logic        axi_arlock,
    output logic        axi_arvalid,
    input  logic        axi_arready,
    input  logic [31:0] axi_rdata,
    input  logic [ 1:0] axi_rresp,
    input  logic        axi_rvalid,
    output logic        axi_rready,
    input  logic        meip,
    input  logic        seip,
    input  logic        mtip,
    input  logic        msip
);

    MervCore #(
        .TLB_ENTRIES(TLB_ENTRIES),
        .NATIVE_AMO (NATIVE_AMO),
        .HW_DIV     (HW_DIV),
        .BARREL_SHIFT(BARREL_SHIFT),
        .AXI_EXCLUSIVE(AXI_EXCLUSIVE)
    ) core (
        .clk         (clk),
        .reset       (reset),
        .reset_vector(32'h40000000),
        .axi_awaddr  (axi_awaddr),
        .axi_awsize  (axi_awsize),
        .axi_awprot  (axi_awprot),
        .axi_awlock  (axi_awlock),
        .axi_awvalid (axi_awvalid),
        .axi_awready (axi_awready),
        .axi_wdata   (axi_wdata),
        .axi_wstrb   (axi_wstrb),
        .axi_wvalid  (axi_wvalid),
        .axi_wready  (axi_wready),
        .axi_bresp   (axi_bresp),
        .axi_bvalid  (axi_bvalid),
        .axi_bready  (axi_bready),
        .axi_araddr  (axi_araddr),
        .axi_arsize  (axi_arsize),
        .axi_arprot  (axi_arprot),
        .axi_arlock  (axi_arlock),
        .axi_arvalid (axi_arvalid),
        .axi_arready (axi_arready),
        .axi_rdata   (axi_rdata),
        .axi_rresp   (axi_rresp),
        .axi_rvalid  (axi_rvalid),
        .axi_rready  (axi_rready),
        .meip        (meip),
        .seip        (seip),
        .mtip        (mtip),
        .msip        (msip),
        .halted      (),
        .trace_retire(),
        .trace_trap  (),
        .trace_fevent(),
        .trace_pc    (),
        .trace_insn  (),
        .trace_priv  (),
        .trace_rd_we (),
        .trace_rd    (),
        .trace_rd_val(),
        .trace_cause (),
        .dbg_trap_cause(),
        .dbg_trap_epc  (),
        .dbg_trap_tval ()
    );

endmodule
