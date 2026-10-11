# Arty S7 boot ROM: loads OpenSBI, the Linux kernel and the device tree from
# the SD card into DRAM.
set(BOOTROM_COMMON ../../common/bootrom)
add_riscv_elf(bootrom
    LINKER_SCRIPT bootrom.x
    MARCH rv32ima_zicsr_zifencei
    SOURCES ${BOOTROM_COMMON}/entry.S
            ${BOOTROM_COMMON}/disk.c
            ${BOOTROM_COMMON}/fat.c
            ${BOOTROM_COMMON}/root.c
            ${BOOTROM_COMMON}/printk.c
            ${BOOTROM_COMMON}/sdhci.c
            ${BOOTROM_COMMON}/tinflate.c
            ${BOOTROM_COMMON}/progress.c
            ${BOOTROM_COMMON}/string.c
            uart.c
    INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/${BOOTROM_COMMON}
    CFLAGS -std=gnu99 -Wno-unused-parameter -Wno-sign-compare)
