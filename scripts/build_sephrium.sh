#!/usr/bin/env bash
# Builds Sephrium.framework from the prepared Chromium tree.
#
# Defaults to the fast inner-loop path (out/Fast, no LTO, chrome_framework
# target). Pass --release for the shippable build (out/Release, LTO, chrome).
set -euo pipefail

cd "$(dirname "$0")/.."

# depot_tools provides autoninja; the real `gn` binary lives in the tarball's
# buildtools/mac (the depot_tools `gn` wrapper can't locate it without a full
# gclient sync, failing with "Unable to find gn in your $PATH"). Prepend
# buildtools/mac so `gn` resolves to the real binary.
export PATH="$(cd "$(dirname "$0")/.." && pwd)/.chromium-src/src/buildtools/mac:$HOME/depot_tools:$PATH"

MODE="--fast"
if [ "${1:-}" = "--release" ]; then
    MODE="--release"
    shift || true
fi

# Overlay canary — src/chrome/sephr is a symlink INTO this repo
# (sephr_overlay/). A stray trailing-slash rm through the symlink would
# empty the overlay; fail here with the recovery instead of a cryptic GN
# "missing source" error.
if [ ! -f sephr_overlay/cal_bridge/cal_bridge.mm ]; then
    echo "[sephr] FAIL: sephr_overlay/cal_bridge/ is missing or empty." >&2
    echo "        Recover with: git checkout -- sephr_overlay/" >&2
    echo "        (then re-check 'git status' — uncommitted bridge work" >&2
    echo "        cannot be recovered this way)" >&2
    exit 1
fi

python3 sephrium/build.py "$MODE" "$@"
if [ "$MODE" = "--release" ]; then
    python3 sephrium/package_framework.py --release
else
    python3 sephrium/package_framework.py
fi
echo "[sephr] Sephrium.framework → $(pwd)/build/Sephrium.framework"

# --- Phase 1 gate: CAL bridge header + exported symbols ----------------------
HEADER="build/Sephrium.framework/Headers/cal_bridge.h"
DYLIB="build/Sephrium.framework/Sephrium"

test -f "$HEADER" || {
    echo "[sephr] FAIL: missing $HEADER" >&2
    echo "        package_framework.py should have copied it from" >&2
    echo "        .chromium-src/src/chrome/sephr/cal_bridge/cal_bridge.h" >&2
    exit 1
}

if ! nm -gU "$DYLIB" 2>/dev/null | grep -q ' _SephriumInitialize$'; then
    echo "[sephr] FAIL: _SephriumInitialize not exported from $DYLIB" >&2
    echo "        Check chrome/app/framework.exports has the _Sephrium* block" >&2
    echo "        and that //chrome/sephr/cal_bridge is in chrome_dll deps." >&2
    exit 1
fi

# Name-based export gate — no manual count to bump. Three set checks:
#   intended  (SEPHRIUM_EXPORT decls in cal_bridge.h)   ⊆ declared
#   declared  (_Sephrium lines in framework.exports)    ⊆ exported (nm)
#   patched   (+_Sephrium lines in patch 002)           == declared
# The first catches "forgot framework.exports" (symbol silently
# dead-stripped — the gate once passed on a raw count while a new export
# was missing). The second catches stripped/missing-dep symbols by name.
# The third keeps the clean-bootstrap patch in sync with the live tree —
# fix is one command, printed in the failure.
SRC_HDR=".chromium-src/src/chrome/sephr/cal_bridge/cal_bridge.h"
EXPORTS_FILE=".chromium-src/src/chrome/app/framework.exports"
PATCH_002="sephrium/patches/sephr/002-cal-webcontents-bridge.patch"

GATE_TMP="$(mktemp -d)"
trap 'rm -rf "$GATE_TMP"' EXIT

# Intended: join each decl (SEPHRIUM_EXPORT ... ;) across lines, then take
# Sephrium* tokens directly followed by '(' — function names only (typedef'd
# callback names are followed by ')', parameter uses by a space).
tr '\n' ' ' < "$SRC_HDR" \
    | grep -oE 'SEPHRIUM_EXPORT [^;]*' \
    | grep -oE 'Sephrium[A-Za-z0-9_]+ *\(' \
    | tr -d ' (' | sed 's/^/_/' | sort -u > "$GATE_TMP/intended"
grep '^_Sephrium' "$EXPORTS_FILE" | sort -u > "$GATE_TMP/declared"
nm -gU "$DYLIB" | grep -oE ' _Sephrium[A-Za-z0-9_]+$' | tr -d ' ' \
    | sort -u > "$GATE_TMP/exported"
grep '^+_Sephrium' "$PATCH_002" | sed 's/^+//' | sort -u > "$GATE_TMP/patched"

MISSING=$(comm -23 "$GATE_TMP/intended" "$GATE_TMP/declared")
if [ -n "$MISSING" ]; then
    echo "[sephr] FAIL: declared SEPHRIUM_EXPORT in cal_bridge.h but missing" >&2
    echo "        from chrome/app/framework.exports (will be silently" >&2
    echo "        dead-stripped from the dylib):" >&2
    echo "$MISSING" | sed 's/^/          /' >&2
    exit 1
fi

MISSING=$(comm -23 "$GATE_TMP/declared" "$GATE_TMP/exported")
if [ -n "$MISSING" ]; then
    echo "[sephr] FAIL: listed in framework.exports but not exported from" >&2
    echo "        $DYLIB (typo, or //chrome/sephr/cal_bridge missing from" >&2
    echo "        chrome_dll deps?):" >&2
    echo "$MISSING" | sed 's/^/          /' >&2
    exit 1
fi

if ! cmp -s "$GATE_TMP/declared" "$GATE_TMP/patched"; then
    echo "[sephr] FAIL: patch 002 is out of sync with the live" >&2
    echo "        framework.exports — clean bootstrap would not reproduce" >&2
    echo "        this build. Fix: ./scripts/regen_bridge_patch.sh" >&2
    diff "$GATE_TMP/patched" "$GATE_TMP/declared" | sed 's/^/          /' >&2 || true
    exit 1
fi

COUNT=$(wc -l < "$GATE_TMP/declared" | tr -d ' ')
echo "[sephr] CAL bridge: $HEADER + $COUNT _Sephrium* exports ✓ (header ⊆ exports ⊆ dylib, patch 002 in sync)"
