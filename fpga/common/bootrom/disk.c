#include "common.h"
#include "string.h"
#include "disk.h"
#include "sdhci.h"
#include "printk.h"

static int assert_partitioned(const unsigned char *mbr)
{
    if (mbr[0x1fe] != 0x55 || mbr[0x1ff] != 0xaa) {
        putstr("ERROR: card not partitioned, no MBR\n");
        return -1;
    }

    return 0;
}

static int get_active_partition(const unsigned char *mbr,
                                unsigned long *start,
                                unsigned long *size)
{
    int rc;
    unsigned m;

    rc = assert_partitioned(mbr);
    if (rc)
        return -1;

    for (m = 0; m < 4; ++m) {
        struct partition_entry pe;

        memcpy(&pe, mbr + 0x1be + (m * sizeof(pe)), sizeof(pe));

        if (pe.type == 0 || !pe.status)
            continue;

        *start = pe.first_lba;
        *size = pe.num_sectors * 512;

        return 0;
    }

    return -1;
}

void find_boot_partition(unsigned long *start, unsigned long *size)
{
    static unsigned char mbr[BLOCK_SIZE];

    if (read_sector(0, mbr))
        panic("unable to read MBR");

    if (get_active_partition(mbr, start, size)) {
        // The partition table and signature as read
        for (unsigned off = 0x1b0; off < BLOCK_SIZE; off += 16) {
            printk("%x:", off);
            for (unsigned b = 0; b < 16; ++b)
                printk(" %x", mbr[off + b]);
            printk("\n");
        }
        panic("unable to get boot partition");
    }
}