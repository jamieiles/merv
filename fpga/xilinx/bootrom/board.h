#pragma once

/* Arty S7 bootrom configuration. */

#define BOARD_DTB_NAME u"MERV.DTB"

/*
 * The timer runs at 10.140625MHz, exactly 649/64 ticks per microsecond, so
 * conversions avoid a 64-bit division (no libgcc).
 */
#define BOARD_TIMER_HZ 10140625
#define BOARD_US_TO_TICKS(us) (((uint64_t)(us) * 649) >> 6)

/* The SD host controller's base clock, the MIG UI clock. */
#define BOARD_SDHCI_BASE_KHZ 81248

/* SMP: harts other than 0 wait for their CLINT msip before entering OpenSBI. */
#define CLINT_BASE 0xf0000000
#define MAX_HARTS 4
#define MIP_MSIP (1 << 3)

/* OpenSBI (fw_jump) entry and the device tree it is passed. */
#define PAYLOAD_ENTRY 0x80000000
#define PAYLOAD_DTB 0x80200000
