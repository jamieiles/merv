// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <deque>
#include <fstream>
#include <string>

#include <poll.h>
#include <termios.h>
#include <unistd.h>

#include "../Bus.h"

// Puts the terminal into raw mode for the lifetime of the object so that
// characters are passed straight through to the simulated UART.
class RawTTY
{
public:
    RawTTY()
    {
        if (!isatty(STDIN_FILENO) || tcgetattr(STDIN_FILENO, &old_termios))
            return;

        auto t = old_termios;
        cfmakeraw(&t);
        t.c_cc[VMIN] = 0;
        t.c_cc[VTIME] = 0;
        t.c_lflag |= ISIG;
        t.c_oflag |= OPOST | ONLCR;
        active = tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0;
    }

    ~RawTTY()
    {
        if (active)
            tcsetattr(STDIN_FILENO, TCSANOW, &old_termios);
    }

private:
    struct termios old_termios {};
    bool active = false;
};

// 16550A with reg-shift = 2 and 32-bit accesses.  Transmission is instant so
// THR is always empty, input is taken from stdin.
class Uart16550 : public Device
{
public:
    Uart16550(const std::string &log_path, bool echo, bool input)
        : echo(echo), input(input)
    {
        if (!log_path.empty())
            log.open(log_path, std::ios::out | std::ios::binary);
    }

    bool irq() const
    {
        return ((ier & IER_ERBFI) && !rx.empty()) ||
               ((ier & IER_ETBEI) && thre_pending);
    }

    // Called periodically to poll for input.
    void poll_input()
    {
        if (!input)
            return;
        struct pollfd pfd = {STDIN_FILENO, POLLIN, 0};
        if (::poll(&pfd, 1, 0) <= 0 || !(pfd.revents & POLLIN))
            return;
        char c;
        auto n = ::read(STDIN_FILENO, &c, 1);
        if (n == 1)
            rx.push_back(static_cast<uint8_t>(c));
        else
            input = false;
    }

    const std::string &output() const
    {
        return out;
    }

    bool read(uint32_t offset, unsigned size, uint32_t &val) override
    {
        (void)size;
        val = 0;
        switch (offset >> 2) {
        case 0:
            if (lcr & LCR_DLAB) {
                val = dll;
            } else if (!rx.empty()) {
                val = rx.front();
                rx.pop_front();
            }
            break;
        case 1: val = (lcr & LCR_DLAB) ? dlm : ier; break;
        case 2:
            if ((ier & IER_ERBFI) && !rx.empty()) {
                val = 0x04;
            } else if ((ier & IER_ETBEI) && thre_pending) {
                val = 0x02;
                thre_pending = false;
            } else {
                val = 0x01;
            }
            if (fcr & 1)
                val |= 0xc0;
            break;
        case 3: val = lcr; break;
        case 4: val = mcr; break;
        case 5: val = 0x60 | (rx.empty() ? 0 : 1); break;
        case 6: val = 0xb0; break;
        case 7: val = scr; break;
        }
        return true;
    }

    bool write(uint32_t offset, unsigned size, uint32_t val) override
    {
        (void)size;
        val &= 0xff;
        switch (offset >> 2) {
        case 0:
            if (lcr & LCR_DLAB) {
                dll = val;
            } else {
                transmit(static_cast<char>(val));
                thre_pending = true;
            }
            break;
        case 1:
            if (lcr & LCR_DLAB) {
                dlm = val;
            } else {
                if ((val & IER_ETBEI) && !(ier & IER_ETBEI))
                    thre_pending = true;
                ier = val & 0x0f;
            }
            break;
        case 2:
            fcr = val;
            if (val & 2)
                rx.clear();
            break;
        case 3: lcr = val; break;
        case 4: mcr = val; break;
        case 7: scr = val; break;
        default: break;
        }
        return true;
    }

private:
    static constexpr uint32_t IER_ERBFI = 1 << 0;
    static constexpr uint32_t IER_ETBEI = 1 << 1;
    static constexpr uint32_t LCR_DLAB = 1 << 7;

    void transmit(char c)
    {
        if (echo && ::write(STDOUT_FILENO, &c, 1) != 1)
            echo = false;
        if (log.is_open()) {
            log.write(&c, 1);
            log.flush();
        }
        if (out.size() < (1 << 20))
            out.push_back(c);
    }

    bool echo;
    bool input;
    std::ofstream log;
    std::string out;
    std::deque<uint8_t> rx;
    bool thre_pending = false;
    uint32_t ier = 0, fcr = 0, lcr = 0, mcr = 0, scr = 0, dll = 0, dlm = 0;
};
