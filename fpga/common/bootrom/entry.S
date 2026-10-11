	.align	4
	.section ".text.head", "ax"
.globl _start
_start:
	la	sp, stack_top
	la	s1, _bss_start
	la	s2, _bss_end
bss_loop:
	beq	s1, s2, bss_done
	sw	x0, 0(s1)
	addi	s1, s1, 4
	j	bss_loop
bss_done:
	call	root
end:
	j	end
