#!/bin/bash
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Build the software stack for the merv simulation platform: OpenSBI
# (generic platform, fw_jump), a Linux kernel and an initramfs that prints
# "Hello, world" and powers off, plus the device tree.  The arguments for
# merv-sim are written to boot-args, and for 4 harts (an SMP kernel and
# device tree) to boot-args-smp4.
#
# usage: build-software.sh [out_dir]
#
# Environment:
#   LINUX_SRC        Linux source tree, must be clean (default: a shared
#                    clone of LINUX_REPO at LINUX_VERSION)
#   LINUX_REPO       Linux git repository (default ~/src/linux)
#   LINUX_VERSION    Linux revision (default v6.9)
#   OPENSBI_SRC      OpenSBI source tree (default: clone OPENSBI_VERSION)
#   OPENSBI_VERSION  OpenSBI tag to clone (default v1.6)
#   LINUX_CROSS      Linux cross prefix (default riscv64-linux-gnu-)
#   SBI_CROSS        OpenSBI cross prefix (default riscv64-linux-gnu-)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(dirname "$HERE")"
OUT="$(realpath -m "${1:-$TOP/_build/sw}")"
LINUX_REPO="${LINUX_REPO:-$HOME/src/linux}"
LINUX_VERSION="${LINUX_VERSION:-v6.9}"
OPENSBI_VERSION="${OPENSBI_VERSION:-v1.6}"
LINUX_CROSS="${LINUX_CROSS:-riscv64-linux-gnu-}"
SBI_CROSS="${SBI_CROSS:-riscv64-linux-gnu-}"
JOBS="$(nproc)"

# Memory layout, must match platform/merv-sim.dts and sim/bootrom.
FW_JUMP_ADDR=0x80400000
FW_JUMP_FDT_ADDR=0x82200000
DTB_ADDR=0x83f00000
INITRD_ADDR=0x84000000

mkdir -p "$OUT"

if [ -z "${OPENSBI_SRC:-}" ]; then
    OPENSBI_SRC="$OUT/opensbi-src"
    if [ ! -d "$OPENSBI_SRC" ]; then
        git -c advice.detachedHead=false clone -q --depth 1 -b "$OPENSBI_VERSION" \
            https://github.com/riscv-software-src/opensbi.git "$OPENSBI_SRC"
    fi
fi

echo "== OpenSBI ($OPENSBI_SRC)"
make -s -C "$OPENSBI_SRC" O="$OUT/opensbi" -j"$JOBS" \
    CROSS_COMPILE="$SBI_CROSS" PLATFORM=generic \
    PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
    PLATFORM_RISCV_ABI=ilp32 \
    FW_JUMP_ADDR=$FW_JUMP_ADDR FW_JUMP_FDT_ADDR=$FW_JUMP_FDT_ADDR \
    FW_PAYLOAD=n FW_DYNAMIC=n
cp "$OUT/opensbi/platform/generic/firmware/fw_jump.bin" "$OUT/fw_jump.bin"
cp "$OUT/opensbi/platform/generic/firmware/fw_jump.elf" "$OUT/fw_jump.elf"

if [ -z "${LINUX_SRC:-}" ]; then
    LINUX_SRC="$OUT/linux-src"
    if [ ! -d "$LINUX_SRC" ]; then
        git clone -q --shared --no-checkout "$LINUX_REPO" "$LINUX_SRC"
        git -C "$LINUX_SRC" -c advice.detachedHead=false checkout -q "$LINUX_VERSION"
    fi
fi

# build_kernel <build dir> <config fragments...>: tinyconfig plus the
# fragments, later fragments override earlier ones.
build_kernel() {
    local dir="$1"
    shift
    local kmake=(make -s -C "$LINUX_SRC" O="$dir" ARCH=riscv
                 CROSS_COMPILE="$LINUX_CROSS" -j"$JOBS")
    local stale=0 frag
    [ -f "$dir/.config" ] || stale=1
    for frag in "$@"; do
        [ "$frag" -nt "$dir/.config" ] && stale=1
    done
    if [ $stale -eq 1 ]; then
        mkdir -p "$dir"
        "${kmake[@]}" tinyconfig
        "$LINUX_SRC/scripts/kconfig/merge_config.sh" -m -O "$dir" \
            "$dir/.config" "$@" >/dev/null
        "${kmake[@]}" olddefconfig
        # Make sure that the fragments were applied (the last setting of
        # each option wins).
        cat "$@" | grep '^CONFIG_' | tac | awk -F= '!seen[$1]++' |
        while IFS= read -r line; do
            case "$line" in
            CONFIG_*=n) ! grep -qx "${line%=n}=y" "$dir/.config" ||
                        echo "warning: $line not applied" ;;
            CONFIG_*)   grep -qx "$line" "$dir/.config" ||
                        echo "warning: $line not applied" ;;
            esac
        done
    fi
    "${kmake[@]}" Image
}

echo "== Linux ($LINUX_SRC)"
build_kernel "$OUT/linux" "$TOP/platform/linux-merv.config"
cp "$OUT/linux/arch/riscv/boot/Image" "$OUT/Image"

echo "== Linux SMP"
build_kernel "$OUT/linux-smp" "$TOP/platform/linux-merv.config" \
    "$TOP/platform/linux-merv-smp.config"
cp "$OUT/linux-smp/arch/riscv/boot/Image" "$OUT/Image-smp"

echo "== initramfs"
"${LINUX_CROSS}gcc" -march=rv32ima_zicsr -mabi=ilp32 -static -nostdlib \
    -o "$OUT/init" "$TOP/platform/initramfs/init.S"
sed "s|@INIT@|$OUT/init|" "$TOP/platform/initramfs/initramfs.list" \
    > "$OUT/initramfs.list"
"$OUT/linux/usr/gen_init_cpio" "$OUT/initramfs.list" > "$OUT/initramfs.cpio"

echo "== device tree"
INITRD_SIZE=$(stat -c %s "$OUT/initramfs.cpio")
INITRD_END=$(printf "0x%x" $((INITRD_ADDR + INITRD_SIZE)))
for harts in 1 4; do
    cpp -P -nostdinc -undef -x assembler-with-cpp -I "$TOP/platform" \
        -DINITRD_START=$INITRD_ADDR -DINITRD_END=$INITRD_END \
        -DNUM_HARTS=$harts "$TOP/platform/merv-sim.dts" |
        dtc -q -I dts -O dtb -o "$OUT/merv-sim-$harts.dtb"
done
cp "$OUT/merv-sim-1.dtb" "$OUT/merv-sim.dtb"

cat > "$OUT/boot-args" <<ARGS
--binary $OUT/fw_jump.bin@0x80000000
--binary $OUT/Image@$FW_JUMP_ADDR
--binary $OUT/merv-sim.dtb@$DTB_ADDR
--binary $OUT/initramfs.cpio@$INITRD_ADDR
ARGS
cat > "$OUT/boot-args-smp4" <<ARGS
--harts 4
--binary $OUT/fw_jump.bin@0x80000000
--binary $OUT/Image-smp@$FW_JUMP_ADDR
--binary $OUT/merv-sim-4.dtb@$DTB_ADDR
--binary $OUT/initramfs.cpio@$INITRD_ADDR
ARGS
echo "== done: $OUT"
