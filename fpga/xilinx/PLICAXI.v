// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Block design wrapper for the PLIC: AXI4-Lite registers, four sources and
// the M (context 0) and S (context 1) external interrupts.
//
//   1: SPI controller (rising edge)
//   2: UART (level)
//   3: ENC28J60 (falling edge)
//   4: SD host controller (level)
//
// The PLIC sources are level triggered so edge triggered interrupts are
// latched here until a claim returns their ID.  The ENC28J60 interrupt must
// be edge triggered: its line stays asserted until its interrupt work runs,
// as a level it would interrupt continuously.
module PLICAXI (
    // verilog_format: off
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW" *)
    input  wire        s_axi_aresetn,
    // verilog_format: on
    input  wire [21:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [ 3:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [ 1:0] s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [21:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [ 1:0] s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 spi_irq INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "SENSITIVITY EDGE_RISING" *)
    input  wire        spi_irq,
    input  wire        uart_irq,
    input  wire        eth_int_n,
    input  wire        sdhci_irq,
    output wire        meip,
    output wire        seip,
    // Debug: the PLIC source inputs (4:1) and the raw ENC28J60 interrupt.
    output wire [ 4:0] dbg_sources
);

    wire        reg_wr, reg_rd;
    wire [21:0] reg_waddr, reg_raddr;
    wire [31:0] reg_wdata, reg_rdata;
    wire [ 3:0] reg_wstrb;
    wire [ 1:0] irq;

    // Edge triggered sources are latched until a claim returns their ID
    // (the claim registers are at 0x200004 + 0x1000 * ctx).
    reg  spi_irq_last, spi_pending, eth_int_n_last, eth_pending;
    wire claim_rd = reg_rd && reg_raddr[21:13] == 9'h100 &&
                    reg_raddr[11:0] == 12'h004;

    always @(posedge s_axi_aclk) begin
        spi_irq_last   <= spi_irq;
        eth_int_n_last <= eth_int_n;
        if (spi_irq && !spi_irq_last) spi_pending <= 1'b1;
        else if (claim_rd && reg_rdata == 32'd1) spi_pending <= 1'b0;
        if (!eth_int_n && eth_int_n_last) eth_pending <= 1'b1;
        else if (claim_rd && reg_rdata == 32'd3) eth_pending <= 1'b0;
        if (!s_axi_aresetn) begin
            spi_irq_last   <= 1'b0;
            spi_pending    <= 1'b0;
            eth_int_n_last <= 1'b1;
            eth_pending    <= 1'b0;
        end
    end

    assign dbg_sources = {eth_int_n, sdhci_irq, eth_pending, uart_irq, spi_pending};
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;
    assign meip        = irq[0];
    assign seip        = irq[1];

    AXILiteRegs #(
        .addr_bits(22)
    ) regs (
        .clk          (s_axi_aclk),
        .reset        (~s_axi_aresetn),
        .s_axi_awaddr (s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata  (s_axi_wdata),
        .s_axi_wstrb  (s_axi_wstrb),
        .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wready (s_axi_wready),
        .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_araddr (s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata  (s_axi_rdata),
        .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rready (s_axi_rready),
        .reg_wr       (reg_wr),
        .reg_waddr    (reg_waddr),
        .reg_wdata    (reg_wdata),
        .reg_wstrb    (reg_wstrb),
        .reg_rd       (reg_rd),
        .reg_raddr    (reg_raddr),
        .reg_rdata    (reg_rdata)
    );

    PLIC #(
        .num_sources (4),
        .num_contexts(2)
    ) plic (
        .clk      (s_axi_aclk),
        .reset    (~s_axi_aresetn),
        .sources  ({sdhci_irq, eth_pending, uart_irq, spi_pending}),
        .irq      (irq),
        .reg_wr   (reg_wr),
        .reg_waddr(reg_waddr),
        .reg_wdata(reg_wdata),
        .reg_wstrb(reg_wstrb),
        .reg_rd   (reg_rd),
        .reg_raddr(reg_raddr),
        .reg_rdata(reg_rdata)
    );

endmodule
