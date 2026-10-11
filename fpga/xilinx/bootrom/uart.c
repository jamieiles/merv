#include "console.h"

static const unsigned long uart_base = 0xffff1000;
static volatile unsigned long *uart_mmio = (volatile unsigned long *)uart_base;

static void uart_wait_tx_empty(void)
{
    unsigned long lsr;

    do {
        lsr = uart_mmio[5];
    } while (!(lsr & (1 << 5)));
}

void console_putc(int c)
{
    uart_wait_tx_empty();
    uart_mmio[0] = c;
}

void console_init(void)
{
    uart_mmio = (volatile unsigned long *)uart_base;

    // disable irqs
    uart_mmio[0] = 0x00;
    // enable dlab
    uart_mmio[3] = 0x80;

    // set baud
    uart_mmio[0] = 44;
    uart_mmio[1] = 0;

    // set 8n1
    uart_mmio[3] = 3;

    // enable fifo
    uart_mmio[2] = 0xc7;

    // ready
    uart_mmio[4] = 0xf;
}
