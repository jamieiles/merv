#!/usr/bin/env python3
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
"""Rough static timing estimate of a Yosys synth_xilinx netlist (JSON).

This is a sanity check of logic depth, not a substitute for Vivado timing:
delays are approximate Spartan-7 -2 values with an average routing delay per
net.  Paths start at flop/BRAM/DSP outputs and top level inputs and end at
flop/BRAM/DSP inputs and top level outputs.
"""
import json
import sys
from collections import defaultdict

ROUTE = 0.45      # average net delay
LUT = 0.12        # LUT logic delay
MUXF = 0.25       # MUXF7/MUXF8
CARRY_IN = 0.40   # LUT/DI into the carry chain (excluding routing)
CARRY_STAGE = 0.12  # CI -> CO per CARRY4
CARRY_OUT = 0.25  # CI -> O
CLK_Q = 0.40      # flop clock to out
BRAM_CLK_Q = 2.10 # BRAM clock to out without the output register
DSP_CLK_Q = 0.60  # DSP with output register
SETUP = 0.10

SEQ = ('FD', 'RAMB', 'DSP48')


def main():
    netlist = json.load(open(sys.argv[1]))
    top = [m for m in netlist['modules'].values()
           if m.get('attributes', {}).get('top')][0]

    drivers = {}      # bit -> (cell, port)
    sinks = defaultdict(list)
    cells = top['cells']
    for name, c in cells.items():
        for port, bits in c['connections'].items():
            d = c['port_directions'].get(port)
            for b in bits:
                if isinstance(b, str):
                    continue
                if d == 'output':
                    drivers[b] = (name, port)
                else:
                    sinks[b].append((name, port))

    arrival = {}
    pred = {}

    def is_seq(t):
        return t.startswith(SEQ)

    def cell_out_delay(name, port, visiting):
        """Arrival time at an output port of a cell."""
        key = (name, port)
        if key in arrival:
            return arrival[key]
        c = cells[name]
        t = c['type']
        if t.startswith('FD'):
            arrival[key] = CLK_Q
            return CLK_Q
        if t.startswith('RAMB'):
            arrival[key] = BRAM_CLK_Q
            return BRAM_CLK_Q
        if t.startswith('DSP48'):
            arrival[key] = DSP_CLK_Q
            return DSP_CLK_Q
        if key in visiting:
            return 0.0
        visiting.add(key)
        ins = []
        for p, bits in c['connections'].items():
            if c['port_directions'].get(p) != 'input':
                continue
            for b in bits:
                if isinstance(b, str):
                    continue
                ins.append((p, b))
        worst = 0.0
        worst_in = None
        for p, b in ins:
            a = net_arrival(b, visiting)
            if t == 'CARRY4':
                if p == 'CI':
                    d = a + (CARRY_OUT if port.startswith('O') else CARRY_STAGE)
                else:
                    d = a + ROUTE + CARRY_IN + (CARRY_OUT if port.startswith('O') else CARRY_STAGE)
            elif t.startswith('MUXF'):
                d = a + MUXF
            else:
                d = a + ROUTE + LUT
            if d > worst:
                worst, worst_in = d, drivers.get(b)
        visiting.discard(key)
        arrival[key] = worst
        pred[key] = worst_in
        return worst

    def net_arrival(b, visiting):
        if b not in drivers:
            return 0.0
        name, port = drivers[b]
        return cell_out_delay(name, port, visiting)

    import os
    ENDPOINT = os.environ.get('ENDPOINT', '')
    qnames = {}
    for nm, net in top['netnames'].items():
        if not nm.startswith('$'):
            for b in net['bits']:
                if not isinstance(b, str):
                    qnames.setdefault(b, nm)

    def qname(c):
        q = c['connections'].get('Q', [None])
        return qnames.get(q[0], '') if q else ''

    worst = 0.0
    worst_end = None
    worst_start = None
    for name, c in cells.items():
        if not is_seq(c['type']):
            continue
        for p, bits in c['connections'].items():
            if c['port_directions'].get(p) != 'input' or p in ('C', 'CLKARDCLK', 'CLKBWRCLK', 'CLK'):
                continue
            for b in bits:
                if isinstance(b, str):
                    continue
                a = net_arrival(b, set())
                if not a:
                    continue
                t = a + ROUTE + SETUP
                if ENDPOINT and ENDPOINT not in qname(c):
                    continue
                if t > worst:
                    worst, worst_end = t, (name, p)
                    worst_start = drivers.get(b)

    if '-v' in sys.argv:
        names = {}
        for nm, net in top['netnames'].items():
            if nm.startswith('$'):
                continue
            for i, b in enumerate(net['bits']):
                if not isinstance(b, str) and b not in names:
                    names[b] = nm
        per_reg = defaultdict(float)
        for name, c in cells.items():
            if not c['type'].startswith('FD'):
                continue
            q = c['connections'].get('Q', [None])[0]
            reg = names.get(q, name)
            for p, bits in c['connections'].items():
                if c['port_directions'].get(p) != 'input' or p == 'C':
                    continue
                for b in bits:
                    if isinstance(b, str):
                        continue
                    a = net_arrival(b, set())
                    per_reg[reg] = max(per_reg[reg], a + ROUTE + SETUP)
        print('  slowest endpoints:')
        for reg, t in sorted(per_reg.items(), key=lambda x: -x[1])[:15]:
            print(f'    {t:6.2f} ns  {reg}')
    print(f'estimated worst path: {worst:.2f} ns -> {1000 / worst:.0f} MHz '
          f'(ending at {worst_end[0]}.{worst_end[1]})')
    if '-v' in sys.argv:
        names = {}
        for nm, net in top['netnames'].items():
            if nm.startswith('$'):
                continue
            for i, b in enumerate(net['bits']):
                if not isinstance(b, str) and b not in names:
                    names[b] = f'{nm}[{i}]' if len(net['bits']) > 1 else nm
        def out_name(node):
            c = cells[node[0]]
            for b in c['connections'].get(node[1], []):
                if b in names:
                    return names[b]
            return ''
        endq = cells[worst_end[0]]['connections'].get('Q', [])
        print('  endpoint:', [names.get(b) for b in endq])
        node = worst_start
        while node:
            c = cells[node[0]]
            src = c.get('attributes', {}).get('src', '')
            print(f'  {arrival.get(node, 0):6.2f} {c["type"]:10s} {out_name(node)[:50]:50s} {src.split("|")[0][-40:]}')
            node = pred.get(node)


if __name__ == '__main__':
    sys.setrecursionlimit(100000)
    main()
