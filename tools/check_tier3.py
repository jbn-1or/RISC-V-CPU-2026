#!/usr/bin/env python3
"""Audit Tier 3 synthesis/IPC artifacts against the current RTL inputs.

This checks the validated 32 KiB D$ configuration. Correctness, latency and
protocol tests must be run separately; their commands are in docs/validation.md.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

BENCHMARKS = {"perf_median", "perf_multiply", "perf_qsort",
              "perf_rsort", "perf_towers", "perf_vvadd"}


def audit(directory, perf_log):
    report = json.loads((directory / "report.json").read_text())
    module = json.loads((directory / "design.json").read_text())["modules"]["student_top"]
    synth_log = (directory / "synth.log").read_text()
    checks = {}

    mismatches = []
    for entry in report["inputs"]:
        path = Path(entry["path"])
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            mismatches.append(str(path))
    checks["input_hashes_match"] = bool(report["inputs"]) and not mismatches
    checks["opt_with_resource_sharing"] = (
        report["mode"] == "opt" and "Executing SHARE pass" in synth_log)

    driven = set()
    for port in module["ports"].values():
        if port["direction"] == "input":
            driven.update(port["bits"])
    for cell in module["cells"].values():
        for port, direction in cell["port_directions"].items():
            if direction == "output":
                driven.update(cell["connections"][port])
    macros = [c for c in module["cells"].values() if c["type"] == "fakeram_asap7_1024x8"]
    addresses = [c["connections"]["addr_in"] for c in macros]
    checks["dcache_has_32_macros"] = len(macros) == 32
    checks["dcache_addresses_are_10_bits"] = bool(addresses) and all(len(a) == 10 for a in addresses)
    checks["dcache_addresses_are_driven"] = all(
        isinstance(bit, int) and bit in driven for address in addresses for bit in address)
    checks["no_errors_latches_or_port_resizes"] = not re.search(
        r"ERROR:|Latch inferred|Resizing cell port|used but has no driver", synth_log)

    rows = re.findall(r"^(perf_\w+)\s+(\d+)\s+(\d+)\s+[\d.]+\s*$",
                      perf_log.read_text(), flags=re.MULTILINE)
    benchmarks = [{"name": name, "instructions": int(insns), "cycles": int(cycles)}
                  for name, insns, cycles in rows]
    checks["six_official_benchmarks"] = (
        len(rows) == 6 and {name for name, _, _ in rows} == BENCHMARKS
        and all(b["instructions"] > 0 and b["cycles"] > 0 for b in benchmarks))
    ipc = math.exp(sum(math.log(b["instructions"] / b["cycles"])
                       for b in benchmarks) / 6) if checks["six_official_benchmarks"] else 0.0
    area = report["area"]["area_um2"]
    frequency = report["timing"]["estimated_fmax_mhz"]
    checks["area_below_36000"] = math.isfinite(area) and 0 < area < 36000
    checks["frequency_above_300"] = math.isfinite(frequency) and frequency > 300
    checks["ipc_at_least_1_0985"] = ipc >= 1.0985
    return {
        "passed": all(checks.values()), "checks": checks,
        "area_um2": area, "fmax_mhz": frequency,
        "minimum_period_ns": report["timing"]["minimum_period_ns"],
        "ipc_geomean": ipc, "dcache_macros": len(macros),
        "input_hash_mismatches": mismatches, "benchmarks": benchmarks,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--synth", type=Path, required=True, help="directory containing opt/report.json")
    parser.add_argument("--perf-log", type=Path, required=True, help="make perf output at LATENCY=10")
    parser.add_argument("--out", type=Path, help="optional JSON output")
    args = parser.parse_args()
    try:
        result = audit(args.synth, args.perf_log)
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    output = json.dumps(result, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output)
    print(output, end="")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
