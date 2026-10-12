// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// SMP: run with --harts 4.  Every hart starts at _start, checks mhartid,
// then increments shared counters with AMOs and with LR/SC loops.  Hart 0
// checks the totals (and that the other harts' stores made SCs fail), then
// sends each of the others an IPI through the CLINT.
#include "test.h"

#define NHARTS     4
#define ITERS      200
#define CLINT_MSIP 0xf0000000
#define MIP_MSIP   (1 << 3)

    .text
test_main:
    csrr    a0, mhartid
    li      t0, NHARTS
    bgeu    a0, t0, fail
    la      t0, present
    slli    t1, a0, 2
    add     t0, t0, t1
    sw      a0, 0(t0)

    // Shared counter with AMOs.
    la      a1, amo_count
    li      t1, ITERS
1:  li      t2, 1
    amoadd.w zero, t2, (a1)
    addi    t1, t1, -1
    bnez    t1, 1b

    // Shared counter with LR/SC, counting the failed SCs.
    la      a1, sc_count
    la      a2, sc_fails
    li      t1, ITERS
2:  lr.w    t2, (a1)
    addi    t2, t2, 1
    sc.w    t3, t2, (a1)
    beqz    t3, 3f
    li      t4, 1
    amoadd.w zero, t4, (a2)
    j       2b
3:  addi    t1, t1, -1
    bnez    t1, 2b

    la      a1, done
    li      t2, 1
    amoadd.w zero, t2, (a1)
    bnez    a0, secondary

    TEST 2
    li      t0, NHARTS
1:  lw      t2, (a1)
    bne     t2, t0, 1b

    // Every hart ran with its own ID.
    TEST 3
    la      t0, present
    li      t1, 0
1:  lw      t2, 0(t0)
    bne     t2, t1, fail
    addi    t0, t0, 4
    addi    t1, t1, 1
    li      t3, NHARTS
    bne     t1, t3, 1b

    TEST 4
    lw      t0, amo_count
    CHECK t0, NHARTS * ITERS
    lw      t0, sc_count
    CHECK t0, NHARTS * ITERS
    lw      t0, sc_fails
    beqz    t0, fail

    // IPIs: each other hart sees its msip, clears it and acknowledges.
    TEST 5
    csrr    t0, mip
    andi    t0, t0, MIP_MSIP
    bnez    t0, fail
    li      t0, CLINT_MSIP + 4
    li      t1, 1
    li      t2, NHARTS - 1
1:  sw      t1, 0(t0)
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    csrr    t0, mip
    andi    t0, t0, MIP_MSIP
    bnez    t0, fail
    la      a1, ack
    li      t0, NHARTS - 1
1:  lw      t2, (a1)
    bne     t2, t0, 1b
    li      t0, CLINT_MSIP + 4
    li      t2, NHARTS - 1
1:  lw      t1, 0(t0)
    bnez    t1, fail
    addi    t0, t0, 4
    addi    t2, t2, -1
    bnez    t2, 1b
    j       pass

secondary:
1:  csrr    t0, mip
    andi    t0, t0, MIP_MSIP
    beqz    t0, 1b
    li      t1, CLINT_MSIP
    slli    t2, a0, 2
    add     t1, t1, t2
    sw      zero, 0(t1)
1:  csrr    t0, mip
    andi    t0, t0, MIP_MSIP
    bnez    t0, 1b
    la      a1, ack
    li      t2, 1
    amoadd.w zero, t2, (a1)
1:  j       1b

    .data
    .align 2
present:    .word -1, -1, -1, -1
amo_count:  .word 0
    // Separate words so the LR/SC loop only contends with itself.
    .align 4
sc_count:   .word 0
    .align 4
sc_fails:   .word 0
done:       .word 0
ack:        .word 0
