**KI-001：部分性能基准的门级周期数与 RTL 不一致**

状态：已修复并完成回归；用户在后续指令中授权继续检查和修正此问题。

发现版本：面积/频率阶段基线，ROB16 / PRF64 / IQ4 / LDQ4 / STQ8，WB_BYPASS=0、EARLY_REDIRECT=0，I$ 2 KiB / D$ 16 KiB。

| 用例 | RTL 周期 | 门级周期 |
| --- | ---: | ---: |
| perf_median | 9,378 | 9,826 |
| perf_multiply | 23,376 | 23,456 |
| perf_qsort | 168,665 | 169,347 |
| perf_rsort | 178,773 | 178,777 |
| perf_towers | 5,944 | 5,947 |
| perf_vvadd | 4,862 | 4,862 |

当时这些用例的输出结果均正确，门级 LAT=10 的 5,115 项 ISA 自检也通过，但周期比较没有通过，原因尚未确定。本轮已定位并修复，见下文；这些历史检查不构成形式化等价证明。

原始证据：build/fix_tier3/gate/comparison.json、gate/isa/isa_results.json、gate/manifest.json 与 verification.json。该记录保留历史配置的具体计数，不将其自动归因于后续配置。

根因：`verilog/frontend/bp.sv` 的 `up_pc[BHI+1:2][GH-1:0]` 连续位切片在原生 Yosys 中展开成 PC `[GH-1:0]`，而 RTL 仿真使用预期的 `[GH+1:2]`。默认配置即 `[7:0]` 与 `[9:2]` 的差别，导致误预测恢复时重建的 GHR 不同，继而改变预测与周期数。程序最终结果仍可由分支恢复机制保证。

修复：直接使用单次切片 `up_pc[GH+1:2]`，不改变 RTL 原有行为。新增 BP 恢复测试同时覆盖条件分支和间接跳转，并让测试失败返回非零。修复前 RTL 测试通过，Yosys 展开版本出现 32 项失败；修复后两者通过。

历史复现：从与原综合输入逐文件匹配的 ROB16 冻结源复制出诊断版本，仅显式模拟 Yosys 的错误 PC 位连接，六项周期数逐项等于上表的历史门级计数。证据为 `build/cycle_audit/historical_native_semantics/perf.log`。

修复前 ROB32 / WB_BYPASS=1 当前配置也复现了五项差异，记录在 `build/cycle_audit/before_cycles.json`。修复后 24 个官方用例（最终门级集不含 π）、8 个延迟边界用例以及三组 ISA 自检的周期和功能结果均与 RTL 一致；不将这些回归表述为形式化等价证明。

**当前 ROB32 配置修复前后**

| 基准 | RTL 周期 | 修复前门级 | 修复后门级 |
| --- | ---: | ---: | ---: |
| perf_median | 8201 | 8649 | 8201 |
| perf_multiply | 18474 | 18428 | 18474 |
| perf_qsort | 159846 | 161397 | 159846 |
| perf_rsort | 132054 | 132045 | 132054 |
| perf_towers | 4937 | 4856 | 4937 |
| perf_vvadd | 3444 | 3444 | 3444 |

最终总面积 30186.042410 µm²、频率 300.822562 MHz、IPC 1.104759628915139，同一份修复后生产 RTL 同时通过 Tier 3。严格审计新增实际 PC 位连接检查。完整证据为 `build/final_compliance/verification.json`，复现命令见 [validation.md](validation.md)。

**KI-002：ROB64 下 IFB 半环年龄恢复边界**

状态：已修复并完成定向及联合回归。原实现用 6 位分支序号差不超过 32 识别年轻 IFB 项；ROB64 可出现大于 32 的合法距离，导致部分队列保留错误路径项。`tb_ifb_recovery` 在旧逻辑的 ROB64、单项队列、距离 40 情况复现失败。

取指与分派按序，触发恢复的分支已进入后端，因此 IFB 内所有指令都更年轻。现在恢复直接清空 IFB，移除半环扫描和冗余影子数组。ROB16/32/64 的部分、满、物理回绕和序号回绕队列测试全部通过，默认六项性能计数不变。证据位于 `build/cycle_audit/ifb_before/` 及 `build/final_compliance/{units,ifb_rob16.log,ifb_rob64.log}`。
