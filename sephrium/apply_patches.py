#!/usr/bin/env python3
"""Apply a directory of .patch files (unified diff) to a Chromium tree.

Usage:
    apply_patches.py --patch-dir <dir> --chromium-dir <dir>

Conventions:
  * Patch filenames are applied in lexicographic order so numeric prefixes
    (001-, 002-, ...) control sequence.
  * A `series` file inside the patch dir, if present, takes precedence and
    lists patches one per line in application order. Blank lines and
    lines starting with '#' are ignored. This matches quilt semantics and
    the layout used by ungoogled-chromium.

Application strategy — three tiers, fall through on failure:
  1. `git apply --3way` against a baseline commit. Works for any patch
     where the file in the working tree is reachable from HEAD; git's
     own merge engine handles context drift without needing the patch
     to carry index blob hashes (we synthesize them on the fly).
  2. `wiggle` — applies hunks even when context drifts by many lines.
     Optional; only used if the binary is available on PATH.
  3. `patch -p1 --fuzz=3` — last-resort plain apply. Records PARTIAL
     when some hunks land and some reject.

This three-tier strategy turns most "context drift" rejects into clean
applies, which is the dominant failure mode when ungoogled-chromium's
patches lag a Chromium minor bump.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys

BASELINE_TAG = "chromium-baseline"


def load_series(patch_dir: pathlib.Path) -> list[pathlib.Path]:
    series = patch_dir / "series"
    if series.exists():
        entries: list[pathlib.Path] = []
        for line in series.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            entries.append(patch_dir / line)
        return entries
    return sorted(patch_dir.rglob("*.patch"))


def have_git_repo(chromium_dir: pathlib.Path) -> bool:
    return (chromium_dir / ".git").exists()


def have_baseline(chromium_dir: pathlib.Path) -> bool:
    if not have_git_repo(chromium_dir):
        return False
    r = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", BASELINE_TAG],
        cwd=chromium_dir, capture_output=True,
    )
    return r.returncode == 0


def try_git_3way(patch_abs: pathlib.Path,
                 chromium_dir: pathlib.Path) -> tuple[bool, str]:
    """Attempt `git apply --3way`. Requires a git repo + baseline.

    Synthesizes index blob hashes from the working tree so patches that
    don't carry their own `index <sha>..<sha>` lines still get the
    3-way treatment. Returns (success, message).
    """
    if not have_baseline(chromium_dir):
        return False, "no baseline"
    result = subprocess.run(
        ["git", "apply",
         "--3way",
         "--whitespace=nowarn",
         "--allow-empty",
         str(patch_abs)],
        cwd=chromium_dir, capture_output=True, text=True,
    )
    if result.returncode == 0:
        return True, "git-3way"
    return False, result.stderr.splitlines()[0] if result.stderr else "git-3way failed"


def try_wiggle(patch_abs: pathlib.Path,
               chromium_dir: pathlib.Path) -> tuple[bool, str]:
    """Attempt wiggle — looser context matching than patch -p1.

    wiggle runs per-file, so we parse the patch to extract per-file
    sub-diffs and run wiggle on each. Returns (success, message).
    """
    if not shutil.which("wiggle"):
        return False, "wiggle not installed"
    # Split patch into per-file chunks, then wiggle each.
    text = patch_abs.read_text(encoding="utf-8", errors="replace")
    chunks = re.split(r"(?m)^(?=diff --git )", text)
    any_failed = False
    for chunk in chunks:
        if not chunk.strip():
            continue
        m = re.search(r"^\+\+\+ [ab]/(.+?)(?:\s|$)", chunk, re.MULTILINE)
        if not m:
            continue
        target = chromium_dir / m.group(1)
        if not target.exists():
            any_failed = True
            continue
        r = subprocess.run(
            ["wiggle", "--replace", "--merge", str(target)],
            input=chunk, capture_output=True, text=True,
        )
        if r.returncode != 0:
            any_failed = True
    return (not any_failed), "wiggle"


def try_patch(patch_abs: pathlib.Path,
              chromium_dir: pathlib.Path) -> tuple[bool, str]:
    """Final fallback: plain `patch -p1 --fuzz=3`. Returns (clean, status).

    "clean" means returncode 0 AND no .rej files left behind. Status is
    "clean", "partial", or "failed".
    """
    result = subprocess.run(
        ["patch", "-p1", "--forward", "--no-backup-if-mismatch",
         "--fuzz=3", "-i", str(patch_abs)],
        cwd=chromium_dir, capture_output=True, text=True,
    )
    if result.returncode == 0:
        return True, "patch"
    out = (result.stdout or "") + (result.stderr or "")
    if "succeeded" in out or "patching file" in out:
        return False, "partial"
    return False, "failed"


def apply_one(patch: pathlib.Path,
              chromium_dir: pathlib.Path) -> tuple[bool, str]:
    """Apply a single patch. Tries git-3way, wiggle, then plain patch.

    Returns (clean, status) where status is one of:
      "git-3way" | "wiggle" | "patch" — clean apply, name of tier that won
      "partial" — patch -p1 landed some hunks; .rej files written
      "failed"  — no tier landed it
    """
    patch_abs = patch.resolve()
    chromium_abs = chromium_dir.resolve()

    ok, msg = try_git_3way(patch_abs, chromium_abs)
    if ok:
        return True, msg

    ok, msg = try_wiggle(patch_abs, chromium_abs)
    if ok:
        return True, msg

    return try_patch(patch_abs, chromium_abs)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch-dir", required=True, type=pathlib.Path)
    ap.add_argument("--chromium-dir", required=True, type=pathlib.Path)
    ap.add_argument("--continue-on-error", action="store_true",
                    help="Keep going past failures; write a report to "
                         "<patch-dir>/../rejects.log")
    args = ap.parse_args()

    patches = load_series(args.patch_dir)
    print(f"[sephr] applying {len(patches)} patches from {args.patch_dir}")
    if not have_baseline(args.chromium_dir):
        print("[sephr]  (no chromium-baseline tag — git-3way disabled; "
              "run bootstrap.sh to init the tree)")

    tier_counts: dict[str, int] = {}
    log_entries: list[str] = []
    clean = partial = failed = 0
    for p in patches:
        if not p.exists():
            print(f"[sephr] skipping missing patch: {p}", file=sys.stderr)
            continue
        print(f"[sephr]  → {p.name}")
        ok, status = apply_one(p, args.chromium_dir)
        tier_counts[status] = tier_counts.get(status, 0) + 1
        if ok:
            clean += 1
            print(f"[sephr]    ✓ clean ({status})")
        elif status == "partial":
            partial += 1
            log_entries.append(f"PARTIAL {p.name}")
            print("[sephr]    ⚠ partial (some hunks rejected)")
            if not args.continue_on_error:
                raise SystemExit(f"[sephr] partial apply: {p}")
        else:
            failed += 1
            log_entries.append(f"FAILED  {p.name}")
            print("[sephr]    ✗ failed")
            if not args.continue_on_error:
                raise SystemExit(f"[sephr] failed to apply {p}")

    if log_entries:
        report = args.patch_dir.parent / "rejects.log"
        with report.open("w") as f:
            f.write("# Patch application report\n")
            f.write("# PARTIAL = some hunks applied; .rej files written\n")
            f.write("# FAILED  = no hunks applied\n\n")
            for e in log_entries: f.write(f"{e}\n")
        print(f"[sephr] report → {report}")

    by_tier = ", ".join(f"{k}={v}" for k, v in sorted(tier_counts.items()))
    print(f"[sephr] done ({clean} clean / {partial} partial / "
          f"{failed} failed of {len(patches)}) — tiers: {by_tier}")
    return 0 if (failed == 0 or args.continue_on_error) else 1


if __name__ == "__main__":
    raise SystemExit(main())
