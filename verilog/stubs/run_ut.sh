#!/bin/sh
# Compatibility entry point; production sources come from verilog/filelist.f.
# Usage: sh verilog/stubs/run_ut.sh [tb_lsu] [--jobs 8]
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
exec python3 "$REPO/tools/run_unit.py" "$@"
