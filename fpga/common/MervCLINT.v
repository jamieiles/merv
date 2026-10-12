// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// CLINT: mtime, and mtimecmp and msip for each of NUM_HARTS (up to 4) harts,
// msip at 0x0 + 4 * hart and mtimecmp at 0x4000 + 8 * hart.  The per-hart
// interrupts are separate ports for the block design, those of harts
// beyond NUM_HARTS are tied low.
module MervCLINT #(
    parameter NUM_HARTS = 1
) (
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
    output wire        mtime_irq_1,
    output wire        mtime_irq_2,
    output wire        mtime_irq_3,
    output wire        msip,
    output wire        msip_1,
    output wire        msip_2,
    output wire        msip_3,
    output wire        sys_reset
);

    localparam MSIP_OFFSET = 16'h0000;
    localparam MTIMECMP_OFFSET = 16'h4000;
    localparam MTIME_LOW_OFFSET = 16'hbff8;
    localparam MTIME_HIGH_OFFSET = 16'hbffc;
    localparam RESET_OFFSET = 16'hc000;

    wire        refclk_sync;
    reg  [63:0] mtime_next;
    reg  [NUM_HARTS-1:0] msip_q;
    wire [NUM_HARTS-1:0] irq_q;
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
        sys_reset_next = sys_reset;
        if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == RESET_OFFSET)
            sys_reset_next = s_axi_wdata[0];
    end

    // Per hart msip and mtimecmp.
    wire [63:0] mtimecmp[0:NUM_HARTS-1];
    wire [31:0] hart_rd[0:NUM_HARTS-1];
    reg  [31:0] hart_rdata;

    genvar h;
    generate
        for (h = 0; h < NUM_HARTS; h = h + 1) begin : gen_hart
            localparam [15:0] msip_offset = MSIP_OFFSET + 4 * h;
            localparam [15:0] cmp_offset  = MTIMECMP_OFFSET + 8 * h;
            reg  [63:0] mtimecmp_next;

            // Machine software interrupt.
            always @(posedge s_axi_aclk) begin
                if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == msip_offset)
                    msip_q[h] <= s_axi_wdata[0];
                if (reset) msip_q[h] <= 1'b0;
            end

            always @(*) begin
                mtimecmp_next = mtimecmp[h];
                if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == cmp_offset)
                    mtimecmp_next[31:0] = s_axi_wdata;
                if (s_axi_wvalid && s_axi_awvalid && s_axi_awaddr == cmp_offset + 16'd4)
                    mtimecmp_next[63:32] = s_axi_wdata;
            end

            MervDFF #(
                .width(64)
            ) mtimecmp_dff (
                .clk  (s_axi_aclk),
                .reset(reset),
                .en   (1'b1),
                .d    (mtimecmp_next),
                .q    (mtimecmp[h])
            );

            assign hart_rd[h] =
                s_axi_araddr == msip_offset ? {31'b0, msip_q[h]} :
                s_axi_araddr == cmp_offset ? mtimecmp[h][31:0] :
                s_axi_araddr == cmp_offset + 16'd4 ? mtimecmp[h][63:32] : 32'b0;

            MervDFF mtime_irq_dff (
                .clk  (s_axi_aclk),
                .reset(reset),
                .en   (1'b1),
                .d    (mtime > mtimecmp[h]),
                .q    (irq_q[h])
            );
        end
    endgenerate

    assign msip        = msip_q[0];
    assign msip_1      = NUM_HARTS > 1 ? msip_q[1 % NUM_HARTS] : 1'b0;
    assign msip_2      = NUM_HARTS > 2 ? msip_q[2 % NUM_HARTS] : 1'b0;
    assign msip_3      = NUM_HARTS > 3 ? msip_q[3 % NUM_HARTS] : 1'b0;
    assign mtime_irq   = irq_q[0];
    assign mtime_irq_1 = NUM_HARTS > 1 ? irq_q[1 % NUM_HARTS] : 1'b0;
    assign mtime_irq_2 = NUM_HARTS > 2 ? irq_q[2 % NUM_HARTS] : 1'b0;
    assign mtime_irq_3 = NUM_HARTS > 3 ? irq_q[3 % NUM_HARTS] : 1'b0;

    integer i;
    always @(*) begin
        hart_rdata = 32'b0;
        for (i = 0; i < NUM_HARTS; i = i + 1) hart_rdata = hart_rdata | hart_rd[i];
    end

    always @(*) begin
        case (s_axi_araddr)
            MTIME_LOW_OFFSET: s_axi_rdata_next = mtime[31:0];
            MTIME_HIGH_OFFSET: s_axi_rdata_next = mtime[63:32];
            default: s_axi_rdata_next = hart_rdata;
        endcase
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
