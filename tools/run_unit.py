#!/usr/bin/env python3
"""Build and run an RTL unit test using the production source list."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from build import read_sources, verilator_command
from fakeram import with_ram_source
from toolchain import DEFAULT_APPIMAGE, enter_appimage


def main():
    tests = ROOT / "verilog" / "stubs"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("top", nargs="?", default="tb_stub_link",
                        choices=sorted(p.stem for p in tests.glob("tb_*.sv")))
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--appimage", default=str(DEFAULT_APPIMAGE))
    parser.add_argument("--verilator", help="explicit executable; skips AppImage")
    parser.add_argument("--filelist", type=Path, default=ROOT / "verilog" / "filelist.f")
    parser.add_argument("--out", type=Path, help="isolated output directory")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")

    try:
        if not args.verilator:
            enter_appimage(args.appimage)
        sources = with_ram_source(read_sources(args.filelist))
        out = (args.out or ROOT / "build" / f"ut_{args.top}").resolve()
        objects = out / "obj"
        out.mkdir(parents=True, exist_ok=True)
        # Generated dependencies contain paths into the transient AppImage mount.
        # Rebuild objects on each invocation, as the main simulator builder does.
        if objects.is_symlink():
            objects.unlink()
        elif objects.exists():
            shutil.rmtree(objects)
        binary = out / args.top
        binary.unlink(missing_ok=True)
        subprocess.run([
            verilator_command(args.verilator), "--binary", "--timing", "--assert",
            "-Wall", "-Wno-fatal", "--top-module", args.top,
            "--Mdir", str(objects), "-o", str(binary), "-j", str(args.jobs),
            *map(str, sources), str(tests / "be_sink.sv"),
            str(tests / "fe_stub.sv"), str(tests / f"{args.top}.sv"),
        ], cwd=ROOT, check=True)
        subprocess.run([str(binary)], cwd=ROOT, check=True)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode)


if __name__ == "__main__":
    main()
