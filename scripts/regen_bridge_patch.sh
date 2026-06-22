#!/usr/bin/env bash
# Regenerates sephrium/patches/sephr/002-cal-webcontents-bridge.patch from
# the LIVE Chromium tree, so a clean bootstrap reproduces exactly what we
# build today.
#
# Run this after adding/removing a _Sephrium* line in
# .chromium-src/src/chrome/app/framework.exports (the build_sephrium.sh
# gate fails until you do). The bridge sources themselves are NOT in the
# patch — they live in sephr_overlay/ and bootstrap symlinks them in at
# src/chrome/sephr.
#
# Mechanics: preimage = live file minus our changes; hunks = diff -u
# preimage→live; self-verifies by replaying the fresh patch onto the
# preimage and comparing byte-for-byte with the live tree.
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE_EXPORTS=".chromium-src/src/chrome/app/framework.exports"
LIVE_GN=".chromium-src/src/chrome/BUILD.gn"
PATCH="sephrium/patches/sephr/002-cal-webcontents-bridge.patch"
DEP_LINE='      "//chrome/sephr/cal_bridge",'

test -f "$LIVE_EXPORTS" || { echo "[regen] FAIL: $LIVE_EXPORTS missing (no bootstrapped tree?)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/pre/chrome/app" "$WORK/post/chrome/app"

# Preimage exports = everything above our block marker, minus the trailing
# blank line the block introduces. Keeps working if upstream grows the file.
awk '/^# ---- Sephr CAL bridge/{exit} {print}' "$LIVE_EXPORTS" \
    | sed -e '${/^$/d;}' > "$WORK/pre/chrome/app/framework.exports"
grep -q '^# ---- Sephr CAL bridge' "$LIVE_EXPORTS" || {
    echo "[regen] FAIL: Sephr block marker not found in $LIVE_EXPORTS" >&2; exit 1; }

# Preimage BUILD.gn = live minus our single dep line (must remove exactly 1).
grep -vxF "$DEP_LINE" "$LIVE_GN" > "$WORK/pre/chrome/BUILD.gn"
DELTA=$(( $(wc -l < "$LIVE_GN") - $(wc -l < "$WORK/pre/chrome/BUILD.gn") ))
[ "$DELTA" -eq 1 ] || {
    echo "[regen] FAIL: expected exactly 1 cal_bridge dep line in chrome/BUILD.gn, removed $DELTA" >&2
    exit 1
}

cp "$LIVE_EXPORTS" "$WORK/post/chrome/app/framework.exports"
cp "$LIVE_GN"      "$WORK/post/chrome/BUILD.gn"

N_EXPORTS=$(grep -c '^_Sephrium' "$LIVE_EXPORTS")

(
cd "$WORK"
diff -u --label a/chrome/app/framework.exports --label b/chrome/app/framework.exports \
    pre/chrome/app/framework.exports post/chrome/app/framework.exports > exports.hunk || true
diff -u --label a/chrome/BUILD.gn --label b/chrome/BUILD.gn \
    pre/chrome/BUILD.gn post/chrome/BUILD.gn > buildgn.hunk || true
)

{
cat <<HDR
# Sephr — 002-cal-webcontents-bridge (slim overlay version)
#
# Wires Sephr's CAL bridge into the chrome_dll link. The bridge sources
# THEMSELVES live in this repo under sephr_overlay/cal_bridge/ and are
# symlinked into the Chromium tree at //chrome/sephr by bootstrap.sh
# (section 4b) — they do NOT live in this patch. //chrome/sephr matches
# the \`#include "chrome/sephr/cal_bridge/..."\` paths inside the bridge
# and the GN label below.
#
# Real upstream touchpoints (the ONLY thing 3-way merge has to rebase on
# every Chromium bump):
#   * chrome/app/framework.exports — the _Sephrium* exports list ($N_EXPORTS
#     symbols). Exported symbols are link roots; any extern "C" entry point
#     missing here is silently dead-stripped (the build_sephrium.sh gate
#     checks every name).
#   * chrome/BUILD.gn — one line, add //chrome/sephr/cal_bridge to
#     chrome_dll deps.
#
# GENERATED FILE — do not hand-edit the hunks. Regenerate from the live
# tree with scripts/regen_bridge_patch.sh (the build gate fails when this
# patch drifts from the live framework.exports).
HDR
cat "$WORK/exports.hunk"
cat "$WORK/buildgn.hunk"
} > "$WORK/002.patch.new"

# --- Self-verify: replay the fresh patch onto the preimage ------------------
(
cd "$WORK/pre"
patch -p1 --silent < "$WORK/002.patch.new"
)
cmp -s "$WORK/pre/chrome/app/framework.exports" "$LIVE_EXPORTS" || {
    echo "[regen] FAIL: replayed patch does not reproduce live framework.exports" >&2; exit 1; }
cmp -s "$WORK/pre/chrome/BUILD.gn" "$LIVE_GN" || {
    echo "[regen] FAIL: replayed patch does not reproduce live chrome/BUILD.gn" >&2; exit 1; }

if cmp -s "$WORK/002.patch.new" "$PATCH"; then
    echo "[regen] $PATCH already in sync ($N_EXPORTS exports) — no change."
else
    cp "$WORK/002.patch.new" "$PATCH"
    echo "[regen] $PATCH regenerated ($N_EXPORTS exports) + replay-verified."
fi
