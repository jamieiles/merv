// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <iomanip>
#include <sstream>
#include <string>

#include "Hart.h"
#include "RtlCore.h"
#include "Soc.h"

// Lockstep comparison of the RTL against the ISS.  The ISS runs on a mirror
// of the memory map with sinks for the devices: values that legitimately
// differ between the two (counter/interrupt CSR reads and MMIO loads) are
// copied from the RTL, everything else must match exactly.
class Cosim
{
public:
    Cosim(const Config &cfg, size_t dram_size)
        : mirror(dram_size), hart(cfg, mirror.bus)
    {
        hart.set_cosim(true);
    }

    // Returns false on a mismatch, with the reason in error().
    bool check(const RtlEvent &ev)
    {
        if (!ev.retire && !ev.trap && !ev.fevent)
            return true;

        ++events;
        if (ev.trap && (ev.cause & 0x20)) {
            hart.force_interrupt(ev.cause & 0x1f);
        } else if (ev.fevent && (ev.cause == fevent::cycle_wrap ||
                                 ev.cause == fevent::instret_wrap)) {
            hart.force_fevent(ev.cause);
        } else {
            hart.step();
        }

        auto &s = hart.last_step();
        if (hart.is_halted())
            return fail(ev, "ISS halted: " + hart.halt_reason());
        if (s.pc != ev.pc)
            return fail(ev, "pc mismatch");

        if (ev.retire) {
            if (!s.retired)
                return fail(ev, "RTL retired, ISS didn't");
            if (s.insn != ev.insn)
                return fail(ev, "instruction mismatch");
            // The RTL keeps the interrupted privilege level while in F mode.
            uint8_t rtl_priv = (ev.priv & 4) ? 4 : ev.priv;
            if (encode_priv(s.priv) != rtl_priv)
                return fail(ev, "privilege mismatch");
            bool iss_we = s.rd_written;
            if (iss_we != ev.rd_we)
                return fail(ev, "rd write mismatch");
            if (ev.rd_we && (s.rd != ev.rd || s.rd_val != ev.rd_val)) {
                if (!volatile_result(s))
                    return fail(ev, "rd value mismatch");
                hart.set_reg(ev.rd, ev.rd_val, s.priv == Priv::F);
            }
        } else if (ev.trap) {
            if (!s.trap || s.interrupt != bool(ev.cause & 0x20) ||
                s.cause != (ev.cause & 0x1f))
                return fail(ev, "trap mismatch");
        } else if (ev.fevent) {
            if (!s.fevent || s.fcause != ev.cause)
                return fail(ev, "F event mismatch");
        }
        return true;
    }

    const std::string &error() const
    {
        return err;
    }

    MirrorSoc mirror;
    Hart hart;
    uint64_t events = 0;

private:
    static uint8_t encode_priv(Priv p)
    {
        return p == Priv::F ? 4 : static_cast<uint8_t>(p);
    }

    static bool volatile_result(const StepInfo &s)
    {
        if ((s.insn & 0x7f) == 0x73 && ((s.insn >> 12) & 3)) {
            switch (s.insn >> 20) {
            case csr::mcycle: case csr::minstret: case csr::cycle:
            case csr::instret: case csr::mip: case csr::sip:
            case csr::fstatus:
                return true;
            default: return false;
            }
        }
        return s.mem && !s.mem_write && MirrorSoc::is_mmio(s.mem_pa);
    }

    bool fail(const RtlEvent &ev, const std::string &why)
    {
        auto &s = hart.last_step();
        std::ostringstream os;
        os << std::hex << std::setfill('0') << why << " after " << std::dec
           << events << " events\n"
           << std::hex << "  RTL: pc=" << std::setw(8) << ev.pc
           << " insn=" << std::setw(8) << ev.insn << " priv=" << unsigned(ev.priv)
           << (ev.retire ? " retire" : "") << (ev.trap ? " trap" : "")
           << (ev.fevent ? " fevent" : "") << " cause=" << ev.cause
           << " rd_we=" << ev.rd_we << " x" << std::dec << unsigned(ev.rd)
           << std::hex << "=" << std::setw(8) << ev.rd_val << "\n"
           << "  ISS: pc=" << std::setw(8) << s.pc << " insn=" << std::setw(8)
           << s.insn << " priv=" << unsigned(encode_priv(s.priv))
           << (s.retired ? " retire" : "") << (s.trap ? " trap" : "")
           << (s.fevent ? " fevent" : "") << " cause="
           << (s.fevent ? s.fcause : s.cause) << " rd_we=" << s.rd_written
           << " x" << std::dec << unsigned(s.rd) << std::hex << "="
           << std::setw(8) << s.rd_val;
        err = os.str();
        return false;
    }

    std::string err;
};
