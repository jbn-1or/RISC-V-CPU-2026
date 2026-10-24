#!/usr/bin/env python3
"""Audit Tier 3 synthesis/IPC artifacts against the current RTL inputs.

This checks payload memories, parameter-derived D$ structure and all three
performance thresholds. Correctness, latency and protocol tests must be run
separately; their commands are in docs/validation.md.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re

BENCHMARKS = {"perf_median", "perf_multiply", "perf_qsort",
              "perf_rsort", "perf_towers", "perf_vvadd"}


def audit(directory, perf_log, target="tier3"):
    report = json.loads((directory / "report.json").read_text())
    module = json.loads((directory / "design.json").read_text())["modules"]["student_top"]
    synth_log = (directory / "synth.log").read_text()
    checks = {}

    # Macro counts alone do not prove that the CPU survived elaboration.
    # Native Yosys can misread an unpacked array of package structs as one
    # packed word and silently zero-extend a bit select at each read port.
    elaborated = json.loads((directory / "elaborated.json").read_text())["modules"]

    def complete_memory(module, name, width, depth):
        cell = module["cells"].get(name, {})
        params = cell.get("parameters", {})
        return (cell.get("type") == "$mem_v2"
                and int(params.get("WIDTH", "0"), 2) == width
                and int(params.get("SIZE", "0"), 2) == depth)

    frontend = elaborated["fetch_unit"]
    iq = elaborated["iq"]
    checks["frontend_payload_memory_complete"] = complete_memory(
        frontend, "ifb_mem", len(frontend["ports"]["fe0"]["bits"]), 8)
    checks["iq_instruction_memory_complete"] = complete_memory(
        iq, "insn_q", len(elaborated["decode1"]["ports"]["out_d"]["bits"]),
        len(iq["netnames"]["v_q"]["bits"]))
    skids = [m for name, m in elaborated.items()
             if name == "wb_skid" or m.get("attributes", {}).get("hdlname") == "wb_skid"]
    checks["writeback_fifo_memories_complete"] = bool(skids) and all(
        complete_memory(m, "mem", len(m["ports"]["in"]["bits"]),
                        int(m["parameter_default_values"]["DEPTH"], 2)) for m in skids)

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
    # Read capacity from the exact package used for this synthesis. Each
    # 32-bit word bank consists of four byte-write SRAM macros.
    package = next(Path(e["path"]) for e in report["inputs"] if Path(e["path"]).name == "cpu_pkg.sv")
    config = dict((k, int(v)) for k, v in re.findall(
        r"parameter int\s+(\w+)\s*=\s*(\d+)\s*;", package.read_text()))
    # A chained packed slice on up_pc was interpreted differently by native
    # Yosys and Verilator. Inspect the actual elaborated XOR connections, not
    # just the spelling of the repaired source expression.
    bp = elaborated.get("bp", {})
    gh = min(max(config["BP_GHR_BITS"], 2), max(1, (config["BHT_ENTRIES"]-1).bit_length()))
    bp_ports = bp.get("ports", {})
    pc_slice = bp_ports.get("up_pc", {}).get("bits", [])[2:gh+2]
    index_slice = bp_ports.get("up_ix", {}).get("bits", [])[:gh]
    restore = bp.get("netnames", {}).get("ghr_rst", {}).get("bits", [])
    checks["bp_recovery_pc_slice_correct"] = config["BP_GHR_BITS"] == 0 or (
        len(pc_slice) == len(index_slice) == gh and len(restore) >= gh
        and all(bit == "0" for bit in restore[gh:])
        and any(cell["type"] == "$xor"
                and cell["connections"].get("Y") == restore[:gh]
                and ((cell["connections"].get("A") == pc_slice
                      and cell["connections"].get("B") == index_slice)
                     or (cell["connections"].get("B") == pc_slice
                         and cell["connections"].get("A") == index_slice))
                for cell in bp.get("cells", {}).values()))
    lines, line_bytes = config["DC_LINES"], config["LINE_BYTES"]
    macros = [c for c in module["cells"].values() if c["type"] == f"fakeram_asap7_{lines}x8"]
    addresses = [c["connections"]["addr_in"] for c in macros]
    checks["dcache_has_expected_macros"] = len(macros) == line_bytes
    checks["dcache_addresses_have_full_width"] = bool(addresses) and all(
        len(a) == (lines-1).bit_length() for a in addresses)
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
    phase_checks = {k: v for k, v in checks.items()
                    if target == "tier3" or k != "ipc_at_least_1_0985"}
    return {
        "target": target, "passed": all(phase_checks.values()),
        "tier3_passed": all(checks.values()), "checks": checks,
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
    parser.add_argument("--target", choices=("tier3", "area-frequency"), default="tier3",
                        help="area-frequency records IPC but does not require its Tier 3 threshold")
    args = parser.parse_args()
    try:
        result = audit(args.synth, args.perf_log, args.target)
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
