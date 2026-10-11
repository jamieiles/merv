// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "Hart.h"
#include "Soc.h"

// The ISS on the reference platform.
class Platform
{
public:
    Platform(const Config &core, const SocOptions &opts)
        : soc(opts), hart(core, soc.bus)
    {
    }

    void step()
    {
        hart.step();
        soc.tick();
        auto irq = soc.irqs();
        hart.set_interrupt_lines(irq.meip, irq.seip, irq.mtip, irq.msip);
    }

    bool stopped() const
    {
        return hart.is_halted() || soc.stopped();
    }

    Soc soc;
    Hart hart;
};
