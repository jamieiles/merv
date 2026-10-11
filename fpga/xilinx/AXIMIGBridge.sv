// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// AXI4 subordinate to Xilinx 7-series MIG native (app_*) interface bridge
// for the merv platform, where there are no caches in the core and every
// access is a single 32-bit (or narrower) beat, apart from DMA which may use
// INCR bursts.  There are two subordinate ports, port 0 for the CPU (DRAM
// accesses come straight from the core, bypassing the interconnect) and
// port 1 for DMA, arbitrated a transaction at a time.
//
// With CACHE_SETS > 0 there is a CACHE_WAYS set associative write-back cache
// of 16 byte lines (one MIG command) in front of the DRAM.  Both ports go
// through it so it is the single point of coherence and DMA needs no
// maintenance.  Read misses allocate, evicting an invalid way or otherwise
// the next way in round robin order, writing a dirty victim back as one full
// line before the fill.  Write hits only update the line and mark it dirty,
// write misses go straight to the DRAM without allocating so that streams of
// writes (clearing or copying pages) don't cause line fills.  The tags are
// initialized at configuration and not by reset so dirty data survives a
// system reset.
//
// Read hits return the data straight from the cache arrays in the cycle after
// the tags are read.  Writes are posted: the write data may be accepted with
// the address and the response is given as soon as the last beat has been
// accepted, before it has been written to the cache or DRAM.  The bridge
// only starts the next transaction once the write has been done, so later
// reads observe it.
//
// One beat is in flight at a time: each DRAM access is one MIG command, with
// a 4:1 PHY and x16 DDR3 each command is a BL8 of 128 bits.  Uncached reads
// select the addressed 32-bit word from the returned data, writes replicate
// the word across the 128 bits and mask the other bytes.  The MIG retires
// requests to the same bank in order so a read after a write observes the
// write.
module AXIMIGBridge #(
    parameter int APP_ADDR_WIDTH = 28,
    parameter int CACHE_SETS     = 2048,
    parameter int CACHE_WAYS     = 4
) (
    input  logic                      clk,
    input  logic                      reset,
    // AXI4 subordinates, 32-bit data, no IDs.  Bursts are INCR of 32-bit
    // beats, size and burst type are not checked.
    input  logic [   1:0][31:0] s_axi_awaddr,
    input  logic [   1:0][ 7:0] s_axi_awlen,
    input  logic [   1:0]       s_axi_awvalid,
    output logic [   1:0]       s_axi_awready,
    input  logic [   1:0][31:0] s_axi_wdata,
    input  logic [   1:0][ 3:0] s_axi_wstrb,
    input  logic [   1:0]       s_axi_wvalid,
    output logic [   1:0]       s_axi_wready,
    output logic [   1:0][ 1:0] s_axi_bresp,
    output logic [   1:0]       s_axi_bvalid,
    input  logic [   1:0]       s_axi_bready,
    input  logic [   1:0][31:0] s_axi_araddr,
    input  logic [   1:0][ 7:0] s_axi_arlen,
    input  logic [   1:0]       s_axi_arvalid,
    output logic [   1:0]       s_axi_arready,
    output logic [   1:0][31:0] s_axi_rdata,
    output logic [   1:0][ 1:0] s_axi_rresp,
    output logic [   1:0]       s_axi_rlast,
    output logic [   1:0]       s_axi_rvalid,
    input  logic [   1:0]       s_axi_rready,
    // MIG native interface.
    input  logic                      init_calib_complete,
    output logic [APP_ADDR_WIDTH-1:0] app_addr,
    output logic [               2:0] app_cmd,
    output logic                      app_en,
    input  logic                      app_rdy,
    output logic [             127:0] app_wdf_data,
    output logic [              15:0] app_wdf_mask,
    output logic                      app_wdf_wren,
    output logic                      app_wdf_end,
    input  logic                      app_wdf_rdy,
    input  logic [             127:0] app_rd_data,
    input  logic                      app_rd_data_valid,
    // verilator lint_off UNUSEDSIGNAL
    input  logic                      app_rd_data_end
    // verilator lint_on UNUSEDSIGNAL
);

    localparam logic [2:0] CMD_WRITE = 3'b000, CMD_READ = 3'b001;

    localparam logic [3:0]
        IDLE     = 4'd0,
        RD_CMD   = 4'd1,
        RD_WAIT  = 4'd2,
        RD_RESP  = 4'd3,
        WR_DATA  = 4'd4,
        WR_WDF   = 4'd5,
        WR_CMD   = 4'd6,
        RD_TAG   = 4'd8,
        RD_CHECK = 4'd9,
        WR_CHECK = 4'd11,
        WB_WDF   = 4'd12,
        WB_CMD   = 4'd13;

    localparam bit HAS_CACHE = CACHE_SETS > 0;
    localparam int WAYS      = HAS_CACHE ? CACHE_WAYS : 1;
    localparam int IDX_BITS  = HAS_CACHE ? $clog2(CACHE_SETS) : 1;
    localparam int WAY_BITS  = WAYS > 1 ? $clog2(WAYS) : 1;
    localparam int TAG_BITS  = APP_ADDR_WIDTH - 4 - IDX_BITS;
    // Tag entries are {dirty, valid, tag}.
    localparam int VALID     = TAG_BITS;
    localparam int DIRTY     = TAG_BITS + 1;

    initial assert (!HAS_CACHE || (1 << IDX_BITS) == CACHE_SETS);
    initial assert (WAYS == 1 || (1 << WAY_BITS) == WAYS);

    logic [3:0]  state;
    // verilator lint_off UNUSEDSIGNAL
    logic [31:0] addr;
    // verilator lint_on UNUSEDSIGNAL
    logic [7:0]  beats_left;
    logic [31:0] data;
    logic [3:0]  strb;
    logic        port;       // the port of the transaction in progress
    logic        b_pend;     // a posted write response for b_port
    logic        b_port;
    logic [1:0]  last_grant; // round robin priority

    // Cache arrays, single ported with a one cycle read latency.  The
    // outputs hold their value while the index is unchanged and the arrays
    // aren't written, so a victim's tag and data stay available until it has
    // been written back.  While idle the arrays are read with the address of
    // the request being granted so that the tags are valid in the first
    // state of the transaction (RD_CHECK, or WR_CHECK straight after the
    // write data).
    // verilator lint_off UNUSEDSIGNAL
    wire  [IDX_BITS-1:0] index    = addr[4+:IDX_BITS];
    logic [IDX_BITS-1:0] ram_index;
    wire  [TAG_BITS-1:0] addr_tag = addr[4+IDX_BITS+:TAG_BITS];
    logic [TAG_BITS+1:0] tag_q [WAYS];
    logic [127:0]        line_q[WAYS];
    logic [WAYS-1:0]     tag_we, line_we;
    logic [TAG_BITS+1:0] tag_wdata;
    logic [15:0]         line_be;
    logic [127:0]        line_wdata;
    // verilator lint_on UNUSEDSIGNAL
    logic [WAYS-1:0]     way_hit;
    logic [WAY_BITS-1:0] hit_way, victim, way, next_way;
    wire                 hit = |way_hit;
    wire  [15:0]         wr_be = 16'(strb) << {addr[3:2], 2'b00};

    generate
        if (HAS_CACHE) begin : gen_cache
            for (genvar w = 0; w < WAYS; ++w) begin : gen_way
                (* ram_style = "block" *)
                logic [TAG_BITS+1:0] tags[CACHE_SETS];
                (* ram_style = "block" *)
                logic [127:0] lines[CACHE_SETS];
                logic [TAG_BITS+1:0] tq;
                logic [127:0] lq;

                initial begin
                    for (int i = 0; i < CACHE_SETS; ++i) tags[i] = '0;
                end

                always_ff @(posedge clk) begin
                    if (tag_we[w]) tags[ram_index] <= tag_wdata;
                    tq <= tags[ram_index];
                end

                always_ff @(posedge clk) begin
                    for (int b = 0; b < 16; ++b)
                        if (line_we[w] && line_be[b])
                            lines[ram_index][b*8+:8] <= line_wdata[b*8+:8];
                    lq <= lines[ram_index];
                end

                assign tag_q[w]  = tq;
                assign line_q[w] = lq;
            end
        end else begin : gen_no_cache
            assign tag_q[0]  = '0;
            assign line_q[0] = '0;
        end
    endgenerate

    // Hit detection and victim selection: the first invalid way, otherwise
    // round robin.
    always_comb begin
        way_hit = '0;
        hit_way = '0;
        victim  = WAYS == 1 ? '0 : next_way;
        for (int w = WAYS - 1; w >= 0; --w) begin
            if (HAS_CACHE && tag_q[w][VALID] && tag_q[w][TAG_BITS-1:0] == addr_tag) begin
                way_hit[w] = 1'b1;
                hit_way    = WAY_BITS'(w);
            end
            if (!tag_q[w][VALID]) victim = WAY_BITS'(w);
        end
    end

    // Fill a whole line from the DRAM, or update the written bytes of a line
    // that hits and mark it dirty.
    always_comb begin
        tag_we     = '0;
        line_we    = '0;
        tag_wdata  = {1'b0, 1'b1, addr_tag};
        line_be    = 16'hffff;
        line_wdata = app_rd_data;
        if (HAS_CACHE && state == RD_WAIT && app_rd_data_valid) begin
            tag_we[way]  = 1'b1;
            line_we[way] = 1'b1;
        end else if (state == WR_CHECK && hit) begin
            tag_we[hit_way]  = 1'b1;
            line_we[hit_way] = 1'b1;
            tag_wdata        = {1'b1, 1'b1, addr_tag};
            line_be          = wr_be;
            line_wdata       = {4{data}};
        end
    end

    // app_addr is in units of the 16-bit DRAM word, each command covers 16
    // bytes.  A write back goes to the victim's address.
    assign app_addr     = state == WB_CMD ?
                          APP_ADDR_WIDTH'({tag_q[way][TAG_BITS-1:0], index, 3'b000}) :
                          APP_ADDR_WIDTH'({addr[APP_ADDR_WIDTH-1:4], 3'b000});
    assign app_cmd      = state == RD_CMD ? CMD_READ : CMD_WRITE;
    assign app_en       = state == RD_CMD || state == WR_CMD || state == WB_CMD;
    assign app_wdf_data = state == WB_WDF ? line_q[way] : {4{data}};
    assign app_wdf_mask = state == WB_WDF ? 16'h0000 : ~wr_be;
    assign app_wdf_wren = state == WR_WDF || state == WB_WDF;
    assign app_wdf_end  = app_wdf_wren;

    // Round robin arbitration of the four request channels (AR and AW of
    // each port), granted only when idle.
    logic [3:0] req, grant;
    logic [1:0] grant_idx;

    assign req = {s_axi_awvalid[1], s_axi_arvalid[1], s_axi_awvalid[0],
                  s_axi_arvalid[0]};

    always_comb begin
        grant     = 4'b0;
        grant_idx = 2'd0;
        for (int i = 4; i >= 1; --i) begin
            logic [1:0] idx;
            idx = last_grant + 2'(i);
            if (req[idx]) begin
                grant     = 4'b0001 << idx;
                grant_idx = idx;
            end
        end
        if (state != IDLE || b_pend || !init_calib_complete) grant = 4'b0;
    end

    // The arrays are never written while idle.
    // verilator lint_off UNUSEDSIGNAL
    wire [31:0] req_addr = grant_idx[0] ? s_axi_awaddr[grant_idx[1]] :
                                          s_axi_araddr[grant_idx[1]];
    // verilator lint_on UNUSEDSIGNAL
    assign ram_index = state == IDLE ? req_addr[4+:IDX_BITS] : index;

    assign s_axi_arready = {grant[2], grant[0]};
    assign s_axi_awready = {grant[3], grant[1]};

    // The first write beat can be accepted along with the address.
    wire [1:0] w_with_aw = {grant[3], grant[1]};
    // A read hit returns the data from the arrays in RD_CHECK, otherwise
    // from the data register in RD_RESP.
    wire        rd_hit   = HAS_CACHE && state == RD_CHECK && hit;
    wire [31:0] hit_data = line_q[hit_way][{addr[3:2], 5'b00000}+:32];
    wire        rvalid   = state == RD_RESP || rd_hit;

    always_comb begin
        for (int p = 0; p < 2; ++p) begin
            s_axi_wready[p] = (state == WR_DATA && port == p[0]) || w_with_aw[p];
            s_axi_rvalid[p] = rvalid && port == p[0];
            s_axi_rdata[p]  = rd_hit ? hit_data : data;
            s_axi_rresp[p]  = 2'b00;
            s_axi_rlast[p]  = beats_left == 8'd0;
            s_axi_bvalid[p] = b_pend && b_port == p[0];
            s_axi_bresp[p]  = 2'b00;
        end
    end

    // Accepting the last write beat posts the write response.
    wire w_last = (state == IDLE && |w_with_aw &&
                   s_axi_wvalid[grant_idx[1]] && s_axi_awlen[grant_idx[1]] == 8'd0) ||
                  (state == WR_DATA && s_axi_wvalid[port] && beats_left == 8'd0);

    always_ff @(posedge clk) begin
        if (w_last) begin
            b_pend <= 1'b1;
            b_port <= state == IDLE ? grant_idx[1] : port;
        end else if (b_pend && s_axi_bready[b_port]) begin
            b_pend <= 1'b0;
        end
        if (reset) b_pend <= 1'b0;
    end

    always_ff @(posedge clk) begin
        case (state)
            IDLE: begin
                if (|grant) begin
                    port       <= grant_idx[1];
                    last_grant <= grant_idx;
                    if (grant_idx[0]) begin
                        addr       <= s_axi_awaddr[grant_idx[1]];
                        beats_left <= s_axi_awlen[grant_idx[1]];
                        state      <= WR_DATA;
                        if (s_axi_wvalid[grant_idx[1]]) begin
                            data  <= s_axi_wdata[grant_idx[1]];
                            strb  <= s_axi_wstrb[grant_idx[1]];
                            state <= HAS_CACHE ? WR_CHECK : WR_WDF;
                        end
                    end else begin
                        addr       <= s_axi_araddr[grant_idx[1]];
                        beats_left <= s_axi_arlen[grant_idx[1]];
                        state      <= HAS_CACHE ? RD_CHECK : RD_CMD;
                    end
                end
            end
            // Subsequent beats of a burst read the arrays here.
            RD_TAG: state <= RD_CHECK;
            RD_CHECK: begin
                if (hit) begin
                    // Returned now if accepted, otherwise held in RD_RESP.
                    data  <= hit_data;
                    state <= RD_RESP;
                    if (s_axi_rready[port]) begin
                        if (beats_left == 8'd0) begin
                            state <= IDLE;
                        end else begin
                            addr       <= addr + 32'd4;
                            beats_left <= beats_left - 8'd1;
                            state      <= RD_TAG;
                        end
                    end
                end else begin
                    way      <= victim;
                    next_way <= next_way + 1'b1;
                    state    <= tag_q[victim][VALID] && tag_q[victim][DIRTY] ?
                                WB_WDF : RD_CMD;
                end
            end
            WB_WDF: if (app_wdf_rdy) state <= WB_CMD;
            WB_CMD: if (app_rdy) state <= RD_CMD;
            RD_CMD: if (app_rdy) state <= RD_WAIT;
            RD_WAIT: begin
                if (app_rd_data_valid) begin
                    data  <= app_rd_data[{addr[3:2], 5'b00000}+:32];
                    state <= RD_RESP;
                end
            end
            RD_RESP: begin
                if (s_axi_rready[port]) begin
                    if (beats_left == 8'd0) begin
                        state <= IDLE;
                    end else begin
                        addr       <= addr + 32'd4;
                        beats_left <= beats_left - 8'd1;
                        state      <= HAS_CACHE ? RD_TAG : RD_CMD;
                    end
                end
            end
            WR_DATA: begin
                if (s_axi_wvalid[port]) begin
                    data  <= s_axi_wdata[port];
                    strb  <= s_axi_wstrb[port];
                    state <= HAS_CACHE ? WR_CHECK : WR_WDF;
                end
            end
            WR_CHECK: begin
                if (!hit) begin
                    state <= WR_WDF;
                end else if (beats_left == 8'd0) begin
                    state <= IDLE;
                end else begin
                    addr       <= addr + 32'd4;
                    beats_left <= beats_left - 8'd1;
                    state      <= WR_DATA;
                end
            end
            WR_WDF: if (app_wdf_rdy) state <= WR_CMD;
            WR_CMD: begin
                if (app_rdy) begin
                    if (beats_left == 8'd0) begin
                        state <= IDLE;
                    end else begin
                        addr       <= addr + 32'd4;
                        beats_left <= beats_left - 8'd1;
                        state      <= WR_DATA;
                    end
                end
            end
            default: state <= IDLE;
        endcase

        if (reset) begin
            state      <= IDLE;
            last_grant <= 2'd0;
            next_way   <= '0;
        end
    end

endmodule
