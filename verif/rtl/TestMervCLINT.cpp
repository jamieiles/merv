// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#include <gtest/gtest.h>

#include "VMervCLINT.h"

namespace
{
// MervCLINT built with NUM_HARTS=4: per hart msip and mtimecmp.
class MervCLINTTest : public ::testing::Test
{
protected:
    MervCLINTTest()
    {
        dut.s_axi_aresetn = 0;
        tick();
        tick();
        dut.s_axi_aresetn = 1;
        tick();
    }

    void tick()
    {
        dut.s_axi_aclk = 0;
        dut.eval();
        dut.s_axi_aclk = 1;
        dut.eval();
    }

    void write(uint16_t addr, uint32_t v)
    {
        dut.s_axi_awaddr = addr;
        dut.s_axi_wdata = v;
        dut.s_axi_wstrb = 0xf;
        dut.s_axi_awvalid = 1;
        dut.s_axi_wvalid = 1;
        dut.s_axi_bready = 1;
        dut.eval();
        ASSERT_TRUE(dut.s_axi_awready);
        tick();
        dut.s_axi_awvalid = 0;
        dut.s_axi_wvalid = 0;
        dut.eval();
        ASSERT_TRUE(dut.s_axi_bvalid);
        tick();
        dut.s_axi_bready = 0;
    }

    uint32_t read(uint16_t addr)
    {
        dut.s_axi_araddr = addr;
        dut.s_axi_arvalid = 1;
        dut.s_axi_rready = 1;
        dut.eval();
        EXPECT_TRUE(dut.s_axi_arready);
        tick();
        dut.s_axi_arvalid = 0;
        dut.eval();
        EXPECT_TRUE(dut.s_axi_rvalid);
        uint32_t v = dut.s_axi_rdata;
        tick();
        dut.s_axi_rready = 0;
        return v;
    }

    unsigned msips()
    {
        return dut.msip | dut.msip_1 << 1 | dut.msip_2 << 2 | dut.msip_3 << 3;
    }

    unsigned mtips()
    {
        return dut.mtime_irq | dut.mtime_irq_1 << 1 | dut.mtime_irq_2 << 2 |
               dut.mtime_irq_3 << 3;
    }

    VMervCLINT dut;
};

TEST_F(MervCLINTTest, Msip)
{
    EXPECT_EQ(msips(), 0u);
    for (unsigned h = 0; h < 4; ++h) {
        write(4 * h, 1);
        EXPECT_EQ(msips(), 1u << h);
        EXPECT_EQ(read(4 * h), 1u);
        for (unsigned o = 0; o < 4; ++o)
            if (o != h)
                EXPECT_EQ(read(4 * o), 0u);
        write(4 * h, 0);
        EXPECT_EQ(msips(), 0u);
    }
    // Beyond the last hart: ignored.
    write(16, 1);
    EXPECT_EQ(msips(), 0u);
    EXPECT_EQ(read(16), 0u);
}

TEST_F(MervCLINTTest, Mtimecmp)
{
    // Stop mtime advancing past the compares.
    write(0xbff8, 100);
    write(0xbffc, 0);
    for (unsigned h = 0; h < 4; ++h) {
        write(0x4000 + 8 * h, 0x1000 + h);
        write(0x4004 + 8 * h, 0x10 + h);
    }
    for (unsigned h = 0; h < 4; ++h) {
        EXPECT_EQ(read(0x4000 + 8 * h), 0x1000 + h);
        EXPECT_EQ(read(0x4004 + 8 * h), 0x10 + h);
    }
    tick();
    EXPECT_EQ(mtips(), 0u);
    // Only hart 2's compare is below mtime.
    write(0x4014, 0);
    write(0x4010, 50);
    tick();
    tick();
    EXPECT_EQ(mtips(), 1u << 2);
    EXPECT_EQ(read(0xbffc), 0u);
}
} // namespace
