**2026-10-24：当前默认 CPU 在官方流程下同时达到 Tier 3 的面积、频率和 IPC 门槛。** 唯一要求来源为恢复后的官方 [README-EN.md](../README-EN.md)。面积/频率与 IPC 对应同一份最终生产 RTL，输入 SHA256 已核对。

| 指标 | 最终实测 | Tier 3 门槛 |
| --- | ---: | ---: |
| 总面积，含 SRAM | **30186.042410 µm²** | <36,000 µm² |
| 综合频率 | **300.822562 MHz** | >300 MHz |
| 最小周期 | **3.32421875000 ns** | <3.333333333 ns |
| LAT=10 六项 IPC 几何平均 | **1.104759628915139** | ≥1.0985 |
| 官方正确性 | **19/19** | 通过 |
| LAT=1/50 延迟矩阵 | **8/8** | 全部通过 |
| RV32IM 自检 | **5,307 项 × LAT=1/10/50** | 全部通过 |
| 单元测试 | **14/14** | 全部通过 |

IPC 比面积/频率阶段的 0.896022346877662 提高 **23.30%**。频率是课程默认理想时钟、无布线寄生的综合 STA 结果，未进行布局布线。2 ns 是综合优化目标；Tier 3 按实测最小周期和频率判断。

当前频率距门槛约 0.823 MHz；结果对应本页记录的源码 SHA256、默认官方工具和约束，后续 RTL 变更需要重新综合。

**最终配置与实现**

双发射/双提交，ROB32、PRF64、IQ8、LDQ8、STQ16、MUL_LAT=4，I$ 64 行（2 KiB）、D$ 512 行（16 KiB）、32 B line、直接映射、2 MSHR、BHT256、BTB64、RAS16。`WB_BYPASS=1`，`EARLY_REDIRECT=0`。

恢复同拍旁路与较大的调度窗口；保留寄存的前端恢复。IQ 使用并行年龄检查及两级轮转资格掩码，保持原发射次序和功能单元约束。LSQ 将 guard/load/完成候选改为并行年龄比较和资格掩码归约；恢复拍暂停 load 调度，保留较老 load，退休 store 继续 drain。完整设计取舍见 [report.md](report.md) 与 [architecture.md](architecture.md)。

此前修复的 SRA/SRAI、结构体数组展开、真实参数化、ROB 并行恢复和 store 同拍数据捕获均保留。另修复 ROB64 下 IFB 的半环恢复边界：恢复时直接清空所有尚未分派的年轻 IFB 项。最终没有引入分配回绕位、原始写回唤醒或额外 store 流水级。

**官方文件与已知问题**

README-EN.md、README-ZH.md、config.mk 与 upstream/main 一致；Makefile、scripts/、官方接口文档、Dockerfile、packaging/、测试子模块及 .gitmodules 未改变。未修改官方工具链、库、SRAM 成本模型或时序约束以取得结果。

[KI-001：部分基准门级/RTL 周期差异](known-issues.md) 已定位并修复。BP 的连续位切片在 Verilator/Yosys 中产生不同 PC 位连接，改为单次切片后，原有 RTL 六项计数不变，实际综合网表的 24 个官方用例（最终门级集不含 π）和 8 个延迟边界用例均与 RTL 周期一致。门级 5,307 项 ISA 自检在 LAT=1/10/50 均通过，三组周期也与 RTL 相同。此为已测程序的功能与周期检查，未宣称形式化等价。

**复现与审计**

```sh
make code BUILD=build/check/sim JOBS=4
make test SIM=./code MAX_CYCLES=20000000 LATENCY=10
make perf SIM=./code MAX_CYCLES=20000000 LATENCY=10 > build/check_perf.log
python3 tools/run_latency.py --sim ./code --log build/check_latency.log
python3 tools/run_isa.py --sim ./code --out build/check_isa
python3 tools/run_unit.py tb_lsq_recovery
python3 tools/run_unit.py tb_lsu
make synth SYNTH_OUT=build/check_synth
python3 tools/check_tier3.py --synth build/check_synth/opt \
  --perf-log build/check_perf.log --out build/check_audit.json
```

严格审计默认检查三项门槛及实际展开的 BP 恢复 PC 位连接，最终 `passed=true`、`tier3_passed=true`。不使用只检查面积/频率的阶段模式。源码哈希、原生 `opt` 及 SHARE、完整 IFB/IQ/写回 FIFO、SRAM 宏和地址驱动、无 ERROR/latch/端口 resize 均通过。当前 IFB 为 8×152 bits，IQ 指令存储为 8×104 bits，每个写回 FIFO 为 4×44 bits；D$ 有 32 个 `512x8` 宏，物理地址 9 位全部驱动，I$ 有两个 `256x32` 宏。

| 基准 | 动态指令 | 周期 |
| --- | ---: | ---: |
| perf_median | 6,961 | 8,201 |
| perf_multiply | 21,722 | 18,474 |
| perf_qsort | 139,900 | 159,846 |
| perf_rsort | 195,719 | 132,054 |
| perf_towers | 5,278 | 4,937 |
| perf_vvadd | 4,524 | 3,444 |

几何平均由整数指令/周期数重新计算，未使用四位小数 IPC 反算。

最终产物位于 `build/final_compliance/`（Git 忽略）：`rtl/` 为最终 RTL 回归，`synth/opt/` 为官方默认综合，`final_audit.json` 为严格审计，`units/` 为 14 个单测，`variants/` 为最终八参数变体，`build/cycle_audit/bp_matrix/` 为六配置下的 RTL/Yosys BP 测试，`gate/` 为实际网表模型，`after_cycles.json` 和 `after_latency_cycles.json` 为 24+8 个周期比较，`gate_isa/` 为门级 ISA 自检。`verification.json` 汇总源码/仿真器/网表 SHA256、全部结果与官方文件边界；根目录 `code` 由相同生产源生成。

八个最终参数变体分别通过官方正确性 19/19 和性能 6/6；默认最终版本完整执行 ISA、延迟、单测和门级比较。此前 IPC 优化与参数探索的历史记录保留在 `build/ipc_tier3/`。

```sh
python3 tools/run_configs.py --configs issue1 assoc2 rob16 rob64 iq4 prf128 decode1 cache_small \
  --benchmark-only --out build/configs --jobs 2 --parallel 2
```

省略 `--benchmark-only` 会补充每个变体的 ISA 和延迟矩阵；`--perf-only` 仅用于筛选，不提供正确性证据。

**历史结果边界**

面积/频率阶段的 28,683.281810 µm²、375.779817 MHz、IPC 0.896022346877662 保留在 `build/fix_tier3/`。该阶段没有达到完整 Tier 3，当前记录已取代它。先前依赖错误结构体数组展开或 keepdc 包装器的 PPA 已撤回，不能与有效 RTL 的 IPC 混用。

**综合语义回归与门级复现**

```sh
python3 tools/check_bp_recovery.py --out build/check_bp
python3 tools/build_gate.py --synth build/check_synth/opt --out build/check_gate --jobs 4
python3 tools/compare_cycles.py --rtl ./code --gate build/check_gate/sim/sim \
  --exclude-cases correctness_pi --out build/check_cycles.json --jobs 4
python3 tools/compare_cycles.py --rtl ./code --gate build/check_gate/sim/sim \
  --cases correctness_magic correctness_queens correctness_tak correctness_qsort \
  --latencies 1 50 --out build/check_latency_cycles.json --jobs 4
python3 tools/run_isa.py --sim build/check_gate/sim/sim --out build/check_gate_isa
```

BP 定向测试覆盖条件分支与间接跳转的历史恢复，默认、GHR=0/1/4/12 和 BHT128 六组配置在 RTL 与原生 Yosys 输出上均通过。旧版本原生展开的 32 项恢复检查失败，修复后的严格审计新增 `bp_recovery_pc_slice_correct`，会拒绝旧的错误位连接。
