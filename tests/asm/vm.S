// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Sv32 translation through the F mode page table walker: permission checks,
// megapages, Svade A/D handling and walker faults.
#include "test.h"

#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_U 0x10
#define PTE_A 0x40
#define PTE_D 0x80
#define RWAD  (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D)

// t0 = PTE for physical address in \pa with \flags.
    .macro MKPTE pa, flags
    srli    t0, \pa, 12
    slli    t0, t0, 10
    ori     t0, t0, \flags
    .endm

    .text
test_main:
    la      a0, pt_root
    la      a1, pt_l0
    la      a2, data_page
    la      a3, code_x_page

    // VA 0x80000000: identity megapage for the test itself.
    li      t1, 0x80000000
    MKPTE   t1, (RWAD | PTE_X)
    addi    t1, a0, 0x400
    sw      t0, 0x400(t1)
    // VA 0x40000000: second level table.
    MKPTE   a1, PTE_V
    sw      t0, 0x400(a0)
    // VA 0x40400000: misaligned megapage.
    li      t1, 0x80001000
    MKPTE   t1, RWAD
    sw      t0, 0x404(a0)
    // VA 0x40800000: pointer to a second level table in the F-RAM range.
    li      t0, PTE_V
    sw      t0, 0x408(a0)
    // VA 0x40c00000: megapage to PA 0x80400000.
    li      t1, 0x80400000
    MKPTE   t1, RWAD
    sw      t0, 0x40c(a0)
    // VA 0x41000000: megapage beyond 32-bit physical addresses.
    li      t0, (0x100000 << 10) | RWAD
    sw      t0, 0x410(a0)

    // Second level entries.
    MKPTE   a2, RWAD
    sw      t0, 0(a1)                       // 0x40000000 RW
    MKPTE   a2, (PTE_V | PTE_R | PTE_W | PTE_A)
    sw      t0, 4(a1)                       // 0x40001000 RW, D=0
    MKPTE   a2, (PTE_V | PTE_R | PTE_W | PTE_D)
    sw      t0, 8(a1)                       // 0x40002000 RW, A=0
    MKPTE   a2, (PTE_R | PTE_W | PTE_A | PTE_D)
    sw      t0, 12(a1)                      // 0x40003000 invalid
    MKPTE   a2, (RWAD | PTE_U)
    sw      t0, 16(a1)                      // 0x40004000 user
    MKPTE   a3, (PTE_V | PTE_X | PTE_A)
    sw      t0, 20(a1)                      // 0x40005000 execute only
    li      t0, RWAD
    sw      t0, 24(a1)                      // 0x40006000 -> PA 0 (F-RAM range)
    MKPTE   a2, RWAD
    sw      t0, 28(a1)                      // 0x40007000 RW, remapped later
    la      t1, data_page2
    li      t0, 0x4242
    sw      t0, 0(t1)
    // 0x40010000-0x4001f000: 16 RW pages to evict TLB entries.
    MKPTE   a2, RWAD
    addi    t1, a1, 0x40
    addi    t2, a1, 0x80
1:  sw      t0, 0(t1)
    addi    t1, t1, 4
    bne     t1, t2, 1b

    li      t0, 0x1234
    sw      t0, 0(a2)

    srli    t0, a0, 12
    li      t1, 0x80000000
    or      t0, t0, t1
    csrw    satp, t0
    sfence.vma
    ENTER_MODE MSTATUS_MPP_S, s_tests

s_tests:
    TEST 2
    li      s0, 0x40000000
    lw      a0, 0(s0)
    CHECK_NO_TRAP
    CHECK a0, 0x1234

    // Clean page: loads are fine, stores fault (Svade).
    TEST 3
    li      s0, 0x40001000
    lw      a0, 0(s0)
    CHECK_NO_TRAP
    CHECK a0, 0x1234
    sw      a0, 4(s0)
    CHECK_TRAP 15
    addi    t0, s0, 4
    bne     s10, t0, fail

    // Not accessed (Svade) and invalid.
    TEST 4
    li      s0, 0x40002000
    lw      a0, 0(s0)
    CHECK_TRAP 13
    CHECK s10, 0x40002000
    TEST 5
    li      s0, 0x40003000
    lw      a0, 0(s0)
    CHECK_TRAP 13

    // User page from S mode needs SUM.
    TEST 6
    li      s0, 0x40004000
    lw      a0, 0(s0)
    CHECK_TRAP 13
    li      s11, NO_TRAP
    li      t0, MSTATUS_SUM
    csrs    sstatus, t0
    lw      a0, 0(s0)
    CHECK_NO_TRAP
    CHECK a0, 0x1234
    li      t0, MSTATUS_SUM
    csrc    sstatus, t0

    // Execute-only page is readable with MXR.
    TEST 7
    li      s0, 0x40005000
    lw      a0, 0(s0)
    CHECK_TRAP 13
    li      s11, NO_TRAP
    li      t0, MSTATUS_MXR
    csrs    sstatus, t0
    lw      a0, 0(s0)
    CHECK_NO_TRAP
    li      t0, MSTATUS_MXR
    csrc    sstatus, t0
    // ... and executable.
    la      s8, 1f
    jalr    s0
1:  CHECK_NO_TRAP
    CHECK a0, 0x5a5a

    // A translation to PA 0 goes to the bus, not the F-RAM.
    TEST 8
    li      s0, 0x40006000
    lw      a0, 0(s0)
    CHECK_TRAP 5

    // Misaligned megapage.
    TEST 9
    li      s0, 0x40400000
    lw      a0, 0(s0)
    CHECK_TRAP 13

    // The walker never reads page tables from the F-RAM range.
    TEST 10
    li      s0, 0x40800000
    lw      a0, 0(s0)
    CHECK_TRAP 5
    li      s11, NO_TRAP
    sw      a0, 0(s0)
    CHECK_TRAP 7

    // Megapage translation.
    TEST 11
    li      s0, 0x40c01234
    li      t0, 0xabcd
    sw      t0, 0(s0)
    CHECK_NO_TRAP

    // Physical address above 4GB.
    TEST 12
    li      s0, 0x41000000
    lw      a0, 0(s0)
    CHECK_TRAP 5

    // AMOs and LR are translated and permission checked.
    TEST 13
    li      s0, 0x40000000
    li      t0, 1
    amoadd.w a0, t0, (s0)
    CHECK_NO_TRAP
    CHECK a0, 0x1234
    lw      a0, 0(s0)
    CHECK a0, 0x1235
    li      s0, 0x40001000
    amoswap.w a0, t0, (s0)
    CHECK_TRAP 15
    TEST 14
    li      s0, 0x40002000
    lr.w    a0, (s0)
    CHECK_TRAP 13
    TEST 15
    li      s0, 0x40000000
    lr.w    a0, (s0)
    li      t0, 0x99
    sc.w    a1, t0, (s0)
    CHECK a1, 0
    lw      a0, 0(s0)
    CHECK a0, 0x99

    // Fetch from a non-executable page.
    TEST 16
    la      s8, 1f
    li      s0, 0x40000000
    jr      s0
1:  CHECK_TRAP 12
    CHECK s10, 0x40000000

    // Svade: setting D and flushing allows the store.
    TEST 17
    la      a1, pt_l0
    lw      t0, 4(a1)
    ori     t0, t0, PTE_D
    sw      t0, 4(a1)
    sfence.vma
    li      s0, 0x40001000
    li      t0, 0x77
    sw      t0, 8(s0)
    CHECK_NO_TRAP

    // Lots of pages to force TLB replacement.
    TEST 18
    li      s0, 0x40000000
    li      s1, 0x40c00000
    li      s2, 0x40001000
    li      t1, 64
1:  lw      a0, 0(s0)
    lw      a0, 0(s1)
    lw      a0, 0(s2)
    addi    s1, s1, 0x400
    addi    t1, t1, -1
    bnez    t1, 1b
    CHECK_NO_TRAP

    // A remapped page is seen after sfence.vma: the firmware's second level
    // TLB must not return the old translation.
    TEST 21
    li      s0, 0x40007000
    lw      a0, 0(s0)
    CHECK a0, 0x99
    // Evict it from the hardware TLB, the next access refills from the
    // second level TLB.
    li      s1, 0x40c00000
    lw      a1, 0(s1)
    lw      a1, 0x400(s1)
    li      s2, 0x40000000
    lw      a1, 0(s2)
    lw      a1, 0(s1)
    lw      a1, 0(s2)
    lw      a0, 0(s0)
    CHECK a0, 0x99
    la      a1, pt_l0
    la      a3, data_page2
    MKPTE   a3, RWAD
    sw      t0, 28(a1)
    sfence.vma
    lw      a0, 0(s0)
    CHECK a0, 0x4242
    CHECK_NO_TRAP

    // sfence.vma with an address while the translation is in the TLB.
    TEST 22
    li      s0, 0x40007000
    lw      a0, 0(s0)
    CHECK a0, 0x4242
    la      a1, pt_l0
    la      a3, data_page
    MKPTE   a3, RWAD
    sw      t0, 28(a1)
    sfence.vma s0
    lw      a0, 0(s0)
    CHECK a0, 0x99

    // ...and when it has been evicted to the firmware's second level TLB.
    TEST 23
    call    evict_tlb
    la      a1, pt_l0
    la      a3, data_page2
    MKPTE   a3, RWAD
    sw      t0, 28(a1)
    li      t1, 0x40007abc
    sfence.vma t1
    lw      a0, 0(s0)
    CHECK a0, 0x4242
    CHECK_NO_TRAP

    // A megapage remapped and flushed by an address in a different 4KB page
    // of the megapage to the ones accessed.
    TEST 24
    li      s1, 0x40c00000
    lw      a0, 0(s1)
    lw      a0, 0x400(s1)
    call    evict_tlb
    lw      a0, 0(s1)
    la      a1, pt_root
    li      t1, 0x80000000
    MKPTE   t1, RWAD
    sw      t0, 0x40c(a1)
    li      t1, 0x40c01000
    sfence.vma t1
    la      t1, data_page2
    li      t2, 0x003fffff
    and     t1, t1, t2
    add     t1, t1, s1
    lw      a0, 0(t1)
    CHECK a0, 0x4242
    // Restore for the physical checks in M mode.
    li      t1, 0x80400000
    MKPTE   t1, RWAD
    la      a1, pt_root
    sw      t0, 0x40c(a1)
    sfence.vma s1
    CHECK_NO_TRAP

    RETURN_TO_M m_checks

// Touch 16 pages to evict every TLB entry but the code's.
evict_tlb:
    li      t1, 0x40010000
    li      t2, 0x40020000
    li      t3, 0x1000
1:  lw      t4, 0(t1)
    add     t1, t1, t3
    bne     t1, t2, 1b
    ret

m_checks:
    // MPRV translates M mode loads/stores with MPP.
    TEST 19
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPRV | MSTATUS_MPP_S
    csrs    mstatus, t0
    li      s0, 0x40000000
    lw      a0, 0(s0)
    CHECK_NO_TRAP
    CHECK a0, 0x99
    li      s0, 0x40003000
    lw      a0, 0(s0)
    CHECK_TRAP 13
    li      t0, MSTATUS_MPRV
    csrc    mstatus, t0

    // Check the physical results.
    TEST 20
    csrw    satp, zero
    la      a2, data_page
    lw      a0, 8(a2)
    CHECK a0, 0x77
    li      t0, 0x80401234
    lw      a0, 0(t0)
    CHECK a0, 0xabcd

    j       pass

    .section .text.xpage, "ax"
    .align 12
code_x_page:
    li      a0, 0x5a5a
    ret

    .data
    .align 12
pt_root:
    .fill 1024, 4, 0
pt_l0:
    .fill 1024, 4, 0
data_page:
    .fill 1024, 4, 0
data_page2:
    .fill 1024, 4, 0
