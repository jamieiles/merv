// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// 32-bit hardware counters with the upper halves maintained by F mode.
#include "test.h"

    .text
// Read the 64-bit cycle counter into a1:a0 with the hi/lo/hi idiom.
read_cycle:
1:  csrr    a1, mcycleh
    csrr    a0, mcycle
    csrr    t0, mcycleh
    bne     a1, t0, 1b
    ret

test_main:
    // mcycle wraps into mcycleh.
    TEST 2
    csrw    mcycleh, zero
    li      t0, -50
    csrw    mcycle, t0
    li      t1, 100
1:  addi    t1, t1, -1
    bnez    t1, 1b
    csrr    a0, mcycleh
    CHECK a0, 1
    // Bounded by the cycles taken to run the loop on any implementation.
    csrr    a0, mcycle
    li      t0, 0x10000
    bgeu    a0, t0, fail

    // minstret wraps into minstreth.
    TEST 3
    csrw    minstreth, zero
    li      t0, -20
    csrw    minstret, t0
    li      t1, 30
1:  addi    t1, t1, -1
    bnez    t1, 1b
    csrr    a0, minstreth
    CHECK a0, 1
    csrr    a0, minstret
    li      t0, 100
    bgeu    a0, t0, fail

    // Writes to the upper halves read back.
    TEST 4
    li      t0, 0x1234
    csrw    mcycleh, t0
    csrr    a0, mcycleh
    CHECK a0, 0x1234

    // A 64-bit read across a wrap is consistent.
    TEST 5
    csrw    mcycleh, zero
    li      t0, -3
    csrw    mcycle, t0
    call    read_cycle
    beqz    a1, 1f
    CHECK a1, 1
    li      t0, 0x10000
    bgeu    a0, t0, fail
    j       2f
1:  li      t0, -3
    bltu    a0, t0, fail
2:

    // cycleh/instreth from U mode follow mcounteren/scounteren.
    TEST 6
    csrw    mcounteren, zero
    csrw    scounteren, zero
    ENTER_MODE 0, 1f
1:  csrr    a0, cycleh
    CHECK_TRAP 2
    li      s11, NO_TRAP
    csrr    a0, cycle
    CHECK_TRAP 2
    RETURN_TO_M 2f
2:  TEST 7
    li      t0, 7
    csrw    mcounteren, t0
    csrw    scounteren, t0
    li      t0, 0x55
    csrw    mcycleh, t0
    ENTER_MODE 0, 1f
1:  csrr    a0, cycleh
    CHECK_NO_TRAP
    CHECK a0, 0x55
    csrr    a0, instreth
    CHECK_NO_TRAP
    csrr    a0, cycle
    CHECK_NO_TRAP
    RETURN_TO_M 2f
2:
    j       pass
