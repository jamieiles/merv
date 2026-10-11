# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Out-of-context synthesis and implementation of the core alone for the
# Spartan-7 to measure utilization and Fmax, run from an empty directory:
#
#   vivado -mode batch -source <merv>/fpga/ooc/ooc.tcl \
#       -tclargs [period_ns [TLB_ENTRIES NATIVE_AMO HW_DIV [BARREL_SHIFT]]]
#
# The clock period is a target to drive the implementation, the achieved Fmax
# is reported from the worst slack.
set script_dir [file dirname [file normalize [info script]]]
set origin_dir [file normalize "${script_dir}/../.."]
set period [expr {[llength $argv] > 0 ? [lindex $argv 0] : 5.0}]
set tlb [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]
set amo [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]
set div [expr {[llength $argv] > 3 ? [lindex $argv 3] : 1}]
set bs [expr {[llength $argv] > 4 ? [lindex $argv 4] : 0}]

create_project -in_memory -part xc7s50csga324-2 MervOOC
read_verilog -sv "${origin_dir}/rtl/MervDefs.svh"
foreach f [glob "${origin_dir}/rtl/*.sv"] {
    read_verilog -sv $f
}
read_verilog -sv "${script_dir}/MervCoreOOC.sv"

synth_design -top MervCoreOOC -mode out_of_context \
    -include_dirs [list "${origin_dir}/rtl"] \
    -generic TLB_ENTRIES=$tlb -generic NATIVE_AMO=$amo -generic HW_DIV=$div \
    -generic BARREL_SHIFT=$bs \
    -fsm_extraction one_hot -directive PerformanceOptimized

create_clock -period $period -name clk [get_ports clk]
# The I/O are registered at the AXI boundary in a real system, constrain them
# loosely so that they don't dominate.
set_input_delay -clock clk [expr {$period * 0.2}] [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk [expr {$period * 0.2}] [get_ports -filter {DIRECTION == OUT}]

opt_design
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore

report_utilization -file ooc_util.rpt
report_utilization -hierarchical -file ooc_util_hier.rpt
report_timing_summary -file ooc_timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts [format "OOC: TLB_ENTRIES=%d NATIVE_AMO=%d HW_DIV=%d BARREL_SHIFT=%d period %.2fns WNS %.3fns Fmax %.1fMHz" \
          $tlb $amo $div $bs $period $wns $fmax]
exit
