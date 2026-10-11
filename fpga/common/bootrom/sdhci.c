#include "common.h"
#include "board.h"
#include "printk.h"
#include "string.h"
#include "mtime.h"
#include "sdhci.h"

/*
 * Polled driver for the SDHCI (version 2.00, PIO only) controller.  The card
 * is initialized into 4-bit mode, and high speed if it supports it.
 */

#define SDHCI_BASE ((void *)0xfffc0000)

#define SDHCI_BLOCK 0x04
#define SDHCI_ARGUMENT 0x08
#define SDHCI_COMMAND 0x0c
#define SDHCI_RESPONSE 0x10
#define SDHCI_BUFFER 0x20
#define SDHCI_PRESENT_STATE 0x24
#define SDHCI_HOST_CONTROL 0x28
#define SDHCI_CLOCK_CONTROL 0x2c
#define SDHCI_INT_STATUS 0x30
#define SDHCI_INT_ENABLE 0x34
#define SDHCI_ACMD12_ERR 0x3c

/* Transfer mode */
#define SDHCI_TM_BCE (1 << 1)
#define SDHCI_TM_AUTO12 (1 << 2)
#define SDHCI_TM_READ (1 << 4)
#define SDHCI_TM_MULTI (1 << 5)

/* Command flags */
#define SDHCI_RESP_NONE 0x00
#define SDHCI_RESP_136 0x09
#define SDHCI_RESP_R1 0x1a
#define SDHCI_RESP_R1B 0x1b
#define SDHCI_RESP_R3 0x02
#define SDHCI_RESP_BUSY 0x03
#define SDHCI_CMD_DATA 0x20

/* Present state */
#define SDHCI_CMD_INHIBIT (1 << 0)
#define SDHCI_DAT_INHIBIT (1 << 1)
#define SDHCI_BUF_RD_EN (1 << 11)
#define SDHCI_CARD_DETECT (1 << 18)

/* Host control and power */
#define SDHCI_CTRL_4BIT (1 << 1)
#define SDHCI_CTRL_HISPD (1 << 2)
#define SDHCI_POWER_330_ON (0x0f << 8)

/* Clock control */
#define SDHCI_CLOCK_INT_EN (1 << 0)
#define SDHCI_CLOCK_INT_STABLE (1 << 1)
#define SDHCI_CLOCK_CARD_EN (1 << 2)
#define SDHCI_TIMEOUT_MAX (0xe << 16)
#define SDHCI_RESET_ALL (1 << 24)
#define SDHCI_RESET_CMD (1 << 25)
#define SDHCI_RESET_DAT (1 << 26)

/* SDCLK = base clock / (2 * div) */
#define SDHCI_DIV_400K 0x80
#define SDHCI_DIV_25M 0x02
#define SDHCI_DIV_50M 0x01

/* Interrupt status */
#define SDHCI_INT_CMD_COMPLETE (1 << 0)
#define SDHCI_INT_XFER_COMPLETE (1 << 1)
#define SDHCI_INT_BUF_RD_READY (1 << 5)
#define SDHCI_INT_ERROR (1 << 15)
#define SDHCI_INT_ERROR_MASK 0xffff0000

#define SD_CMD_TIMEOUT_US 100000
#define SD_READ_TIMEOUT_US 100000
#define SD_BUSY_TIMEOUT_US 1000000
#define SD_INIT_TIMEOUT_US 1000000
#define SD_RESET_TIMEOUT_US 10000

#define SD_OCR_BUSY (1u << 31)
#define SD_OCR_CCS (1u << 30)
#define SD_OCR_HCS (1u << 30)
#define SD_OCR_VDD_32_34 0x00300000

static int sd_block_addressed;
static uint32_t sd_rca;

static inline uint32_t sdhci_readl(unsigned reg)
{
    return readl(SDHCI_BASE + reg);
}

static inline void sdhci_writel(uint32_t v, unsigned reg)
{
    writel(v, SDHCI_BASE + reg);
}

static void udelay(unsigned long us)
{
    uint64_t deadline = timeout_us(us);

    while (!timed_out(deadline))
        continue;
}

static uint32_t sdhci_wait_set(unsigned reg,
                               uint32_t mask,
                               unsigned long us,
                               const char *what)
{
    uint64_t deadline = timeout_us(us);
    uint32_t v;

    while (!((v = sdhci_readl(reg)) & mask))
        if (timed_out(deadline))
            panic(what);

    return v;
}

static void sdhci_wait_clear(unsigned reg,
                             uint32_t mask,
                             unsigned long us,
                             const char *what)
{
    uint64_t deadline = timeout_us(us);

    while (sdhci_readl(reg) & mask)
        if (timed_out(deadline))
            panic(what);
}

static void sdhci_reset(uint32_t mask)
{
    uint32_t clock = sdhci_readl(SDHCI_CLOCK_CONTROL);

    sdhci_writel(clock | mask, SDHCI_CLOCK_CONTROL);
    sdhci_wait_clear(SDHCI_CLOCK_CONTROL, mask, SD_RESET_TIMEOUT_US,
                     "SD: reset timeout");
}

static void sdhci_set_clock(unsigned div)
{
    uint32_t clock = SDHCI_TIMEOUT_MAX | (div << 8);

    sdhci_writel(clock, SDHCI_CLOCK_CONTROL);
    sdhci_writel(clock | SDHCI_CLOCK_INT_EN, SDHCI_CLOCK_CONTROL);
    sdhci_wait_set(SDHCI_CLOCK_CONTROL, SDHCI_CLOCK_INT_STABLE,
                   SD_RESET_TIMEOUT_US, "SD: clock not stable");
    sdhci_writel(clock | SDHCI_CLOCK_INT_EN | SDHCI_CLOCK_CARD_EN,
                 SDHCI_CLOCK_CONTROL);
}

static int sdhci_error(uint32_t status)
{
    printk("SD: error, status %x acmd12 %x\n", status,
           sdhci_readl(SDHCI_ACMD12_ERR));
    sdhci_writel(status, SDHCI_INT_STATUS);
    sdhci_reset(SDHCI_RESET_CMD | SDHCI_RESET_DAT);

    return -1;
}

static uint32_t sdhci_wait_int(uint32_t mask, unsigned long us, const char *what)
{
    return sdhci_wait_set(SDHCI_INT_STATUS, mask | SDHCI_INT_ERROR, us, what);
}

/*
 * Several blocks may be buffered behind a single Buffer Read Ready interrupt
 * so wait for Buffer Read Enable instead, or an error.
 */
static uint32_t sdhci_wait_read_ready(void)
{
    uint64_t deadline = timeout_us(SD_READ_TIMEOUT_US);
    uint32_t status;

    while (!(sdhci_readl(SDHCI_PRESENT_STATE) & SDHCI_BUF_RD_EN)) {
        status = sdhci_readl(SDHCI_INT_STATUS);
        if (status & SDHCI_INT_ERROR)
            return status;
        if (timed_out(deadline))
            panic("SD: buffer read ready timeout");
    }

    return 0;
}

static int sdhci_send_cmd(unsigned index,
                          uint32_t arg,
                          unsigned flags,
                          unsigned mode)
{
    uint32_t inhibit = SDHCI_CMD_INHIBIT;
    uint32_t status;

    if ((flags & SDHCI_CMD_DATA) ||
        (flags & SDHCI_RESP_BUSY) == SDHCI_RESP_BUSY)
        inhibit |= SDHCI_DAT_INHIBIT;
    sdhci_wait_clear(SDHCI_PRESENT_STATE, inhibit, SD_CMD_TIMEOUT_US,
                     "SD: command inhibit timeout");

    sdhci_writel(arg, SDHCI_ARGUMENT);
    sdhci_writel(((index << 8 | flags) << 16) | mode, SDHCI_COMMAND);

    status = sdhci_wait_int(SDHCI_INT_CMD_COMPLETE, SD_CMD_TIMEOUT_US,
                            "SD: command complete timeout");
    if (status & SDHCI_INT_ERROR)
        return sdhci_error(status);
    sdhci_writel(SDHCI_INT_CMD_COMPLETE, SDHCI_INT_STATUS);

    if ((flags & SDHCI_RESP_BUSY) == SDHCI_RESP_BUSY &&
        !(flags & SDHCI_CMD_DATA)) {
        status = sdhci_wait_int(SDHCI_INT_XFER_COMPLETE, SD_BUSY_TIMEOUT_US,
                                "SD: busy timeout");
        if (status & SDHCI_INT_ERROR)
            return sdhci_error(status);
        sdhci_writel(SDHCI_INT_XFER_COMPLETE, SDHCI_INT_STATUS);
    }

    return 0;
}

static int sdhci_send_acmd(unsigned index, uint32_t arg, unsigned flags)
{
    if (sdhci_send_cmd(55, sd_rca << 16, SDHCI_RESP_R1, 0))
        return -1;

    return sdhci_send_cmd(index, arg, flags, 0);
}

static void sdhci_read_buffer(unsigned char *dst, unsigned len)
{
    unsigned m;

    if (!((unsigned long)dst & 3) && !(len & 3)) {
        uint32_t *dst32 = (uint32_t *)dst;

        for (m = 0; m < len / 4; ++m)
            dst32[m] = sdhci_readl(SDHCI_BUFFER);
        return;
    }

    for (m = 0; m < len; m += 4) {
        uint32_t v = sdhci_readl(SDHCI_BUFFER);
        unsigned b;

        for (b = 0; b < 4 && m + b < len; ++b)
            dst[m + b] = v >> (8 * b);
    }
}

static int sdhci_read_blocks(unsigned index,
                             uint32_t arg,
                             unsigned blksz,
                             unsigned long count,
                             unsigned char *dst)
{
    unsigned mode = SDHCI_TM_READ;
    uint32_t status;
    unsigned long n;

    if (count > 1)
        mode |= SDHCI_TM_MULTI | SDHCI_TM_BCE | SDHCI_TM_AUTO12;

    sdhci_writel((count << 16) | blksz, SDHCI_BLOCK);
    if (sdhci_send_cmd(index, arg, SDHCI_RESP_R1 | SDHCI_CMD_DATA, mode))
        return -1;

    for (n = 0; n < count; ++n) {
        status = sdhci_wait_read_ready();
        if (status)
            return sdhci_error(status);

        sdhci_read_buffer(dst, blksz);
        dst += blksz;
    }

    status = sdhci_wait_int(SDHCI_INT_XFER_COMPLETE, SD_BUSY_TIMEOUT_US,
                            "SD: transfer complete timeout");
    if (status & SDHCI_INT_ERROR)
        return sdhci_error(status);
    sdhci_writel(SDHCI_INT_XFER_COMPLETE | SDHCI_INT_BUF_RD_READY,
                 SDHCI_INT_STATUS);

    return 0;
}

int read_sectors(unsigned long start, unsigned long count, unsigned char *dst)
{
    while (count) {
        unsigned long n = count > 0xffff ? 0xffff : count;
        uint32_t arg = sd_block_addressed ? start : start * BLOCK_SIZE;

        if (sdhci_read_blocks(n > 1 ? 18 : 17, arg, BLOCK_SIZE, n, dst))
            return -1;

        start += n;
        count -= n;
        dst += n * BLOCK_SIZE;
    }

    return 0;
}

int read_sector(unsigned long sector, unsigned char *dst)
{
    return read_sectors(sector, 1, dst);
}

static int sd_switch_high_speed(void)
{
    static unsigned char status[64];

    /* Switch function group 1 to high speed. */
    if (sdhci_read_blocks(6, 0x80fffff1, sizeof(status), 1, status))
        return -1;

    return (status[16] & 0xf) == 1 ? 0 : -1;
}

void sd_init(void)
{
    uint32_t ocr_arg = SD_OCR_VDD_32_34;
    uint32_t ocr;
    uint64_t deadline;
    int high_speed;

    sdhci_writel(SDHCI_RESET_ALL, SDHCI_CLOCK_CONTROL);
    sdhci_wait_clear(SDHCI_CLOCK_CONTROL, SDHCI_RESET_ALL, SD_RESET_TIMEOUT_US,
                     "SD: reset timeout");
    sdhci_writel(~0, SDHCI_INT_ENABLE);

    sdhci_writel(SDHCI_POWER_330_ON, SDHCI_HOST_CONTROL);
    sdhci_set_clock(SDHCI_DIV_400K);
    /* At least 74 clocks before the first command. */
    udelay(1000);

    printk("SD: card detect %s\n",
           sdhci_readl(SDHCI_PRESENT_STATE) & SDHCI_CARD_DETECT ? "present"
                                                                 : "absent");

    if (sdhci_send_cmd(0, 0, SDHCI_RESP_NONE, 0))
        panic("SD: CMD0 failed");

    /* Version 2.00 cards echo the check pattern, older cards don't respond. */
    if (!sdhci_send_cmd(8, 0x1aa, SDHCI_RESP_R1, 0)) {
        if ((sdhci_readl(SDHCI_RESPONSE) & 0xfff) != 0x1aa)
            panic("SD: CMD8 check pattern mismatch");
        ocr_arg |= SD_OCR_HCS;
    }

    deadline = timeout_us(SD_INIT_TIMEOUT_US);
    do {
        if (timed_out(deadline))
            panic("SD: ACMD41 timeout");
        if (sdhci_send_acmd(41, ocr_arg, SDHCI_RESP_R3))
            panic("SD: ACMD41 failed");
        ocr = sdhci_readl(SDHCI_RESPONSE);
    } while (!(ocr & SD_OCR_BUSY));
    sd_block_addressed = !!(ocr & SD_OCR_CCS);

    if (sdhci_send_cmd(2, 0, SDHCI_RESP_136, 0))
        panic("SD: CMD2 failed");
    if (sdhci_send_cmd(3, 0, SDHCI_RESP_R1, 0))
        panic("SD: CMD3 failed");
    sd_rca = sdhci_readl(SDHCI_RESPONSE) >> 16;
    if (sdhci_send_cmd(7, sd_rca << 16, SDHCI_RESP_R1B, 0))
        panic("SD: CMD7 failed");

    if (sdhci_send_acmd(6, 2, SDHCI_RESP_R1))
        panic("SD: ACMD6 failed");
    sdhci_writel(SDHCI_POWER_330_ON | SDHCI_CTRL_4BIT, SDHCI_HOST_CONTROL);

    if (sdhci_send_cmd(16, BLOCK_SIZE, SDHCI_RESP_R1, 0))
        panic("SD: CMD16 failed");

    sdhci_set_clock(SDHCI_DIV_25M);

    high_speed = !sd_switch_high_speed();
    if (high_speed) {
        sdhci_writel(SDHCI_POWER_330_ON | SDHCI_CTRL_4BIT | SDHCI_CTRL_HISPD,
                     SDHCI_HOST_CONTROL);
        sdhci_set_clock(SDHCI_DIV_50M);
    }

    unsigned long khz = BOARD_SDHCI_BASE_KHZ / (2 * (high_speed ? SDHCI_DIV_50M : SDHCI_DIV_25M));
    printk("SD: %s card, 4-bit, %s %u.%uMHz\n", sd_block_addressed ? "SDHC" : "SDSC",
           high_speed ? "high speed" : "default speed", khz / 1000, (khz % 1000) / 100);
}
