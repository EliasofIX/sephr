#!/usr/bin/env bash
# Packages build/Sephr.app into a compressed, drag-to-install DMG.
#
#   scripts/make_dmg.sh            → build/Sephr-<version>.dmg
#   scripts/make_dmg.sh --out X.dmg
#
# The DMG contains Sephr.app + an /Applications symlink so the user can
# drag it across. The app is ad-hoc signed; on a DIFFERENT Mac the
# downloaded copy carries a quarantine flag that Gatekeeper will block.
# After dragging to /Applications, run once on the target machine:
#
#   xattr -cr /Applications/Sephr.app && open /Applications/Sephr.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Sephr.app"
OUT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) echo "[dmg] unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { printf '\n[dmg] %s\n' "$*"; }

[ -d "$APP" ] || { echo "[dmg] $APP not found — run scripts/make_app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ -n "$OUT" ] || OUT="build/Sephr-${VERSION}.dmg"

log "Verifying app signature (deep)..."
codesign --verify --deep "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

log "Staging app bundle (ditto preserves signatures)..."
ditto "$APP" "$STAGE/Sephr.app"
ln -s /Applications "$STAGE/Applications"

log "Re-verifying staged copy..."
codesign --verify --deep "$STAGE/Sephr.app"

log "Building compressed DMG → $OUT"
rm -f "$OUT"
hdiutil create \
    -volname "Sephr ${VERSION}" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$OUT"

log "Done."
ls -lh "$OUT"
shasum -a 256 "$OUT"
