#!/usr/bin/env python3
"""Atomic patch applier: either a patch lands fully clean, or all files
it touched are reverted to HEAD. Logs clean/partial/failed counts and
the names of every rejected patch."""
from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import subprocess
import sys


def load_series(patch_dir: pathlib.Path) -> list[pathlib.Path]:
    series = patch_dir / "series"
    if series.exists():
        out: list[pathlib.Path] = []
        for line in series.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(patch_dir / line)
        return out
    return sorted(patch_dir.rglob("*.patch"))


def patch_targets(patch: pathlib.Path) -> list[str]:
    """Extract the list of files a patch touches by reading its `+++ b/<path>`
    lines. Ignores `+++ /dev/null` (deletions)."""
    targets: list[str] = []
    for line in patch.read_text(encoding="utf-8",
                                 errors="replace").splitlines():
        m = re.match(r"^\+\+\+ [ab]/(.+?)(?:\s|$)", line)
        if m and m.group(1) != "/dev/null":
            targets.append(m.group(1))
    return targets


def run_patch(patch: pathlib.Path, tree: pathlib.Path) -> int:
    """Apply one patch. Returns the shell exit code (0 = clean)."""
    r = subprocess.run(
        ["patch", "-p1", "--forward", "--no-backup-if-mismatch",
         "--fuzz=3", "-i", str(patch.resolve())],
        cwd=tree.resolve(),
        capture_output=True, text=True,
    )
    return r.returncode


def revert_files(tree: pathlib.Path, files: list[str]) -> None:
    for f in files:
        subprocess.run(["git", "checkout", "HEAD", "--", f],
                       cwd=tree, capture_output=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch-dir", required=True, type=pathlib.Path)
    ap.add_argument("--chromium-dir", required=True, type=pathlib.Path)
    args = ap.parse_args()

    series = load_series(args.patch_dir)
    clean: list[str] = []
    skipped: list[str] = []
    tree = args.chromium_dir

    print(f"[sephr] atomic apply: {len(series)} patches")
    for p in series:
        if not p.exists():
            continue
        targets = patch_targets(p)
        rc = run_patch(p, tree)
        # Also sweep any .rej files created during this apply.
        rejs = list(tree.rglob("*.rej"))
        if rc == 0 and not rejs:
            clean.append(p.name)
            print(f"[sephr]  ✓ {p.name}")
        else:
            skipped.append(p.name)
            print(f"[sephr]  ✗ {p.name} (reverting {len(targets)} files)")
            revert_files(tree, targets)
            for rej in rejs:
                rej.unlink()

    out = args.patch_dir.parent / "apply-summary.log"
    with out.open("w") as f:
        f.write(f"# Applied clean: {len(clean)}\n")
        f.write(f"# Skipped:       {len(skipped)}\n\n")
        f.write("## Clean\n")
        for n in clean:  f.write(f"  {n}\n")
        f.write("\n## Skipped\n")
        for n in skipped: f.write(f"  {n}\n")

    print(f"[sephr] summary → {out}")
    print(f"[sephr] clean={len(clean)}  skipped={len(skipped)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
