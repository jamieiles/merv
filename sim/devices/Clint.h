// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <vector>

#include "../Bus.h"

// SiFive compatible CLINT: msip at 0x0 + 4 * hart, mtimecmp at
// 0x4000 + 8 * hart and mtime at 0xbff8.  mtime increments every `divider`
// calls to tick() so that simulated time is a deterministic function of
// instructions executed.
class Clint : public Device
{
public:
    Clint(unsigned divider, unsigned harts)
        : divider(divider), msip_reg(harts, 0), mtimecmp(harts, ~0ULL)
    {
    }

    void tick()
    {
        if (++count >= divider) {
            count = 0;
            ++mtime;
        }
    }

    bool mtip(unsigned hart) const
    {
        return mtime >= mtimecmp[hart];
    }

    bool msip(unsigned hart) const
    {
        return msip_reg[hart] & 1;
    }

    uint64_t get_mtime() const
    {
        return mtime;
    }

    bool read(uint32_t offset, unsigned size, uint32_t &val) override
    {
        if (size != 4)
            return false;
        val = 0;
        if (auto h = offset / 4; offset < 0x4000 && h < msip_reg.size()) {
            val = msip_reg[h];
        } else if (auto h = (offset - 0x4000) / 8;
                   offset >= 0x4000 && h < mtimecmp.size()) {
            val = static_cast<uint32_t>(mtimecmp[h] >> (offset & 4 ? 32 : 0));
        } else if (offset == 0xbff8) {
            val = static_cast<uint32_t>(mtime);
        } else if (offset == 0xbffc) {
            val = static_cast<uint32_t>(mtime >> 32);
        }
        return true;
    }

    bool write(uint32_t offset, unsigned size, uint32_t val) override
    {
        if (size != 4)
            return false;
        if (auto h = offset / 4; offset < 0x4000 && h < msip_reg.size()) {
            msip_reg[h] = val & 1;
        } else if (auto h = (offset - 0x4000) / 8;
                   offset >= 0x4000 && h < mtimecmp.size()) {
            if (offset & 4)
                mtimecmp[h] = (mtimecmp[h] & 0xffffffffULL) | (uint64_t(val) << 32);
            else
                mtimecmp[h] = (mtimecmp[h] & ~0xffffffffULL) | val;
        } else if (offset == 0xbff8) {
            mtime = (mtime & ~0xffffffffULL) | val;
        } else if (offset == 0xbffc) {
            mtime = (mtime & 0xffffffffULL) | (uint64_t(val) << 32);
        }
        return true;
    }

private:
    unsigned divider;
    unsigned count = 0;
    std::vector<uint32_t> msip_reg;
    uint64_t mtime = 0;
    std::vector<uint64_t> mtimecmp;
};
