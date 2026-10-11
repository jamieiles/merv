#pragma once

#include <stdint.h>

typedef unsigned int size_t;
#define NULL ((void *)0)
#define __used __attribute__((used))

void panic(const char *str);

static inline void writel(uint32_t v, void *r)
{
    volatile uint32_t *r32 = (volatile uint32_t *)r;

    *r32 = v;
}

static inline uint32_t readl(void *r)
{
    volatile uint32_t *r32 = (volatile uint32_t *)r;

    return *r32;
}
