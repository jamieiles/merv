OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* The top 512 bytes of the 8KB F-RAM are the register window. */
    fram (rwx) : ORIGIN = 0x00000000, LENGTH = 8K - 512
}

SECTIONS
{
    .text : {
        KEEP(*(.text.entry))
        *(.text .text.*)
    } > fram
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > fram
    .data : {
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.* .data .data.*)
    } > fram
    .bss (NOLOAD) : { *(.sbss .sbss.* .bss .bss.* COMMON) } > fram
    _end = .;
    _stack_top = ORIGIN(fram) + LENGTH(fram);
    ASSERT(tlb_miss == 0x4, "the TLB miss entry point must be at 0x4")
    ASSERT(_end <= _stack_top - 1024, "F mode firmware leaves less than 1KB of stack")
}
