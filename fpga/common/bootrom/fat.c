#include "common.h"
#include "string.h"
#include "disk.h"
#include "sdhci.h"
#include "fat.h"
#include "console.h"
#include "printk.h"
#include "progress.h"

static inline unsigned char fat_read8(const unsigned char *p)
{
    return *p;
}

static inline unsigned short fat_read16(const unsigned char *p)
{
    return (unsigned short)*p | ((unsigned short)*(p + 1) << 8);
}

static inline unsigned long fat_read32(const unsigned char *p)
{
    return (unsigned long)*p | ((unsigned long)*(p + 1) << 8) |
           ((unsigned long)*(p + 2) << 16) | ((unsigned long)*(p + 3) << 24);
}

static int fat_read(struct fat_superblock *sb,
                    void *dst,
                    unsigned len,
                    unsigned long offset,
                    int is_metadata)
{
    static unsigned char sector_buf[512];
    unsigned bytes_read = 0;

    while (bytes_read < len) {
        unsigned sector_num = (offset / 512) + sb->partition_lba;
        unsigned sector_offset = offset % 512;
        unsigned bytes_to_sector_end = 512 - sector_offset;
        unsigned long bytes_remaining = len - bytes_read;
        unsigned read_len = bytes_to_sector_end < bytes_remaining
                                ? bytes_to_sector_end
                                : bytes_remaining;
        unsigned char *buf = is_metadata ? sb->sector_cache : sector_buf;

        if ((!is_metadata || sb->last_sector_num != sector_num) &&
            read_sector(sector_num, buf))
            return -1;

        if (is_metadata)
            sb->last_sector_num = sector_num;

        memcpy(dst + bytes_read, buf + sector_offset, read_len);

        bytes_read += read_len;
        offset += read_len;
    }

    return 0;
}

static unsigned long fat_read_entry(struct fat_superblock *sb,
                                    unsigned long entry)
{
    unsigned long val, fat_byte_addr = (entry * sb->fat_bits) / 8;
    unsigned bit_offs = (entry * sb->fat_bits) % 8;
    unsigned long fat_addr = sb->reserved_sectors * sb->bytes_per_sector;

    fat_read(sb, &val, sizeof(val), fat_byte_addr + fat_addr, 1);

    val >>= bit_offs;
    val &= ((1 << sb->fat_bits) - 1);

    return val;
}

void fat_decode_boot_sect(const unsigned char *hdr, struct fat_superblock *sb)
{
    unsigned long nr_clusters;

    sb->bytes_per_sector = fat_read16(hdr + 0xb);
    sb->sectors_per_cluster = fat_read8(hdr + 0xd);
    sb->reserved_sectors = fat_read16(hdr + 0xe);
    sb->nr_fats = fat_read8(hdr + 0x10);
    sb->max_root_dirents = fat_read16(hdr + 0x11);
    sb->sectors_per_fat = fat_read16(hdr + 0x16);

    sb->total_sectors = fat_read16(hdr + 0x13);
    if (!sb->total_sectors)
        sb->total_sectors = fat_read32(hdr + 0x20);
    nr_clusters = sb->total_sectors / sb->sectors_per_cluster;

    if (nr_clusters < 4085) {
        sb->version = FAT12;
        sb->fat_bits = 12;
    } else if (nr_clusters < 65525) {
        sb->version = FAT16;
        sb->fat_bits = 16;
    } else {
        sb->version = FAT32;
        sb->fat_bits = 32;
        panic("FAT32 unsupported");
    }

    sb->eoc_marker = fat_read_entry(sb, 1);

    memcpy(sb->oem_name, hdr + 0x3, 8);
    sb->oem_name[8] = '\0';
}

static inline int fat_is_lfn(const struct fat_dirent *dirent)
{
    return (dirent->flags & 0x0f) == 0x0f;
}

static void fat_read_wchar(unsigned short *dst,
                           const unsigned char *src,
                           unsigned long nr_wchar)
{
    while (nr_wchar--) {
        *dst++ = (*src | (*(src + 1) << 8));
        src += 2;
    }
}

static void fat_read_lfn(struct fat_superblock *sb,
                         struct fat_dirent *dirent,
                         unsigned nr_lfn_ents,
                         unsigned long offs)
{
    unsigned char buf[32];
    unsigned long pos = offs + (nr_lfn_ents - 1) * 32;
    unsigned long idx = 0;

    do {
        if (fat_read(sb, buf, sizeof(buf), pos, 1))
            return;

        fat_read_wchar(dirent->name + idx + 0, buf + 0x01, 5);
        fat_read_wchar(dirent->name + idx + 5, buf + 0x0e, 6);
        fat_read_wchar(dirent->name + idx + 11, buf + 0x1c, 2);

        pos -= 32;
        idx += 13;

    } while (pos >= offs);
}

static unsigned char *strnchr(unsigned char *str, unsigned long len, int c)
{
    unsigned long n;

    for (n = 0; n < len; ++n)
        if (str[n] == c)
            return str + n;

    return NULL;
}

static void fat_read_shortname(struct fat_dirent *dirent,
                               unsigned long offs,
                               const unsigned char buf[32])
{
    unsigned char name[9];
    unsigned char ext[4];
    unsigned short *lstr = dirent->name;
    unsigned char *p;

    memcpy(name, buf + 0x00, 8);
    if (strnchr(name, 9, ' '))
        *strnchr(name, 9, ' ') = '\0';
    name[8] = '\0';
    memcpy(ext, buf + 0x08, 3);
    if (strnchr(ext, 4, ' '))
        *strnchr(ext, 4, ' ') = '\0';
    ext[3] = '\0';

    p = name;
    while (*p)
        *lstr++ = *p++;

    *lstr++ = '.';

    p = ext;
    while (*p)
        *lstr++ = *p++;
}

static int fat_get_next_dirent(struct fat_superblock *sb,
                               unsigned char *buf,
                               unsigned long *offs)
{
    for (;;) {
        if (fat_read(sb, buf, 32, *offs, 1)) {
            putstr("failed to read\n");
            return -1;
        }

        if (buf[0] == 0)
            return -1;

        if (buf[0] != 0xe5)
            break;

        *offs += 32;
    }

    return 0;
}

static void fat_read_name(struct fat_superblock *sb,
                          struct fat_dirent *dirent,
                          unsigned nr_lfn_ents,
                          unsigned long offs,
                          unsigned char *buf)
{
    if (fat_is_lfn(dirent))
        fat_read_lfn(sb, dirent, nr_lfn_ents, offs);
    else
        fat_read_shortname(dirent, offs, buf);
}

int fat_read_dirent(struct fat_superblock *sb,
                    struct fat_dirent *dirent,
                    unsigned long *offs)
{
    unsigned char buf[32];
    unsigned nr_lfn_ents;
    unsigned long pos;
    int ret;

    ret = fat_get_next_dirent(sb, buf, offs);
    if (ret == -1)
        return ret;

    dirent->flags = buf[0x0b];
    nr_lfn_ents = fat_is_lfn(dirent) ? buf[0] & 0x3f : 0;

    pos = *offs + 32 * nr_lfn_ents;
    if (fat_read(sb, buf, sizeof(buf), pos, 1)) {
        putstr("failed to read directory entry\n");
        return -1;
    }

    dirent->flags = buf[0x0b];
    dirent->first_cluster = fat_read16(buf + 0x1a);
    dirent->size = fat_read32(buf + 0x1c);
    fat_read_name(sb, dirent, nr_lfn_ents, *offs, buf);

    if (buf[0] == 0) {
        putstr("name invalid\n");
        return -1;
    }

    *offs = pos + 32;

    return 0;
}

static unsigned long fat_read_from_cluster(struct fat_superblock *sb,
                                           void *dst,
                                           unsigned long cluster,
                                           unsigned long len)
{
    unsigned long cluster_addr = 0;
    unsigned long data_sector_base;
    unsigned long nr_sectors = len / BLOCK_SIZE;
    unsigned long tail = len % BLOCK_SIZE;

    data_sector_base =
        (sb->reserved_sectors + sb->nr_fats * sb->sectors_per_fat);

    if (sb->version != FAT32)
        data_sector_base +=
            ((sb->max_root_dirents * 32) / sb->bytes_per_sector);

    /*
     * Clusters 0&1 are reserved so we start from cluster 2, hence the -2.
     */
    cluster_addr =
        data_sector_base * sb->bytes_per_sector +
        (cluster - 2) * sb->sectors_per_cluster * sb->bytes_per_sector;
    /*
     * Clusters are sector aligned so whole sectors are read with a single
     * multi-block read straight into the destination.
     */
    if ((nr_sectors &&
         read_sectors(sb->partition_lba + cluster_addr / BLOCK_SIZE,
                      nr_sectors, dst)) ||
        (tail && fat_read(sb, dst + nr_sectors * BLOCK_SIZE, tail,
                          cluster_addr + nr_sectors * BLOCK_SIZE, 0))) {
        putstr("failed to read from cluster\n");
        return 0;
    }

    return len;
}

unsigned long fat_read_buf(struct fat_superblock *sb,
                           const struct fat_dirent *dirent,
                           void *dst,
                           unsigned long len,
                           unsigned offs)
{
    unsigned long cluster = dirent->first_cluster;
    unsigned long pos = 0, copied = 0;
    unsigned long bytes_per_cluster =
        sb->bytes_per_sector * sb->sectors_per_cluster;
    unsigned long cluster_read_count = 0;
    unsigned long orig_len = len;

    while (len > 0) {
        if (pos >= offs) {
            unsigned long cluster_offs = offs % bytes_per_cluster;
            unsigned long clen = bytes_per_cluster - cluster_offs;

            if (clen > len)
                clen = len;
            if (clen > bytes_per_cluster)
                clen = bytes_per_cluster;

            fat_read_from_cluster(sb, dst + copied, cluster, clen);
            ++cluster_read_count;

            offs += cluster_offs;
            copied += clen;
            len -= clen;
        }

        cluster = fat_read_entry(sb, cluster);
        if (cluster == sb->eoc_marker)
            break;

        pos += bytes_per_cluster;

        if (cluster_read_count % 128 == 0)
            progress(pos, orig_len);
    }
    progress(orig_len, orig_len);
    progress_clear();

    return 0;
}