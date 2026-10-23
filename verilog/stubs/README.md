# RTL 单元测试

生产 RTL 的编译顺序只维护在 [`../filelist.f`](../filelist.f)。测试顶层位于本目录，`be_sink` 和 `fe_stub` 提供前后端连接桩。

```sh
python3 tools/run_unit.py tb_lsu --jobs 8
python3 tools/run_unit.py tb_axi_write
# 旧入口继续可用，也支持从仓库以外的目录调用：
sh verilog/stubs/run_ut.sh tb_lsu
```

新入口复用课程框架的源文件解析、SRAM 模型和 AppImage 工具选择，启用 Verilator `--timing --assert`。也可以用 `--verilator /path/to/verilator` 指定本机工具。输出位于 `build/ut_<top>/`，每次重建对象目录，避免复用已失效的 AppImage 挂载路径。

| 测试 | 覆盖内容 |
| --- | --- |
| `tb_axi_write` | 256 笔写，AW/W 独立背压、payload 稳定、B tag 顺序及无背压每拍一笔 |
| `tb_dcache_recovery` | flush 与关键字返回同拍、消费端背压、ROB 号复用、保留较老 load |
| `tb_lsu` | LSQ、D$、AXI 集成，转发、重试、退休与冲刷 |
| `tb_be_link` | 前端输入桩与乱序后端连接 |
| `tb_stub_link` | decode 与连接桩的接口冒烟测试 |
| `tb_bp` | BHT、BTB、RAS 和预测索引 |
| `tb_mul` / `tb_div` | 乘除法执行单元 |

测试顶层命名为 `tb_*.sv` 后即可由 runner 选择；不要加入生产 `filelist.f`。完整 CPU 正确性、IPC 和综合验证见 [`../../docs/validation.md`](../../docs/validation.md)。
