`ifndef vivado
`default_nettype none
`else
`default_nettype wire
`endif

`ifdef USE_POWER_PINS
`define POWER_PIN_PORTS \
    inout               vccd1, \
    inout               vssd1,
`define POWER_PIN_CONNECT \
    .vccd1(vccd1), \
    .vssd1(vssd1),
`else
`define POWER_PIN_PORTS
`define POWER_PIN_CONNECT
`endif
