#pragma once

/*
 * The boot console, provided by the board: a UART on the Arty, the
 * framebuffer on the DE0-CV.
 */
void console_init(void);
void console_putc(int c);
