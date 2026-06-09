#!/usr/bin/env bash
# Builds Sephrium.framework from the prepared Chromium tree.
#
# Defaults to the fast inner-loop path (out/Fast, no LTO, chrome_framework
# target). Pass --release for the shippable build (out/Release, LTO, chrome).
set -euo pipefail

cd "$(dirname "$0")/.."

export PATH="$HOME/depot_tools:$PATH"

MODE="--fast"
if [ "${1:-}" = "--release" ]; then
    MODE="--release"
    shift || true
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

EXPECTED=33   # +1 SephriumSetOpenExternalURLCallback — routes external URL
              #   opens (default-browser link clicks, Handoff, cold-launch
              #   URL) into Sephr/CAL tabs instead of a native Chromium
              #   window. Hooked at AppController -openUrlsReplacingNTP:.
              # +2 popup exports (SetPopupRequestCallback /
              #   SetCloseRequestCallback) — window.open/OAuth popups are
              #   adopted with their opener intact and shown in a peek
              #   (e.g. claude.ai "Continue with Google").
              # +4 Extensions bridge exports (Subscribe / SetEnabled /
              #   Uninstall / InstallCRX) — native chrome://extensions
              #   replacement.
              # Phase 1 baseline (20) + SephriumSetUiBootCallback (Phase 2)
              # + SephriumWebContentsSetFaviconCallback (favicon plumbing)
              # + SephriumWebContentsSetLoadingCallback (loading indicator)
              # + SephriumWebContentsSetNewTabRequestCallback (right-click
              #   context menu's "Open in New Tab" handoff).
              # + SephriumWebContentsSetVisible (visibility-only WasShown/
              #   WasHidden, driven by CALWebView window membership — fixes
              #   tabs painting blank until a switch-away/back cycle).
              # + SephriumWebContentsSetTargetURLCallback (hovered-link URL,
              #   drives the Shift+hover link-peek gesture).
COUNT=$(nm -gU "$DYLIB" | grep -c ' _Sephrium' || true)
if [ "$COUNT" -lt "$EXPECTED" ]; then
    echo "[sephr] FAIL: expected $EXPECTED _Sephrium* exports, found $COUNT" >&2
    nm -gU "$DYLIB" | grep ' _Sephrium' >&2 || true
    exit 1
fi

echo "[sephr] CAL bridge: $HEADER + $COUNT exported _Sephrium* symbols ✓"
