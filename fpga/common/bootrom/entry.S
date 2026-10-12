#include "board.h"

	.align	4
	.section ".text.head", "ax"
.globl _start
_start:
	/*
	 * Only hart 0 boots, the others wait without touching memory (the
	 * stack is shared and DRAM may hold stale data from before a reset)
	 * until hart 0 has loaded the payload and sets their msip, then enter
	 * it with a0 = hartid and a1 = the device tree, as hart 0 does.
	 */
	csrr	a0, mhartid
	bnez	a0, secondary
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

secondary:
	li	t0, CLINT_BASE
	slli	t1, a0, 2
	add	t0, t0, t1
	li	t1, MIP_MSIP
	csrs	mie, t1
1:	wfi
	lw	t1, 0(t0)
	beqz	t1, 1b
	sw	zero, 0(t0)
	li	a1, PAYLOAD_DTB
	li	t0, PAYLOAD_ENTRY
	jr	t0
