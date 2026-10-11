// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Block design wrapper for the SD host controller: IP integrator module
// references must have a Verilog top level.  The s_axi_ and m_axi_ naming
// lets the AXI4-Lite register interface and the AXI4 SDMA manager be
// inferred.
module SDHCIAXI (
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire        s_axi_aresetn,
    // verilog_format: on
    input  wire [15:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [ 3:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [ 1:0] s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [15:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [ 1:0] s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY LEVEL_HIGH" *)
    output wire        irq,
    output wire        activity,
    // SDMA: whole 64 byte line bursts only, one outstanding transaction.  The
    // cache and protection attributes are fixed so not brought out.
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 m_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axi, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32, ID_WIDTH 0, MAX_BURST_LENGTH 16, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, HAS_LOCK 0, HAS_CACHE 0, HAS_PROT 0, HAS_QOS 0, HAS_REGION 0" *)
    // verilog_format: on
    output wire [31:0] m_axi_awaddr,
    output wire [ 7:0] m_axi_awlen,
    output wire [ 2:0] m_axi_awsize,
    output wire [ 1:0] m_axi_awburst,
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
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [ 1:0] m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,
    // SDCLK is a register output, not a clock in the block design.
    (* X_INTERFACE_IGNORE = "true" *)
    output wire        sd_clk,
    output wire        sd_cmd_o,
    output wire        sd_cmd_t,
    input  wire        sd_cmd_i,
    output wire [ 3:0] sd_dat_o,
    output wire [ 3:0] sd_dat_t,
    input  wire [ 3:0] sd_dat_i,
    input  wire        sd_cd_n
);

    SDHCI sdhci (
        .clk          (s_axi_aclk),
        .resetn       (s_axi_aresetn),
        .s_axi_awaddr (s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata  (s_axi_wdata),
        .s_axi_wstrb  (s_axi_wstrb),
        .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wready (s_axi_wready),
        .s_axi_bresp  (s_axi_bresp),
        .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_araddr (s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata  (s_axi_rdata),
        .s_axi_rresp  (s_axi_rresp),
        .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rready (s_axi_rready),
        .irq          (irq),
        .activity     (activity),
        .m_axi_awaddr (m_axi_awaddr),
        .m_axi_awlen  (m_axi_awlen),
        .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awcache(),
        .m_axi_awprot(),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata  (m_axi_wdata),
        .m_axi_wstrb  (m_axi_wstrb),
        .m_axi_wlast  (m_axi_wlast),
        .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_bresp  (m_axi_bresp),
        .m_axi_bvalid (m_axi_bvalid),
        .m_axi_bready (m_axi_bready),
        .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen  (m_axi_arlen),
        .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arcache(),
        .m_axi_arprot(),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata  (m_axi_rdata),
        .m_axi_rresp  (m_axi_rresp),
        .m_axi_rlast  (m_axi_rlast),
        .m_axi_rvalid (m_axi_rvalid),
        .m_axi_rready (m_axi_rready),
        .sd_clk       (sd_clk),
        .cmd_o        (sd_cmd_o),
        .cmd_t        (sd_cmd_t),
        .cmd_i        (sd_cmd_i),
        .dat_o        (sd_dat_o),
        .dat_t        (sd_dat_t),
        .dat_i        (sd_dat_i),
        .cd_n         (sd_cd_n)
    );

endmodule
