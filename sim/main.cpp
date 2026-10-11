// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#include <cstdio>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>

#include "Args.h"
#include "Platform.h"
#include "RiscVELF.h"

#ifdef MERV_HAVE_RTL
#include "Cosim.h"
#include "RtlCore.h"
#include "VMervCore.h"
#include "VMervCoreBarrel.h"
#include "VMervCoreNoDiv.h"
#include "VMervCoreNoDivBarrel.h"
#include "VMervCoreSmall.h"
#endif

namespace
{
const char *priv_name(Priv p)
{
    switch (p) {
    case Priv::U: return "U";
    case Priv::S: return "S";
    case Priv::M: return "M";
    case Priv::F: return "F";
    }
    return "?";
}

std::string format_step(const StepInfo &s, uint64_t n)
{
    std::ostringstream os;
    os << std::setw(10) << n << " " << priv_name(s.priv) << " " << std::hex
       << std::setfill('0') << std::setw(8) << s.pc << " " << std::setw(8)
       << s.insn;
    if (s.rd_written)
        os << "  x" << std::dec << unsigned(s.rd) << std::hex << "="
           << std::setw(8) << s.rd_val;
    if (s.mem)
        os << (s.mem_write ? "  W[" : "  R[") << std::setw(8) << s.mem_va
           << "->" << std::setw(8) << s.mem_pa << "]=" << std::setw(8)
           << s.mem_val;
    if (s.trap)
        os << "  TRAP " << (s.interrupt ? "irq " : "exc ") << std::dec
           << s.cause;
    if (s.fevent)
        os << "  FEVENT " << std::dec << s.fcause;
    return os.str();
}

#ifdef MERV_HAVE_RTL
std::string format_event(const RtlEvent &e, uint64_t cycle)
{
    static const char *privs[] = {"U", "S", "?", "M", "F", "F", "F", "F"};
    std::ostringstream os;
    os << std::setw(10) << cycle << " " << privs[e.priv & 7] << " "
       << std::hex << std::setfill('0') << std::setw(8) << e.pc << " "
       << std::setw(8) << e.insn;
    if (e.rd_we)
        os << "  x" << std::dec << unsigned(e.rd) << std::hex << "="
           << std::setw(8) << e.rd_val;
    if (e.trap)
        os << "  TRAP " << ((e.cause & 0x20) ? "irq " : "exc ") << std::dec
           << (e.cause & 0x1f);
    if (e.fevent)
        os << "  FEVENT " << std::dec << e.cause;
    return os.str();
}
#endif

std::vector<uint8_t> read_file(const std::string &path)
{
    std::ifstream f(path, std::ios::binary);
    if (!f)
        throw std::runtime_error("failed to open " + path);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),
                                std::istreambuf_iterator<char>());
}

struct Image {
    uint32_t addr;
    std::vector<uint8_t> data;
};

std::vector<Image> load_images(const RiscVELF *elf,
                               const std::vector<std::string> &binaries)
{
    std::vector<Image> images;
    if (elf)
        for (auto &[addr, bytes] : elf->load_segments())
            images.push_back({addr, bytes});
    for (auto &spec : binaries) {
        auto at = spec.rfind('@');
        if (at == std::string::npos)
            throw std::runtime_error("--binary expects file@address: " + spec);
        auto addr = static_cast<uint32_t>(
            std::stoul(spec.substr(at + 1), nullptr, 0));
        images.push_back({addr, read_file(spec.substr(0, at))});
    }
    return images;
}

void write_signature(Bus &bus, const RiscVELF &elf, std::ostream &os)
{
    uint32_t begin, end;
    try {
        begin = elf.sym_addr("begin_signature");
        end = elf.sym_addr("end_signature");
    } catch (std::out_of_range &) {
        return;
    }
    for (auto a = begin; a < end; a += 4) {
        uint32_t v = 0;
        bus.read(a, 4, v);
        os << std::hex << std::setw(8) << std::setfill('0') << v << "\n";
    }
}

struct Options {
    Config core;
    SocOptions soc;
    std::string ffw = MERV_FFW_PATH;
    std::string elf_path, trace_path, signature_path, waves_path;
    std::vector<std::string> binaries;
    uint64_t max_steps = 0;
    unsigned trace_last = 0;
    unsigned axi_latency = 2;
    unsigned dram_latency = 0;
    unsigned dram_cache_sets = 0;
    unsigned dram_cache_ways = 4;
    bool compliance = false, stats = false, rtl = false, cosim = false;
    int64_t reset_vector = -1;
    int64_t mcycle_init = -1, minstret_init = -1;
};

// Common run loop state: tohost polling, tracing and the exit status.
class Runner
{
public:
    Runner(const Options &opts, Bus &bus, const RiscVELF *elf)
        : opts(opts), bus(bus)
    {
        if (!opts.trace_path.empty())
            trace.open(opts.trace_path);
        if (opts.compliance && elf)
            tohost = elf->sym_addr("tohost");
    }

    void record(const std::string &line)
    {
        if (trace.is_open())
            trace << line << "\n";
        if (opts.trace_last) {
            last.push_back(line);
            if (last.size() > opts.trace_last)
                last.pop_front();
        }
    }

    bool tracing() const
    {
        return trace.is_open() || opts.trace_last;
    }

    // Returns true when the test has finished.
    bool poll_tohost(uint64_t n)
    {
        if (!tohost || (n & 63))
            return false;
        uint32_t v = 0;
        bus.read(tohost, 4, v);
        if (!v)
            return false;
        passed = v == 1;
        if (!passed)
            std::cerr << "test failed: tohost=" << v << " (test " << (v >> 1)
                      << ")" << std::endl;
        return true;
    }

    void dump_last()
    {
        for (auto &l : last)
            std::cerr << l << "\n";
    }

    const Options &opts;
    Bus &bus;
    std::ofstream trace;
    std::deque<std::string> last;
    uint32_t tohost = 0;
    bool passed = false;
};

int finish(const Options &opts, Runner &runner, Soc &soc, const RiscVELF *elf,
           bool halted, const std::string &halt_reason, bool timeout,
           const std::string &error)
{
    int status = 0;

    if (timeout) {
        std::cerr << "\nstep limit reached" << std::endl;
        status = 3;
    }
    if (!error.empty()) {
        std::cerr << "\n" << error << std::endl;
        status = 4;
    } else if (halted) {
        std::cerr << "\ncore halted: " << halt_reason << std::endl;
        status = 2;
    } else {
        switch (soc.syscon.state) {
        case Syscon::State::PowerOff: break;
        case Syscon::State::Fail:
            std::cerr << "\npower off with failure code " << soc.syscon.code
                      << std::endl;
            status = soc.syscon.code ? int(soc.syscon.code) : 1;
            break;
        case Syscon::State::Reset:
            std::cerr << "\nreset requested" << std::endl;
            break;
        default: break;
        }
    }

    if (opts.compliance) {
        if (!runner.passed && status == 0)
            status = 1;
        if (elf) {
            if (!opts.signature_path.empty()) {
                std::ofstream sig(opts.signature_path);
                write_signature(soc.bus, *elf, sig);
            } else {
                write_signature(soc.bus, *elf, std::cout);
            }
        }
    }

    if (status && opts.trace_last)
        runner.dump_last();

    return status;
}

int run_iss(const Options &opts, const RiscVELF *elf,
            const std::vector<Image> &images)
{
    Platform p(opts.core, opts.soc);
    {
        RiscVELF ffw(opts.ffw);
        for (auto &[addr, bytes] : ffw.load_segments())
            p.hart.load_fram(addr, bytes.data(), bytes.size());
    }
    for (auto &i : images)
        p.soc.bus.load(i.addr, i.data.data(), i.data.size());
    if (opts.mcycle_init >= 0)
        p.hart.set_mcycle(static_cast<uint32_t>(opts.mcycle_init));
    if (opts.minstret_init >= 0)
        p.hart.set_minstret(static_cast<uint32_t>(opts.minstret_init));

    Runner runner(opts, p.soc.bus, elf);
    uint64_t n = 0;
    for (; !opts.max_steps || n < opts.max_steps; ++n) {
        p.step();
        if (runner.tracing())
            runner.record(format_step(p.hart.last_step(), n));
        if (p.stopped() || runner.poll_tohost(n))
            break;
    }

    auto status = finish(opts, runner, p.soc, elf, p.hart.is_halted(),
                         p.hart.halt_reason(),
                         opts.max_steps && n >= opts.max_steps, "");

    if (opts.stats) {
        auto &h = p.hart;
        std::cerr << std::dec << "steps: " << h.steps
                  << "\nretired (U/S/M): " << h.retired_lower
                  << "\nretired (F): " << h.retired_f << "\nF events:";
        for (auto c : h.fevent_counts)
            std::cerr << " " << c;
        std::cerr << std::endl;
    }
    return status;
}

#ifdef MERV_HAVE_RTL
int run_rtl(const Options &opts, const RiscVELF *elf,
            const std::vector<Image> &images)
{
    Soc soc(opts.soc);
    for (auto &i : images)
        soc.bus.load(i.addr, i.data.data(), i.data.size());

    std::unique_ptr<RtlCoreBase> core;
    auto &c = opts.core;
    auto make = [&]<typename Model>() {
        core = std::make_unique<RtlCore<Model>>(
            soc, c.reset_vector, opts.axi_latency, opts.dram_latency,
            opts.dram_cache_sets, opts.dram_cache_ways);
    };
    bool deflt = c.tlb_entries == 4 && c.native_amo;
    if (deflt && c.hw_div && !c.barrel_shift)
        make.operator()<VMervCore>();
    else if (deflt && c.hw_div && c.barrel_shift)
        make.operator()<VMervCoreBarrel>();
    else if (deflt && !c.hw_div && !c.barrel_shift)
        make.operator()<VMervCoreNoDiv>();
    else if (deflt && !c.hw_div && c.barrel_shift)
        make.operator()<VMervCoreNoDivBarrel>();
    else if (c.tlb_entries == 2 && !c.native_amo && !c.hw_div &&
             !c.barrel_shift)
        make.operator()<VMervCoreSmall>();
    else
        throw std::runtime_error(
            "RTL models: --tlb-entries 4 --native-amo 1 with any --hw-div and "
            "--barrel-shift, or --tlb-entries 2 --native-amo 0 --hw-div 0 "
            "--barrel-shift 0");
    if (!opts.waves_path.empty())
        core->open_waves(opts.waves_path);

    std::unique_ptr<Cosim> cosim;
    if (opts.cosim) {
        cosim = std::make_unique<Cosim>(c, opts.soc.dram_size);
        RiscVELF ffw(opts.ffw);
        for (auto &[addr, bytes] : ffw.load_segments())
            cosim->hart.load_fram(addr, bytes.data(), bytes.size());
        for (auto &i : images)
            cosim->mirror.bus.load(i.addr, i.data.data(), i.data.size());
    }

    Runner runner(opts, soc.bus, elf);
    std::string error;
    uint64_t n = 0, retired = 0;
    for (; !opts.max_steps || n < opts.max_steps; ++n) {
        core->cycle();
        auto &ev = core->event();
        retired += ev.retire;
        if (runner.tracing() && (ev.retire || ev.trap || ev.fevent))
            runner.record(format_event(ev, n));
        if (cosim && !cosim->check(ev)) {
            error = "cosim: " + cosim->error();
            break;
        }
        if (core->halted() || soc.stopped() || runner.poll_tohost(n))
            break;
    }

    auto status = finish(opts, runner, soc, elf, core->halted(),
                         "RTL halted", opts.max_steps && n >= opts.max_steps,
                         error);
    if (opts.stats)
        std::cerr << std::dec << "cycles: " << core->cycles()
                  << "\nretired: " << retired << std::endl;
    return status;
}
#endif
} // namespace

int main(int argc, char **argv)
{
    Options opts;
    Args args(argc, argv);
    try {
        args.str("ffw", opts.ffw, "F mode firmware ELF");
        args.str("elf", opts.elf_path,
                 "ELF to load, sets the reset vector to its entry point");
        args.list("binary", opts.binaries, "file@address raw binary to load");
        args.num("reset-vector", opts.reset_vector, "M mode reset vector");
        args.num("tlb-entries", opts.core.tlb_entries, "TLB entries");
        args.flag01("native-amo", opts.core.native_amo, "AMOs in hardware (0/1)");
        args.flag01("hw-div", opts.core.hw_div, "division in hardware (0/1)");
        args.flag01("barrel-shift", opts.core.barrel_shift,
                    "single cycle shifter in the RTL (0/1)");
        size_t dram_mb = opts.soc.dram_size >> 20;
        args.num("dram-mb", dram_mb, "DRAM size in MB");
        opts.soc.dram_size = dram_mb << 20;
        args.num("mtime-div", opts.soc.mtime_divider,
                 "steps (ISS) or cycles (RTL) per mtime tick");
        args.str("uart-log", opts.soc.uart_log, "UART output log");
        opts.soc.uart_echo =
            !args.flag("no-echo", "don't echo UART output to stdout");
        opts.soc.uart_input = args.flag("input", "pass stdin through to the UART");
        args.num("max-steps", opts.max_steps,
                 "maximum steps (ISS) or cycles (RTL) to run");
        opts.compliance = args.flag("compliance", "run as a compliance test (tohost)");
        args.str("signature", opts.signature_path,
                 "write the test signature to a file");
        args.str("trace", opts.trace_path, "write an execution trace");
        args.num("trace-last", opts.trace_last, "print the last N steps on failure");
        args.num("mcycle-init", opts.mcycle_init, "initial mcycle (ISS)");
        args.num("minstret-init", opts.minstret_init, "initial minstret (ISS)");
        opts.stats = args.flag("stats", "print statistics on exit");
        opts.rtl = args.flag("rtl", "simulate the RTL instead of the ISS");
        opts.cosim = args.flag("cosim", "simulate the RTL checked against the ISS");
        args.num("axi-latency", opts.axi_latency, "RTL AXI response latency");
        args.num("dram-latency", opts.dram_latency,
                 "RTL DRAM read latency (default: the AXI latency)");
        args.num("dram-cache-sets", opts.dram_cache_sets,
                 "RTL model of the DRAM bridge cache sets (16 byte lines, 0: none)");
        args.num("dram-cache-ways", opts.dram_cache_ways,
                 "RTL model of the DRAM bridge cache ways");
        args.str("waves", opts.waves_path, "RTL waveform (FST) output");
        if (args.flag("help", "show this help")) {
            std::cout << args.help();
            return 0;
        }
        args.finish();
    } catch (std::exception &e) {
        std::cerr << "error: " << e.what() << "\n" << args.help();
        return 2;
    }

    std::unique_ptr<RawTTY> raw_tty;
    if (opts.soc.uart_input)
        raw_tty = std::make_unique<RawTTY>();

    try {
        std::unique_ptr<RiscVELF> elf;
        if (!opts.elf_path.empty()) {
            elf = std::make_unique<RiscVELF>(opts.elf_path);
            opts.core.reset_vector = elf->entry_point();
        }
        if (opts.reset_vector >= 0)
            opts.core.reset_vector = static_cast<uint32_t>(opts.reset_vector);
        auto images = load_images(elf.get(), opts.binaries);

        if (opts.rtl || opts.cosim) {
#ifdef MERV_HAVE_RTL
            return run_rtl(opts, elf.get(), images);
#else
            throw std::runtime_error("built without RTL support");
#endif
        }
        return run_iss(opts, elf.get(), images);
    } catch (std::exception &e) {
        std::cerr << "error: " << e.what() << std::endl;
        return 2;
    }
}
