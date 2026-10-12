// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#include <map>
#include <random>
#include <stdexcept>

#include <gtest/gtest.h>

#include "VMervAXIClk2x.h"

namespace
{
// A manager behaving like the core (one transaction at a time, AW and W
// together, valid held until ready, rready/bready only while waiting) on
// fast_clk and a memory on clk, which only changes its outputs and samples
// handshakes on clk edges.
class MervAXIClk2xTest : public ::testing::Test
{
protected:
    MervAXIClk2xTest()
    {
        dut.reset = 1;
        for (int i = 0; i < 4; ++i)
            cycle();
        dut.reset = 0;
    }

    // One fast_clk cycle: a rising fast_clk edge, with a rising clk edge on
    // every other one.
    void cycle()
    {
        if (n > 4000000)
            throw std::runtime_error("timeout");
        dut.eval();
        bool slow = (n & 1) == 0;
        if (!dut.reset) {
            sample_core();
            if (slow)
                sample_mem();
        }
        dut.fast_clk = 1;
        dut.clk = slow;
        dut.eval();
        dut.fast_clk = 0;
        dut.eval();
        if (!dut.reset) {
            drive_core();
            if (slow)
                drive_mem();
        }
        ++n;
    }

    // Core model.
    enum class Core { Idle, Ar, R, Aw, B } core = Core::Idle;
    uint32_t c_addr = 0, c_data = 0;
    bool c_lock = false, aw_done = false, w_done = false;
    unsigned done = 0;

    void sample_core()
    {
        switch (core) {
        case Core::Ar:
            if (dut.c_arvalid && dut.c_arready)
                core = Core::R;
            break;
        case Core::R:
            if (dut.c_rvalid && dut.c_rready) {
                auto it = ref.find(c_addr);
                EXPECT_EQ(dut.c_rdata, it == ref.end() ? 0 : it->second)
                    << std::hex << c_addr;
                EXPECT_EQ(dut.c_rresp, c_lock ? 1u : 0u);
                core = Core::Idle;
                ++done;
            }
            break;
        case Core::Aw:
            aw_done |= dut.c_awvalid && dut.c_awready;
            w_done |= dut.c_wvalid && dut.c_wready;
            if (aw_done && w_done)
                core = Core::B;
            break;
        case Core::B:
            if (dut.c_bvalid && dut.c_bready) {
                EXPECT_EQ(dut.c_bresp, c_lock ? 1u : 0u);
                ref[c_addr] = c_data;
                core = Core::Idle;
                ++done;
            }
            break;
        default: break;
        }
    }

    void drive_core()
    {
        if (core == Core::Idle && rng() % 4 == 0) {
            c_addr = 0x80000000 + (rng() % 16) * 4;
            c_lock = rng() & 1;
            if (rng() & 1) {
                core = Core::Ar;
            } else {
                c_data = rng();
                aw_done = w_done = false;
                core = Core::Aw;
            }
        }
        dut.c_arvalid = core == Core::Ar;
        dut.c_araddr = c_addr;
        dut.c_arsize = 2;
        dut.c_arprot = c_addr & 7;
        dut.c_arlock = c_lock;
        dut.c_rready = core == Core::R;
        dut.c_awvalid = core == Core::Aw && !aw_done;
        dut.c_wvalid = core == Core::Aw && !w_done;
        dut.c_awaddr = c_addr;
        dut.c_awsize = 2;
        dut.c_awprot = c_addr & 7;
        dut.c_awlock = c_lock;
        dut.c_wdata = c_data;
        dut.c_wstrb = 0xf;
        dut.c_bready = core == Core::B;
    }

    // Memory model on clk.
    std::map<uint32_t, uint32_t> mem, ref;
    bool m_rbusy = false, m_bbusy = false, m_aw = false, m_w = false;
    bool m_rlock = false, m_wlock = false;
    uint32_t m_raddr = 0, m_waddr = 0, m_wdata = 0;
    unsigned m_rdelay = 0, m_bdelay = 0;

    void sample_mem()
    {
        if (dut.m_arvalid && dut.m_arready) {
            EXPECT_FALSE(m_rbusy) << "second read in flight";
            EXPECT_EQ(dut.m_arprot, dut.m_araddr & 7);
            m_rbusy = true;
            m_raddr = dut.m_araddr;
            m_rlock = dut.m_arlock;
            m_rdelay = rng() % 4;
        }
        if (dut.m_rvalid && dut.m_rready)
            m_rbusy = false;
        if (dut.m_awvalid && dut.m_awready) {
            EXPECT_EQ(dut.m_awprot, dut.m_awaddr & 7);
            m_aw = true;
            m_waddr = dut.m_awaddr;
            m_wlock = dut.m_awlock;
        }
        if (dut.m_wvalid && dut.m_wready) {
            m_w = true;
            m_wdata = dut.m_wdata;
        }
        if (m_aw && m_w && !m_bbusy) {
            mem[m_waddr] = m_wdata;
            m_aw = m_w = false;
            m_bbusy = true;
            m_bdelay = rng() % 4;
        }
        if (dut.m_bvalid && dut.m_bready)
            m_bbusy = false;
    }

    void drive_mem()
    {
        dut.m_arready = !m_rbusy && rng() % 3 != 0;
        dut.m_awready = !m_aw && rng() % 3 != 0;
        dut.m_wready = !m_w && rng() % 3 != 0;
        if (m_rbusy && m_rdelay)
            --m_rdelay;
        if (m_bbusy && m_bdelay)
            --m_bdelay;
        dut.m_rvalid = m_rbusy && m_rdelay == 0;
        auto it = mem.find(m_raddr);
        dut.m_rdata = it == mem.end() ? 0 : it->second;
        dut.m_rresp = m_rlock ? 1 : 0;
        dut.m_bvalid = m_bbusy && m_bdelay == 0;
        dut.m_bresp = m_wlock ? 1 : 0;
    }

    std::mt19937 rng{42};
    VMervAXIClk2x dut;
    uint64_t n = 0;
};

TEST_F(MervAXIClk2xTest, Random)
{
    while (done < 20000 && n < 2000000)
        cycle();
    EXPECT_EQ(done, 20000u);
    EXPECT_EQ(mem, ref);
}

// A read with an immediately ready memory, from the core's AR to its R
// handshake, in fast_clk cycles: the handshake waits for the cycle ending
// on a clk edge, then a clk cycle for the request register and a clk
// cycle for the memory's response, which is registered.
TEST_F(MervAXIClk2xTest, Latency)
{
    while (core != Core::Idle)
        cycle();
    unsigned best = ~0u;
    for (int i = 0; i < 200; ++i) {
        while (core != Core::Ar)
            cycle();
        auto start = n;
        while (core != Core::Idle)
            cycle();
        best = std::min<unsigned>(best, n - start);
    }
    EXPECT_LE(best, 6u);
}
} // namespace
