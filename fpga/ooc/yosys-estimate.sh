#!/bin/bash
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
#
# Quick area/logic depth estimate of the core for Xilinx 7-series with Yosys
# (synth_xilinx).  This is only an estimate: Vivado (ooc.tcl) is the
# reference for utilization and Fmax.
#
# usage: yosys-estimate.sh [TLB_ENTRIES NATIVE_AMO HW_DIV [BARREL_SHIFT]]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTL="$HERE/../../rtl"
TLB="${1:-4}"
AMO="${2:-1}"
DIV="${3:-1}"
BS="${4:-0}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

yosys -q -l "$OUT/yosys.log" -p "
    read_verilog -sv -I$RTL $RTL/MervCore.sv $RTL/MervALU.sv $RTL/MervRAM.sv \
        $RTL/MervTLB.sv $RTL/MervMul.sv $RTL/MervDiv.sv \
        $HERE/MervCoreOOC.sv
    chparam -set TLB_ENTRIES $TLB -set NATIVE_AMO $AMO -set HW_DIV $DIV \
        -set BARREL_SHIFT $BS MervCoreOOC
    synth_xilinx -family xc7 -top MervCoreOOC -flatten -abc9
    tee -o $OUT/stat.txt stat
    write_json $OUT/netlist.json
" >/dev/null

echo "TLB_ENTRIES=$TLB NATIVE_AMO=$AMO HW_DIV=$DIV BARREL_SHIFT=$BS"
grep -E "LUT[1-6]|FDRE|FDSE|FDCE|FDPE|RAMB|DSP48|CARRY4|MUXF[78]|RAM[0-9]" "$OUT/stat.txt" | \
    awk '{print "  " $0}'
awk '/LUT[1-6]/ {l += $NF} /FD[RSCP]E/ {f += $NF} END {print "  total LUTs: " l "  FFs: " f}' "$OUT/stat.txt"
python3 "$HERE/yosys-timing.py" "$OUT/netlist.json" ${VERBOSE:+-v} | sed 's/^/  /'
