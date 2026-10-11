// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// CSRs emulated by the F mode firmware.
#include "test.h"

    .text
test_main:
    TEST 2
    csrr    a0, misa
    CHECK a0, 0x40141101
    TEST 3
    csrr    a0, mhartid
    CHECK a0, 0
    csrr    a0, mvendorid
    CHECK a0, 0
    // Writes to misa are ignored.
    csrw    misa, zero
    csrr    a0, misa
    CHECK a0, 0x40141101

    // No PMP.
    TEST 4
    li      t0, -1
    csrw    pmpaddr0, t0
    csrr    a0, pmpaddr0
    CHECK a0, 0
    csrw    pmpcfg0, t0
    csrr    a0, pmpcfg0
    CHECK a0, 0
    CHECK_NO_TRAP

    // Unknown CSRs are illegal with the instruction in mtval.
    TEST 5
unknown_csr:
    csrr    a0, 0x7d0
    CHECK_TRAP 2
    la      t0, unknown_csr
    lw      t0, 0(t0)
    bne     s10, t0, fail

    // Writes to read-only emulated CSRs are illegal.
    TEST 6
    csrw    mhartid, zero
    CHECK_TRAP 2

    // csrrs/csrrc with x0 don't write and the destination gets the old value.
    TEST 7
    li      a0, 0x5a5a
    csrrs   a0, mvendorid, zero
    CHECK a0, 0
    CHECK_NO_TRAP

    // time advances and is read from the CLINT.
    TEST 8
    csrr    a0, time
    li      t1, 1000
1:  addi    t1, t1, -1
    bnez    t1, 1b
    csrr    a1, time
    bgeu    a0, a1, fail
    li      t0, 0xf000bff8
    lw      a2, 0(t0)
    bltu    a2, a1, fail
    csrr    a0, timeh
    CHECK a0, 0

    // time from S mode needs mcounteren.TM, M mode CSRs are illegal.
    TEST 9
    csrw    mcounteren, zero
    ENTER_MODE MSTATUS_MPP_S, 1f
1:  csrr    a0, time
    CHECK_TRAP 2
    li      s11, NO_TRAP
    csrr    a0, misa
    CHECK_TRAP 2
    li      s11, NO_TRAP
    csrw    mcycleh, zero
    CHECK_TRAP 2
    RETURN_TO_M 2f
2:  li      t0, 2
    csrw    mcounteren, t0
    TEST 10
    ENTER_MODE MSTATUS_MPP_S, 1f
1:  csrr    a0, time
    CHECK_NO_TRAP
    // menvcfg reads as zero from M only, senvcfg from S.
    csrr    a0, senvcfg
    CHECK_NO_TRAP
    CHECK a0, 0
    RETURN_TO_M 2f
2:
    // Emulated instructions retire.
    TEST 11
    csrr    a0, minstret
    csrr    a1, misa
    csrr    a2, minstret
    sub     a2, a2, a0
    CHECK a2, 2

    j       pass
