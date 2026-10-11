add_riscv_elf(sim-bootrom
    LINKER_SCRIPT bootrom.ld
    MARCH rv32ima_zicsr
    SOURCES entry.S)
