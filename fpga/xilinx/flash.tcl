open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target [get_hw_targets */xilinx_tcf/Digilent/*]
open_hw_target

current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices] 0]

set my_mem_device [lindex [get_cfgmem_parts {s25fl128sxxxxxx0-spi-x1_x2_x4}] 0]
set programming_files {MervArty.bin}
set cfgmem [create_hw_cfgmem -hw_device \
[lindex [get_hw_devices] 0] -mem_dev $my_mem_device]
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
set_property PROGRAM.FILES $programming_files $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem
program_hw_devices [lindex [get_hw_devices] 0]
set_property PROGRAM.BLANK_CHECK 0 $cfgmem
set_property PROGRAM.ERASE 1 $cfgmem
set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
set_property PROGRAM.VERIFY 1 $cfgmem
program_hw_cfgmem -hw_cfgmem $cfgmem

exit
