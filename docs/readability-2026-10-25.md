**逻辑简化与可读性复查（2026-10-25）**

本轮保留两个局部改动，生产 RTL 共减少 24 行、非空非注释代码减少 23 行。默认参数、发射策略、流水线时序和官方框架保持原有配置。改动前工作区及源码副本保存在 `build/readability_20261025/baseline/`。

| 指标 | 简化前 | 简化后 | 用户标准 |
| --- | ---: | ---: | ---: |
| 总面积，含 SRAM，µm² | 29616.839210 | 29824.822910 | <36000 |
| OpenSTA 估算频率，MHz | 352.132050 | 346.414073 | >330 |
| 六项性能 IPC 几何平均 | 1.101955112159 | 1.101955112159 | >1.1 |

新结果来自同一组冻结 RTL 的官方 opt 综合、默认 2 ns 目标、默认驱动/负载和 LATENCY=10 性能测试。严格按用户的三个不等式验收，而非只检查官方 Tier 3。面积增加约 208 µm²，频率下降约 5.72 MHz；这轮收益是代码表达更直接，没有性能周期收益，也没有面积收益。

**rename：直接使用已有的空闲位图**

原先先统计全部空闲 tag 的数量，再把两路目的寄存器需求相加，检查数量是否足够；第二路还同时检查分配第一路后的剩余位图。现在只保留每路真正需要的判断：

- slot0 没有目的寄存器，或原位图非空。
- slot1 没有目的寄存器，或扣除 slot0 分配后的位图非空。
- slot1 仍依赖 slot0 成功分派，保持前缀接受。

两路都需要 tag 时，slot0 的最低有效位被扣除，slot1 必须再找到另一个 tag；slot0 不需要 tag 时，剩余位图等于原位图。这样覆盖需求为 0、1、2 的情况，无需全量计数。`free_q` 的寄存边界及 pending 隔离规则保留。`rename.sv` 从 200 行减为 191 行。

**memory_subsystem：删除不可达的 store 完成缓冲**

旧 `sp_v` 复位时为零，随后只有 `wr_rsp_valid && sp_v` 才能写入一，因此从复位后始终为零，`sp_rob` 及对应响应分支均不可达。

响应仲裁直接写成 B/store 完成优先，其次是 D$ load。AXI 每拍最多给一条 B，LSQ 每拍可接收一条完成；同拍到达的 load 响应留在 D$ FIFO 等待。用于已接受 store 身份及 cache 命中信息的 `tw_*`、`tagrob/tagaddr/tagmiss` 保留，它们承担真实流水线职责。`memory_subsystem.sv` 从 192 行减为 177 行。

**验证及证明范围**

- 官方正确性 19/19，含 π；MAX_CYCLES=20000000。
- 官方性能 6/6，LATENCY=10；与基线合计 25 个官方用例逐项比较，结果和周期完全一致。
- ISA 自检 5307 项 × LATENCY=1/10/50；8 项延迟边界测试。
- 8 个相关单测：后端联调、LSU 集成、ROB 恢复、发射宽度、LSQ 恢复、AXI 写、cache 相联度和 D$ 恢复。
- 新种子 202610264–202610287 的随机混合流 × 三种延迟，共 72/72。
- rename 模块通过 Yosys 等价检查：默认、PRF128、DECODE_WIDTH=1。
- memory_subsystem 在 ROB16/32/64 下通过复位后的归纳等价检查；D$ 为未修改的共同边界，将其输出视为两边共有的任意输入，并验证向 D$ 发出的控制及外部响应相同。该检查包含旧 sp_v 恒零的不变式。
- 新综合通过 payload 完整展开、SRAM 宏数量/地址驱动、BP 恢复连接和源码哈希审计。

模块证明没有覆盖完整 CPU；本轮未重跑门级仿真或八组完整参数变体。报告中的八变体敏感性表和旧门级记录属于简化前版本，已标明来源。π 超过默认百万周期上限的运行限制保留。

**保留的展开写法**

ALU/BRU 结果寄存器、IQ 年龄选择和 SRAM bank 控制继续保持现有表达。历史探索表明，压缩这些代码可能改变综合映射和关键路径；本轮的两个局部改动已达到可读性目标和全部数值标准，不将更广的重构混入本次结果。

**证据与复现**

`build/readability_20261025/candidate/verification.json` 汇总当前源码哈希、严格门槛、回归、周期比较及证明范围。新综合报告位于 `candidate/synth/opt/report.json`，两处修改的独立补丁为 `candidate/change.patch`，等价检查脚本及日志位于 `equivalence/`。

```sh
make build BUILD=build/readability_check/sim JOBS=4
make test SIM=build/readability_check/sim/sim MAX_CYCLES=20000000 LATENCY=10
make perf SIM=build/readability_check/sim/sim LATENCY=10 > build/readability_check/perf.log
python3 tools/run_isa.py --sim build/readability_check/sim/sim --out build/readability_check/isa
python3 tools/run_latency.py --sim build/readability_check/sim/sim --log build/readability_check/latency.log
make synth SYNTH_OUT=build/readability_check/synth
python3 tools/check_tier3.py --synth build/readability_check/synth/opt --perf-log build/readability_check/perf.log
```

`check_tier3.py` 使用官方 300 MHz/1.0985 门槛；本轮 `verification.json` 另行检查用户更严格的 >330 MHz 和 >1.1。没有修改官方文件或放宽验收数值。
