#!/usr/bin/env python3
"""Build isolated parameter configurations and measure correctness and IPC.

Snapshots prevent configuration runs from changing production cpu_pkg.sv. Each
result records every source hash; failed tests never count as an IPC result.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONFIGS = {
    'baseline': {},
    'issue1': {'ISSUE_WIDTH': 1},
    'assoc2': {'ASSOC': 2},
    'rob16': {'ROB_DEPTH': 16},
    'rob32': {'ROB_DEPTH': 32},
    'rob64': {'ROB_DEPTH': 64},
    'prf128': {'PRF_NUM': 128},
    'iq8': {'IQ_DEPTH': 8},
    'iq4': {'IQ_DEPTH': 4},
    'cache_half': {'IC_LINES': 64, 'DC_LINES': 512},
    'cache_small': {'IC_LINES': 32, 'DC_LINES': 256},
    'dcache_half': {'DC_LINES': 512},
    'icache_half': {'IC_LINES': 64},
    'decode1': {'DECODE_WIDTH': 1},
    'dc512_assoc2': {'DC_LINES': 512, 'ASSOC': 2},
    'dc512_rob64': {'DC_LINES': 512, 'ROB_DEPTH': 64},
    'dc512_window64': {'DC_LINES': 512, 'ROB_DEPTH': 64, 'PRF_NUM': 128},
    'dc512_iq8': {'DC_LINES': 512, 'IQ_DEPTH': 8},
    'dc512_ldq8': {'DC_LINES': 512, 'LDQ_DEPTH': 8},
    'dc512_ghr4': {'DC_LINES': 512, 'BP_GHR_BITS': 4},
    'dc512_ghr0': {'DC_LINES': 512, 'BP_GHR_BITS': 0},
    'dc512_bht512': {'DC_LINES': 512, 'BHT_ENTRIES': 512},
    'dc512_bht1024': {'DC_LINES': 512, 'BHT_ENTRIES': 1024},
    'registered_only': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0},
    'no_bypass_only': {'WB_BYPASS': 0, 'EARLY_REDIRECT': 1},
    'early_bypass': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1},
    'ipc_restore': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16},
    'ipc_ldq8': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'LDQ_DEPTH': 8},
    'ipc_mul2': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'MUL_LAT': 2},
    'ipc_ldq8_mul2': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'LDQ_DEPTH': 8, 'MUL_LAT': 2},
    'ipc_mshr4': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'MSHR_N': 4},
    'ipc_ldq8_mshr4': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'LDQ_DEPTH': 8, 'MSHR_N': 4},
    'ipc_iq8': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8},
    'ipc_rob64': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 1, 'ROB_DEPTH': 64, 'STQ_DEPTH': 16, 'LDQ_DEPTH': 8, 'PRF_NUM': 128},
    'ipc_iq8_registered': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8},
    'ipc_iq8_registered_mul2': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8, 'MUL_LAT': 2},
    'ipc_iq8_btb64': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8, 'BTB_ENTRIES': 64},
    'ipc_iq8_btb32': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8, 'BTB_ENTRIES': 32},
    'ipc_iq8_bht128': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8, 'BHT_ENTRIES': 128},
    'ipc_iq8_btb64_bht128': {'WB_BYPASS': 1, 'EARLY_REDIRECT': 0, 'ROB_DEPTH': 32, 'STQ_DEPTH': 16, 'IQ_DEPTH': 8, 'LDQ_DEPTH': 8, 'BTB_ENTRIES': 64, 'BHT_ENTRIES': 128},
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configs', nargs='+', choices=CONFIGS,
                        default=['baseline', 'issue1', 'assoc2', 'rob32',
                                 'prf128', 'iq8', 'cache_small', 'decode1'])
    parser.add_argument('--out', type=Path, default=ROOT / 'build' / 'configs')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--parallel', type=int, default=2)
    parser.add_argument('--units', action='store_true', help='also run cache and issue configuration tests')
    parser.add_argument('--perf-only', action='store_true', help='screen candidates; does not establish correctness')
    parser.add_argument('--benchmark-only', action='store_true',
                        help='run official correctness and performance; skip extra latency/ISA suites')
    args = parser.parse_args()
    if args.jobs < 1 or args.parallel < 1:
        parser.error('jobs and parallel must be positive')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    entries = [x.split('#', 1)[0].strip() for x in (ROOT / 'verilog/filelist.f').read_text().splitlines()]
    entries = [x for x in entries if x]
    # Capture once before starting threads, so every configuration has the
    # exact same baseline and no live-source edits can enter a running build.
    sources = {x: (ROOT / 'verilog' / x).read_bytes() for x in entries}
    hashes = {x: hashlib.sha256(data).hexdigest() for x, data in sources.items()}
    (out / 'source_hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')

    def run(name):
        folder = out / name
        rtl = folder / 'rtl'
        rtl.mkdir(parents=True, exist_ok=True)
        for entry, data in sources.items():
            target = rtl / entry
            target.parent.mkdir(parents=True, exist_ok=True)
            if entry == 'cpu_pkg.sv':
                content = data.decode()
                for key, value in CONFIGS[name].items():
                    content, count = re.subn(r'(parameter int\s+' + key + r'\s*=\s*)\d+',
                                             lambda m: m[1] + str(value), content)
                    if count != 1:
                        raise ValueError(f'parameter {key}: found {count} declarations')
                data = content.encode()
            target.write_bytes(data)
        filelist = rtl / 'filelist.f'
        filelist.write_text('\n'.join(entries) + '\n')
        result = {'name': name, 'overrides': CONFIGS[name], 'passed': False, 'steps': {},
                  'validation': ('performance_only' if args.perf_only else
                                 'correctness_and_performance' if args.benchmark_only else 'full')}

        def step(label, command):
            with (folder / f'{label}.log').open('w') as log:
                code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
            result['steps'][label] = code
            if code:
                print(f'{name}: FAIL {label} ({folder / (label + ".log")})', flush=True)
            return code == 0

        sim = folder / 'sim' / 'sim'
        if not step('build', [sys.executable, str(ROOT / 'scripts/build.py'), '--filelist', str(filelist),
                              '--out', str(sim.parent), '--jobs', str(args.jobs)]):
            return result
        common = ['--sim', str(sim), '--max-cycles', '20000000', '--latency', '10']
        for label, command in [
            ('correctness', [sys.executable, str(ROOT / 'scripts/testcase.py'), '--kind', 'correctness', *common]),
            ('perf', [sys.executable, str(ROOT / 'scripts/testcase.py'), '--kind', 'perf', *common]),
            ('latency', [sys.executable, str(ROOT / 'tools/run_latency.py'), '--sim', str(sim),
                         '--log', str(folder / 'latency_details.log')]),
            ('isa', [sys.executable, str(ROOT / 'tools/run_isa.py'), '--sim', str(sim), '--out', str(folder / 'isa')]),
        ]:
            if args.perf_only and label != 'perf':
                continue
            if args.benchmark_only and label not in ('correctness', 'perf'):
                continue
            if not step(label, command):
                return result
        if args.units:
            for top in ['tb_cache_assoc', 'tb_issue_width', 'tb_dcache_recovery', 'tb_lsu']:
                if not step(top, [sys.executable, str(ROOT / 'tools/run_unit.py'), top, '--jobs', str(args.jobs),
                                  '--filelist', str(filelist), '--out', str(folder / top)]):
                    return result
        rows = re.findall(r'^(perf_\w+)\s+(\d+)\s+(\d+)\s+[\d.]+\s*$',
                          (folder / 'perf.log').read_text(), re.MULTILINE)
        if len(rows) != 6:
            raise ValueError(f'{name}: expected six official benchmarks')
        result['benchmarks'] = [dict(name=n, instructions=int(i), cycles=int(c), ipc=int(i)/int(c))
                                for n, i, c in rows]
        result['ipc_geomean'] = math.exp(sum(math.log(b['ipc']) for b in result['benchmarks']) / 6)
        result['passed'] = True
        print(f"{name}: PASS IPC={result['ipc_geomean']:.9f}", flush=True)
        return result

    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        results = list(pool.map(run, args.configs))
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return int(any(not x['passed'] for x in results))


if __name__ == '__main__':
    raise SystemExit(main())
