#include "common.h"
#include "board.h"
#include "string.h"
#include "printk.h"
#include "console.h"
#include "fat.h"
#include "disk.h"
#include "sdhci.h"
#include <stdint.h>

static const char *banner =
    "\n\n"
    " ████     ████  ████████  ███████    ██      ██\n"
    "░██░██   ██░██ ░██░░░░░  ░██░░░░██  ░██     ░██\n"
    "░██░░██ ██ ░██ ░██       ░██   ░██  ░██     ░██\n"
    "░██ ░░███  ░██ ░███████  ░███████   ░░██    ██\n"
    "░██  ░░█   ░██ ░██░░░░   ░██░░░██    ░░██  ██\n"
    "░██   ░    ░██ ░██       ░██  ░░██    ░░████\n"
    "░██        ░██ ░████████ ░██   ░░██    ░░██\n"
    "░░         ░░  ░░░░░░░░  ░░     ░░      ░░\n";
static const uint32_t entrypoint = PAYLOAD_ENTRY;

struct boot_file {
    const uint16_t *name;
    uint32_t load_address;
    int required;
    int compressed;
    // Only loaded if the previous file was not found.
    int fallback;
};

void panic(const char *str)
{
    putstr(str);
    putstr("\n");

    for (;;)
        continue;
}

static void jump_payload(void)
{
    // Release the other harts (waiting in entry.S), the CLINT ignores the
    // msip of harts that don't exist.
    for (unsigned h = 1; h < MAX_HARTS; ++h)
        ((volatile uint32_t *)CLINT_BASE)[h] = 1;

    asm volatile(
        "fence.i\n\t"
        "li a0, 0\n\t"
        "addi a1, %1, 0\n\t"
        "addi s0, %0, 0\n\t"
        "jr s0" ::"r"(entrypoint),
        "r"(PAYLOAD_DTB));
}

extern char load_scratch[];

static const struct boot_file boot_files[] = {
    {.name = u"OPENSBI.BIN", .load_address = PAYLOAD_ENTRY, .required = 1},
    // Prefer the uncompressed kernel, decompressing on the core is slow.
    {.name = u"IMAGE.BIN", .load_address = 0x80400000, .required = 0},
    {.name = u"IMAGEGZ.BIN",
     .load_address = 0x80400000,
     .required = 0,
     .compressed = 1,
     .fallback = 1},
    {.name = BOARD_DTB_NAME, .load_address = PAYLOAD_DTB, .required = 1},
    {}};

long tinflate(const void *compressed_data,
              long compressed_size,
              void *output_buffer,
              long output_size,
              unsigned long *crc_ret);

static void decompress(void *dst, const void *src, uint32_t len)
{
    const char *buf8 = src;
    uint32_t uncompressed_len;

    if (buf8[0] != 0x1f || buf8[1] != 0x8b) {
        putstr("Invalid gzip magic\n");
        return;
    }

    memcpy(&uncompressed_len, buf8 + len - 4, sizeof(uncompressed_len));

    unsigned long crc_out;
    long rc = tinflate(src + 10, len - 18, dst, uncompressed_len, &crc_out);

    if (rc != uncompressed_len)
        putstr("Failed to decompress\n");
}

static int load_one_file(struct fat_superblock *sb,
                         const uint16_t *name,
                         uint32_t load_address,
                         int compressed)
{
    unsigned long offs = fat_root_dir_offs(sb);
    int err = -1;

    for (;;) {
        struct fat_dirent dirent = {};

        err = fat_read_dirent(sb, &dirent, &offs);
        if (err == -1)
            return err;

        if (!wstrcmp(dirent.name, name)) {
            if (!fat_dirent_is_dir(&dirent)) {
                uint32_t read_address =
                    compressed ? (unsigned long)load_scratch : load_address;
                printk("Reading %ls%s ", name,
                       compressed ? " (compressed)" : "");
                fat_read_buf(sb, &dirent, (void *)read_address, dirent.size, 0);
                putstr("\n");

                if (compressed) {
                    putstr("Decompressing... ");
                    decompress((void *)load_address, (const void *)read_address,
                               dirent.size);
                    putstr("\n");
                }

                return 0;
            }
        }
    }

    return 0;
}

static int load_files(struct fat_superblock *sb)
{
    const struct boot_file *bf = boot_files;
    int rc = 0, prev_loaded = 0;

    while (bf->name) {
        if (bf->fallback && prev_loaded) {
            ++bf;
            continue;
        }
        rc = load_one_file(sb, bf->name, bf->load_address, bf->compressed);
        prev_loaded = !rc;
        if (rc && bf->required) {
            printk("ERROR: required file %ls not found\n", bf->name);
            return -1;
        } else if (rc) {
            printk("Skipping optional not-present file %ls\n", bf->name);
            rc = 0;
        }

        ++bf;
    }

    return rc;
}

void root(void)
{
    static unsigned char sector_buf[512];
    unsigned long start = 0, size = 0;
    struct fat_superblock sb;

    console_init();

    putstr(banner);
    putstr("BootROM " __DATE__ " " __TIME__ "\n");

    sd_init();

    find_boot_partition(&start, &size);
    if (read_sector(start, sector_buf))
        panic("unable to read fatfs sector");

    sb.partition_lba = start;
    fat_decode_boot_sect(sector_buf, &sb);

    if (load_files(&sb))
        panic("failed to load");
    putstr("Loaded, jumping to entry point\n");
    jump_payload();

    __builtin_unreachable();
}
