// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <vector>

// A memory mapped device.  Accesses are naturally aligned and 1, 2 or 4 bytes
// wide, the value is the zero-extended little-endian value of the bytes at
// offset (not positioned on byte lanes).  Returning false signals a bus error.
class Device
{
public:
    virtual ~Device() = default;
    virtual bool read(uint32_t offset, unsigned size, uint32_t &val) = 0;
    virtual bool write(uint32_t offset, unsigned size, uint32_t val) = 0;
};

class Ram : public Device
{
public:
    explicit Ram(size_t size) : mem(size, 0)
    {
    }

    bool read(uint32_t offset, unsigned size, uint32_t &val) override
    {
        if (offset + size > mem.size())
            return false;
        val = 0;
        memcpy(&val, &mem[offset], size);
        return true;
    }

    bool write(uint32_t offset, unsigned size, uint32_t val) override
    {
        if (offset + size > mem.size())
            return false;
        memcpy(&mem[offset], &val, size);
        return true;
    }

    uint8_t *data()
    {
        return mem.data();
    }

    size_t size() const
    {
        return mem.size();
    }

private:
    std::vector<uint8_t> mem;
};

class Bus
{
public:
    // An LR reservation of one of the harts sharing the bus.  A store by any
    // other hart to the reserved word clears it, as the exclusive monitor
    // in the DDR bridge does.
    struct Reservation {
        bool valid = false;
        uint32_t addr = 0;
    };

    void add_reservation(Reservation *r)
    {
        reservations.push_back(r);
    }

    void snoop_store(const Reservation *self, uint32_t addr)
    {
        if (reservations.size() < 2)
            return;
        for (auto *r : reservations)
            if (r != self && r->valid && (r->addr >> 2) == (addr >> 2))
                r->valid = false;
    }

    void add(uint32_t base, uint32_t size, Device *dev)
    {
        regions.push_back({base, size, dev});
    }

    // DRAM gets a fast path as it's the overwhelmingly common target.
    void set_dram(uint32_t base, Ram *ram)
    {
        dram_base = base;
        dram = ram;
        add(base, ram->size(), ram);
    }

    bool read(uint32_t addr, unsigned size, uint32_t &val)
    {
        if (dram && addr - dram_base < dram->size()) {
            val = 0;
            memcpy(&val, dram->data() + (addr - dram_base), size);
            return true;
        }
        for (auto &r : regions)
            if (addr - r.base < r.size)
                return r.dev->read(addr - r.base, size, val);
        return false;
    }

    bool write(uint32_t addr, unsigned size, uint32_t val)
    {
        if (dram && addr - dram_base < dram->size()) {
            memcpy(dram->data() + (addr - dram_base), &val, size);
            return true;
        }
        for (auto &r : regions)
            if (addr - r.base < r.size)
                return r.dev->write(addr - r.base, size, val);
        return false;
    }

    // Backdoor loading for images, throws if the range isn't backed by RAM.
    void load(uint32_t addr, const uint8_t *data, size_t len)
    {
        for (size_t i = 0; i < len; ++i)
            if (!write(addr + i, 1, data[i]))
                throw std::runtime_error("load outside of memory at " +
                                         std::to_string(addr + i));
    }

private:
    struct Region {
        uint32_t base;
        uint32_t size;
        Device *dev;
    };
    std::vector<Region> regions;
    std::vector<Reservation *> reservations;
    uint32_t dram_base = 0;
    Ram *dram = nullptr;
};
