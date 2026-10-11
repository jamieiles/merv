set_property PACKAGE_PIN R2 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rtl_0_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rtl_0_txd]
set_property PACKAGE_PIN R12 [get_ports uart_rtl_0_txd]
set_property PACKAGE_PIN V12 [get_ports uart_rtl_0_rxd]
set_property IOSTANDARD SSTL135 [get_ports clk]

create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]
set_false_path -from [get_clocks clk_pll_i] -to [get_clocks clk]

set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]

set_property INTERNAL_VREF 0.675 [get_iobanks 34]

# Pmod MicroSD on JC in native SD mode
set_property PACKAGE_PIN U15 [get_ports {sd_dat[3]}]
set_property PACKAGE_PIN V16 [get_ports sd_cmd]
set_property PACKAGE_PIN U17 [get_ports {sd_dat[0]}]
set_property PACKAGE_PIN U18 [get_ports sd_clk]
set_property PACKAGE_PIN U16 [get_ports {sd_dat[1]}]
set_property PACKAGE_PIN P13 [get_ports {sd_dat[2]}]
set_property PACKAGE_PIN R13 [get_ports sd_cd_n]
set_property IOSTANDARD LVCMOS33 [get_ports {sd_clk sd_cmd sd_dat[*] sd_cd_n}]
set_property PULLUP TRUE [get_ports {sd_cmd sd_dat[*] sd_cd_n}]
# The controller drives and samples the bus from registers relative to its
# own SDCLK strobes so pack them into the IOBs for consistent timing; the
# paths through the pads are fixed so don't time them.
set_property IOB TRUE [get_ports {sd_clk sd_cmd sd_dat[*]}]
set_false_path -to [get_ports {sd_clk sd_cmd sd_dat[*]}]
set_false_path -from [get_ports {sd_cmd sd_dat[*] sd_cd_n}]

set_property PACKAGE_PIN V15 [get_ports eth_int]
set_property PACKAGE_PIN R11 [get_ports eth_sck]
set_property PACKAGE_PIN U11 [get_ports eth_miso]
set_property PACKAGE_PIN T11 [get_ports eth_mosi]
set_property PACKAGE_PIN T13 [get_ports eth_ncs]
set_property PACKAGE_PIN V13 [get_ports eth_reset]
set_property IOSTANDARD LVCMOS33 [get_ports eth_int]
set_property IOSTANDARD LVCMOS33 [get_ports eth_sck]
set_property IOSTANDARD LVCMOS33 [get_ports eth_miso]
set_property IOSTANDARD LVCMOS33 [get_ports eth_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports eth_ncs]
set_property IOSTANDARD LVCMOS33 [get_ports eth_reset]

set_property PACKAGE_PIN C18 [get_ports ext_reset]
set_property IOSTANDARD LVCMOS33 [get_ports ext_reset]


set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

set_property IOSTANDARD LVCMOS33 [get_ports sd_busy]
set_property PACKAGE_PIN E18 [get_ports sd_busy]

# LD3: the core has halted (an exception in F mode).
set_property IOSTANDARD LVCMOS33 [get_ports led_halted]
set_property PACKAGE_PIN F13 [get_ports led_halted]
