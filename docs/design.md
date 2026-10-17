# RISC-V CPU 2026 —— 双发射乱序核心完整设计文档

> 版本 v1.0（对应仓库 commit `a81c802`：`cpu_pkg.sv` 契约 v0 + stub 单测脚手架）
> 关联文档：`README-ZH.md`（评分与提交要求）、`docs/axi4-lite.md`（总线与内存从机）、
> `docs/sram.md`（片上 SRAM）、`verilog/cpu_pkg.sv`（跨人接口契约）、`verilog/stubs/README.md`（单测脚手架）。
> 本文档是整项目实现蓝本：实现与文档冲突时，必须先改文档（PR）再改代码。
> 落地排程见 `docs/impl-plan.md`（阶段/任务/验收与排期）。

---

## 1. 设计目标与评分策略

### 1.1 交付物

| 项目 | 要求 | 来源 |
| --- | --- | --- |
| ISA | 完整 RV32I + M 扩展 + 全部整数 Load/Store；免除 CSR/FENCE/FENCE.I/ECALL/EBREAK | README-ZH §架构要求 |
| 微架构 | 乱序发射 + 按序提交（ROB）；关键参数可参数化 | README-ZH §架构要求 |
| 顶层 | 模块名 `student_top`，AXI4-Lite 端口严格按 README 模板，列入 `verilog/filelist.f` | README-ZH §顶层模块 |
| 终止 | 向 `0x80000000` 发 `WSTRB=4'hf` 的 32 位写，返回值在 `WDATA` | docs/axi4-lite.md §6.5 |
| 评分 | 正确性 ≤85 + IPC 几何平均×面积×频率分级 ≤15 + 频率加分 ≤4 | README-ZH §评分标准 |

### 1.2 性能目标与策略

| 配置代号 | 面积目标 (um²) | IPC 几何平均 | 频率 | 对应得分 |
| --- | ---: | ---: | ---: | ---: |
| cfg-small（保底） | ≤ 9,000 | ≥ 0.600 | ≥ 300 MHz | 90 |
| cfg-base（默认） | ≤ 18,000 | ≥ 0.845 | ≥ 300 MHz | 95 |
| cfg-big（冲刺） | ≤ 36,000 | ≥ 1.0985 | ≥ 400/500 MHz | 100~104 |

策略：**先正确性（85 分）→ cfg-base 调到稳定通过 → 参数扫描决定停在哪个档**。
所有微架构参数集中在 `verilog/cpu_pkg.sv`，一档配置 = 一组参数值（§3.4/§13），
调参闭环 = `make perf`（IPC 表与 GEOMEAN）+ `make synth MODE=opt`（面积/频率）双报告。

### 1.3 性能画像（依据 `testcases/*/metrics.json` 实测指令数）

| 测试 | 动态指令数 | 特征 | 对设计的指向 |
| --- | ---: | --- | --- |
| perf_qsort / perf_rsort | 139,900 / 195,719 | 递归调用（RAS 关键）、访存密集 | 分支预测 + D-Cache |
| perf_multiply | 21,722 | 乘法为主、依赖链长 | 乘法器流水化 |
| perf_median | 6,961 | 循环 + 栈访问 | D-Cache 命中率 |
| perf_towers | 5,278 | 深递归 | RAS |
| perf_vvadd | 4,524 | 流式 load/store | AXI 多发射挂起 + MSHR |
| correctness_pi | 3,117,658 | div/rem 密集（约占 1/4 指令） | 除法器吞吐需容忍数百万周期量级运行（§6.4.3 通用优化） |
| correctness_qsort/tak/magic/superloop | 0.26M~1.2M | 大循环上限 | 本地 `make test MAX_CYCLES=20000000` |

> 结论：`MAX_CYCLES` 默认 1e6 对 pi 等大程序不够（3.1M 条指令的物理下限就超过 1e6 周期），
> 本地回归一律 `MAX_CYCLES=20000000`（Makefile 支持传参，OJ 上限由评测方决定）。

---

## 2. 框架硬约束（实现前必须吃透的既定行为）

以下事实来自 `scripts/sim.cpp` 与框架文档，**全部既定，不许假设、不许修改**（行号为 sim.cpp）：

1. **端口契约**：`student_top` 端口一字不差（README 模板）；ARPROT/AWPROT 可不声明。
2. **复位**：同步复位，启动保持 5 周期高电平（L196-197）；复位期间从机所有 `ready`/`valid` 强 0
   （L100-107）；复位结束后 `memory.cycle` 从 0 计数，即 IPC 分母（L117）。
3. **内存**：小端 256 MiB（`0x00000000–0x0fffffff`），未加载区全零；超出范围且非 `0x80000000`
   → DECERR；地址未 4 字节对齐 → SLVERR（L71-74）。
4. **通道队列**：AR/AW/W/R/B 各 16 深 FIFO；非复位且未满时 `ready` 恒 1；握手当拍入队，
   **下一拍才开始服务**；读、写各每拍最多服务一个，两者冲突时服务顺序**随机**
   （xorshift，L126-131）→ 绝不能依赖 AXI 内部读写先后序。
5. **响应顺序**：R 通道按 AR 入队序返回，读响应全程有序（L118, L131-132）；
   `due = 服务周期 + latency`（默认 10，`LATENCY=` 可调）→ 未命中一次往返 ≥ 12 周期。
6. **握手法学**：`fire = valid && ready @posedge`；VALID 在 fire 前不可撤销、payload 不可变；
   VALID 不得组合依赖 READY（docs/axi4-lite.md §3）。
7. **AW/W 相互独立**：协议不限制顺序；本设计**强制 awvalid/wvalid 同拍生灭**（§7.4）。
8. **退出协议**：`awaddr==0x80000000 && wstrb==4'hf` 的写打 exit 标（L91）；**bvalid&&bready
   握手成功那一拍**捕获 `wdata` 为返回值并结束仿真（L119-122）；退出写 wstrb≠4'hf → SLVERR
   且不退出。`bready` 必须保持随时可收。
9. **SRAM**：只能实例化 `sram_fakeram`（单端口 1RW、同步读 1 拍延迟、字节写掩码、无复位、
   写/禁用周期 rdata 未定义、越界 fatal）；**不得**把 `scripts/ram/sram_fakeram.sv` 写进
   `verilog/filelist.f`（框架自动加入），**不得**自写同名 stub（docs/sram.md）。
10. `scripts/` 不得修改；`packaging/` 可删；OJ 只看 `./code`（`make code`）。
11. **综合流**：Yosys+ABC→ASAP7（7.5-track RVT TT）→OpenSTA；`MODE=opt` 展平（评测口径），
    `MODE=diagnose` 保留层次（定位面积热点用）；默认目标 `CLOCK_PERIOD_NS=2.0`（500 MHz）。

---

## 3. 总体微架构

### 3.1 顶层数据流与分工

```text
              ┌─────────────────────────── A：前端 + 访存旁路 ───────────────────────────┐
              │                                                                          │
 AXI4-Lite ◄── axi_master ── rdQ/wrQ ◄── dcache(MSHR) ◄── dcache ★ lsu.A(drain/lookup)  │
 内存从机     │                              │数据阵列            │  ▲ mem_req_t        │
      ▲       │                              │                    │  │ mem_resp_t       │
      │       ├── icache(S0/S1) → IFB → decode(S2) ──┐          lsu.B(AGU/LDQ/STQ) ──┤
      │       │                                      │ decoded_t (A→B, 2 路并行位流) ▼
              └──────────────────────────────────────┼────────────────────────────────────┘
                                                     ▼
              ┌─────────────────────────── B：乱序核心 ──────────────────────────────────┐
              │   rename(映射表+空闲表) → rob(按序提交 + flush 恢复)                      │
              │      │                                                                   │
              │      ▼                                                                   │
              │   iq(唤醒+选择) → alu×2 / mul(4 级流水) / div(迭代+融合) / bru / agu      │
              │        ▲  写回总线 BA/BB ← 各执行单元 ←── 操作数 ← prf(64×32, 4R/2W) ────┤
              └──────────────────────────────────────────────────────────────────────────┘
```

分工（与 `cpu_pkg.sv` 注释一致："A 的 decoder 产出 == B 的消费格式"、
"访存请求：B（AGU/LSQ）→ A（Cache/AXI）"）：

- **A：前端 + 访存旁路**：fetch/decode/ICache/BP；dcache/mshr/axi_master；`lsu` 的 A 侧。
- **B：乱序执行核心**：rename/rob/iq/prf/alu/mul/div/bru；`lsu` 的 B 侧（AGU/LDQ/STQ/前递）。
- `lsu` 为跨人模块：对外接口严格走 `mem_req_t/mem_resp_t`（B→A 方向），
  内部按 `memory/lsu_b.sv`（B 侧）与 `memory/lsu_a.sv` 挂接同一数据结构实现。

### 3.2 流水级定义

| 级 | 归属 | 职责 |
| --- | --- | --- |
| S0 取指地址 | A | PC 生成（顺序/预测跳转/重定向）、I$ 查询发起 |
| S1 取指数据 | A | I$ 数据（sram 同步读 1 拍）+ 命中判断 → 取指缓冲 IFB |
| S2 译码 | A | 每拍 2 条 RV32IM 译码 → `decoded_t`；JAL 自重定向；RAS 压/弹 |
| S3 重命名分派 | B | IFB 出队 → rename → 分派 IQ/ROB/LDQ/STQ（原子 1~2 条） |
| IQ | B | 唤醒（WB 总线 CAM）+ 选择（每拍 2 条就绪项） |
| EX | B | ALU 1 拍；MUL `MUL_LAT=4` 拍流水；DIV 迭代（§6.4.3）；BRU 1 拍 |
| AGU→LSU | B | 地址生成、LDQ/STQ 登记、前递判定、D$ 请求 |
| D$ | A | 数组读 1 拍 / 命中判断 / MSHR 登记 |
| WB | 共享 | BA/BB 总线 → PRF 写 + ROB 完成 + IQ 唤醒 |
| ROB 提交 | B | 每拍至多 2 条按序退休；flush 仲裁 |

典型时延（IPC 预算用）：I$ 命中取指 2 拍；load 命中端到端 ≈ 4 拍；load 未命中首字 ≈ 12 拍
（握手后下一拍进入服务 + 10 拍 latency）；store 从队头发起到 B 返回 ≈ 12 拍（异步）；
误预测代价 ≈ 4~6 拍。

### 3.3 模块与 filelist 计划

```text
verilog/
├── cpu_pkg.sv                 # 契约（已存在），按 §3.4/§4.2 增补
├── student_top.sv             # 顶层：AXI 端口 + 子模块互连（无任何功能逻辑）
├── frontend/
│   ├── fetch_unit.sv          # S0/S1：PC 生成、ICache 请求、IFB、重定向
│   ├── icache.sv              # 指令 Cache（2 bank × 32b）+ 1 项 refill
│   ├── bp.sv                  # BHT/BTB/RAS
│   └── decode.sv              # 2-wide 译码 → decoded_t
├── backend/
│   ├── rename.sv              # 映射表 + 空闲表 + 链式分派
│   ├── rob.sv                 # ROB + 提交 + flush 走表恢复
│   ├── iq.sv                  # 统一发射队列（CAM 唤醒 + 轮转选择）
│   ├── prf.sv                 # 64×32 flop 寄存器堆（4R/2W）
│   ├── alu.sv                 # ALU（例化 2 份）
│   ├── mul.sv                 # 流水化乘法（MUL_LAT 级）
│   ├── div.sv                 # 迭代除法（radix-2 + 提前退出 + div/rem 融合）
│   └── bru.sv                 # 分支/目标校验 + flush 请求
└── memory/
    ├── lsu.sv / lsu_b.sv / lsu_a.sv  # AGU+LDQ/STQ+前递（B）；D$/AXI 接口（A）
    ├── dcache.sv              # 数据 Cache（直接映射、写穿）+ MSHR_N 项
    └── axi_master.sv          # AXI4-Lite 主端仲裁（读/写 FSM、在飞上限）
```

`verilog/filelist.f` 按上述追加全部 `.sv`（路径相对 `verilog/`），`cpu_pkg.sv` 保持第一。
`verilog/stubs/` 下的一切文件**绝不进 filelist**，仅 `run_ut.sh` 编译。

### 3.4 参数表（`cpu_pkg.sv` 增补项，既有四个参数不动）

```systemverilog
parameter int DECODE_WIDTH = 2;   // 译码/重命名/提交宽度（= ISSUE_WIDTH）
parameter int LDQ_DEPTH    = 8;   // 在飞 load 上限
parameter int STQ_DEPTH    = 8;   // store 缓冲深度
parameter int MUL_LAT      = 4;   // 乘法流水级数
parameter int DIV_LAT_MAX  = 32;  // 除法最大迭代拍数（radix-2，运行期提前退出）
parameter int LINE_BYTES   = 16;  // 行大小（4 × AXI 字）
parameter int IC_LINES     = 128; // I$ 组内深度（总行数 = IC_LINES × ASSOC）
parameter int DC_LINES     = 256; // D$ 组内深度
parameter int ASSOC        = 1;   // 相联度（1=直接映射；逻辑按 ASSOC 路参数化）
parameter int MSHR_N       = 2;   // D$ 未命中合并项数
parameter int AXI_MAX_RD   = 8;   // 在飞 AXI 读上限（≤ 从机 R 队列 16 − 裕量）
parameter int AXI_MAX_WR   = 8;   // 在飞 AXI 写上限
parameter int BHT_ENTRIES  = 256; // 方向表项数（锦标赛：bimodal+gshare+choice 三表）
parameter int BTB_ENTRIES  = 128;
parameter int RAS_DEPTH    = 16;
parameter int BP_GHR_BITS  = 8;   // gshare GHR 宽（0=纯 bimodal；有效历史=min(值, log2(BHT_ENTRIES))）
```

三档配置（§13）除这组参数外代码零差异。

**参数-结构缩放规则**（保证参数化的真实性，防止"伪参数"）：

- 每拍发射/译码/提交条数、ALU 实例数、WB 总线数、PRF 写口 = `ISSUE_WIDTH`（改 1→ 单 ALU 单总线自动成立）；
- cache 索引/tag 位宽、victim 选择逻辑 = `IC_LINES/DC_LINES/ASSOC` 派生（ASSOC>1 时增加
  每 set 的 replaced 选择，默认 2 位 Pseudo-LRU；数据阵列按 `ASSOC` 个独立 bank 例化，
  以保持每拍 1 次访问的端口模型）；
- 结构位宽（`rob` 等字段）一律 `$clog2(参数)` 派生，扫描参数不出显式常数改写。

---

## 4. 内部微协议契约

### 4.1 valid/ready 总规则（全工程强制）

1. 发送方寄存 `valid` + payload；接收方组合生成 `ready`（`fe_stub/be_sink` 即范例）。
2. `valid` 不得组合依赖 `ready`；fire 前不得撤 `valid`、payload 不得变。
3. 每拍多条传输用"前缀切片"：各条独立 valid，接受者给出接受数 k，发送方按 k 前移。

### 4.2 与 `cpu_pkg.sv` 契约的对应与增补

| 契约 | 方向 | 本设计用法 |
| --- | --- | --- |
| `decoded_t` | A→B | 译码→重命名载荷，一字段不动 |
| `fetch_out_t` | IF→ID | 仅 stub 单测继续用；正式 FE→rename 改为 **2 路 `decoded_t` 并行位流**（`fe2rn_valid[1:0]` + `fe2rn_insn[1:0]`，scalar 版对外保留给 stub） |
| `writeback_t` | 执行单元→ROB | **PR 增补**：追加 `logic [$clog2(ROB_DEPTH)-1:0] rob;`（ROB 按号标 complete） |
| `mem_req_t` | B→A | AGU/LSU→dcache/axi；`rob` 字段用于响应配对与 flush 丢弃 |
| `mem_resp_t` | A→B | dcache→LSU；miss 被 A 侧 MSHR 内部吞掉，B 无感知 |

非 `cpu_pkg` 的横穿信号（文档级内部契约，走 PR 后入 `cpu_pkg`）：

```systemverilog
typedef struct packed {
    logic        valid;   // 本拍发生误预测冲刷（每拍至多 1 次）
    logic [31:0] pc;      // 重定向 PC（taken→目标，not-taken→pc+4）
    logic [4:0]  rob;     // 肇事分支 ROB 号（冲刷严格年幼于它）
    logic [5:0]  bsf;     // 该分支之前 FE 已见的分支计数（模 64），供 FE 截断幼年指令
} flush_t;
```

### 4.3 flush 协议（核心正确性机制，单点广播）

触发：BRU 判定"实际 taken ≠ 预测 taken"，或（taken 且目标 ≠ 预测目标），或 JALR 目标校验失败。
冲刷当拍一次性完成，真源唯一（`rob` 广播）：

| 结构 | 动作 |
| --- | --- |
| ROB | `tail ← (flush.rob+1) mod ROB_DEPTH`；年幼表项清 valid |
| 重命名 | 从 ROB 尾向 flush 点逆序恢复映射 `map[rd]←old_pdst`（§6.2.3），当拍组合完成 |
| IQ | 按 ROB 环距删除年幼项（CAM 一拍） |
| LDQ/STQ | 按 ROB 环距删除年幼项；被删 STQ 项**尚未 drain 则永不发出** |
| dcache/MSHR | 不动作：AXI 已发出的读不可撤回，行回填照常（幂等）；waiter 带 kill 位丢响应 |
| FE | 重定向 PC 寄存 1 拍生效；IFB 丢 `bsf > flush.bsf` 的项；流水截断 |

三条安全铁则（flush 一致性的全部内容）：

1. **AXI 侧不可撤回**：已发出请求必然返回，用"响应配对 + kill 位"丢弃过期响应，
   绝不允许过期数据写 PRF。
2. **PRF 写抑制与延后回收**：被冲刷指令的写回一律不写 PRF、不广播唤醒；其目的 tag 进
   **挂起回收表**，直到其写回事件真正到来才回收（防止 tag 提前重派被旧写回污染）。
3. **环距不变式**：一切年龄判断用 ROB 环距 `(x - ref) mod ROB_DEPTH < 在飞数`，
   不做绝对大小比较。

`mem_req_t.rob` 5 位环号在 ROB=32 下的复用歧义收敛规则：**每 ROB 号同时至多 1 条在飞访存记录**；
LSU 分配记录时直接覆盖同号旧记录（旧记录只可能是已完成或已 kill），未配对的迟到响应一律丢弃。

### 4.4 写回/唤醒总线

- 2 条结果总线 BA、BB（载荷 `writeback_t` 含增补的 `rob`）：
  - BA：ALU0、BRU、DIV 竞争（固定优先级 ALU0 > BRU > DIV）；
  - BB：LSU(load)、MUL、ALU1 竞争（LSU > MUL > ALU1，load 链路最敏感）。
- 附加 1 条"完成窄带"：store 的 B 响应 → 仅 ROB 标 done，不占结果总线。
- 每个 WB 拍内完成三件事：写 PRF（2 个写口）、ROB 标 done（按 rob 号 1-热译码）、
  IQ 唤醒（全阵列 ps1/ps2 CAM，次拍生效 → 依赖链唤醒延迟 1 拍）。
- 重命名期不做静态写回：LUI/AUIPC/JAL/JALR-link 全走正常 ALU/BRU
  （operands 由 `decoded_t.pc/imm` 直供），避免增加 PRF 写口。

---

## 5. 前端（A）

### 5.1 取指与 I-Cache（`fetch_unit.sv` / `icache.sv`）

- 每拍取 2 条（8 字节 fetch block）。I$ 数据阵列 = 每路每 bank
  `sram_fakeram #(.WIDTH(32))` ×（`IC_LINES×2`）深度；行 16B，tag/valid 为 flop 阵列
  （SRAM 估算面积按数据阵列计）。默认 `ASSOC=1`。
- PC 对齐到 8B 查询；块内两条指令的实际 pc 与次序由 `pc[2]` 还原，产物按程序序送 IFB。
- `ASSOC(=1) 直接映射`：`set = addr[clog2(LINE_BYTES)+clog2(IC_LINES)-1 : clog2(LINE_BYTES)]`，
  tag 取其余高位（含 `addr[clog2(...)+clog2(ASSOC)]` 内 set 区段）；ASSOC>1 时 victim
  按 Pseudo-LRU 选择。代码恒 < `0x10000000`，无需高位旁路。
- Miss：1 项 refill，向 AXI 发 4 个背靠背 32 位读（§7.4 rdQ 天然流水），逐字回填；
  回填期间取指停顿（FE 流水清空后 IFB 供 8 条 ≈ 4 拍缓冲）。
  可选优化（M4）：MSHR 记录触发偏移，关键字先到先旁路 IFB。
- `IFB` 深度 8（4 个 block），每条含 `decoded_t` + 独立 valid + `bsf` 旁路字段（§4.2）。

### 5.2 分支预测（`bp.sv`）

| 结构 | 参数 | 算法 |
| --- | --- | --- |
| BHT（锦标赛） | `BHT_ENTRIES=256` × 三表 | bimodal（`index=pc`）+ gshare（`index=pc^GHR`）+ 每 pc 选择表；两方向表同步训练，选择表向"预测正确的一方"训练 |
| GHR | `BP_GHR_BITS=8` | **随取指程序序**按预测方向移位；该分支的 gshare 索引随指令携带（`decoded_t` 系载荷的 `bix` 字段）到 BRU 训练——**预测与训练同索引**；任何误预测（含 JALR）按携带索引恢复 GHR（条件分支再移入实际结果） |
| BTB | 128 项 | tag + 目标 PC（tag 取 `pc[31:BI+2]` 截短），用于 JALR 目标猜测 |
| RAS | 16 深 | 译码见 JAL/JALR 且 `rd∈{x1,x5}` → 压栈（返回地址 = 当前 pc+4）；JALR 且 `rs1∈{x1,x5} 且 rd=x0` → 弹栈作目标 |
| 顺序路径 | — | 预测不跳转 → 连取下一个 8B 块 |

规则：
- S2 译码出 `JAL`（无条件直跳）不冲刷：直接修正下块 PC（1 拍 bubble）。
- BRU 解析回灌：BHT **按携带索引**更新（预测/训练同索引，见上表 GHR 行）；误预测或 BTB-miss 的分支写入 BTB；RAS 误弹不修复
  （已知局限：qsort/tak 递归深度 ~10，`RAS_DEPTH=16` 覆盖，溢出弃底不回卷）。
- 重定向：BRU `flush_t.pc` 寄存 1 拍 → S0 重启，总 bubble ≈ 4~6 拍。

### 5.3 译码（`decode.sv`）

2-wide，严格按 `cpu_pkg.sv` 填充 `decoded_t`：

- 立即数各型位段拼接（I/S/B/U/J），表格见 §8。
- 解码期即可判定：`uses_rs1/uses_rs2`（x0 或无该操作数 → 0）、`is_branch`、`fu`；
  Load/Store 宽度语义留在 `funct3`。
- `is_exit` 恒 0：退出判定取决于**运行期地址**与 wstrb（§7.5），解码期不可知。
- 非法/免除指令（SYSTEM/FENCE/AMO 等）→ `OP_NOP` + `illegal=1`（无副作用，仅自检，
  测试集不会出现）。

---

## 6. 乱序核心（B）

### 6.1 重命名（`rename.sv`）

- 映射表 32×6b（arch→phys）与空闲表（深 `PRF_NUM-32=32` 项 FIFO）全 flop，
  同步复位初始化：`map[i]=i`、空闲表预装 32..63；x0 恒不分配、恒 ready。
- 原子分派 1~2 条：ROB/IQ/LDQ/STQ/空闲表任一空位不足 → 按前缀切片只收部分（§4.1.3）。
- 每条指令：查表取 `ps1/ps2`（`uses_*` 为 0 → 绕表直 ready）；`rd≠x0` → 弹空闲表得 `pdst`、
  旧映射写进 ROB 表项 `old_pdst`、更新 map；同拍两条的寄存器依赖拍内串联（写后读穿透）。
- 反压：任一结构满 → `fe2rn_ready` 降，整体反压到前端，无内部缓冲倾泻。

### 6.2 ROB（`rob.sv`）

#### 6.2.1 表项

```systemverilog
typedef struct packed {
    logic       valid;
    logic [4:0] rd;            // x0 ⇒ 无目的
    logic [5:0] pdst;          // 目的物理寄存器号
    logic [5:0] old_pdst;      // 分派时旧映射（提交时释放）
    logic       is_load, is_store, is_branch, is_jalr;
    logic       done;          // WB/B 响应/B 解析置位
    logic       flushed_dep;   // （可选）供 kill 统计
} rob_entry_t;   // ≈ 22b × 32 项，flop
```

#### 6.2.2 按序提交

每弹出队首 ≤2 条 `done` 表项：`rd≠x0` → `old_pdst` 进空闲表。
**store 提前退休**（本设计关键取舍）：store 到队头且地址已生成（AGU 完成）即退休，**不等 drain/B**；
顺序正确性由 STQ 的 FIFO drain 次序 + §7.2 的 load 阻塞规则保证。这消除了
"store 阻塞队首 12 拍"的队阻塞问题，ROB 吞吐只受 load 链影响。

#### 6.2.3 flush 恢复映射（当拍组合完成）

从 ROB 尾向 `flush.rob` 逆序遍历"年幼且 rd≠x0"表项：`map[rd] ← old_pdst`
（逆序处理 ⇒ 最老者最后覆盖生效 = 分支时刻映射）。同时：

- 已 done 的年幼项：`pdst` 立即回收进空闲表；
- 未 done 的年幼项：`pdst` 进挂起回收表，待其写回事件真正到来才回收；
  该写回**不写 PRF、不唤醒**（按 `writeback_t.rob` 过滤）；
- LDQ/STQ 年幼项 kill；LSU 响应记录按 §4.3 覆盖/丢弃规则处理。

### 6.3 发射队列（`iq.sv`）

- 统一 16 项（`IQ_DEPTH`），项内容：`decoded_t` 精简字段 + `ps1/ps2`（6b）+ 2 位 ready +
  `pdst` + `rob` 号（5b）+ LDQ/STQ 指针（load/store 分派时预留的表项槽位）。
- 唤醒：§4.4 的 BA/BB 全阵列 CAM ps1/ps2，次拍 ready 置位（依赖链延迟 1 拍）。
- 选择：环起优先级每拍释放 2 条"双源就绪"项；load 项需 LSU 有受纳能力（§7.1）方许发射。
- store 数据（rs2 值）在发射时经 PRF 读口取得并随 AGU 结果写进 STQ；
  load 只带 `pdst`，数据由 WB 总线回填。

### 6.4 执行单元

#### 6.4.1 ALU ×2（1 拍）

`ADD/SUB/SLL/SRL/SRA/SLT/SLTU/XOR/OR/AND` 由 `funct3+funct7` 选路；
`OP_LUI`（imm 直出）、`OP_AUIPC`（pc+imm）、`OP_JAL`（pc+4）同走此路。

#### 6.4.2 乘法（`mul.sv`，`MUL_LAT=4` 级流水）

- 统一为符号扩展 33×33 概念积；`funct3`: 000 MUL(低 32)、001 MULH(高)、010 MULHSU、011 MULHU。
- 结构：Booth-4 部分积 8 个/级，4 级压缩树 + 逐级寄存截断；非阻塞流水（占用计数 `MUL_LAT-1`）；
  结果走 BB 总线（优先级低于 LSU）。

#### 6.4.3 除法（`div.sv`，迭代 + 融合 + 提前退出）

- radix-2 非恢复迭代，上限 `DIV_LAT_MAX=32` 步；**前导零提前退出**（LZA，通用优化）：
  以被除数/除数前导零差决定首轮对齐与有效商位数，商位小时实际迭代远小于上限。
- **DIV/REM 同源融合**（通用优化）：编译器对 `%` 常生成商/余成对指令（同 `(rs1,rs2,符号性)`），
  融合后单次迭代同时产商与余、双结果双写回（解码期 `is_fuse` 标记，同组在 IQ 成对发射），
  把成对除法的除法时长减半；无配对时退化为普通单结果除法。
- 边界值见表 §8.3（除零、`−2^31/−1`）。
- 占用：FU_DIV 忙标志，空闲才 ready；结果走 BA 回写。

#### 6.4.4 分支单元 BRU（1 拍）

- 条件按 `funct3`（§8.4）；JALR 目标 `(rs1+imm) & ~1`。
- 输出：`writeback_t`（JALR link）+ `flush_t`（§4.3，当拍广播）+ BP 更新请求。

---

## 7. 访存子系统（A/B 跨界，接口严守 cpu_pkg 契约）

### 7.1 AGU 与 LDQ/STQ（B 侧，`lsu_b.sv`）

- **AGU**：`addr = rs1 + imm`；对齐与字节掩码推导见 §8.2。
- **LDQ（8 项）**：登记在飞 load：`addr/funct3/rob/pdst/state∈{wait, refill_wait, done}`；
  IQ 表项 fire 即释放，load 后续推进由 LDQ 内部 replay 承担（§7.2）。
- **STQ（8 项）**：登记 `addr/wdata/wstrb/rob/state∈{ready, drained, completed}`；
  FIFO 次序即程序次序；队头 ready 项 → drain（§7.4）；B 返回 → completed → 释放。
- LSU 对 IQ 的受纳信号：LDQ/STQ 有空位（分派登记用）+ D$ 访问端口空闲余量（发射门槛），
  防止"发射了却无处登记"的队头阻塞。

### 7.2 load 前递与阻塞规则（正确性核心）

对每个 load L（字节区间 B_L = 由 `addr[1:0]+funct3` 决定，多数为整字）：

1. **完全前递**：存在唯一**更老** store S（STQ 中未 completed）其字节区间 B_S ⊇ B_L
   → 结果 = `S.wdata` 对齐移位，当拍产 WB（免 D$）。
2. **部分重叠**：存在更老 store 与 B_L 相交但不完全覆盖 → L 阻塞，直到重叠 store 全部
   completed（B 已握手）后走正常路径。原因：从机读写服务顺序随机（§2.4），若 store 已入 AXI
   而 B 未回时 L 也入 AXI 读，可能被随机先服务拿到旧值——必须等写完。
3. **无重叠**：直接走 D$。

实现：STQ 侧 CAM 按 `addr[31:2]`（30b）× `STQ_DEPTH` 比较，与"completed 位"组合出
重叠掩码；LDQ 的阻塞项在掩码清零下拍 replay D$ 端口。利用 STQ 的 FIFO 次序可简化：
只需等**最新一个**重叠 store completed 即可放行（更早的重叠 store 必然已先完成）。
所有比较基于对齐字地址（`addr & ~3`）。

### 7.3 D-Cache 与 MSHR（A 侧，`dcache.sv`）

- 结构：`ASSOC` 路 × `DC_LINES` 组 × 16B（默认直接映射）；**写穿 + 写不分配**
  （无 dirty 位，面积/复杂度最优）；tag/valid 为 flop，数据阵列按路分 bank 例化。
  数据阵列 `sram_fakeram #(.DEPTH(DC_LINES), .WIDTH(32), .WRITE_GRANULARITY(8))`
  （字节写掩码），tag/valid 为 flop。
- 端口仲裁（1RW，每拍 1 个访问）：`load replay/前递完成 > 新 load > 行回填写 > store 命中落阵`。
- 命中：读 1 拍后数据出，走 BB 总线 WB（LSU 侧）。
- 未命中：占 MSHR（`MSHR_N=2`：`addr/rob/pdst/字索引/kill`），向 §7.4 发 4 个背靠背读；
  每字返回即写阵列（wmask=4'hf）；4 字聚齐或触发字先到 → 完成 waiter；
  **kill 位的 waiter 丢响应**（不写 PRF、不唤醒）。
- MSHR 满：新 load 挂 `refill_wait`（同 tag 行自动合并；否则等空位）。
- 预算：栈 × 工作数组 ≪ 4KB 时命中率主导；未命中占比进入 §14 敏感度扫描。
- I$：独立 1 项 refill，与 D$ 共用 rdQ；响应由 `{src,word_idx}` 标记派发。

### 7.4 AXI4-Lite 主端（`axi_master.sv`）

所有访存源（D$ refill、I$ refill、STQ drain）整形进两条内部队列：

- `rdQ`：`{addr(4B 对齐), src, word_idx}`，容量 `AXI_MAX_RD`；
- `wrQ`：`{addr, wdata, wstrb, src}`，容量 `AXI_MAX_WR`。

**读通道 FSM**：
1. `rdQ` 非空且在飞 `< AXI_MAX_RD` → 寄存 `arvalid=1, araddr`（payload 同拍锁定）；
2. fire → 在飞++、弹队；锁存 `{src,word_idx}` 进**在飞序 FIFO**（响应与 AR 同序，§2.5）；
3. `rready` 恒 1；`rvalid` 到 → 按序弹出在飞项，派给对应 MSHR/ICache refill。
   因为从机逐拍最多服务 1 读、按队列序返回，在飞序 FIFO 天然对齐。

**写通道 FSM**：
1. `wrQ` 非空且在飞 `< AXI_MAX_WR` → 同拍置 `awvalid=1, awaddr, wvalid=1, wdata, wstrb`
   （AW/W 同生同灭；本设计在飞上限 8 ≪ 从机队列 16，从机 `awready/wready` 稳定为 1）；
2.    fire 判定按**各自通道独立**（协议鲁棒，不依赖"恒同拍"的内建假设）：
   仅 AW fire 时保持 `awvalid` 不再重复发新地址、锁存该写为"AW 已收"，继续高 `wvalid`；
   仅 W fire 时反之；双 fire 或先后补齐后进入等 B；`bready` 恒 1；`bvalid` 到 → 在飞−−、
   完成标记（store→ROB 窄带），随后才允许下一写的 AW/W 出队；
3. **退出写**与普通写同路径（§7.5），从机行为由其自决。

复位期间全部 valid 强 0、队列清空（§2.2）；fire 前永不改 payload（§2.6）。

### 7.5 退出协议实现（端到端）

1. 程序尾部 `sw xK, 0(t0)`（t0=`0x80000000`）按**普通 store** 全流程：
   AGU → STQ → 队头 drain → wrQ → AXI 写（`wstrb=4'hf`, `awaddr=0x80000000`）→
   从机打 exit 标 → B 握手 → 仿真器结束。
2. CPU 侧唯一特判：`addr[31:28] ≠ 0` 的 store **绕过 D$** 直入 wrQ（防污染 cache 标签）；
   原 RAM 内 store 命中才写阵列（写穿）。
3. 无需"末条指令"判定、无需停发射：B 握手即停，模糊窗口内 IQ/LDQ 的残留对结果无影响。

### 7.6 错误响应与边界访存（通用语义，非针对用例）

| 场景 | 设计决策 | 理由 |
| --- | --- | --- |
| load 的 `rd=x0` | 不发起访存、不进 LDQ；译码即按无目的指令处理（retire 时无空闲表动作） | 目的寄存器不可见 ⇒ 访存无结构效应；框架亦无 fault 概念，跳过是合法等价 |
| 读地址 ≥ `0x10000000`（含 `0x80000000`） | 绕过 D$，作无 cache 读；`rresp=DECERR/SLVERR` 或 OKAY 一律按返回数据处理 | 本框架无异常/中断机制，ISA 层面也没有 fault 概念 |
| load 响应 `SLVERR/DECERR` | 完成该 load，值为 `rdata`（错误时从机给 0） | 同上；程序正确性不依赖错误路径，但行为必须定义 |
| 读/写地址 < `0x10000000` 且未对齐 | 按 §8.2 位段掩码语义处理，不产生任何错误 | 协议只强制总线请求对齐（我们已对齐）；ISA 免除非对齐支持，测试集保证自然对齐 |
| store 地址 ≥ `0x10000000` | 绕过 D$ 直入 wrQ（§7.5） | `0x80000000` 为专用退出地址，不能进 cache 标签域 |

> 同一原则适用于整个设计：**每一个协议可能事件都必须有已定义行为**，即使当前评测集不触发。
> 这是"不面向测试点设计"的落地形式——上面五条没有一条来自具体测点的假设。

---

## 8. 指令语义与边界情况

### 8.1 操作码映射（解码产 `op_e/fu_e`）

| 主 opcode | 指令 | op_e | fu_e | 备注 |
| --- | --- | --- | --- | --- |
| 0x37 | LUI | OP_LUI | FU_ALU | imm 直出 |
| 0x17 | AUIPC | OP_AUIPC | FU_ALU | pc+imm |
| 0x6F | JAL | OP_JAL | FU_ALU | rd=pc+4；FE 自重定向 |
| 0x67 | JALR | OP_JALR | FU_BR | rd=pc+4（BRU 写回）；目标校验 |
| 0x63 | BEQ/BNE/BLT/BGE/BLTU/BGEU | OP_BR | FU_BR | funct3=000/001/100/101/110/111 |
| 0x03 | LB/LH/LW/LBU/LHU | OP_LOAD | FU_LSU | funct3=0/1/2/4/5 |
| 0x23 | SB/SH/SW | OP_STORE | FU_LSU | funct3=0/1/2 |
| 0x13 | ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI | OP_ALU | FU_ALU | SLLI/SRLI/SRAI 由 funct7=0/0x20 区分 |
| 0x33, f7=0x00 | ADD/SLL/SLT/SLTU/XOR/SRL/OR/AND | OP_ALU | FU_ALU | funct3=0..7 |
| 0x33, f7=0x20 | SUB / SRA | OP_ALU | FU_ALU | funct3=000 / 101 |
| 0x33, f7=0x01 | MUL/MULH/MULHSU/MULHU | OP_MUL | FU_MUL | funct3=0..3 |
| 0x33, f7=0x01 | DIV/DIVU/REM/REMU | OP_DIV | FU_DIV | funct3=4..7；同源融合 |
| 其他 | CSR*/FENCE*/ECALL/EBREAK/AMO… | OP_NOP | FU_ALU | `illegal=1`，无副作用 |

### 8.2 访存字节语义（统一小端、字对齐总线）

AXI 请求一律 `bus_addr = addr & ~3`（满足 §2.3 的 4B 对齐强制）。

| 指令 | 写（wstrb / wdata） | 读（提取） |
| --- | --- | --- |
| SW | `4'hf` / 直传 | `rdata` 直用 |
| SH | addr[1]=0: `0011`；addr[1]=1: `1100`；wdata = `data<<(16*addr[1])` | `rdata>>(16*addr[1])` 取 [15:0] |
| SB | `0001<<addr[1:0]`；wdata = `data<<(8*addr[1:0])` | `rdata>>(8*addr[1:0])` 取 [7:0] |
| LB/LBU | — | 按 SB 槽位字节，[7:0] 符号/零扩展 |
| LH/LHU | — | 按 SH 槽位半字，[15:0] 符号/零扩展 |

**非对齐语义**：ISA 只要求自然对齐（测试集保证），框架无 fault/probe 机制，故不做对齐检查；
上述位段/掩码公式对任何 `addr[1:0]` 都有确定行为（生成确定但不保证有意义的掩码）。
总线请求恒 4B 对齐，从机永不回 SLVERR-for-alignment。

### 8.3 M 扩展边界（RISC-V 规范定义值）

| 情形 | 定义值 |
| --- | --- |
| DIV x/0 | −1（全 1） |
| DIVU x/0 | 2³²−1 |
| REM x/0、REMU x/0 | 被除数 x |
| DIV (−2³¹)/(−1) | −2³¹ |
| REM (−2³¹)/(−1) | 0 |
| MULH/MULHSU/MULHU | 64 位积的 [63:32]（符号组合见 §6.4.2） |

---

## 9. 复位与顶层（`student_top.sv`）

- `clock/reset` 直透全部子模块（同步复位）。复位职责：所有 flop/FIFO/队列/仲裁状态清零；
  重命名映射表与空闲表重建初值（x0 恒映 p0，**PRF 表项 0 即 p0 同步清 0 且永不被写**：
  `rd=x0` 永不分配、WB 按号过滤）；cache 仅清 valid/tag（SRAM 内容垃圾无害）。
- 不额外做复位整形（框架已保 5 拍高电平）；复位内部任何 `valid` 强 0。
- 顶层零功能逻辑（diagnose 报告中顶层 "Direct" 面积应≈0，作为审计点）。

---

## 10. IPC 概算（cfg-base 点检）

| 场景 | 主导链 | 估算 |
| --- | --- | --- |
| ALU 依赖链（2 发射） | 唤醒 1 + EX 1 | IPC ≈ 1.0~1.3 |
| load 命中链（AGU+D$+WB ≈ 4 拍） | 中间逻辑占空 | IPC ≈ 0.8~1.1（median/vvadd 主体） |
| store 密集 | drain 异步、提前退休 | 基本不伤 IPC |
| perf_multiply（乘链） | 4 级流水无阻塞 | IPC ≈ 0.7~0.9 |
| 递归（qsort/towers, RAS ≥95% 命中） | 误预测 ~5 拍 | IPC ≈ 0.7~1.0 |
| correctness_pi（div/rem 链） | 同源融合 + 提前退出 | IPC 取决于除法链长（不进 GEOMEAN，仅正确性） |

几何平均 ≥0.845（tier2）/ ≥1.0985（tier3）的達标度取决于：D$ 命中率、误预测率、
MUL/div 依赖链。任一不足时按 §13 参数优先诊断。

---

## 11. 验证计划

### 11.1 单元测试（`verilog/stubs/`，`sh verilog/stubs/run_ut.sh <tb>`）

| tb | 组合 | 验证点 |
| --- | --- | --- |
| `tb_stub_link`（已有） | fe_stub + be_sink | 契约握手回归基线，永久保留 |
| `tb_fe_link` | **真前端** + be_sink | IFB 反压不丢不重；flush.bsf 截断幼年指令；重定向 PC 正确 |
| `tb_be_link` | fe_stub + **真后端**（rename+rob+iq+alu+prf） | 重命名映射/旧 tag 回收；ROB 顺序提交；链式依赖唤醒 |
| `tb_flush` | fe_stub + 后端 + bru 打 flush | 映射恢复 = 分支时刻快照；挂起回收不误写 PRF；tag 无泄漏（终态空闲表 = 初始） |
| `tb_lsu` | lsu + dcache + axi_master（cmem stub 用 `scripts/ram/sram_fakeram.sv`） | 前递全覆盖；重叠阻塞正确解除；MSHR 合并；kill 丢响应 |
| `tb_axi` | axi_master 官方从机模型（连 sim.cpp 行为的简化重放） | payload 稳定；在飞上限；读响应按序；aw/w 同拍 |
| `tb_mul_div` | mul/div 单体 | M 扩展全表 + §8.3 边界 + 融合产商余对 |

纪律：断言写 `if (!cond) $fatal(1, ...)`；`run_ut.sh` 已自动挂 `sram_fakeram.sv`；
每天收尾在主干跑一次完整回归（下条）。

### 11.2 系统级（testcases，命令行）

```sh
make build                                    # Verilator 编译（AppImage 工具链）
make test MAX_CYCLES=20000000                 # 全正确性
make test Case=correctness_add_to_100 MAX_CYCLES=20000000
make perf                                     # IPC 表 + GEOMEAN
make run PROGRAM=testcases/perf_qsort/program.data EXPECTED=$(cat testcases/perf_qsort/expected.txt) \
         MAX_CYCLES=20000000 WAVE=qsort.vcd LOG=qsort.log   # 波形只作最后手段，优先 LOG/$display
make synth MODE=diagnose                      # 面积热点定位 → 改 → MODE=opt 出分数口径
```

### 11.3 自检断言（RTL 内置，`DEBUG` 参数关闭零成本）

- fetch/rename 消费数量与 IFB 深度一致性；
- ROB：提交数累计 ≤ 动态指令总数；flush 后空闲表预测值 == 快照重算值；
- LSU：响应记录表无孤儿（终态全空）；STQ completed 数 = 发出的写数；
- AXI：在飞计数不越 `AXI_MAX_*`；`arvalid` 期间 `araddr` 不变。

---

## 12. 里程碑

| 里程碑 | 内容 | 完成判据 |
| --- | --- | --- |
| M0（已完成） | 工具链跑通 + cpu_pkg 契约 + stub 脚手架 | `tb_stub_link` 绿 |
| M1 顺序通路 | student_top→axi_master→简化 LSU（阻塞式 load/store、无 cache）+ 最小 order 执行 | `correctness_add_to_100` PASS |
| M2 乱序核心 | rename/rob/iq/al×2/bru + flush 全链 | `perf_towers`/`correctness_hanoi` PASS，`tb_flush` 绿 |
| M3 访存子系统 | dcache+MSHR+STQ drain+前递；I$；BP 初版 | `make test` 全 PASS（20M 上限）、`make perf` 出分 |
| M4 性能调优 | MUL 流水/融合除法参数化、MSHR/IFB 加深、BTB/RAS 修正 | GEOMEAN ≥0.845（tier2 达标） |
| M5 面积/频率 | diagnose 定热点→参数与物理改造→opt 口径；三档配置固化 | 面积+IPC+频率进入目标 tier |

每里程碑结束：`make test`（全绿）+ `make synth` 留档 report.json（面积/频率跟踪进报告）。

---

## 13. 参数敏感度实验矩阵（报告素材，§14 相关）

固定其余参数，单因子扫描并记录（IPC GEOMEAN / 面积 / Fmax 三元组）：

| 实验 | 扫描值 | 预期观察 |
| --- | --- | --- |
| E1 ISSUE_WIDTH | 1 / 2 / 3 | 2→3 边际衰减（受取指带宽与唤醒瓶颈限制） |
| E2 ROB_DEPTH | 8/16/32/64 | 大到未命中率不再限制窗口为止；上限受 LSQ 比例失配 |
| E3 PRF_NUM | 48/64/128 | 64 后基本平坦（除非 ROB>64） |
| E4 IQ_DEPTH | 4/8/16/32 | 小 IQ 限制乱序收益；与 ROB 匹配点 |
| E5 MUL_LAT / 除法迭代 | 4 vs 2 级乘；除法 LZA/融合开关 | 乘法/除法依赖链程序的差异 |
| E6 D$ 容量 | 1KB/2KB/4KB/8KB；直接映射 vs 2 路 | 工作集匹配拐点；租用 FakeRAM 面积换算 |
| E7 行大小 | 8B/16B/32B | 流式（vvadd）vs 单字交换 |
| E8 MSHR_N | 1/2/4 | 未命中重叠度收益 |
| E9 分支预测 | 静态 not-taken / +BHT / +BTB / +RAS | 各级增量；RAS 对递归类决定性 |
| E10 延迟敏感性 | LATENCY=1/10/50 | 验证延迟隐藏策略有效性（框架参数） |

报告交付：以上矩阵 + 架构探索总结（用本仓库 git 历史 + 本文档变更记录做素材）。

---

## 14. 风险与对策

| 风险 | 影响 | 对策（已在设计中内建） |
| --- | --- | --- |
| AXI 死锁（payload 漂移/VALID 撤回） | 仿真挂死 | `axi_master` 寄存型 valid + fire 前锁存；rready/bready 恒 1；在飞上限 8 ≪16 |
| 读写服务随机序导致旧值 | 错答案 | §7.2 规则 2（重叠 store 等完成） |
| flush 期间旧写回/D$ 响应污染 | 错答案 | 挂起回收表 + kill 位 + 覆盖式记录分配（§4.3） |
| store 提前退休引入乱序 | 错答案 | STQ FIFO drain 序 + load 阻塞在更老未完成重叠 store |
| 退出前 store 未 drain 即超时 | FAIL | drain 带宽 1 写/拍、STQ 深度 8，裕量足够；`is_exit` 走正常路径 |
| WB 总线长依赖（MUL/DIV 长占 BA/BB） | IPC 掉 | 分总线优先级 + 部分积寄存化 |
| iq CAM 口径在 500 MHz 边缘 | 频率掉 | 唤醒 CAM 与选择分两级；必要时 IQ 分裂为 ALU/MEM 两队列（cfg 变体） |
| PRF 4R/2W flop 面积 | 面积超 | diagnose 审计；备选：PRF 降价为 2R/2W + 发射拍读取串行化（cfg-small 变体） |
| 面积超档（18k/36k） | 分数掉 | §13 参数扫描；cfg-small 备份配方（小 ROB/PRF/Cache、乘法改 2 级） |
| pi 类长程序在 OJ 周期上限内跑不完 | 正确性风险 | 除法融合/提前退出为通用管线部分（M2 范围内）；`MAX_CYCLES` 由评测方/本地参数控制，不构成设计约束 |
| ECO 难重放缓 | 流程风险 | 参数集中 cpu_pkg；每个 report.json 留 git hash |

---

## 15. 附录

### 15.1 与既有仓库文件的对应

- `verilog/cpu_pkg.sv`：本设计 §3.4 增补参数、§4.2 增补 `writeback_t.rob` 与 `flush_t`；
  其余字段/枚举原样使用（`EXIT_ADDR`、`ZERO_REG`、所有 `op_e/fu_e` 值、各结构体）。
- `verilog/student_top.sv`：重写（当前 M0 全无效骨架退役）。
- `verilog/stubs/*`：保留并扩展（§11.1）；其 `run_ut.sh` 机制与 AppImage Verilator 用法不变。
- `docs/axi4-lite.md`、`docs/sram.md`、`scripts/*`：只读依据。
- OJ 提交：`make code` 产 `./code`；`verilog/filelist.f` 覆盖全部正式 RTL。

### 15.2 术语

ROB=Reorder Buffer；PRF=Physical Register File；IQ=Issue Queue；LDQ/STQ=Load/Store Queue；
MSHR=Miss Status Holding Register；IFB=Instruction Fetch Buffer；
bsf="branches seen before"（某指令之前已译码分支数）；BHT/BTB/RAS=分支历史/目标缓冲/返回栈。
"年幼/更老"一律指 ROB 里的程序序相对关系（环距比较）。




---

## 16. 阶段 2 冲刺设计（IPC GEOMEAN ≥ 0.8450；M6~M11）

> v1.1 增补（2026-10-16 第二窗定稿）。置于附录之后仅为避免重编号；**本节是阶段 2（cfg-base，95 分档）的实现蓝本：实现与本文冲突时先改本文（PR）再改代码**。
> 基线：GEOMEAN **0.6489** / 4,475.4 µm² / 383.66 MHz（2026-10-16 第二窗终态）。
> **每步硬门禁（缺一即停）**：面积 ≤18,000 µm²；频率 ≥300 MHz（护栏 ≥320，破线即重排或回退该里程碑）；全量回归不退化（`make test` 19/19 + UT 6/6 + `make perf` + LATITUDE=1/50）。

### 16.1 目标向量（+30% 落到每个用例）

GEOMEAN=0.845 等价于六项 IPC 乘积 ≈0.364，差距按对数均摊：

| 用例 | 现状 IPC | 目标 IPC | 倍率 | 主要可回收 stall（探针证据） |
| --- | ---: | ---: | ---: | --- |
| qsort | 0.462 | ~0.66 | ×1.43 | 条件分支误预测 25% + store 保序阻塞 |
| towers | 0.525 | ~0.74 | ×1.41 | 误预测 30% + LSU 串行 |
| vvadd | 0.660 | ~0.92 | ×1.39 | rob_full 52% + LSU 单口 |
| median | 0.641 | ~0.88 | ×1.37 | 依赖链 + LSU 单口 |
| rsort | 0.810 | ~0.97 | ×1.20 | store-head 阻塞 35% |
| multiply | 0.897 | ~0.96 | ×1.07 | 误预测 10% + 乘法链 |

推论：**"预测、访存乱序、访存宽度"必须三管齐下**；零误预测的完美预测器也只能把 GEOMEAN 抬到 ~0.71（对数均摊反推），单靠任何一项都到不了 0.845。

### 16.2 M6：测量先行（不动任何功能逻辑）

探针纪律：一律 `$fopen/$fwrite` 到 `build/dbg_probe.log`（**绝不污染 test/perf stdout**），当天清零三步验证（清零 → 重建 → 关键用例周期一致）。

| 探针 | 位置 | 量什么 | 决定什么 |
| --- | --- | --- | --- |
| P1 分支流离线建模 | `core_ooo` 打 `(pc, op, taken, pred)` 流 | 离线模拟 bimodal/gshare/**TAGE 变体**（表数/历史长/tag 宽）的可达误预测率 | **M7 的 TAGE 配置**（选型后才写 RTL） |
| P2 LSU 并行度 | `lsu_b` | 同拍 ≥2 条就绪 WAIT load 的周期占比 + 两 load 同 set/同 bank 冲突率 | M9 的收益上限与 bank 方案 |
| P3 store-head 归因 | `iq`/`lsu_b` | 被堵周期里 store 未就绪的原因 = 地址操作数未就绪 / 数据操作数未就绪 / STQ 满 | **M8 收益上限**（数据未就绪占比越高越值） |
| P4 依赖链 | `iq`/`core_ooo` | `zn_dep` 中 load→use 链占比 | M10 必做项的空间 |

### 16.3 M7：TAGE 方向预测（`frontend/bp.sv`）

> **【2026-10-17 状态：No-Go，未实施】** M6/P1 实测（handoff §15.2）：qsort 条件分支方向**不可约**（bimodal 24.47% 已优于一切历史预测器，全部 TAGE 变体 ≥25%，机器现值 27.37%），G1 的"qsort 误预测 ≤16%"**结构上不可达**；且 TAGE 均值不优于现有锦标赛（13.27%）。按 §16.7 压缩投入直推 M8。本节保留为历史设计，**勿按此实施**；离线模型与 trace 见 `build/m6_branch_model.py`（build/ 不入库，可重写）。

- 结构：base bimodal（沿用 `bht_b`）+ 3 张 tagged 历史表（GHR 8/24/64 折叠索引）+ 8~9b tag + 2b ctr + useful 位；最长匹配胜出；useful 位控制分配/失效。
- **一致性铁律**（本仓实测教训：不一致使 qsort 误预测 24.8%→38.6%）：预测与训练必须同一索引 ⇒ 携带字段由 `bix`（8b，gshare 索引）扩为 `{命中表号, 各表索引}`（≈30~40b，`fe2rn_t/renamed_t/issue_t` 只增）；GHR 扩到 64b。
- flush 恢复：沿用"由携带索引重建低 GHR 位 + 实际结果移位（条件分支）/不移位（JALR）"机制；**长历史表允许部分失真**，由 useful 位自愈（不追求完美检查点）。
- 验收：`tb_bp` 重写；误预测率探针复核；门 **G1：GEOMEAN ≥0.67 且 qsort 误预测 ≤16%、towers ≤20%**。

### 16.4 M8：访存乱序（store 地址早知；**无投机版本**）

> **【2026-10-17 状态：已实施并通过 G2（GEOMEAN 0.6489→0.7259）**，全量验收与记录见 handoff §15.4】。as-built 与本节的差异：
> ① ROB done 时机二选一取了"**AGU（发射拍）即 done**"（提前退役安全性论证不变：store 无寄存器结果，内存副作用由 STQ 退役后 FIFO drain 保证）；
> ② 携带字段落在 `issue_t.rs2_ready`（cpu_pkg 只增）而非 renamed_t，ps2 复用 issue_t 既有字段；
> ③ 数据回填用**合格写回总线 `ba_ok/bb_ok`** 的 STQ CAM（匹配 `s_ps2` → `s_data=stsh(wb.result)`、`s_dvalid=1`）；
> ④ drain 门槛 = 退役 ∧ `s_dvalid`；前递仅在 `s_dvalid[best]` 且全字节覆盖时成立，否则按 §7.2 规则 2 阻塞；
> ⑤ `same-line 守卫`（第 4 点）**未收窄**（保持原样，留作 M9c 门控项）；
> ⑥ load 门槛未再放宽（单 LSU + 最老优先下，"早于最老未发射 store"与"早于最老地址未知 store"等价——store 地址就绪即发）。

机制（全部可证保序，不引入违规重放）：
1. **IQ（§6.3 修订）**：store 项**仅 rs1（地址）就绪即可发射**（rs2 数据未就绪不阻塞发射）；携带 `ps2` 到 LSU。
2. **STQ（§7.1 修订）**：表项增 `data_valid=0` + `ps2`；**WB 总线 CAM 匹配回填数据**；drain 门槛 = 退役 ∧ `data_valid`；store 的 ROB done 时机相应调整（实现时二选一并重证 §6.2.2 提前退役安全性）。
3. **load 门槛（iq.sv）**：从"早于最老未发射 store"放宽为"早于**最老地址未知**的 store"。
4. **前递/阻塞（§7.2 规则不变）**：与重叠但数据未就绪的更老 store 仍按规则 2 阻塞；`same-line 守卫`（stale-line guard）在地址已知条件下重审，能收窄为"仅重叠阻塞"须写论证。

保序论证义务（必须写进 `iq.sv` 注释）：load 发射时所有更老 store 的**地址**均已知且已在 STQ ⇒ 重叠判定完整；数据未就绪只影响前递来源选择，不影响"是否需要等"。更年轻 store 不可能先脏化（drain 仍退役后、程序序）。

验收：保序论证注释 + **提交级 golden 对拍**（qsort/rsort）+ tak/queens/hanoi flush 压测 + LATENCY=1/50；门 **G2：GEOMEAN ≥0.72**。预期 rsort/vvadd +15~25%、qsort/towers 再 +8~12%。

### 16.5 M9：双发 LSU + 双读 D$

- **D$（§7.3 修订）**：双读口（两路独立 `acc_word/acc_set`；**不同 bank 并行、同 bank 冲突一方 replay**）；store 写/回填共享写口；`MSHR_N→4` 且**每 set 2 项**。
- **LSU（§7.1 修订）**：双路 load 调度器（两个锁存候选，按程序序 key）；LDQ 双分配口。
- **IQ（§6.3 修订）**：LSU 每拍最多 2 项（store-head + 更老 load，或两条 load）；**store 仍严格程序序**。
- 风险：深 mux/CAM 掉频——每步 synth 门禁；门 **G3：GEOMEAN ≥0.76 且频率 ≥320 MHz**。

### 16.6 M10：延迟与宽度（门控项）

- 必做：load 命中数据**更早唤醒 IQ**（消 1 拍 load-use）；`WB_BYPASS` 覆盖面复查。
- 门控（仅 G3 未过时启动）：3 发射/3 ALU/WB 3 总线/PRF 3W/取指 16B——牵动 §3.4 `ISSUE_WIDTH` 缩放规则全链，属"第二代核心"级改动，缺口 ≤10% 才值得做。

### 16.7 Go/No-Go 门、预算与降级

| 门 | 条件 | 不过怎么办 |
| --- | --- | --- |
| G1（M7 后） | ≥0.67 且 qsort 误预测 ≤16% | 复查 TAGE 配置/一致性；仍不过则压缩投入直推 M8 |
| G2（M8 后） | ≥0.72 | 重跑 P3 归因；若阻塞主导项不是"数据未就绪"则重审机制 |
| G3（M9 后） | ≥0.76 且频率 ≥320 MHz | 频率破线先重排（减表/减 MSHR/切级）；IPC 不足启动 M10 门控项 |
| G4（M10 后） | ≥0.845 | **判定阶段 2 在合理范围内不可达** → 降级路线 |

| 面积增量（估） | 累计 |
| --- | --- |
| 基线 4,475.4 | — |
| M7 ~0.3k / M8 ~0.5k / M9 1.5~3k / M10（门控）1~3k | ≤11.3k ≪ 18,000 ✓ |

预算不是瓶颈，**频率门禁与正确性（M8/M9 动访存内核）才是**：每里程碑独立可回退、每步 golden 对拍、M8 先无投机版本。

降级路线（G4 失败）：锁定阶段 1（90 分）+ 冲 **400 MHz（+2）/ 500 MHz（+4）**（383.66→400 需 −4.1% 周期；已知深链 = IQ 唤醒/选择 CAM、rename 优先级编码、ROB 恢复扫描、LSU CAM，可切级）。

### 16.8 契约增补预告（`cpu_pkg` 只增不删）

- 新参数：`BP_TAGE_*`（表数/基础历史/历史步进/tag 宽）等；`MSHR_N` 值变更 2→4；携带字段 `bix` 扩宽为 TAGE 索引组。
- 一切新字段/新参数先改 `cpu_pkg`（PR 双审纪律），随后**全链透传并全树 grep 窄连线**（端口宽度一律与 `cpu_pkg` 派生一致，防 Yosys `Resizing cell port`）。
  > 2026-10-17 注：`BP_TAGE_*` 与 `bix` 扩宽随 M7 No-Go 一并搁置；`MSHR_N 2→4` 移入 M9。

### 16.9 v1.2 路线修订（2026-10-17：M6 实测 + M8 落地后；**本节优先级高于 §16.5/§16.6 的排序**）

> 基线：GEOMEAN **0.7259** / **4,270.6 µm²** / **671.92 MHz**（频率含 ABC 映射方差警示：功能等价网表可差 383↔618↔672 MHz，见 handoff §15.6A；护栏以 ≥320 MHz 计，勿把 672 当稳定资产）。
> 依据（M6 四探针，handoff §15.2）：① 分支方向不可约（M7 No-Go，§16.3）；② store 侧阻塞已被 M8 收割（rsort −26.9%、vvadd −22.4%）；③ 剩余大头 = **load 侧延迟**（每条 load→use 固定 +2 拍，P4 纯 load-use：median 82.5%/multiply 66.9%/qsort 42.7% 的 zerodep 拍）、**误预测代价**（qsort ~16k 次 × 代价拍）、**LSU 单口宽度**（P2 双就绪拍：vvadd 42.7%/median 41.3%/rsort 15.5%）。

**修订后里程碑（按序）**：

| 里程碑 | 机制 | 依据/预估 | 门 |
|---|---|---|---|
| **M8a（新，第一位）：load 早写回** | 现路径：D$ resp 拍 T → `l_st/l_data` 寄存 → `wb_hv` 保持寄存 → **T+2 才上 BB** → 消费者（WB_BYPASS）T+2 发射。改为 **resp（及 store 前递）完成拍组合直通 BB**，省 2 拍/条。要点：`wb_hv` 保留为同拍双完成（resp+前递）兜底；早写回**同拍释放 LDQ**（恰好一次，防双写回）；kill 过滤沿用 `l_valid∧SENT∧rob 匹配`（被杀 load 的早写回走 ROB 过滤/reclaim，语义同 §5C-1）；BB 优先级 early-LSU > hold-LSU > MUL > ALU1；M8 store 数据回填走 `bb_ok` 自动提前 2 拍（协同） | P4；qsort −8% / median −15% / vvadd −20% / multiply −3% → GEOMEAN ≈ +9% | **GA ≥0.78** |
| **M8b：误预测代价 −1 拍** | flush 仍按 §4.3 寄存 1 拍广播（协议不变）；**仅 FE 的 pc 重定向提前到 BRU 解析拍**（组合送 target，pc_r 早一拍重启）；解析拍→广播拍之间取到的错路径块当拍丢弃（push 抑制一拍）；`bsf`/IFB 截断时序重证 | qsort 16k 次 ×1 拍 = −5.5%、median −4.4%、multiply −5.2% → ≈ +3% | **GB ≥0.80** |
| **M9：双发 LSU + 双读 D$** | §16.5 原案 + as-built 注：D$ 数据 bank **复制双份**（每 bank 两份 SRAM，写双副本；SRAM +≈1.4k µm²）；同 bank（= 同 word 索引）冲突一方 replay；`MSHR_N→4` 且每 set 2 项；store 仍严格程序序；IQ 每拍 ≤2 LSU（最老优先沿用 `lsu_sel` 教训） | P2：同 bank 硬冲突仅占可双发拍 0~13%；vvadd/rsort/median 为主 → ≈ +9% | **GC ≥0.84 且频率 ≥320 MHz** |
| **M9c（门控）：同线 guard 放宽** | 仅当复测 P5 显示"同线无重叠"阻塞占比大才做：**load 命中路径不需要 guard**（无重叠字节本就正确），只有 miss 分配路径存在"store 完成失效 vs load 回填"竞态（§7.2 注）；实现需把 guard 挪到 A 侧或向 lsu_b 传 hit/miss | 待 P5 测量 | 无独立门（并入 G4） |

> **【2026-10-17 第二窗状态】** M8a 已实施（0.7259→0.8044）、M8b 已实施（→0.8170）；**M9c 已实施（→0.9348）**——GA/GB/GC 全过，**阶段 2 的 G4（≥0.845）已越过**。**M9 判定 No-Go 未实施**：M8a 探针实测 load 完成率 ≈0.14~0.26 条/周期（远低于单读口容量 1/cycle），且 LSU 仅 1 条 BB 结果总线、`hold`≈0（WB 无积压）——端口非稳态瓶颈，无第 2 条 WB 总线时 M9 结构性难提速（对照 M7 No-Go 先例）；改由 **M9c 同线 guard 放宽** 以低代价取更大收益。**M9c 机制**：D$ 组合 tag 探针（`probe_addr→probe_hit`），对"仅被同线 guard 堵住"的最老 load，若其行命中则放行（命中不分配→无失效竞态，正证见 handoff §17.5）。详见 handoff §17。

- **G4（≥0.845）与降级路线（§16.7）不变**。
- M8a/M8b **不改访存数值语义**（golden 应保持 0 mismatch）；M9 动访存内核，须全量 golden + flush 压测 + LATENCY=1/50。
- 排程同步：impl-plan §13 末尾已加修订指引；交接细节与启动数字见 handoff §16。
