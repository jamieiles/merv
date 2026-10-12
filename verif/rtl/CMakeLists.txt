# Verilator unit tests of RTL blocks.
if(NOT MERV_HAVE_RTL)
    return()
endif()

add_executable(rtl-unit-tests TestAXIMIGBridge.cpp TestMervCLINT.cpp TestMervAXIClk2x.cpp)
verilate(rtl-unit-tests
    SOURCES ${PROJECT_SOURCE_DIR}/fpga/xilinx/AXIMIGBridge.sv
    TOP_MODULE AXIMIGBridge
    PREFIX VAXIMIGBridge
    # A small cache so that the random tests see plenty of conflicts.
    VERILATOR_ARGS -Wall -O3 -GNPORTS=5 -GCACHE_SETS=8 -GCACHE_WAYS=2)
verilate(rtl-unit-tests
    SOURCES ${PROJECT_SOURCE_DIR}/fpga/common/MervCLINT.v
            ${PROJECT_SOURCE_DIR}/fpga/common/lib/BitSync.sv
            ${PROJECT_SOURCE_DIR}/fpga/common/lib/MervDFF.sv
    INCLUDE_DIRS ${PROJECT_SOURCE_DIR}/fpga/common/lib
    TOP_MODULE MervCLINT
    PREFIX VMervCLINT
    VERILATOR_ARGS -Wall -GNUM_HARTS=4)
verilate(rtl-unit-tests
    SOURCES ${PROJECT_SOURCE_DIR}/fpga/common/lib/MervAXIClk2x.sv
    TOP_MODULE MervAXIClk2x
    PREFIX VMervAXIClk2x
    VERILATOR_ARGS -Wall)
target_link_libraries(rtl-unit-tests gtest_main)
target_compile_options(rtl-unit-tests PRIVATE -Wno-error -Wno-unused-parameter -Wno-sign-compare -Wno-unused-variable)
add_test(NAME rtl-unit-tests COMMAND rtl-unit-tests)

# The bridge for a single hart: two ports and no exclusive monitors.
add_executable(rtl-unit-tests-1hart TestAXIMIGBridge.cpp)
target_compile_definitions(rtl-unit-tests-1hart PRIVATE BRIDGE_1HART)
verilate(rtl-unit-tests-1hart
    SOURCES ${PROJECT_SOURCE_DIR}/fpga/xilinx/AXIMIGBridge.sv
    TOP_MODULE AXIMIGBridge
    PREFIX VAXIMIGBridge1
    VERILATOR_ARGS -Wall -O3 -GNPORTS=2 -GEXCLUSIVE=0 -GCACHE_SETS=8 -GCACHE_WAYS=2)
target_link_libraries(rtl-unit-tests-1hart gtest_main)
target_compile_options(rtl-unit-tests-1hart PRIVATE -Wno-error -Wno-unused-parameter -Wno-sign-compare -Wno-unused-variable)
add_test(NAME rtl-unit-tests-1hart COMMAND rtl-unit-tests-1hart)
