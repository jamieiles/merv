// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "../Bus.h"

// SiFive test finisher compatible power/reset control.
class Syscon : public Device
{
public:
    enum class State { Running, PowerOff, Fail, Reset };

    bool read(uint32_t, unsigned, uint32_t &val) override
    {
        val = 0;
        return true;
    }

    bool write(uint32_t offset, unsigned size, uint32_t val) override
    {
        if (offset != 0 || size != 4)
            return true;
        switch (val & 0xffff) {
        case 0x5555: state = State::PowerOff; break;
        case 0x3333:
            state = State::Fail;
            code = val >> 16;
            break;
        case 0x7777: state = State::Reset; break;
        default: break;
        }
        return true;
    }

    State state = State::Running;
    uint32_t code = 0;
};
