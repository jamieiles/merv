// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Simulation boot ROM: enter OpenSBI (fw_jump) in DRAM with the hart ID and
// the address of the preloaded device tree.

#ifndef DTB_ADDR
#define DTB_ADDR 0x83f00000
#endif
#ifndef SBI_ADDR
#define SBI_ADDR 0x80000000
#endif

    .section .text.entry, "ax"
    .global _start
_start:
    li      a0, 0
    li      a1, DTB_ADDR
    li      t0, SBI_ADDR
    jr      t0
