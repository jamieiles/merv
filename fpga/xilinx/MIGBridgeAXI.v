// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Block design wrapper for the DRAM bridge: s_axi, s_axi1-3 directly from the
// cores of NUM_HARTS (1-4) harts and s_dma_axi directly from the SD host
// controller's DMA, all into the MIG native interface.  The ports of harts
// beyond NUM_HARTS are unused.  A single hart has no exclusive monitor, its
// core must be built without AXI_EXCLUSIVE.
module MIGBridgeAXI #(
    parameter NUM_HARTS = 1
) (
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s_axi:s_axi1:s_axi2:s_axi3:s_dma_axi, ASSOCIATED_RESET reset" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 reset RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME reset, POLARITY ACTIVE_HIGH" *)
    input  wire         reset,
    // verilog_format: on
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 1, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_axi_awaddr,
    input  wire [  7:0] s_axi_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi_awsize,
    input  wire [  1:0] s_axi_awburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi_awlock,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [ 31:0] s_axi_wdata,
    input  wire [  3:0] s_axi_wstrb,
    // verilator lint_off UNUSEDSIGNAL
    input  wire         s_axi_wlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [  1:0] s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [ 31:0] s_axi_araddr,
    input  wire [  7:0] s_axi_arlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi_arsize,
    input  wire [  1:0] s_axi_arburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi_arlock,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [ 31:0] s_axi_rdata,
    output wire [  1:0] s_axi_rresp,
    output wire         s_axi_rlast,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi1, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 1, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_axi1_awaddr,
    input  wire [  7:0] s_axi1_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi1_awsize,
    input  wire [  1:0] s_axi1_awburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi1_awlock,
    input  wire         s_axi1_awvalid,
    output wire         s_axi1_awready,
    input  wire [ 31:0] s_axi1_wdata,
    input  wire [  3:0] s_axi1_wstrb,
    // verilator lint_off UNUSEDSIGNAL
    input  wire         s_axi1_wlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi1_wvalid,
    output wire         s_axi1_wready,
    output wire [  1:0] s_axi1_bresp,
    output wire         s_axi1_bvalid,
    input  wire         s_axi1_bready,
    input  wire [ 31:0] s_axi1_araddr,
    input  wire [  7:0] s_axi1_arlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi1_arsize,
    input  wire [  1:0] s_axi1_arburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi1_arlock,
    input  wire         s_axi1_arvalid,
    output wire         s_axi1_arready,
    output wire [ 31:0] s_axi1_rdata,
    output wire [  1:0] s_axi1_rresp,
    output wire         s_axi1_rlast,
    output wire         s_axi1_rvalid,
    input  wire         s_axi1_rready,
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi2, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 1, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_axi2_awaddr,
    input  wire [  7:0] s_axi2_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi2_awsize,
    input  wire [  1:0] s_axi2_awburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi2_awlock,
    input  wire         s_axi2_awvalid,
    output wire         s_axi2_awready,
    input  wire [ 31:0] s_axi2_wdata,
    input  wire [  3:0] s_axi2_wstrb,
    // verilator lint_off UNUSEDSIGNAL
    input  wire         s_axi2_wlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi2_wvalid,
    output wire         s_axi2_wready,
    output wire [  1:0] s_axi2_bresp,
    output wire         s_axi2_bvalid,
    input  wire         s_axi2_bready,
    input  wire [ 31:0] s_axi2_araddr,
    input  wire [  7:0] s_axi2_arlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi2_arsize,
    input  wire [  1:0] s_axi2_arburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi2_arlock,
    input  wire         s_axi2_arvalid,
    output wire         s_axi2_arready,
    output wire [ 31:0] s_axi2_rdata,
    output wire [  1:0] s_axi2_rresp,
    output wire         s_axi2_rlast,
    output wire         s_axi2_rvalid,
    input  wire         s_axi2_rready,
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi3, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 1, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_axi3_awaddr,
    input  wire [  7:0] s_axi3_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi3_awsize,
    input  wire [  1:0] s_axi3_awburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi3_awlock,
    input  wire         s_axi3_awvalid,
    output wire         s_axi3_awready,
    input  wire [ 31:0] s_axi3_wdata,
    input  wire [  3:0] s_axi3_wstrb,
    // verilator lint_off UNUSEDSIGNAL
    input  wire         s_axi3_wlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi3_wvalid,
    output wire         s_axi3_wready,
    output wire [  1:0] s_axi3_bresp,
    output wire         s_axi3_bvalid,
    input  wire         s_axi3_bready,
    input  wire [ 31:0] s_axi3_araddr,
    input  wire [  7:0] s_axi3_arlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi3_arsize,
    input  wire [  1:0] s_axi3_arburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_axi3_arlock,
    input  wire         s_axi3_arvalid,
    output wire         s_axi3_arready,
    output wire [ 31:0] s_axi3_rdata,
    output wire [  1:0] s_axi3_rresp,
    output wire         s_axi3_rlast,
    output wire         s_axi3_rvalid,
    input  wire         s_axi3_rready,
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_dma_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, MAX_BURST_LENGTH 16, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 1, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_dma_axi_awaddr,
    input  wire [  7:0] s_dma_axi_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_dma_axi_awsize,
    input  wire [  1:0] s_dma_axi_awburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_dma_axi_awlock,
    input  wire         s_dma_axi_awvalid,
    output wire         s_dma_axi_awready,
    input  wire [ 31:0] s_dma_axi_wdata,
    input  wire [  3:0] s_dma_axi_wstrb,
    // verilator lint_off UNUSEDSIGNAL
    input  wire         s_dma_axi_wlast,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_dma_axi_wvalid,
    output wire         s_dma_axi_wready,
    output wire [  1:0] s_dma_axi_bresp,
    output wire         s_dma_axi_bvalid,
    input  wire         s_dma_axi_bready,
    input  wire [ 31:0] s_dma_axi_araddr,
    input  wire [  7:0] s_dma_axi_arlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_dma_axi_arsize,
    input  wire [  1:0] s_dma_axi_arburst,
    // verilator lint_on UNUSEDSIGNAL
    input  wire         s_dma_axi_arlock,
    input  wire         s_dma_axi_arvalid,
    output wire         s_dma_axi_arready,
    output wire [ 31:0] s_dma_axi_rdata,
    output wire [  1:0] s_dma_axi_rresp,
    output wire         s_dma_axi_rlast,
    output wire         s_dma_axi_rvalid,
    input  wire         s_dma_axi_rready,
    // DDR3 controller, MIG native interface
    input  wire         ddr_calib_complete,
    output wire [ 27:0] ddr_app_addr,
    output wire [  2:0] ddr_app_cmd,
    output wire         ddr_app_en,
    input  wire         ddr_app_rdy,
    output wire [127:0] ddr_app_wdf_data,
    output wire [ 15:0] ddr_app_wdf_mask,
    output wire         ddr_app_wdf_wren,
    output wire         ddr_app_wdf_end,
    input  wire         ddr_app_wdf_rdy,
    input  wire [127:0] ddr_app_rd_data,
    input  wire         ddr_app_rd_data_valid,
    input  wire         ddr_app_rd_data_end
);

    localparam NPORTS = NUM_HARTS + 1;

    // All five ports, 0-3 the harts and 4 DMA, and the bridge's ports, the
    // harts then DMA.
    // verilator lint_off UNUSEDSIGNAL
    wire [159:0] all_awaddr;
    wire [39:0] all_awlen;
    wire [4:0] all_awlock;
    wire [4:0] all_awvalid;
    wire [159:0] all_wdata;
    wire [19:0] all_wstrb;
    wire [4:0] all_wvalid;
    wire [4:0] all_bready;
    wire [159:0] all_araddr;
    wire [39:0] all_arlen;
    wire [4:0] all_arlock;
    wire [4:0] all_arvalid;
    wire [4:0] all_rready;
    wire [4:0] all_awready;
    wire [4:0] all_wready;
    wire [9:0] all_bresp;
    wire [4:0] all_bvalid;
    wire [4:0] all_arready;
    wire [159:0] all_rdata;
    wire [9:0] all_rresp;
    wire [4:0] all_rlast;
    wire [4:0] all_rvalid;
    wire [NPORTS*32-1:0] br_awaddr;
    wire [NPORTS*8-1:0] br_awlen;
    wire [NPORTS-1:0] br_awlock;
    wire [NPORTS-1:0] br_awvalid;
    wire [NPORTS*32-1:0] br_wdata;
    wire [NPORTS*4-1:0] br_wstrb;
    wire [NPORTS-1:0] br_wvalid;
    wire [NPORTS-1:0] br_bready;
    wire [NPORTS*32-1:0] br_araddr;
    wire [NPORTS*8-1:0] br_arlen;
    wire [NPORTS-1:0] br_arlock;
    wire [NPORTS-1:0] br_arvalid;
    wire [NPORTS-1:0] br_rready;
    wire [NPORTS-1:0] br_awready;
    wire [NPORTS-1:0] br_wready;
    wire [NPORTS*2-1:0] br_bresp;
    wire [NPORTS-1:0] br_bvalid;
    wire [NPORTS-1:0] br_arready;
    wire [NPORTS*32-1:0] br_rdata;
    wire [NPORTS*2-1:0] br_rresp;
    wire [NPORTS-1:0] br_rlast;
    wire [NPORTS-1:0] br_rvalid;
    // verilator lint_on UNUSEDSIGNAL

    assign all_awaddr = {s_dma_axi_awaddr, s_axi3_awaddr, s_axi2_awaddr, s_axi1_awaddr, s_axi_awaddr};
    assign all_awlen = {s_dma_axi_awlen, s_axi3_awlen, s_axi2_awlen, s_axi1_awlen, s_axi_awlen};
    assign all_awlock = {s_dma_axi_awlock, s_axi3_awlock, s_axi2_awlock, s_axi1_awlock, s_axi_awlock};
    assign all_awvalid = {s_dma_axi_awvalid, s_axi3_awvalid, s_axi2_awvalid, s_axi1_awvalid, s_axi_awvalid};
    assign all_wdata = {s_dma_axi_wdata, s_axi3_wdata, s_axi2_wdata, s_axi1_wdata, s_axi_wdata};
    assign all_wstrb = {s_dma_axi_wstrb, s_axi3_wstrb, s_axi2_wstrb, s_axi1_wstrb, s_axi_wstrb};
    assign all_wvalid = {s_dma_axi_wvalid, s_axi3_wvalid, s_axi2_wvalid, s_axi1_wvalid, s_axi_wvalid};
    assign all_bready = {s_dma_axi_bready, s_axi3_bready, s_axi2_bready, s_axi1_bready, s_axi_bready};
    assign all_araddr = {s_dma_axi_araddr, s_axi3_araddr, s_axi2_araddr, s_axi1_araddr, s_axi_araddr};
    assign all_arlen = {s_dma_axi_arlen, s_axi3_arlen, s_axi2_arlen, s_axi1_arlen, s_axi_arlen};
    assign all_arlock = {s_dma_axi_arlock, s_axi3_arlock, s_axi2_arlock, s_axi1_arlock, s_axi_arlock};
    assign all_arvalid = {s_dma_axi_arvalid, s_axi3_arvalid, s_axi2_arvalid, s_axi1_arvalid, s_axi_arvalid};
    assign all_rready = {s_dma_axi_rready, s_axi3_rready, s_axi2_rready, s_axi1_rready, s_axi_rready};

    assign s_axi_awready = all_awready[0];
    assign s_axi1_awready = all_awready[1];
    assign s_axi2_awready = all_awready[2];
    assign s_axi3_awready = all_awready[3];
    assign s_dma_axi_awready = all_awready[4];
    assign s_axi_wready = all_wready[0];
    assign s_axi1_wready = all_wready[1];
    assign s_axi2_wready = all_wready[2];
    assign s_axi3_wready = all_wready[3];
    assign s_dma_axi_wready = all_wready[4];
    assign s_axi_bresp = all_bresp[(0)*2 +: 2];
    assign s_axi1_bresp = all_bresp[(1)*2 +: 2];
    assign s_axi2_bresp = all_bresp[(2)*2 +: 2];
    assign s_axi3_bresp = all_bresp[(3)*2 +: 2];
    assign s_dma_axi_bresp = all_bresp[(4)*2 +: 2];
    assign s_axi_bvalid = all_bvalid[0];
    assign s_axi1_bvalid = all_bvalid[1];
    assign s_axi2_bvalid = all_bvalid[2];
    assign s_axi3_bvalid = all_bvalid[3];
    assign s_dma_axi_bvalid = all_bvalid[4];
    assign s_axi_arready = all_arready[0];
    assign s_axi1_arready = all_arready[1];
    assign s_axi2_arready = all_arready[2];
    assign s_axi3_arready = all_arready[3];
    assign s_dma_axi_arready = all_arready[4];
    assign s_axi_rdata = all_rdata[(0)*32 +: 32];
    assign s_axi1_rdata = all_rdata[(1)*32 +: 32];
    assign s_axi2_rdata = all_rdata[(2)*32 +: 32];
    assign s_axi3_rdata = all_rdata[(3)*32 +: 32];
    assign s_dma_axi_rdata = all_rdata[(4)*32 +: 32];
    assign s_axi_rresp = all_rresp[(0)*2 +: 2];
    assign s_axi1_rresp = all_rresp[(1)*2 +: 2];
    assign s_axi2_rresp = all_rresp[(2)*2 +: 2];
    assign s_axi3_rresp = all_rresp[(3)*2 +: 2];
    assign s_dma_axi_rresp = all_rresp[(4)*2 +: 2];
    assign s_axi_rlast = all_rlast[0];
    assign s_axi1_rlast = all_rlast[1];
    assign s_axi2_rlast = all_rlast[2];
    assign s_axi3_rlast = all_rlast[3];
    assign s_dma_axi_rlast = all_rlast[4];
    assign s_axi_rvalid = all_rvalid[0];
    assign s_axi1_rvalid = all_rvalid[1];
    assign s_axi2_rvalid = all_rvalid[2];
    assign s_axi3_rvalid = all_rvalid[3];
    assign s_dma_axi_rvalid = all_rvalid[4];

    genvar p, i;
    generate
        for (p = 0; p < NPORTS; p = p + 1) begin : gen_in
            assign br_awaddr[(p)*32 +: 32] = all_awaddr[(p == NUM_HARTS ? 4 : p)*32 +: 32];
            assign br_awlen[(p)*8 +: 8] = all_awlen[(p == NUM_HARTS ? 4 : p)*8 +: 8];
            assign br_awlock[p] = all_awlock[p == NUM_HARTS ? 4 : p];
            assign br_awvalid[p] = all_awvalid[p == NUM_HARTS ? 4 : p];
            assign br_wdata[(p)*32 +: 32] = all_wdata[(p == NUM_HARTS ? 4 : p)*32 +: 32];
            assign br_wstrb[(p)*4 +: 4] = all_wstrb[(p == NUM_HARTS ? 4 : p)*4 +: 4];
            assign br_wvalid[p] = all_wvalid[p == NUM_HARTS ? 4 : p];
            assign br_bready[p] = all_bready[p == NUM_HARTS ? 4 : p];
            assign br_araddr[(p)*32 +: 32] = all_araddr[(p == NUM_HARTS ? 4 : p)*32 +: 32];
            assign br_arlen[(p)*8 +: 8] = all_arlen[(p == NUM_HARTS ? 4 : p)*8 +: 8];
            assign br_arlock[p] = all_arlock[p == NUM_HARTS ? 4 : p];
            assign br_arvalid[p] = all_arvalid[p == NUM_HARTS ? 4 : p];
            assign br_rready[p] = all_rready[p == NUM_HARTS ? 4 : p];
        end
        for (i = 0; i < 5; i = i + 1) begin : gen_out
            if (i < NUM_HARTS) begin : gen_hart
                assign all_awready[i] = br_awready[i];
                assign all_wready[i] = br_wready[i];
                assign all_bresp[(i)*2 +: 2] = br_bresp[(i)*2 +: 2];
                assign all_bvalid[i] = br_bvalid[i];
                assign all_arready[i] = br_arready[i];
                assign all_rdata[(i)*32 +: 32] = br_rdata[(i)*32 +: 32];
                assign all_rresp[(i)*2 +: 2] = br_rresp[(i)*2 +: 2];
                assign all_rlast[i] = br_rlast[i];
                assign all_rvalid[i] = br_rvalid[i];
            end else if (i == 4) begin : gen_dma
                assign all_awready[i] = br_awready[NUM_HARTS];
                assign all_wready[i] = br_wready[NUM_HARTS];
                assign all_bresp[(i)*2 +: 2] = br_bresp[(NUM_HARTS)*2 +: 2];
                assign all_bvalid[i] = br_bvalid[NUM_HARTS];
                assign all_arready[i] = br_arready[NUM_HARTS];
                assign all_rdata[(i)*32 +: 32] = br_rdata[(NUM_HARTS)*32 +: 32];
                assign all_rresp[(i)*2 +: 2] = br_rresp[(NUM_HARTS)*2 +: 2];
                assign all_rlast[i] = br_rlast[NUM_HARTS];
                assign all_rvalid[i] = br_rvalid[NUM_HARTS];
            end else begin : gen_unused
                assign all_awready[i] = 1'd0;
                assign all_wready[i] = 1'd0;
                assign all_bresp[(i)*2 +: 2] = 2'd0;
                assign all_bvalid[i] = 1'd0;
                assign all_arready[i] = 1'd0;
                assign all_rdata[(i)*32 +: 32] = 32'd0;
                assign all_rresp[(i)*2 +: 2] = 2'd0;
                assign all_rlast[i] = 1'd0;
                assign all_rvalid[i] = 1'd0;
            end
        end
    endgenerate

    AXIMIGBridge #(
        .APP_ADDR_WIDTH(28),
        .NPORTS        (NPORTS),
        .EXCLUSIVE     (NUM_HARTS > 1)
    ) bridge (
        .clk                (clk),
        .reset              (reset),
        .s_axi_awaddr           (br_awaddr),
        .s_axi_awlen            (br_awlen),
        .s_axi_awlock           (br_awlock),
        .s_axi_awvalid          (br_awvalid),
        .s_axi_wdata            (br_wdata),
        .s_axi_wstrb            (br_wstrb),
        .s_axi_wvalid           (br_wvalid),
        .s_axi_bready           (br_bready),
        .s_axi_araddr           (br_araddr),
        .s_axi_arlen            (br_arlen),
        .s_axi_arlock           (br_arlock),
        .s_axi_arvalid          (br_arvalid),
        .s_axi_rready           (br_rready),
        .s_axi_awready          (br_awready),
        .s_axi_wready           (br_wready),
        .s_axi_bresp            (br_bresp),
        .s_axi_bvalid           (br_bvalid),
        .s_axi_arready          (br_arready),
        .s_axi_rdata            (br_rdata),
        .s_axi_rresp            (br_rresp),
        .s_axi_rlast            (br_rlast),
        .s_axi_rvalid           (br_rvalid),
        .init_calib_complete(ddr_calib_complete),
        .app_addr           (ddr_app_addr),
        .app_cmd            (ddr_app_cmd),
        .app_en             (ddr_app_en),
        .app_rdy            (ddr_app_rdy),
        .app_wdf_data       (ddr_app_wdf_data),
        .app_wdf_mask       (ddr_app_wdf_mask),
        .app_wdf_wren       (ddr_app_wdf_wren),
        .app_wdf_end        (ddr_app_wdf_end),
        .app_wdf_rdy        (ddr_app_wdf_rdy),
        .app_rd_data        (ddr_app_rd_data),
        .app_rd_data_valid  (ddr_app_rd_data_valid),
        .app_rd_data_end    (ddr_app_rd_data_end)
    );

endmodule
