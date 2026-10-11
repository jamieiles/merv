// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Block design wrapper for the merv core.  The core has a single AXI4
// manager shared by instruction fetch and data with one single-beat
// transaction in flight.  DRAM accesses (0x80000000-0x8fffffff) are split
// off onto m_dram_axi, connected straight to the DDR3 bridge to avoid the
// interconnect's latency, everything else goes out on m_axi to the
// interconnect.
//
// With one transaction in flight a split only needs to steer the request
// channels by address and remember where the response comes from.  The core
// presents AW and W together and holds the address until the response, so
// W is steered with the AW address.
module MervCoreAXI #(
    parameter TLB_ENTRIES  = 4,
    parameter NATIVE_AMO   = 1,
    parameter HW_DIV       = 1,
    parameter BARREL_SHIFT = 0,
    parameter RESET_VECTOR = 32'h40000000,
    parameter FFW_INIT     = "ffw.mem"
) (
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF m_axi:m_dram_axi, ASSOCIATED_RESET reset" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 reset RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME reset, POLARITY ACTIVE_HIGH" *)
    input  wire        reset,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, SUPPORTS_NARROW_BURST 0" *)
    // verilog_format: on
    output wire [31:0] m_axi_awaddr,
    output wire [ 7:0] m_axi_awlen,
    output wire [ 2:0] m_axi_awsize,
    output wire [ 1:0] m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [ 3:0] m_axi_awcache,
    output wire [ 2:0] m_axi_awprot,
    output wire [ 3:0] m_axi_awqos,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [ 3:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [ 1:0] m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [31:0] m_axi_araddr,
    output wire [ 7:0] m_axi_arlen,
    output wire [ 2:0] m_axi_arsize,
    output wire [ 1:0] m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [ 3:0] m_axi_arcache,
    output wire [ 2:0] m_axi_arprot,
    output wire [ 3:0] m_axi_arqos,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [ 1:0] m_axi_rresp,
    // verilator lint_off UNUSEDSIGNAL
    input  wire        m_axi_rlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_dram_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, SUPPORTS_NARROW_BURST 0" *)
    // verilog_format: on
    output wire [31:0] m_dram_axi_awaddr,
    output wire [ 7:0] m_dram_axi_awlen,
    output wire [ 2:0] m_dram_axi_awsize,
    output wire [ 1:0] m_dram_axi_awburst,
    output wire        m_dram_axi_awvalid,
    input  wire        m_dram_axi_awready,
    output wire [31:0] m_dram_axi_wdata,
    output wire [ 3:0] m_dram_axi_wstrb,
    output wire        m_dram_axi_wlast,
    output wire        m_dram_axi_wvalid,
    input  wire        m_dram_axi_wready,
    input  wire [ 1:0] m_dram_axi_bresp,
    input  wire        m_dram_axi_bvalid,
    output wire        m_dram_axi_bready,
    output wire [31:0] m_dram_axi_araddr,
    output wire [ 7:0] m_dram_axi_arlen,
    output wire [ 2:0] m_dram_axi_arsize,
    output wire [ 1:0] m_dram_axi_arburst,
    output wire        m_dram_axi_arvalid,
    input  wire        m_dram_axi_arready,
    input  wire [31:0] m_dram_axi_rdata,
    input  wire [ 1:0] m_dram_axi_rresp,
    // verilator lint_off UNUSEDSIGNAL
    input  wire        m_dram_axi_rlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire        m_dram_axi_rvalid,
    output wire        m_dram_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 meip INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    input  wire        meip,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 seip INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    input  wire        seip,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 mtip INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    input  wire        mtip,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 msip INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    input  wire        msip,
    output wire        halted,
    // Debug: the instruction being executed and the privilege level
    // ({is_f, priv}), for a VIO/ILA.
    output wire [31:0] dbg_pc,
    output wire [31:0] dbg_insn,
    output wire [ 2:0] dbg_priv,
    output wire [ 5:0] dbg_trap_cause,
    output wire [31:0] dbg_trap_epc,
    output wire [31:0] dbg_trap_tval
);

    // Single beat, non-bufferable, non-modifiable accesses.
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0000;
    assign m_axi_awqos   = 4'b0000;
    assign m_axi_wlast   = 1'b1;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0000;
    assign m_axi_arqos   = 4'b0000;

    // The core's manager.
    wire [31:0] awaddr, wdata, araddr;
    wire [ 2:0] awsize, arsize;
    wire [ 3:0] wstrb;
    wire        awvalid, wvalid, bready, arvalid, rready;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [ 1:0] bresp, rresp;
    wire [31:0] rdata;

    wire aw_dram = awaddr[31:28] == 4'h8;
    wire ar_dram = araddr[31:28] == 4'h8;
    reg  b_dram, r_dram;

    always @(posedge clk) begin
        if (awvalid && awready) b_dram <= aw_dram;
        if (arvalid && arready) r_dram <= ar_dram;
    end

    assign m_axi_awaddr       = awaddr;
    assign m_axi_awsize       = awsize;
    assign m_axi_awvalid      = awvalid && !aw_dram;
    assign m_axi_wdata        = wdata;
    assign m_axi_wstrb        = wstrb;
    assign m_axi_wvalid       = wvalid && !aw_dram;
    assign m_axi_bready       = bready && !b_dram;
    assign m_axi_araddr       = araddr;
    assign m_axi_arsize       = arsize;
    assign m_axi_arvalid      = arvalid && !ar_dram;
    assign m_axi_rready       = rready && !r_dram;

    assign m_dram_axi_awaddr  = awaddr;
    assign m_dram_axi_awlen   = 8'd0;
    assign m_dram_axi_awsize  = awsize;
    assign m_dram_axi_awburst = 2'b01;
    assign m_dram_axi_awvalid = awvalid && aw_dram;
    assign m_dram_axi_wdata   = wdata;
    assign m_dram_axi_wstrb   = wstrb;
    assign m_dram_axi_wlast   = 1'b1;
    assign m_dram_axi_wvalid  = wvalid && aw_dram;
    assign m_dram_axi_bready  = bready && b_dram;
    assign m_dram_axi_araddr  = araddr;
    assign m_dram_axi_arlen   = 8'd0;
    assign m_dram_axi_arsize  = arsize;
    assign m_dram_axi_arburst = 2'b01;
    assign m_dram_axi_arvalid = arvalid && ar_dram;
    assign m_dram_axi_rready  = rready && r_dram;

    assign awready = aw_dram ? m_dram_axi_awready : m_axi_awready;
    assign wready  = aw_dram ? m_dram_axi_wready : m_axi_wready;
    assign bvalid  = b_dram ? m_dram_axi_bvalid : m_axi_bvalid;
    assign bresp   = b_dram ? m_dram_axi_bresp : m_axi_bresp;
    assign arready = ar_dram ? m_dram_axi_arready : m_axi_arready;
    assign rvalid  = r_dram ? m_dram_axi_rvalid : m_axi_rvalid;
    assign rdata   = r_dram ? m_dram_axi_rdata : m_axi_rdata;
    assign rresp   = r_dram ? m_dram_axi_rresp : m_axi_rresp;

    MervCore #(
        .TLB_ENTRIES(TLB_ENTRIES),
        .NATIVE_AMO (NATIVE_AMO),
        .HW_DIV     (HW_DIV),
        .BARREL_SHIFT(BARREL_SHIFT),
        .FFW_INIT   (FFW_INIT)
    ) core (
        .clk         (clk),
        .reset       (reset),
        .reset_vector(RESET_VECTOR),
        .axi_awaddr  (awaddr),
        .axi_awsize  (awsize),
        .axi_awprot  (m_axi_awprot),
        .axi_awvalid (awvalid),
        .axi_awready (awready),
        .axi_wdata   (wdata),
        .axi_wstrb   (wstrb),
        .axi_wvalid  (wvalid),
        .axi_wready  (wready),
        .axi_bresp   (bresp),
        .axi_bvalid  (bvalid),
        .axi_bready  (bready),
        .axi_araddr  (araddr),
        .axi_arsize  (arsize),
        .axi_arprot  (m_axi_arprot),
        .axi_arvalid (arvalid),
        .axi_arready (arready),
        .axi_rdata   (rdata),
        .axi_rresp   (rresp),
        .axi_rvalid  (rvalid),
        .axi_rready  (rready),
        .meip        (meip),
        .seip        (seip),
        .mtip        (mtip),
        .msip        (msip),
        .halted      (halted),
        .trace_retire(),
        .trace_trap  (),
        .trace_fevent(),
        .trace_pc    (dbg_pc),
        .trace_insn  (dbg_insn),
        .trace_priv  (dbg_priv),
        .trace_rd_we (),
        .trace_rd    (),
        .trace_rd_val(),
        .trace_cause (),
        .dbg_trap_cause(dbg_trap_cause),
        .dbg_trap_epc  (dbg_trap_epc),
        .dbg_trap_tval (dbg_trap_tval)
    );

endmodule
