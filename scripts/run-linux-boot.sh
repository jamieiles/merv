#!/bin/bash
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Boot OpenSBI + Linux + the hello world initramfs on the simulator and check
# that it prints "Hello, world" and powers off cleanly.  Exits with 77 (skip)
# if the software hasn't been built with scripts/build-software.sh.
#
# usage: run-linux-boot.sh <merv-sim> <bootrom.elf> <sw_dir> [sim args...]
set -uo pipefail

SIM="$1"
BOOTROM="$2"
SW="$3"
shift 3

if [ ! -f "$SW/boot-args" ]; then
    echo "software not built, run scripts/build-software.sh"
    exit 77
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

"$SIM" --elf "$BOOTROM" $(cat "$SW/boot-args") --no-echo --uart-log "$LOG" \
    --max-steps 1000000000 --stats "$@"
status=$?
tail -5 "$LOG"
if [ $status -ne 0 ]; then
    echo "simulator exited with $status"
    exit 1
fi
if ! grep -q "^Hello, world" "$LOG"; then
    echo "no greeting from init"
    exit 1
fi
