# Helpers for building bare-metal RISC-V programs with the cross toolchain.
set(RISCV_PREFIX "riscv64-unknown-elf-" CACHE STRING "Bare-metal RISC-V toolchain prefix")
find_program(RISCV_GCC ${RISCV_PREFIX}gcc REQUIRED)
find_program(RISCV_OBJCOPY ${RISCV_PREFIX}objcopy REQUIRED)
find_program(RISCV_OBJDUMP ${RISCV_PREFIX}objdump REQUIRED)

# add_riscv_elf(<name> LINKER_SCRIPT <ld> MARCH <march> SOURCES <src...>
#               [INCLUDES <dir...>] [CFLAGS <flag...>])
#
# Produces <name>.elf, <name>.bin, <name>.mem (32-bit words, one per line,
# for $readmemh/Vivado) and <name>.dis in the current binary directory.
function(add_riscv_elf name)
    cmake_parse_arguments(ARG "" "LINKER_SCRIPT;MARCH" "SOURCES;INCLUDES;CFLAGS" ${ARGN})
    set(out ${CMAKE_CURRENT_BINARY_DIR}/${name})
    set(srcs)
    foreach(s ${ARG_SOURCES})
        list(APPEND srcs ${CMAKE_CURRENT_SOURCE_DIR}/${s})
    endforeach()
    set(incs -I${CMAKE_CURRENT_SOURCE_DIR})
    foreach(i ${ARG_INCLUDES})
        list(APPEND incs -I${i})
    endforeach()
    add_custom_command(
        OUTPUT ${out}.elf ${out}.bin ${out}.mem ${out}.dis
        COMMAND ${RISCV_GCC} -march=${ARG_MARCH} -mabi=ilp32 -O2 -g
                -ffreestanding -nostdlib -nostartfiles -fno-builtin
                -Wall -Wextra -Werror -Wl,--no-warn-rwx-segments ${ARG_CFLAGS} ${incs}
                -T ${CMAKE_CURRENT_SOURCE_DIR}/${ARG_LINKER_SCRIPT}
                ${srcs} -o ${out}.elf
        COMMAND ${RISCV_OBJCOPY} -O binary ${out}.elf ${out}.bin
        COMMAND ${RISCV_OBJDUMP} -d ${out}.elf > ${out}.dis
        COMMAND ${CMAKE_COMMAND} -DIN=${out}.bin -DOUT=${out}.mem
                -P ${PROJECT_SOURCE_DIR}/CMake/bin2mem.cmake
        DEPENDS ${srcs} ${CMAKE_CURRENT_SOURCE_DIR}/${ARG_LINKER_SCRIPT}
                ${PROJECT_SOURCE_DIR}/CMake/bin2mem.cmake
        IMPLICIT_DEPENDS C ${srcs}
        COMMENT "Building RISC-V program ${name}")
    add_custom_target(${name} ALL DEPENDS ${out}.elf ${out}.mem)
endfunction()
