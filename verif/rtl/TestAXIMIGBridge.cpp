// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <vector>

#include <gtest/gtest.h>

#include "VAXIMIGBridge.h"

namespace
{
// Behavioural model of the MIG native interface: commands are BL8s of 128
// bits, write data is accepted ahead of the command and read data returns in
// order after a delay.
class MIGModel
{
public:
    explicit MIGModel(std::mt19937 &rng) : rng(rng)
    {
    }

    // Drive inputs for the next edge.
    void drive(VAXIMIGBridge &dut)
    {
        std::uniform_int_distribution<int> pct(0, 99);
        dut.app_rdy = pct(rng) < 70;
        dut.app_wdf_rdy = pct(rng) < 70;
        dut.app_rd_data_valid = 0;
        dut.app_rd_data_end = 0;
        if (!reads.empty() && reads.front().delay == 0) {
            for (int i = 0; i < 4; ++i)
                dut.app_rd_data[i] = reads.front().data[i];
            dut.app_rd_data_valid = 1;
            dut.app_rd_data_end = 1;
        }
    }

    // Sample the handshakes at the edge.
    void sample(VAXIMIGBridge &dut)
    {
        if (dut.app_rd_data_valid)
            reads.pop_front();
        for (auto &r : reads)
            if (r.delay)
                --r.delay;

        if (dut.app_wdf_wren && dut.app_wdf_rdy) {
            EXPECT_TRUE(dut.app_wdf_end);
            Wdf w;
            for (int i = 0; i < 4; ++i)
                w.data[i] = dut.app_wdf_data[i];
            w.mask = dut.app_wdf_mask;
            wdf.push_back(w);
        }
        if (dut.app_en && dut.app_rdy) {
            uint32_t addr = dut.app_addr;
            EXPECT_EQ(addr & 7, 0u);
            auto &line = mem[addr >> 3];
            if (dut.app_cmd == 0) {
                ASSERT_FALSE(wdf.empty()) << "write command without data";
                auto w = wdf.front();
                wdf.pop_front();
                auto *bytes = reinterpret_cast<uint8_t *>(w.data);
                for (int i = 0; i < 16; ++i)
                    if (!(w.mask & (1u << i)))
                        line[i] = bytes[i];
            } else if (dut.app_cmd == 1) {
                ++read_cmds;
                Read r;
                memcpy(r.data, line.data(), 16);
                r.delay = std::uniform_int_distribution<int>(2, 12)(rng);
                reads.push_back(r);
            } else {
                ADD_FAILURE() << "unexpected command " << unsigned(dut.app_cmd);
            }
        }
    }

    std::map<uint32_t, std::array<uint8_t, 16>> mem;
    unsigned read_cmds = 0;

private:
    struct Wdf {
        uint32_t data[4];
        uint16_t mask;
    };
    struct Read {
        uint32_t data[4];
        int delay;
    };

    std::mt19937 &rng;
    std::deque<Wdf> wdf;
    std::deque<Read> reads;
};

class AXIMIGBridgeTest : public ::testing::Test
{
protected:
    AXIMIGBridgeTest() : mig(rng)
    {
        dut.init_calib_complete = 1;
        dut.reset = 1;
        tick();
        tick();
        dut.reset = 0;
    }

    void tick()
    {
        mig.drive(dut);
        dut.clk = 0;
        dut.eval();
        mig.sample(dut);
        dut.clk = 1;
        dut.eval();
        if (++cycles > 10000000)
            FAIL() << "timeout";
    }

    // Helpers for the packed per-port fields.
    template <typename T>
    static void set(T &field, unsigned port, unsigned width, uint64_t v)
    {
        uint64_t mask = ((1ull << width) - 1) << (port * width);
        field = (static_cast<uint64_t>(field) & ~mask) |
                ((v << (port * width)) & mask);
    }

    template <typename T>
    static uint64_t get(T field, unsigned port, unsigned width)
    {
        return (static_cast<uint64_t>(field) >> (port * width)) &
               ((1ull << width) - 1);
    }

    template <typename F>
    void wait_for(F cond)
    {
        for (int i = 0; i < 1000 && !cond(); ++i)
            tick();
        ASSERT_TRUE(cond()) << "timed out waiting";
    }

    // with_aw presents the first beat with the address (as the core does),
    // b_delay holds off bready.
    void write(uint32_t addr, const std::vector<uint32_t> &data,
               uint8_t strb = 0xf, unsigned port = 0, bool with_aw = false,
               unsigned b_delay = 0)
    {
        set(dut.s_axi_awaddr, port, 32, addr);
        set(dut.s_axi_awlen, port, 8, data.size() - 1);
        set(dut.s_axi_awvalid, port, 1, 1);
        size_t first = 0;
        if (with_aw) {
            set(dut.s_axi_wdata, port, 32, data[0]);
            set(dut.s_axi_wstrb, port, 4, strb);
            set(dut.s_axi_wvalid, port, 1, 1);
        }
        dut.eval();
        wait_for([&] { return get(dut.s_axi_awready, port, 1); });
        if (with_aw && get(dut.s_axi_wready, port, 1))
            first = 1;
        tick();
        set(dut.s_axi_awvalid, port, 1, 0);
        set(dut.s_axi_wvalid, port, 1, 0);
        for (size_t i = first; i < data.size(); ++i) {
            set(dut.s_axi_wdata, port, 32, data[i]);
            set(dut.s_axi_wstrb, port, 4, strb);
            set(dut.s_axi_wvalid, port, 1, 1);
            dut.eval();
            wait_for([&] { return get(dut.s_axi_wready, port, 1); });
            tick();
            set(dut.s_axi_wvalid, port, 1, 0);
        }
        for (unsigned i = 0; i < b_delay; ++i)
            tick();
        set(dut.s_axi_bready, port, 1, 1);
        dut.eval();
        wait_for([&] { return get(dut.s_axi_bvalid, port, 1); });
        EXPECT_EQ(get(dut.s_axi_bresp, port, 2), 0u);
        tick();
        set(dut.s_axi_bready, port, 1, 0);
    }

    // r_delay holds off rready for each beat, the data must be held.
    std::vector<uint32_t> read(uint32_t addr, unsigned beats, unsigned port = 0,
                               unsigned r_delay = 0)
    {
        std::vector<uint32_t> out;
        set(dut.s_axi_araddr, port, 32, addr);
        set(dut.s_axi_arlen, port, 8, beats - 1);
        set(dut.s_axi_arvalid, port, 1, 1);
        dut.eval();
        wait_for([&] { return get(dut.s_axi_arready, port, 1); });
        tick();
        set(dut.s_axi_arvalid, port, 1, 0);
        set(dut.s_axi_rready, port, 1, 1);
        for (unsigned i = 0; i < beats; ++i) {
            dut.eval();
            if (r_delay) {
                set(dut.s_axi_rready, port, 1, 0);
                dut.eval();
                wait_for([&] { return get(dut.s_axi_rvalid, port, 1); });
                uint32_t first = get(dut.s_axi_rdata, port, 32);
                for (unsigned d = 0; d < r_delay; ++d) {
                    tick();
                    dut.eval();
                    EXPECT_TRUE(get(dut.s_axi_rvalid, port, 1));
                    EXPECT_EQ(get(dut.s_axi_rdata, port, 32), first);
                }
                set(dut.s_axi_rready, port, 1, 1);
                dut.eval();
            }
            wait_for([&] { return get(dut.s_axi_rvalid, port, 1); });
            out.push_back(get(dut.s_axi_rdata, port, 32));
            EXPECT_EQ(get(dut.s_axi_rlast, port, 1), i == beats - 1);
            tick();
        }
        set(dut.s_axi_rready, port, 1, 0);
        return out;
    }

    std::mt19937 rng{1234};
    VAXIMIGBridge dut;
    MIGModel mig;
    uint64_t cycles = 0;
};

TEST_F(AXIMIGBridgeTest, SingleWordReadWrite)
{
    for (uint32_t a = 0x80000000; a < 0x80000040; a += 4)
        write(a, {a ^ 0x5a5a5a5au});
    for (uint32_t a = 0x80000000; a < 0x80000040; a += 4)
        EXPECT_EQ(read(a, 1)[0], a ^ 0x5a5a5a5au) << std::hex << a;
}

TEST_F(AXIMIGBridgeTest, ByteStrobes)
{
    write(0x80001000, {0x11223344});
    write(0x80001000, {0xaabbccdd}, 0x2);
    write(0x80001000, {0xaabbccdd}, 0x8);
    EXPECT_EQ(read(0x80001000, 1)[0], 0xaa22cc44u);
}

TEST_F(AXIMIGBridgeTest, Bursts)
{
    std::vector<uint32_t> line;
    for (int i = 0; i < 16; ++i)
        line.push_back(0x1000 + i);
    write(0x80002040, line);
    EXPECT_EQ(read(0x80002040, 16), line);
    // Again, hitting, with rready held off on every beat.
    EXPECT_EQ(read(0x80002040, 16, 0, 2), line);
    // Unaligned to the 16 byte MIG granule.
    EXPECT_EQ(read(0x80002048, 4),
              (std::vector<uint32_t>{0x1002, 0x1003, 0x1004, 0x1005}));
}

TEST_F(AXIMIGBridgeTest, DMAPort)
{
    std::vector<uint32_t> line;
    for (int i = 0; i < 16; ++i)
        line.push_back(0x2000 + i);
    write(0x80003000, line, 0xf, 1);
    EXPECT_EQ(read(0x80003000, 16, 0), line);
    write(0x80003004, {0x12345678}, 0xf, 0);
    EXPECT_EQ(read(0x80003000, 2, 1), (std::vector<uint32_t>{0x2000, 0x12345678}));
}

// The tests use 8 sets of 2 ways: lines 128 bytes apart share a set.
constexpr uint32_t set_stride = 8 * 16;

// A read hit returns data in the cycle after the AR handshake (RD_CHECK, the
// arrays are read with the request's address while idle) and a write
// accepts the data with the address and posts the response in the next
// cycle.
TEST_F(AXIMIGBridgeTest, HitLatency)
{
    write(0x80005004, {0x80005004u ^ 0x5a5a5a5au});
    read(0x80005000, 1);

    set(dut.s_axi_araddr, 0, 32, 0x80005004);
    set(dut.s_axi_arlen, 0, 8, 0);
    set(dut.s_axi_arvalid, 0, 1, 1);
    dut.eval();
    ASSERT_TRUE(get(dut.s_axi_arready, 0, 1));
    tick();
    set(dut.s_axi_arvalid, 0, 1, 0);
    set(dut.s_axi_rready, 0, 1, 1);
    unsigned n = 0;
    for (dut.eval(); !get(dut.s_axi_rvalid, 0, 1) && n < 10; dut.eval(), ++n)
        tick();
    EXPECT_EQ(n, 0u);
    EXPECT_EQ(get(dut.s_axi_rdata, 0, 32), 0x80005004u ^ 0x5a5a5a5au);
    tick();
    set(dut.s_axi_rready, 0, 1, 0);

    // AW and W together, as the core issues them.
    set(dut.s_axi_awaddr, 0, 32, 0x80005008);
    set(dut.s_axi_awlen, 0, 8, 0);
    set(dut.s_axi_awvalid, 0, 1, 1);
    set(dut.s_axi_wdata, 0, 32, 0xfeedf00d);
    set(dut.s_axi_wstrb, 0, 4, 0xf);
    set(dut.s_axi_wvalid, 0, 1, 1);
    set(dut.s_axi_bready, 0, 1, 1);
    dut.eval();
    ASSERT_TRUE(get(dut.s_axi_awready, 0, 1));
    ASSERT_TRUE(get(dut.s_axi_wready, 0, 1));
    tick();
    set(dut.s_axi_awvalid, 0, 1, 0);
    set(dut.s_axi_wvalid, 0, 1, 0);
    n = 0;
    for (dut.eval(); !get(dut.s_axi_bvalid, 0, 1) && n < 10; dut.eval(), ++n)
        tick();
    EXPECT_EQ(n, 0u);
    tick();
    set(dut.s_axi_bready, 0, 1, 0);

    EXPECT_EQ(read(0x80005008, 1)[0], 0xfeedf00du);
}

TEST_F(AXIMIGBridgeTest, CacheHits)
{
    write(0x80005000, {0xcafef00d});
    EXPECT_EQ(read(0x80005000, 1)[0], 0xcafef00du);
    auto before = mig.read_cmds;
    // The rest of the line and repeated reads hit.
    EXPECT_EQ(read(0x80005000, 1)[0], 0xcafef00du);
    read(0x80005004, 3);
    EXPECT_EQ(mig.read_cmds, before);
    // Two other lines in the same set fit alongside it.
    read(0x80005000 + set_stride, 1);
    EXPECT_EQ(read(0x80005000, 1)[0], 0xcafef00du);
    EXPECT_EQ(mig.read_cmds, before + 1);
    // A third evicts one of them.
    read(0x80005000 + 2 * set_stride, 1);
    read(0x80005000, 1);
    read(0x80005000 + set_stride, 1);
    EXPECT_EQ(mig.read_cmds, before + 4);
}

TEST_F(AXIMIGBridgeTest, WriteBack)
{
    const uint32_t a = 0x80007000;
    const uint32_t key = (a & 0x0fffffff) >> 4;
    write(a, {0x11111111});
    EXPECT_EQ(read(a, 1)[0], 0x11111111u);
    // A write that hits only updates the cache.
    write(a + 4, {0x12345678}, 0x3);
    EXPECT_EQ(read(a + 4, 1)[0] & 0xffff, 0x5678u);
    EXPECT_NE(mig.mem[key][4], 0x78);
    // Evicting the line writes it back.
    read(a + set_stride, 1);
    read(a + 2 * set_stride, 1);
    read(a + 3 * set_stride, 1);
    EXPECT_EQ(mig.mem[key][4], 0x78);
    EXPECT_EQ(mig.mem[key][5], 0x56);
    EXPECT_EQ(mig.mem[key][0], 0x11);
    EXPECT_EQ(read(a + 4, 1)[0] & 0xffff, 0x5678u);
}

// A posted write response that hasn't been accepted holds off the other
// port, otherwise its response would be lost.
TEST_F(AXIMIGBridgeTest, PostedResponseBlocks)
{
    set(dut.s_axi_awaddr, 0, 32, 0x80006000);
    set(dut.s_axi_awlen, 0, 8, 0);
    set(dut.s_axi_wdata, 0, 32, 0x11111111);
    set(dut.s_axi_wstrb, 0, 4, 0xf);
    dut.s_axi_awvalid = 1;
    dut.s_axi_wvalid = 1;
    dut.s_axi_bready = 0;
    dut.eval();
    ASSERT_TRUE(get(dut.s_axi_awready, 0, 1));
    ASSERT_TRUE(get(dut.s_axi_wready, 0, 1));
    tick();
    dut.s_axi_awvalid = 0;
    dut.s_axi_wvalid = 0;

    // The DMA port's write must wait for port 0's response.
    set(dut.s_axi_awaddr, 1, 32, 0x80006010);
    set(dut.s_axi_awlen, 1, 8, 0);
    set(dut.s_axi_wdata, 1, 32, 0x22222222);
    set(dut.s_axi_wstrb, 1, 4, 0xf);
    dut.s_axi_awvalid = 2;
    dut.s_axi_wvalid = 2;
    for (int i = 0; i < 20; ++i) {
        dut.eval();
        EXPECT_TRUE(get(dut.s_axi_bvalid, 0, 1));
        EXPECT_FALSE(get(dut.s_axi_awready, 1, 1));
        tick();
    }
    dut.s_axi_bready = 3;
    bool b0 = false, b1 = false;
    for (int i = 0; i < 100 && !(b0 && b1); ++i) {
        dut.eval();
        if (get(dut.s_axi_awready, 1, 1)) {
            tick();
            dut.s_axi_awvalid = 0;
            dut.s_axi_wvalid = 0;
            continue;
        }
        b0 |= get(dut.s_axi_bvalid, 0, 1);
        b1 |= get(dut.s_axi_bvalid, 1, 1);
        tick();
    }
    EXPECT_TRUE(b0);
    EXPECT_TRUE(b1);
    dut.s_axi_bready = 0;
    EXPECT_EQ(read(0x80006000, 1)[0], 0x11111111u);
    EXPECT_EQ(read(0x80006010, 1)[0], 0x22222222u);
}

TEST_F(AXIMIGBridgeTest, WriteMissNoAllocate)
{
    const uint32_t a = 0x80008000;
    write(a, {0xdeadbeef});
    // The write went straight to the DRAM and didn't allocate (the response
    // is posted, the read is ordered after the write completes).
    auto before = mig.read_cmds;
    EXPECT_EQ(read(a, 1)[0], 0xdeadbeefu);
    EXPECT_EQ(mig.read_cmds, before + 1);
    EXPECT_EQ(mig.mem[(a & 0x0fffffff) >> 4][0], 0xef);
}

TEST_F(AXIMIGBridgeTest, DMACoherent)
{
    write(0x80006000, {0x11111111}, 0xf, 0);
    EXPECT_EQ(read(0x80006000, 1, 0)[0], 0x11111111u);
    // DMA writes the cached line, the CPU sees the new data.
    write(0x80006000, {0x22222222}, 0xf, 1);
    EXPECT_EQ(read(0x80006000, 1, 0)[0], 0x22222222u);
    // DMA reads dirty data written by the CPU before it reaches the DRAM.
    write(0x80006004, {0x33333333}, 0xf, 0);
    EXPECT_EQ(read(0x80006000, 2, 1),
              (std::vector<uint32_t>{0x22222222, 0x33333333}));
}

TEST_F(AXIMIGBridgeTest, SimultaneousRequests)
{
    write(0x80004000, {0x11111111}, 0xf, 0);
    write(0x80004004, {0x22222222}, 0xf, 1);
    // Both ports request at once, both must complete.
    set(dut.s_axi_araddr, 0, 32, 0x80004000);
    set(dut.s_axi_araddr, 1, 32, 0x80004004);
    set(dut.s_axi_arlen, 0, 8, 0);
    set(dut.s_axi_arlen, 1, 8, 0);
    dut.s_axi_arvalid = 3;
    dut.s_axi_rready = 3;
    uint32_t got[2] = {0, 0};
    bool done[2] = {false, false};
    for (int i = 0; i < 1000 && !(done[0] && done[1]); ++i) {
        dut.eval();
        for (unsigned p = 0; p < 2; ++p) {
            if (get(dut.s_axi_arready, p, 1))
                ; // accepted at this edge
            if (get(dut.s_axi_rvalid, p, 1)) {
                got[p] = get(dut.s_axi_rdata, p, 32);
                done[p] = true;
            }
        }
        uint8_t accepted = dut.s_axi_arready;
        tick();
        dut.s_axi_arvalid &= ~accepted;
    }
    EXPECT_TRUE(done[0] && done[1]);
    EXPECT_EQ(got[0], 0x11111111u);
    EXPECT_EQ(got[1], 0x22222222u);
}

TEST_F(AXIMIGBridgeTest, Random)
{
    std::map<uint32_t, uint32_t> ref;
    std::uniform_int_distribution<uint32_t> word(0, 255), val;
    for (int i = 0; i < 2000; ++i) {
        // 1KB of addresses over a 256 byte cache: lots of evictions.
        uint32_t a = 0x80000000 + word(rng) * 4;
        unsigned port = val(rng) & 1;
        if (val(rng) & 1) {
            uint8_t strb = (val(rng) & 0xf) | 1;
            uint32_t v = val(rng);
            write(a, {v}, strb, port, val(rng) & 1, val(rng) % 3);
            auto &r = ref[a];
            for (int b = 0; b < 4; ++b)
                if (strb & (1 << b))
                    r = (r & ~(0xffu << (8 * b))) | (v & (0xffu << (8 * b)));
        } else {
            EXPECT_EQ(read(a, 1, port, val(rng) % 3)[0], ref[a]) << std::hex << a;
        }
    }
}
} // namespace
