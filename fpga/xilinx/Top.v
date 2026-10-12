// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns / 1ps

module Top #(
    // Run the cores on a 2x UI clock (162.5MHz).
    parameter CORE_CLK2X = 0
) (
    input  wire        clk,
    input  wire        ext_reset,
    input  wire        uart_rtl_0_rxd,
    output wire        uart_rtl_0_txd,
    output wire [13:0] ddr3_addr,
    output wire [ 2:0] ddr3_ba,
    output wire        ddr3_cas_n,
    output wire        ddr3_ck_n,
    output wire        ddr3_ck_p,
    output wire        ddr3_cke,
    output wire        ddr3_cs_n,
    output wire [ 1:0] ddr3_dm,
    inout       [15:0] ddr3_dq,
    inout       [ 1:0] ddr3_dqs_n,
    inout       [ 1:0] ddr3_dqs_p,
    output wire        ddr3_odt,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n,
    output wire        sd_clk,
    inout  wire        sd_cmd,
    inout  wire [ 3:0] sd_dat,
    input  wire        sd_cd_n,
    output wire        sd_busy,
    input  wire        eth_miso,
    output wire        eth_mosi,
    output wire        eth_ncs,
    output wire        eth_sck,
    input  wire        eth_int,
    output wire        eth_reset,
    output wire        led_halted
);

    wire        core_halted;
    wire [31:0] dbg_pc, dbg_insn;
    wire [ 2:0] dbg_priv;
    wire        dbg_meip, dbg_seip, dbg_mtip, dbg_sdhci_irq;
    wire [ 5:0] dbg_trap_cause;
    wire [31:0] dbg_trap_epc, dbg_trap_tval;
    wire [ 4:0] dbg_plic_sources;
    assign led_halted = core_halted;

    wire        reset_rtl_0;
    wire        uart_rtl_0_baudoutn;
    wire        uart_rtl_0_ctsn;
    wire        uart_rtl_0_dcdn;
    wire        uart_rtl_0_ddis;
    wire        uart_rtl_0_dsrn;
    wire        uart_rtl_0_dtrn;
    wire        uart_rtl_0_out1n;
    wire        uart_rtl_0_out2n;
    wire        uart_rtl_0_ri;
    wire        uart_rtl_0_rtsn;
    wire        uart_rtl_0_rxrdyn;
    wire        uart_rtl_0_txrdyn;

    wire [15:0] bootrom_bram_addr;
    wire        bootrom_bram_clk;
    wire [31:0] bootrom_bram_din;
    wire [31:0] bootrom_bram_dout;
    wire        bootrom_bram_en;
    wire [ 3:0] bootrom_bram_we;

    wire        sd_busy_counter_reload;
    wire        sd_busy_expired;

    wire        spi_miso;
    wire        spi_mosi;
    wire [ 0:0] spi_ncs;
    wire        spi_sck;

    wire        sd_activity;
    wire        sd_cmd_o;
    wire        sd_cmd_t;
    wire        sd_cmd_i;
    wire [ 3:0] sd_dat_o;
    wire [ 3:0] sd_dat_t;
    wire [ 3:0] sd_dat_i;

    assign sd_busy   = ~sd_busy_expired;

    // The SPI controller is dedicated to the ENC28J60.
    assign eth_mosi  = spi_mosi;
    assign eth_ncs   = spi_ncs[0];
    assign eth_sck   = spi_sck;
    assign eth_reset = 1'b1;
    assign spi_miso  = eth_miso;

    // The SDHCI registers are packed into the IOBs, so connect them
    // straight to the buffers.
    IOBUF sd_cmd_iobuf (
        .I (sd_cmd_o),
        .T (sd_cmd_t),
        .O (sd_cmd_i),
        .IO(sd_cmd)
    );

    genvar sd_dat_n;
    generate
        for (sd_dat_n = 0; sd_dat_n < 4; sd_dat_n = sd_dat_n + 1) begin : gen_sd_dat
            IOBUF sd_dat_iobuf (
                .I (sd_dat_o[sd_dat_n]),
                .T (sd_dat_t[sd_dat_n]),
                .O (sd_dat_i[sd_dat_n]),
                .IO(sd_dat[sd_dat_n])
            );
        end
    endgenerate

    // Stretch SD activity so that it is visible on the LED.
    MervCountdown #(
        .width     (22),
        .reload_val(22'h3fffff)
    ) sd_busy_counter (
        .clk    (bootrom_bram_clk),
        .reset  (1'b0),
        .reload (sd_activity),
        .expired(sd_busy_expired)
    );

    wire rst_pulse;

    MervCountdown #(
        .width     (8),
        .reload_val(8'hff)
    ) reset_counter (
        .clk    (rst_clk),
        .reset  (1'b0),
        .reload (mmio_rst_sync & ~mmio_rst_sync_last),
        .expired(rst_pulse)
    );

    xpm_memory_spram #(
        .ADDR_WIDTH_A      (14),
        .BYTE_WRITE_WIDTH_A(8),
        .MEMORY_PRIMITIVE  ("block"),
        .MEMORY_SIZE       (16384 * 32),
        .READ_DATA_WIDTH_A (32),
        .READ_LATENCY_A    (1),
        .WRITE_DATA_WIDTH_A(32),
        .WRITE_MODE_A      ("write_first"),
        .MEMORY_INIT_FILE  ("bootrom.mem"),
        .MEMORY_INIT_PARAM ("")
    ) ram (
        .addra (bootrom_bram_addr[15:2]),
        .clka  (bootrom_bram_clk),
        .dina  (bootrom_bram_din),
        .douta (bootrom_bram_dout),
        .ena   (bootrom_bram_en),
        .rsta  (1'b0),
        .wea   (bootrom_bram_we),
        .regcea(1'b1),
        .sleep (1'b0)
    );


    wire                                      sys_clk;
    wire                                      rst_clk;
    wire                                      mmio_rst;
    wire                                      mmio_rst_sync;
    reg                                       mmio_rst_sync_last;

    wire rtl_reset = ~ext_reset | ~rst_pulse;

    always @(posedge rst_clk) mmio_rst_sync_last <= mmio_rst_sync;

    BitSync mmio_rst_bitsync (
        .clk  (rst_clk),
        .reset(1'b0),
        .d    (mmio_rst),
        .q    (mmio_rst_sync)
    );

    BUFG sys_bufg (
        .I(clk),
        .O(sys_clk)
    );

    BUFG rst_bufg (
        .I(clk),
        .O(rst_clk)
    );

    wire         ui_clk;
    wire         ui_clk_sync_rst;
    wire         mig_clk_ref;
    wire         clint_refclk;
    wire         init_calib_complete;
    wire [ 27:0] app_addr;
    wire [  2:0] app_cmd;
    wire         app_en;
    wire         app_rdy;
    wire [127:0] app_wdf_data;
    wire [ 15:0] app_wdf_mask;
    wire         app_wdf_wren;
    wire         app_wdf_end;
    wire         app_wdf_rdy;
    wire [127:0] app_rd_data;
    wire         app_rd_data_valid;
    wire         app_rd_data_end;

    // The MIG only provides additional UI clocks with the AXI interface, so
    // recreate them here exactly as the MIG did: an MMCM from the UI clock
    // (81.25MHz x 8 = 650MHz VCO) giving the 200MHz IDELAYCTRL reference and
    // the CLINT reference clock (650MHz / 64 = 10.15625MHz).  The MIG PLL is
    // only reset by sys_rst so the UI clock runs before the reference clock
    // is available, as it did with the internal MMCM.
    wire        clkgen_fb, clkgen_fb_in;
    wire        clkgen_ref;
    wire        clkgen_clint;
    wire        clkgen_2x;
    wire        core_clk;
    wire        clkgen_locked;
    reg  [16:0] clkgen_rst_count = 17'h1ffff;

    // Hold the MMCM in reset until the MIG PLL has locked and the UI clock
    // is stable (~1.3ms at 100MHz).
    always @(posedge sys_clk)
        if (|clkgen_rst_count) clkgen_rst_count <= clkgen_rst_count - 1'b1;

    MMCME2_BASE #(
        .CLKIN1_PERIOD   (12.308),
        .DIVCLK_DIVIDE   (1),
        .CLKFBOUT_MULT_F (8.0),
        .CLKOUT0_DIVIDE_F(3.25),
        .CLKOUT1_DIVIDE  (64),
        .CLKOUT2_DIVIDE  (4)
    ) clkgen (
        .CLKIN1  (ui_clk),
        .CLKFBIN (clkgen_fb_in),
        .CLKFBOUT(clkgen_fb),
        .CLKOUT0 (clkgen_ref),
        .CLKOUT1 (clkgen_clint),
        .CLKOUT2 (clkgen_2x),
        .LOCKED  (clkgen_locked),
        .RST     (|clkgen_rst_count),
        .PWRDWN  (1'b0)
    );

    // Only start the reference clock once stable so that the IDELAYCTRL
    // reset is applied with a valid clock.
    BUFGCE clk_ref_bufg (
        .I (clkgen_ref),
        .CE(clkgen_locked),
        .O (mig_clk_ref)
    );

    BUFG clint_refclk_bufg (
        .I(clkgen_clint),
        .O(clint_refclk)
    );

    // The cores' clock (650MHz / 4 = 162.5MHz) is synchronous to the UI
    // clock: with the feedback through a BUFG the MMCM compensates the
    // clock tree so that the two are phase aligned at the flops.  Otherwise
    // the cores run on the UI clock.
    generate
        if (CORE_CLK2X != 0) begin : gen_clk2x
            BUFG clkgen_fb_bufg (
                .I(clkgen_fb),
                .O(clkgen_fb_in)
            );

            BUFG core_clk_bufg (
                .I(clkgen_2x),
                .O(core_clk)
            );
        end else begin : gen_clk1x
            assign clkgen_fb_in = clkgen_fb;
            assign core_clk     = ui_clk;
        end
    endgenerate

    mig_native mig (
        .ddr3_addr          (ddr3_addr),
        .ddr3_ba            (ddr3_ba),
        .ddr3_cas_n         (ddr3_cas_n),
        .ddr3_ck_n          (ddr3_ck_n),
        .ddr3_ck_p          (ddr3_ck_p),
        .ddr3_cke           (ddr3_cke),
        .ddr3_cs_n          (ddr3_cs_n),
        .ddr3_dm            (ddr3_dm),
        .ddr3_dq            (ddr3_dq),
        .ddr3_dqs_n         (ddr3_dqs_n),
        .ddr3_dqs_p         (ddr3_dqs_p),
        .ddr3_odt           (ddr3_odt),
        .ddr3_ras_n         (ddr3_ras_n),
        .ddr3_reset_n       (ddr3_reset_n),
        .ddr3_we_n          (ddr3_we_n),
        .sys_clk_i          (sys_clk),
        .clk_ref_i          (mig_clk_ref),
        .sys_rst            (1'b0),
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_clk_sync_rst),
        .init_calib_complete(init_calib_complete),
        .device_temp        (),
        .app_addr           (app_addr),
        .app_cmd            (app_cmd),
        .app_en             (app_en),
        .app_rdy            (app_rdy),
        .app_wdf_data       (app_wdf_data),
        .app_wdf_mask       (app_wdf_mask),
        .app_wdf_wren       (app_wdf_wren),
        .app_wdf_end        (app_wdf_end),
        .app_wdf_rdy        (app_wdf_rdy),
        .app_rd_data        (app_rd_data),
        .app_rd_data_valid  (app_rd_data_valid),
        .app_rd_data_end    (app_rd_data_end),
        .app_sr_req         (1'b0),
        .app_ref_req        (1'b0),
        .app_zq_req         (1'b0),
        .app_sr_active      (),
        .app_ref_ack        (),
        .app_zq_ack         ()
    );

    MervArty_wrapper inst (
        .ui_clk             (ui_clk),
        .core_clk           (core_clk),
        .clint_refclk       (clint_refclk),
        // Hold the system in reset until the DRAM is calibrated
        .ddr_ready          (init_calib_complete & ~ui_clk_sync_rst),
        .ddr_calib_complete (init_calib_complete),
        .ddr_app_addr       (app_addr),
        .ddr_app_cmd        (app_cmd),
        .ddr_app_en         (app_en),
        .ddr_app_rdy        (app_rdy),
        .ddr_app_wdf_data   (app_wdf_data),
        .ddr_app_wdf_mask   (app_wdf_mask),
        .ddr_app_wdf_wren   (app_wdf_wren),
        .ddr_app_wdf_end    (app_wdf_end),
        .ddr_app_wdf_rdy    (app_wdf_rdy),
        .ddr_app_rd_data    (app_rd_data),
        .ddr_app_rd_data_valid(app_rd_data_valid),
        .ddr_app_rd_data_end(app_rd_data_end),
        .reset_rtl_0        (rtl_reset),
        .uart_rtl_0_baudoutn(),
        .uart_rtl_0_ctsn    (),
        .uart_rtl_0_dcdn    (),
        .uart_rtl_0_ddis    (),
        .uart_rtl_0_dsrn    (),
        .uart_rtl_0_dtrn    (),
        .uart_rtl_0_out1n   (),
        .uart_rtl_0_out2n   (),
        .uart_rtl_0_ri      (),
        .uart_rtl_0_rtsn    (),
        .uart_rtl_0_rxd     (uart_rtl_0_rxd),
        .uart_rtl_0_rxrdyn  (),
        .uart_rtl_0_txd     (uart_rtl_0_txd),
        .uart_rtl_0_txrdyn  (),
        .bootrom_bram_addr  (bootrom_bram_addr),
        .bootrom_bram_clk   (bootrom_bram_clk),
        .bootrom_bram_din   (bootrom_bram_din),
        .bootrom_bram_dout  (bootrom_bram_dout),
        .bootrom_bram_en    (bootrom_bram_en),
        .bootrom_bram_we    (bootrom_bram_we),
        .spi_miso           (spi_miso),
        .spi_mosi           (spi_mosi),
        .spi_ncs            (spi_ncs),
        .spi_sck            (spi_sck),
        .eth_int            (eth_int),
        .sd_clk             (sd_clk),
        .sd_cmd_o           (sd_cmd_o),
        .sd_cmd_t           (sd_cmd_t),
        .sd_cmd_i           (sd_cmd_i),
        .sd_dat_o           (sd_dat_o),
        .sd_dat_t           (sd_dat_t),
        .sd_dat_i           (sd_dat_i),
        .sd_cd_n            (sd_cd_n),
        .sd_activity        (sd_activity),
        .mmio_rst           (mmio_rst),
        .core_halted        (core_halted),
        .dbg_pc             (dbg_pc),
        .dbg_insn           (dbg_insn),
        .dbg_priv           (dbg_priv),
        .dbg_meip           (dbg_meip),
        .dbg_seip           (dbg_seip),
        .dbg_mtip           (dbg_mtip),
        .dbg_sdhci_irq      (dbg_sdhci_irq),
        .dbg_trap_cause     (dbg_trap_cause),
        .dbg_trap_epc       (dbg_trap_epc),
        .dbg_trap_tval      (dbg_trap_tval),
        .dbg_plic_sources   (dbg_plic_sources)
    );

    // Debug visibility over JTAG.
    vio_debug vio (
        .clk       (ui_clk),
        .probe_in0 (dbg_pc),
        .probe_in1 (dbg_insn),
        .probe_in2 ({core_halted, dbg_priv}),
        .probe_in3 ({dbg_sdhci_irq, dbg_mtip, dbg_seip, dbg_meip}),
        .probe_in4 (dbg_trap_cause),
        .probe_in5 (dbg_trap_epc),
        .probe_in6 (dbg_trap_tval),
        .probe_in7 (dbg_plic_sources)
    );

endmodule
