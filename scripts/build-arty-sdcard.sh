#!/bin/bash
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Build the files for the first (FAT16) partition of the Arty S7 SD card:
# OPENSBI.BIN, IMAGE.BIN, IMAGEGZ.BIN and MERV.DTB, loaded by the boot ROM
# (which prefers the uncompressed IMAGE.BIN as decompressing on the core is
# slow, falling back to IMAGEGZ.BIN).  OpenSBI is
# shared with the simulation build (scripts/build-software.sh, which must be
# run first), the kernel is built with platform/linux-arty-defconfig.
#
# usage: build-arty-sdcard.sh [sw_dir]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(dirname "$HERE")"
SW="$(realpath -m "${1:-$TOP/_build/sw}")"
LINUX_SRC="${LINUX_SRC:-$SW/linux-src}"
LINUX_CROSS="${LINUX_CROSS:-riscv64-linux-gnu-}"
OUT="$SW/sdcard"
JOBS="$(nproc)"

if [ ! -f "$SW/fw_jump.bin" ] || [ ! -d "$LINUX_SRC" ]; then
    echo "run scripts/build-software.sh first" >&2
    exit 1
fi

mkdir -p "$OUT"
KMAKE=(make -s -C "$LINUX_SRC" O="$SW/linux-arty" ARCH=riscv
       CROSS_COMPILE="$LINUX_CROSS" -j"$JOBS")
mkdir -p "$SW/linux-arty"
cp "$TOP/platform/linux-arty-defconfig" "$SW/linux-arty/.config"
"${KMAKE[@]}" olddefconfig
for opt in CONFIG_SIFIVE_PLIC=y CONFIG_MMC_SDHCI_OF_ARASAN=y CONFIG_ENC28J60=y; do
    grep -qx "$opt" "$SW/linux-arty/.config" || echo "warning: $opt not set"
done
grep -q "^CONFIG_RISCV_ISA_C=y" "$SW/linux-arty/.config" &&
    { echo "error: compressed instructions enabled" >&2; exit 1; }
"${KMAKE[@]}" Image

cp "$SW/fw_jump.bin" "$OUT/OPENSBI.BIN"
cp "$SW/linux-arty/arch/riscv/boot/Image" "$OUT/IMAGE.BIN"
gzip -9 -n -c "$SW/linux-arty/arch/riscv/boot/Image" > "$OUT/IMAGEGZ.BIN"
dtc -q -I dts -O dtb -o "$OUT/MERV.DTB" "$TOP/platform/merv-arty.dts"
ls -l "$OUT"
