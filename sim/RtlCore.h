// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <verilated.h>
#include <verilated_fst_c.h>

#include "Soc.h"

// What the core reported in a clock cycle.
struct RtlEvent {
    bool retire;
    bool trap;
    bool fevent;
    uint32_t pc;
    uint32_t insn;
    uint8_t priv;  // {is_f, priv[1:0]}
    bool rd_we;
    uint8_t rd;
    uint32_t rd_val;
    uint32_t cause;  // {interrupt, cause[4:0]} or the F event cause
};

class RtlCoreBase
{
public:
    virtual ~RtlCoreBase() = default;
    virtual void cycle() = 0;
    virtual bool halted() const = 0;
    virtual const RtlEvent &event() const = 0;
    virtual uint64_t cycles() const = 0;
    virtual void open_waves(const std::string &path) = 0;
};

// A Verilated MervCore connected to the Soc through a simple AXI4
// subordinate.  Responses take `latency` cycles, DRAM accesses `dram_latency`
// cycles unless they hit in an optional model of the bridge's set associative
// write-back cache of 16 byte lines (fpga/xilinx/AXIMIGBridge.sv).
template <typename Model>
class RtlCore : public RtlCoreBase
{
public:
    RtlCore(Soc &soc, uint32_t reset_vector, unsigned latency,
            unsigned dram_latency = 0, unsigned cache_sets = 0,
            unsigned cache_ways = 1)
        : soc(soc), latency(latency),
          dram_latency(dram_latency ? dram_latency : latency),
          cache_sets(cache_sets), cache_ways(cache_ways),
          cache(size_t(cache_sets) * cache_ways), ctx(new VerilatedContext),
          top(new Model(ctx.get()))
    {
        top->reset_vector = reset_vector;
        top->reset = 1;
        for (int i = 0; i < 4; ++i)
            clock();
        top->reset = 0;
    }

    ~RtlCore() override
    {
        if (waves)
            waves->close();
        top->final();
    }

    void open_waves(const std::string &path) override
    {
        Verilated::traceEverOn(true);
        waves = std::make_unique<VerilatedFstC>();
        top->trace(waves.get(), 99);
        waves->open(path.c_str());
    }

    void cycle() override
    {
        auto irq = soc.irqs();
        top->meip = irq.meip;
        top->seip = irq.seip;
        top->mtip = irq.mtip;
        top->msip = irq.msip;

        drive();
        top->eval();

        ev.retire = top->trace_retire;
        ev.trap = top->trace_trap;
        ev.fevent = top->trace_fevent;
        ev.pc = top->trace_pc;
        ev.insn = top->trace_insn;
        ev.priv = top->trace_priv;
        ev.rd_we = top->trace_rd_we;
        ev.rd = top->trace_rd;
        ev.rd_val = top->trace_rd_val;
        ev.cause = top->trace_cause;

        bool ar_hs = top->axi_arvalid && top->axi_arready;
        bool r_hs = top->axi_rvalid && top->axi_rready;
        bool aw_hs = top->axi_awvalid && top->axi_awready;
        bool w_hs = top->axi_wvalid && top->axi_wready;
        bool b_hs = top->axi_bvalid && top->axi_bready;
        uint32_t araddr = top->axi_araddr, arsize = top->axi_arsize;
        uint32_t awaddr = top->axi_awaddr, awsize = top->axi_awsize;
        uint32_t wdata = top->axi_wdata;

        clock();
        soc.tick();

        update(ar_hs, r_hs, aw_hs, w_hs, b_hs, araddr, arsize, awaddr,
               awsize, wdata);
    }

    bool halted() const override
    {
        return top->halted;
    }

    const RtlEvent &event() const override
    {
        return ev;
    }

    uint64_t cycles() const override
    {
        return ncycles;
    }

private:
    void clock()
    {
        top->clk = 1;
        top->eval();
        if (waves)
            waves->dump(ctx->time());
        ctx->timeInc(1);
        top->clk = 0;
        top->eval();
        if (waves)
            waves->dump(ctx->time());
        ctx->timeInc(1);
        ++ncycles;
    }

    void drive()
    {
        top->axi_arready = !rd.busy;
        top->axi_rvalid = rd.busy && rd.wait == 0;
        top->axi_rdata = rd.data;
        top->axi_rresp = rd.err ? 2 : 0;
        top->axi_awready = !wr.busy && !wr.aw_have;
        top->axi_wready = !wr.busy && !wr.w_have;
        top->axi_bvalid = wr.busy && wr.wait == 0;
        top->axi_bresp = wr.err ? 2 : 0;
    }

    void update(bool ar_hs, bool r_hs, bool aw_hs, bool w_hs, bool b_hs,
                uint32_t araddr, uint32_t arsize, uint32_t awaddr,
                uint32_t awsize, uint32_t wdata)
    {
        if (r_hs)
            rd.busy = false;
        else if (rd.busy && rd.wait)
            --rd.wait;
        if (ar_hs) {
            uint32_t v = 0;
            rd.err = !soc.bus.read(araddr, 1u << arsize, v);
            rd.data = v << (8 * (araddr & 3));
            rd.busy = true;
            rd.wait = access_latency(araddr, true);
        }

        if (b_hs)
            wr.busy = false;
        else if (wr.busy && wr.wait)
            --wr.wait;
        if (aw_hs) {
            wr.aw_have = true;
            wr.addr = awaddr;
            wr.size = awsize;
        }
        if (w_hs) {
            wr.w_have = true;
            wr.data = wdata;
        }
        if (wr.aw_have && wr.w_have && !wr.busy) {
            unsigned bytes = 1u << wr.size;
            uint32_t v = wr.data >> (8 * (wr.addr & 3));
            if (bytes < 4)
                v &= (1u << (8 * bytes)) - 1;
            wr.err = !soc.bus.write(wr.addr, bytes, v);
            wr.aw_have = wr.w_have = false;
            wr.busy = true;
            wr.wait = access_latency(wr.addr, false);
        }
    }

    unsigned access_latency(uint32_t addr, bool read)
    {
        if (addr < merv::dram_base)
            return latency;
        if (cache.empty())
            return dram_latency;
        uint32_t line = (addr - merv::dram_base) >> 4;
        auto *set = &cache[(line % cache_sets) * cache_ways];
        for (unsigned w = 0; w < cache_ways; ++w) {
            if (set[w].line == line) {
                ++cache_hits;
                set[w].dirty |= !read;
                return latency;
            }
        }
        // Write misses go straight to the DRAM without allocating and don't
        // wait for it.
        if (!read)
            return latency;
        ++cache_misses;
        // The first invalid way, otherwise round robin.
        unsigned victim = next_way++ % cache_ways;
        for (unsigned w = cache_ways; w-- > 0;)
            if (set[w].line == ~0u)
                victim = w;
        // A dirty victim is written back before the fill, the write is
        // posted so only costs the handshake.
        unsigned cost = dram_latency + (set[victim].dirty ? latency : 0);
        set[victim] = {line, false};
        return cost;
    }

    struct {
        bool busy = false;
        unsigned wait = 0;
        uint32_t data = 0;
        bool err = false;
    } rd;

    struct {
        bool busy = false, aw_have = false, w_have = false;
        unsigned wait = 0;
        uint32_t addr = 0, size = 0, data = 0;
        bool err = false;
    } wr;

public:
    uint64_t cache_hits = 0, cache_misses = 0;

private:
    Soc &soc;
    unsigned latency, dram_latency;
    struct Way {
        uint32_t line = ~0u;
        bool dirty = false;
    };
    unsigned cache_sets, cache_ways;
    std::vector<Way> cache;
    unsigned next_way = 0;
    std::unique_ptr<VerilatedContext> ctx;
    std::unique_ptr<Model> top;
    std::unique_ptr<VerilatedFstC> waves;
    RtlEvent ev{};
    uint64_t ncycles = 0;
};
