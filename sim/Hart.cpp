// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#include "Hart.h"

#include <cstring>
#include <sstream>
#include <stdexcept>

using namespace mstatus_bits;

namespace
{
constexpr uint32_t mstatus_mask = SIE | MIE | SPIE | MPIE | SPP | MPP |
                                  MPRV | SUM | MXR | TVM | TW | TSR;
constexpr uint32_t sstatus_mask = SIE | SPIE | SPP | SUM | MXR;
constexpr uint32_t medeleg_mask = 0xb3ff;
constexpr uint32_t mideleg_mask = 0x222;
constexpr uint32_t mie_mask = 0xaaa;
constexpr uint32_t mip_sw_mask = 0x222;

inline uint32_t bits(uint32_t v, unsigned hi, unsigned lo)
{
    return (v >> lo) & ((1u << (hi - lo + 1)) - 1);
}

inline int32_t sext(uint32_t v, unsigned width)
{
    auto shift = 32 - width;
    return static_cast<int32_t>(v << shift) >> shift;
}

inline int32_t imm_i(uint32_t insn)
{
    return static_cast<int32_t>(insn) >> 20;
}

inline int32_t imm_s(uint32_t insn)
{
    return sext((bits(insn, 31, 25) << 5) | bits(insn, 11, 7), 12);
}

inline int32_t imm_b(uint32_t insn)
{
    return sext((bits(insn, 31, 31) << 12) | (bits(insn, 7, 7) << 11) |
                    (bits(insn, 30, 25) << 5) | (bits(insn, 11, 8) << 1),
                13);
}

inline int32_t imm_j(uint32_t insn)
{
    return sext((bits(insn, 31, 31) << 20) | (bits(insn, 19, 12) << 12) |
                    (bits(insn, 20, 20) << 11) | (bits(insn, 30, 21) << 1),
                21);
}

inline unsigned rd_of(uint32_t insn)
{
    return bits(insn, 11, 7);
}

inline unsigned rs1_of(uint32_t insn)
{
    return bits(insn, 19, 15);
}

inline unsigned rs2_of(uint32_t insn)
{
    return bits(insn, 24, 20);
}

inline unsigned funct3_of(uint32_t insn)
{
    return bits(insn, 14, 12);
}

inline unsigned funct7_of(uint32_t insn)
{
    return bits(insn, 31, 25);
}
} // namespace

Hart::Hart(const Config &cfg, Bus &bus)
    : cfg(cfg), bus(bus), fram(merv::fram_size, 0), tlb(cfg.tlb_entries)
{
    // An instruction may need a fetch and a data translation at the same
    // time, with one entry the refills would evict each other forever.
    if (cfg.tlb_entries < 2 || cfg.tlb_entries > 16)
        throw std::invalid_argument("TLB entries must be 2-16");
    reset();
}

void Hart::reset()
{
    memset(gpr, 0, sizeof(gpr));
    pc = merv::fram_base;
    priv = Priv::F;
    halted = false;
    halt_msg.clear();

    mstatus = 0;
    medeleg = mideleg = 0;
    mie = mip_sw = 0;
    mtvec = stvec = 0;
    mcounteren = scounteren = 0;
    mscratch = sscratch = 0;
    mepc = sepc = 0;
    mcause = scause = 0;
    mtval = stval = 0;
    satp = 0;
    mcycle_r = minstret_r = 0;

    fstatus = static_cast<uint32_t>(Priv::M);
    fepc = fcause = ftval = fpaddr = 0;
    finject = ftlbidx = ftlbhi = 0;
    fcause = fevent::reset;

    for (auto &e : tlb)
        e = TlbEntry{};
    reservation_valid = false;
}

void Hart::load_fram(uint32_t addr, const uint8_t *data, size_t len)
{
    if (addr < merv::fram_base || addr - merv::fram_base + len > fram.size())
        throw std::runtime_error("F mode firmware does not fit in F-RAM");
    memcpy(fram.data() + (addr - merv::fram_base), data, len);
}

void Hart::halt(const std::string &why)
{
    std::ostringstream os;
    os << why << " (pc=0x" << std::hex << pc << ", priv=" << std::dec
       << priv_level() << ")";
    halted = true;
    halt_msg = os.str();
    trapped = true;
}

void Hart::begin_step()
{
    ++steps;
    info = StepInfo{};
    info.pc = pc;
    info.priv = priv;
    trapped = false;
    cycle_written = false;
    instret_written = false;
}

void Hart::end_step(Priv start_priv, bool retired)
{
    info.retired = retired;

    if (!cycle_written && ++mcycle_r == 0)
        fstatus |= fstatus_bits::CYWRAP;
    if (retired) {
        if (start_priv != Priv::F) {
            ++retired_lower;
            if (!instret_written && ++minstret_r == 0)
                fstatus |= fstatus_bits::IRWRAP;
        } else {
            ++retired_f;
        }
    }
}

void Hart::force_interrupt(uint32_t cause)
{
    begin_step();
    take_trap(cause, true, pc, 0);
    info.interrupt = true;
    end_step(priv, false);
}

void Hart::force_fevent(uint32_t cause)
{
    begin_step();
    fstatus &= ~(cause == fevent::cycle_wrap ? fstatus_bits::CYWRAP
                                             : fstatus_bits::IRWRAP);
    enter_f(cause, pc, 0);
    end_step(priv, false);
}

void Hart::step()
{
    if (halted)
        return;

    begin_step();
    auto start_priv = priv;
    bool retired = false;

    do {
        // An sfence.vma raises an F mode event before anything else is
        // translated so that the firmware can invalidate its own state.
        if (priv != Priv::F && (fstatus & fstatus_bits::SFPEND)) {
            fstatus &= ~fstatus_bits::SFPEND;
            enter_f(fevent::sfence, pc, sfence_tval);
            break;
        }
        if (priv != Priv::F && !cosim) {
            if (fstatus & fstatus_bits::CYWRAP) {
                fstatus &= ~fstatus_bits::CYWRAP;
                enter_f(fevent::cycle_wrap, pc, 0);
                break;
            }
            if (fstatus & fstatus_bits::IRWRAP) {
                fstatus &= ~fstatus_bits::IRWRAP;
                enter_f(fevent::instret_wrap, pc, 0);
                break;
            }
            if (check_interrupts())
                break;
        }

        uint32_t insn;
        if (!fetch(insn))
            break;

        info.insn = insn;
        next_pc = pc + 4;
        execute(insn);
        if (trapped)
            break;

        pc = next_pc;
        retired = true;
    } while (0);

    end_step(start_priv, retired);
}

bool Hart::check_interrupts()
{
    auto pending = (mip_sw | ext_irqs) & mie;
    if (!pending)
        return false;

    auto level = priv_level();
    bool m_enabled = level < 3 || (mstatus & MIE);
    bool s_enabled = level < 1 || (level == 1 && (mstatus & SIE));
    auto enabled = (m_enabled ? (pending & ~mideleg) : 0) |
                   (s_enabled ? (pending & mideleg) : 0);
    if (!enabled)
        return false;

    for (auto cause : {11u, 3u, 7u, 9u, 1u, 5u}) {
        if (enabled & (1u << cause)) {
            take_trap(cause, true, pc, 0);
            return true;
        }
    }
    return false;
}

void Hart::raise(uint32_t cause, uint32_t tval)
{
    if (priv == Priv::F) {
        halt("exception " + std::to_string(cause) + " in F mode");
        return;
    }
    take_trap(cause, false, pc, tval);
}

void Hart::take_trap(uint32_t cause, bool interrupt, uint32_t epc,
                     uint32_t tval)
{
    reservation_valid = false;
    info.trap = true;
    info.interrupt = interrupt;
    info.cause = cause;

    auto level = priv_level();
    auto deleg = interrupt ? mideleg : medeleg;
    if (level <= 1 && ((deleg >> cause) & 1)) {
        scause = (interrupt ? 0x80000000u : 0) | cause;
        sepc = epc;
        stval = tval;
        mstatus = (mstatus & ~(SPP | SPIE | SIE)) | (level ? SPP : 0) |
                  ((mstatus & SIE) ? SPIE : 0);
        priv = Priv::S;
        pc = stvec;
    } else {
        mcause = (interrupt ? 0x80000000u : 0) | cause;
        mepc = epc;
        mtval = tval;
        mstatus = (mstatus & ~(MPP | MPIE | MIE)) | (level << MPP_SHIFT) |
                  ((mstatus & MIE) ? MPIE : 0);
        priv = Priv::M;
        pc = mtvec;
    }
    trapped = true;
}

void Hart::enter_f(uint32_t cause, uint32_t epc, uint32_t tval,
                   uint32_t paddr)
{
    if (priv == Priv::F) {
        halt("F mode event " + std::to_string(cause) + " in F mode");
        return;
    }

    fepc = epc;
    fcause = cause;
    ftval = tval;
    fpaddr = paddr;
    fstatus = (fstatus & ~fstatus_bits::PPRV) | priv_level();
    priv = Priv::F;
    pc = cause >= fevent::itlb_miss && cause <= fevent::store_tlb_miss ?
             merv::fram_tlb_entry : merv::fram_base;
    trapped = true;
    info.fevent = true;
    info.fcause = cause;
    if (cause < fevent_counts.size())
        ++fevent_counts[cause];
}

void Hart::fret()
{
    priv = static_cast<Priv>(fstatus & fstatus_bits::PPRV);
    if (finject & 0x80000000u) {
        auto cause = finject & 0x1f;
        finject = 0;
        take_trap(cause, false, fepc, ftval);
        return;
    }
    next_pc = fepc;
}

void Hart::jump(uint32_t target)
{
    if (target & 3)
        raise(exc::insn_misaligned, target);
    else
        next_pc = target;
}

bool Hart::translate(uint32_t va, Access acc, uint32_t &pa)
{
    if (priv == Priv::F) {
        pa = va;
        return true;
    }

    auto eff = priv_level();
    if (acc != Access::Fetch && priv == Priv::M && (mstatus & MPRV))
        eff = bits(mstatus, 12, 11);
    if (eff == 3 || !(satp >> 31)) {
        pa = va;
        return true;
    }

    auto vpn = va >> 12;
    for (auto &e : tlb) {
        if (!e.valid)
            continue;
        if (e.super ? ((e.vpn ^ vpn) >> 10) != 0 : e.vpn != vpn)
            continue;

        bool ok;
        if (acc == Access::Fetch)
            ok = e.x;
        else if (acc == Access::Load)
            ok = e.r || ((mstatus & MXR) && e.x);
        else
            ok = e.w;

        if (eff == 0)
            ok = ok && e.u;
        else if (e.u)
            ok = ok && acc != Access::Fetch && (mstatus & SUM);

        if (!ok) {
            raise(acc == Access::Fetch  ? exc::insn_page
                  : acc == Access::Load ? exc::load_page
                                        : exc::store_page,
                  va);
            return false;
        }

        auto ppn = e.super ? ((e.ppn & ~0x3ffu) | (vpn & 0x3ff)) : e.ppn;
        pa = (ppn << 12) | (va & 0xfff);
        return true;
    }

    enter_f(acc == Access::Fetch  ? fevent::itlb_miss
            : acc == Access::Load ? fevent::load_tlb_miss
                                  : fevent::store_tlb_miss,
            pc, va);
    return false;
}

// The GPR banks alias the F-RAM register window.
uint32_t *Hart::fram_reg(uint32_t off)
{
    if (off < merv::fram_regs || off >= merv::fram_regs_end)
        return nullptr;
    auto idx = (off - merv::fram_regs) / 4;
    return &gpr[idx / 32][idx % 32];
}

bool Hart::phys_read(uint32_t pa, unsigned size, uint32_t &val)
{
    if (priv == Priv::F) {
        auto off = pa - merv::fram_base;
        if (auto *r = fram_reg(off)) {
            val = 0;
            memcpy(&val, reinterpret_cast<uint8_t *>(r) + (off & 3), size);
        } else if (off + size <= fram.size()) {
            val = 0;
            memcpy(&val, &fram[off], size);
        } else if (!bus.read(pa, size, val)) {
            fstatus |= fstatus_bits::BERR;
            val = 0;
        }
        return true;
    }
    return bus.read(pa, size, val);
}

bool Hart::phys_write(uint32_t pa, unsigned size, uint32_t val)
{
    if (priv == Priv::F) {
        auto off = pa - merv::fram_base;
        if (auto *r = fram_reg(off)) {
            // The RTL has no x0 special case in the window.
            if (r == &gpr[0][0] || r == &gpr[1][0])
                halt("F mode write to x0 in the register window");
            else
                memcpy(reinterpret_cast<uint8_t *>(r) + (off & 3), &val, size);
        } else if (off + size <= fram.size())
            memcpy(&fram[off], &val, size);
        else if (!bus.write(pa, size, val))
            fstatus |= fstatus_bits::BERR;
        return true;
    }
    return bus.write(pa, size, val);
}

bool Hart::fetch(uint32_t &insn)
{
    uint32_t pa;
    if (!translate(pc, Access::Fetch, pa))
        return false;

    if (priv == Priv::F && pa - merv::fram_base + 4 <= fram.size()) {
        memcpy(&insn, &fram[pa - merv::fram_base], 4);
        return true;
    }
    if (!bus.read(pa, 4, insn)) {
        if (priv == Priv::F)
            halt("instruction fetch bus error in F mode");
        else
            raise(exc::insn_access, pc);
        return false;
    }
    return true;
}

bool Hart::load(uint32_t va, unsigned size, uint32_t &val, bool reserve)
{
    if (va & (size - 1)) {
        raise(exc::load_misaligned, va);
        return false;
    }
    uint32_t pa;
    if (!translate(va, Access::Load, pa))
        return false;
    if (!phys_read(pa, size, val)) {
        raise(exc::load_access, va);
        return false;
    }
    if (reserve) {
        reservation_valid = true;
        reservation_addr = pa;
    }
    info.mem = true;
    info.mem_va = va;
    info.mem_pa = pa;
    info.mem_val = val;
    return true;
}

bool Hart::store(uint32_t va, unsigned size, uint32_t val)
{
    if (va & (size - 1)) {
        raise(exc::store_misaligned, va);
        return false;
    }
    uint32_t pa;
    if (!translate(va, Access::Store, pa))
        return false;
    if (!phys_write(pa, size, val)) {
        raise(exc::store_access, va);
        return false;
    }
    info.mem = true;
    info.mem_write = true;
    info.mem_va = va;
    info.mem_pa = pa;
    info.mem_val = val;
    return true;
}

void Hart::execute(uint32_t insn)
{
    auto rd = rd_of(insn);

    switch (insn & 0x7f) {
    case 0x37: wr(rd, insn & 0xfffff000); break;
    case 0x17: wr(rd, pc + (insn & 0xfffff000)); break;
    case 0x6f: {
        auto target = pc + imm_j(insn);
        jump(target);
        if (!trapped)
            wr(rd, pc + 4);
        break;
    }
    case 0x67: {
        if (funct3_of(insn) != 0) {
            raise(exc::illegal, insn);
            break;
        }
        auto target = (rs(rs1_of(insn)) + imm_i(insn)) & ~1u;
        jump(target);
        if (!trapped)
            wr(rd, pc + 4);
        break;
    }
    case 0x63: exec_branch(insn); break;
    case 0x03: exec_load(insn); break;
    case 0x23: exec_store(insn); break;
    case 0x13: exec_op_imm(insn); break;
    case 0x33: exec_op(insn); break;
    case 0x0f:
        if (funct3_of(insn) > 1)
            raise(exc::illegal, insn);
        break;
    case 0x2f: exec_amo(insn); break;
    case 0x73: exec_system(insn); break;
    default: raise(exc::illegal, insn); break;
    }
}

void Hart::exec_branch(uint32_t insn)
{
    auto a = rs(rs1_of(insn));
    auto b = rs(rs2_of(insn));
    bool taken;

    switch (funct3_of(insn)) {
    case 0: taken = a == b; break;
    case 1: taken = a != b; break;
    case 4: taken = static_cast<int32_t>(a) < static_cast<int32_t>(b); break;
    case 5: taken = static_cast<int32_t>(a) >= static_cast<int32_t>(b); break;
    case 6: taken = a < b; break;
    case 7: taken = a >= b; break;
    default: raise(exc::illegal, insn); return;
    }

    if (taken)
        jump(pc + imm_b(insn));
}

void Hart::exec_load(uint32_t insn)
{
    auto addr = rs(rs1_of(insn)) + imm_i(insn);
    uint32_t v;

    switch (funct3_of(insn)) {
    case 0:
        if (load(addr, 1, v))
            wr(rd_of(insn), sext(v, 8));
        break;
    case 1:
        if (load(addr, 2, v))
            wr(rd_of(insn), sext(v, 16));
        break;
    case 2:
        if (load(addr, 4, v))
            wr(rd_of(insn), v);
        break;
    case 4:
        if (load(addr, 1, v))
            wr(rd_of(insn), v);
        break;
    case 5:
        if (load(addr, 2, v))
            wr(rd_of(insn), v);
        break;
    default: raise(exc::illegal, insn); break;
    }
}

void Hart::exec_store(uint32_t insn)
{
    auto addr = rs(rs1_of(insn)) + imm_s(insn);
    auto v = rs(rs2_of(insn));

    switch (funct3_of(insn)) {
    case 0: store(addr, 1, v & 0xff); break;
    case 1: store(addr, 2, v & 0xffff); break;
    case 2: store(addr, 4, v); break;
    default: raise(exc::illegal, insn); break;
    }
}

void Hart::exec_op_imm(uint32_t insn)
{
    auto a = rs(rs1_of(insn));
    auto imm = imm_i(insn);
    auto shamt = bits(insn, 24, 20);
    auto f7 = funct7_of(insn);
    uint32_t r;

    switch (funct3_of(insn)) {
    case 0: r = a + imm; break;
    case 2: r = static_cast<int32_t>(a) < imm; break;
    case 3: r = a < static_cast<uint32_t>(imm); break;
    case 4: r = a ^ imm; break;
    case 6: r = a | imm; break;
    case 7: r = a & imm; break;
    case 1:
        if (f7 != 0) {
            raise(exc::illegal, insn);
            return;
        }
        r = a << shamt;
        break;
    case 5:
        if (f7 == 0) {
            r = a >> shamt;
        } else if (f7 == 0x20) {
            r = static_cast<int32_t>(a) >> shamt;
        } else {
            raise(exc::illegal, insn);
            return;
        }
        break;
    default: __builtin_unreachable();
    }

    wr(rd_of(insn), r);
}

void Hart::exec_op(uint32_t insn)
{
    auto f7 = funct7_of(insn);
    if (f7 == 1) {
        exec_muldiv(insn);
        return;
    }

    auto a = rs(rs1_of(insn));
    auto b = rs(rs2_of(insn));
    auto f3 = funct3_of(insn);
    uint32_t r;

    if (f7 == 0x20) {
        if (f3 == 0)
            r = a - b;
        else if (f3 == 5)
            r = static_cast<int32_t>(a) >> (b & 31);
        else {
            raise(exc::illegal, insn);
            return;
        }
    } else if (f7 == 0) {
        switch (f3) {
        case 0: r = a + b; break;
        case 1: r = a << (b & 31); break;
        case 2: r = static_cast<int32_t>(a) < static_cast<int32_t>(b); break;
        case 3: r = a < b; break;
        case 4: r = a ^ b; break;
        case 5: r = a >> (b & 31); break;
        case 6: r = a | b; break;
        case 7: r = a & b; break;
        default: __builtin_unreachable();
        }
    } else {
        raise(exc::illegal, insn);
        return;
    }

    wr(rd_of(insn), r);
}

bool Hart::exec_muldiv(uint32_t insn)
{
    auto f3 = funct3_of(insn);
    auto a = rs(rs1_of(insn));
    auto b = rs(rs2_of(insn));

    // The hardware divider is unsigned only: signed division with a negative
    // operand is emulated by F mode, as is all division without HW_DIV.
    bool negative = !(f3 & 1) && ((a | b) & 0x80000000u);
    if (f3 >= 4 && (!cfg.hw_div || negative)) {
        enter_f(fevent::emulate, pc, insn);
        return false;
    }

    auto sa = static_cast<int64_t>(static_cast<int32_t>(a));
    auto sb = static_cast<int64_t>(static_cast<int32_t>(b));
    auto ua = static_cast<uint64_t>(a);
    auto ub = static_cast<uint64_t>(b);
    uint32_t r;

    switch (f3) {
    case 0: r = a * b; break;
    case 1: r = static_cast<uint64_t>(sa * sb) >> 32; break;
    case 2: r = static_cast<uint64_t>(sa * static_cast<int64_t>(ub)) >> 32; break;
    case 3: r = (ua * ub) >> 32; break;
    case 4:
        if (b == 0)
            r = ~0u;
        else if (a == 0x80000000u && b == ~0u)
            r = a;
        else
            r = static_cast<int32_t>(a) / static_cast<int32_t>(b);
        break;
    case 5: r = b == 0 ? ~0u : a / b; break;
    case 6:
        if (b == 0)
            r = a;
        else if (a == 0x80000000u && b == ~0u)
            r = 0;
        else
            r = static_cast<int32_t>(a) % static_cast<int32_t>(b);
        break;
    case 7: r = b == 0 ? a : a % b; break;
    default: __builtin_unreachable();
    }

    wr(rd_of(insn), r);
    return true;
}

void Hart::exec_amo(uint32_t insn)
{
    auto f5 = bits(insn, 31, 27);
    auto addr = rs(rs1_of(insn));
    auto rd = rd_of(insn);

    if (funct3_of(insn) != 2) {
        raise(exc::illegal, insn);
        return;
    }

    if (f5 == 2) {
        if (rs2_of(insn) != 0) {
            raise(exc::illegal, insn);
            return;
        }
        uint32_t v;
        if (load(addr, 4, v, true))
            wr(rd, v);
        return;
    }

    switch (f5) {
    case 0x00: case 0x01: case 0x03: case 0x04: case 0x08: case 0x0c:
    case 0x10: case 0x14: case 0x18: case 0x1c: break;
    default: raise(exc::illegal, insn); return;
    }

    if (addr & 3) {
        raise(exc::store_misaligned, addr);
        return;
    }
    uint32_t pa;
    if (!translate(addr, Access::Store, pa))
        return;

    if (f5 == 3) {
        bool ok = reservation_valid && reservation_addr == pa;
        reservation_valid = false;
        if (ok) {
            if (!phys_write(pa, 4, rs(rs2_of(insn)))) {
                raise(exc::store_access, addr);
                return;
            }
            info.mem = true;
            info.mem_write = true;
            info.mem_va = addr;
            info.mem_pa = pa;
            info.mem_val = rs(rs2_of(insn));
        }
        wr(rd, ok ? 0 : 1);
        return;
    }

    if (!cfg.native_amo) {
        enter_f(fevent::emulate, pc, insn, pa);
        return;
    }

    uint32_t old;
    if (!phys_read(pa, 4, old)) {
        raise(exc::store_access, addr);
        return;
    }

    auto b = rs(rs2_of(insn));
    uint32_t v;
    switch (f5) {
    case 0x00: v = old + b; break;
    case 0x01: v = b; break;
    case 0x04: v = old ^ b; break;
    case 0x08: v = old | b; break;
    case 0x0c: v = old & b; break;
    case 0x10: v = static_cast<int32_t>(old) < static_cast<int32_t>(b) ? old : b; break;
    case 0x14: v = static_cast<int32_t>(old) > static_cast<int32_t>(b) ? old : b; break;
    case 0x18: v = old < b ? old : b; break;
    case 0x1c: v = old > b ? old : b; break;
    default: __builtin_unreachable();
    }

    if (!phys_write(pa, 4, v)) {
        raise(exc::store_access, addr);
        return;
    }
    info.mem = true;
    info.mem_write = true;
    info.mem_va = addr;
    info.mem_pa = pa;
    info.mem_val = v;
    wr(rd, old);
}

void Hart::exec_system(uint32_t insn)
{
    if (funct3_of(insn) != 0) {
        if (funct3_of(insn) == 4)
            raise(exc::illegal, insn);
        else
            exec_csr(insn);
        return;
    }

    auto level = priv_level();
    bool is_f = priv == Priv::F;

    if ((insn & 0xfe007fff) == 0x12000073) {
        // sfence.vma
        if (level == 0 || (level == 1 && (mstatus & TVM))) {
            raise(exc::illegal, insn);
            return;
        }
        // With rs1 = x0 every entry is invalidated, otherwise the entries
        // that translate the address in rs1.  The event's ftval is rs1 ORed
        // with its register number: zero only for x0.
        auto rs1 = rs1_of(insn);
        sfence_tval = rs(rs1) | rs1;
        for (auto &e : tlb) {
            uint32_t vpn = sfence_tval >> 12;
            if (!rs1 || (e.super ? (e.vpn >> 10) == (vpn >> 10) : e.vpn == vpn))
                e.valid = false;
        }
        if (!is_f)
            fstatus |= fstatus_bits::SFPEND;
        return;
    }

    switch (insn) {
    case 0x00000073:
        if (is_f)
            halt("ecall in F mode");
        else
            raise(level == 0   ? exc::ecall_u
                  : level == 1 ? exc::ecall_s
                               : exc::ecall_m,
                  0);
        break;
    case 0x00100073: raise(exc::breakpoint, pc); break;
    case 0x30200073: {
        if (level != 3) {
            raise(exc::illegal, insn);
            break;
        }
        auto mpp = bits(mstatus, 12, 11);
        mstatus = (mstatus & ~(MPP | MIE)) | MPIE |
                  ((mstatus & MPIE) ? MIE : 0);
        if (mpp != 3)
            mstatus &= ~MPRV;
        priv = static_cast<Priv>(mpp);
        next_pc = mepc;
        break;
    }
    case 0x10200073: {
        if (is_f || level == 0 || (level == 1 && (mstatus & TSR))) {
            raise(exc::illegal, insn);
            break;
        }
        auto spp = bits(mstatus, 8, 8);
        mstatus = (mstatus & ~(SPP | SIE | MPRV)) | SPIE |
                  ((mstatus & SPIE) ? SIE : 0);
        priv = static_cast<Priv>(spp);
        next_pc = sepc;
        break;
    }
    case 0x10500073:
        if (level == 0 || (level == 1 && (mstatus & TW)))
            raise(exc::illegal, insn);
        break;
    case fret_insn:
        if (!is_f)
            raise(exc::illegal, insn);
        else
            fret();
        break;
    default: raise(exc::illegal, insn); break;
    }
}

bool Hart::csr_is_hw(uint16_t addr) const
{
    switch (addr) {
    case csr::sstatus: case csr::sie: case csr::stvec: case csr::scounteren:
    case csr::sscratch: case csr::sepc: case csr::scause: case csr::stval:
    case csr::sip: case csr::satp: case csr::mstatus: case csr::medeleg:
    case csr::mideleg: case csr::mie: case csr::mtvec: case csr::mcounteren:
    case csr::mscratch: case csr::mepc: case csr::mcause: case csr::mtval:
    case csr::mip: case csr::mcycle: case csr::minstret: case csr::cycle:
    case csr::instret:
        return true;
    default:
        return false;
    }
}

Hart::CsrStatus Hart::csr_check(uint16_t addr, bool write) const
{
    // 0x7c6 and 0x7c7 are unallocated.
    if (addr >= csr::fstatus && addr <= csr::fconfig && addr != 0x7c6 &&
        addr != 0x7c7) {
        if (priv != Priv::F)
            return CsrStatus::Illegal;
        if (write && (addr == csr::fbootvec || addr == csr::fconfig))
            return CsrStatus::Illegal;
        return CsrStatus::Ok;
    }
    if (!csr_is_hw(addr))
        return priv == Priv::F ? CsrStatus::Illegal : CsrStatus::Emulate;

    if (priv != Priv::F) {
        auto level = priv_level();
        if (bits(addr, 9, 8) > level)
            return CsrStatus::Illegal;
        if (addr == csr::satp && level == 1 && (mstatus & TVM))
            return CsrStatus::Illegal;
        if (addr == csr::cycle || addr == csr::instret) {
            auto bit = addr & 31;
            if (level < 3 && !((mcounteren >> bit) & 1))
                return CsrStatus::Illegal;
            if (level == 0 && !((scounteren >> bit) & 1))
                return CsrStatus::Illegal;
        }
    }
    if (write && bits(addr, 11, 10) == 3)
        return CsrStatus::Illegal;
    return CsrStatus::Ok;
}

uint32_t Hart::csr_read(uint16_t addr)
{
    switch (addr) {
    case csr::sstatus: return mstatus & sstatus_mask;
    case csr::sie: return mie & mideleg;
    case csr::stvec: return stvec;
    case csr::scounteren: return scounteren;
    case csr::sscratch: return sscratch;
    case csr::sepc: return sepc;
    case csr::scause: return scause;
    case csr::stval: return stval;
    case csr::sip: return (mip_sw | ext_irqs) & mideleg;
    case csr::satp: return satp;
    case csr::mstatus: return mstatus;
    case csr::medeleg: return medeleg;
    case csr::mideleg: return mideleg;
    case csr::mie: return mie;
    case csr::mtvec: return mtvec;
    case csr::mcounteren: return mcounteren;
    case csr::mscratch: return mscratch;
    case csr::mepc: return mepc;
    case csr::mcause: return mcause;
    case csr::mtval: return mtval;
    case csr::mip: return mip_sw | ext_irqs;
    case csr::mcycle: case csr::cycle: return mcycle_r;
    case csr::minstret: case csr::instret: return minstret_r;
    case csr::fstatus: return fstatus;
    case csr::fepc: return fepc;
    case csr::fcause: return fcause;
    case csr::ftval: return ftval;
    case csr::fpaddr: return fpaddr;
    case csr::finject: return finject;
    case csr::ftlbidx: return ftlbidx;
    case csr::ftlbhi: return 0;
    case csr::ftlblo: return 0;
    case csr::fbootvec: return cfg.reset_vector;
    case csr::fconfig:
        return cfg.tlb_entries | (cfg.native_amo ? 1u << 8 : 0) |
               (cfg.hw_div ? 1u << 9 : 0) | (cfg.barrel_shift ? 1u << 10 : 0);
    default: return 0;
    }
}

void Hart::csr_write(uint16_t addr, uint32_t v)
{
    switch (addr) {
    case csr::sstatus:
        mstatus = (mstatus & ~sstatus_mask) | (v & sstatus_mask);
        break;
    case csr::sie: mie = (mie & ~mideleg) | (v & mideleg); break;
    case csr::stvec: stvec = v & ~3u; break;
    case csr::scounteren: scounteren = v & 7; break;
    case csr::sscratch: sscratch = v; break;
    case csr::sepc: sepc = v & ~3u; break;
    case csr::scause: scause = v; break;
    case csr::stval: stval = v; break;
    case csr::sip: {
        auto m = mideleg & 0x2;
        mip_sw = (mip_sw & ~m) | (v & m);
        break;
    }
    case csr::satp: satp = v & 0x803fffffu; break;
    case csr::mstatus: {
        auto nv = v & mstatus_mask;
        if (bits(nv, 12, 11) == 2)
            nv = (nv & ~MPP) | (mstatus & MPP);
        mstatus = nv;
        break;
    }
    case csr::medeleg: medeleg = v & medeleg_mask; break;
    case csr::mideleg: mideleg = v & mideleg_mask; break;
    case csr::mie: mie = v & mie_mask; break;
    case csr::mtvec: mtvec = v & ~3u; break;
    case csr::mcounteren: mcounteren = v & 7; break;
    case csr::mscratch: mscratch = v; break;
    case csr::mepc: mepc = v & ~3u; break;
    case csr::mcause: mcause = v; break;
    case csr::mtval: mtval = v; break;
    case csr::mip: mip_sw = (mip_sw & ~mip_sw_mask) | (v & mip_sw_mask); break;
    case csr::mcycle:
        mcycle_r = v;
        cycle_written = true;
        break;
    case csr::minstret:
        minstret_r = v;
        instret_written = true;
        break;
    case csr::fstatus: {
        auto pprv = v & fstatus_bits::PPRV;
        if (pprv == 2)
            pprv = fstatus & fstatus_bits::PPRV;
        fstatus = pprv | (v & (fstatus_bits::BERR | fstatus_bits::CYWRAP |
                               fstatus_bits::IRWRAP | fstatus_bits::SFPEND));
        break;
    }
    case csr::fepc: fepc = v & ~3u; break;
    case csr::fcause: fcause = v; break;
    case csr::ftval: ftval = v; break;
    case csr::fpaddr: fpaddr = v; break;
    case csr::finject: finject = v & 0x8000001fu; break;
    case csr::ftlbidx: ftlbidx = v; break;
    case csr::ftlbhi: ftlbhi = v & 0xfffff003u; break;
    case csr::ftlblo: {
        auto &e = tlb[ftlbidx % tlb.size()];
        e.valid = ftlbhi & 1;
        e.super = (ftlbhi >> 1) & 1;
        e.vpn = ftlbhi >> 12;
        e.ppn = v >> 12;
        e.r = v & 1;
        e.w = (v >> 1) & 1;
        e.x = (v >> 2) & 1;
        e.u = (v >> 3) & 1;
        break;
    }
    default: break;
    }
}

void Hart::exec_csr(uint32_t insn)
{
    auto f3 = funct3_of(insn);
    auto op = f3 & 3;
    auto rs1 = rs1_of(insn);
    auto rd = rd_of(insn);
    auto addr = static_cast<uint16_t>(insn >> 20);

    if (op == 0) {
        raise(exc::illegal, insn);
        return;
    }

    auto src = (f3 & 4) ? rs1 : rs(rs1);
    bool write = op == 1 || rs1 != 0;

    switch (csr_check(addr, write)) {
    case CsrStatus::Illegal:
        if (priv == Priv::F)
            halt("illegal CSR access in F mode");
        else
            raise(exc::illegal, insn);
        return;
    case CsrStatus::Emulate: enter_f(fevent::emulate, pc, insn); return;
    case CsrStatus::Ok: break;
    }

    uint32_t old = (op != 1 || rd != 0) ? csr_read(addr) : 0;
    // A CSR instruction that writes mip reads (and so writes back) only the
    // software SEIP bit, not the external interrupt.
    if (addr == csr::mip && write)
        old = (old & ~(1u << 9)) | (mip_sw & (1u << 9));
    if (write) {
        uint32_t nv = op == 1 ? src : op == 2 ? (old | src) : (old & ~src);
        csr_write(addr, nv);
    }
    wr(rd, old);
}
