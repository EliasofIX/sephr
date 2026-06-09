#!/usr/bin/env python3
"""Apply ungoogled-chromium-style domain substitution to a Chromium tree.

Reads a list of regex patterns (one per line, `pattern=replacement`) and
rewrites occurrences across a list of files. This is a faithful
reimplementation of the subset of ungoogled-chromium's domain_substitution
behavior required by Sephrium. For deeper substitutions, run the upstream
tool from vendor/ungoogled-chromium/utils.

Usage:
    apply_domain_substitution.py \\
        --regex-file sephrium/domain_regex.list \\
        --substitution-file sephrium/domain_substitution.list \\
        apply <chromium_src>
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


def load_regexes(path: pathlib.Path) -> list[tuple[re.Pattern[str], str]]:
    """Parse ungoogled-chromium's domain_regex.list format:
        <regex>#<replacement>
    Split on the first unescaped '#'. Lines that begin with '#' alone are
    treated as comments."""
    rules: list[tuple[re.Pattern[str], str]] = []
    for line in path.read_text().splitlines():
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#!"):
            continue
        # Find the first '#' not preceded by a backslash. The regex itself
        # doesn't escape '#' in the upstream list, so a plain search works.
        idx = line.find("#")
        if idx <= 0:
            continue
        pattern, repl = line[:idx], line[idx + 1:]
        try:
            rules.append((re.compile(pattern), repl))
        except re.error as e:
            print(f"[sephr] skipping bad regex {pattern!r}: {e}",
                  file=sys.stderr)
    return rules


def iter_targets(list_file: pathlib.Path) -> list[str]:
    return [
        line.strip()
        for line in list_file.read_text().splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def apply(chromium_dir: pathlib.Path, targets: list[str],
          rules: list[tuple[re.Pattern[str], str]]) -> int:
    changed = 0
    for rel in targets:
        fp = chromium_dir / rel
        if not fp.exists():
            continue
        try:
            text = fp.read_text(encoding="utf-8", errors="surrogateescape")
        except UnicodeDecodeError:
            continue
        new = text
        for pattern, repl in rules:
            new = pattern.sub(repl, new)
        if new != text:
            fp.write_text(new, encoding="utf-8", errors="surrogateescape")
            changed += 1
    return changed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--regex-file", required=True, type=pathlib.Path)
    ap.add_argument("--substitution-file", required=True, type=pathlib.Path)
    ap.add_argument("command", choices=["apply"])
    ap.add_argument("chromium_dir", type=pathlib.Path)
    args = ap.parse_args()

    rules = load_regexes(args.regex_file)
    targets = iter_targets(args.substitution_file)
    print(f"[sephr] {len(rules)} rules × {len(targets)} targets")
    changed = apply(args.chromium_dir, targets, rules)
    print(f"[sephr] domain substitution applied to {changed} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
