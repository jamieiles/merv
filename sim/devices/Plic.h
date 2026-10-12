// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <vector>

#include "../Bus.h"

// SiFive compatible PLIC with level triggered sources 1..31 and two contexts
// per hart (2h = M mode external interrupt, 2h + 1 = S mode external
// interrupt), matching the RTL PLIC in fpga/common/PLIC.sv:
//
//   0x000000 + 4 * id         source priority
//   0x001000                  pending bits
//   0x002000 + 0x80 * ctx     enable bits
//   0x200000 + 0x1000 * ctx   priority threshold
//   0x200004 + 0x1000 * ctx   claim/complete
//
// A source is pending while its input is high and it hasn't been claimed,
// once claimed it is not pending again until the claim is completed.
class Plic : public Device
{
public:
    static constexpr uint32_t priority_mask = 0x7;

    explicit Plic(unsigned harts)
        : num_contexts(2 * harts), enable(num_contexts), threshold(num_contexts)
    {
    }

    void set_source(unsigned id, bool level)
    {
        if (level)
            levels |= 1u << id;
        else
            levels &= ~(1u << id);
    }

    bool irq(unsigned ctx) const
    {
        auto id = best(ctx);
        return id != 0 && priority[id] > threshold[ctx];
    }

    bool read(uint32_t offset, unsigned size, uint32_t &val) override
    {
        if (size != 4)
            return false;
        val = 0;
        if (offset < 0x1000) {
            val = priority[(offset / 4) & 31];
        } else if (offset == 0x1000) {
            val = pending();
        } else if (offset >= 0x2000 && offset < 0x2000 + 0x80 * num_contexts) {
            if ((offset & 0x7f) == 0)
                val = enable[(offset - 0x2000) / 0x80];
        } else if (offset >= 0x200000 &&
                   offset < 0x200000 + 0x1000 * num_contexts) {
            auto ctx = (offset - 0x200000) / 0x1000;
            if ((offset & 0xfff) == 0) {
                val = threshold[ctx];
            } else if ((offset & 0xfff) == 4) {
                val = best(ctx);
                if (val)
                    claimed |= 1u << val;
            }
        }
        return true;
    }

    bool write(uint32_t offset, unsigned size, uint32_t val) override
    {
        if (size != 4)
            return false;
        if (offset < 0x1000) {
            auto id = (offset / 4) & 31;
            if (id)
                priority[id] = val & priority_mask;
        } else if (offset >= 0x2000 && offset < 0x2000 + 0x80 * num_contexts) {
            if ((offset & 0x7f) == 0)
                enable[(offset - 0x2000) / 0x80] = val & ~1u;
        } else if (offset >= 0x200000 &&
                   offset < 0x200000 + 0x1000 * num_contexts) {
            auto ctx = (offset - 0x200000) / 0x1000;
            if ((offset & 0xfff) == 0)
                threshold[ctx] = val & priority_mask;
            else if ((offset & 0xfff) == 4 && val < 32)
                claimed &= ~(1u << val);
        }
        return true;
    }

private:
    uint32_t pending() const
    {
        return levels & ~claimed & ~1u;
    }

    // Highest priority pending and enabled source, lowest ID wins ties.
    unsigned best(unsigned ctx) const
    {
        auto p = pending() & enable[ctx];
        unsigned best_id = 0;
        uint32_t best_prio = 0;
        for (unsigned id = 1; id < 32; ++id) {
            if ((p & (1u << id)) && priority[id] > best_prio) {
                best_id = id;
                best_prio = priority[id];
            }
        }
        return best_id;
    }

    unsigned num_contexts;
    uint32_t levels = 0;
    uint32_t claimed = 0;
    uint32_t priority[32]{};
    std::vector<uint32_t> enable;
    std::vector<uint32_t> threshold;
};
