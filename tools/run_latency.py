#!/usr/bin/env python3
"""Run memory-sensitive correctness tests at both short and long AXI latencies."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CASES = ("magic", "queens", "tak", "qsort")
LATENCIES = (1, 50)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--testcases", type=Path, default=ROOT / "testcases")
    parser.add_argument("--log", type=Path, default=ROOT / "build" / "latency.log")
    args = parser.parse_args()
    sim, testcases = args.sim.resolve(), args.testcases.resolve()
    if not sim.is_file():
        parser.error(f"simulator does not exist: {sim}")

    def run(item):
        case, latency = item
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "testcase.py"),
            "--kind", "correctness", "--case", f"correctness_{case}",
            "--testcases", str(testcases), "--sim", str(sim),
            "--latency", str(latency), "--max-cycles", "20000000",
        ], cwd=ROOT, capture_output=True, text=True)
        return case, latency, result

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(run, ((c, l) for c in CASES for l in LATENCIES)))
    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.log.write_text("\n".join(
        f"{case} LAT={latency} rc={r.returncode}\n{r.stdout}{r.stderr}"
        for case, latency, r in results))
    for case, latency, result in results:
        print(f"{case} LAT={latency}: {'PASS' if result.returncode == 0 else 'FAIL'}")
    return int(any(r.returncode for _, _, r in results))


if __name__ == "__main__":
    raise SystemExit(main())
