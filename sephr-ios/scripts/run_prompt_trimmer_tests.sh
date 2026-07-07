#!/usr/bin/env bash
# Compile and run pure-Swift inference budget / prompt trimmer tests on
# Linux CI where Xcode isn't available. Mirrors SephrTests coverage for
# the LEAP-free Intelligence helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/Intelligence"
BIN="$(mktemp)"
trap 'rm -f "$BIN"' EXIT

swiftc -O \
  "$SRC/InferenceBudget.swift" \
  "$SRC/TextBudget.swift" \
  "$SRC/PromptTrimmer.swift" \
  "$ROOT/scripts/prompt_trimmer_test_main.swift" \
  -o "$BIN"

"$BIN"
echo "prompt_trimmer tests passed"
