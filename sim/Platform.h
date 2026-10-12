// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <memory>
#include <vector>

#include "Hart.h"
#include "Soc.h"

// The ISS on the reference platform.  With several harts each executes one
// step in turn, so an instruction (including an AMO) is atomic.
class Platform
{
public:
    Platform(const Config &core, const SocOptions &opts) : soc(opts)
    {
        for (unsigned h = 0; h < opts.harts; ++h) {
            Config c = core;
            c.hart_id = h;
            harts.push_back(std::make_unique<Hart>(c, soc.bus));
        }
    }

    void step()
    {
        for (auto &h : harts)
            h->step();
        soc.tick();
        for (unsigned h = 0; h < harts.size(); ++h) {
            auto irq = soc.irqs(h);
            harts[h]->set_interrupt_lines(irq.meip, irq.seip, irq.mtip,
                                          irq.msip);
        }
    }

    Hart &hart(unsigned h = 0)
    {
        return *harts[h];
    }

    bool halted() const
    {
        for (auto &h : harts)
            if (h->is_halted())
                return true;
        return false;
    }

    bool stopped() const
    {
        return halted() || soc.stopped();
    }

    Soc soc;
    std::vector<std::unique_ptr<Hart>> harts;
};
