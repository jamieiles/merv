// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>

// Build time configuration of the core, mirrors the RTL parameters.
struct Config {
    unsigned tlb_entries = 4;
    bool native_amo = true;
    bool hw_div = true;
    bool hw_mul = true;
    // Only changes the timing of the RTL (and fconfig).
    bool barrel_shift = false;
    uint32_t reset_vector = 0x40000000;
    // fconfig[31:24], emulated mhartid.
    unsigned hart_id = 0;
    // LR/SC and AMOs use AXI exclusive accesses (RTL only).
    bool axi_exclusive = false;
};

namespace merv
{
constexpr uint32_t fram_base = 0x00000000;
constexpr uint32_t fram_size = 8192;
// F mode entry points: TLB misses enter at fram_tlb_entry, reset and every
// other event at fram_base.
constexpr uint32_t fram_tlb_entry = 0x00000004;
// Register window at the top of the F-RAM: GPR banks 0 and 1, then reserved.
constexpr uint32_t fram_regs = 0x1e00;
constexpr uint32_t fram_regs_end = 0x1f00;
constexpr uint32_t bootrom_base = 0x40000000;
constexpr uint32_t bootrom_size = 0x10000;
constexpr uint32_t dram_base = 0x80000000;
constexpr uint32_t clint_base = 0xf0000000;
constexpr uint32_t clint_size = 0xc000;
constexpr uint32_t syscon_base = 0xf000c000;
constexpr uint32_t syscon_size = 0x1000;
constexpr uint32_t plic_base = 0xf8000000;
constexpr uint32_t plic_size = 0x400000;
constexpr uint32_t uart_base = 0xffff1000;
constexpr uint32_t uart_size = 0x1000;
} // namespace merv
