#include "common.h"
#include "string.h"
#include "printk.h"
#include "console.h"
#include "mtime.h"

#define SZ_KB (1024)
#define SZ_MB (SZ_KB * 1024)

#define UPDATES_PER_SECOND 10
#define UPDATE_INTERVAL ((1000 / UPDATES_PER_SECOND) * TICKS_PER_MS)

static void fmt_size(unsigned long sz,
                     unsigned long *lhs,
                     unsigned long *rhs,
                     char **suffix)
{
    if (sz > SZ_MB) {
        unsigned long mb = sz / SZ_MB;
        unsigned long kb = (sz % SZ_MB) / (SZ_MB / 100);

        *lhs = mb;
        *rhs = kb;
        *suffix = "MB";
    } else if (sz > SZ_KB) {
        unsigned long kb = sz / SZ_KB;
        unsigned long b = (sz % SZ_KB) / (SZ_KB / 100);

        *lhs = kb;
        *rhs = b;
        *suffix = "KB";
    } else {
        *lhs = sz;
        *rhs = 0;
        *suffix = "B";
    }
}

static void clear(int clear_chars)
{
    for (int i = 0; i < clear_chars; ++i)
        console_putc('\x08');
    for (int i = 0; i < clear_chars; ++i)
        console_putc(' ');
    for (int i = 0; i < clear_chars; ++i)
        console_putc('\x08');
}

static int last_draw_len;

void progress(unsigned long done, unsigned long total)
{
    unsigned long progress = done / (total / 100);

    if (progress > 100)
        progress = 100;

    clear(last_draw_len);

    unsigned long done_lhs, done_rhs, total_lhs, total_rhs;
    char *done_suffix, *total_suffix;
    fmt_size(done, &done_lhs, &done_rhs, &done_suffix);
    fmt_size(total, &total_lhs, &total_rhs, &total_suffix);

    last_draw_len =
        printk("%u.%02u%s/%u.%02u%s (%u%%)", done_lhs, done_rhs, done_suffix,
               total_lhs, total_rhs, total_suffix, progress);
}

void progress_ratelimited(unsigned long done, unsigned long total)
{
    static uint64_t last_update;
    uint64_t now = get_time();

    if (now > last_update + UPDATE_INTERVAL) {
        progress(done, total);
        last_update = now;
    }
}

void progress_clear(void)
{
    last_draw_len = 0;
}
