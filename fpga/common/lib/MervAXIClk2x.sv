// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Crossing for the core's AXI4 manager (single beat, one transaction in
// flight) from fast_clk to clk, where fast_clk is exactly twice clk and
// phase aligned with it (from the same MMCM, or derived from clk with a
// compensated MMCM), so the paths between the domains are synchronous and
// timed as one fast_clk period without multicycle constraints.
//
// The fabric side only ever sees registers in the clk domain, stable for a
// whole clk cycle, and the core only ever sees registers:
//
// - Requests (AR, AW, W): the core's handshake is only allowed in the
//   fast_clk cycle that ends on a clk edge (ph), where the clk domain
//   captures the request into a register that drives the fabric until it
//   has been accepted.
// - Responses (R, B): captured in a clk domain register.  The core may take
//   it on any fast_clk edge, `taken` hides it from the core until the clk
//   domain has seen the handshake and emptied the register.
module MervAXIClk2x (
    input  logic        fast_clk,
    input  logic        clk,
    input  logic        reset,
    // Core side, fast_clk.
    input  logic [31:0] c_awaddr,
    input  logic [ 2:0] c_awsize,
    input  logic [ 2:0] c_awprot,
    input  logic        c_awlock,
    input  logic        c_awvalid,
    output logic        c_awready,
    input  logic [31:0] c_wdata,
    input  logic [ 3:0] c_wstrb,
    input  logic        c_wvalid,
    output logic        c_wready,
    output logic [ 1:0] c_bresp,
    output logic        c_bvalid,
    input  logic        c_bready,
    input  logic [31:0] c_araddr,
    input  logic [ 2:0] c_arsize,
    input  logic [ 2:0] c_arprot,
    input  logic        c_arlock,
    input  logic        c_arvalid,
    output logic        c_arready,
    output logic [31:0] c_rdata,
    output logic [ 1:0] c_rresp,
    output logic        c_rvalid,
    input  logic        c_rready,
    // Fabric side, clk.
    output logic [31:0] m_awaddr,
    output logic [ 2:0] m_awsize,
    output logic [ 2:0] m_awprot,
    output logic        m_awlock,
    output logic        m_awvalid,
    input  logic        m_awready,
    output logic [31:0] m_wdata,
    output logic [ 3:0] m_wstrb,
    output logic        m_wvalid,
    input  logic        m_wready,
    input  logic [ 1:0] m_bresp,
    input  logic        m_bvalid,
    output logic        m_bready,
    output logic [31:0] m_araddr,
    output logic [ 2:0] m_arsize,
    output logic [ 2:0] m_arprot,
    output logic        m_arlock,
    output logic        m_arvalid,
    input  logic        m_arready,
    input  logic [31:0] m_rdata,
    input  logic [ 1:0] m_rresp,
    input  logic        m_rvalid,
    output logic        m_rready
);

    // ph: the fast_clk cycle ending on a clk edge.  tog changes after every
    // clk edge, tog_q samples it on every fast_clk edge so they're equal in
    // the second half of each clk cycle.
    logic tog = 1'b0, tog_q = 1'b0;

    always_ff @(posedge clk) tog <= ~tog;
    always_ff @(posedge fast_clk) tog_q <= tog;

    wire ph = tog == tog_q;

    // Requests, captured on the clk edge that the core's handshake ends on.
    assign c_arready = !m_arvalid && ph;
    assign c_awready = !m_awvalid && ph;
    assign c_wready  = !m_wvalid && ph;

    always_ff @(posedge clk) begin
        if (!m_arvalid && c_arvalid) begin
            m_arvalid <= 1'b1;
            m_araddr  <= c_araddr;
            m_arsize  <= c_arsize;
            m_arprot  <= c_arprot;
            m_arlock  <= c_arlock;
        end else if (m_arready) begin
            m_arvalid <= 1'b0;
        end
        if (!m_awvalid && c_awvalid) begin
            m_awvalid <= 1'b1;
            m_awaddr  <= c_awaddr;
            m_awsize  <= c_awsize;
            m_awprot  <= c_awprot;
            m_awlock  <= c_awlock;
        end else if (m_awready) begin
            m_awvalid <= 1'b0;
        end
        if (!m_wvalid && c_wvalid) begin
            m_wvalid <= 1'b1;
            m_wdata  <= c_wdata;
            m_wstrb  <= c_wstrb;
        end else if (m_wready) begin
            m_wvalid <= 1'b0;
        end
        if (reset) begin
            m_arvalid <= 1'b0;
            m_awvalid <= 1'b0;
            m_wvalid  <= 1'b0;
        end
    end

    // Responses.
    logic r_valid, r_taken, b_valid, b_taken;

    assign m_rready = !r_valid;
    assign m_bready = !b_valid;
    assign c_rvalid = r_valid && !r_taken;
    assign c_bvalid = b_valid && !b_taken;

    always_ff @(posedge clk) begin
        if (!r_valid && m_rvalid) begin
            r_valid <= 1'b1;
            c_rdata <= m_rdata;
            c_rresp <= m_rresp;
        end else if (r_valid && (r_taken || c_rready)) begin
            // Taken earlier, or being taken at this edge.
            r_valid <= 1'b0;
        end
        if (!b_valid && m_bvalid) begin
            b_valid <= 1'b1;
            c_bresp <= m_bresp;
        end else if (b_valid && (b_taken || c_bready)) begin
            b_valid <= 1'b0;
        end
        if (reset) begin
            r_valid <= 1'b0;
            b_valid <= 1'b0;
        end
    end

    always_ff @(posedge fast_clk) begin
        if (c_rvalid && c_rready) r_taken <= 1'b1;
        else if (!r_valid) r_taken <= 1'b0;
        if (c_bvalid && c_bready) b_taken <= 1'b1;
        else if (!b_valid) b_taken <= 1'b0;
        if (reset) begin
            r_taken <= 1'b0;
            b_taken <= 1'b0;
        end
    end

endmodule
