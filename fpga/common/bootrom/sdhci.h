#pragma once

#define BLOCK_SIZE 512

void sd_init(void);
int read_sector(unsigned long sector, unsigned char *dst);
int read_sectors(unsigned long start, unsigned long count, unsigned char *dst);
