// Copyright 2026 Jamie Iles
// SPDX-License-Identifier: Apache-2.0
//
// Minimal rv32 Linux init: print a greeting and power off.

#define SYS_write  64
#define SYS_reboot 142

#define LINUX_REBOOT_MAGIC1       0xfee1dead
#define LINUX_REBOOT_MAGIC2       672274793
#define LINUX_REBOOT_CMD_POWER_OFF 0x4321fedc

    .section .rodata
msg:
    .ascii  "Hello, world\n"
    .equ    msg_len, . - msg

    .text
    .global _start
_start:
    li      a0, 1
    la      a1, msg
    li      a2, msg_len
    li      a7, SYS_write
    ecall

    li      a0, LINUX_REBOOT_MAGIC1
    li      a1, LINUX_REBOOT_MAGIC2
    li      a2, LINUX_REBOOT_CMD_POWER_OFF
    li      a3, 0
    li      a7, SYS_reboot
    ecall
1:  j       1b
