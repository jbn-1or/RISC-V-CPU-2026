#!/usr/bin/env python3
"""Build the reported mapped netlist with Liberty logic and SRAM models.

This uses the unmodified course simulator, so testcases and cycle counts can
be compared directly with RTL simulation. It is functional gate simulation,
without annotated timing delays, rather than a formal equivalence proof.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth', type=Path, required=True)
    parser.add_argument('--out', type=Path, default=ROOT / 'build' / 'gate')
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    enter_appimage(DEFAULT_APPIMAGE)
    synth, out = args.synth.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = json.loads((synth / 'report.json').read_text())
    # Library paths in reports may point into a previous transient mount.
    import os
    library_root = Path(os.environ['CPU2026_ASAP7_LIB'])
    libs = sorted(library_root.glob('*.lib'))
    reported = {Path(e['path']).name: e['sha256'] for e in report['libraries']}
    for lib in libs:
        if hashlib.sha256(lib.read_bytes()).hexdigest() != reported.get(lib.name):
            raise ValueError(f'library differs from synthesis: {lib.name}')
    models = out / 'cells.v'
    script = out / 'models.ys'
    script.write_text('\n'.join([
        *[f'read_liberty -ignore_miss_func "{lib}"' for lib in libs],
        f'write_verilog -noattr "{models}"',
    ]) + '\n')
    subprocess.run([packaged_tool('yosys'), '-Q', '-T', '-q', '-s', str(script)], check=True)
    ram = out / 'ram.v'
    definitions = []
    macros = {e['module']: e for e in report['area']['sram_instances']}
    for name, entry in sorted(macros.items()):
        depth, width = entry['depth'], entry['width']
        abits = (depth-1).bit_length()
        definitions.append(f'''module {name} (
    input clk, ce_in, we_in,
    input [{abits-1}:0] addr_in,
    input [{width-1}:0] wd_in,
    output reg [{width-1}:0] rd_out);
    reg [{width-1}:0] words [0:{depth-1}];
    always @(posedge clk) begin
        rd_out <= 'x;
        if (ce_in) begin
            if (we_in) words[addr_in] <= wd_in;
            else rd_out <= words[addr_in];
        end
    end
endmodule
''')
    ram.write_text('\n'.join(definitions))
    # Copy the exact reported netlist to freeze its identity for this build.
    netlist = out / 'mapped.v'
    netlist.write_bytes((synth / 'mapped.v').read_bytes())
    filelist = out / 'filelist.f'
    filelist.write_text('\n'.join(str(p) for p in (models, ram, netlist)) + '\n')
    manifest = {
        'netlist_sha256': hashlib.sha256(netlist.read_bytes()).hexdigest(),
        'synthesis_inputs': report['inputs'],
        'models_sha256': hashlib.sha256(models.read_bytes()).hexdigest(),
        'ram_sha256': hashlib.sha256(ram.read_bytes()).hexdigest(),
    }
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run([sys.executable, str(ROOT / 'scripts/build.py'), '--filelist', str(filelist),
                    '--out', str(out / 'sim'), '--jobs', str(args.jobs)], check=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
