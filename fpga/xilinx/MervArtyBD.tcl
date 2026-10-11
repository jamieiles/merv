# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# IP Integrator block design for merv on the Arty S7-50:
#
#   MervCoreAXI_0/m_axi -> axi_interconnect_0 -> peripherals
#   MervCoreAXI_0/m_dram_axi -> MIGBridgeAXI_0/s_axi (point to point)
#   SDHCIAXI_0 DMA -> MIGBridgeAXI_0/s_dma_axi (point to point)
#
#   0x40000000  64KB   boot ROM (BRAM)
#   0x80000000  256MB  DDR3 through MIGBridgeAXI_0
#   0xf0000000  64KB   CLINT (msip, mtimecmp, mtime) + reset at 0xc000
#   0xf8000000  4MB    PLIC
#   0xfffc0000  64KB   SD host controller
#   0xfffe0000  64KB   Quad SPI (ENC28J60)
#   0xffff0000  64KB   UART 16550 (registers at +0x1000)
#
# Requires the module sources (MervCLINT, MervCoreAXI, SDHCIAXI, PLICAXI,
# MIGBridgeAXI) to have been added to the project.

set design_name MervArty
create_bd_design $design_name
current_bd_design $design_name

proc add_module { name cell } {
    if { [catch {set c [create_bd_cell -type module -reference $name $cell]} errmsg] } {
        error "Unable to add referenced block <$name>: $errmsg"
    }
    return $c
}

# Ports
set bootrom_bram [ create_bd_intf_port -mode Master -vlnv xilinx.com:interface:bram_rtl:1.0 bootrom_bram ]
set_property -dict [ list CONFIG.MASTER_TYPE {BRAM_CTRL} CONFIG.READ_WRITE_MODE {READ_WRITE} ] $bootrom_bram
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:uart_rtl:1.0 uart_rtl_0

# The DDR3 controller is outside of the block design (native MIG interface)
# and provides the system clock and calibration status.
create_bd_port -dir I -type clk -freq_hz 81247969 ui_clk
create_bd_port -dir I -type clk -freq_hz 10140625 clint_refclk
create_bd_port -dir I ddr_ready
create_bd_port -dir I ddr_calib_complete
create_bd_port -dir O -from 27 -to 0 ddr_app_addr
create_bd_port -dir O -from 2 -to 0 ddr_app_cmd
create_bd_port -dir O ddr_app_en
create_bd_port -dir I ddr_app_rdy
create_bd_port -dir O -from 127 -to 0 ddr_app_wdf_data
create_bd_port -dir O -from 15 -to 0 ddr_app_wdf_mask
create_bd_port -dir O ddr_app_wdf_wren
create_bd_port -dir O ddr_app_wdf_end
create_bd_port -dir I ddr_app_wdf_rdy
create_bd_port -dir I -from 127 -to 0 ddr_app_rd_data
create_bd_port -dir I ddr_app_rd_data_valid
create_bd_port -dir I ddr_app_rd_data_end
create_bd_port -dir I eth_int
set reset_rtl_0 [ create_bd_port -dir I -type rst reset_rtl_0 ]
set_property -dict [ list CONFIG.POLARITY {ACTIVE_HIGH} ] $reset_rtl_0
create_bd_port -dir I -type data spi_miso
create_bd_port -dir O -type data spi_mosi
create_bd_port -dir O -from 0 -to 0 spi_ncs
create_bd_port -dir O -type clk spi_sck
create_bd_port -dir O -type data mmio_rst
create_bd_port -dir O sd_clk
create_bd_port -dir O sd_cmd_o
create_bd_port -dir O sd_cmd_t
create_bd_port -dir I sd_cmd_i
create_bd_port -dir O -from 3 -to 0 sd_dat_o
create_bd_port -dir O -from 3 -to 0 sd_dat_t
create_bd_port -dir I -from 3 -to 0 sd_dat_i
create_bd_port -dir I sd_cd_n
create_bd_port -dir O sd_activity
create_bd_port -dir O core_halted
# Debug visibility for a VIO in the top level.
create_bd_port -dir O -from 31 -to 0 dbg_pc
create_bd_port -dir O -from 31 -to 0 dbg_insn
create_bd_port -dir O -from 2 -to 0 dbg_priv
create_bd_port -dir O -from 5 -to 0 dbg_trap_cause
create_bd_port -dir O -from 31 -to 0 dbg_trap_epc
create_bd_port -dir O -from 31 -to 0 dbg_trap_tval
create_bd_port -dir O dbg_meip
create_bd_port -dir O -from 4 -to 0 dbg_plic_sources
create_bd_port -dir O dbg_seip
create_bd_port -dir O dbg_mtip
create_bd_port -dir O dbg_sdhci_irq

# Cells
set core [add_module MervCoreAXI MervCoreAXI_0]
# The number of TLB entries and the barrel shifter can be overridden with
# $MERV_TLB_ENTRIES and $MERV_BARREL_SHIFT.
if { [info exists ::env(MERV_TLB_ENTRIES)] } {
    set_property CONFIG.TLB_ENTRIES $::env(MERV_TLB_ENTRIES) $core
}
if { [info exists ::env(MERV_BARREL_SHIFT)] } {
    set_property CONFIG.BARREL_SHIFT $::env(MERV_BARREL_SHIFT) $core
}
add_module MervCLINT MervCLINT_0
add_module SDHCIAXI SDHCIAXI_0
add_module PLICAXI PLICAXI_0
add_module MIGBridgeAXI MIGBridgeAXI_0

set axi_quad_spi_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 axi_quad_spi_0 ]
set_property -dict [ list \
    CONFIG.C_BYTE_LEVEL_INTERRUPT_EN {0} \
    CONFIG.C_FIFO_DEPTH {256} \
    CONFIG.C_NUM_SS_BITS {1} \
    CONFIG.C_NUM_TRANSFER_BITS {8} \
    CONFIG.C_SCK_RATIO {4} \
    CONFIG.C_SPI_MODE {0} \
    CONFIG.C_TYPE_OF_AXI4_INTERFACE {0} \
    CONFIG.C_USE_STARTUP {0} \
    CONFIG.C_USE_STARTUP_INT {0} \
    CONFIG.C_XIP_MODE {0} \
    CONFIG.Multiples16 {1} \
] $axi_quad_spi_0

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uart16550:2.0 axi_uart16550_0

set bootrom_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bootrom_ctrl ]
set_property -dict [ list CONFIG.DATA_WIDTH {32} CONFIG.SINGLE_PORT_BRAM {1} ] $bootrom_ctrl

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_ui_clk

# A single manager (the core) with one transaction in flight so the
# interconnect only needs to decode: an area optimized AXI Interconnect is
# much smaller than a SmartConnect.  DRAM doesn't go through it, its address
# arbitration costs a cycle on every access.
set axi_interconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0 ]
set_property -dict [ list CONFIG.NUM_SI {1} CONFIG.NUM_MI {6} CONFIG.STRATEGY {1} ] $axi_interconnect_0

# Interface connections
connect_bd_intf_net [get_bd_intf_pins MervCoreAXI_0/m_axi] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_ports uart_rtl_0] [get_bd_intf_pins axi_uart16550_0/UART]
connect_bd_intf_net [get_bd_intf_ports bootrom_bram] [get_bd_intf_pins bootrom_ctrl/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins axi_uart16550_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] [get_bd_intf_pins bootrom_ctrl/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M02_AXI] [get_bd_intf_pins axi_quad_spi_0/AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M03_AXI] [get_bd_intf_pins MervCLINT_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M04_AXI] [get_bd_intf_pins PLICAXI_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M05_AXI] [get_bd_intf_pins SDHCIAXI_0/s_axi]
# The core's DRAM accesses (split off in MervCoreAXI) and SDMA from the SD
# host controller go straight into the DRAM bridge, point to point rather than
# through the interconnect.  Both go through the bridge's cache so DMA is
# coherent with the CPU.
connect_bd_intf_net [get_bd_intf_pins MervCoreAXI_0/m_dram_axi] [get_bd_intf_pins MIGBridgeAXI_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins SDHCIAXI_0/m_axi] [get_bd_intf_pins MIGBridgeAXI_0/s_dma_axi]

# Clocks and resets
connect_bd_net [get_bd_ports ui_clk] \
    [get_bd_pins MervCoreAXI_0/clk] \
    [get_bd_pins MervCLINT_0/s_axi_aclk] \
    [get_bd_pins SDHCIAXI_0/s_axi_aclk] \
    [get_bd_pins PLICAXI_0/s_axi_aclk] \
    [get_bd_pins MIGBridgeAXI_0/clk] \
    [get_bd_pins axi_quad_spi_0/ext_spi_clk] \
    [get_bd_pins axi_quad_spi_0/s_axi_aclk] \
    [get_bd_pins axi_uart16550_0/s_axi_aclk] \
    [get_bd_pins bootrom_ctrl/s_axi_aclk] \
    [get_bd_pins rst_ui_clk/slowest_sync_clk] \
    [get_bd_pins axi_interconnect_0/ACLK] \
    [get_bd_pins axi_interconnect_0/S00_ACLK] \
    [get_bd_pins axi_interconnect_0/M00_ACLK] [get_bd_pins axi_interconnect_0/M01_ACLK] \
    [get_bd_pins axi_interconnect_0/M02_ACLK] [get_bd_pins axi_interconnect_0/M03_ACLK] \
    [get_bd_pins axi_interconnect_0/M04_ACLK] [get_bd_pins axi_interconnect_0/M05_ACLK]
connect_bd_net [get_bd_ports clint_refclk] [get_bd_pins MervCLINT_0/refclk]
connect_bd_net [get_bd_ports ddr_ready] [get_bd_pins rst_ui_clk/dcm_locked]
connect_bd_net [get_bd_ports reset_rtl_0] [get_bd_pins rst_ui_clk/ext_reset_in]
connect_bd_net [get_bd_pins rst_ui_clk/interconnect_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins rst_ui_clk/peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN] \
    [get_bd_pins axi_interconnect_0/M00_ARESETN] [get_bd_pins axi_interconnect_0/M01_ARESETN] \
    [get_bd_pins axi_interconnect_0/M02_ARESETN] [get_bd_pins axi_interconnect_0/M03_ARESETN] \
    [get_bd_pins axi_interconnect_0/M04_ARESETN] [get_bd_pins axi_interconnect_0/M05_ARESETN]
connect_bd_net [get_bd_pins rst_ui_clk/peripheral_aresetn] \
    [get_bd_pins MervCLINT_0/s_axi_aresetn] \
    [get_bd_pins SDHCIAXI_0/s_axi_aresetn] \
    [get_bd_pins PLICAXI_0/s_axi_aresetn] \
    [get_bd_pins axi_quad_spi_0/s_axi_aresetn] \
    [get_bd_pins axi_uart16550_0/s_axi_aresetn] \
    [get_bd_pins bootrom_ctrl/s_axi_aresetn]
connect_bd_net [get_bd_pins rst_ui_clk/peripheral_reset] \
    [get_bd_pins MervCoreAXI_0/reset] \
    [get_bd_pins MIGBridgeAXI_0/reset]

# Interrupts
connect_bd_net [get_bd_pins MervCLINT_0/mtime_irq] [get_bd_pins MervCoreAXI_0/mtip] [get_bd_ports dbg_mtip]
connect_bd_net [get_bd_pins MervCLINT_0/msip] [get_bd_pins MervCoreAXI_0/msip]
connect_bd_net [get_bd_pins PLICAXI_0/meip] [get_bd_pins MervCoreAXI_0/meip] [get_bd_ports dbg_meip]
connect_bd_net [get_bd_pins PLICAXI_0/seip] [get_bd_pins MervCoreAXI_0/seip] [get_bd_ports dbg_seip]
connect_bd_net [get_bd_pins axi_quad_spi_0/ip2intc_irpt] [get_bd_pins PLICAXI_0/spi_irq]
connect_bd_net [get_bd_pins axi_uart16550_0/ip2intc_irpt] [get_bd_pins PLICAXI_0/uart_irq]
connect_bd_net [get_bd_ports eth_int] [get_bd_pins PLICAXI_0/eth_int_n]
connect_bd_net [get_bd_pins SDHCIAXI_0/irq] [get_bd_pins PLICAXI_0/sdhci_irq] [get_bd_ports dbg_sdhci_irq]

# Peripheral I/O
connect_bd_net [get_bd_ports spi_mosi] [get_bd_pins axi_quad_spi_0/io0_o]
connect_bd_net [get_bd_ports spi_miso] [get_bd_pins axi_quad_spi_0/io1_i]
connect_bd_net [get_bd_ports spi_sck] [get_bd_pins axi_quad_spi_0/sck_o]
connect_bd_net [get_bd_ports spi_ncs] [get_bd_pins axi_quad_spi_0/ss_o]
connect_bd_net [get_bd_ports sd_activity] [get_bd_pins SDHCIAXI_0/activity]
connect_bd_net [get_bd_ports sd_clk] [get_bd_pins SDHCIAXI_0/sd_clk]
foreach pin {sd_cmd_o sd_cmd_t sd_cmd_i sd_dat_o sd_dat_t sd_dat_i sd_cd_n} {
    connect_bd_net [get_bd_ports $pin] [get_bd_pins SDHCIAXI_0/$pin]
}
foreach pin {ddr_calib_complete ddr_app_addr ddr_app_cmd ddr_app_en ddr_app_rdy \
             ddr_app_wdf_data ddr_app_wdf_mask ddr_app_wdf_wren ddr_app_wdf_end \
             ddr_app_wdf_rdy ddr_app_rd_data ddr_app_rd_data_valid ddr_app_rd_data_end} {
    connect_bd_net [get_bd_ports $pin] [get_bd_pins MIGBridgeAXI_0/$pin]
}
connect_bd_net [get_bd_ports mmio_rst] [get_bd_pins MervCLINT_0/sys_reset]
connect_bd_net [get_bd_ports core_halted] [get_bd_pins MervCoreAXI_0/halted]
connect_bd_net [get_bd_ports dbg_pc] [get_bd_pins MervCoreAXI_0/dbg_pc]
connect_bd_net [get_bd_ports dbg_insn] [get_bd_pins MervCoreAXI_0/dbg_insn]
connect_bd_net [get_bd_ports dbg_priv] [get_bd_pins MervCoreAXI_0/dbg_priv]
connect_bd_net [get_bd_ports dbg_plic_sources] [get_bd_pins PLICAXI_0/dbg_sources]
foreach pin {dbg_trap_cause dbg_trap_epc dbg_trap_tval} {
    connect_bd_net [get_bd_ports $pin] [get_bd_pins MervCoreAXI_0/$pin]
}

# Address map
set core_space [get_bd_addr_spaces MervCoreAXI_0/m_axi]
assign_bd_address -offset 0x40000000 -range 0x00010000 -target_address_space $core_space [get_bd_addr_segs bootrom_ctrl/S_AXI/Mem0] -force
assign_bd_address -offset 0x80000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces MervCoreAXI_0/m_dram_axi] [get_bd_addr_segs MIGBridgeAXI_0/s_axi/reg0] -force
assign_bd_address -offset 0xF0000000 -range 0x00010000 -target_address_space $core_space [get_bd_addr_segs MervCLINT_0/s_axi/reg0] -force
assign_bd_address -offset 0xF8000000 -range 0x00400000 -target_address_space $core_space [get_bd_addr_segs PLICAXI_0/s_axi/reg0] -force
assign_bd_address -offset 0xFFFC0000 -range 0x00010000 -target_address_space $core_space [get_bd_addr_segs SDHCIAXI_0/s_axi/reg0] -force
assign_bd_address -offset 0xFFFE0000 -range 0x00010000 -target_address_space $core_space [get_bd_addr_segs axi_quad_spi_0/AXI_LITE/Reg] -force
assign_bd_address -offset 0xFFFF0000 -range 0x00010000 -target_address_space $core_space [get_bd_addr_segs axi_uart16550_0/S_AXI/Reg] -force
assign_bd_address -offset 0x80000000 -range 0x10000000 -target_address_space [get_bd_addr_spaces SDHCIAXI_0/m_axi] [get_bd_addr_segs MIGBridgeAXI_0/s_dma_axi/reg0] -force

validate_bd_design
save_bd_design
