# 验证与复现

Tier 3 需要同一份 RTL 同时满足：**面积 <36,000 µm²、频率 >300 MHz、LATENCY=10 的六项性能测试 IPC 几何平均 ≥1.0985**。频率来自课程 Yosys/ABC/ASAP7/OpenSTA 流程，采用理想时钟、无布线寄生模型；不是布局布线后的实测频率。

## 完整回归

在仓库根目录执行，工具链位置由 `config.mk` 设置。首次使用先运行 `git submodule update --init --recursive`，并安装课程 AppImage 或指定本机工具。

```sh
make build JOBS=8 BUILD=build/check
make test SIM=build/check/sim MAX_CYCLES=20000000 LATENCY=10 > build/check_test.log 2>&1
make perf SIM=build/check/sim MAX_CYCLES=20000000 LATENCY=10 > build/check_perf.log 2>&1
python3 tools/run_latency.py --sim build/check/sim --log build/check_latency.log
python3 tools/run_unit.py tb_lsu --jobs 8
python3 tools/run_unit.py tb_dcache_recovery --jobs 8
python3 tools/run_unit.py tb_axi_write --jobs 8
make synth MODE=opt SYNTH_OUT=build/synth_check
python3 tools/check_tier3.py --synth build/synth_check/opt \
  --perf-log build/check_perf.log --out build/check_audit.json
```

通过 `SIM=` 复用刚编译的仿真器。需要指定外部测试目录时，make 使用 `TESTCASES=/path/to/testcases`，延迟脚本使用 `--testcases /path/to/testcases`。Verilator 对象目录在每次构建时重建，避免旧 AppImage 挂载路径失效。

| 检查 | 验收内容 |
| --- | --- |
| `make test` | 官方正确性用例 19/19；`pi` 等长程序需要提高周期上限 |
| `make perf` | median、multiply、qsort、rsort、towers、vvadd 六项，LAT=10 |
| `run_latency.py` | magic、queens、tak、qsort ×LAT=1/50，共 8 项 |
| `tb_lsu` | load/store queue、D$、AXI 集成和访存定向检查 |
| `tb_dcache_recovery` | 返回与 flush 同拍时，背压跨越恢复后不得向复用的 ROB 号返回旧数据；较老 load 仍须完成 |
| `tb_axi_write` | 256 笔写、AW/W 独立停顿、payload 稳定、B tag 顺序、无背压每拍一笔 |
| `make synth` | 默认 `opt`，保留资源分享；检查时序与面积 |
| `check_tier3.py` | 三项门槛、报告输入 SHA256、D$ 宏数量/地址驱动及综合错误检查 |

审计工具从指令数/周期数重新计算完整精度 IPC，不使用表格里四位小数的 IPC。它检查综合与性能日志，正确性、延迟矩阵和协议测试仍须分别执行。性能日志应来自同一轮构建；不要将其他分支或不同队列配置的 IPC 与当前时序报告拼接。

## 综合口径与结构检查

`config.mk` 默认使用 [`tools/yosys_keepdc`](../tools/yosys_keepdc)。该包装器展开内置 `synth` pass 序列，在 `opt -full` 中加入 `-keepdc`，保留默认 `share`。此配置用于避免本工具版本对 D$ 的 don't-care 优化删除缓存或错误缩减 10-bit set 地址；不修改课程 `scripts/`。

即使 RTL 行为等价，信号名、表达式和模块组织变化也可能改变优化顺序及 ABC 映射。因此重构后必须重新综合，不直接沿用旧频率。正常报告应包含：

- 32 个 `fakeram_asap7_1024x8` D$ 宏，所有 `addr_in` 均为 10 位、无常量/未驱动地址位；另有两个 `fakeram_asap7_512x32` I$ 宏。
- 无综合 ERROR、推断 latch 或 SRAM 端口 resize。
- 输入 SHA256 与当前 RTL 一致。
- 面积包含 logic 和 SRAM；最小周期及关键路径可在 `report.json`、`timing.rpt` 中检查。

`check_tier3.py` 针对当前 32 KiB D$ 配置检查 32 个宏；若正式改变容量，需要同时更新结构预期及重新验证指标。

## 当前验证结果（频率裕量优化）

2026-10-23，以 `8f2de41` 为基线，保持队列参数、双发射/双提交、缓存容量和全部流水线延迟。使用默认 `MODE=opt`、资源分享和 `CLOCK_PERIOD_NS=2.0` 重新综合。

| 指标 | 优化前 | 当前版本 | 目标 |
| --- | ---: | ---: | --- |
| 面积 / µm² | 28,778.756 | **28,659.579** | <36,000 |
| 综合频率 / MHz | 303.858 | **333.225** | 本轮约 330；Tier 3 >300 |
| 最小周期 / ns | 3.291015625 | **3.0009765625** | <3.333333333 |
| IPC 几何平均 | 1.102294 | **1.102294** | ≥1.0985 |
| 正确性 / LAT=1/50 | 19/19、8/8 | **19/19、8/8** | 全部通过 |

频率提高约 9.66%，相对 300 MHz 门槛的余量约 11.07%。六项性能基准的指令数和周期数与 `8f2de41` 完全一致；完整精度 IPC 为 `1.1022941378197337`。

实现集中在两处：响应 payload 的选择/字节提取提前完成，晚到的 hit/replay 只限定有效性；写回调度资格在最终 BB 选择前完成，LSU 直接使用其在飞队列身份。PRF 写入、ROB 完成和回收保留原有完整检查，仿真断言持续验证 LSU 身份前提。

同时修复 FIFO 入队与 flush 同拍的 kill 标记遗漏。新增定向测试在原版本复现了 `token=4` 的旧数据返回到复用 ROB 号的问题；本版验证被杀死响应丢弃、较老 load 保留。LSU、后端连接和新恢复测试均通过。

结构审计通过：32 个 D$ SRAM 宏、10 位地址完整驱动、无 ERROR/latch/端口 resize，报告输入 SHA256 匹配当前 RTL。

| 本轮产物 | 路径 |
| --- | --- |
| 仿真器 / 构建日志 | `build/sim_freq330_verified/sim`、`build/build_freq330_verified.log` |
| 正确性 / IPC | `build/test_freq330_verified.log`、`build/perf_freq330_verified.log` |
| 延迟矩阵 | `build/latency_freq330_verified.log`、`build/latency_freq330_verified_summary.log` |
| LSU / 恢复边界 | `build/lsu_freq330_verified.log`、`build/recovery_freq330_verified.log` |
| 后端连接 | `build/be_freq330_final.log` |
| 综合 | `build/synth_freq330_verified/opt/{report.json,report.txt,timing.rpt,design.json,mapped.v}` |
| 审计 / 汇总 | `build/audit_freq330_verified.json`、`build/verification_freq330.json` |
| 冻结 RTL | `build/rtl_freq330_verified/` |

## 历史基线（可读性重构）

重构前基线为 `9fcb1d7`（`tier3-throughput`）：28,456.713 µm²、310.491 MHz、IPC 1.102294；正确性 19/19、延迟回归 8/8、AXI 定向检查通过。

2026-10-23，`refactor-readability` 工作目录重新构建和综合，结果如下。发射策略、队列深度和流水线延迟保持原配置。

| 指标 | 重构前 `9fcb1d7` | 重构版 | 门槛 |
| --- | ---: | ---: | --- |
| 面积 / µm² | 28,456.713 | **28,778.756** | <36,000 |
| 综合频率 / MHz | 310.491 | **303.858** | >300 |
| 最小周期 / ns | 3.220703125 | **3.291015625** | <3.333333333 |
| IPC 几何平均 | 1.102294 | **1.102294** | ≥1.0985 |
| 正确性 | 19/19 | **19/19** | 全部通过 |
| LAT=1/50 矩阵 | 8/8 | **8/8** | 全部通过 |

LSU、后端连接、默认桩连接和 256 笔 AXI 写通道定向测试通过。综合结构审计通过：D$ 宏 32 个、地址均为 10 位且全部有驱动，输入 SHA256 匹配，无 ERROR、latch 或端口 resize。

本轮本地产物（`build/` 不纳入 Git）：

| 产物 | 路径 |
| --- | --- |
| 仿真器及构建日志 | `build/readable_final_sim/sim`、`build/readable_final_build.log` |
| 正确性 / IPC | `build/readable_final_test.log`、`build/readable_final_perf.log` |
| 延迟矩阵 | `build/readable_final_latency.log`、`build/readable_final_latency_summary.log` |
| LSU / 后端连接 | `build/readable_final_lsu.log`、`build/readable_final_be_link.log` |
| AXI / 默认桩连接 | `build/readable_axi.log`、`build/readable_stub_link.log` |
| 综合报告 | `build/synth_readable_final/opt/{report.json,report.txt,timing.rpt,design.json,mapped.v}` |
| 自动门槛审计 | `build/readable_final_audit.json` |
| 验证汇总 / RTL 快照 | `build/readable_final_verification.json`、`build/rtl_readable_final/` |

两版一致的六项计数如下，IPC 几何平均完整精度为 `1.1022941378197337`。

| 基准 | 指令数 | 周期数 | IPC |
| --- | ---: | ---: | ---: |
| perf_median | 6961 | 8164 | 0.852646 |
| perf_multiply | 21722 | 17867 | 1.215761 |
| perf_qsort | 139900 | 142686 | 0.980475 |
| perf_rsort | 195719 | 124758 | 1.568789 |
| perf_towers | 5278 | 5086 | 1.037751 |
| perf_vvadd | 4524 | 4173 | 1.084112 |
