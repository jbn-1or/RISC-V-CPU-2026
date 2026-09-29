#!/bin/sh
# 单元测试一键脚本：用课程 AppImage 内置的 Verilator 5.020 编译并运行 stubs/ 下的测试顶层。
#
# 用法（在仓库任意位置都可以）：
#   sh verilog/stubs/run_ut.sh                 # 默认跑 tb_stub_link
#   sh verilog/stubs/run_ut.sh tb_my_decoder   # 跑自己的测试顶层（需放在 verilog/stubs/ 下）
#
# 要点：
#   * 不需要额外安装 Verilator —— AppImage 里自带（$APPDIR/bin/verilator）；
#   * --binary --timing：生成并运行仿真程序，支持测试里的 #延时；
#   * -Wno-fatal：警告不致命（与框架 make build 的配置一致，不加会因警告直接失败）；
#   * 产物写到 build/ut_<top>/（build/ 已在 .gitignore 中，不会污染仓库）。
set -e

REPO=$(cd "$(dirname "$0")/../.." && pwd)
TOP=${1:-tb_stub_link}
OUT="build/ut_$TOP"
APPIMAGE="$REPO/cpu2026-tools-x86_64.AppImage"

if [ ! -x "$APPIMAGE" ]; then
    echo "找不到可执行的 AppImage: $APPIMAGE" >&2
    exit 2
fi

if [ ! -f "$REPO/verilog/stubs/$TOP.sv" ]; then
    echo "找不到测试顶层: verilog/stubs/$TOP.sv" >&2
    exit 2
fi

exec "$APPIMAGE" exec /bin/sh -c "
    cd '$REPO' &&
    rm -rf '$OUT' &&
    mkdir -p '$OUT' &&
    \$APPDIR/bin/verilator --binary --timing -Wall -Wno-fatal \
        --top-module $TOP \
        verilog/cpu_pkg.sv \
        verilog/stubs/be_sink.sv \
        verilog/stubs/fe_stub.sv \
        verilog/stubs/$TOP.sv \
        --Mdir '$OUT' -o $TOP &&
    ./'$OUT'/$TOP
"
