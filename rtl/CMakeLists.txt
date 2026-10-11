# Verilated models of the core used by merv-sim --rtl/--cosim.
find_package(verilator HINTS $ENV{VERILATOR_ROOT} /usr/share/verilator)

set(MERV_RTL_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/MervCore.sv
    ${CMAKE_CURRENT_SOURCE_DIR}/MervALU.sv
    ${CMAKE_CURRENT_SOURCE_DIR}/MervRAM.sv
    ${CMAKE_CURRENT_SOURCE_DIR}/MervTLB.sv
    ${CMAKE_CURRENT_SOURCE_DIR}/MervMul.sv
    ${CMAKE_CURRENT_SOURCE_DIR}/MervDiv.sv
    CACHE INTERNAL "")

if(verilator_FOUND)
    set(MERV_HAVE_RTL ON CACHE INTERNAL "")
    get_target_property(FFW_DIR ffw BINARY_DIR)
    set(FFW_MEM ${CMAKE_BINARY_DIR}/firmware/ffw/ffw.mem)

    add_library(merv-rtl STATIC)
    # The default configuration, the smallest one (emulated AMOs and
    # division, two TLB entries) and the default with each combination of
    # the divider and the barrel shifter.
    foreach(model
            "MervCore|-GTLB_ENTRIES=4 -GNATIVE_AMO=1 -GHW_DIV=1 -GBARREL_SHIFT=0"
            "MervCoreSmall|-GTLB_ENTRIES=2 -GNATIVE_AMO=0 -GHW_DIV=0 -GBARREL_SHIFT=0"
            "MervCoreBarrel|-GTLB_ENTRIES=4 -GNATIVE_AMO=1 -GHW_DIV=1 -GBARREL_SHIFT=1"
            "MervCoreNoDiv|-GTLB_ENTRIES=4 -GNATIVE_AMO=1 -GHW_DIV=0 -GBARREL_SHIFT=0"
            "MervCoreNoDivBarrel|-GTLB_ENTRIES=4 -GNATIVE_AMO=1 -GHW_DIV=0 -GBARREL_SHIFT=1")
        string(REPLACE "|" ";" parts "${model}")
        list(GET parts 0 prefix)
        list(GET parts 1 params)
        separate_arguments(params)
        verilate(merv-rtl
            SOURCES ${MERV_RTL_SOURCES}
            INCLUDE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}
            TOP_MODULE MervCore
            PREFIX V${prefix}
            DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/V${prefix}
            TRACE_FST
            VERILATOR_ARGS -Wall -Wno-DECLFILENAME -O3 --x-assign fast
                           --x-initial fast ${params}
                           "-GFFW_INIT=\"${FFW_MEM}\"")
    endforeach()
    add_dependencies(merv-rtl ffw)
    target_compile_options(merv-rtl PRIVATE -w)
else()
    message(WARNING "Verilator not found, RTL simulation disabled")
    set(MERV_HAVE_RTL OFF CACHE INTERNAL "")
endif()
