# 现场交接（handoff）——窗口 2026-10-16 晚（IPC 战役：前端流水化 + D$ 扩容，阶段 1 达标）

> 阅读顺序：本文 → `docs/design.md`（§2 框架硬约束、§4.3 flush 协议、§5 前端/BP、§6 后端、§7 AXI/边界与访存、§13 参数矩阵、**§16 阶段 2 冲刺设计**）→ `docs/impl-plan.md`（**§13 阶段 2 排程**）→ `docs/axi4-lite.md` → `references/synth-history/2026-10-16-notes.md`（**注意：该文 §4 三元组表是旧综合流程的数字，见本文 §2；该文追加了 §10/§12**）。**动任何代码前先读完。**

---

## §1 当前状态（一句话）

- **RTL 功能已达标阶段 1**：`cpu_pkg` 默认 `WB_BYPASS=1`、`ROB_DEPTH=32`、`PRF_NUM=64`、`IQ_DEPTH=16`、`MSHR_N=2`、`LINE_BYTES=32`、`DC_LINES=1024`、`MUL_LAT=4`、`LDQ/STQ=8`、`BHT_ENTRIES=256`、`BTB_ENTRIES=128`、`RAS_DEPTH=16`、`BP_GHR_BITS=8`。
- **回归（20M 口径）**：`make test` **19/19**；`sh build/run_all_ut.sh` **6/6**；`make perf` **GEOMEAN 0.6489**（median 10,852 / multiply 24,222 / qsort 302,470 / rsort 241,619 / towers 10,058 / vvadd 6,855）。
- **新综合流程（默认新配置）**：**4,475.4 µm² / 2.6064 ns → 383.66 MHz**，报告 `2026-10-16-newflow-ipcwin-ab-tournament-opt.json`。
- **最近两窗做完**：①前端取指流水化 + D$ 扩容（§6.5，0.5492→0.6353）；②**(A) LSU 顺序门控放宽（最老优先收口）**（§13.2）；③**(B) 分支预测升级：bp 参数化 + 锦标赛 gshare + 全链 `bix` 携带 + BHT256/BTB128/RAS16**（§13.3）；④本地审查清理（§13.6）。合计 0.6353→**0.6489**。
- **阶段 1 三项阈值全部满足**：面积 4,475 ≪ 9,000 ✓、频率 383.66 ≥ 300 ✓、IPC 0.6489 ≥ 0.6000 ✓。
- **未 git commit**：全部实现都在工作树（`verilog/backend|frontend|memory/`、`docs/handoff.md`、`tools/` 未跟踪；`cpu_pkg.sv / filelist.f / student_top.sv / stubs/*` 已跟踪但已修改；(A)/(B) 改动同样未提交，见 §13）。正式 RTL（filelist.f 内）`$display` 为 **0 处**（探针已清零）。

---

## §2 综合口径变更（本窗最重要的一次“环境变化”）

今晨 upstream 合并（commit `c018907` ← `302f0cf`「Enable configurable ABC buffering and cell sizing constraints」）：`scripts/synth.py` 现在向 ABC 传 `-constr`（`set_driving_cell INVx1_ASAP7_75t_R` + `set_load 5.0fF`），**并启用 ABC 的 buffering 与 cell sizing**。Makefile 新增 `ABC_DRIVING_CELL` / `ABC_LOAD_FF` 两个可调项（默认即上值）。

后果：
- **全部历史 JSON（≤ `2026-10-16-bypass1-opt.json`）的面积/频率列来自旧流程，不可与新流程数字直接比较**（旧流程无缓冲/无负载模型，频率被严重低估：同一 RTL 旧流程 93.5 MHz ↔ 新流程 381.8 MHz）。
- 新流程下面积也变了（3,463.7 → 3,680.0 µm²，+6.2%，缓冲单元计入）。
- 历史扫描的 **IPC/周期结论仍然有效**（那是 Verilator 仿真口径），只有面积/频率列需要重测。

### 分数形势（README-ZH §评分标准）

| 阶段 | 面积上限 | 最低 IPC(GEOMEAN) | 最低频率 | 累计分 |
|---|---|---|---|---|
| 1 | 9,000 µm² | **0.6000** | 300 MHz | 90 |
| 2 | 18,000 µm² | 0.8450 | 300 MHz | 95 |
| 3 | 36,000 µm² | 1.0985 | 300 MHz | 100 |

频率加分（**必须先满足某阶段的面积+IPC+300MHz**）：400 MHz +2、500 MHz +4。

当前：面积 4,475 ≪ 9,000 ✓，频率 383.66 ≥ 300 ✓，**IPC 0.6489 ≥ 0.6000 ✓** → **阶段 1 三项达标（累计 90 分）**。下一得分点：①频率 383.66 → 400 MHz（+2 分，需 −4.1% 周期）；②阶段 2（95 分）：面积 ≤18,000 / 频率 ≥300 / **IPC ≥0.8450（需 +30%）——路线已定稿于 `docs/design.md §16`（M6 测量 → M7 TAGE → M8 访存乱序 → M9 双发 LSU/双读 D$ → M10/M11 按 Go/No-Go 门推进），交接见本文 §14**。

**本窗归因结论（重要，修正上一窗口的印象）**：所有 perf 用例在基线都没被“前端取指吞吐”单点限制——`req ≈ cycles/2` 只是两相 FSM 的自我节流假象；实测瓶颈是**核心侧（ROB/IQ 满 + 依赖链）+ D$ 冲突未命中**。前端流水化只带来 +6.5%（0.5492→0.5848，multiply 单点 +22%）；D$ 扩容/行大小再叠 +8.6%。两者合起来 +15.7%。

**GEOMEAN 杠杆提示**：单点提升 x% 只让 GEOMEAN 涨约 x/6。要 +9.25% 需要“面”的改善，例如 qsort/median/towers 各 +20%，或五个访存类各 +9%。6 个 perf 里 5 个是访存/递归受限（median 0.4968、towers 0.4987、qsort 0.4098、rsort 0.6266、vvadd 0.6251），只有 multiply 是计算类 → **主战场是 D$ 命中/未命中处理、load-use 延迟、分支预测**，而不是微调单个用例。

---

## §3 代码地图（`verilog/filelist.f` 顺序）

```
cpu_pkg.sv              # 契约 + 参数；WB_BYPASS=1 / ROB_DEPTH=32 / PRF_NUM=64（均可真参数化）
frontend/decode.sv      # 2 宽译码（decode1 + decode 包装）
frontend/bp.sv          # BHT(128×2b) + BTB(32) + RAS(8×32b)；双查询口 + 训练口
frontend/icache.sv      # 2 bank 直映 I$（IC_LINES×LINE_BYTES），1 项 refill，busy 全停
frontend/fetch_unit.sv  # 流水化取指（1 block/周期，I$ 1 拍读）/ IFB(8) / 组合预测 / flush 截断
backend/alu.sv bru.sv   # ALU×2、BRU（flush_t 当拍产生、寄存 1 拍广播）
backend/mul.sv          # MUL_LAT 结构化（4 级 / 2 级）；meta 打包已参数化
backend/div.sv          # radix-2 + 提前退出 + 同操作数结果缓存（融合未接线）
backend/prf.sv          # 4R/2W；**unpacked 数组 + 4 宽展开 reset 循环**（见 §5D）
backend/rename.sv       # 映射表/空闲表/挂起表；宽度全参数化（PB/RB localparam，端口用 $clog2）
backend/rob.sv          # ROB；dtain 满窗编码 = ROB_DEPTH；kill/恢复循环按 ROB_DEPTH
backend/iq.sv           # 统一 IQ；WB_BYPASS 选择；LSU 按程序序只发最老
backend/wb_skid.sv      # MUL/DIV 写回 skid
backend/core_ooo.sv     # 集成 + BA/BB 仲裁 + 旁路 mux；rob_space 等连线已随参数加宽
memory/lsu_b.sv         # AGU/LDQ/STQ/前递/replay；程序序键（单调退役序号 + 12bit 模差）
memory/lsu_a.sv         # store drain FSM（S_IDLE/S_SU/S_PUSH）+ 完成失效
memory/dcache.sv        # 直接映射写穿 + MSHR_N 项（同 set 串行 replay）+ 响应 FIFO + kill 位
memory/axi_master.sv    # rdQ/wrQ、在飞上限、AW/W 同生同灭
student_top.sv          # D$>I$ 读仲裁 + 按 src 路由（零功能逻辑）
```

数据流：`icache(S0/S1) → decode(S2) → BP → IFB → rename → {ROB, IQ} → FU → BA/BB → PRF/ROB/IQ`；
访存：`lsu_b ⇄ lsu_a(dcache/写队列) ⇄ axi_master`；flush 由 BRU 解析拍寄存 1 拍广播。

---

## §4 契约与接口

- **端口契约**：`student_top` 端口一字不差（README 模板）。
- **rd push/rsp aux idx 5bit**：`{slot[1:0], word[2:0]}`（I$ 推 `{2'b00,word}`；D$ 推 `{slot,word}`）；响应取低位 `$clog2(LINE_BYTES/4)`。
- **`cpu_pkg` 参数**：`ISSUE_WIDTH=2`（固定用法）、`DECODE_WIDTH`、`ROB_DEPTH`、`PRF_NUM`、`IQ_DEPTH`、`LDQ_DEPTH`、`STQ_DEPTH`、`MUL_LAT`、`DIV_LAT_MAX`、`LINE_BYTES`、`IC_LINES`、`DC_LINES`、`ASSOC=1`、`MSHR_N`、`AXI_MAX_RD/WR`、`BHT_ENTRIES`、`BTB_ENTRIES`、`RAS_DEPTH`、`WB_BYPASS`。
  - **真正可用的旋钮（已验证）**：`LINE_BYTES`（16/32）、`MUL_LAT`（2/≥4）、`IQ_DEPTH`、`MSHR_N`（1/2/4）、`ROB_DEPTH`、`PRF_NUM`、`WB_BYPASS`。
  - **尚不是真旋钮**（硬编码 8，见 §6 待办）：`LDQ_DEPTH` / `STQ_DEPTH`（lsu_b 内 `lowest()`、掩码、数组宽度是字面量 8）。
- **LSU 程序序键**：`s_key/l_key` 13bit；retired = `{1'b0, s_seq[11:0]}`，live = `{1'b1, {(12-RB){1'b0}}, (rob-rob_head)}`（RB=`$clog2(ROB_DEPTH)`，故 ROB=64 时 dist 6bit 仍落 7 位域）；跨回绕**一律模差比较**（`seq_older`：`(b-a)<2048`；`key_newer` 处理 retired/live 混合）。`ret_seq_q` 每退役拍 **+2**（cmt1 占 base+1）。
- **`flush_younger(i, frob, dtail)`**：位宽随 ROB_DEPTH 派生（`RB=$clog2(ROB_DEPTH)`，rob 域 RB 位、dtail 域 RB+1 位）；dtail=0 无幼年项，**ROB_DEPTH = 满窗**（frob 恰为满 ROB 头部）。全链唯一真源（rob 生成，IQ/LSU/D$/core_ooo 消费）。

---

## §5 必背陷阱

### A. 全线通用（历史遗留，仍全部有效）

1. **SV「带初值的 var」陷阱**：`logic [N:0] sig = expr;`（无 `wire`）= 只 t=0 求值一次。组合赋值一律 `wire ... = ...;` 或 `always_comb`。
2. **`{slot1,slot0}` 不能当二进制计数**；计数用 `{1'b0,a}+{1'b0,b}`。
3. **flush 拍仍须标记写回完成**：ROB 的 done 标记在 flush 分支之外无条件执行。
4. **取指 miss 不得提前推进 pc**（两相 `phase_q`）。
5. **I$ refill 地址必须含 idx**：`{tag,set,idx,2'b0}`。
6. **IQ 必须按程序序只发最老的 LSU 项**（`lsu_old` 门控）。
7. **被删项挂起回收用 `issued`/`is_load` 判定**（否则空闲表泄漏 → 死锁）。
8. **JAL/JALR 重定向由 fetch_unit 组合检测**，`bsf` 重定向补齐 slot1 自增。
9. **Yosys 0.63 兼容**：不支持 `import cpu_pkg::*`；不支持 `'{字段:值}` 与变址访问结构体数组字段；不支持结构体数组端口；**package 函数体内不得引用 enum 常量**（`Failed to detect width for identifier ...OP_JALR`——本窗 `is_ret()` 踩过，改用 `decoded_t.is_ret` 字段绕过；照旧 `flush_younger` 这类纯位运算函数没问题）。出 `Resizing cell port` 即网表失真。generate+genvar 循环合法（dcache/prf 已用）。
10. **decode 对无目的指令清零 `rd`**。
11. **Store 只能在「退役后」drain**；错误路径 store 不得触内存。
12. **程序序 key**：退役项用**单调退役序号**（不是 `31-(head-rob)`），live 用 `0x1000+head 距离`；步进 +2；**比较用模差**（§5C-2）。
13. **已退役 STQ 项永不 kill**（kill 循环带 `!s_ret`）。
14. **tag-0（rd=x0）陈旧写回**：ROB 写回过滤加 `iss_q`；被 kill 的 tag-0 hold 排空子句放链尾。
15. **闩锁候选要自愈**：候选既非 GO 也非 FWD 时 `sc_v<=0` 重选。
16. **半字移位是 `{off[1],4'b0000}`（×16）**；`stsh` 与 `ldext.hsel` 同错会在转发路径抵消。
17. **D$ 失效时机**：store drain `su_hit=0` → B 回执拍失效该行。
18. **drain 握手记账**：直选当拍被接受的项必须同拍记 `s_drd`。
19. **D$ 结构细节**：同 set MSHR 串行（replay）、分配时立即清该 set valid；响应 FIFO 双写；bypass（≥0x10000000）用 `m_trig`。
20. **UNOPTFLAT**：LSU `in_ready` 不得依赖“被发射的 op”（`ld_alloc_ok/st_alloc_ok` 分路 + IQ `st_ent_q`）。

### B. M3 血泪（仍有效）

1. **dtail 域**：满窗编码 = ROB_DEPTH（现在是参数化值，不是字面 32）。改 flush 协议前先读 rob.sv 注释。
2. **kill 与分配同拍**：flush 拍新到达的分配必须由分配方组合判据拒绝（`lsu_b.in_kill`、`dcache.pend_kill`）。
3. **lookup→分配跨拍**：`lk_kill` 直接拒收 flush 拍被 kill 的 lookup。
4. **预测三件套**：BHT/BTB 索引用指令自身 pc；BTB 仅 taken 写、返回 JALR 不写；RAS s0 口含 half 取指。
5. **smoke 周期数“完全不变”是可疑信号**（改动没生效）。

### C. 各窗合订（全有复现记录）

1. **回收门控**：`rec_eff = reclaim_mask & (pend_q|flush_pend_mask)`——被杀 load 的迟到写回只能作用于仍挂 pend 的 tag。
2. **退役序号步进与比较**：基址每退役拍 +2；12bit 戳 2048 拍回绕 → **必须模差**。普通比较实测代价：tak +167k；**BYPASS=1 下 qsort 错答案 305,561/707（本窗归因复现）**。
3. **旁路三定律**：选择旁路与操作数 mux 同用“已限定”写回（ba_ok/bb_ok）；mux 必须 `ps!=0` 门控；mux 单开是可证明 no-op。
4. **幻影 LV / RWB≠提交**：kill 前已 hold_take 的 load 仍打 LV/WB（rob 拒绝）；**flush 到达前 `a_ok` 已收下的误预测写回同样“被接受”** → `RWB` 只证明写回被收下，**不证明提交**；架构确认流必须用 **CMT 提交流**，且按 rob 实例（上一 `DSP` < LV ≤ 该 CMT）配对。
5. **探针 seq 位宽 ≥32bit**（rsort 级 LSQ 事件 >65,536，16bit 回绕会伪造 mismatch）。
6. **提交-完成配对必须按 rob 实例**（同 4）。
7. **upstream 综合口径已变更**（见 §2）：比较面积/频率前先确认 JSON 是新流程产物。

### D. 本窗新增（参数化/加宽/探针）

1. **端口声明不得引用模块体内 localparam**：Yosys 报 `Non-constant range in declaration of \xxx`。**端口写内联 `[$clog2(cpu_pkg::PARAM)-1:0]`**，模块体内才用 `localparam`。Verilator 两种都收（容易漏）。
2. **加宽一个结构必须全链扫描“窄声明”**：本轮漏改的四处全是**连线/端口**而非逻辑——`core_ooo.wire rob_space [5:0]`（把 64 截成 0 → rename 永不分配 → 死锁）、`rename` 的 5 个掩码输入 `[63:0]`、`restore_pdst [191:0]`、`rob_pdst*/rob_old*` 输出 `[5:0]`、`rob.rec_a_tag/rec_b_tag [5:0]`（tags≥64 丢 reclaim → 挂死/错答案）。**方法**：加宽后 grep 全树旧位宽字面量（`[4:0] [5:0] [63:0] [191:0] 5'd 6'd 64'd1 192'b0 6'd32`）逐个核对，并跑 `make test` + UT。
3. **Verilator BLKLOOPINIT**：unpacked 数组在 `for` 里的**延迟赋值**，128 次迭代被拒（64 次可以）。PRF reset 改为 **4 宽展开循环**（`i+=4` 四句）。packed 向量形式可行但新流程综合更慢，已回数组形式。
4. **行为等价证明法（加宽/重构必做）**：
   ```sh
   make test SIM=build/sim MAX_CYCLES=20000000 > /tmp/x.log 2>&1
   grep -B1 -E "^PASS" /tmp/x.log | grep -E "^\[" | paste - <(grep -E "^PASS" /tmp/x.log) > /tmp/new.pairs
   diff /tmp/new.pairs <(旧基线 pairs)
   ```
   逐项**周期数完全相同**才算“默认未变”。本窗 ROB/PRF 参数化已在默认 32/64 下证明 19/19 全等 + perf 全等。
5. **探针 `$time % N == 0` 陷阱**：posedge 时刻 ≡1 (mod 4)，`$time%4000==0` 永不成立 → 用**周期计数器**（`dbg_cyc <= dbg_cyc+1; if (dbg_cyc%N==0)`）。
6. **参数化留给下窗的已知边界**：`LDQ_DEPTH/STQ_DEPTH` 仍是假旋钮（lsu_b 里 8 是字面量）。
7. **D$ `DC_LINES` 必须为 2 的幂**：`$clog2` 派生 set 位宽，非 2 的幂（如 1536）会产生越界 SRAM 地址 → `sram_fakeram` `RAM library error`（实测 fatal）。`LINE_BYTES` 只支持 16/32（dcache 有 `initial $fatal` 守卫）。
8. **探针 `$display` 会污染 `make test/perf` 的 stdout 协议**（OJ 模式 sim 只向 stdout 打印返回值，`testcase.py` 逐行比对）→ 探针输出必须走文件（`$fopen/$fwrite` 到 `build/…log`）或只在 `make run` 下用，绝不带进 `make test/perf`。
9. **前端流水化后 `bsf` 与 `pc` 解耦**：`bsf_r` 随“已消费的响应块”推进（与是否发新请求无关），`pc_r` 随 `issue_ok` 推进；redirect/flush 用组合 `first_bsf`。改 fetch 前先读 fetch_unit 头注释。

---

## §6 已完成的本窗任务（含证据）

### 6.1 唤醒旁路收口（默认 `WB_BYPASS=1`）

- 上窗“BYPASS=1 qsort 错答案 255/707”**在当前树不可复现**；**归因实验**：把 `lsu_b::seq_older` 临时退回普通比较 `(a<b)`，qsort 立刻 `FAIL cycles=305,561 result=707`，与上窗失败现场 `build/qsort_dbg4.log` 逐字一致 → 根因=退役序号回绕反序，模差收口同时收口了旁路。
- **提交级 golden 对拍**（探针：rob `DSP/CMT/RWB` + lsu_b 32bit seq `LF/LV/FWD/LDACC/STACC`；脚本 `build/win2_analyze_commit.py`）：qsort 31,033/31,033、rsort 37,902/37,902 条已提交 load 的 (addr,val) 与 golden **逐项全等**；store 流全等（golden 不含退出写）。LATENCY=1/50 压测 12/12 PASS。
- 收益：GEOMEAN 0.5201 → **0.5492**（rsort 360,521→312,368 −13.4%、vvadd −8.5%、qsort 353,181→341,376 且正确、median 14,388→14,013、towers −3.1%）。代价：correctness 中 `pi` 17.35M→17.76M（+2.4%，不进 GEOMEAN）。
- **副作用**：无（探针全部清除；正式 RTL `$display` 0 处）。

### 6.2 I$ 关键字优先评估（结论：不做）

实测（探针计数）：miss 仅 18/19/39/56/67/13（median/multiply/qsort/rsort/towers/vvadd），每 miss 全停 ~19-20 拍。AXI 读**按序返回**，4 个字背靠背 → 关键字优先只省**尾部 ≈2 拍/miss**（≤0.04% qsort/rsort，仅 towers 1.3%），却要 per-block valid + busy 语义 + refill 期 bank 仲裁重构。**维持不做**。

### 6.3 E2/E3（ROB64+PRF128）：参数化已落地，默认不回退配置

- **参数化落地**（真实旋钮，非伪参数）：cpu_pkg 字段 + flush_younger 泛化 + rob/rename/iq/core_ooo/lsu_b/lsu_a/dcache/student_top/mul/div/prf/stub 全链宽度。默认 32/64 下 **19/19 逐周期全等 + perf 全等 + UT 6/6**（等价性证明通过）。
- **64/128 实测**：`make test` **19/19**、UT **6/6**、perf **GEOMEAN 0.5491**（median 14,013 / multiply 31,482 / qsort 341,321 / rsort **312,808（反而 +0.14%）** / towers 10,583 / vvadd 7,239）；correctness 小幅变化（bulgarian 409,462→406,816、magic 659,658→658,198、qsort 1,577,813→1,575,518、pi 微降、tak 1,429,833 等）。
- 旧流程综合代价：64/128 = 3,591.6 µm² / 11.5039 ns vs 32/64 = 3,463.7 µm² / 10.7002 ns（+3.7% 面积、−7% 频率）。
- **新流程综合 64/128 实测跑不完**：`make synth MODE=opt` 超过 **30 分钟未完成**（默认 32/64 约数分钟；中途已清进程）。即该配置在启用 ABC buffering/cell-sizing 后**综合时间显著爆炸**（ROB 64 项 × 128-bit 掩码/回绕循环的组合锥 + 巨扇出），**三元组未得到**。
- **决策：默认保持 32/64**（IPC 中性 + 综合侧不可用；参数保留，一行可切，但**若要再试 64/128，先做好综合爆炸的心理/时间准备，或改用 `make synth MODE=diagnose` 先看规模**）。
- 为什么窗口不是瓶颈：实测 ROB 满 qsort 13%/rsort 16% 时间，但加深后 IPC 不变 → 说明“ROB 满”时头部通常在等长延迟事件（D$ 未命中/同 set replay/依赖链），**LDQ/STQ=8、MSHR_N=2、LSU 顺序发射、同 set replay 才是真正的限制**。

### 6.4 本窗：IPC 归因测量（临时探针，已清零）

- 在 `core_ooo/iq/lsu_b/dcache/fetch_unit/axi_master` 加临时探针，用 **AXI 退出写 B 握手的 tag** 作单拍 `dbg_dump`，各模块在该拍输出累计计数（输出到 `build/dbg_probe.log`，**不污染 make test/perf 的 stdout 协议**）——这是比“周期计数器取模打印”更精确的做法（无尾部误差）。
- 关键实测（基线 256/16）：qsort `req=144920`、`fe_empty=43%`、`rob_full=14%`、`zn_dep=33%`、`replay=21037`（setset 18169）；rsort `iq_full=34%`、`ifb_stall=35%`、`replay=27392`（setset 24364）；vvadd `rob_full=52%`、`ldq_full=21%`。
- **修正**：`req ≈ cycles/2` 不是“前端受限”证据，而是两相 FSM 的自我节流；流水化后核心侧（ROB/IQ 满）暴露为主因。
- 探针清除三步验证：①全树 `$display/$fopen` 归零；②重建；③**带探针与不带探针对同一配置给出逐周期完全相同的 6 个 perf 周期**（dc1024lb32：median 12381 / qsort 301353 / rsort 242634 …）→ 探针非侵入且清除干净。

### 6.5 本窗：前端取指流水化 + D$ 调参（阶段 1 达标）

- **前端流水化**（`frontend/fetch_unit.sv`，唯一结构性改动）：删除两相 `phase_q` FSM，改为 I$ 每周期接收一个请求（I$ SRAM 本就是 1 拍流水读）；响应在下一拍检查、命中则同拍压 IFB 并发起下一个 fall-through 块（1 block/周期）；miss 用 `miss_det` 回退 pc 重发；redirect 抑制一拍并重启 target；flush 语义不变。收益：GEOMEAN 0.5492→0.5848（multiply −22%、tak −13%、qsort(correctness) −12%）。风险点在 `bsf` 推进与 pc 解耦（bsf 随“已消费块”推进，与是否发新请求无关）。
- **D$ 调参**（`cpu_pkg`）：`DC_LINES 256→1024`、`LINE_BYTES 16→32`。收益：0.5848→**0.6353**。参数扫描（流水化后，`make run`）：DC512 0.5929、DC1024 0.6226、DC2048 0.6253、DC1024+LB32 **0.6353**。
- **无效旋钮（实测）**：`MSHR_N=4` 零收益（同 set replay 主导，MSHR 数不是卡点）；`IQ_DEPTH=32` 零收益；`ROB_DEPTH=64+PRF=128` 零收益（本窗复测，与上窗一致）→ 均不采用。
- **硬约束**：`DC_LINES` 必须为 2 的幂（1536 会越过 `sram_fakeram` DEPTH → `RAM library error`）。
- **验收**：`make test` 19/19、UT 6/6、perf 6/6 GEOMEAN 0.6353、`make synth MODE=opt` 无 ERROR/latch/Resizing（4,306.8 µm² / 2.6152 ns / 382.37 MHz）；LATENCY=1/50：perf 12/12 PASS、correctness 子集 (tak/queens/qsort/hanoi) 8/8 PASS。

### 6.6 本窗：代码审查清理（行为等价）

- 对未提交改动做了一次本地审查（六轨），10 条 SUGGESTION 全部清理，**逐周期等价证明通过**（19 个 correctness 周期、perf 六项、UT 全与清理前逐项相同）：
  - 去重：`cpu_pkg::is_uncached(addr)` 单点定义（dcache load 侧 `pend_unc` 改为查表锁存 `pend_unc_q`，lsu_a store 侧与失效检查改用它）；返回指令判定改为 **`decoded_t.is_ret` 字段**（decode 置位，fetch_unit 的 RAS 与 core_ooo 的 BTB 训练共用）——注意 **Yosys 0.63 不支持 package 函数里引用 enum 常量（`OP_JALR`）**，故用字段而非 `is_ret()` 函数。
  - 死代码清理：`axi_master` 的 `wr_rsp_ready`/`bresp` 端口、`student_top.ax_rsp_err`、`iq.p0/p1`、`div.cfast/fgt_p/f_c`、`rename.RB`、`tools/mk_storeload.auipc`。
  - `student_top.bresp` 是 README 端口契约（一字不差），必须保留；已用注释 + `/* verilator lint_off UNUSEDSIGNAL */` 标记为“有意忽略写错误（design §7.6）”。
- 代价：`decoded_t` 加 1 位 `is_ret` → 面积 +65 µm²（4,242→4,307），频率基本不变（380.25→382.37 MHz）。仍在阶段 1 阈值内。

### 6.7 本窗追加：dc1024/lb32 的 stall 归因再测（临时探针，已清零）

- 探针同上（单拍 `dbg_dump` 由 AXI 退出写 B 握手 tag 触发，写 `build/dbg_probe.log`，文件中转不污染 make test/perf）；本轮**新增** `lsu_order`、`zn_dep`/`zn_fu`、`br_res`/`br_mis`、`iss_lsu` 四类计数。
  - `lsu_order` = 该拍 0 发射、且"最老 LSU 项操作数未就绪"而"存在更年轻且就绪的 LSU 项"——即 `iq.lsu_old` 顺序门控堵住的周期。
  - `br_mis` = BRU 解析拍 `b_i && b_mispred`（每次误预测 ⇒ 一次 flush）。
- 结果（占 cyc 比例）：

| 用例 | cycles | IPC | **lsu_order** | 误预测率→成本% | zn_dep | rob_full | iq_full | fe_empty | ifb_stall | D$ 命中 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| median | 12,381 | 0.562 | 2% | 22.7%→~24% | 17.8% | 9% | 0% | 30% | 8% | 78% |
| multiply | 24,100 | 0.901 | 0% | 9.7%→~14% | 3.5% | 1% | 0% | 34% | 1% | 73% |
| qsort | 301,353 | 0.464 | **21.9%** | 24.7%→~20% | 15.2% | 8% | 13% | 24% | 15% | **94%** |
| rsort | 242,634 | 0.807 | **35.4%** | 0.26% | 3.6% | 2% | 38% | 2% | 54% | 89% |
| towers | 10,058 | 0.525 | **39.0%** | 39%→~6.5% | 2.1% | 6% | 37% | 13% | 52% | 98% |
| vvadd | 6,855 | 0.660 | **29.7%** | 0.8% | 14.9% | 57% | 1% | 4% | 52% | 66% |

- **结论**：
  1. **`lsu_order` 是最大且最广的瓶颈**（rsort 35 / towers 39 / vvadd 30 / qsort 22）；且占"有就绪项却零发射"周期的 **96~99%**（qsort `zn_fu=68,366` ⊃ `lsu_order=65,939`）。根因是 `iq.lsu_old` 只允许"最老 LSU 项"发射。
  2. **误预测**集中在 median/qsort/towers/multiply（rsort/vvadd 几乎为 0）。
  3. **D$ 已非瓶颈**（命中 66~98%、replay 大降）；`MSHR_N=4`、`IQ32`、`ROB64/PRF128` 已证无收益。
- 探针清除三步验证：全树 `$display/$fopen` 归零；重建；**移除探针后 6 项 perf 周期与带探针时逐项完全一致**（GEOMEAN 0.6353）。

---

## §7 调试工具箱

- **黄金解释器**：`python3 tools/rv32golden.py testcases/<c>/program.data <max_insn> --ld`（**golden `--ld` 不含退出写**；先给 max_insn 再加 --ld）。
- **提交级对拍法（本窗定型）**：
  1) 探针：rob `DSP`（分配 rob）/`CMT`（提交 rob/rd/tag/ld/st）/`RWB`（a_ok 写回）；lsu_b 32bit `dbg_seq` + `LF/LV/FWD/LDACC/STACC`（STACC 嵌在 drain 接受点；rob 探针放 always_ff 的 non-reset 支）。
  2) 分析：`python3 build/win2_analyze_commit.py <probe.log> <golden_ld.txt>` → 已提交 load 按 rob 实例对齐 golden LD、STACC 对齐 golden ST；判据 = mismatch 0 且“无 LV 的已提交 load = 0”。
  3) `RWB` 只作辅证（**不证明提交**，§5C-4）。
- **逐周期不变证明**：见 §5D-4。
- **参数扫描模板**：`build/sweep_line.sh` / `build/sweep_mshr*.sh`（sed 改 cpu_pkg → test/perf/synth → 归档 → 恢复）；`build/mk_loopbench.py` 热分支环微基准。
- **单例跑法**：`make run PROGRAM=... EXPECTED=... MAX_CYCLES=20000000 LATENCY=10 LOG=build/x.log`；**带探针不要跑 make test/perf**；探针当天清（清零 `$display` + 重建 + 关键用例周期一致三步验证）。
- AppImage：`./cpu2026-tools-x86_64.AppImage exec /bin/sh -c '...'`；**沙箱看不到 `/tmp`**，临时文件放 `build/`。

---

## §8 命令速查

```sh
make build
make run  PROGRAM=testcases/<c>/program.data EXPECTED=$(cat testcases/<c>/expected.txt) MAX_CYCLES=20000000
make test SIM=build/sim MAX_CYCLES=20000000
make perf SIM=build/sim MAX_CYCLES=20000000
make synth MODE=opt            # 新流程（ABC -constr + buffering/sizing）；可选 ABC_DRIVING_CELL= / ABC_LOAD_FF=
make synth MODE=diagnose       # 层次化报告（热点定位）
sh build/run_all_ut.sh
sh verilog/stubs/run_ut.sh tb_lsu   # 亦可 tb_mul/tb_div/tb_stub_link/tb_be_link/tb_bp
```

---

## §9 工程纪律（硬性）

- 正式 RTL 禁 `$display/$write`；本地回归一律 `MAX_CYCLES=20000000`；每完成模块先过 `run_ut.sh`。
- `cpu_pkg.sv` 字段只增不删、改动前说明；`scripts/` 只读；**不要随手 commit**（改动累积后先给 diff 摘要）。
- `make synth MODE=opt` 必须无 ERROR / 无 latch / 无 `Resizing cell port`。
- **任何参数/宽度改动先证“默认逐周期不变”**，再扫新配置；扫描脚本恢复默认并重建。
- 交付以 Verilator 仿真为准。

---

## §10 回归与综合明细（口径：`make test/perf SIM=build/sim MAX_CYCLES=20000000`）

### 10.1 当前默认（WB_BYPASS=1 / ROB=32 / PRF=64 / DC_LINES=1024 / LINE_BYTES=32）

- correctness **19/19**：tak **1,251,867**、qsort **1,298,836**、pi **17,425,762**、queens **450,878**、magic 630,962、bulgarian 376,089、basicopt1 208,400、hanoi 6,454、superloop 545,933、gcd 404、add_to_100 459、array_test1 447、array_test2 497、expr 580、lvalue2 246、manyarguments 275、multiarray 2,508、naive 230、statement_test 1,224。
- perf **6/6，GEOMEAN 0.6353**：median 12,381/0.5622、multiply 24,100/0.9013、qsort 301,353/0.4642、rsort 242,634/0.8066、towers 10,058/0.5248、vvadd 6,855/0.6600。
- UT **6/6**。
- **新流程 synth**：4,306.8 µm²（组合 1,663.5 / 时序 1,267.3 / SRAM 1,375.9）、2.6152 ns → **382.37 MHz**；留档 `references/synth-history/2026-10-16-newflow-ipcwin-pipefetch-dc1024lb32-opt.json`。
- 上一窗基线（同流程，对照）：3,680.0 µm² / 2.6191 ns / 381.8 MHz，GEOMEAN 0.5492（`2026-10-16-newflow-base32-opt.json`）。

### 10.1b 本窗参数扫描（流水化后，`make run` 6 用例，GEOMEAN 为换算值）

| 配置 | GEOMEAN | qsort | rsort | 备注 |
|---|---:|---:|---:|---|
| 基线 256/16 | 0.5492 | 341,376 | 312,368 | 窗起点 |
| + 流水化 (256/16) | 0.5848 | 328,276 | 307,221 | 仅 fetch_unit |
| dc512/16 | 0.5929 | 314,701 | 294,985 | |
| dc1024/16 | 0.6226 | 283,965 | 244,148 | |
| dc2048/16 | 0.6253 | 283,145 | 238,411 | |
| **dc1024/32（采用）** | **0.6353** | 301,353 | 242,634 | 小用例最优 |
| dc1024/32 (lb32 单独) | 0.5848 | 328,276 | 307,221 | 流水化基线 |
| +IQ32 | ≈dc1024 | 284,347 | 244,803 | 无收益 |
| +ROB64/PRF128 | ≈dc1024 | 285,090 | 244,192 | 无收益 |

- 注：`DC_LINES` 非 2 的幂（如 1536）会越过 `sram_fakeram` DEPTH 触发 `RAM library error`。

### 10.2 备选配置（已测，未采用）

- ROB=64/PRF=128：19/19、UT 6/6、GEOMEAN 0.5491（rsort +0.14%）；旧流程 3,591.6 µm² / 11.5039 ns；**新流程 synth 30 分钟+ 未完成（综合爆炸）**。→ 不作为默认。

### 10.3 旧流程历史扫描（IPC 结论仍有效，面积/频率需重测）

- E7 LINE_BYTES 16 vs 32：32 行 IPC +0.4%（GEOMEAN 0.5224 vs 0.5201，BYPASS=0 时代）。
- E5 MUL_LAT 4 vs 2：IPC 无变化（乘法不在 perf 关键路径）。
- E4 IQ 16→32：IPC +0.06%（噪声级）。
- E8 MSHR_N（`2026-10-14-m4-mshr1/mshr4-opt.json`）：见 JSON。
- 本窗实测：同 set replay qsort ≥16,384 / rsort ≥20,480 次；MSHR 满 replay **0 次**；空闲表 ≤1 **从未发生**（PRF=64 与 ROB=32 恰好匹配）。

---

## §11 下一步优先事项（新窗口按序）

> **（本节任务已由 §13 完成并存档；新窗口任务改以 §14 + `docs/design.md §16` + `docs/impl-plan.md §13` 为准。）**

0. **启动核对（先跑）**：`make test` 19/19（tak=1,251,867、qsort=1,298,836、pi=17,425,762、queens=450,878）；`sh build/run_all_ut.sh` 6/6；`make perf` GEOMEAN **0.6353**（qsort 301,353 / rsort 242,634）；`make synth MODE=opt` 无 ERROR/latch/Resizing（预期 ≈4,307 µm² / ≈2.62 ns / ≈382 MHz）。任一不符先排干净。

1. **阶段 1 已达标**（面积 4,307 ≪ 9,000、频率 382.37 ≥ 300、IPC 0.6353 ≥ 0.6000）。本窗（新窗口）目标：按 §6.7 的归因结论，实施两项 IPC 优化并保持全量回归不退化。

2. **(A) LSU 顺序门控放宽（第一优先，见 §6.7：命中 rsort 35% / towers 39% / vvadd 30% / qsort 22% 的周期）**
   - **位置**：`verilog/backend/iq.sv` 的 LSU 选择门控（`lsu_v`/`lsu_old` 与 `case (FU_LSU)` 分支）。
   - **现状**：`lsu_old[i]` = 全局最老 live LSU 项，只允许它发射；当它操作数未就绪时，更年轻但已就绪的 load 被全部堵死。
   - **目标规则（保序）**：令 `st_ent[i]` = 该 LSU 项是 store；`store_head` = IQ 内最老的 **未发射** store（IQ 里的 store 项即"未发射"）；`st_head_age = rob_q[store_head] - rob_head`。
     - **store 项**：仅当自己是 `store_head` 时允许发射 ⇒ 所有 store 仍**按程序序**发射。
     - **load 项**：当 IQ 内无 store，或 `age(i) = rob_q[i]-rob_head < st_head_age` 时允许发射 ⇒ load 不会越过任何**尚未进入 STQ 的更老 store**。
     - 其余照旧：操作数就绪 + LDQ/STQ 有空间；**保持每拍最多 1 个 LSU**（选中后照旧 `lsu_ld=0; lsu_st=0`）。
   - **正确性论证（必须写进代码注释）**：任何 load 发射时所有更老 store 都已在 STQ（被"更老于最老未发射 store"约束）⇒ `lsu_b` 前递/阻塞（12bit 程序序 key，§7.2 三规则）能看到全部更老 store；store 程序序发射 ⇒ STQ 分配序=程序序；load 乱序不影响 STQ FIFO 排空与按 key 前递。flush：`kill[i]` 仍门控。**`in_ready` 不得依赖被发射的 op**（§5A-20 UNOPTFLAT）——新谓词只用 `v_q/fu_q/st_ent_q/rob_q/rob_head/lsu_free_*`，与 `in_valid` 无关，安全。
   - **已知保守边界**：若最老未发射 store 的操作数未就绪（如 store data 依赖一个 load），其后的 load 仍被堵——必要（该 store 地址/数据未知，无法判重叠）。
   - **验证**：`tb_lsu` 绿；`make test` 19/19（重点 tak/queens/hanoi flush 压测 + qsort/rsort 正确性）；`make perf` 记录四项访存类周期；LATENCY=1/50 压测；`make synth MODE=opt` 无 ERROR/latch/Resizing。预期 rsort/towers/vvadd +8~20%、qsort +5~10%。
   - 可与"每拍 2 个 LSU"叠加评估（但 D$ 单端口 + `lsu_b` 单 load 调度器是硬上限，先只放宽顺序、不加宽度）。

3. **(B) 分支预测升级（针对 median 22.7% / qsort 24.7% / towers 39% 误预测率，见 §6.7）**
   - **位置**：`verilog/frontend/bp.sv`（必要时 `decode`/`fetch_unit`）。
   - **第一步（参数化）**：`bp.sv` 现在**硬编码**——`initial $fatal` 强制 `BHT_ENTRIES==128 && BTB_ENTRIES==32`。先按 `$clog2(BHT_ENTRIES)/$clog2(BTB_ENTRIES)` 派生 index/tag 位宽，去掉该硬约束。
   - **第二步（gshare）**：BHT index = `pc[..] ^ ghr`（GHR 8~12 位，在 BRU 解析/提交处更新）；BTB→128、RAS→16。可选二级/锦标赛。
   - **Yosys 约束**：保持"数组 + reset for 循环"风格（"Replacing memory with registers" 警告正常）；**package 函数内不得引用 enum 常量**（§5A-9）；端口范围不得用体内 localparam（§5D-1）。
   - **验证**：同上；用探针 `br_mis`（§6.7 方式）复核误预测率下降。预期 median/qsort +5~10%、multiply/towers 小幅。

4. **不要再做**：I$ 关键字优先（§6.2 已否）；ROB64/PRF128 作为默认（§6.3 + 复测已否）；`MSHR_N=4`（零收益）；`IQ_DEPTH=32`（零收益）；D$ 继续加容量（已饱和，§6.7）；`DC_LINES` 取非 2 的幂（会崩）。

5. **频率（可选并行，+2/+4 分）**：382.37 → 400 MHz（需 −4.9% 周期）。读 `build/synth/opt/timing.rpt`，本窗关键路径 `_49235_/QN → _52607_/D`（未定位）；已知深链：IQ 唤醒/选择 CAM、rename 优先级编码、ROB 恢复扫描、LSU CAM。**先 `make synth MODE=diagnose` 定位**。注意切流水级可能给依赖链加 1 拍而掉 IPC，需权衡。

6. **文档/留档**：每步更新 `docs/handoff.md` 与 `references/synth-history/`；新流程 synth 报告存 `2026-10-16-newflow-ipcwin-*`。

7. **提交纪律**：仍未 git commit（等指示）。当前改动见 §6.5/§6.6。

---

## §12 新窗口启动提示词（直接复制）

```
继续 RISC-V CPU 的实现。阶段 1 已达标（面积 4,306.8 µm²≤9,000、频率 382.37 MHz≥300、IPC GEOMEAN 0.6353≥0.6000）。本窗口目标：按 handoff §6.7 的探针归因结论，实施两项 IPC 优化并保持全量回归不退化：(A) LSU 顺序门控放宽（iq.sv）优先；(B) 分支预测升级（bp.sv 参数化 + gshare）。先测量后动手。

先按顺序完整读完五份文档再动任何代码：
1) docs/handoff.md（§2 综合口径、§5 全部陷阱、§6.7 探针归因、§11 本窗任务(A)/(B)、§12 本文）；
2) docs/design.md（§2 框架硬约束、§4.3 flush 协议、§5 前端与 BP、§6 后端、§7 AXI/边界与访存、§13 参数矩阵）；
3) docs/impl-plan.md（M4/M5 任务表与验收命令）；
4) docs/axi4-lite.md；
5) references/synth-history/2026-10-16-notes.md（§11；该文面积/频率列有旧流程，仅 IPC/周期结论可沿用）。

启动核对（数字对表，任一不符先排干净）：make test SIM=build/sim MAX_CYCLES=20000000 应 19/19（tak=1,251,867、qsort=1,298,836、pi=17,425,762、queens=450,878）；sh build/run_all_ut.sh 应 6/6；make perf SIM=build/sim MAX_CYCLES=20000000 应 GEOMEAN=0.6353（qsort 301,353 / rsort 242,634）；make synth MODE=opt 无 ERROR/latch/Resizing（预期 ≈4,307 µm² / ≈2.615 ns / ≈382.37 MHz）。

任务（按序，详见 handoff §11）：
1. (A) 改 verilog/backend/iq.sv 的 LSU 发射门控：store 仅“最老未发射 store”可发；load 仅当其 age < 最老未发射 store 的 age（或 IQ 内无 store）可发；每拍仍最多 1 个 LSU。必须写保序论证注释（load 不越过未入 STQ 的更老 store）。预期 rsort/towers/vvadd +8~20%、qsort +5~10%。
2. (B) bp.sv 参数化（去掉 BHT=128/BTB=32 硬编码的 $fatal）+ gshare（GHR 8~12b）+ BTB→128/RAS→16；先测误预测率。预期 median/qsort +5~10%。
3. 需要 stall 归因时，按 §6.7 方式加“文件输出”临时探针（$fopen/$fwrite 到 build/dbg_probe.log，绝不污染 make test/perf 的 stdout），当天清零（清零 $display/$fopen + 重建 + 关键用例周期一致三步验证）。
4. 每步：make test（20M）+ run_all_ut.sh + make perf 六项 + make synth MODE=opt 冒烟留档 references/synth-history/；改动累积后展示 diff 摘要等指示，不随手 commit。

已知必读陷阱：handoff §5 全部（A 20 条 / B 5 条 / C 7 条 / D 9 条）。本窗新增重点：Yosys 0.63 不支持 package 函数内引用 enum 常量（用 decoded_t 字段）；探针 $display 会污染 test/perf 的 stdout（改文件输出）；DC_LINES 必须为 2 的幂；端口范围不得用体内 localparam；加宽必查窄连线。

工程纪律：RTL 禁 $display（探针除外且当天清）；回归一律 MAX_CYCLES=20000000；cpu_pkg 只增不删、改前说明；scripts/ 只读；行为等价改动先证默认逐周期不变（paste/diff 法），行为变更需说明并全量回归；不随手 commit。
```

---

## §13 本窗（2026-10-16 第二窗）：IPC 优化 (A) LSU 顺序门控放宽 + (B) 分支预测升级

> 口径：`make test/perf SIM=build/sim MAX_CYCLES=20000000`；综合 `make synth MODE=opt`（新流程 ABC -constr）。

### 13.1 结论先行

- **GEOMEAN 0.6353 → 0.6489（+2.1%）**：(A) 贡献 +0.06%（rsort −0.4%），(B) 贡献 +2.1%（median −12.3%）。
- **全量**：`make test` 19/19、UT 6/6、`make perf` 6/6、LATENCY=1/50 perf 12/12、`make synth MODE=opt` 无 ERROR/latch/Resizing。
- **本窗三元组**：**4,475.4 µm² / 2.6064 ns → 383.66 MHz**（报告 `2026-10-16-newflow-ipcwin-ab-tournament-opt.json`；面积 +3.9%、频率 +0.3% vs 上窗，仍远优于阶段 1 阈值；无 Resizing）。
- **未 git commit**（等指示）。

### 13.2 (A) LSU 顺序门控放宽（backend/iq.sv）——结论与预期相反，但已收口为非退化

- **实测否定了 §6.7 的乐观归因**（临时探针，AXI 退出写 B 握手触发，写 build/dbg_probe.log，已清零）：
  - 旧门控下 rsort 的 `lsu_order`（"最老 LSU 未就绪且存在更年轻就绪 LSU"）**绝大多数是"最老未发射 store 未就绪挡住更年轻 load"**：这是**必需的保序约束**（store 未入 STQ 时地址/数据未知，load 越过后前递/阻塞看不到它），**无法放宽**。
  - 因此 §6.7 的 `lsu_order`（rsort 35%/qsort 22%/vvadd 30%）**不等于可回收 stall**；qsort/vvadd 上放宽门控的额外可发项 **relax=0**。
- **尝试 1（任务原文直接放宽，选择仍走轮转）**：rsort **+3.8%（反而变慢）**。探针：多出 8,543 次"非最老 LSU 发射"，周期同步 +9,337（≈每次 1.1 拍）。根因：放松后**多个 LSU 项同时可发，轮转选择可能挑到更年轻的项，把最老（关键路径）的 LSU 推迟 1 拍**。
- **尝试 2（采用，收口）**：保留放宽谓词（store 仅"最老未发射 store"；load 仅当 `age < 该 store 的 age` 或 IQ 内无 store），**但加 `lsu_sel`：在"就绪且可发"的 LSU 项中只发最老者**（等价于旧行为优先，仅在"最老者不可发"时才让更年轻者顶上）。结果：**rsort 241,615（−0.4%）、其余五项逐周期不变**，GEOMEAN 0.6353→0.6357。
- 保序论证已写入 iq.sv 注释（load 发射时更老 store 必已在 STQ；store 严格按序入 STQ；更年轻 store 因退役顺序不可能先脏化）。

### 13.3 (B) 分支预测升级（cpu_pkg.sv + frontend/bp.sv + 全链 bix）——主贡献

- **误预测归因（探针，已清零）**：误预测**几乎全部来自条件分支方向**；返回/JALR（RAS/BTB 目标）已接近完美（towers 返回 5/69、qsort 2/3）→ 单纯 **BTB→128 / RAS→16 几乎零收益**（GEOMEAN 0.6357→0.6358）；主战场是**方向**。
- **参数化（等价性已证）**：bp.sv 去掉 `BHT==128/BTB==32` 的 `$fatal` 硬编码，BHT/BTB/RAS 位宽全部由 cpu_pkg 旋钮派生（RAS 指针/索引用 $clog2(RAS_DEPTH)，支持 16）。**默认 128/32/8 下 19 个 correctness 周期 + 6 项 perf 与旧 bp.sv 逐项完全相同**（paste/diff 通过）。
- **gshare 的坑（重要）**：直接"GHR 在 BRU 解析处更新、查表用当前 GHR"**严重变差**（qsort 误预测 24.8%→38.6%，GEOMEAN 0.6358→0.6169）。原因：某分支的**训练索引**（解析时 GHR）与**预测索引**（取指时 GHR）不一致，计数器被训练到别的格子。根因：gshare 要求"预测与训练用同一索引"。
- **正确实现（采用）**：
  1. **GHR 在取指顺序更新**（bp.sv 用新增"本拍取到的条件分支 + 预测方向"输入 `s0_cond/s0_pt/s1_cond/s1_pt`，按 fetch 程序序移位）；
  2. **把该分支查表用的 gshare 索引随指令携带到解析点**：cpu_pkg 新增 `fe2rn_t/renamed_t/issue_t.bix[9:0]`（只增字段），经 fetch_unit→rename→iq 透传到 core_ooo，BRU 用它做 BHT 训练 ⇒ 索引一致；
  3. **误预测时恢复 GHR**：由该分支携带的 bix 反推其取指时 GHR，再按其实际结果移位（更老分支必已正确预测，否则早已 flush）。
- **锦标赛（采用，解决 gshare 对 qsort 的伤害）**：gshare 单独使 median +14% 却使 qsort −7%（qsort 分支数据相关，pc-only 计数器反而不易被噪声 GHR 打散）。改为 **bimodal（pc 索引）+ gshare（pc^GHR）+ 每 pc 选择表**；两方向表同步训练，选择表向"预测正确的一方"靠拢。结果：**median −12.3%、qsort 回到中性（+0.5%）、towers 误预测 59%→30%**。
- **最终默认参数改动（值变更，未删字段）**：`BHT_ENTRIES 128→256`、`BTB_ENTRIES 32→128`、`RAS_DEPTH 8→16`；**新增** `BP_GHR_BITS=8`（0 = 退化为纯 bimodal）。BHI=8 时 GHR 8/10/12 等价（历史折入受索引位宽封顶）。

### 13.4 本窗默认回归明细（逐周期）

- correctness **19/19**：tak **1,253,500**、qsort **1,244,239**、pi **17,425,762**、queens **447,170**、magic 628,627、bulgarian 369,437、basicopt1 208,400、hanoi 6,046、superloop 537,120、gcd 404、add_to_100 459、array_test1 461、array_test2 500、expr 580、lvalue2 246、manyarguments 275、multiarray 2,443、naive 230、statement_test 1,233。
- perf **6/6，GEOMEAN 0.6489**：median **10,852/0.6414**、multiply 24,222/0.8968、qsort 302,470/0.4625、rsort 241,619/0.8100、towers 10,058/0.5248、vvadd 6,855/0.6600。
- UT **6/6**（tb_bp 改为随 cpu_pkg 尺寸派生 + 适配锦标赛 gshare 的 `up_ix/lk_ix` 接口）。
- LATENCY=1 GEOMEAN 0.7401；LATENCY=50 GEOMEAN 0.3921（12/12 PASS）。

### 13.5 本窗新增/踩坑（补充 §5）

- **gshare 一致性铁律**：BHT 训练索引必须等于该分支预测时用的索引（跨流水携带 bix），否则越训越差（qsort 实测 24.8%→38.6%）。GHR 必须在**取指程序序**推进，并在误预测时按该分支快照恢复。
- **IQ 轮转选择不是按年龄**：放宽门控使多个 LSU 同时可发后，轮转可能先挑更年轻项、推迟最老关键项（rsort +3.8%）。放宽类改动必须显式保证"最老优先"。
- **`$fatal` 硬编码结构性约束**（bp.sv）在参数化时必须一并去掉，且端口不得引用体内 localparam（沿用 §5D-1）；bix 这类跨流水新字段是"只增"契约，但需全链（fe2rn_t/renamed_t/issue_t + fetch/rename/iq/core_ooo）透传，漏一处即静默失配（性能问题，非功能错）。
- **stub 同步**：decoded_t/结构体加字段后 fe_stub.sv 的 '{...} 赋值模式要补新字段（本窗补 is_ret，否则 tb_stub_link 编译报 Assignment pattern missed initializing elements）。
- 临时探针一律 $fopen/$fwrite 到 build/dbg_probe.log（final 块），绝不污染 stdout；已全部清零（全树 $display/$fopen 0 处）。

### 13.6 本窗本地审查清理（行为等价/仅质量）

对未提交改动做了一次本地审查（聚焦 bp/前端），3 条全部清理并全量回归：

1. **GHR 恢复改为"任何误预测"都恢复**（原仅在条件分支误预测时恢复）：`core_ooo` 的 `br_upd_mispred = b_i && b_mispred`（对所有 BRU 解析），`bp` 改为 `if (up_mispred) ghr <= up_valid ? {ghr_rst[..], up_taken} : ghr_rst;`——JALR/JAL 误预测后错误路径的条件分支推进过的 GHR 也在该拍回滚（JALR 不额外移位）。修复前该污染会一直残留到下一次条件分支误预测。
2. **`bix` 携带位宽随 `BHT_ENTRIES` 派生**（`cpu_pkg` 三个结构体 + `bp/fetch_unit/core_ooo/student_top/tb_bp` 端口连线全部改 `$clog2(cpu_pkg::BHT_ENTRIES)-1:0`）：去掉"10 位/`10-BHI`"魔数，消除 `BHT_ENTRIES≥2048` 时的负复制/静默截断；曾因漏改 `fetch_unit.br_upd_ix`/`bp.up_ix` 端口触发 Yosys `Resizing cell port ... from 8 to 10`（**已修，最终 synth 无 Resizing**）。
3. **记录 GHR 生效上限**：`BP_GHR_BITS` 的有效历史 = `min(BP_GHR_BITS, log2(BHT_ENTRIES))`（BHT=256 时 >8 无额外区分位），注释已写明。

清理后：`make test` 19/19、UT 6/6、`make perf` 6/6 GEOMEAN **0.6489**（逐项与清理前相同）、`make synth MODE=opt` 无 ERROR/latch/**无 Resizing**（4,475.4 µm² / 2.6064 ns / 383.66 MHz）。

---

## §14 新窗口交接（阶段 2 冲刺：IPC GEOMEAN → 0.8450）

> §13 是上一窗（(A)/(B)）记录；本节是新窗口交接。**设计蓝本已先行增补：`docs/design.md §16`（阶段 2 冲刺设计，M6~M11）；排程：`docs/impl-plan.md §13`。**

### 14.1 当前基线（启动核对数字，任一不符先排干净）

- `make test SIM=build/sim MAX_CYCLES=20000000` 应 **19/19**：tak=**1,253,500**、qsort=**1,244,239**、pi=**17,425,762**、queens=**447,170**；其余见 §13.4（magic 628,627 / bulgarian 369,437 / basicopt1 208,400 / hanoi 6,046 / superloop 537,120 / multiarray 2,443 / statement_test 1,233 / add_to_100 459 / array_test1 461 / array_test2 500 / expr 580 / gcd 404 / lvalue2 246 / manyarguments 275 / naive 230）。
- `sh build/run_all_ut.sh` 应 **6/6**（注意 `tb_stub_link` 打印 `[tb_stub_link] ok:`，脚本 grep 不显示它——**无 `%Error` 即通过**；其余五个 ALL OK）。
- `make perf SIM=build/sim MAX_CYCLES=20000000` 应 **GEOMEAN=0.6489**（median 10,852/0.6414、multiply 24,222/0.8968、qsort 302,470/0.4625、rsort 241,619/0.8100、towers 10,058/0.5248、vvadd 6,855/0.6600）。
- `make synth MODE=opt` 应无 ERROR/latch/Resizing（**≈4,475.4 µm² / ≈2.6064 ns / ≈383.66 MHz**；留档 `references/synth-history/2026-10-16-newflow-ipcwin-ab-tournament-opt.json`）。
- LATENCY 口径备查：L=1 GEOMEAN 0.7401；L=50 GEOMEAN 0.3921（12/12 PASS）。

### 14.2 新窗口任务（按序；机制/验收细节一律以 `design.md §16` 为准）

1. **M6 测量先行**（P1 分支流离线建模定 TAGE 配置；P2 同拍双就绪 load + 同 bank/set 冲突率；P3 store-head 阻塞三归因（地址操作数/数据操作数/STQ 满）；P4 load→use 链占比）→ 产出决定 M7/M8/M9 的投入与配置。探针一律 `$fopen/$fwrite` 到 `build/dbg_probe.log`，**绝不污染 stdout**，当天清零（清零 + 重建 + 关键用例周期一致三步验证）。
2. **M7 TAGE**（`bp.sv`；携带字段 `bix` 扩宽全链透传）。门 **G1**：GEOMEAN ≥0.67 且 qsort 误预测 ≤16%。
3. **M8 store 地址早知 + load 门槛放宽**（`iq.sv`/`lsu_b.sv`；无投机版本；**必须重写保序论证注释 + 提交级 golden 对拍（qsort/rsort，`win2_analyze_commit.py` 方法）+ tak/queens/hanoi flush 压测**）。门 **G2**：GEOMEAN ≥0.72。
4. **M9 双发 LSU + 双读 D$**（`iq.sv`/`lsu_b.sv`/`dcache.sv`；同 bank 冲突 replay；MSHR→4 且每 set 2 项）。门 **G3**：GEOMEAN ≥0.76 且**频率 ≥320 MHz**（低于即重排或回退该步）。
5. **M10/M11** 按 `design.md §16.6/§16.7` 门控推进（load-use 降延迟必做；3 发射仅在 G3 未过时启动）；G4（≥0.845）不过则按 §16.7 降级路线。
6. 每步：`make test`（20M）+ `run_all_ut.sh` + `make perf` 六项 + `make synth MODE=opt` 冒烟留档 `references/synth-history/`；改动累积后展示 diff 摘要等指示，**不随手 commit**。

### 14.3 本窗新增陷阱合订（在 §5 全部之外）

1. **gshare 一致性铁律**：BHT 训练索引必须**等于该分支预测时用的索引**（跨流水携带，`bix`）；否则越训越差（qsort 实测 24.8%→38.6%）。GHR 必须在**取指程序序**推进、误预测时按携带索引恢复（**任何**误预测含 JALR 都恢复，JALR 不移位）。
2. **IQ 轮转选择不是按年龄**：放宽门控使多项可发后，轮转可能先挑年轻项、推迟最老关键项（rsort +3.8% 教训）；放宽类改动必须显式"最老优先"（`lsu_sel` 先例）。
3. **端口/连线宽度必须与 `cpu_pkg` 派生一致**：本窗 `bix` 改派生宽度时漏改 `fetch_unit.br_upd_ix`/`bp.up_ix` 触发 Yosys `Resizing cell port`（网表失真）；加宽必全树 grep 窄连线（§5D-2 方法）。
4. **`make synth` 会清掉 `build/sim`**（本窗实测踩过）：synth 之后必须先 `make build` 再跑 test/perf。
5. **结构体加字段后 stub 赋值模式要补**（`fe_stub.sv` 的 `'{...}` 漏 `is_ret` → `tb_stub_link` 编译失败；本窗已补）。
6. **`BP_GHR_BITS` 有效历史 = min(值, log2(BHT_ENTRIES))**（BHT=256 时 >8 无额外区分位；TAGE 表另计）。
7. **iq 现状**：`lsu_sel` = 就绪可发 LSU 中**最老者**（单 bit，每拍 ≤1 LSU）；`lsu_order` 的主体是"最老 store 未就绪挡住更年轻 load"（保序必需），M8 才是解药。

### 14.4 工程纪律（沿用 §9，另加两条）

- **访存语义变更（M8/M9）必须提交级 golden 对拍**（qsort/rsort）+ LATENCY=1/50 + flush 压测，缺一不算完成。
- **每步 synth 门禁**：面积 ≤18,000 µm²、频率 ≥320 MHz（护栏，阈值 300）；任一破线即停下重排（减表/减 MSHR/切级）或回退该里程碑（每里程碑独立可回退）。

### 14.5 新窗口启动提示词（直接复制）

```
继续 RISC-V CPU 的实现。阶段 1 已达标（IPC GEOMEAN 0.6489 / 面积 4,475.4 µm² / 383.66 MHz）。本窗口目标：按 docs/design.md §16 的阶段 2 冲刺计划，从 M6（测量先行）起步，逐里程碑推进（M7 TAGE → M8 访存乱序 → M9 双发 LSU/双读 D$，按 Go/No-Go 门 G1~G4），目标 IPC GEOMEAN ≥0.8450（阶段 2：面积 ≤18,000 µm²、频率 ≥300 MHz）。先测量后动手。

先按顺序完整读完五份文档再动任何代码：
1) docs/handoff.md（§13 上一窗记录、§14 本节、§5 全部陷阱、§9 纪律）；
2) docs/design.md（§2 框架硬约束、§4.3 flush 协议、§5 前端与 BP、§6 后端、§7 AXI/边界与访存、§16 阶段 2 冲刺设计）；
3) docs/impl-plan.md（§13 阶段 2 排程）；
4) docs/axi4-lite.md；
5) references/synth-history/2026-10-16-notes.md（§11/§12；面积/频率列以新流程留档为准）。

启动核对（数字对表，任一不符先排干净）：make test SIM=build/sim MAX_CYCLES=20000000 应 19/19（tak=1,253,500、qsort=1,244,239、pi=17,425,762、queens=447,170）；sh build/run_all_ut.sh 应 6/6（tb_stub_link 打 "[tb_stub_link] ok:"，无 %Error 即过）；make perf SIM=build/sim MAX_CYCLES=20000000 应 GEOMEAN=0.6489（median 10,852 / multiply 24,222 / qsort 302,470 / rsort 241,619 / towers 10,058 / vvadd 6,855）；make synth MODE=opt 无 ERROR/latch/Resizing（≈4,475 µm² / ≈2.606 ns / ≈383.7 MHz）。注意：make synth 会清掉 build/sim，synth 后先 make build 再跑 test/perf。

任务（按序，详见 handoff §14.2 / design §16）：
1. M6 探针测量：P1 分支流离线建模（定 TAGE 配置）；P2 同拍双就绪 load + 同 bank/set 冲突率；P3 store-head 阻塞三归因（地址操作数/数据操作数/STQ 满）；P4 load→use 链占比。探针一律 $fopen/$fwrite 到 build/dbg_probe.log，绝不污染 make test/perf 的 stdout，当天清零（清零 $display/$fopen + 重建 + 关键用例周期一致三步验证）。
2. M7 TAGE（bp.sv；携带字段扩宽全链透传；门 G1：GEOMEAN ≥0.67 且 qsort 误预测 ≤16%）。
3. M8 store 地址早知 + load 门槛放宽（iq/lsu_b；无投机；必须重写保序论证注释 + 提交级 golden 对拍 qsort/rsort + tak/queens/hanoi flush 压测 + LATENCY=1/50；门 G2：≥0.72）。
4. M9 双发 LSU + 双读 D$（iq/lsu_b/dcache；同 bank 冲突 replay；门 G3：≥0.76 且频率 ≥320 MHz）。
5. 每步：make test（20M）+ run_all_ut.sh + make perf 六项 + make synth MODE=opt 冒烟留档 references/synth-history/；改动累积后展示 diff 摘要等指示，不随手 commit。

已知必读陷阱：handoff §5 全部（A20/B5/C7/D9）+ §13.5/§14.3 新增（gshare 一致性铁律；IQ 轮转非按年龄须显式最老优先；端口宽度与 cpu_pkg 派生一致否则 Yosys Resizing；make synth 清 build/sim；结构体加字段 stub 赋值模式要补）。

工程纪律：RTL 禁 $display（探针除外且当天清）；回归一律 MAX_CYCLES=20000000；cpu_pkg 只增不删、改前说明；scripts/ 只读；行为等价改动先证默认逐周期不变（paste/diff 法）；行为变更需说明并全量回归，访存语义变更必须提交级 golden 对拍；不随手 commit。
```

---

## §15 本窗（2026-10-17）：M6 测量先行 + M8 访存乱序（store 地址早知）——G2 通过

> 口径：`make test/perf SIM=build/sim MAX_CYCLES=20000000`；综合 `make synth MODE=opt`（新流程）。**M7（TAGE）经 M6 判定为 No-Go 未实施**，理由见 §15.2。

### 15.1 启动核对与 §14.1 数字修正

- `make test` **19/19**、`run_all_ut.sh` **6/6**、`make perf` **GEOMEAN 0.6489**（六项与 §14.1 逐项相同）、`make synth MODE=opt` **4,475.431 µm² / 2.6064 ns / 383.66 MHz** 无 ERROR/latch/Resizing —— 与 §14.1 完全一致。
- **唯一不符：§14.1 的部分 correctness 周期数**（tak/qsort/queens/magic/bulgarian/multiarray）。**已排干净**：根因是 §13.6 审查清理第 1 条（GHR 在**任何**误预测（含 JALR）都恢复）。本窗实测：临时把该子句退回"仅条件分支误预测恢复"→ tak **1,253,500**、qsort **1,244,239**，与 §13.4/§14.1 逐字一致；带该子句（当前树）→ tak 1,249,782 / qsort 1,246,622。两者 **perf 逐项全等（0.6489）**、19/19 均 PASS。即 §14.1 抄录的是清理**前**的 correctness 周期；**当前树（含清理）为正确终态**，本节起以当前树为准。

### 15.2 M6 四探针测量（临时探针，AXI 退出写 B 握手/文件输出；已清零三步验证）

探针：core_ooo P1（提交序条件分支流 `B pc tk pt mis`）、lsu_b P2（同拍双就绪 load + 同 set/同 bank）、iq P3（store-head 三归因）+ P4（依赖 stall 的 load-use 占比）；一律 `$fopen/$fwrite` → `build/dbg_probe.log`（每次写 `$fflush` 防多句柄交错）。清零验证：全树 `$display/$fopen/$fwrite` 归零 + 重建 + 6 项 perf 逐周期与带探针时全等（GEOMEAN 0.6489）。原始 log 与离线模型脚本：`/tmp/kilo/m6_probe_raw.log`、`build/m6_branch_model.py`。

**P1 分支流离线建模（程序序，方向）** —— 对同一 trace 重放 bimodal/gshare/锦标赛/多组 TAGE/局部历史：

| 用例 | 机器 mis% | 锦标赛(复现) | bimodal256 | gshare8 | 最佳 TAGE |
|---|---:|---:|---:|---:|---:|
| median | 13.02 | 15.82 | 20.84 | 23.91 | 17.7 |
| multiply | 9.99 | 9.42 | 9.18 | 10.76 | 9.1 |
| qsort | 27.37 | 25.70 | **24.47** | 36.72 | 25.0 |
| rsort | 0.25 | 0.26 | 0.25 | 1.93 | 0.26 |
| towers | 32.88 | 27.99 | 41.03 | 36.96 | 27.99 |
| vvadd | 0.46 | 0.46 | 0.46 | 2.46 | 0.46 |
| 均值 | — | **13.27** | 16.04 | 18.79 | ≥14.0 |

- **qsort/median 条件分支方向基本不可约**：qsort 上 bimodal(24.47%) 已优于一切历史预测器，TAGE/局部历史均 ≥25%（数据相关分支，历史只会引入噪声）；towers 靠锦标赛的 choice 选 gshare 才从 41% 降到 28%。
- **结论：任何方向预测器都无法把 qsort 压到 ≤24%，G1 的"qsort 误预测 ≤16%"不可达**；且我对全部 TAGE 变体（短/长历史、1k~4k 表、8~10b tag）实测均值 ≥ 现有锦标赛。"预测"一项在阶段 2 无可回收空间。

**P2 LSU 并行度**（`dual_go`=同拍 ≥2 条可发内存 load 的周期；`samebank`=其中最老两条同 D$ bank（同 word 索引）即硬冲突）：

| 用例 | cyc | dual_go | dual_go% | samebank | samebank/dual |
|---|---:|---:|---:|---:|---:|
| median | 10,852 | 4,484 | 41.3% | 222 | 5.0% |
| multiply | 24,222 | 847 | 3.5% | 48 | 5.7% |
| qsort | 302,470 | 29,918 | 9.9% | 3,824 | 12.8% |
| rsort | 241,619 | 37,532 | 15.5% | 3,297 | 8.8% |
| towers | 10,058 | 1,224 | 12.2% | 0 | 0% |
| vvadd | 6,855 | 2,929 | 42.7% | 0 | 0% |

- D$ 数据阵列为**按字分 bank**（每个 line word 一个 1RW SRAM，共 8 bank）。同 set 但不同字 = 不同 bank，可并行；**同 bank 冲突仅占可双发周期的 0~13%** → M9 双读 D$ 的收益大部分可落地（>87% 的双发周期不撞 bank）。

**P3 store-head 阻塞三归因**（`notissued`=最老 store 当拍未发；`data_nr`=rs1(地址)就绪但 rs2(数据)未就绪；`yload_when_data_nr`=其中同时存在"更年轻且就绪的 load"被堵——**M8 的直接上限**）：

| 用例 | 占比 cyc | notissued | addr_nr | data_nr | stq_full | yload_when_data_nr |
|---|---:|---:|---:|---:|---:|---:|
| qsort | 40.0% | 120,958 | 2,467 | **116,997** | 2 | **96,170 (31.8%)** |
| rsort | 79.5% | 192,164 | 47,467 | **143,508** | 1,030 | **121,603 (50.3%)** |
| towers | 74.4% | 7,488 | 957 | **5,219** | 1,078 | **4,833 (48.0%)** |
| vvadd | 55.8% | 3,824 | 0 | **3,824** | 0 | **3,782 (55.2%)** |
| median | 24.6% | 2,674 | 0 | 2,619 | 0 | 819 (7.5%) |
| multiply | — | 1 | 0 | 0 | 0 | 0 |

- **主导原因 = store 数据(rs2)未就绪**（非地址、非 STQ 满）；且堵住的正是更年轻的就绪 load → M8"store 地址早知、数据后填"是最大且最广的杠杆。

**P4 依赖链 load-use 占比**（`zerodep`=零发射且有操作数未就绪；`zerodep_load`=其中至少一个未就绪来自在飞 load(LDQ)；`zerodep_onlyload`=**全部**未就绪操作数都是在飞 load）：

| 用例 | zerodep | zerodep_load | zerodep_onlyload | only/zero |
|---|---:|---:|---:|---:|
| median | 2,798 | 2,798 | 2,309 | 82.5% |
| multiply | 595 | 595 | 398 | 66.9% |
| qsort | 103,319 | 103,319 | 44,104 | 42.7% |
| rsort | 95,764 | 95,750 | 2,921 | 3.1% |
| towers | 4,514 | 4,116 | 194 | 4.3% |
| vvadd | 3,178 | 3,178 | 1,102 | 34.7% |

- 依赖 stall 中"涉及 load"的占比 ~100%（load 是普遍的长延迟源）；"纯 load-use"（M10 load-use 降延迟的可回收量）median/vvadd 显著（~35~83%），rsort/towers 很小。

### 15.3 M7（TAGE）判定：**G1 No-Go，未实施**

- G1 要求 qsort 误预测 ≤16%，而 M6/P1 实测任何方向预测器的 qsort 下界 ≈24%（数据相关分支，不可约）→ G1 结构上不可达；且 TAGE 全变体均值不优于现有锦标赛。按 design §16.7"仍不过则压缩投入直推 M8"，**跳过高成本 TAGE 实施**（宽 `bix` 全链透传 + 大表），直接把投入放 M8。（若后续仍要 TAGE，M6 trace 与离线模型可直接复用选型。）

### 15.4 M8：store 地址早知 + load 门槛（无投机）——**G2 通过**

**改动（4 文件 + 1 stub）**：
- `cpu_pkg.sv`：`issue_t` **只增**字段 `logic rs2_ready`（store 的 rs2 值是否当拍有效）。
- `backend/iq.sv`：store 发射门槛由"rs1∧rs2 就绪"放宽为**仅 rs1 就绪**（load 仍 rs1∧rs2）；携带 `rs2_ready`；**保序论证注释已按 M8 重写**（load 发射时所有更老 store 的地址均已知且已在 STQ，重叠判定完整；数据未就绪只改前递来源、不改"是否要等"）。
- `backend/core_ooo.sv`：把 `l_iss.ps2 / l_iss.rs2_ready` 与**合格写回总线 `ba_ok/bb_ok`** 接给 lsu_b。
- `memory/lsu_b.sv`：STQ 新增 `s_dvalid`/`s_ps2`/`s_f3`；store 分配时按 `in_rs2_ready` 决定数据是否即时落地；**写回总线 CAM 迟到回填**（匹配 `s_ps2` 的合格 WB → `s_data=stsh(wb.result)`、`s_dvalid=1`）；**drain 门槛 = 退役 ∧ s_dvalid**；**前递只在 `s_dvalid` 时成立，否则按 §7.2 规则 2 阻塞**。store ROB done 时机不变（AGU 即 done；提前退役安全性不变：store 无寄存器结果，内存副作用由 STQ 退役后 FIFO drain 保证）。
- `stubs/tb_lsu.sv`：绑定 `in_rs2_ready=1`、`ps2=0`、`wb=0`（定向用例数据即时有效）。

**验收**：
- `make test` **19/19**（tak 1,250,250 / qsort 1,269,616 / pi 15,609,411 / queens 446,416 …）；`run_all_ut.sh` **6/6**。
- **提交级 golden 对拍**（`win2_analyze_commit.py`，qsort/rsort）：qsort 已提交 load **31,033/31,033、0 mismatch**、store **0 mismatch**、无 LV/无 RWB 的已提交 load = 0；rsort 已提交 load **37,902/37,902、0 mismatch**、store 0 mismatch。
- **flush 压测**：tak/queens/hanoi 在 LATENCY=1/50 全 PASS；`LATENCY=1` perf **12/12 PASS**（GEOMEAN 0.8470）、`LATENCY=50` **12/12**（0.4146）。
- **perf（LATENCY=10）**：median 10,833 / multiply 24,222 / qsort **293,199** / rsort **176,713** / towers **9,343** / vvadd **5,321** → **GEOMEAN 0.7259**（0.6489→+11.9%；rsort −26.9%、vvadd −22.4%、towers −7.1%、qsort −3.1%）。**G2（≥0.72）通过**。
- **synth**：**4,270.640 µm² / 1.4883 ns → 671.92 MHz**，无 ERROR/latch/Resizing（留档 `references/synth-history/2026-10-16-newflow-m8-storeaddr-opt.json` + `-timing.rpt`）。**意外且可复现**：面积反而 −205 µm²、关键路径 2.6064→1.4883 ns（ABC 明显绕开了旧的 store-data 关键锥）；建议复核 timing.rpt。若属实，**同时满足阶段 2 频率门槛并触发 400/500 MHz 加分**。

### 15.5 M8 后状态与下一步

- 当前：correctness 19/19、UT 6/6、`make perf` **0.7259**、综合 **4,270.6 µm² / 671.92 MHz**（阶段 2：面积 ≤18,000 ✓、频率 ≥300（>500）✓、IPC 0.7259 < 0.8450 未达）。
- **M9（双发 LSU + 双读 D$，门 G3 ≥0.76 且频率 ≥320）尚未开始**。M6/P2 显示 M9 有据（同 bank 硬冲突仅 0~13%）；但 M9 是访存内核级改动（D$ 双读口 + 双 load 调度 + IQ 每拍 2 LSU），风险高，需按 design §16.5 全链实现 + golden 对拍 + flush 压测。
- 探针本窗已全部清零并三步验证。
- **未 git commit**（等指示）。

### 15.6 追加：M8 综合异常核查 + M8 diff 独立审查（步骤 0）

**(A) 频率 671.92 MHz 的核查（结论：可复现但属 ABC 映射方差，非架构性提速）**
- 流程完整、确定性：两次 `make synth MODE=opt` 逐位一致（4,270.640 µm² / 1.4883 ns / 671.92 MHz），无 ERROR/latch/Resizing，SRAM 面积/模块树正常（非黑盒）。
- **隔离实验**：临时把 `iq` 的 store 门槛退回"需 rs1∧rs2 就绪"（lsu_b 的 M8 改动仍在，但此时 `s_dvalid≡1` ⇒ lsu_b 行为与原版等价、新增逻辑退化为常量）→ synth **4,253.159 µm² / 1.6182 ns / 617.98 MHz**。仍是基线（383.66 MHz）的 1.6 倍。⇒ 频率跃升**不来自 iq 放宽**，而来自 **lsu_b 网表扰动**；且被扰动的"功能等价"网表也给出 618 MHz。
- 对照 §2 先例（同一 RTL 旧流程 93.5 MHz ↔ 新流程 381.8 MHz），结论：**新 ABC（buffering + cell sizing）对网表扰动极敏感，383→672 MHz 是映射方差**。当前提交 RTL 的官方口径值就是 **671.92 MHz**（可复现、按口径有效），但**不可假定它能挺过无关的后续 RTL 改动**——频率加分策略不要押在它稳定上。
- 已恢复 iq 并重建：`make perf` 仍 **0.7259**。

**(B) M8 diff 独立审查（`iq.sv`/`lsu_b.sv`/`core_ooo.sv`/`cpu_pkg.sv`）——未发现正确性缺陷**
- 逐项核对：store 数据迟到（`s_ps2`+`s_dvalid`+WB CAM）与 issue 当拍写回（bypass 使 `rs2_ready=1`、值取自总线）无缝隙；`ps2=0`(x0) 恒 `rs2_ready=1`；生产者被杀 ⇒ store 必被杀（生产者更老）⇒ 无孤儿；同拍分配与 CAM 回填不冲突；`stsh` 晚填的 off/f3 用 `s_addr/s_f3`，与分配期一致；前递仅在 `s_dvalid[best]`（全覆写）成立，否则 `blk`（§7.2 规则 2）；drain 门槛、flush kill、`ndone`/提前退役均未变。
- `make build` 的 7 条 LATCH 告警与 M8 前**逐数相同**（均为 `lsu_b` 前递 `always_comb` 内块局部临时变量，Verilator 良性的假阳性）；**`make synth` 无 latch、无 UNOPTFLAT**。lsu_b 新增的 `wb_a/wb_b` 只用于 `always_ff` 次态，无组合环。
- 结论：M8 保持合并状态。

---

## §16 新窗口交接（2026-10-17：M8a load 早写回 → M8b 误预测代价 → M9 双发）

> §15 是上一窗（M6+M8）记录；本节是新窗口交接。**路线已按 M6 实测修订，蓝本以 `docs/design.md §16.9` 为准**（M7 TAGE No-Go；M8 已落地）。

### 16.1 当前基线（启动核对数字，任一不符先排干净）

- RTL 状态 = commit `1a855fe`（已推 origin/main）+ 本窗未提交的文档改动（design/impl-plan/handoff）。`cpu_pkg`：`WB_BYPASS=1 / ROB=32 / PRF=64 / IQ=16 / LDQ/STQ=8 / MSHR_N=2 / LINE_BYTES=32 / DC_LINES=1024 / BHT=256 / BTB=128 / RAS=16 / BP_GHR_BITS=8`；`issue_t` 新增 `rs2_ready`（M8）。
- `make test SIM=build/sim MAX_CYCLES=20000000` 应 **19/19**：tak=**1,250,250**、qsort=**1,269,616**、pi=**15,609,411**、queens=**446,416**；其余：magic 624,034 / bulgarian 356,233 / basicopt1 208,371 / hanoi 5,793 / superloop 537,110 / multiarray 1,954 / statement_test 1,212 / add_to_100 459 / array_test1 451 / array_test2 499 / expr 575 / gcd 401 / lvalue2 232 / manyarguments 263 / naive 216。
- `sh build/run_all_ut.sh` 应 **6/6**（`tb_stub_link` 打 "[tb_stub_link] ok:"，无 %Error 即过）。
- `make perf SIM=build/sim MAX_CYCLES=20000000` 应 **GEOMEAN=0.7259**（median 10,833/0.6426、multiply 24,222/0.8968、qsort 293,199/0.4772、rsort 176,713/1.1076、towers 9,343/0.5649、vvadd 5,321/0.8502）。
- `make synth MODE=opt` 应无 ERROR/latch/Resizing（**≈4,270.6 µm² / ≈1.4883 ns / ≈671.9 MHz**；留档 `references/synth-history/2026-10-16-newflow-m8-storeaddr-opt.json`。**注意 ABC 映射方差**：功能等价网表可差 383↔618↔672 MHz（§15.6A），勿把 672 当稳定资产，护栏按 ≥320 计）。
- LATENCY 口径备查：L=1 GEOMEAN **0.8470**、L=50 **0.4146**（perf 12/12 PASS；tak/queens/qsort/hanoi correctness 子集 L1/L50 全 PASS）。
- golden 基线：qsort 已提交 load **31,033**、rsort **37,902**，均 0 mismatch（§15.4）。

### 16.2 新窗口任务（按序；机制/门以 design §16.9 为准）

0. **启动核对**（§16.1）。
1. **复测探针（~半天，当天清零三步验证）**：post-M8 重跑 P2（同拍双就绪 load + 同 bank 冲突）与 P4（load-use 占比——**必须用 LDQ 派生的在飞 load 掩码**（lsu_b 输出 dbg 位图→iq 输入），不能在 IQ 本地记账：被杀 load 永不写回 → 位泄漏 → 指标退化为 100%）；**新增 P5**（同线 guard：被堵 load 中"仅同线、无重叠"的拍数与占比——决定 M9c 是否做）与 **P6**（误预测代价：BRU 解析拍 → 正确路径首条指令发射拍的直方图——校准 M8b 收益）。探针一律 `$fopen/$fwrite` 到 `build/dbg_probe.log`，**每次 `$fwrite` 后 `$fflush`**（多句柄写同一文件会撕裂行，本窗踩过），绝不污染 stdout。
2. **M8a：load 早写回（消 2 拍 load-use）——本窗第一优先**。现路径：D$ resp 拍 T → `l_st/l_data` 寄存 → `wb_hv` 保持寄存 → **T+2 上 BB** → 消费者 T+2 发射（WB_BYPASS）。改：resp（及 store 前递 `sc_fwd/f_data`）完成拍**组合直通 BB**。要点：`wb_hv` 保留为同拍双完成（resp+前递）兜底与仲裁败者路径；早写回**同拍释放 LDQ 项**（恰好一次，防双写回/漏写回）；kill 过滤沿用 `l_valid∧SENT∧rob 匹配`（被杀 load 的早写回会被 ROB 过滤成 reclaim，语义同 §5C-1，需复核 tag-0 分支）；BB 优先级 early-LSU > hold-LSU > MUL > ALU1（`alu1_grant` 等连带）；M8 的 store 数据回填走 `bb_ok`，自动提前 2 拍。**不改访存数值语义**（golden 应仍 0 mismatch）。门 **GA：GEOMEAN ≥0.78**（预期 ~0.79）。验收：全量回归 + golden（qsort/rsort）+ LATENCY=1/50 + synth 留档（新组合路径 D$resp→ldext→BB→IQ CAM 可能成为关键路径，护栏 ≥320）。
3. **M8b：误预测代价 −1 拍**。flush/kill 广播**不动**（§4.3 寄存 1 拍是全链不变式）；仅把 **FE 的 pc 重定向提前到 BRU 解析拍**（组合送 target）；解析拍~广播拍之间取到的错路径块当拍丢弃（push 抑制一拍）；`bsf` 一致性与 IFB 截断重证（fetch_unit 头注释 + §5D-9 必读）。门 **GB：≥0.80**。
4. **M9：双发 LSU + 双读 D$**（§16.5/§16.9）：D$ 数据 bank 复制双份（写双副本，SRAM +≈1.4k µm²）、同 bank（同 word 索引）冲突 replay、`MSHR_N→4` 且每 set 2 项、IQ 每拍 ≤2 LSU（**最老优先**，沿用 `lsu_sel` 教训）、store 仍严格程序序。门 **GC：≥0.84 且频率 ≥320 MHz**。访存内核级改动：全量 golden + flush 压测 + LATENCY=1/50 缺一不可。
5. **M9c（门控）**：同线 guard 放宽——仅当 P5 显示占比大；只有 load **miss** 分配路径存在竞态（hit 不需要 guard），需把 guard 挪到 A 侧或传 hit/miss，并重证 §7.2 注的失效竞态。
6. 每步：`make test`（20M）+ `run_all_ut.sh` + `make perf` 六项 + `make synth MODE=opt` 冒烟留档 `references/synth-history/`；改动累积后展示 diff 摘要等指示，**不随手 commit**。

### 16.3 本窗新增陷阱合订（在 §5/§13.5/§14.3 之外）

1. **ABC 频率映射方差（§15.6A）**：新流程下功能等价网表可差 383↔618↔672 MHz；频率数字只作当次留档口径，**不要**作为可依赖资产或优化目标（护栏 ≥320 计）。
2. **探针多句柄写同一文件会撕裂行**：不同模块各自 `$fopen("...","a")` 的缓冲区会在 flush 时交错；**每次 `$fwrite` 后 `$fflush`**，或每模块独立文件。
3. **"在飞 load 集合"必须从 LDQ 派生**（lsu_b 组合输出位图→iq 探针输入）：IQ 本地按"dispatch 置位/WB 清零"记账会被"被杀 load 永不写回"泄漏污染（本窗实测退化为 zerodep_load==zerodep）。
4. **§14.1 的 correctness 周期数已被 §15.1 修正**（§13.6 GHR 恢复清理晚于该数字；两版 perf 全等）。新窗口一律以 §16.1 数字对表。
5. **Verilator 7 条 LATCH 告警为良性假阳性**（`lsu_b` 前递 `always_comb` 块内局部临时变量，M8 前后逐数相同）；判据以 `make synth` 无 latch 为准。
6. **M8 不变式（动 `lsu_b`/`iq` 前必背）**：store 仅 rs1 就绪即发射（数据可后到）；STQ `s_dvalid/s_ps2/s_f3` + `ba_ok/bb_ok` CAM 回填；drain=退役∧`s_dvalid`；前递仅 `s_dvalid[best]` 且全覆盖，否则 §7.2 规则 2 阻塞；load 门槛="早于最老未发射 store"（单 LSU+最老优先下等价于"早于最老地址未知 store"）。
7. `iq.sv` 的 `bix_q` 仍是字面量 `[9:0]`（bix 实为 8b 派生）：BHT=256 下无害；若未来 BHT>1024 需全链改派生（M7 已 No-Go，低优先）。
8. **不要用字符串脚本批量改 `verilog/memory/lsu_b.sv`**（本窗曾因 python 替换误操作致文件重复损坏，靠字节级重建恢复；一律用编辑工具逐处改）。

### 16.4 工具/口径备忘

- **golden 重生成（已验证逐行一致）**：`python3 tools/rv32golden.py testcases/perf_qsort/program.data 200000 --ld > build/win2_qsort_golden_ld.txt`（rsort 同理；现存量 qsort 31,033 LD / 13,750 ST）。`build/` 被 gitignore，`make clean` 后须重生成。
- 提交级对拍：`python3 build/win2_analyze_commit.py build/dbg_probe.log build/win2_qsort_golden_ld.txt`（探针行格式 `TAG <cyc> key=val...`，即**周期是裸 token**，不是 `cyc=N`；探针在 rob（DSP/CMT/RWB）与 lsu_b（LF/LV/FWD/STACC），写法可参考 §15.4 的实现记录）。
- 分支流离线模型：`build/m6_branch_model.py`（bimodal/gshare/锦标赛/TAGE/oracle；输入 P1 的 `B pc tk pt mis` 提交流）。M7 已 No-Go，仅存档用。
- 单例跑法/参数扫描/逐周期不变证明：见 §7/§8；`make synth` 会清 `build/sim`，synth 后先 `make build`。

### 16.5 新窗口启动提示词（直接复制）

```
继续 RISC-V CPU 的实现（阶段 2 冲刺）。M6 测量与 M8（store 地址早知）已完成：IPC GEOMEAN 0.7259 / 面积 4,270.6 µm² / 671.92 MHz（注意：频率含 ABC 映射方差，勿当稳定资产，见 handoff §15.6A）。本窗口目标：按 docs/design.md §16.9 修订路线冲 IPC——第一优先 M8a「load 结果响应拍直通 BB（消 2 拍 load-use）」，其次 M8b「误预测代价 −1 拍」，再 M9「双发 LSU + 双读 D$」，目标 GEOMEAN ≥0.8450（阶段 2：面积 ≤18,000 µm²、频率 ≥300 MHz，护栏 ≥320）。先测量后动手。

先按顺序完整读完五份文档再动任何代码：
1) docs/handoff.md（§15 上一窗记录、§16 本节、§5 全部陷阱、§9/§14.4 纪律）；
2) docs/design.md（§2 框架硬约束、§4.3 flush 协议、§4.4 写回总线、§5 前端与 BP、§6 后端、§7 AXI/边界与访存、§16 阶段 2（§16.9 修订路线优先）；
3) docs/impl-plan.md（§13 排程 + 修订指引）；
4) docs/axi4-lite.md；
5) references/synth-history/2026-10-16-notes.md（§11/§12；面积/频率以新流程留档为准）。

启动核对（数字对表，任一不符先排干净）：make test SIM=build/sim MAX_CYCLES=20000000 应 19/19（tak=1,250,250、qsort=1,269,616、pi=15,609,411、queens=446,416）；sh build/run_all_ut.sh 应 6/6（tb_stub_link 无 %Error 即过）；make perf SIM=build/sim MAX_CYCLES=20000000 应 GEOMEAN=0.7259（median 10,833 / multiply 24,222 / qsort 293,199 / rsort 176,713 / towers 9,343 / vvadd 5,321）；make synth MODE=opt 无 ERROR/latch/Resizing（≈4,270.6 µm² / ≈1.488 ns / ≈672 MHz）。注意：make synth 会清 build/sim，synth 后先 make build 再跑 test/perf。

任务（按序，详见 handoff §16.2 / design §16.9）：
1. 复测探针（~半天，当天清零三步验证）：post-M8 重跑 P2/P4（P4 的在飞 load 集合必须从 LDQ 派生，不能在 IQ 本地记账）；新增 P5（同线 guard 无重叠阻塞占比）与 P6（误预测代价直方图）。探针一律 $fopen/$fwrite 到 build/dbg_probe.log 且每次 $fwrite 后 $fflush，绝不污染 stdout。
2. M8a：lsu_b 的 load 完成（D$ resp 与 store 前递）在完成拍组合直通 BB，消 2 拍 load-use；wb_hv 保留兜底（同拍双完成仲裁）；早写回同拍释放 LDQ（恰好一次）；kill 过滤沿用 l_valid∧SENT∧rob 匹配；BB 优先级 early-LSU > hold-LSU > MUL > ALU1；不改访存数值语义。门 GA：GEOMEAN ≥0.78。验收：make test + UT + make perf + 提交级 golden（qsort/rsort，应仍 0 mismatch）+ LATENCY=1/50 + synth 留档（新组合路径注意频率护栏）。
3. M8b：误预测代价 −1 拍（FE pc 重定向提前到 BRU 解析拍；flush/kill 广播协议 §4.3 不变；错路径块当拍丢弃；bsf/IFB 截断重证）。门 GB：≥0.80。
4. M9：双发 LSU + 双读 D$（D$ bank 复制双副本写双份；同 bank=同 word 索引冲突 replay；MSHR_N→4 且每 set 2 项；store 仍严格程序序；IQ 每拍 ≤2 LSU 且最老优先）。门 GC：≥0.84 且频率 ≥320 MHz。全量 golden + flush 压测 + LATENCY=1/50。
5. 每步：make test（20M）+ run_all_ut.sh + make perf 六项 + make synth MODE=opt 冒烟留档 references/synth-history/；改动累积后展示 diff 摘要等指示，不随手 commit。

已知必读陷阱：handoff §5 全部 + §13.5/§14.3 + §15.6/§16.3 新增（gshare 一致性铁律；IQ 轮转非按年龄须显式最老优先；端口宽度与 cpu_pkg 派生一致否则 Yosys Resizing；make synth 清 build/sim；结构体加字段 stub 赋值模式要补；ABC 频率映射方差；探针多句柄写同一文件须 $fflush；M8 不变式——store 仅 rs1 发射、数据经 ba_ok/bb_ok CAM 回填、drain=退役∧dvalid、前递仅 dvalid）。

工程纪律：RTL 禁 $display（探针除外且当天清）；回归一律 MAX_CYCLES=20000000；cpu_pkg 只增不删、改前说明；scripts/ 只读；行为等价改动先证默认逐周期不变；行为变更需说明并全量回归，访存语义变更必须提交级 golden 对拍（golden 丢失时用 tools/rv32golden.py 重生成，命令见 handoff §16.4）；不随手 commit。
```

---

## §17 本窗（2026-10-17 第二窗）：M6b 复测 + M8a load 早写回 + M8b 误预测早重定向 + M9c 同线 guard 放宽；M9 判定 No-Go

> 口径：`make test/perf SIM=build/sim MAX_CYCLES=20000000`；综合 `make synth MODE=opt`（新流程）。启动核对与 §16.1 **逐项完全一致**（19/19、UT 6/6、GEOMEAN 0.7259、4,270.640 µm² / 1.4883 ns / 671.92 MHz）。

### 17.1 结论先行

- **GEOMEAN 0.7259 → 0.9348**（M8a +6.0%、M8b +1.6%、**M9c +14.4%**）。**GA（≥0.78）/ GB（≥0.80）/ GC（≥0.84）全过，且越过阶段 2 的 G4 目标 0.845（0.9348 ≥ 0.845）**。
- 全量：`make test` **19/19**、UT **6/6**、`make perf` 6/6 **GEOMEAN 0.9348**；LATENCY=1 GEOMEAN **1.0235** / LATENCY=50 **0.5638**；flush 压测 tak/queens/qsort/hanoi 在 L=1/50 全 PASS。
- **提交级 golden**（`win2_analyze_commit.py`，M8a/M8b/M9c 各跑一轮）：qsort 已提交 load **31,033/31,033、0 mismatch**、store 0 mismatch、无 LV/无 RWB=0；rsort **37,902/37,902、0 mismatch**、store 0 mismatch。
- synth（均无 ERROR/latch/Resizing）：M8a **4,103.6 µm² / 605.56 MHz**、M8b **4,082.7 µm² / 600.59 MHz**、**M9c 4,091.8 µm² / 605.20 MHz**（留档 `2026-10-17-m8a-*`、`-m8b-*`、`-m9c-*`）。频率含 ABC 方差警示，护栏以 ≥320 MHz 计。
- **M9（双发 LSU + 双读 D$）：判定 No-Go，未实施**（论证见 §17.4）——由 **M9c 以低得多的代价取得更大收益**（+14.4% vs M9 预估 +9%）。
- RTL 改动 5 文件：`memory/lsu_b.sv`（M8a + M9c）、`backend/core_ooo.sv` + `student_top.sv`（M8b + M9c 连线）、`memory/lsu_a.sv` + `memory/dcache.sv`（M9c）。**未 git commit**。


### 17.2 M6b 复测探针（临时，已清零三步验证）

探针：lsu_b P2（同拍 ≥2 条 D$ 可发 load + 同 word bank 冲突）、P5（被堵 load 中"仅同线、无字节重叠"）、IQ P4（依赖 stall 中在飞 load 占比，**在飞集合由 lsu_b 的 LDQ 位图派生**，非 IQ 本地记账）、core_ooo P6（BRU 解析拍→下一次发射的直方图）。一律 `$fopen/$fwrite` → `build/dbg_probe.log`，每次写后 `$fflush`。清零验证：全树 `$display/$fopen/$fwrite` 归零 + 重建 + 6 项 perf 逐周期与带探针时全等（0.8170 前后一致）。原始结果：`build/m6b_probe_results.txt`。

| 用例 | cyc | dual_go | samebank/dual | P5blk 占比 | P5sl 占比 | zdep | zdep_load | onlyload | mis | 平均代价 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| median | 10,832 | 47.0% | 6.3% | 0 | 0 | 2,405 | 2,405 | 2,403 | 305 | 3.30 |
| multiply | 24,221 | 3.5% | 5.7% | 0 | 0 | 595 | 595 | 398 | 677 | 4.05 |
| qsort | 293,198 | 11.0% | 12.2% | 52.2% | 52.0% | 83,110 | 83,108 | 79,812 | 13,151 | 3.52 |
| rsort | 176,712 | 22.0% | 9.6% | 23.6% | 23.4% | 43,072 | 39,549 | 7,577 | 32 | 5.56 |
| towers | 9,342 | 16.4% | 2.0% | 43.0% | 43.0% | 3,795 | 3,222 | 1,019 | 71 | 5.63 |
| vvadd | 5,320 | 94.0% | 0% | 0 | 0 | 2,210 | 2,210 | 2,210 | 7 | 10.0 |

- **P5 是最大新发现**：qsort/rsort/towers 的"被堵 load"几乎**全部只被同线 guard 挡住（无字节重叠）**（qsort 52.0% 周期、rsort 23.4%、towers 43.0%）→ **M9c（同线 guard 放宽）是比 M9 更有据的下一步**（须重证 §7.2 注的失效竞态，只有 miss 分配路径有竞态）。
- P6：误预测代价以 **4 拍为主桶**（median/multiply/qsort 的 h4 占绝大多数）→ M8b 削 1 拍按键值。

### 17.3 M8a（load 结果响应拍直通 BB）+ M8b（FE 早重定向）

- **M8a（`memory/lsu_b.sv`，唯一改动文件）**：load 完成（D$ resp 与 store 前递）**在完成拍组合直通 BB**；`wb_hv` 保留为同拍双完成兜底（early 优先于 hold，`wb_grant` 仅在 hold 被呈现时清除）；早写回**同拍释放 LDQ**（`l_valid<=0`，恰好一次）；kill 过滤沿用 `l_valid∧SENT∧rob 匹配`（treat as §5C-1）。**并额外消除 load 发射的强制锁存拍**：新选中（未锁存）的 load 当拍组合呈现 D$，端口即刻接受则直接 SENT、端口忙才锁存（payload 稳定不变）——这一项贡献最大（0.7571→0.8044）。不改访存数值语义（golden 0 mismatch）。0.7259→**0.8044**（median −15.2%、vvadd −14.6%、qsort −12.8%、tak −9.7%）。
- **M8b（`core_ooo.sv` + `student_top.sv`）**：core_ooo 增加组合早重定向输出 `redir_valid/pc/bsf`（= BRU 解析拍 `b_i∧b_mispred` 的 target）；student_top 组装 `fe_flush`（registered `flush` 的字段 + 早 valid/pc/bsf）**只喂 fetch_unit**，后端仍用寄存 1 拍的 `flush`（§4.3 协议不变）。**fetch_unit 一字未改**：即"FE 的 flush 整体提前 1 拍"，`pc_r` 早一拍重启、当拍丢弃错路径块、`bsf`/IFB 截断时序沿原逻辑。0.8044→**0.8170**（median −3.0%、multiply −2.8%、qsort −3.1%）。
  - **踩坑**：先按"仅提前 pc 重定向 + 在 flush 寄存拍仍允许发射"实现 → median 错答案（`result=4`）。根因：FE 与后端 flush 一拍错位（早重定向必须与 FE 的 flush 同拍整体生效）。改为"整体提前 FE 的 flush"后正确。**教训：FE 的 flush 语义是个整体，不能只搬 pc 一项。**

### 17.4 M9（双发 LSU + 双读 D$）判定：No-Go（未实施）

用本窗 M8a 的诊断探针（`LS cyc/…`）量化 **load 需求 vs D$ 端口容量**：

- **load 完成率 ≈ 0.14~0.35 条/周期**（median：resp 2,076 / 8,909 cyc ≈ 0.23；qsort：35,326/247,766 ≈ 0.14；vvadd：1,200/4,543 ≈ 0.26），而 D$ 单读口容量 **1 条/周期** → D$ 端口**远未饱和**（呈现 `go` 亦仅占 median 35% 周期）。
- **LSU 只有 1 条 BB 结果总线**，load 完成上限本就 **1 条/周期**；M8a 后 `hold`（DONE 等 WB）≈ 0（median/qsort 几乎不排队）→ **WB 侧无积压**。即使 D$ 双读把响应提到 2 条/周期，WB 也只能 1 条/周期 → **结构上无法提速**（除非再加第 2 条 LSU WB 总线，而 §16.5/§16.9 未规划）。
- P2 的 `dual_go`（同拍 ≥2 条就绪 load）只说明"偶发争用发射口"，不代表端口是稳态瓶颈（P4/Q 见 §17.2 的绝对完成率）。

结论：**M9 在本基线（WB 单总线 + load 需求 ≪1/周期）预期收益近零，且改动横跨 iq/lsu_a/lsu_b/dcache（访存内核）风险极高**；按 §16.7 的 Go/No-Go 精神（对照 M7 No-Go 先例）**跳过实施**。剩余最有据的杠杆是 **M9c 同线 guard 放宽**（§17.2 P5）。

### 17.5 M9c（同线 guard 放宽）—— 已实施，本窗最大贡献

**依据**：§17.2 P5（qsort 52% / towers 43% / rsort 23% 周期被"仅同线、无字节重叠"的 guard 堵住）。

**机制（安全性论证）**：guard 只为防 **load miss 分配路径**的"store 完成失效 vs 回填"竞态；**load 命中不分配、无竞态**。故放宽条件 = **"该 load 的 D$ 行当拍命中"**：
- `dcache` 新增组合 **tag 探针** `probe_addr→probe_hit`（`v_q[set] && tag_q[set]==tag`，纯读 tag/valid flop 阵列，无副作用）。
- `lsu_b` 保留原 guard 逻辑，但对"**仅被同线 guard 堵住**的最老者"（`sl_any && !blk_ov && !f_fwd`，程序序最老，每拍 1 条）查询探针；命中则放行（`f_go=1`）。
- **证明（无分配即无竞态）**：探针命中（A 拍行有效）→ A+1 拍 lookup 若命中则安全（L 的字不与任何更老 store 重叠，其字节来自更早的完成回填）；若 A+1 拍变 miss，只可能因（a）store B 完成失效（该 store 已写穿 AXI → 回填取到新值，安全）或（b）同 set 新 MSHR 分配（`set_busy=1` → 该 load replay、不分配，安全）。故探针命中是充分条件。
- 探针/连线路径：`lsu_b.probe_addr → core_ooo → student_top → lsu_a → dcache.probe_hit`（`mem_req_t` 未改，独立侧带）。

**收益**：0.8170 → **0.9348**（+14.4%）：**qsort 247,766→158,303（−36.1%）**、towers 8,710→6,942（−20.3%）、rsort 164,305→143,858（−12.5%）；median/multiply/vvadd 逐周期不变（P5=0，行为等价）。**提交级 golden qsort/rsort 仍 0 mismatch**；synth 4,091.8 µm² / 605.20 MHz（探针 1024 项 tag mux 未成关键路径）。

### 17.6 下一步（按优先级）

1. **阶段 2 的 G4（≥0.845）已由 M9c 越过（0.9348）**。剩余可选：冲**阶段 3**（面积 ≤36,000、IPC ≥1.0985、频率 ≥400/500）或加固收口。
2. 若继续提 IPC：M9c 只放宽了"同线命中"；可评估 (a) 更激进的多同线候选探针（当前每拍只探最老 1 条）、(b) M10 门控项（3 发射/更宽 WB）、(c) MSHR/流式（vvadd 仍 0.996 已近满）。
3. 若冲频率：本题 RTL 综合口径频率受 ABC 方差影响大（§15.6A），建议先 `MODE=diagnose` 定位、再结构化。
4. 全量回归 + golden + synth 后收口；**仍未 git commit**（等指示）。

### 17.7 本窗 diff 摘要

```
verilog/backend/core_ooo.sv   | M8b redir 输出 + M9c probe 连线
verilog/memory/lsu_b.sv       | M8a 早写回/零锁存 + M9c guard 放宽
verilog/memory/dcache.sv      | M9c tag 探针 (probe_addr/probe_hit)
verilog/memory/lsu_a.sv       | M9c probe 透传
verilog/student_top.sv        | M8b fe_flush + M9c probe 连线
docs/{handoff,design,impl-plan}.md | 文档更新（§17）
```
`rob.sv`/`fetch_unit.sv`/`cpu_pkg.sv` 无净改动；全树 `$display/$fopen` 0 处（探针已清）；3 个 synth JSON/timing.rpt 留档。



