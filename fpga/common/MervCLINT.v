// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// CLINT: mtime/mtimecmp and msip.
module MervCLINT (
    input  wire        refclk,
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [15:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    // verilator lint_off UNUSEDSIGNAL
    input  wire [ 3:0] s_axi_wstrb,
    // verilator lint_on UNUSEDSIGNAL
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [ 1:0] s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [15:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output reg  [ 1:0] s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,
    output wire [63:0] mtime,
    output wire        mtime_irq,
    output reg         msip,
    output wire        sys_reset
);

    localparam MSIP_OFFSET = 16'h0000;
    localparam MTIMECMP_LOW_OFFSET = 16'h4000;
    localparam MTIMECMP_HIGH_OFFSET = 16'h4004;
    localparam MTIME_LOW_OFFSET = 16'hbff8;
    localparam MTIME_HIGH_OFFSET = 16'hbffc;
    localparam RESET_OFFSET = 16'hc000;

    wire        refclk_sync;
    wire [63:0] mtimecmp;
    reg  [63:0] mtimecmp_next;
    reg  [63:0] mtime_next;
    reg         mtime_irq_next;
    reg         s_axi_bvalid_next;
    reg         s_axi_rvalid_next;
    reg  [31:0] s_axi_rdata_next;
    wire        refclk_last;
    reg         reset;
    reg         refclk_half_next;
    wire        refclk_half;
    reg         sys_reset_next;

    always @(*) begin
        reset = ~s_axi_aresetn;
    end

    always @(*) begin
        refclk_half_next = ~refclk_half;
    end

    always @(*) begin
        mtime_next = mtime;
        if (refclk_sync & ~refclk_last) mtime_next = mtime + 64'd2;
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == MTIME_LOW_OFFSET)
            mtime_next[31:0] = s_axi_wdata;
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == MTIME_HIGH_OFFSET)
            mtime_next[63:32] = s_axi_wdata;
    end

    always @(*) begin
        mtimecmp_next = mtimecmp;
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == MTIMECMP_LOW_OFFSET)
            mtimecmp_next[31:0] = s_axi_wdata;
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == MTIMECMP_HIGH_OFFSET)
            mtimecmp_next[63:32] = s_axi_wdata;
    end

    always @(*) begin
        sys_reset_next = sys_reset;
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == RESET_OFFSET)
            sys_reset_next = s_axi_wdata[0];
    end

    // Machine software interrupt for the single hart.
    always @(posedge s_axi_aclk) begin
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == MSIP_OFFSET)
            msip <= s_axi_wdata[0];
        if (reset) msip <= 1'b0;
    end

    always @(*) begin
        case (s_axi_araddr)
            MSIP_OFFSET: s_axi_rdata_next = {31'b0, msip};
            MTIME_LOW_OFFSET: s_axi_rdata_next = mtime[31:0];
            MTIME_HIGH_OFFSET: s_axi_rdata_next = mtime[63:32];
            MTIMECMP_LOW_OFFSET: s_axi_rdata_next = mtimecmp[31:0];
            MTIMECMP_HIGH_OFFSET: s_axi_rdata_next = mtimecmp[63:32];
            default: s_axi_rdata_next = 32'b0;
        endcase
    end

    always @(*) begin
        mtime_irq_next = mtime > mtimecmp;
    end

    always @(*) begin
        s_axi_awready = s_axi_awvalid & s_axi_wvalid;
        s_axi_wready  = s_axi_awvalid & s_axi_wvalid;
        s_axi_bresp   = 2'b00;
    end

    always @(*) begin
        s_axi_arready     = s_axi_arvalid & s_axi_rready;
        s_axi_rvalid_next = s_axi_arvalid & s_axi_rready;
        s_axi_rresp       = 2'b00;
    end

    always @(*) begin
        s_axi_bvalid_next = s_axi_bvalid;
        if (s_axi_awvalid && s_axi_wvalid) s_axi_bvalid_next = 1'b1;
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid_next = 1'b0;
    end

    BitSync refclk_synchronizer (
        .clk  (s_axi_aclk),
        .reset(reset),
        .d    (refclk_half),
        .q    (refclk_sync)
    );

    MervDFF refclk_last_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (refclk_sync),
        .q    (refclk_last)
    );

    MervDFF #(
        .width(64)
    ) mtime_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (mtime_next),
        .q    (mtime)
    );

    MervDFF s_axi_bvalid_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (s_axi_bvalid_next),
        .q    (s_axi_bvalid)
    );

    MervDFF #(
        .width(64)
    ) mtimecmp_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (mtimecmp_next),
        .q    (mtimecmp)
    );

    MervDFF mtime_irq_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (mtime_irq_next),
        .q    (mtime_irq)
    );

    MervDFF s_axi_rready_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (s_axi_rvalid_next),
        .q    (s_axi_rvalid)
    );

    MervDFF #(
        .width(32)
    ) s_axi_rdata_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (s_axi_rdata_next),
        .q    (s_axi_rdata)
    );

    MervDFF refclk_dff (
        .clk  (refclk),
        .reset(reset),
        .en   (1'b1),
        .d    (refclk_half_next),
        .q    (refclk_half)
    );

    MervDFF sys_reset_dff (
        .clk  (s_axi_aclk),
        .reset(reset),
        .en   (1'b1),
        .d    (sys_reset_next),
        .q    (sys_reset)
    );

endmodule
