// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Minimal environment for directed tests run with merv-sim --compliance.
// Tests start in M mode at _start.  gp holds the current test number and is
// reported through tohost on failure.
//
// The M mode trap handler records mcause in s11 and mtval in s10 and then:
//   - for ECALLs, returns to the M mode address in s9 (staying in M mode),
//   - for instruction access/page faults, resumes at s8 in the faulting mode,
//   - otherwise skips the faulting instruction.
// Tests must not use t6 or s8-s11 for anything else.

#define MSTATUS_MPP_S (1 << 11)
#define MSTATUS_MPP   (3 << 11)
#define MSTATUS_MPRV  (1 << 17)
#define MSTATUS_SUM   (1 << 18)
#define MSTATUS_MXR   (1 << 19)

#define NO_TRAP 0xffffffff

    .macro TEST n
    li      gp, \n
    li      s11, NO_TRAP
    .endm

    // Fail unless reg == val.
    .macro CHECK reg, val
    li      t5, \val
    bne     \reg, t5, fail
    .endm

    // Fail unless the last trap had the given cause.
    .macro CHECK_TRAP cause
    li      t5, \cause
    bne     s11, t5, fail
    .endm

    .macro CHECK_NO_TRAP
    li      t5, NO_TRAP
    bne     s11, t5, fail
    .endm

    // Drop from M to the given mode (MPP value) at label.
    .macro ENTER_MODE mpp, label
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, \mpp
    csrs    mstatus, t0
    la      t0, \label
    csrw    mepc, t0
    mret
    .endm

    // From S/U: return to M mode at label.
    .macro RETURN_TO_M label
    la      s9, \label
    ecall
    .endm

    .section .text.init, "ax"
    .global _start
_start:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      s11, NO_TRAP
    j       test_main

    .align 2
trap_handler:
    csrr    s11, mcause
    csrr    s10, mtval
    li      t6, 8
    beq     s11, t6, 1f
    li      t6, 9
    beq     s11, t6, 1f
    li      t6, 1
    beq     s11, t6, 2f
    li      t6, 12
    beq     s11, t6, 2f
    csrr    t6, mepc
    addi    t6, t6, 4
    csrw    mepc, t6
    mret
1:  li      s11, NO_TRAP
    jr      s9
2:  csrw    mepc, s8
    mret

pass:
    li      t0, 1
    la      t1, tohost
    sw      t0, 0(t1)
1:  j       1b

fail:
    slli    t0, gp, 1
    ori     t0, t0, 1
    la      t1, tohost
    sw      t0, 0(t1)
1:  j       1b

    .section .tohost, "aw", @progbits
    .align 6
    .global tohost
tohost: .word 0
    .align 6
