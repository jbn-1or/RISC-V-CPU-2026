# Two-wide RV32IM out-of-order CPU

English | [简体中文](README-ZH.md)

This repository implements an RV32IM processor with up to two instructions issued and committed per cycle, physical register renaming, a unified issue queue, in-order ROB retirement, and a nonblocking data cache. The top-level module is `student_top`, with an AXI4-Lite master interface.

Start with the [architecture guide, in Chinese](docs/architecture.md), then read `student_top → core_ooo → rename/rob/iq → load_store_queue → memory_subsystem/dcache`. Reproduction commands and synthesis assumptions are documented in the [validation guide](docs/validation.md).

## Configuration

| Component | Configuration |
| --- | --- |
| Decode / issue / commit | Up to 2 instructions per cycle |
| ROB / physical registers / IQ | 32 / 64 / 4 entries |
| Fetch buffer / LDQ / STQ | 8 / 4 / 16 entries |
| Execution | 2×ALU, BRU, four-stage multiplier, iterative divider, LSU |
| I$ / D$ | 4 KiB / 32 KiB, direct mapped, 32-byte lines |
| Data memory | 2 MSHRs; write-through, no-write-allocate; store forwarding |
| Prediction | gshare BHT256, BTB128, RAS16 |
| AXI outstanding requests | Up to 8 reads and 8 writes; independent AW/W handshakes |

The ordinary ALU path has five broad phases: fetch, decode into the IFB, rename/dispatch, issue/execute/writeback, and commit. Queue waits, multiplication, division and cache misses have different latencies; this is not a fixed five-cycle machine.

The Tier 3 requirements are **area <36,000 µm², frequency >300 MHz, and geometric-mean IPC ≥1.0985**. The refactored version achieves **28,778.756 µm², 303.858 MHz and IPC 1.102294** under the course synthesis flow. Correctness passes 19/19, the latency matrix passes 8/8, and all six benchmark instruction/cycle counts match the baseline. See the [validation record](docs/validation.md) for details.

## Build and check

Host prerequisites: Python 3.10+, GNU Make, G++ with C++17 support, and binutils. Place the course `cpu2026-tools-x86_64.AppImage` in the repository root, or configure native executables in `config.mk`.

```sh
git submodule update --init --recursive
chmod +x cpu2026-tools-x86_64.AppImage
make build JOBS=8 BUILD=build/check
make test SIM=build/check/sim MAX_CYCLES=20000000
make perf SIM=build/check/sim MAX_CYCLES=20000000
python3 tools/run_latency.py --sim build/check/sim
python3 tools/run_unit.py tb_lsu
python3 tools/run_unit.py tb_axi_write
make synth MODE=opt SYNTH_OUT=build/synth_check
```

`make` or `make code` produces `./code` for the OJ. Use `make run PROGRAM=... EXPECTED=...` for an individual program, or `Case=perf_qsort` to select a benchmark. Pass `SIM=...` to reuse an existing simulator.

## Source map

| Path | Responsibility |
| --- | --- |
| `verilog/cpu_pkg.sv` | Configuration, payload types, address and age predicates |
| `verilog/student_top.sv` | CPU integration and AXI response routing |
| `verilog/filelist.f` | Single source list for production RTL and unit-test builds |
| `verilog/frontend/` | Fetch, decode, instruction cache and predictor |
| `verilog/backend/` | Rename, ROB, IQ, PRF, execution and writeback |
| `verilog/memory/` | Load/store queue, cache integration, data cache and AXI master |
| `verilog/stubs/` | Unit and integration testbenches |
| `scripts/` | Course simulation, test and synthesis framework |
| `tools/` | Design-specific unit tests, latency regression and synthesis helpers |
| `docs/` | Architecture, validation and interface documentation |
| `testcases/` | Official testcase submodule |
| `build/` | Generated local artifacts, ignored by Git |

Parameters live in `cpu_pkg.sv`. The datapath is implemented as two-wide; changing `ISSUE_WIDTH` alone does not generate an arbitrary-width CPU. Recheck all three Tier 3 metrics after changing queue depths, cache sizes or handshake paths.

Further reading: [AXI4-Lite](docs/axi4-lite.md), [SRAM model](docs/sram.md), [unit tests](verilog/stubs/README.md). The ignored local `references/` directory contains historical working notes and is not required to understand or run this design.

The original toolchain, grading and submission instructions are preserved in the [course framework documentation](docs/framework-EN.md).
