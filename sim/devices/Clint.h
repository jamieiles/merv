// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "../Bus.h"

// SiFive compatible CLINT for a single hart: msip at 0x0, mtimecmp at 0x4000
// and mtime at 0xbff8.  mtime increments every `divider` calls to tick() so
// that simulated time is a deterministic function of instructions executed.
class Clint : public Device
{
public:
    explicit Clint(unsigned divider) : divider(divider)
    {
    }

    void tick()
    {
        if (++count >= divider) {
            count = 0;
            ++mtime;
        }
    }

    bool mtip() const
    {
        return mtime >= mtimecmp;
    }

    bool msip() const
    {
        return msip_reg & 1;
    }

    uint64_t get_mtime() const
    {
        return mtime;
    }

    bool read(uint32_t offset, unsigned size, uint32_t &val) override
    {
        if (size != 4)
            return false;
        switch (offset) {
        case 0x0: val = msip_reg; return true;
        case 0x4000: val = static_cast<uint32_t>(mtimecmp); return true;
        case 0x4004: val = static_cast<uint32_t>(mtimecmp >> 32); return true;
        case 0xbff8: val = static_cast<uint32_t>(mtime); return true;
        case 0xbffc: val = static_cast<uint32_t>(mtime >> 32); return true;
        default: val = 0; return true;
        }
    }

    bool write(uint32_t offset, unsigned size, uint32_t val) override
    {
        if (size != 4)
            return false;
        switch (offset) {
        case 0x0: msip_reg = val & 1; break;
        case 0x4000: mtimecmp = (mtimecmp & ~0xffffffffULL) | val; break;
        case 0x4004:
            mtimecmp = (mtimecmp & 0xffffffffULL) | (uint64_t(val) << 32);
            break;
        case 0xbff8: mtime = (mtime & ~0xffffffffULL) | val; break;
        case 0xbffc:
            mtime = (mtime & 0xffffffffULL) | (uint64_t(val) << 32);
            break;
        default: break;
        }
        return true;
    }

private:
    unsigned divider;
    unsigned count = 0;
    uint32_t msip_reg = 0;
    uint64_t mtime = 0;
    uint64_t mtimecmp = ~0ULL;
};
