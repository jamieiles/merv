#include "string.h"
#include "console.h"

void putstr(const char *str)
{
    while (*str) {
        const char *p = str++;

        console_putc(*p);
        if (*p == '\n')
            console_putc('\r');
    }
}

int strcmp(const char *a, const char *b)
{
    while (*a && *b) {
        if (*a != *b)
            return *a - *b;
        if (!*a || !*b)
            break;
        ++a;
        ++b;
    }

    return *a - *b;
}

int wstrcmp(const unsigned short *a, const unsigned short *b)
{
    while (*a && *b) {
        if (*a != *b)
            return *a - *b;
        if (!*a || !*b)
            break;
        ++a;
        ++b;
    }

    return *a - *b;
}

void *memcpy(void *dst, const void *src, size_t len)
{
    unsigned char *dst8 = dst;
    const unsigned char *src8 = src;
    size_t nbytes;

    for (nbytes = 0; nbytes < len; ++nbytes)
        *dst8++ = *src8++;

    return dst;
}

void *memset(void *dst, int c, size_t len)
{
    char *p = dst;
    size_t i;

    for (i = 0; i < len; ++i)
        p[i] = c;

    return dst;
}
