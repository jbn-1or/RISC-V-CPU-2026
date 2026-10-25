#!/usr/bin/env python3
"""Run BP recovery tests on RTL and native Yosys output, without editing production files."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool

CONFIGS = {'default': {}, 'ghr0': {'BP_GHR_BITS': 0}, 'ghr1': {'BP_GHR_BITS': 1},
           'ghr4': {'BP_GHR_BITS': 4}, 'ghr12': {'BP_GHR_BITS': 12},
           'bht128': {'BHT_ENTRIES': 128}, 'bht256': {'BHT_ENTRIES': 256}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configs', choices=CONFIGS, nargs='+', default=list(CONFIGS))
    parser.add_argument('--out', type=Path, default=ROOT / 'build/bp_recovery')
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    enter_appimage(DEFAULT_APPIMAGE)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    package = (ROOT / 'verilog/cpu_pkg.sv').read_text()
    bp = (ROOT / 'verilog/frontend/bp.sv').read_bytes()
    results = []
    for name in args.configs:
        folder = out / name
        folder.mkdir(exist_ok=True)
        pkg = package
        for key, value in CONFIGS[name].items():
            pkg, count = re.subn(r'(parameter int\s+' + key + r'\s*=\s*)\d+',
                                lambda m: m[1] + str(value), pkg)
            if count != 1:
                raise ValueError(f'missing parameter {key}')
        (folder / 'cpu_pkg.sv').write_text(pkg)
        (folder / 'bp.sv').write_bytes(bp)
        rtl_list = folder / 'rtl.f'
        rtl_list.write_text(str(folder / 'cpu_pkg.sv') + '\n' + str(folder / 'bp.sv') + '\n')
        ys = folder / 'native.ys'
        ys.write_text(f'read_verilog -sv -D SYNTHESIS "{folder / "cpu_pkg.sv"}" "{folder / "bp.sv"}"\n'
                      f'synth -top bp -noabc\nwrite_verilog -noattr "{folder / "native.v"}"\n')
        native_list = folder / 'native.f'
        native_list.write_text(str(folder / 'cpu_pkg.sv') + '\n' + str(folder / 'native.v') + '\n')
        steps = [('synthesis', [packaged_tool('yosys'), '-Q', '-T', '-q', '-s', str(ys)])]
        for label, filelist in [('rtl', rtl_list), ('native', native_list)]:
            steps.append((label, [sys.executable, str(ROOT / 'tools/run_unit.py'), 'tb_bp',
                                  '--filelist', str(filelist), '--out', str(folder / label),
                                  '--jobs', str(args.jobs)]))
        row = {'config': name, 'overrides': CONFIGS[name],
               'bp_sha256': hashlib.sha256(bp).hexdigest(), 'steps': {}}
        for label, command in steps:
            with (folder / (label + '.log')).open('w') as log:
                rc = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
            row['steps'][label] = rc
            if rc:
                break
        row['passed'] = len(row['steps']) == 3 and all(v == 0 for v in row['steps'].values())
        results.append(row)
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(f"{name}: {'PASS' if row['passed'] else 'FAIL'}", flush=True)
    return int(any(not row['passed'] for row in results))


if __name__ == '__main__':
    raise SystemExit(main())
