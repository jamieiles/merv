# The F mode firmware must not use the M extension so that it works with
# HW_DIV=0, and must not use AMOs so that it works with NATIVE_AMO=0.
add_riscv_elf(ffw
    LINKER_SCRIPT ffw.ld
    MARCH rv32ia_zicsr
    SOURCES entry.S ffw.c
    CFLAGS -msmall-data-limit=8 -ffixed-s3 -ffixed-s4 -ffixed-s5 -ffixed-s6 -ffixed-s7
           -ffixed-s8 -ffixed-s10 -ffixed-s11)
set(MERV_FFW_ELF ${CMAKE_CURRENT_BINARY_DIR}/ffw.elf CACHE INTERNAL "")
