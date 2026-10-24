**历史审查：以下结论针对修复前的 `f31e1f6`。** 修复后的实现、正式综合和回归记录见 [validation.md](validation.md)。

后续已确认原先的 `-keepdc` 综合仍存在结构体数组展开错误。本文和旧验证记录中的 28,660 µm² / 333 MHz 数字不能作为有效硬件达标证据；修复后的官方流程结果以新验证记录为准。

**修复前验收结论：CPU 尚未完全符合官方要求。** 已确认 `SRA/SRAI` 功能错误，以及发射宽度和缓存相联度未真正参数化。官方测试全部通过、本地综合数值达到 Tier 3，不能抵消这些缺口。

检查日期：2026-10-24。受检提交：`f31e1f664ee917720bf1daa51166bd7045a99ce8`。本次只新增审查报告，未修改受检 RTL、工具配置或官方测试框架。

**要求来源与上游同步**

唯一验收依据为官方上游 [README-EN.md（302f0cf）](https://github.com/ACMClassCourse-2025/RISC-V-CPU-2026/blob/302f0cf3cccdaa5de084a2120e0d950c663e4cf5/README-EN.md)。本仓库的 README-EN.md 已被改写为实现介绍，不能将其中的达标声明作为验收证据；官方原文允许替换项目 README，因此这一文档调整本身不是违规。以下架构、验证文档只用于定位实现和历史记录，不引入额外要求。

执行 `git fetch upstream --prune` 并查询远端默认分支后：

| 项目 | 检查结果 |
| --- | --- |
| 上游 | `ACMClassCourse-2025/RISC-V-CPU-2026`，默认分支 `main` |
| 上游最新提交 | `302f0cf3cccdaa5de084a2120e0d950c663e4cf5`，2026-10-14，ABC buffering/cell sizing 配置 |
| `HEAD...upstream/main` | 本地独有 15，上游独有 0；无需合并 |
| 官方 testcase 子模块 | 已 fetch；当前与 `origin/main` 均为 `29f980727f7d99a1842a58f34091c7579ba3fe85`，无需更新 |
| `scripts/`、Makefile | 与上游一致 |

没有新上游提交需要拉取合并，未创建无内容的合并提交。官方 README 快照及源码、仿真器 SHA256 保存在 `build/compliance_20261024/manifest.json` 和 `upstream-README-EN.md`。

**逐项检查**

| 官方 README 条款 | 结论 | 证据与边界 |
| --- | --- | --- |
| 完整 RV32I（排除明确豁免的指令） | **不符合** | 负数算术右移错误，见下方最小复现 |
| 全部 8 条 M 扩展指令 | 本次检查通过 | 官方用例、mul/div 单测、补充边界/随机操作数检查；包含除零、符号溢出与高位乘法 |
| LB/LBU/LH/LHU/LW、SB/SH/SW，自然对齐 | 本次检查通过 | LSU 单测及补充各字节/半字 lane、符号扩展检查；未把非对齐访问列为要求 |
| OoO 执行 | 实现满足架构要求 | IQ 按操作数就绪及功能单元可用性选取条目，支持年轻就绪指令越过等待中的老指令；`backend/iq.sv` |
| 按序提交 | 实现满足架构要求 | ROB 只提交完成的队首及连续下一项，store 退休后才允许外部写；`backend/rob.sv:134`、`memory/load_store_queue.sv` |
| ROB、PRF、IQ 容量参数化 | 有实际参数化实现 | 数组和 tag 位宽依赖对应参数；本次动态回归只覆盖默认配置，不宣称所有取值均有效 |
| 发射宽度参数化 | **不符合** | `ISSUE_WIDTH` 仅声明，实际端口和选择器固定双路 |
| 缓存容量参数化 | 有实际参数化实现 | `IC_LINES/DC_LINES/LINE_BYTES` 参与数组、地址和 SRAM 实例；支持范围有限 |
| 缓存相联度参数化 | **不符合** | `ASSOC` 仅声明；I$/D$ 都只有每 set 一份 tag 和 valid，无多 way 选择/替换 |
| 退出 MMIO、32 位 WDATA、WSTRB=4'hf | 本次检查通过 | 官方仿真框架通过该约定获取结果；正确性、性能、补充程序均通过此路径退出 |
| RAM 为 256 MiB、小端、未加载字节为零 | 本次检查通过 | 补充检查覆盖 `0x0fffffc0` 附近的自然对齐访问和未初始化字；容量由官方仿真从机提供 |
| `student_top` 端口与 filelist | 符合 | 端口名称、方向和宽度匹配；正式 filelist 可直接构建 |
| AXI 地址 4 字节对齐、独立握手 | 本次检查通过 | LSU 对齐断言、256 笔写通道背压测试、LAT=1/10/50 回归；非形式化协议证明 |
| 同步 SRAM 使用 `sram_fakeram` | 符合 | I$/D$ 通过框架宏实例化；本地综合包含 32 个 D$ 宏及 2 个 I$ 宏 |
| 不修改官方 scripts | 符合 | `git diff upstream/main -- scripts Makefile` 为空 |
| Tier 3 面积、IPC、频率 | **本地配置下数值通过** | 新运行结果见下表；原始 Yosys 流程结构异常须另行解决 |
| 最终报告中的参数敏感性分析 | **仓库内材料不足** | 现有架构/验证文档没有不同参数配置对应 IPC 的实验结果；同参数版本的频率对比不等于参数敏感性分析 |
| 架构探索与设计取舍 | 有材料，最终报告完整性未确认 | architecture/validation 中有设计和优化说明；提交报告、团队人数、答辩及 LLM 交互日志的外部提交状态无法由代码仓库确认 |

**P1：SRA / SRAI 对负数的算术右移错误**

位置：[`verilog/backend/alu.sv:31`](../verilog/backend/alu.sv)。

```systemverilog
3'b101: r = in_funct7[5] ? (sa >>> shamt) : (in_a >> shamt);
```

条件表达式混用 signed 的 `sa` 与 unsigned 的 `in_a`，使算术右移分支受到 unsigned 表达式上下文影响，生成逻辑右移。两个独立最小程序均在新构建的正式 CPU 仿真器上失败，错误不依赖完整审查程序的汇编器或大规模控制流。

```asm
lui  x5, 0x80000       # x5 = 0x80000000
addi x6, x0, 1
sra  x7, x5, x6       # 另一个程序将此行替换成 srai x7,x5,1
lui  x30, 0x80000
sw   x7, 0(x30)       # 将实际结果写入退出 MMIO
jal  x0, 0
```

| 指令 | 预期结果 | 实际结果 | LAT=10 周期数 |
| --- | --- | --- | ---: |
| SRA | `0xc0000000` | `0x40000000` | 46 |
| SRAI | `0xc0000000` | `0x40000000` | 46 |

复现记录和逐条机器码：`build/compliance_20261024/shift_repro.json`。可直接重新执行：

```sh
build/compliance_20261024/sim/sim build/compliance_20261024/sra_minimal.bin 3221225472 10000 10
build/compliance_20261024/sim/sim build/compliance_20261024/srai_minimal.bin 3221225472 10000 10
```

补充完整 RV32IM 自检程序在 LAT=1/10/50 均首先失败于第 998 项：`SRA a=80000000 b=00000001`。排除已知失败的 SRA/SRAI 后，其余 4,898 项检查在三个延迟下全部通过；这不能证明未运行到的完整配置无其他错误，也不构成形式化 ISA 验证。测试生成器及结果保存在同目录的 `isa_audit.py`、`isa_results.json`、`remaining_results.json` 中。

修复方向：将两种移位放入独立的 if/else 赋值，或在移位表达式边界明确控制 signedness；修复后必须重新构建、回归和综合，不能直接沿用本次性能数字。

**P1：ISSUE_WIDTH 和 ASSOC 不是有效配置项**

[`cpu_pkg.sv:7`](../verilog/cpu_pkg.sv) 声明 `ISSUE_WIDTH=2`，[`cpu_pkg.sv:24`](../verilog/cpu_pkg.sv) 声明 `ASSOC=1`。对整个生产 RTL 搜索，二者均只有声明，没有消费该参数的逻辑。`DECODE_WIDTH` 同样未使用。

IQ 的 `iss0/iss1`、双路 payload 和 ROB 双提交逻辑均固定存在；改变 `ISSUE_WIDTH` 不改变发射宽度。I$/D$ 的 tag 和数据地址只依赖 set 和 line offset，改变 `ASSOC` 不会增加 way。仅保留参数名不满足官方 README 的参数化条款。现有 [`architecture.md:117`](architecture.md) 也明确记录了固定双路和直接映射的限制。

需要让支持的至少多个宽度/相联度取值实际影响硬件，并在相应配置下验证功能和 IPC；支持范围应明确约束，不要求任意整数都合法。

**P2：最终报告尚缺可审查的参数敏感性实验**

官方要求最终报告说明 IPC 如何随参数配置改变。仓库现有表格比较的是保持队列参数和缓存容量不变时的版本优化。没有找到包含实际参数值、六项 benchmark IPC 和几何平均的配置对比表。架构探索已有部分说明，但无法确认是否另有未纳入仓库的最终报告和交互日志。

**本次重新运行的验证结果**

| 检查 | 结果 |
| --- | --- |
| 正式 RTL 从零构建 | 通过，AppImage Verilator，启用 assertions |
| 官方正确性 LAT=10 | 19/19，周期上限 20,000,000 |
| 官方性能 LAT=10 | 6/6，完整精度 IPC 几何平均 `1.1022941378197337` |
| magic/queens/tak/qsort × LAT=1/50 | 8/8 |
| 仓库全部 8 个 tb | 8/8；检查退出状态及日志错误，未仅依赖 `$finish` 返回码 |
| 补充完整指令自检 | 三个延迟均失败于 SRA，见上文 |
| 排除 SRA/SRAI 后的补充自检 | 4,898 检查 × LAT=1/10/50，全部通过 |
| 默认本地综合与输入 hash / SRAM 结构审计 | 通过 |

| 基准 | 指令数 | 周期数 |
| --- | ---: | ---: |
| perf_median | 6,961 | 8,164 |
| perf_multiply | 21,722 | 17,867 |
| perf_qsort | 139,900 | 142,686 |
| perf_rsort | 195,719 | 124,758 |
| perf_towers | 5,278 | 5,086 |
| perf_vvadd | 4,524 | 4,173 |

本地默认配置 `config.mk:19` 使用 `tools/yosys_keepdc`，其会展开 Yosys synth pass 并添加 `-keepdc`。本次从当前源码重新运行：

| 项目 | 数值 | Tier 3 |
| --- | ---: | --- |
| 总面积（含 SRAM） | 28,659.578832 µm² | 满足 36,000 门槛 |
| Fmax | 333.224862 MHz | 满足 300 门槛 |
| 最小周期 | 3.0009765625 ns | — |
| IPC 几何平均 | 1.1022941378197337 | 满足 1.0985 门槛 |
| 频率加分 | 未达到 400 MHz | 无额外加分 |

这些数值描述当前本地流程。`CLOCK_PERIOD_NS=2.0` 只是优化目标；报告的负 slack 表示未达到 500 MHz 目标，不影响其已超过 300 MHz 门槛的数值事实。

另执行 `make synth YOSYS= ...` 直接使用 AppImage 原始 Yosys，得到面积 `3,971.473028 µm²`、Fmax `614.277145 MHz`，但 **D$ 宏为 0，结构审计失败**，仅保留两个 I$ 宏。没有完成该网表与 RTL 的等价性验证，不能把这个异常的更小面积/更高频率当作有效达标或加分证据。README 允许配置工具路径，本次不据此断言包装器违反规则；但应解决原始流程的结构异常，并验证最终评测配置与功能 RTL 一致。其根因是否完全属于工具缺陷，本次未独立证明。

**复查入口**

详细日志和机器可读结果均在 `build/compliance_20261024/`（Git 忽略的本地构建产物）：`correctness.log`、`perf.log`、`latency.log`、`units.json`、`shift_repro.json`、`audit.json`、`audit_official.json`、两份 synth 目录与 `manifest.json`。

```sh
make build JOBS=8 BUILD=build/compliance_20261024/sim
make test SIM=build/compliance_20261024/sim/sim MAX_CYCLES=20000000 LATENCY=10
make perf SIM=build/compliance_20261024/sim/sim MAX_CYCLES=20000000 LATENCY=10
python3 tools/run_latency.py --sim build/compliance_20261024/sim/sim
python3 build/compliance_20261024/isa_audit.py
python3 build/compliance_20261024/isa_audit.py --exclude SRA SRAI --tag remaining
make synth MODE=opt SYNTH_OUT=build/compliance_20261024/synth
make synth YOSYS= MODE=opt SYNTH_OUT=build/compliance_20261024/synth_official
```
