# 单元测试与替身（stubs）

这里放**只用于本地单模块验证**的代码。**这些文件绝对不能写进 `verilog/filelist.f`**：它们只由
`run_ut.sh` 单独编译运行，不参与 `make build` / `make test` / OJ 提交。

| 文件 | 作用 |
| --- | --- |
| `be_sink.sv` | 假后端：A 写前端时用它顶替真正的后端（接收 `cpu_pkg::decoded_t`，按 `LATENCY` 拍后“提交”） |
| `fe_stub.sv` | 假前端：B 写后端时用它喂固定指令流（按 `COUNT` 条发完为止） |
| `tb_stub_link.sv` | 把上面两者串起来，验证 valid/ready 握手链路是否成立 |
| `run_ut.sh` | 一键编译 + 运行：`sh verilog/stubs/run_ut.sh` |

## 运行

```sh
sh verilog/stubs/run_ut.sh                    # 默认 tb_stub_link
sh verilog/stubs/run_ut.sh tb_my_decoder      # 自己的测试顶层（也要放在本目录）
```

脚本内部用的是课程 AppImage 自带的 Verilator 5.020（`$APPDIR/bin/verilator`），**不需要额外安装工具**，
产物在 `build/ut_<top>/`（已被 `.gitignore` 忽略）。

预期输出：

```text
[be_sink] accept pc=00000000 op=7 rd=0 imm=1
[be_sink] accept pc=00000004 op=7 rd=1 imm=2
[be_sink] accept pc=00000008 op=7 rd=2 imm=3
[be_sink] accept pc=0000000c op=7 rd=3 imm=4
[tb_stub_link] ok: committed=4 fe_done=1
- verilog/stubs/tb_stub_link.sv:37: Verilog $finish
```

## 自己加测试顶层时的注意事项

1. 需要片上 RAM 的模块，把 `scripts/ram/sram_fakeram.sv` 加进 `run_ut.sh` 的编译列表即可
   （`docs/sram.md` 明确允许框架外仿真这么用）。
2. 断言写成 `if (!条件) $fatal(1, "消息")`。
3. 单元测试只保证子模块单独正确，**每天结束前仍要在主干跑一次 `make test`**。
4. 跨人接口只允许用 `verilog/cpu_pkg.sv` 里的类型；改契约要走 PR 双审。
5. 手工编译时需要 `--binary --timing -Wno-fatal`，且 **`--Mdir` 目录每次先删掉再重建**：Verilator 生成的
   makefile 嵌了本次 AppImage 挂载点的绝对路径（每次不同、用后即失效），复用旧目录会报
   `No rule to make target '/tmp/.mount_cpu202Xxx/verilator/include/verilated.cpp'`。
   （`run_ut.sh` 已经替你做了 `rm -rf`，这也是框架 `scripts/build.py` 的同样做法。）

分工、对接流程与接口契约说明见 [`../../references/分工方案.md`](../../references/分工方案.md)。
