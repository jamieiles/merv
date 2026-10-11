// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// F mode state must be inaccessible from M mode: the F-RAM window decodes to
// the bus (an access fault), F CSRs and fret are illegal.
#include "test.h"

    .text
test_main:
    // Loads/stores/AMOs to the F-RAM window are access faults.
    TEST 2
    lw      a0, 0(zero)
    CHECK_TRAP 5
    CHECK s10, 0
    TEST 3
    li      a1, 0x100
    sw      a1, 0(a1)
    CHECK_TRAP 7
    CHECK s10, 0x100
    TEST 4
    li      a1, 0x40
    amoadd.w a0, a1, (a1)
    CHECK_TRAP 7
    TEST 5
    li      a1, 0x80
    lr.w    a0, (a1)
    CHECK_TRAP 5

    // Instruction fetch from the F-RAM window is an access fault.
    TEST 6
    la      s8, 1f
    jr      zero
1:  CHECK_TRAP 1
    CHECK s10, 0

    // F mode CSRs and fret are illegal outside of F mode.
    TEST 7
    csrr    a0, 0x7c0
    CHECK_TRAP 2
    TEST 8
    li      a0, 0x12345000
    csrw    0x7c9, a0
    CHECK_TRAP 2
    TEST 9
    csrw    0x7ca, a0
    CHECK_TRAP 2
    TEST 10
    csrr    a0, 0x7c8
    CHECK_TRAP 2
    TEST 11
fret_insn:
    .word   0xf0200073
    CHECK_TRAP 2
    la      t0, fret_insn
    lw      t0, 0(t0)
    bne     s10, t0, fail

    // The F GPR bank is separate, M mode registers are unaffected by F mode
    // events (a CSR emulation trap).
    TEST 12
    li      a0, 0x11111111
    li      a7, 0x77777777
    li      sp, 0x22222222
    csrr    a1, misa
    CHECK_NO_TRAP
    CHECK a0, 0x11111111
    CHECK a7, 0x77777777
    CHECK sp, 0x22222222

    j       pass
