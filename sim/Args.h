// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Minimal --option value / --option=value command line parsing.
class Args
{
public:
    Args(int argc, char **argv)
    {
        for (int i = 1; i < argc; ++i) {
            std::string a = argv[i];
            if (a.rfind("--", 0) != 0)
                throw std::runtime_error("unexpected argument " + a);
            a = a.substr(2);
            auto eq = a.find('=');
            if (eq != std::string::npos) {
                values[a.substr(0, eq)].push_back(a.substr(eq + 1));
            } else if (i + 1 < argc && std::string(argv[i + 1]).rfind("--", 0) != 0) {
                values[a].push_back(argv[++i]);
            } else {
                values[a].push_back("");
            }
        }
    }

    bool flag(const std::string &name, const std::string &desc)
    {
        describe(name, "", desc);
        return take(name) != nullptr;
    }

    void flag01(const std::string &name, bool &v, const std::string &desc)
    {
        describe(name, "0|1", desc);
        if (auto s = take(name))
            v = std::stoul(*s, nullptr, 0) != 0;
    }

    void str(const std::string &name, std::string &v, const std::string &desc)
    {
        describe(name, "ARG", desc);
        if (auto s = take(name))
            v = *s;
    }

    void list(const std::string &name, std::vector<std::string> &v,
              const std::string &desc)
    {
        describe(name, "ARG", desc);
        auto it = values.find(name);
        if (it != values.end()) {
            v.insert(v.end(), it->second.begin(), it->second.end());
            values.erase(it);
        }
    }

    template <typename T>
    void num(const std::string &name, T &v, const std::string &desc)
    {
        describe(name, "N", desc);
        if (auto s = take(name))
            v = static_cast<T>(std::stoll(*s, nullptr, 0));
    }

    void finish()
    {
        if (!values.empty())
            throw std::runtime_error("unknown option --" + values.begin()->first);
    }

    std::string help() const
    {
        return usage.str();
    }

private:
    const std::string *take(const std::string &name)
    {
        auto it = values.find(name);
        if (it == values.end())
            return nullptr;
        last = it->second.back();
        values.erase(it);
        return &last;
    }

    void describe(const std::string &name, const std::string &arg,
                  const std::string &desc)
    {
        std::string opt = "--" + name + (arg.empty() ? "" : " " + arg);
        usage << "  " << opt << std::string(opt.size() < 24 ? 24 - opt.size() : 1, ' ')
              << desc << "\n";
    }

    std::map<std::string, std::vector<std::string>> values;
    std::string last;
    std::ostringstream usage;
};
