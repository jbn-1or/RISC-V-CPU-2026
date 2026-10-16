# 实现计划（Per `docs/design.md` v1.0）

> 本计划把 `docs/design.md`（设计蓝本）落成可执行的开发排程：阶段目标、文件级任务、
> 谁先做什么（A/A=前端+访存，B=乱序核心）、每步验收命令、接口冻结点与集成顺序。
> 原则：**先打通端到端，再层层加厚**；每一步都有可运行的产物与固定的验证命令。

---

## 1. 总则与工程纪律

| # | 纪律 | 内容 |
| --- | --- | --- |
| D1 | 时序仿真口径 | 本地一律 `MAX_CYCLES=20000000`（pi 类正确性大程序必需；`LATENCY` 默认 10） |
| D2 | 契约改动 | `verilog/cpu_pkg.sv` 一切改动 = PR 双审；字段只增不删（见 P0） |
| D3 | 丢弃代码 | 标注"（丢弃型）"的临时实现不得遗留到下一里程碑主干（M1 的 `core_seq.sv`、无 cache 取指） |
| D4 | stub 纪律 | `verilog/stubs/` 内容永不进 `verilog/filelist.f`；`run_ut.sh` 一键 UT；`$fatal` 只出现在 stub/UT |
| D5 | 可综合纪律 | 每个进入 filelist 的文件当天必须过 `make build`（Verilator）+ 冒烟 `make synth MODE=opt`；lint 用 AppImage Verilator `--lint-only -Wall` 清警报 |
| D6 | 留档 | 每个里程碑结束把 `build/synth/*/report.json` 拷贝到 `references/synth-history/<date>-<tag>.json`（`build/` 被 gitignore，需手动留档供报告做图） |
| D7 | 回归频率 | 每个开发日收尾：全量 UT + `make test` 抽样 + 主干编译；里程碑切换点跑全量 |
| D8 | `scripts/` 只读 | 永不修改 `scripts/`；`packaging/` 维持原样 |
| D9 | 分支模型 | `main` 保持绿（能 build + 通过该阶段的 correctness 抽样）；功能分支合入前必须 UT 绿 + 主干 regression |

---

## 2. 实现顺序总览与依赖

```text
P0 契约冻结 ──► M1 端到端顺序通路 ──► M2 乱序核心 ──► M3 访存子系统 ──► M4 IPC 调优 ──► M5 综合/频率/档位固化
                     │                      │                │
              axi_master(终版)          rename/rob/iq     icache/dcache/lsu(终版)
              decode(终版)              mul/div/bru       flush 跨 A/B 全链
              lsu 阻塞版(丢弃)          prf(终版)         STQ drain + B 窄带
              顺序核(丢弃)
```

排序依据（关键路径）：
- **A 线**：`axi_master` 与退出协议是所有东西的地基 → M1 先做；
  M2 期间 A 并行做 I$ 取指/IFB/BP（不需要 B 的接口就能跑）；M3 合流 dcache+LSU。
- **B 线**：rename→rob→iq 是 OoO 三件套，顺序上 rename/ROB 先行（flush 机制依赖 ROB 表项结构）；
  mul/div 依赖 ROB 与 WB 总线成形。
- **合流点**：M2 末 `tb_be_link`/`tb_flush` 双绿；M3 中 `student_top` 最终互连。

---

## 3. 阶段 P0：契约冻结与骨架（0.5 天）

**目标**：两个半区的编译器都指向同一份 `cpu_pkg`，filelist 可增量演进，顶层壳先立起来。

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | `cpu_pkg.sv` 增补 PR（双审）：§3.4 全部参数、`writeback_t` 追加 `rob`、新增 `flush_t`、`decoded_t` 追加 `is_fuse` | `verilog/cpu_pkg.sv` | 终版 | design.md 合入 | 双审通过，`make build` 在空 student_top 下绿 |
| P0-2 | filelist 增加已存在文件的骨架（cpu_pkg + student_top），后续按阶段追加 | `verilog/filelist.f` | 演进 | P0-1 | `make code` 出 `./code` |
| P0-3 | `student_top.sv` 重写为互连壳（M1 简化核心直连，但端口/复位结构定稿） | `verilog/student_top.sv` | M1 版 | P0-1 | `make run` 跑通 5 拍复位无波形错误 |
| P0-4 | `run_ut.sh` 对 cpu_pkg 增补的编译回归（struct 更宽了，验证 stub 不破） | `verilog/stubs/` | 终版 | P0-1 | `sh verilog/stubs/run_ut.sh` 绿 |

---

## 4. 阶段 M1：端到端顺序通路（目标：端到端数据通路与退出协议全通）

**锚定用例**：`correctness_add_to_100`（421 条指令）必须 PASS——这是通路自检，不是产品形态。
M1 产出的多数是**丢弃型**垫脚（D3），终版文件只有 `axi_master`、`decode`、`alu`、LSU 的
wstrb/对齐推导部分与 student_top 互连。

**A 线任务**

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| A1-1 | AXI4-Lite 主端：读 FSM（在飞上限/半握手里 payload 锁存/响应按序派发）+ 写 FSM（`bready` 恒 1，按通道独立 fire，§7.4） | `verilog/memory/axi_master.sv` | 终版 | P0 | `tb_axi` 绿；`--lint-only -Wall` 零警告 |
| A1-2 | `tb_axi`：从机行为复刻（16 深队列、随机服务序、10 拍延迟、退出捕获） | `verilog/stubs/tb_axi.sv` | 终版 | A1-1 | payload 稳定性、在飞上限、读序三项断言通过 |
| A1-3 | 2-wide 译码（终版）：全 RV32IM 表、imm 拼装、`fu_e` 路由、非法→NOP | `verilog/frontend/decode.sv` | 终版 | P0 | 指令全表 UT（对拍 §8.1/§8.2/§8.3 语义） |
| A1-4 | M1 阻塞式 LSU：字对齐、wstrb/移位推导（§8.2）、load 直读 AXI、store 队头直写 | `verilog/memory/lsu_m1.sv` | 丢弃型 | A1-1 | `correctness_*` 简单点 PASS |
| A1-5 | M1 顺序取指：PC 生成 + AXI 直读（10 拍/条，无 I$）+ 单条 IFB | `verilog/frontend/fetch_m1.sv` | 丢弃型 | A1-1 | 顺序/分支重定向正确 |

**B 线任务**

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| B1-1 | ALU（终版：§8.1 全运算 + LUI/AUIPC/JAL 特殊路） | `verilog/backend/alu.sv` | 终版 | P0 | 运算全表 UT |
| B1-2 | BRU M1 版：条件解析 + 直接重定向（无预测，flush_t.valid=1, rob=当前槽） | `verilog/backend/bru.sv` | 终版 | B1-1 | 分支 6 条件单测 |
| B1-3 | M1 顺序核：五级壳（fetch/decode/exec/mem/commit），每拍 1 条，无 rename/ROB | `verilog/backend/core_seq.sv` | 丢弃型 | A1-3, B1-1 | `correctness_add_to_100` PASS |

**系统级验收（M1 出门条件）**

```sh
make build
make test Case=correctness_add_to_100 MAX_CYCLES=20000000      # 必须绿
make test Case=correctness_expr      MAX_CYCLES=20000000      # 小样本抽样
make test Case=correctness_gcd       MAX_CYCLES=20000000
make synth MODE=opt                                           # 综合冒烟（可综合+面积基线）
```

**M1 已知坑**：从机读写服务随机序在阻塞式单请求下无风险（任一时刻读/写至多一个在飞）；
退出写在 M1 就必须走 `wrQ→bvalid` 全链，别抄捷径。

---

## 5. 阶段 M2：乱序核心（目标：OoO 三件套 + 执行单元 + flush 全链绿）

**前置冻结（接口冻结点 F1）**：`decoded_t`（含 `is_fuse`）、`flush_t`、`writeback_t`、
fe→rename 2 路位流格式定稿后不再回调。

**B 线任务（关键路径）**

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| B2-1 | PRF：64×32 flop，4R/2W（按 `ISSUE_WIDTH` 缩放），p0 恒 0 | `verilog/backend/prf.sv` | 终版 | P0 | 读-写口独立 UT |
| B2-2 | 重命名：映射表+空闲表+链式依赖+前缀切片反压 | `verilog/backend/rename.sv` | 终版 | B2-1 | `tb_be_link` 前半段绿 |
| B2-3 | ROB：表项/提交（含 store 提前退休）/**flush 走表恢复**+挂起回收表 | `verilog/backend/rob.sv` | 终版 | B2-2 | `tb_flush` 恢复快照=分派时映射 |
| B2-4 | IQ：CAM 唤醒（次拍生效）+ 轮转 2 口选择 + rob 环距删除 | `verilog/backend/iq.sv` | 终版 | B2-3 | WAW/WAR/RAW 各一条链 UT |
| B2-5 | MUL 4 级流水（含 MULH 变体） | `verilog/backend/mul.sv` | 终版 | B2-4 | `tb_mul_div` 乘法部分 |
| B2-6 | DIV：radix-2 迭代 + LZA 提前退出 + 同源融合双写回（§6.4.3） | `verilog/backend/div.sv` | 终版 | B2-4 | `tb_mul_div` 除法部分（含 §8.3 全边界） |
| B2-7 | BRU 终版：JALR link/目标校验、flush_t 三字段、BP 更新请求 | `verilog/backend/bru.sv`（升级） | 终版 | B2-3 | 误预测当拍广播、次拍 FE 启动 |

**A 线任务（并行，不阻塞 B）**

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| A2-1 | 取指 2 路位流（`fe2rn_valid[1:0]`+payload 2 条）+ IFB（8 条、`bsf` 旁路） | `verilog/frontend/fetch_unit.sv` | 终版 | P0 | `tb_fe_link` 反压不丢不重 |
| A2-2 | flush 期 FE 行为：重定向寄存 1 拍、`bsf > flush.bsf` 截断 | 同上 | 终版 | A2-1 | `tb_fe_link` flush 段绿 |
| A2-3 | BP v1：BHT（2-bit）+ RAS 压/弹（JAL/JALR 译码期）；BTB 留 M3（先静态目标 guess=never） | `verilog/frontend/bp.sv` | 终版+ | A2-1 | 方向预测骨架 UT；RAS 序列 UT |

**集成顺序**：`tb_be_link`（fe_stub+真后端）→ `tb_flush`（真后端+BRU flush）→
接 `tb_fe_link`（真前端真 be_sink）→ M2 末期接真前端+真后端的整机 smoke（仍无 cache）。

**M2 出门条件**

```sh
sh verilog/stubs/run_ut.sh tb_stub_link   # 回归基线
sh verilog/stubs/run_ut.sh tb_be_link
sh verilog/stubs/run_ut.sh tb_flush
sh verilog/stubs/run_ut.sh tb_fe_link
sh verilog/stubs/run_ut.sh tb_mul_div
make test Case=correctness_tak  MAX_CYCLES=20000000   # 递归+分支压力
make test Case=correctness_queens MAX_CYCLES=20000000
make synth MODE=opt                                  # 面积曲线第一斜坡留档（D6）
```

---

## 6. 阶段 M3：访存子系统（目标：全 correctness 绿 + perf 首次出全表）

**前置冻结（F2）**：`mem_req_t/mem_resp_t` 用法、LDQ/STQ 表项尺寸、`mem_resp_t.is_store`
配对语义确认。

**A 线**

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| A3-1 | I$（`ASSOC` 路模型 + 1 项 refill）：tag/valid 阵列、miss→rdQ | `verilog/frontend/icache.sv` | 终版 | A1-5 已退场 | 命中/未命中/重复未命中 UT |
| A3-2 | D$：`ASSOC` 路、写穿不分配、字节写掩码、端口仲裁四优先级（§7.3） | `verilog/memory/dcache.sv` | 终版 | A3-1 | 命中率 UT + 回填可见性 UT |
| A3-3 | MSHR：合并/聚合 4 字回填/kill 位丢响应 | `verilog/memory/dcache.sv` 内 | 终版 | A3-2 | `tb_lsu` MSHR 段 |
| A3-4 | LSU A 侧终版（替换、消化 `lsu_m1.sv`） | `verilog/memory/lsu_a.sv` | 终版 | A3-2 | `tb_lsu` 通 |
| A3-5 | 存储 drain→wrQ 完成 → ROB 窄带标 done | `memory/lsu_a.sv` + `rob.sv` | 终版 | A3-4 | `tb_lsu` store 段 |
| A3-6 | BP v2：BTB（JALR 目标）+ BRU 解析回写 | `verilog/frontend/bp.sv`（升级） | 终版 | A2-3 | 分支统计 UT |

**B 线**

| ID | 任务 | 文件 | 类型 | 前置 | 验收 |
| --- | --- | --- | --- | --- | --- |
| B3-1 | AGU + LDQ/STQ（含 IQ fire 即释放、replay 通道） | `verilog/memory/lsu_b.sv` | 终版 | B2-4 | `tb_lsu` B 侧段 |
| B3-2 | 前递/阻塞三规则（§7.2：完全覆盖前递 / FIFO 序阻塞 / 无重叠直通） | `lsu_b.sv` | 终版 | B3-1 | `tb_lsu` 前递段全覆盖 |
| B3-3 | store 提前退休确认（rob 侧）/ LSU 记录覆盖式分配（§4.3 尾条） | `rob.sv` 配合 | 终版 | B3-1 | 环距复用无孤儿断言（§11.3） |
| B3-4 | flush 跨 A/B 全链（IQ/LDQ/STQ 年幼 kill ↔ MSHR kill 位 ↔ FE 截断） | 跨模块 | 终版 | B2, A2, A3 | 整机 flush 压测（随机分支流） |

**M3 出门条件**

```sh
make test MAX_CYCLES=20000000            # 全 19 个 correctness 绿
make perf                                # 6 个 perf 出全表 + GEOMEAN（进报告基线）
make synth MODE=diagnose                 # 面积热点定位第一轮
```

**M3 已知坑**（按序攻破）：重叠阻塞解除后的 replay 撞 D$ 端口仲裁；MSHR 满时 IQ 反压死锁
（必须在 `tb_lsu` 用"MSHR 全占 + 新 load"用例覆盖）；RAS 溢出弃底（行为要固定且进注释）。

---

## 7. 阶段 M4：IPC 调优（分数口径的第一冲刺）

**方法**：全部调用 design §13 的 E1~E10 参数矩阵，单因子扫描，记录
（GEOMEAN / 面积 / Fmax）三元组进 `references/synth-history/`；禁止无参数名的魔改。

**优先动作池**（按经验性价比排序，命中后即停）：

| 序 | 动作 | 预期收益 |
| --- | --- | --- |
| 1 | `MSHR_N` 1→2→4、`LINE_BYTES` 16 与 32 对比 | 流式程序（vvadd 类）未命中摊薄 |
| 2 | `MUL_LAT` 4 vs 2 级；DIV LZA 开关 | 乘/除链 |
| 3 | BTB/JALR + RAS 修正 | 递归类误预测率 5%→1% 量级 |
| 4 | IQ 16→32、ROB 32→64（若 PRF=64 未饱和） | 窗口上限 |
| 5 | 唤醒旁路（WB→IQ 同拍 CAM 匹配，省 1 拍依赖延迟） | ALU 链 IPC 直接抬升 |
| 6 | 关键字优先（rows: I$/D$ 触发字先出） | 取指 + 未命中链缩短 ~4 拍 |
| 7 | （大刀，仅 tier3 冲刺评估）双 ALU→三发射或 ALU/MEM IQ 拆分 | 与面积预算一起裁决 |

**出门条件**：`make perf` GEOMEAN 达到 cfg-base 目标（≥0.845）或明确知道卡点在哪一档。

---

## 8. 阶段 M5：综合、频率与档位固化

| ID | 任务 | 做法 | 验收 |
| --- | --- | --- | --- |
| M5-1 | `make synth MODE=diagnose` 定热点 | 报告读树（模块 Area/Direct/％）；重写面积前三名 | 热点清单 + 重构 PR |
| M5-2 | 频率结构化 | `CLOCK_PERIOD_NS=2.0` 起步 → 必要时拆级（IQ 唤醒/选择、LSU CAM 已在 §6.3/§7.2 分拍）；路径审查 `timing.rpt` | `CLOCK_PERIOD_NS` 各点 Fmax 曲线 |
| M5-3 | cfg-small / cfg-base / cfg-big 参数固化 | 仅 `cpu_pkg.sv` 参数（§3.4 缩放规则），零 RTL 差异 | 三份 report.json + 三份 perf 表 |
| M5-4 | 档位决策（对照 README 分数表） | 面积↔IPC↔频率 分数比较；与频率加分一起权衡 | 选定提交档与理由（写入报告） |
| M5-5 | 提交复核（OJ checklist，见 §10） | 逐项 grep/命令 | `make code` 产物通过官方 `run` 复现 |

**M5 出门条件**：`make synth MODE=opt` 与 `make perf` 结果符合选定档的全部三项阈值。

---

## 9. 双人排程（相对课程时间线：中期第 7 周，DDL 第 14 周周六）

| 周 | A 线（前端+访存） | B 线（乱序核心） | 阶段出口 |
| --- | --- | --- | --- |
| W1 | P0-1~4；A1-1/A1-2（axi_master+tb_axi） | B1-1（alu）；B1-2（bru M1） | P0 冻结、M1 启动 |
| W1~W2 | A1-3（decode）、A1-4/A1-5（M1 阻塞 LSU/取指） | B1-3（M1 顺序核集成） | **M1 完成：add_to_100 绿** |
| W2~W3 | A2-1/A2-2（2 路位流+IFB+flush 截断） | B2-1（prf）、B2-2（rename） | rename 单测绿 |
| W3~W4 | A2-3（BP v1） | B2-3/B2-4（rob+IQ）、B2-5/B2-6（mul/div） | `tb_be_link`/`tb_flush` 绿 |
| W5 | A/B 整机 smoke、tb_fe_link 合流 | B2-7（bru 终版） | **M2 完成：recursion 类 correctness 绿** |
| W5~W6 | A3-1～A3-3（I$/D$/MSHR） | B3-1/B3-2（AGU+前递） | `tb_lsu` 段绿 |
| W7 | （中期检查）A3-4/A3-5 终版 LSU | B3-3/B3-4 flush 全链 | 中期：OoO+简化 mem；perf 初值 |
| W8 | A3-6（BP v2） | 联调 `student_top` 终互连 | **M3 完成：全 correctness 绿** |
| W9~W10 | （联同）M4 扫描 1~4 | （联同）M4 扫描 5 | GEOMEAN 进档 |
| W11 | M4 收口：写报告用的参数表 | 同 | **M4 完成** |
| W12 | M5-2/3（综合/频率结构化） | M5-1（热点重构） | Fmax 曲线 |
| W13 | M5-4/5：档位固化 + OJ 复核 + 冻结 | 同 + 报告初稿 | 全面冻结 |
| W14 | 缓冲周（仅修 bug/重跑口径）；DDL 周六 23:59 | 同 | 交卷 |

> 双人节拍规则：两侧任一侧进入"等接口"状态时，被迫等待者先做下一阶段可并行项，
> 不允许静态等待；每周固定一次交叉 code review（尤其 flush/LSU 环距逻辑）。

---

## 10. OJ 提交前 checklist（对应 README §OJ）

1. `verilog/filelist.f` 相对路径齐全（`grep -v '^#' filelist.f` 逐个存在性检查）；
2. `student_top` 端口与 README 模板逐位 diff（`clock/reset/ar*/r*/aw*/w*/b*`）；
3. `make code` 产出 `./code`，并用 `./code` 走官方无参（OJ 模式）输入重放
   （stdin 头 `CPU2026-OJ 1 <cycles> <latency>` + program.data）；
4. 工程内无 `$fatal` 泄漏（UT/backdoor 全部限 stub 与 `SYNTHESIS` 显式分支之外）；
5. `sram_fakeram` 只被引用、未被重定义（grep 单一来源）；`scripts/` diff 为空；
6. 注销流水级调试 `$display`（或统一用 `DEBUG` 参数包住）；
7. 用 OJ 口径偏保守复跑一轮：`LATENCY=10`，对三个最贵的 correctness 项全绿。

---

## 11. 风险闸门（阶段切换的硬条件）

| 闸门 | 必须满足的硬证据 |
| --- | --- |
| G-P0→M1 | `cpu_pkg` PR 合并 + 双方可编译 |
| G-M1→M2 | `add_to_100` PASS + `make synth MODE=opt` 无 lint 红字 + axi UT 全绿 |
| G-M2→M3 | `tb_flush` 绿 + tak/queens PASS + 空闲表终态守恒断言（§11.3） |
| G-M3→M4 | 全 correctness PASS（20M 上限）+ perf 表完备 + flush 跨 A/B 随机压测无错答案 |
| G-M4→M5 | cfg-base GEOMEAN 达标或卡点诊断结论成立（决定 cfg-small 兜底还是冲 tier3） |
| G-M5→提交 | §10 checklist 7/7 + 冻结后无 RTL diff |

---

## 12. 计划的修改规则

- 本计划随实施进程滚动更新（完成后勾销、遇到新依赖时插入任务），但**阶段目标/放手条件不变时
  只改内文**；影响设计结构时先改 `docs/design.md`（PR）再同步本计划；
- UT 数量按需增补，但 §11.1（design 文档）里列的七条 UT 是必做全集；
- 任何任务完成定义固定为：**代码 + UT/抽样绿 + 留档（D6）**三件套，缺一不算完。



---

## 13. 阶段 2 冲刺排程（对应 `docs/design.md §16`；2026-10-16 定稿）

> 设计细节（机制/保序论证/验收判据）一律以 design.md §16 为准；本节是排程与出门条件。基线：GEOMEAN 0.6489 / 4,475.4 µm² / 383.66 MHz。

| 里程碑 | 内容 | 面积增量（估） | 出门条件（硬门禁：面积 ≤18,000、频率 ≥320 护栏、全量回归） |
| --- | --- | --- | --- |
| M6 | 四探针测量 + 离线建模（P1 分支流/TAGE 选型、P2 LSU 并行度、P3 store-head 归因、P4 load-use） | 0 | 四份量化结论进 handoff；探针清零三步验证 |
| M7 | TAGE（bp.sv + 携带字段扩宽全链） | ~0.3k | **G1**：GEOMEAN ≥0.67 且 qsort 误预测 ≤16%；UT/回归全绿 |
| M8 | store 地址早知 + load 门槛放宽（无投机；iq/lsu_b） | ~0.5k | **G2**：≥0.72；保序论证注释 + **golden 对拍（qsort/rsort）** + flush 压测 + LATITUDE=1/50 |
| M9 | 双发 LSU + 双读 D$（iq/lsu_b/dcache；同 bank replay；MSHR→4） | 1.5~3k | **G3**：≥0.76 且频率 ≥320 MHz |
| M10 | load-use 降延迟（必做）；3 发射等宽度项（门控） | 1~3k（门控） | G4 冲 ≥0.845；未达则按 design §16.7 降级 |
| M11 | 参数定格 + 频率护栏复核 + 全量留档 + 文档收口 | ~0 | 阶段 2 三元组定格或降级结论成立 |

每里程碑独立可回退；每步 `make test`（20M）+ `sh build/run_all_ut.sh` + `make perf` + `make synth MODE=opt` 冒烟留档 `references/synth-history/`（**synth 会清 `build/sim`，先 `make build` 再跑 test/perf**）。
