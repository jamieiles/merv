# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Sample the debug VIO (PC, instruction, privilege, interrupts) over JTAG.
# Run from the build directory containing MervArty.bit/MervArty.ltx:
#
#   vivado -mode batch -source debug-sample.tcl -tclargs [program] [samples]
set do_program [expr {[llength $argv] > 0 ? [lindex $argv 0] : 0}]
set samples [expr {[llength $argv] > 1 ? [lindex $argv 1] : 20}]

open_hw_manager
connect_hw_server
current_hw_target [get_hw_targets */xilinx_tcf/Digilent/*]
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE {MervArty.ltx} $dev
set_property FULL_PROBES.FILE {MervArty.ltx} $dev
if { $do_program } {
    set_property PROGRAM.FILE {MervArty.bit} $dev
    program_hw_devices $dev
}
refresh_hw_device $dev
set vio [get_hw_vios -of_objects $dev]
for {set i 0} {$i < $samples} {incr i} {
    refresh_hw_vio $vio
    set line "sample $i:"
    foreach p [lsort [get_hw_probes -of_objects $vio]] {
        append line " [get_property NAME $p]=[get_property INPUT_VALUE $p]"
    }
    puts $line
    after 50
}
exit
