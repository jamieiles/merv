// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <vector>

#include "Bus.h"
#include "Config.h"

enum class Priv : uint8_t { U = 0, S = 1, M = 3, F = 4 };

namespace csr
{
enum : uint16_t {
    sstatus = 0x100,
    sie = 0x104,
    stvec = 0x105,
    scounteren = 0x106,
    sscratch = 0x140,
    sepc = 0x141,
    scause = 0x142,
    stval = 0x143,
    sip = 0x144,
    satp = 0x180,
    mstatus = 0x300,
    medeleg = 0x302,
    mideleg = 0x303,
    mie = 0x304,
    mtvec = 0x305,
    mcounteren = 0x306,
    mscratch = 0x340,
    mepc = 0x341,
    mcause = 0x342,
    mtval = 0x343,
    mip = 0x344,
    fstatus = 0x7c0,
    fepc = 0x7c1,
    fcause = 0x7c2,
    ftval = 0x7c3,
    fpaddr = 0x7c4,
    finject = 0x7c5,
    ftlbidx = 0x7c8,
    ftlbhi = 0x7c9,
    ftlblo = 0x7ca,
    fbootvec = 0x7cb,
    fconfig = 0x7cc,
    mcycle = 0xb00,
    minstret = 0xb02,
    cycle = 0xc00,
    instret = 0xc02,
};
} // namespace csr

namespace fevent
{
enum : uint32_t {
    reset = 0,
    itlb_miss = 1,
    load_tlb_miss = 2,
    store_tlb_miss = 3,
    cycle_wrap = 4,
    instret_wrap = 5,
    emulate = 6,
    sfence = 7,
};
} // namespace fevent

namespace exc
{
enum : uint32_t {
    insn_misaligned = 0,
    insn_access = 1,
    illegal = 2,
    breakpoint = 3,
    load_misaligned = 4,
    load_access = 5,
    store_misaligned = 6,
    store_access = 7,
    ecall_u = 8,
    ecall_s = 9,
    ecall_m = 11,
    insn_page = 12,
    load_page = 13,
    store_page = 15,
};
} // namespace exc

namespace mstatus_bits
{
constexpr uint32_t SIE = 1u << 1;
constexpr uint32_t MIE = 1u << 3;
constexpr uint32_t SPIE = 1u << 5;
constexpr uint32_t MPIE = 1u << 7;
constexpr uint32_t SPP = 1u << 8;
constexpr uint32_t MPP_SHIFT = 11;
constexpr uint32_t MPP = 3u << 11;
constexpr uint32_t MPRV = 1u << 17;
constexpr uint32_t SUM = 1u << 18;
constexpr uint32_t MXR = 1u << 19;
constexpr uint32_t TVM = 1u << 20;
constexpr uint32_t TW = 1u << 21;
constexpr uint32_t TSR = 1u << 22;
} // namespace mstatus_bits

namespace fstatus_bits
{
constexpr uint32_t PPRV = 3u << 0;
constexpr uint32_t BERR = 1u << 2;
constexpr uint32_t CYWRAP = 1u << 8;
constexpr uint32_t IRWRAP = 1u << 9;
constexpr uint32_t SFPEND = 1u << 10;
} // namespace fstatus_bits

constexpr uint32_t fret_insn = 0xf0200073;

struct TlbEntry {
    bool valid = false;
    bool super = false;
    uint32_t vpn = 0;
    uint32_t ppn = 0;
    bool r = false, w = false, x = false, u = false;
};

// Per-step record of what happened, used for tracing and co-simulation.
struct StepInfo {
    uint32_t pc;
    uint32_t insn;
    Priv priv;
    bool retired;
    bool rd_written;
    uint8_t rd;
    uint32_t rd_val;
    bool trap;          // M/S trap taken
    bool interrupt;
    uint32_t cause;
    bool fevent;        // F mode event taken
    uint32_t fcause;
    bool mem;
    bool mem_write;
    uint32_t mem_va;
    uint32_t mem_pa;
    uint32_t mem_val;
};

class Hart
{
public:
    Hart(const Config &cfg, Bus &bus);

    void reset();
    void step();

    // Co-simulation: the ISS doesn't take interrupts or counter wrap events
    // itself, they are forced at the points that the RTL takes them.
    void set_cosim(bool v)
    {
        cosim = v;
    }
    void force_interrupt(uint32_t cause);
    void force_fevent(uint32_t cause);

    void set_interrupt_lines(bool meip, bool seip, bool mtip, bool msip)
    {
        ext_irqs = (meip ? (1u << 11) : 0) | (seip ? (1u << 9) : 0) |
                   (mtip ? (1u << 7) : 0) | (msip ? (1u << 3) : 0);
    }

    void load_fram(uint32_t addr, const uint8_t *data, size_t len);

    bool is_halted() const
    {
        return halted;
    }

    const std::string &halt_reason() const
    {
        return halt_msg;
    }

    uint32_t get_pc() const
    {
        return pc;
    }

    Priv get_priv() const
    {
        return priv;
    }

    uint32_t get_reg(unsigned r, bool fbank = false) const
    {
        return gpr[fbank][r & 31];
    }

    void set_reg(unsigned r, uint32_t v, bool fbank = false)
    {
        if (r & 31)
            gpr[fbank][r & 31] = v;
    }

    uint32_t get_mcycle() const
    {
        return mcycle_r;
    }

    void set_mcycle(uint32_t v)
    {
        mcycle_r = v;
    }

    void set_minstret(uint32_t v)
    {
        minstret_r = v;
    }

    const StepInfo &last_step() const
    {
        return info;
    }

    // Host statistics.
    uint64_t steps = 0;
    uint64_t retired_lower = 0;
    uint64_t retired_f = 0;
    std::array<uint64_t, 8> fevent_counts{};

private:
    enum class Access { Fetch, Load, Store };
    enum class CsrStatus { Ok, Illegal, Emulate };

    void execute(uint32_t insn);
    void exec_op(uint32_t insn);
    void exec_op_imm(uint32_t insn);
    void exec_branch(uint32_t insn);
    void exec_load(uint32_t insn);
    void exec_store(uint32_t insn);
    void exec_amo(uint32_t insn);
    void exec_system(uint32_t insn);
    void exec_csr(uint32_t insn);
    bool exec_muldiv(uint32_t insn);

    bool translate(uint32_t va, Access acc, uint32_t &pa);
    bool fetch(uint32_t &insn);
    bool load(uint32_t va, unsigned size, uint32_t &val, bool reserve = false);
    bool store(uint32_t va, unsigned size, uint32_t val);
    bool phys_read(uint32_t pa, unsigned size, uint32_t &val);
    bool phys_write(uint32_t pa, unsigned size, uint32_t val);
    uint32_t *fram_reg(uint32_t off);

    CsrStatus csr_check(uint16_t addr, bool write) const;
    uint32_t csr_read(uint16_t addr);
    void csr_write(uint16_t addr, uint32_t val);
    bool csr_is_hw(uint16_t addr) const;

    bool check_interrupts();
    void raise(uint32_t cause, uint32_t tval);
    void take_trap(uint32_t cause, bool interrupt, uint32_t epc,
                   uint32_t tval);
    void enter_f(uint32_t cause, uint32_t epc, uint32_t tval,
                 uint32_t paddr = 0);
    void fret();
    void halt(const std::string &why);
    void jump(uint32_t target);

    void wr(unsigned rd, uint32_t v)
    {
        if (rd) {
            gpr[bank()][rd] = v;
            info.rd_written = true;
            info.rd = rd;
            info.rd_val = v;
        }
    }

    uint32_t rs(unsigned r) const
    {
        return gpr[bank()][r];
    }

    unsigned bank() const
    {
        return priv == Priv::F;
    }

    unsigned priv_level() const
    {
        return static_cast<unsigned>(priv);
    }

    void begin_step();
    void end_step(Priv start_priv, bool retired);

    Config cfg;
    Bus &bus;
    bool cosim = false;
    std::vector<uint8_t> fram;

    uint32_t gpr[2][32];
    uint32_t pc = 0;
    uint32_t next_pc = 0;
    Priv priv = Priv::F;

    // Set when the current instruction has raised a trap/F event and so must
    // not retire or update state further.
    bool trapped = false;
    bool cycle_written = false;
    bool instret_written = false;

    bool halted = false;
    std::string halt_msg;

    // Hardware CSRs.
    uint32_t mstatus = 0;
    uint32_t medeleg = 0, mideleg = 0;
    uint32_t mie = 0, mip_sw = 0;
    uint32_t ext_irqs = 0;
    uint32_t mtvec = 0, stvec = 0;
    uint32_t mcounteren = 0, scounteren = 0;
    uint32_t mscratch = 0, sscratch = 0;
    uint32_t mepc = 0, sepc = 0;
    uint32_t mcause = 0, scause = 0;
    uint32_t mtval = 0, stval = 0;
    uint32_t satp = 0;
    uint32_t mcycle_r = 0, minstret_r = 0;

    // F mode CSRs.
    uint32_t fstatus = 0, fepc = 0, fcause = 0, ftval = 0, fpaddr = 0;
    // ftval for the pending sfence.vma event (fstatus.SFPEND).
    uint32_t sfence_tval = 0;
    uint32_t finject = 0, ftlbidx = 0, ftlbhi = 0;

    std::vector<TlbEntry> tlb;

    bool reservation_valid = false;
    uint32_t reservation_addr = 0;

    StepInfo info{};
};
