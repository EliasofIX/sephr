#!/usr/bin/env python3
"""Sephrium build driver.

Thin wrapper over `gn gen` + `autoninja` that reads flags.gn (release) or
flags_fast.gn (--fast inner-loop), writes args.gn, and builds the linkable
framework target.

Two build modes:
  --fast (default for the inner loop): out/Fast, flags_fast.gn, target
         chrome_framework. ~3-5x faster than --release. Use this while
         iterating on the CAL bridge.
  --release: out/Release, flags.gn (is_official_build=true + LTO), target
             chrome. Use this for shippable builds.

Idempotent gn_gen: skipped if the output args.gn already matches the input
flags file — saves ~30s per invocation when nothing changed.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROMIUM_SRC = ROOT / ".chromium-src" / "src"


def ensure_depot_tools() -> None:
    if shutil.which("gn") and shutil.which("autoninja"):
        return
    dt = pathlib.Path.home() / "depot_tools"
    if dt.exists():
        os.environ["PATH"] = f"{dt}:{os.environ['PATH']}"
        return
    raise SystemExit("[sephr] depot_tools not found — run scripts/bootstrap.sh")


def write_args(out_dir: pathlib.Path, flags_file: pathlib.Path) -> bool:
    """Returns True if args.gn changed (and gn gen needs to re-run)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    flags = flags_file.read_text()
    target_args = out_dir / "args.gn"
    if target_args.exists() and target_args.read_text() == flags:
        return False
    target_args.write_text(flags)
    return True


def gn_gen(out_dir: pathlib.Path) -> None:
    subprocess.run(["gn", "gen", str(out_dir)], cwd=CHROMIUM_SRC, check=True)


def ninja_build(out_dir: pathlib.Path, target: str,
                jobs: int | None) -> None:
    cmd = ["autoninja", "-C", str(out_dir), target]
    if jobs is not None:
        cmd.extend(["-j", str(jobs)])
    subprocess.run(cmd, cwd=CHROMIUM_SRC, check=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--fast", action="store_true",
                      help="Inner-loop build: flags_fast.gn → out/Fast, "
                           "target chrome_framework. Default.")
    mode.add_argument("--release", action="store_true",
                      help="Shippable build: flags.gn → out/Release, "
                           "target chrome (full app + LTO).")
    ap.add_argument("--target",
                    help="Override the ninja target.")
    ap.add_argument("--jobs", type=int, default=None)
    args = ap.parse_args()

    if args.release:
        out_dir = CHROMIUM_SRC / "out" / "Release"
        flags_file = ROOT / "sephrium" / "flags.gn"
        target = args.target or "chrome"
    else:
        out_dir = CHROMIUM_SRC / "out" / "Fast"
        flags_file = ROOT / "sephrium" / "flags_fast.gn"
        target = args.target or "chrome_framework"

    ensure_depot_tools()
    args_changed = write_args(out_dir, flags_file)
    if args_changed or not (out_dir / "build.ninja").exists():
        gn_gen(out_dir)
    else:
        print(f"[sephr] args.gn unchanged; skipping gn gen ({out_dir.name})")
    ninja_build(out_dir, target, args.jobs)
    print(f"[sephr] build complete → {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
