OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
	rom : ORIGIN = 0x40000000, LENGTH = 64K
	sdram : ORIGIN = 0x80000000, LENGTH = 256M
}

PHDRS {
	text PT_LOAD ;
	data PT_LOAD ;
	bss PT_LOAD ;
}

SECTIONS {
	.text 0x40000000 : AT(0x00000000) {
		*(.text.head);
		*(.text);
		*(.text.*);
	} > rom :text

	.rodata	: {
		*(.rodata);
		*(.rodata.*);
		. = ALIGN(4);
	} > rom :data
	
	.data	: {
		. = ALIGN(16);
		_sdata = . ;
		*(.sdata);
		*(.data);
		*(.data.*);
		_edata = . ;
	} > rom :data

	.bss 0x88000000 : {
		. = . + 16 ;
		_bss_start = . ;
		. = ALIGN(16);
		_bss_start = . ;
		*(.bss);
		*(.sbss);
		*(COMMON);
		_bss_end = . ;
		. = . + 65536 ;
		. = ALIGN(16);
		stack_top =  . ;
		. = . + 65536 ;
		load_scratch = . ;
	} > sdram :bss

	/DISCARD/ : {
		*(.comment);
		*(.debug*);
	}
}
