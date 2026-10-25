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
| `tb_lsq_recovery` | 恢复拍暂停 load，保留较老 load 与已退休 store，清除年轻 load/store |
| `tb_be_link` | 前端输入桩与乱序后端连接 |
| `tb_stub_link` | decode 与连接桩的接口冒烟测试 |
| `tb_bp` | BHT、BTB、RAS、预测索引，以及条件/间接分支误预测后的 GHR 恢复 |
| `tb_mul` / `tb_div` | 乘除法执行单元 |
| `tb_issue_width` | 单/双发射上限、年轻就绪指令越过等待指令、ROB 回绕时 LSU 优先级 |
| `tb_store_wakeup` | store 入队与写回同拍，关闭 ALU 旁路时仍捕获数据就绪状态 |
| `tb_cache_assoc` | 冲突地址命中计数、两路替换、字节更新、失效 |
| `tb_rob_recovery` | 每个 flush 点的最老写者恢复，覆盖满 ROB 和回绕窗口 |
| `tb_ifb_recovery` | 分支恢复清空 IFB；全部占用数和 head 位置，覆盖部分/满/回绕队列 |

通过 `--filelist <配置快照>/filelist.f --out <独立目录>` 可运行参数变体，避免覆盖默认构建。LSU 测试会在 ROB 号复用前退休和排空旧 store，断言失败以非零状态退出。

测试顶层命名为 `tb_*.sv` 后即可由 runner 选择；不要加入生产 `filelist.f`。完整 CPU 正确性、IPC 和综合验证见 [`../../docs/validation.md`](../../docs/validation.md)。
