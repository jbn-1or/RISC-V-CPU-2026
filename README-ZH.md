# 双发射 RV32IM 乱序 CPU

[English](README-EN.md) | 简体中文

本仓库实现双发射、双提交的 RV32IM 乱序处理器，使用物理寄存器重命名、统一发射队列、ROB 按序提交，以及非阻塞数据缓存。外部接口为 AXI4-Lite，顶层为 `student_top`。

阅读代码建议从 [架构与模块边界](docs/architecture.md) 开始，再按 `student_top → core_ooo → rename/rob/iq → load_store_queue → memory_subsystem/dcache` 查看。验证命令和综合口径见 [验证说明](docs/validation.md)。

## 当前配置

| 部分 | 配置 |
| --- | --- |
| 译码 / 发射 / 提交 | 每拍最多 2 条 |
| ROB / 物理寄存器 / IQ | 32 / 64 / 4 项 |
| 取指缓冲 / LDQ / STQ | 8 / 4 / 16 项 |
| 执行单元 | 2×ALU、BRU、4 级乘法器、迭代除法器、LSU |
| I$ / D$ | 4 KiB / 32 KiB，直接映射，32 B 缓存行 |
| 数据访存 | 2 个 MSHR；write-through、no-write-allocate；store-to-load forwarding |
| 分支预测 | gshare BHT256、BTB128、RAS16 |
| AXI 在飞请求 | 最多 8 读、8 写；AW/W 独立握手 |

普通 ALU 路径可以按“取指、译码入 IFB、重命名分派、发射执行写回、提交”五个阶段理解；乱序等待、乘除法和缓存访问有各自的可变延迟，不能把所有指令都视为固定五拍完成。

Tier 3 目标为 **面积 <36,000 µm²、频率 >300 MHz、IPC 几何平均 ≥1.0985**。当前频率优化版实测 **28,659.579 µm²、333.225 MHz、IPC 1.102294**，相对 300 MHz 门槛有约 11.1% 余量。正确性 19/19、延迟矩阵 8/8，六项性能测试计数与优化前一致。完整结果和复现口径见 [验证说明](docs/validation.md)。

## 编译和验证

宿主机需要 Python 3.10+、GNU Make、支持 C++17 的 G++ 和 binutils。将课程 `cpu2026-tools-x86_64.AppImage` 放在仓库根目录，或在 `config.mk` 中指定本机工具链。

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

`make` 或 `make code` 生成 OJ 需要的根目录 `code`。`make run PROGRAM=... EXPECTED=...` 可执行单个程序；`Case=perf_qsort` 等参数可以筛选测试。已有仿真器必须通过 `SIM=...` 显式指定，避免每次重新编译。

## 目录

```text
verilog/
  cpu_pkg.sv             配置、流水线载荷、地址与年龄判定
  student_top.sv         前端、后端、缓存与 AXI 集成
  filelist.f             生产 RTL 的唯一源文件清单
  frontend/              取指、译码、I$、分支预测
  backend/               重命名、ROB、IQ、PRF、执行与写回
  memory/                load_store_queue、memory_subsystem、D$、AXI
  stubs/                 单元测试与集成测试顶层
scripts/                 课程仿真、测试、综合框架
tools/                  本设计的单测、延迟回归及综合辅助工具
docs/                   架构、验证和课程协议说明
testcases/              官方测试子模块
build/                  本地产物（不纳入 Git）
```

共享参数集中在 `cpu_pkg.sv`。当前数据通路按双路实现，修改 `ISSUE_WIDTH` 并不会自动生成任意宽度处理器。缓存容量、队列深度或握手路径改动后，需要重新验证三项 Tier 3 指标。

更多资料：[AXI4-Lite 接口](docs/axi4-lite.md)、[SRAM 模型](docs/sram.md)、[单元测试](verilog/stubs/README.md)。本机 `references/` 是忽略目录，运行和阅读本设计不依赖其中的历史协作笔记。

课程工具链、评分和提交规则的原始说明保存在 [课程框架文档](docs/framework-ZH.md)。
