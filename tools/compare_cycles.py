#!/usr/bin/env python3
"""Compare RTL and functional netlist cycles with the official test harness.

Matching bounded simulations are evidence, not a formal equivalence proof.
Neither testcases nor the simulator implementation are changed by this tool.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from testcase import execute, CYCLES


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', type=Path, required=True)
    parser.add_argument('--gate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cases', nargs='+')
    parser.add_argument('--exclude-cases', nargs='*', default=[], help='omit named cases from this comparison')
    parser.add_argument('--latencies', type=int, nargs='+', default=[10])
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--max-cycles', type=int, default=20000000)
    args = parser.parse_args()
    if args.jobs < 1 or args.max_cycles < 1 or any(x < 1 for x in args.latencies):
        parser.error('jobs, cycle limit and latencies must be positive')
    rtl, gate = args.rtl.resolve(), args.gate.resolve()
    cases = args.cases or sorted(p.name for p in (ROOT / 'testcases').iterdir()
                                if p.is_dir() and p.name.startswith(('correctness_', 'perf_')))
    for name in [*cases, *args.exclude_cases]:
        if Path(name).name != name or not (ROOT / 'testcases' / name).is_dir():
            parser.error(f'invalid testcase: {name}')
    cases = [name for name in cases if name not in args.exclude_cases]
    if not cases:
        parser.error('no testcases selected')

    def compare(job):
        name, latency = job
        row = {'case': name, 'latency': latency, 'passed': False}
        for label, simulator in [('rtl', rtl), ('gate', gate)]:
            try:
                run = execute(simulator.parent, ROOT / 'testcases' / name,
                              args.max_cycles, latency, simulator)
                match = CYCLES.search(run.stderr)
                if not match:
                    raise ValueError('missing official cycle report')
                row[label + '_cycles'] = int(match[1])
                row[label + '_functional_passed'] = True
            except (OSError, ValueError) as error:
                row[label + '_functional_passed'] = False
                row[label + '_error'] = str(error)
        row['cycles_match'] = (row.get('rtl_cycles') is not None and
                               row.get('rtl_cycles') == row.get('gate_cycles'))
        row['passed'] = (row['rtl_functional_passed'] and
                         row['gate_functional_passed'] and row['cycles_match'])
        print(f"{name} LAT={latency}: {'PASS' if row['passed'] else 'FAIL'} "
              f"RTL={row.get('rtl_cycles')} gate={row.get('gate_cycles')}", flush=True)
        return row

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        rows = list(pool.map(compare, [(name, lat) for lat in args.latencies for name in cases]))
    result = {'passed': bool(rows) and all(x['passed'] for x in rows),
              'rtl_sim_sha256': sha(rtl), 'gate_sim_sha256': sha(gate), 'results': rows}
    manifest = gate.parent.parent / 'manifest.json'
    if manifest.is_file():
        result['gate_manifest'] = json.loads(manifest.read_text())
        netlist = manifest.parent / 'mapped.v'
        result['gate_netlist_hash_matches'] = sha(netlist) == result['gate_manifest']['netlist_sha256']
        result['passed'] &= result['gate_netlist_hash_matches']
        result['gate_inputs_match_current_sources'] = all(
            Path(e['path']).is_file() and sha(Path(e['path'])) == e['sha256']
            for e in result['gate_manifest']['synthesis_inputs'])
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + '\n')
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
