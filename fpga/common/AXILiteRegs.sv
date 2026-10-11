// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`include "MervCommon.svh"

// AXI4-Lite subordinate for simple register blocks: a write is a single
// cycle reg_wr strobe and a read is a single cycle reg_rd strobe with the
// read data returned combinationally in that cycle, so reads with side
// effects (FIFO pops, claim) happen exactly once.
module AXILiteRegs #(
    parameter int addr_bits = 16
) (
    input  logic                 clk,
    input  logic                 reset,
    input  logic [addr_bits-1:0] s_axi_awaddr,
    input  logic                 s_axi_awvalid,
    output logic                 s_axi_awready,
    input  logic [         31:0] s_axi_wdata,
    input  logic [          3:0] s_axi_wstrb,
    input  logic                 s_axi_wvalid,
    output logic                 s_axi_wready,
    output logic                 s_axi_bvalid,
    input  logic                 s_axi_bready,
    input  logic [addr_bits-1:0] s_axi_araddr,
    input  logic                 s_axi_arvalid,
    output logic                 s_axi_arready,
    output logic [         31:0] s_axi_rdata,
    output logic                 s_axi_rvalid,
    input  logic                 s_axi_rready,
    // Register interface
    output logic                 reg_wr,
    output logic [addr_bits-1:0] reg_waddr,
    output logic [         31:0] reg_wdata,
    output logic [          3:0] reg_wstrb,
    output logic                 reg_rd,
    output logic [addr_bits-1:0] reg_raddr,
    input  logic [         31:0] reg_rdata
);

    always_comb begin
        s_axi_awready = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
        s_axi_wready  = s_axi_awready;
        s_axi_arready = s_axi_arvalid && (!s_axi_rvalid || s_axi_rready);

        reg_wr        = s_axi_awready;
        reg_waddr     = s_axi_awaddr;
        reg_wdata     = s_axi_wdata;
        reg_wstrb     = s_axi_wstrb;
        reg_rd        = s_axi_arready;
        reg_raddr     = s_axi_araddr;
    end

    always_ff @(posedge clk) begin
        if (reg_rd) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= reg_rdata;
        end else if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end

        if (reg_wr) s_axi_bvalid <= 1'b1;
        else if (s_axi_bready) s_axi_bvalid <= 1'b0;

        if (reset) begin
            s_axi_rvalid <= 1'b0;
            s_axi_bvalid <= 1'b0;
        end
    end

endmodule
