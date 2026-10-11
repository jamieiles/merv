// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#include <cstring>
#include <iomanip>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include <boost/io/ios_state.hpp>

#include <fcntl.h>
#include <unistd.h>

#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>

#include "RiscVELF.h"

RiscVELF::RiscVELF(const std::string &filename)
{
    map(filename);
    init_elf();
    read_symbols();
}

RiscVELF::~RiscVELF()
{
    munmap(static_cast<void *>(const_cast<char *>(mapping)), maplen);
}

uint32_t RiscVELF::sym_addr(const std::string &name) const
{
    return symbols.at(name);
}

uint32_t RiscVELF::entry_point() const
{
    return ehdr->e_entry;
}

std::map<uint32_t, std::vector<uint8_t>> RiscVELF::load_segments() const
{
    std::map<uint32_t, std::vector<uint8_t>> segments;

    for (auto phdr = phdrs; phdr < phdrs + ehdr->e_phnum; ++phdr) {
        if (phdr->p_type != PT_LOAD)
            continue;

        auto addr = phdr->p_vaddr;
        auto bytes =
            std::vector<uint8_t>(mapping + phdr->p_offset,
                                 mapping + phdr->p_offset + phdr->p_filesz);
        segments[addr] = bytes;
    }

    return segments;
}

void RiscVELF::map(const std::string &filename)
{
    int fd = open(filename.c_str(), O_RDONLY);
    if (fd < 0)
        throw std::runtime_error("failed to open " + filename);

    struct stat st;
    if (fstat(fd, &st) < 0)
        throw std::runtime_error("failed to stat " + filename);

    maplen = ((st.st_size + getpagesize() - 1) / getpagesize()) * getpagesize();
    mapping = static_cast<const char *>(
        mmap(NULL, maplen, PROT_READ, MAP_PRIVATE, fd, 0));
    if (mapping == MAP_FAILED)
        throw std::runtime_error("failed to map " + filename);

    close(fd);
}

void RiscVELF::init_elf()
{
    ehdr = reinterpret_cast<const Elf32_Ehdr *>(mapping);
    shdrs = reinterpret_cast<const Elf32_Shdr *>(mapping + ehdr->e_shoff);
    phdrs = reinterpret_cast<const Elf32_Phdr *>(mapping + ehdr->e_phoff);
    section_strings = reinterpret_cast<const char *>(
        mapping + shdrs[ehdr->e_shstrndx].sh_offset);
}

const Elf32_Shdr *RiscVELF::find_section(const std::string &name) const
{
    if (!section_strings)
        return nullptr;

    for (auto n = 1; n < ehdr->e_shnum; ++n) {
        auto sec_name = section_strings + shdrs[n].sh_name;

        if (strcmp(sec_name, name.c_str()))
            continue;

        return &shdrs[n];
    }

    return nullptr;
}

void RiscVELF::read_symbols()
{
    auto symtab_sec = find_section(".symtab");
    if (!symtab_sec)
        return;

    auto strtab_sec = find_section(".strtab");
    if (!strtab_sec)
        throw std::runtime_error("No strtab");

    auto symtab =
        reinterpret_cast<const Elf32_Sym *>(mapping + symtab_sec->sh_offset);
    auto strtab =
        reinterpret_cast<const char *>(mapping + strtab_sec->sh_offset);
    for (size_t m = 0; m < symtab_sec->sh_size / sizeof(Elf32_Sym); ++m)
        symbols[strtab + symtab[m].st_name] = symtab[m].st_value;
}