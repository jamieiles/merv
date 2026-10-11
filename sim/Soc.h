// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <string>

#include "Bus.h"
#include "Config.h"
#include "devices/Clint.h"
#include "devices/Plic.h"
#include "devices/Syscon.h"
#include "devices/Uart16550.h"

struct SocOptions {
    size_t dram_size = 128 << 20;
    unsigned mtime_divider = 10;
    std::string uart_log;
    bool uart_echo = true;
    bool uart_input = false;
};

struct IrqLines {
    bool meip, seip, mtip, msip;
};

// The reference simulation platform without a core: boot ROM, DRAM, CLINT,
// PLIC, 16550 UART and a test finisher.
class Soc
{
public:
    static constexpr unsigned uart_irq = 1;

    explicit Soc(const SocOptions &opts)
        : dram(opts.dram_size),
          bootrom(merv::bootrom_size),
          clint(opts.mtime_divider),
          uart(opts.uart_log, opts.uart_echo, opts.uart_input)
    {
        bus.set_dram(merv::dram_base, &dram);
        bus.add(merv::bootrom_base, merv::bootrom_size, &bootrom);
        bus.add(merv::clint_base, merv::clint_size, &clint);
        bus.add(merv::syscon_base, merv::syscon_size, &syscon);
        bus.add(merv::plic_base, merv::plic_size, &plic);
        bus.add(merv::uart_base, merv::uart_size, &uart);
    }

    // Advance time by one ISS step or RTL clock cycle.
    void tick()
    {
        clint.tick();
        if ((++count & 0xfff) == 0)
            uart.poll_input();
    }

    IrqLines irqs()
    {
        plic.set_source(uart_irq, uart.irq());
        return {plic.irq(0), plic.irq(1), clint.mtip(), clint.msip()};
    }

    bool stopped() const
    {
        return syscon.state != Syscon::State::Running;
    }

    Bus bus;
    Ram dram;
    Ram bootrom;
    Clint clint;
    Plic plic;
    Uart16550 uart;
    Syscon syscon;

private:
    uint64_t count = 0;
};

// Accepts any access, used for the MMIO regions of the co-simulation ISS
// whose load results come from the RTL.
class SinkDevice : public Device
{
public:
    bool read(uint32_t, unsigned, uint32_t &val) override
    {
        val = 0;
        return true;
    }

    bool write(uint32_t, unsigned, uint32_t) override
    {
        return true;
    }
};

// Memory map matching Soc with RAM backed DRAM/boot ROM and the devices
// replaced by sinks.
class MirrorSoc
{
public:
    explicit MirrorSoc(size_t dram_size)
        : dram(dram_size), bootrom(merv::bootrom_size)
    {
        bus.set_dram(merv::dram_base, &dram);
        bus.add(merv::bootrom_base, merv::bootrom_size, &bootrom);
        bus.add(merv::clint_base, merv::clint_size, &sink);
        bus.add(merv::syscon_base, merv::syscon_size, &sink);
        bus.add(merv::plic_base, merv::plic_size, &sink);
        bus.add(merv::uart_base, merv::uart_size, &sink);
    }

    static bool is_mmio(uint32_t pa)
    {
        return pa >= merv::clint_base;
    }

    Bus bus;
    Ram dram;
    Ram bootrom;
    SinkDevice sink;
};
