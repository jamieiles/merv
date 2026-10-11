# Verilator unit tests of RTL blocks.
if(NOT MERV_HAVE_RTL)
    return()
endif()

add_executable(rtl-unit-tests TestAXIMIGBridge.cpp)
verilate(rtl-unit-tests
    SOURCES ${PROJECT_SOURCE_DIR}/fpga/xilinx/AXIMIGBridge.sv
    TOP_MODULE AXIMIGBridge
    PREFIX VAXIMIGBridge
    # A small cache so that the random tests see plenty of conflicts.
    VERILATOR_ARGS -Wall -O3 -GCACHE_SETS=8 -GCACHE_WAYS=2)
target_link_libraries(rtl-unit-tests gtest_main)
target_compile_options(rtl-unit-tests PRIVATE -Wno-error -Wno-unused-parameter -Wno-sign-compare -Wno-unused-variable)
add_test(NAME rtl-unit-tests COMMAND rtl-unit-tests)
