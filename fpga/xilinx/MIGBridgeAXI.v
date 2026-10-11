// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Block design wrapper for the DRAM bridge: s_axi from the interconnect
// (CPU) and s_dma_axi directly from the SD host controller's DMA, both into
// the MIG native interface.
module MIGBridgeAXI (
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s_axi:s_dma_axi, ASSOCIATED_RESET reset" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 reset RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME reset, POLARITY ACTIVE_HIGH" *)
    input  wire         reset,
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 0, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_axi_awaddr,
    input  wire [  7:0] s_axi_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_axi_awsize,
    input  wire [  1:0] s_axi_awburst,
    // verilator lint_on UNUSEDSIGNAL
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
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [ 31:0] s_axi_rdata,
    output wire [  1:0] s_axi_rresp,
    output wire         s_axi_rlast,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,
    // verilog_format: off
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_dma_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, MAX_BURST_LENGTH 16, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 0, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    input  wire [ 31:0] s_dma_axi_awaddr,
    input  wire [  7:0] s_dma_axi_awlen,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [  2:0] s_dma_axi_awsize,
    input  wire [  1:0] s_dma_axi_awburst,
    // verilator lint_on UNUSEDSIGNAL
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

    AXIMIGBridge #(
        .APP_ADDR_WIDTH(28)
    ) bridge (
        .clk                (clk),
        .reset              (reset),
        .s_axi_awaddr       ({s_dma_axi_awaddr, s_axi_awaddr}),
        .s_axi_awlen        ({s_dma_axi_awlen, s_axi_awlen}),
        .s_axi_awvalid      ({s_dma_axi_awvalid, s_axi_awvalid}),
        .s_axi_awready      ({s_dma_axi_awready, s_axi_awready}),
        .s_axi_wdata        ({s_dma_axi_wdata, s_axi_wdata}),
        .s_axi_wstrb        ({s_dma_axi_wstrb, s_axi_wstrb}),
        .s_axi_wvalid       ({s_dma_axi_wvalid, s_axi_wvalid}),
        .s_axi_wready       ({s_dma_axi_wready, s_axi_wready}),
        .s_axi_bresp        ({s_dma_axi_bresp, s_axi_bresp}),
        .s_axi_bvalid       ({s_dma_axi_bvalid, s_axi_bvalid}),
        .s_axi_bready       ({s_dma_axi_bready, s_axi_bready}),
        .s_axi_araddr       ({s_dma_axi_araddr, s_axi_araddr}),
        .s_axi_arlen        ({s_dma_axi_arlen, s_axi_arlen}),
        .s_axi_arvalid      ({s_dma_axi_arvalid, s_axi_arvalid}),
        .s_axi_arready      ({s_dma_axi_arready, s_axi_arready}),
        .s_axi_rdata        ({s_dma_axi_rdata, s_axi_rdata}),
        .s_axi_rresp        ({s_dma_axi_rresp, s_axi_rresp}),
        .s_axi_rlast        ({s_dma_axi_rlast, s_axi_rlast}),
        .s_axi_rvalid       ({s_dma_axi_rvalid, s_axi_rvalid}),
        .s_axi_rready       ({s_dma_axi_rready, s_axi_rready}),
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
