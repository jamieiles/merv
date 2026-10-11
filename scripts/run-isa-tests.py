#!/usr/bin/env python3
# Copyright 2026 Jamie Iles
# SPDX-License-Identifier: Apache-2.0
"""Run the riscv-tests ISA tests against the merv simulator."""
import argparse
import concurrent.futures
import os
import re
import subprocess
import sys

TEST_RE = r'^rv32(ui|um|ua|si|mi)-[pv]-[^.]*$'

SKIP = {
    # Misaligned data accesses trap (OpenSBI emulates them).
    'rv32ui-p-ma_data', 'rv32ui-v-ma_data',
    # There are no PMP entries so all PMP CSRs are read-only zero (permitted
    # by the privileged spec), the test requires at least one entry.
    'rv32mi-p-pmpaddr',
}


def run(sim, path, extra, timeout):
    cmd = [sim, '--elf', path, '--compliance', '--max-steps', '20000000',
           '--trace-last', '40'] + extra
    try:
        p = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=timeout)
        return p.returncode == 0, p.stderr.decode(errors='replace')
    except subprocess.TimeoutExpired:
        return False, 'timeout'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('sim')
    parser.add_argument('test_dir')
    parser.add_argument('--filter', default='')
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--sim-args', default='',
                        help='extra simulator arguments')
    args = parser.parse_args()
    extra = args.sim_args.split()

    tests = sorted(f for f in os.listdir(args.test_dir)
                   if re.match(TEST_RE, f) and f not in SKIP and
                   args.filter in f)
    if not tests:
        print('no tests found', file=sys.stderr)
        return 1

    failures = []
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as ex:
        futures = {ex.submit(run, args.sim, os.path.join(args.test_dir, t),
                             extra, args.timeout): t for t in tests}
        for f in concurrent.futures.as_completed(futures):
            ok, err = f.result()
            if not ok:
                failures.append((futures[f], err))

    print(f'{len(tests) - len(failures)}/{len(tests)} passed '
          f'({" ".join(extra)})')
    for name, err in sorted(failures)[:20 if not args.verbose else None]:
        print(f'FAIL: {name}')
        if args.verbose:
            print(err)
    if len(failures) > 20 and not args.verbose:
        print(f'... and {len(failures) - 20} more')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
