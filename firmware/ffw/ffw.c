// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// F mode firmware: Sv32 page table walks for TLB misses, the upper halves of
// mcycle/minstret, emulation of CSRs that aren't implemented in hardware and
// optionally AMOs, multiplication and division.  See docs/merv-arch.md.

#include <stdint.h>

#include "ffw.h"

#define CLINT_MTIME 0xf000bff8u

#define PTE_V (1u << 0)
#define PTE_R (1u << 1)
#define PTE_W (1u << 2)
#define PTE_X (1u << 3)
#define PTE_U (1u << 4)
#define PTE_A (1u << 6)
#define PTE_D (1u << 7)

#define EXC_INSN_ACCESS  1
#define EXC_ILLEGAL      2
#define EXC_LOAD_ACCESS  5
#define EXC_STORE_ACCESS 7
#define EXC_INSN_PAGE    12
#define EXC_LOAD_PAGE    13
#define EXC_STORE_PAGE   15

static uint32_t cycle_hi;
static uint32_t instret_hi;
// Shared with the TLB miss fast path in entry.S, which also reserves s3-s5,
// s7 and s8 for constants.
register uint32_t l2_tag asm("s6");
register uint32_t tlb_next asm("s10");
register uint32_t tlb_entries asm("s11");

// Second level TLB, {ftlbhi | epoch << 4, ftlblo} pairs: L2_MEGA_ENTRIES
// megapages indexed by VPN[1] then L2_ENTRIES 4KB pages indexed by the VPN.
uint32_t l2_tlb[L2_MEGA_ENTRIES + L2_ENTRIES][2] __attribute__((aligned(8)));

// Called on reset and when the epoch wraps: entries can't match epoch 0 so
// start again at 1.
void l2_tlb_clear(void)
{
    for (uint32_t i = 0; i < L2_MEGA_ENTRIES + L2_ENTRIES; ++i)
        l2_tlb[i][0] = 0;
    l2_tag = (1 << 4) | 1;
}
// Set when an emulated instruction writes minstreth, which like a write to
// minstret suppresses the increment for that instruction.
static int instret_written;

static const uint8_t page_fault_cause[4] = {0, EXC_INSN_PAGE, EXC_LOAD_PAGE,
                                            EXC_STORE_PAGE};
static const uint8_t access_fault_cause[4] = {0, EXC_INSN_ACCESS,
                                              EXC_LOAD_ACCESS,
                                              EXC_STORE_ACCESS};

static inline void inject(uint32_t cause)
{
    csr_write(CSR_FINJECT, 0x80000000u | cause);
}

// Bank 0 GPRs in the F-RAM register window, x0 must never be written.
static inline uint32_t xreg_read(uint32_t r)
{
    return ((volatile uint32_t *)FRAM_REGS)[r];
}

static inline void xreg_write(uint32_t r, uint32_t v)
{
    ((volatile uint32_t *)FRAM_REGS)[r] = v;
}

// Physical accesses outside of the F-RAM: bus errors set fstatus.BERR rather
// than trapping, callers check with bus_error().
static inline uint32_t phys_read(uint32_t pa)
{
    return *(volatile uint32_t *)pa;
}

static inline int bus_error(void)
{
    return (csr_read_clear(CSR_FSTATUS, FSTATUS_BERR) & FSTATUS_BERR) != 0;
}

static inline int in_fram(uint32_t pa)
{
    return pa < FRAM_SIZE;
}

// Fold wraps that happened while in F mode into the upper halves.
static void sync_counters(void)
{
    uint32_t st = csr_read_clear(CSR_FSTATUS, FSTATUS_CYWRAP | FSTATUS_IRWRAP);

    if (st & FSTATUS_CYWRAP)
        ++cycle_hi;
    if (st & FSTATUS_IRWRAP)
        ++instret_hi;
}

static void tlb_invalidate_all(void)
{
    csr_write(CSR_FTLBHI, 0);
    for (uint32_t i = 0; i < tlb_entries; ++i) {
        csr_write(CSR_FTLBIDX, i);
        csr_write(CSR_FTLBLO, 0);
    }
}

void ffw_reset(void)
{
    cycle_hi = 0;
    instret_hi = 0;
    tlb_invalidate_all();
    l2_tlb_clear();

    csr_write(CSR_FINJECT, 0);
    csr_write(CSR_FSTATUS, 3);
    csr_write(CSR_FEPC, csr_read(CSR_FBOOTVEC));
}

static void tlb_miss(uint32_t cause, uint32_t va)
{
    uint32_t satp = csr_read(CSR_SATP);
    uint32_t ppn = satp & 0x3fffff;
    uint32_t super = 0;
    uint32_t pte, a;

    for (int level = 1;; --level) {
        uint32_t vpn = level ? (va >> 22) : ((va >> 12) & 0x3ff);

        if (ppn >> 20)
            goto access_fault;
        a = (ppn << 12) + (vpn << 2);
        if (in_fram(a))
            goto access_fault;
        pte = phys_read(a);
        if (bus_error())
            goto access_fault;

        if (!(pte & PTE_V) || (pte & (PTE_R | PTE_W)) == PTE_W)
            goto page_fault;

        ppn = pte >> 10;
        if (pte & (PTE_R | PTE_X)) {
            if (level) {
                if (ppn & 0x3ff)
                    goto page_fault;
                super = 1;
            }
            break;
        }
        if (!level)
            goto page_fault;
    }

    if (!(pte & PTE_A))
        goto page_fault;
    if (ppn >> 20)
        goto access_fault;

    uint32_t perms = (pte >> 1) & 0xf;
    if (!(pte & PTE_D))
        perms &= ~2u;

    csr_write(CSR_FTLBIDX, tlb_next);
    if (++tlb_next == tlb_entries)
        tlb_next = 0;
    uint32_t hi = (va & 0xfffff000u) | (super << 1) | 1;
    uint32_t lo = (ppn << 12) | perms;
    csr_write(CSR_FTLBHI, hi);
    csr_write(CSR_FTLBLO, lo);
    uint32_t *e;
    if (super) {
        e = l2_tlb[(va >> 22) & (L2_MEGA_ENTRIES - 1)];
        e[0] = (va & 0xffc00000u) | 2 | l2_tag;
    } else {
        e = l2_tlb[L2_MEGA_ENTRIES + ((va >> 12) & (L2_ENTRIES - 1))];
        e[0] = (va & 0xfffff000u) | l2_tag;
    }
    e[1] = lo;
    return;

page_fault:
    inject(page_fault_cause[cause]);
    return;

access_fault:
    inject(access_fault_cause[cause]);
}

static void retire_emulated(void)
{
    csr_write(CSR_FEPC, csr_read(CSR_FEPC) + 4);
    if (instret_written) {
        instret_written = 0;
        return;
    }

    uint32_t v = csr_read(CSR_MINSTRET) + 1;
    csr_write(CSR_MINSTRET, v);
    if (!v)
        ++instret_hi;
}

static uint64_t read_mtime(void)
{
    volatile uint32_t *mtime = (volatile uint32_t *)CLINT_MTIME;
    uint32_t hi, lo;

    do {
        hi = mtime[1];
        lo = mtime[0];
    } while (hi != mtime[1]);

    return ((uint64_t)hi << 32) | lo;
}

// Check mcounteren/scounteren for the user level counter CSRs.
static int counter_enabled(uint32_t addr, uint32_t pprv)
{
    uint32_t bit = 1u << (addr & 31);

    if (pprv < 3 && !(csr_read(CSR_MCOUNTEREN) & bit))
        return 0;
    if (pprv == 0 && !(csr_read(CSR_SCOUNTEREN) & bit))
        return 0;
    return 1;
}

// Returns 0 if the CSR is not implemented.
static int emul_csr_read(uint32_t addr, uint32_t pprv, uint32_t *val)
{
    *val = 0;

    switch (addr) {
    case 0xf14: // mhartid
        *val = csr_read(CSR_FCONFIG) >> 24;
        return 1;
    case 0x301: // misa: RV32 A I M S U
        *val = 0x40000000u | (1u << 0) | (1u << 8) | (1u << 12) |
               (1u << 18) | (1u << 20);
        return 1;
    case 0xf11: // mvendorid
    case 0xf12: // marchid
    case 0xf13: // mimpid
    case 0xf15: // mconfigptr
    case 0x310: // mstatush
    case 0x312: // medelegh
    case 0x30a: // menvcfg
    case 0x31a: // menvcfgh
    case 0x10a: // senvcfg
    case 0x320: // mcountinhibit
    case 0x7a0: // tselect: no triggers
    case 0x7a1: // tdata1
    case 0x7a2: // tdata2
    case 0x7a3: // tdata3
        return 1;
    case 0xb80: // mcycleh
        sync_counters();
        *val = cycle_hi;
        return 1;
    case 0xb82: // minstreth
        sync_counters();
        *val = instret_hi;
        return 1;
    case 0xc80: // cycleh
        if (!counter_enabled(addr, pprv))
            return 0;
        sync_counters();
        *val = cycle_hi;
        return 1;
    case 0xc82: // instreth
        if (!counter_enabled(addr, pprv))
            return 0;
        sync_counters();
        *val = instret_hi;
        return 1;
    case 0xc01: // time
    case 0xc81: { // timeh
        if (!counter_enabled(addr, pprv))
            return 0;
        uint64_t t = read_mtime();
        *val = addr == 0xc01 ? (uint32_t)t : (uint32_t)(t >> 32);
        return 1;
    }
    default: break;
    }

    if ((addr >= 0x3a0 && addr <= 0x3a3) || // pmpcfg0-3
        (addr >= 0x3b0 && addr <= 0x3bf) || // pmpaddr0-15
        (addr >= 0xb03 && addr <= 0xb1f) || // mhpmcounter3-31
        (addr >= 0xb83 && addr <= 0xb9f) || // mhpmcounter3-31h
        (addr >= 0x323 && addr <= 0x33f))   // mhpmevent3-31
        return 1;

    if ((addr >= 0xc03 && addr <= 0xc1f) || // hpmcounter3-31
        (addr >= 0xc83 && addr <= 0xc9f))   // hpmcounter3-31h
        return counter_enabled(addr, pprv);

    return 0;
}

static void emul_csr_write(uint32_t addr, uint32_t val)
{
    switch (addr) {
    case 0xb80:
        sync_counters();
        cycle_hi = val;
        break;
    case 0xb82:
        sync_counters();
        instret_hi = val;
        instret_written = 1;
        break;
    default: break;
    }
}

static int emulate_csr(uint32_t insn)
{
    uint32_t f3 = (insn >> 12) & 7;
    uint32_t op = f3 & 3;
    uint32_t rd = (insn >> 7) & 31;
    uint32_t rs1 = (insn >> 15) & 31;
    uint32_t addr = insn >> 20;
    uint32_t pprv = csr_read(CSR_FSTATUS) & FSTATUS_PPRV;
    int write = op == 1 || rs1 != 0;
    uint32_t src, old;

    if (op == 0 || ((addr >> 8) & 3) > pprv)
        return 0;
    if (write && (addr >> 10) == 3)
        return 0;
    if (!emul_csr_read(addr, pprv, &old))
        return 0;

    src = (f3 & 4) ? rs1 : xreg_read(rs1);
    if (write)
        emul_csr_write(addr, op == 1 ? src : op == 2 ? (old | src)
                                                     : (old & ~src));
    if (rd)
        xreg_write(rd, old);

    return 1;
}

static int emulate_amo(uint32_t insn)
{
    uint32_t f5 = insn >> 27;
    uint32_t rd = (insn >> 7) & 31;
    uint32_t b = xreg_read((insn >> 20) & 31);
    uint32_t pa = csr_read(CSR_FPADDR);
    uint32_t old, v, fail;

    if (in_fram(pa)) {
        csr_write(CSR_FTVAL, xreg_read((insn >> 15) & 31));
        inject(EXC_STORE_ACCESS);
        return 1;
    }

    do {
        asm volatile("lr.w %0, (%1)" : "=r"(old) : "r"(pa) : "memory");
        switch (f5) {
        case 0x00: v = old + b; break;
        case 0x01: v = b; break;
        case 0x04: v = old ^ b; break;
        case 0x08: v = old | b; break;
        case 0x0c: v = old & b; break;
        case 0x10: v = (int32_t)old < (int32_t)b ? old : b; break;
        case 0x14: v = (int32_t)old > (int32_t)b ? old : b; break;
        case 0x18: v = old < b ? old : b; break;
        case 0x1c: v = old > b ? old : b; break;
        default: return 0;
        }
        asm volatile("sc.w %0, %2, (%1)"
                     : "=r"(fail)
                     : "r"(pa), "r"(v)
                     : "memory");
    } while (fail && !(csr_read(CSR_FSTATUS) & FSTATUS_BERR));

    if (bus_error()) {
        csr_write(CSR_FTVAL, xreg_read((insn >> 15) & 31));
        inject(EXC_STORE_ACCESS);
        return 1;
    }

    if (rd)
        xreg_write(rd, old);
    return 1;
}

static uint32_t udivmod(uint32_t n, uint32_t d, uint32_t *rem)
{
    uint32_t q = 0, r = 0;

    for (int i = 31; i >= 0; --i) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= 1u << i;
        }
    }
    *rem = r;
    return q;
}

static int emulate_div(uint32_t insn)
{
    uint32_t f3 = (insn >> 12) & 7;
    uint32_t rd = (insn >> 7) & 31;
    uint32_t a = xreg_read((insn >> 15) & 31);
    uint32_t b = xreg_read((insn >> 20) & 31);
    uint32_t q, r, v;

    if (b == 0) {
        q = ~0u;
        r = a;
    } else if (f3 & 1) {
        q = udivmod(a, b, &r);
    } else if (a == 0x80000000u && b == ~0u) {
        q = a;
        r = 0;
    } else {
        int na = (int32_t)a < 0, nb = (int32_t)b < 0;
        q = udivmod(na ? -a : a, nb ? -b : b, &r);
        if (na != nb)
            q = -q;
        if (na)
            r = -r;
    }

    v = (f3 & 2) ? r : q;
    if (rd)
        xreg_write(rd, v);
    return 1;
}

// The firmware is built without the M extension: shift and add, iterating
// over the smaller operand.  Single bit shifts and compares avoid the
// iterative shifter.
static uint32_t umul(uint32_t a, uint32_t b, uint32_t *hi)
{
    uint32_t lo = 0, h = 0, ml, mh = 0;

    if (a < b) {
        ml = b;
        b = a;
    } else {
        ml = a;
    }
    while (b) {
        if (b & 1) {
            uint32_t t = lo + ml;
            h += mh + (t < lo);
            lo = t;
        }
        mh = mh + mh + ((int32_t)ml < 0);
        ml += ml;
        b >>= 1;
    }
    *hi = h;
    return lo;
}

static int emulate_mul(uint32_t insn)
{
    uint32_t f3 = (insn >> 12) & 7;
    uint32_t rd = (insn >> 7) & 31;
    uint32_t a = xreg_read((insn >> 15) & 31);
    uint32_t b = xreg_read((insn >> 20) & 31);
    uint32_t lo, hi;

    lo = umul(a, b, &hi);
    // The signed high words from the unsigned product: subtract b << 32 for
    // a negative signed a and a << 32 for a negative signed b.
    if (f3 == 1 || f3 == 2) {
        if ((int32_t)a < 0)
            hi -= b;
        if (f3 == 1 && (int32_t)b < 0)
            hi -= a;
    }

    if (rd)
        xreg_write(rd, f3 ? hi : lo);
    return 1;
}

static void emulate(uint32_t insn)
{
    int ok = 0;

    switch (insn & 0x7f) {
    case 0x73: ok = emulate_csr(insn); break;
    case 0x2f: ok = emulate_amo(insn); break;
    case 0x33:
        if ((insn >> 25) == 1)
            ok = (insn & 0x4000) ? emulate_div(insn) : emulate_mul(insn);
        break;
    default: break;
    }

    if (!ok)
        inject(EXC_ILLEGAL);
    else if (!(csr_read(CSR_FINJECT) & 0x80000000u))
        retire_emulated();
}

void ffw_event(uint32_t cause)
{
    switch (cause) {
    case FCAUSE_ITLB_MISS:
    case FCAUSE_LOAD_MISS:
    case FCAUSE_STORE_MISS: tlb_miss(cause, csr_read(CSR_FTVAL)); break;
    case FCAUSE_CYCLE_WRAP: ++cycle_hi; break;
    case FCAUSE_INSTRET_WRAP: ++instret_hi; break;
    case FCAUSE_EMULATE: emulate(csr_read(CSR_FTVAL)); break;
    default: break;
    }
}
