# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Build the merv Arty S7-50 bitstream (non-project mode), run from an empty
# directory:
#
#   vivado -mode tcl -source <merv>/fpga/xilinx/merv-arty.tcl
#
# The boot ROM and F mode firmware images are taken from the CMake build
# directory, <merv>/_build by default or $MERV_BUILD.
set script_dir [file dirname [file normalize [info script]]]
set origin_dir [file normalize "${script_dir}/../.."]
if { [info exists ::env(MERV_BUILD)] } {
    set build_dir [file normalize $::env(MERV_BUILD)]
} else {
    set build_dir "${origin_dir}/_build"
}

create_project -in_memory -part xc7s50csga324-2 MervArty
set_property source_mgmt_mode All [current_project]

set include_dirs [list "${origin_dir}/rtl" "${origin_dir}/fpga/common/lib"]
set_property include_dirs $include_dirs [current_fileset]

add_files "${build_dir}/fpga/xilinx/bootrom/bootrom.mem"
add_files "${build_dir}/firmware/ffw/ffw.mem"

# Block design module references (Verilog tops).
read_verilog "${origin_dir}/fpga/common/MervCLINT.v"
read_verilog "${origin_dir}/fpga/common/sdhci/SDHCIAXI.v"
read_verilog "${origin_dir}/fpga/xilinx/MervCoreAXI.v"
read_verilog "${origin_dir}/fpga/xilinx/PLICAXI.v"
read_verilog "${origin_dir}/fpga/xilinx/MIGBridgeAXI.v"

read_verilog -sv "${origin_dir}/fpga/common/lib/MervCommon.svh"
set_property is_global_include true [get_files "${origin_dir}/fpga/common/lib/MervCommon.svh"]
read_verilog -sv "${origin_dir}/rtl/MervDefs.svh"

foreach f [concat \
    [glob "${origin_dir}/rtl/*.sv"] \
    [glob "${origin_dir}/fpga/common/lib/*.sv"] \
    [glob "${origin_dir}/fpga/common/sdhci/*.sv"] \
    [list "${origin_dir}/fpga/common/PLIC.sv" \
          "${origin_dir}/fpga/common/AXILiteRegs.sv" \
          "${origin_dir}/fpga/xilinx/AXIMIGBridge.sv"]] {
    read_verilog -sv $f
}

source "${origin_dir}/fpga/xilinx/mig_native.tcl"

# JTAG readable debug signals.
create_ip -name vio -vendor xilinx.com -library ip -module_name vio_debug
set_property -dict [list CONFIG.C_NUM_PROBE_IN {8} CONFIG.C_NUM_PROBE_OUT {0} \
    CONFIG.C_PROBE_IN0_WIDTH {32} CONFIG.C_PROBE_IN1_WIDTH {32} \
    CONFIG.C_PROBE_IN2_WIDTH {4} CONFIG.C_PROBE_IN3_WIDTH {4} \
    CONFIG.C_PROBE_IN4_WIDTH {6} CONFIG.C_PROBE_IN5_WIDTH {32} \
    CONFIG.C_PROBE_IN6_WIDTH {32} CONFIG.C_PROBE_IN7_WIDTH {5}] [get_ips vio_debug]
generate_target all [get_ips vio_debug]
synth_ip [get_ips vio_debug]
source "${origin_dir}/fpga/xilinx/MervArtyBD.tcl"
set_property source_mgmt_mode All [current_project]

read_xdc "${origin_dir}/fpga/xilinx/MervArty.xdc"

generate_target all [get_files MervArty.bd]
read_verilog ./.gen/sources_1/bd/MervArty/hdl/MervArty_wrapper.v
read_verilog "${origin_dir}/fpga/xilinx/Top.v"

synth_design -top Top -include_dirs $include_dirs -flatten_hierarchy rebuilt \
    -fsm_extraction one_hot -directive PerformanceOptimized \
    -verilog_define vivado=1
write_checkpoint -force post_synth
report_timing_summary -file post_synth_timing_summary.rpt
report_utilization -hierarchical -file post_synth_util_hier.rpt

opt_design -directive ExploreWithRemap
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
write_checkpoint -force post_place
report_timing_summary -file post_place_timing_summary.rpt

route_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force post_route
report_timing_summary -file post_route_timing_summary.rpt
report_timing -file post_route_timing.rpt -sort_by group -max_paths 100 -path_type summary
report_clock_utilization -file clock_util.rpt
report_utilization -file post_route_util.rpt
report_utilization -hierarchical -file post_route_util_hier.rpt
report_drc -file post_imp_drc.rpt

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -force MervArty.bit -bin_file
write_debug_probes -force MervArty.ltx

exit
