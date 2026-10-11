// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <map>
#include <string>
#include <vector>
#include <stdexcept>

#include <elf.h>

class RiscVELF {
public:
    explicit RiscVELF(const std::string &filename);
    virtual ~RiscVELF();
    uint32_t sym_addr(const std::string &name) const;
    uint32_t entry_point() const;

    template <typename T>
    std::vector<T> read_section(const std::string &name) const
    {
        auto sec = find_section(name);
        if (!sec)
            return std::vector<T>{};

        if (sec->sh_size % sizeof(T))
            throw std::runtime_error("Invalid size for " + name);

        auto contents = reinterpret_cast<const T *>(mapping + sec->sh_offset);
        return std::vector<T>(contents, contents + sec->sh_size / sizeof(T));
    }

    std::map<uint32_t, std::vector<uint8_t>> load_segments() const;

private:
    void map(const std::string &filename);
    void init_elf();
    const Elf32_Shdr *find_section(const std::string &name) const;
    void read_symbols();

    const char *mapping;
    size_t maplen;

    const Elf32_Ehdr *ehdr;
    const Elf32_Shdr *shdrs;
    const Elf32_Phdr *phdrs;

    std::map<const std::string, uint32_t> symbols;

    const char *section_strings;
};
