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
//
// With CLK2X the core runs on core_clk, twice and phase aligned with clk,
// through MervAXIClk2x, otherwise core_clk is unused and the core runs on
// clk.  The interrupts and the reset come from clk registers.
//
// With AXI_EXCLUSIVE (SMP) LR/SC and AMOs use exclusive accesses, only DRAM
// (the bridge) has an exclusive monitor.  Exclusive writes elsewhere are
// given EXOKAY so that atomics to MMIO behave as they would with a single
// hart.
module MervCoreAXI #(
    parameter TLB_ENTRIES  = 4,
    parameter NATIVE_AMO   = 1,
    parameter HW_DIV       = 1,
    parameter BARREL_SHIFT = 0,
    parameter HART_ID      = 0,
    parameter AXI_EXCLUSIVE = 0,
    parameter CLK2X        = 0,
    parameter RESET_VECTOR = 32'h40000000,
    parameter FFW_INIT     = "ffw.mem"
) (
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF m_axi:m_dram_axi, ASSOCIATED_RESET reset" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 core_clk CLK" *)
    // verilator lint_off UNUSEDSIGNAL
    input  wire        core_clk,
    // verilator lint_on UNUSEDSIGNAL
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
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_dram_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, SUPPORTS_NARROW_BURST 0, HAS_LOCK 1" *)
    // verilog_format: on
    output wire [31:0] m_dram_axi_awaddr,
    output wire [ 7:0] m_dram_axi_awlen,
    output wire [ 2:0] m_dram_axi_awsize,
    output wire [ 1:0] m_dram_axi_awburst,
    output wire        m_dram_axi_awlock,
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
    output wire        m_dram_axi_arlock,
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

    // The core's manager (c_*) and in the clk domain.
    wire [31:0] c_awaddr, c_wdata, c_araddr;
    wire [ 2:0] c_awsize, c_arsize, c_awprot, c_arprot;
    wire [ 3:0] c_wstrb;
    wire        c_awvalid, c_wvalid, c_bready, c_arvalid, c_rready, c_awlock, c_arlock;
    wire        c_awready, c_wready, c_bvalid, c_arready, c_rvalid;
    wire [ 1:0] c_bresp, c_rresp;
    wire [31:0] c_rdata;
    wire [31:0] awaddr, wdata, araddr;
    wire [ 2:0] awsize, arsize;
    wire [ 3:0] wstrb;
    wire        awvalid, wvalid, bready, arvalid, rready, awlock, arlock;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [ 1:0] bresp, rresp;
    wire [31:0] rdata;
    wire        core_clock;

    generate
        if (CLK2X != 0) begin : gen_clk2x
            assign core_clock = core_clk;

            MervAXIClk2x xclk (
                .fast_clk (core_clk),
                .clk      (clk),
                .reset    (reset),
                .c_awaddr (c_awaddr),
                .c_awsize (c_awsize),
                .c_awprot (c_awprot),
                .c_awlock (c_awlock),
                .c_awvalid(c_awvalid),
                .c_awready(c_awready),
                .c_wdata  (c_wdata),
                .c_wstrb  (c_wstrb),
                .c_wvalid (c_wvalid),
                .c_wready (c_wready),
                .c_bresp  (c_bresp),
                .c_bvalid (c_bvalid),
                .c_bready (c_bready),
                .c_araddr (c_araddr),
                .c_arsize (c_arsize),
                .c_arprot (c_arprot),
                .c_arlock (c_arlock),
                .c_arvalid(c_arvalid),
                .c_arready(c_arready),
                .c_rdata  (c_rdata),
                .c_rresp  (c_rresp),
                .c_rvalid (c_rvalid),
                .c_rready (c_rready),
                .m_awaddr (awaddr),
                .m_awsize (awsize),
                .m_awprot (m_axi_awprot),
                .m_awlock (awlock),
                .m_awvalid(awvalid),
                .m_awready(awready),
                .m_wdata  (wdata),
                .m_wstrb  (wstrb),
                .m_wvalid (wvalid),
                .m_wready (wready),
                .m_bresp  (bresp),
                .m_bvalid (bvalid),
                .m_bready (bready),
                .m_araddr (araddr),
                .m_arsize (arsize),
                .m_arprot (m_axi_arprot),
                .m_arlock (arlock),
                .m_arvalid(arvalid),
                .m_arready(arready),
                .m_rdata  (rdata),
                .m_rresp  (rresp),
                .m_rvalid (rvalid),
                .m_rready (rready)
            );
        end else begin : gen_clk1x
            assign core_clock   = clk;
            assign awaddr       = c_awaddr;
            assign awsize       = c_awsize;
            assign m_axi_awprot = c_awprot;
            assign awlock       = c_awlock;
            assign awvalid      = c_awvalid;
            assign c_awready    = awready;
            assign wdata        = c_wdata;
            assign wstrb        = c_wstrb;
            assign wvalid       = c_wvalid;
            assign c_wready     = wready;
            assign c_bresp      = bresp;
            assign c_bvalid     = bvalid;
            assign bready       = c_bready;
            assign araddr       = c_araddr;
            assign arsize       = c_arsize;
            assign m_axi_arprot = c_arprot;
            assign arlock       = c_arlock;
            assign arvalid      = c_arvalid;
            assign c_arready    = arready;
            assign c_rdata      = rdata;
            assign c_rresp      = rresp;
            assign c_rvalid     = rvalid;
            assign rready       = c_rready;
        end
    endgenerate

    wire aw_dram = awaddr[31:28] == 4'h8;
    wire ar_dram = araddr[31:28] == 4'h8;
    reg  b_dram, r_dram, b_lock;

    always @(posedge clk) begin
        if (awvalid && awready) begin
            b_dram <= aw_dram;
            b_lock <= awlock;
        end
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
    assign m_dram_axi_awlock  = awlock;
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
    assign m_dram_axi_arlock  = arlock;
    assign m_dram_axi_arvalid = arvalid && ar_dram;
    assign m_dram_axi_rready  = rready && r_dram;

    assign awready = aw_dram ? m_dram_axi_awready : m_axi_awready;
    assign wready  = aw_dram ? m_dram_axi_wready : m_axi_wready;
    assign bvalid  = b_dram ? m_dram_axi_bvalid : m_axi_bvalid;
    assign bresp   = b_dram ? m_dram_axi_bresp :
                     {m_axi_bresp[1], m_axi_bresp[1] ? m_axi_bresp[0] : b_lock};
    assign arready = ar_dram ? m_dram_axi_arready : m_axi_arready;
    assign rvalid  = r_dram ? m_dram_axi_rvalid : m_axi_rvalid;
    assign rdata   = r_dram ? m_dram_axi_rdata : m_axi_rdata;
    assign rresp   = r_dram ? m_dram_axi_rresp : m_axi_rresp;

    MervCore #(
        .TLB_ENTRIES(TLB_ENTRIES),
        .NATIVE_AMO (NATIVE_AMO),
        .HW_DIV     (HW_DIV),
        .BARREL_SHIFT(BARREL_SHIFT),
        .HART_ID    (HART_ID),
        .AXI_EXCLUSIVE(AXI_EXCLUSIVE),
        .FFW_INIT   (FFW_INIT)
    ) core (
        .clk         (core_clock),
        .reset       (reset),
        .reset_vector(RESET_VECTOR),
        .axi_awaddr  (c_awaddr),
        .axi_awsize  (c_awsize),
        .axi_awprot  (c_awprot),
        .axi_awlock  (c_awlock),
        .axi_awvalid (c_awvalid),
        .axi_awready (c_awready),
        .axi_wdata   (c_wdata),
        .axi_wstrb   (c_wstrb),
        .axi_wvalid  (c_wvalid),
        .axi_wready  (c_wready),
        .axi_bresp   (c_bresp),
        .axi_bvalid  (c_bvalid),
        .axi_bready  (c_bready),
        .axi_araddr  (c_araddr),
        .axi_arsize  (c_arsize),
        .axi_arprot  (c_arprot),
        .axi_arlock  (c_arlock),
        .axi_arvalid (c_arvalid),
        .axi_arready (c_arready),
        .axi_rdata   (c_rdata),
        .axi_rresp   (c_rresp),
        .axi_rvalid  (c_rvalid),
        .axi_rready  (c_rready),
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
