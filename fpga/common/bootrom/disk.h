#pragma once

struct partition_entry {
    unsigned char status;
    unsigned char chs_start[3];

    unsigned char type;
    unsigned char chs_end[3];

    union {
        unsigned char first_lba_bytes[4];
        unsigned long first_lba;
    };

    union {
        unsigned char num_sectors_bytes[4];
        unsigned long num_sectors;
    };
};

void find_boot_partition(unsigned long *start, unsigned long *size);
