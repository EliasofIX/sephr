#!/usr/bin/env bash
# One-shot Sephr build pipeline. Produces build/Sephr.app ready to launch.
#
# Phases:
#   1. (Optional) scripts/bootstrap.sh — bring up .chromium-src + toolchains
#      + patches. Auto-skipped if .chromium-src/src already exists.
#   2. scripts/build_sephrium.sh — Chromium → Sephrium.framework
#   3. scripts/build_cal.sh        — CAL (SPM static library)
#   4. scripts/build_sephr.sh      — swift build --product Sephr -c release
#   5. scripts/make_app.sh         — assemble Sephr.app
#
# Modes:
#   --fast    (default) out/Fast, no LTO, ~1.5h fresh / <1min incremental
#   --release             out/Release, is_official_build + LTO, ~3h fresh.
#                         Use for the shippable .app.
#
# Sign:
#   --sign <identity>   passes through to make_app.sh; default is `-` (ad-hoc).
#                       For release set this to your Developer ID Application.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="--fast"
SIGN_IDENTITY="-"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --fast)    MODE="--fast"; shift ;;
        --release) MODE="--release"; shift ;;
        --sign)    SIGN_IDENTITY="$2"; shift 2 ;;
        *) echo "[sephr] unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { printf '\n[sephr] %s\n' "$*"; }

# 1. Bootstrap (idempotent)
if [ ! -d .chromium-src/src ]; then
    log "Bootstrapping Chromium tree (first-time setup, ~15 min)..."
    ./scripts/bootstrap.sh
fi

# 2-4. Framework + CAL + Sephr
./scripts/build_sephrium.sh "$MODE"
./scripts/build_cal.sh
./scripts/build_sephr.sh

# 5. Bundle
log "Assembling Sephr.app (--sign $SIGN_IDENTITY)..."
./scripts/make_app.sh "$MODE" --skip-build --sign "$SIGN_IDENTITY"

log "── ready ──"
log "Launch:  open build/Sephr.app"
log "Inspect: ls -la build/Sephr.app/Contents/Frameworks/"

if [ "$MODE" = "--release" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    log "──"
    log "NOTE: release build is ad-hoc signed. To distribute:"
    log "  1. Re-run with --sign 'Developer ID Application: <Your Team>'"
    log "  2. Notarize: xcrun notarytool submit build/Sephr.app.zip ..."
    log "  3. Staple:   xcrun stapler staple build/Sephr.app"
fi
