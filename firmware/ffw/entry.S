// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// F mode entry points.  TLB misses enter at 0x4, reset and every other event
// at 0x0, with fcause describing the event.  The F mode GPR bank persists
// between events so the stack and global pointers and the constants below
// only need initializing on reset.
//
// TLB misses are by far the most frequent event so the common case of a
// valid, accessed, aligned leaf is handled here without touching memory
// other than the PTEs.  Anything unusual (faults, bus errors, PTEs within the
// F-RAM range) is handed to the C walker which repeats the walk and reports
// the fault.  A bus error reading a PTE returns zero which is an invalid PTE
// so needs no explicit check here, fstatus.BERR remains set for the C walker.
//
// Before walking, a miss looks in a second level TLB kept in the F-RAM: two
// direct mapped tables of {ftlbhi | epoch << 4, ftlblo} pairs, L2_ENTRIES for
// 4KB pages indexed by the VPN and L2_MEGA_ENTRIES for megapages indexed by
// VPN[1].  Each translation lives in exactly one entry so an sfence.vma with
// an address (ftval non-zero) only needs to clear the two entries for that
// address.  An sfence.vma of everything invalidates the whole table by
// incrementing the epoch so that older entries no longer match, the table is
// only cleared when the epoch wraps.
//
// Shifts are iterative in the core so the fast path uses masks held in
// reserved registers instead (the C code is compiled with -ffixed for each):
//
//   s3   0x00000ffc     VPN[0] word offset mask
//   s4   0x000ffc00     megapage PTE PPN[0] (must be zero)
//   s5   0xc0000000     PTE PPN bits above 32-bit physical addresses
//   s6   epoch << 4 | 1 the L2 tag bits for the current epoch
//   s7   0xfffff000     page mask
//   s8   &l2_tlb[L2_MEGA_ENTRIES], the first 4KB entry, the megapage
//        entries are below it
//   s10  TLB replacement index
//   s11  number of TLB entries

#include "ffw.h"

#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_A 0x40
#define PTE_D 0x80

#define MEGA_OFF (-L2_MEGA_ENTRIES * 8)

    .section .text.entry, "ax"
    .global _start, tlb_miss
_start:
    j       event

    // 0x4: TLB miss, a1 = va.
tlb_miss:
    csrr    a1, CSR_FTVAL
    // 4KB entry: a2 = &l2_tlb[L2_MEGA_ENTRIES + vpn % L2_ENTRIES].
    srli    t1, a1, 9
    andi    t1, t1, (L2_ENTRIES - 1) << 3
    add     a2, s8, t1
    lw      t3, 0(a2)
    and     t4, a1, s7
    or      t4, t4, s6
    bne     t3, t4, l2_mega
    lw      t4, 4(a2)
    // Fill from ftlbhi in t3 and ftlblo in t4.
fill:
    csrw    CSR_FTLBIDX, s10
    addi    s10, s10, 1
    bne     s10, s11, 1f
    li      s10, 0
1:  csrw    CSR_FTLBHI, t3
    csrw    CSR_FTLBLO, t4
    fret

    // Megapage entry: a3 = &l2_tlb[vpn[1] % L2_MEGA_ENTRIES] - MEGA_OFF.
l2_mega:
    srli    t1, a1, 19
    andi    t1, t1, (L2_MEGA_ENTRIES - 1) << 3
    add     a3, s8, t1
    lw      t3, MEGA_OFF(a3)
    lui     t4, 0xffc00
    and     t4, a1, t4
    or      t4, t4, s6
    ori     t4, t4, 2
    bne     t3, t4, walk
    lw      t4, MEGA_OFF + 4(a3)
    j       fill

walk:
    csrr    t0, CSR_SATP
    // Root table above 4GB.
    srli    t1, t0, 20
    andi    t1, t1, 3
    bnez    t1, slow
    // Level 1 PTE.
    slli    t1, t0, 12
    srli    t2, a1, 20
    andi    t2, t2, ~3
    add     t1, t1, t2
    li      t3, FRAM_SIZE
    bltu    t1, t3, slow
    lw      t2, 0(t1)
    andi    t4, t2, PTE_V
    beqz    t4, slow
    andi    t4, t2, PTE_R | PTE_X
    bnez    t4, 1f

    // Pointer to a level 0 table.
    and     t4, t2, s5
    bnez    t4, slow
    slli    t1, t2, 2
    and     t1, t1, s7
    srli    t4, a1, 10
    and     t4, t4, s3
    add     t1, t1, t4
    bltu    t1, t3, slow
    lw      t2, 0(t1)
    andi    t4, t2, PTE_V
    beqz    t4, slow
    andi    t4, t2, PTE_R | PTE_X
    beqz    t4, slow
    li      t5, 1
    j       2f

    // Megapage, must be aligned.
1:  and     t4, t2, s4
    bnez    t4, slow
    li      t5, 3

    // Leaf in t2, ftlbhi V/SUPER bits in t5.
2:  andi    t4, t2, PTE_R | PTE_W
    li      t6, PTE_W
    beq     t4, t6, slow
    andi    t4, t2, PTE_A
    beqz    t4, slow
    and     t4, t2, s5
    bnez    t4, slow

    // Permissions, clear W for clean pages (Svade).
    srli    t3, t2, 1
    andi    t3, t3, 0xf
    andi    t4, t2, PTE_D
    bnez    t4, 3f
    andi    t3, t3, ~2
3:  slli    t4, t2, 2
    and     t4, t4, s7
    or      t3, t3, t4

    and     a1, a1, s7
    or      a1, a1, t5

    csrw    CSR_FTLBIDX, s10
    addi    s10, s10, 1
    bne     s10, s11, 4f
    li      s10, 0
4:  csrw    CSR_FTLBHI, a1
    csrw    CSR_FTLBLO, t3
    // Insert into the second level TLB.
    li      t6, 3
    beq     t5, t6, 5f
    or      a1, a1, s6
    sw      a1, 0(a2)
    sw      t3, 4(a2)
    fret
5:  lui     t4, 0xffc00
    and     a1, a1, t4
    or      a1, a1, s6
    ori     a1, a1, 2
    sw      a1, MEGA_OFF(a3)
    sw      t3, MEGA_OFF + 4(a3)
    fret

slow:
    csrr    a0, CSR_FCAUSE
    call    ffw_event
    fret

    // 0x0: everything but TLB misses.
event:
    csrr    a0, CSR_FCAUSE
    beqz    a0, reset
    li      t0, FCAUSE_SFENCE
    bne     a0, t0, 2f
    // sfence.vma: the hardware has invalidated the TLB entries.  With an
    // address clear its second level entries, otherwise move to a new epoch.
    csrr    t0, CSR_FTVAL
    beqz    t0, 1f
    srli    t1, t0, 9
    andi    t1, t1, (L2_ENTRIES - 1) << 3
    add     t1, s8, t1
    sw      zero, 0(t1)
    srli    t1, t0, 19
    andi    t1, t1, (L2_MEGA_ENTRIES - 1) << 3
    add     t1, s8, t1
    sw      zero, MEGA_OFF(t1)
    fret
1:  addi    s6, s6, 1 << 4
    andi    t0, s6, L2_EPOCH_MASK << 4
    bnez    t0, 3f
    call    l2_tlb_clear
3:  fret
2:
    call    ffw_event
    fret

reset:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, _stack_top
    li      s3, 0x00000ffc
    li      s4, 0x000ffc00
    li      s5, 0xc0000000
    li      s7, 0xfffff000
    la      s8, l2_tlb + L2_MEGA_ENTRIES * 8
    li      s10, 0
    csrr    s11, CSR_FCONFIG
    andi    s11, s11, 0xff
    call    ffw_reset
    fret
