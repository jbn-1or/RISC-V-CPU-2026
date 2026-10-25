**最新验证（2026-10-25）：局部逻辑简化后，用户三项标准全部通过。**

| 指标 | 简化前基线 | 当前实测 | 用户标准 |
| --- | ---: | ---: | ---: |
| 总面积，含 SRAM，µm² | 29616.839210 | 29824.822910 | <36000 |
| 频率，MHz | 352.132050 | 346.414073 | >330 |
| IPC 几何平均 | 1.101955112159 | 1.101955112159 | >1.1 |

本轮只修改 `rename.sv` 和 `memory_subsystem.sv`，共减少 24 行：以两路已有的空闲位图代替全量 tag 计数，删除不可达的 store 完成缓冲。25 个官方用例的结果及周期与基线逐项一致。面积和频率使用同一份新 RTL 的官方默认 opt 综合及 OpenSTA 流程，未更改库、时钟目标、负载、SRAM 模型或官方测试。

本轮重新通过官方正确性 19/19（含 π）、性能 6/6、ISA 自检 5307 项 × 延迟 1/10/50、8 项延迟边界、8 个相关单测，以及种子 202610264–202610287 × 三个延迟的 72 组随机混合流。rename 在默认、PRF128、DECODE_WIDTH=1 下通过模块等价；memory_subsystem 在 ROB16/32/64 下通过复位后的归纳等价检查，未修改的 D$ 作为共同的无约束接口边界。没有对整个 CPU 作形式化证明，也没有重跑本轮网表仿真或八组完整参数变体。

当前证据：`build/readability_20261025/candidate/verification.json`、`audit.json`、`baseline_cycles.json`、`synth/opt/report.json`；等价脚本和日志见 `build/readability_20261025/equivalence/`。逐项改动与复现命令见 [readability-2026-10-25.md](readability-2026-10-25.md)。π 的百万周期默认上限限制仍然存在，完整正确性测试使用 `MAX_CYCLES=20000000`。

---

以下保留简化前频率优化阶段的历史记录；其中的“当前”及门级/参数变体结果均指该历史版本。

**2026-10-25：频率优化完成，默认配置同时满足 Tier 3。** 唯一要求来源为 [README-EN.md](../README-EN.md)。仅将 rename 的分配候选改为寄存后的 free_q；本拍提交/回收释放的 tag 下一拍参与分配。默认参数、发射策略、同拍写回旁路和恢复协议保持原样。

| 指标 | 优化前 | 当前实测 | Tier 3 门槛 |
| --- | ---: | ---: | ---: |
| 总面积，含 SRAM，µm² | 29906.208470 | 29616.839210 | ≤36000 |
| 频率，MHz | 300.205218 | 352.132050 | ≥300 |
| IPC 几何平均 | 1.101955112159 | 1.101955112159 | ≥1.0985 |

用户目标为约 330 MHz；当前实测约 352 MHz，较 300 MHz 门槛高约 52.132 MHz。频率较原版提升约 17.30%，面积减少约 289.369 µm²。25 个官方用例周期均与优化前一致。面积、频率和 IPC 均来自同一组生产源码，没有组合不同配置的指标。综合使用官方默认 opt 流程、2 ns 目标、驱动、负载和 SRAM 成本模型。

本次验证全部通过：

- 官方正确性 19/19（包含 π），LATENCY=10 官方性能 6/6。
- 5,307 项 ISA 检查 × LATENCY=1/10/50；8 项延迟边界测试。
- 14/14 单测；24 个种子的随机混合流 × 三个延迟，共 72/72。
- 八个参数变体各通过官方正确性 19/19 和性能 6/6；快照逐文件核对为当前 RTL 加声明的参数变化。
- 实际综合网表通过 24 个官方用例及 8 个延迟边界比较，功能和周期均与 RTL 一致；门级 ISA 三组结果也与 RTL 相同。门级集不含 π；完整 π 在 RTL 中通过。
- 严格审计通过：当前源码哈希、opt/SHARE、IFB/IQ/写回 FIFO 完整展开、BP 恢复 PC 连接、SRAM 宏和地址驱动。D$ 保留 32 个 512×8 宏及 9 位 row 地址。

**实现与复现**

`verilog/backend/rename.sv` 不再把组合 rel_msk 直接并入当前分配候选，切断提交/回收到 free-tag 优先选择器的同拍依赖。free_q 的更新、pending tag 隔离和回收规则保留；代价是刚释放的 tag 最早下一拍可用。默认官方测试中未观察到性能周期增加；其他配置的 IPC 见 [report.md](report.md)。

```sh
make code BUILD=build/check/rtl JOBS=4
make test SIM=./code MAX_CYCLES=20000000 LATENCY=10
make perf SIM=./code MAX_CYCLES=20000000 LATENCY=10 > build/check_perf.log
python3 tools/run_isa.py --sim ./code --out build/check/isa
python3 tools/run_latency.py --sim ./code --log build/check/latency.log
make synth SYNTH_OUT=build/check/synth
python3 tools/check_tier3.py --synth build/check/synth/opt --perf-log build/check_perf.log
python3 tools/run_configs.py --configs issue1 assoc2 rob16 rob64 iq4 prf128 decode1 cache_small --benchmark-only --out build/check/variants
python3 tools/build_gate.py --synth build/check/synth/opt --out build/check/gate
python3 tools/compare_cycles.py --rtl ./code --gate build/check/gate/sim/sim --exclude-cases correctness_pi --jobs 3 --out build/check/gate_cycles.json
```

π 实测需要 10,100,155 周期；一百万是框架默认上限，完整测试应提高 MAX_CYCLES。README 未将该默认值定义为独立评分门槛。

**证据与边界**

本次产物位于 `build/freq330_20261025/registered_free/`。`verification.json` 汇总生产源、RTL/门级模拟器哈希、三项门槛、参数变体和回归结果；`baseline_comparison.json` 保留 25 个官方用例的前后周期比较。当前 verilog/ 与综合冻结副本逐字节一致，根目录 code 与正式 RTL 模拟器 SHA256 一致。

此前简化后的 300.205 MHz 基线保留在 `build/simplify_verified_20261025/bht128/`。IQ 年龄矩阵候选实测仅 301.354 MHz，未采用；其余未完成的探索已停止，不作为当前指标。生产 RTL 本轮只改 rename 一行。框架、官方测试、README、SRAM 模型、库与约束没有修改。

这些是代码审查和有限仿真结果，不是形式化等价证明。团队、提交时间和完整历史 LLM 日志的提交状态仍不能从 RTL 确认。
