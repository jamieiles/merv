// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#define CSR_FSTATUS  0x7c0
#define CSR_FEPC     0x7c1
#define CSR_FCAUSE   0x7c2
#define CSR_FTVAL    0x7c3
#define CSR_FPADDR   0x7c4
#define CSR_FINJECT  0x7c5
#define CSR_FTLBIDX  0x7c8
#define CSR_FTLBHI   0x7c9
#define CSR_FTLBLO   0x7ca
#define CSR_FBOOTVEC 0x7cb
#define CSR_FCONFIG  0x7cc

#define FSTATUS_PPRV   0x3
#define FSTATUS_BERR   (1 << 2)
#define FSTATUS_CYWRAP (1 << 8)
#define FSTATUS_IRWRAP (1 << 9)
#define FSTATUS_SFPEND (1 << 10)

#define FCAUSE_RESET        0
#define FCAUSE_ITLB_MISS    1
#define FCAUSE_LOAD_MISS    2
#define FCAUSE_STORE_MISS   3
#define FCAUSE_CYCLE_WRAP   4
#define FCAUSE_INSTRET_WRAP 5
#define FCAUSE_EMULATE      6
#define FCAUSE_SFENCE       7

// Second level TLB: 4KB page and megapage entries (powers of two) and the
// epoch (in ftlbhi[10:4]).
#define L2_ENTRIES      256
#define L2_MEGA_ENTRIES 64
#define L2_EPOCH_MASK   0x7f

#define FRAM_SIZE 8192
// The register window at the top of the F-RAM: bank 0 (U/S/M) GPRs, bank 1
// (F) GPRs then the RAM based CSRs (reserved).
#define FRAM_REGS 0x1e00

#define CSR_SATP       0x180
#define CSR_MCOUNTEREN 0x306
#define CSR_SCOUNTEREN 0x106
#define CSR_MINSTRET   0xb02

#ifdef __ASSEMBLER__
#define fret .word 0xf0200073
#else
#include <stdint.h>

#define STR(x)  #x
#define XSTR(x) STR(x)

#define csr_read(csr)                                                   \
    ({                                                                  \
        uint32_t __v;                                                   \
        asm volatile("csrr %0, " XSTR(csr) : "=r"(__v)::"memory");      \
        __v;                                                            \
    })

#define csr_write(csr, val)                                             \
    asm volatile("csrw " XSTR(csr) ", %0" ::"rK"(val) : "memory")

#define csr_read_clear(csr, val)                                        \
    ({                                                                  \
        uint32_t __v;                                                   \
        asm volatile("csrrc %0, " XSTR(csr) ", %1"                      \
                     : "=r"(__v)                                        \
                     : "rK"(val)                                        \
                     : "memory");                                       \
        __v;                                                            \
    })
#endif
