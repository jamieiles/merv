#!/usr/bin/env python3
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
"""Run riscv-arch-test (2.6.2, make based) against the merv simulator."""
import argparse
import os
import subprocess
import sys

DEVICES = ['I', 'M', 'Zifencei', 'privilege']

# The misaligned branch/jump references in 2.6.2 assume the C extension (no
# trap), merv doesn't implement C so only run the privilege tests that are
# independent of it.  riscv-tests ma_fetch covers misaligned jumps.
PRIV_TESTS = ['ebreak', 'ecall', 'misalign-lh-01', 'misalign-lhu-01',
              'misalign-lw-01', 'misalign-sh-01', 'misalign-sw-01']


def make(src, work, target_dir, sim, sim_args, device, target, test=None):
    cmd = ['make', '-s', '-C', src, f'WORK={work}', f'TARGETDIR={target_dir}',
           'RISCV_TARGET=merv-sim', f'RISCV_DEVICE={device}', 'XLEN=32',
           f'TARGET_SIM={sim}', f'RISCV_TARGET_FLAGS={sim_args}',
           f'-j{os.cpu_count()}', target]
    if test:
        cmd.append(f'RISCV_TEST={test}')
    return subprocess.run(cmd).returncode == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('sim')
    parser.add_argument('src', help='riscv-arch-test source directory')
    parser.add_argument('work', help='work directory')
    parser.add_argument('target_dir', help='arch-test target directory')
    parser.add_argument('--sim-args', default='')
    parser.add_argument('--device', action='append')
    args = parser.parse_args()

    sim = os.path.abspath(args.sim)
    work = os.path.abspath(args.work)
    target_dir = os.path.abspath(args.target_dir)
    failures = []

    for device in args.device or DEVICES:
        if device == 'privilege':
            ok = all(make(args.src, work, target_dir, sim, args.sim_args,
                          device, 'simulate', t) for t in PRIV_TESTS)
            ok = ok and make(args.src, work, target_dir, sim, args.sim_args,
                             device, 'verify', PRIV_TESTS[0])
        else:
            ok = make(args.src, work, target_dir, sim, args.sim_args, device,
                      'variant')
        if not ok:
            failures.append(device)

    if failures:
        print('FAILED: ' + ' '.join(failures))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
