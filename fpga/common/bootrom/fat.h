#pragma once

enum fat_ver {
    FAT12,
    FAT16,
    FAT32,
};

struct fat_superblock {
    unsigned long partition_lba;
    unsigned short bytes_per_sector;
    char sectors_per_cluster;
    unsigned short reserved_sectors;
    char nr_fats;
    unsigned short max_root_dirents;
    unsigned long total_sectors;
    unsigned short sectors_per_fat;
    char fat_bits;
    char oem_name[9];
    enum fat_ver version;
    unsigned long eoc_marker;

    unsigned char sector_cache[512];
    unsigned long last_sector_num;
};

#define FAT_DIRENT_F_RO (1 << 0)
#define FAT_DIRENT_F_HIDDEN (1 << 1)
#define FAT_DIRENT_F_SYSTEM (1 << 2)
#define FAT_DIRENT_F_VOLLABEL (1 << 3)
#define FAT_DIRENT_F_SUBDIR (1 << 4)
#define FAT_DIRENT_F_ARCHIVE (1 << 5)
#define FAT_DIRENT_F_DEVICE (1 << 6)

struct fat_dirent {
    unsigned short name[256];
    char ext[4];
    char flags;
    unsigned short first_cluster;
    unsigned long size;
};

static inline int fat_dirent_is_dir(const struct fat_dirent *d)
{
    return d->flags & FAT_DIRENT_F_SUBDIR;
}

static inline unsigned long fat_root_dir_offs(struct fat_superblock *sb)
{
    return (sb->reserved_sectors + (sb->nr_fats * sb->sectors_per_fat)) *
           sb->bytes_per_sector;
}

int fat_read_dirent(struct fat_superblock *sb,
                    struct fat_dirent *dirent,
                    unsigned long *offs);
unsigned long fat_read_buf(struct fat_superblock *sb,
                           const struct fat_dirent *dirent,
                           void *dst,
                           unsigned long len,
                           unsigned offs);
void fat_decode_boot_sect(const unsigned char *hdr, struct fat_superblock *sb);