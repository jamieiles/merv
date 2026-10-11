#pragma once
#include <stdint.h>
#include "board.h"

#define TICKS_PER_MS (BOARD_TIMER_HZ / 1000)

static inline uint64_t get_time(void)
{
    unsigned long lo, hi, hi2;

    do {
        asm volatile("csrr %0, timeh" : "=r"(hi));
        asm volatile("csrr %0, time" : "=r"(lo));
        asm volatile("csrr %0, timeh" : "=r"(hi2));
    } while (hi != hi2);

    return ((uint64_t)hi << 32) | lo;
}

static inline uint64_t us_to_ticks(unsigned long us)
{
    return BOARD_US_TO_TICKS(us);
}

/* Return a deadline us microseconds from now for timed_out(). */
static inline uint64_t timeout_us(unsigned long us)
{
    return get_time() + us_to_ticks(us);
}

static inline int timed_out(uint64_t deadline)
{
    return get_time() > deadline;
}
