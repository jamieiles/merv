// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// mip.SEIP is the OR of the S external interrupt and a software bit.  A CSR
// instruction that writes mip must only read back the software bit, otherwise
// clearing another bit (OpenSBI's csrc mip, STIP) latches a pending external
// interrupt into the software bit forever.
//
// The external interrupt is the UART transmitter empty interrupt (a level
// source) routed through the PLIC to the S context.
#include "test.h"

#define PLIC_BASE   0xf8000000
#define PLIC_PRIO1  (PLIC_BASE + 4)
#define PLIC_S_EN   (PLIC_BASE + 0x2080)
#define PLIC_S_THR  (PLIC_BASE + 0x201000)
#define UART_IER    (0xffff1000 + 4)
#define MIP_STIP    (1 << 5)
#define MIP_SEIP    (1 << 9)

    .text
test_main:
    // Interrupts stay disabled: mstatus.MIE/SIE are clear and mie is 0.
    csrw    mie, zero

    // Raise the S external interrupt.
    TEST 2
    li      t0, PLIC_PRIO1
    li      t1, 1
    sw      t1, 0(t0)
    li      t0, PLIC_S_THR
    sw      zero, 0(t0)
    li      t0, PLIC_S_EN
    li      t1, 1 << 1
    sw      t1, 0(t0)
    li      t0, UART_IER
    li      t1, 2
    sw      t1, 0(t0)
    li      t1, 100
1:  csrr    a0, mip
    andi    a0, a0, MIP_SEIP
    bnez    a0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
    j       fail
2:

    // Clearing STIP (and a csrrs that sets nothing) must not latch SEIP.
    TEST 3
    li      t0, MIP_STIP
    csrc    mip, t0
    li      t0, MIP_STIP
    csrs    mip, t0
    csrc    mip, t0

    // Drop the external interrupt: SEIP reads as clear.
    TEST 4
    li      t0, PLIC_S_EN
    sw      zero, 0(t0)
    li      t1, 100
1:  csrr    a0, mip
    andi    a0, a0, MIP_SEIP
    beqz    a0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
    j       fail
2:

    // The software bit is still writable.
    TEST 5
    li      t0, MIP_SEIP
    csrs    mip, t0
    csrr    a0, mip
    andi    a0, a0, MIP_SEIP
    CHECK a0, MIP_SEIP
    csrc    mip, t0
    csrr    a0, mip
    andi    a0, a0, MIP_SEIP
    CHECK a0, 0

    li      t0, UART_IER
    sw      zero, 0(t0)
    CHECK_NO_TRAP
    j       pass
