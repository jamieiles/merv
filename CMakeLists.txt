cmake_minimum_required(VERSION 3.20)
project(merv C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_FLAGS "-Wall -Wextra -Werror ${CMAKE_CXX_FLAGS}")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/CMake")
include(RiscV)
include(CTest)

add_subdirectory(vendor/googletest EXCLUDE_FROM_ALL)
add_subdirectory(firmware/ffw)
add_subdirectory(rtl)
add_subdirectory(sim)
# Core configurations exercised by the test suites: name|simulator arguments.
set(MERV_TEST_CONFIGS
    "default|"
    "emulated|--native-amo 0 --hw-div 0 --hw-mul 0"
    "tlb2|--tlb-entries 2 --native-amo 1 --hw-div 0"
    "tlb16|--tlb-entries 16 --native-amo 0 --hw-div 1")

# RTL configurations, simulated in lockstep against the ISS.
set(MERV_RTL_TEST_CONFIGS
    "rtl-default|--cosim"
    "rtl-small|--cosim --tlb-entries 2 --native-amo 0 --hw-div 0"
    "rtl-barrel|--cosim --barrel-shift 1"
    "rtl-nodiv-barrel|--cosim --hw-div 0 --barrel-shift 1"
    "rtl-nomuldiv|--cosim --hw-div 0 --hw-mul 0"
    "rtl-excl|--cosim --barrel-shift 1 --axi-exclusive 1 --amo-retry")

add_subdirectory(tests)
add_subdirectory(verif)
add_subdirectory(fpga/xilinx)
