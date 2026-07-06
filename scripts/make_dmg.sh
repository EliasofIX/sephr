#!/usr/bin/env bash
# Packages build/Sephr.app into a beautifully styled, drag-to-install DMG.
#
#   scripts/make_dmg.sh            → build/Sephr-<version>.dmg
#   scripts/make_dmg.sh --out X.dmg
#
# The DMG mounts to a custom-sized Finder window with:
#   - the cream + black "caviar" background image (rendered by
#     scripts/make_dmg_background.py)
#   - Sephr.app on the left, /Applications symlink on the right
#   - 128px icons, no toolbar, no sidebar, label below
#   - the Sephr app icon as the volume icon (Finder sidebar)
#
# The app is ad-hoc signed; on a DIFFERENT Mac the downloaded copy carries
# a quarantine flag that Gatekeeper will block. After dragging to
# /Applications, run once on the target machine:
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
VOLNAME="Sephr ${VERSION}"

log "Rendering background images..."
python3 scripts/make_dmg_background.py

log "Composing multi-rep .tiff (1x + 2x Retina)..."
BG_TIFF="build/dmg_background.tiff"
rm -f "$BG_TIFF"
tiffutil -cathidpicheck \
    build/dmg_background.png \
    build/dmg_background@2x.png \
    -out "$BG_TIFF" >/dev/null

log "Verifying app signature (deep)..."
codesign --verify --deep "$APP"

STAGE="$(mktemp -d)"
DMG_TMP="$(mktemp -u).dmg"
MOUNT_DIR=""
cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" -quiet -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE"
    rm -f "$DMG_TMP"
}
trap cleanup EXIT

log "Staging app bundle (ditto preserves signatures)..."
ditto "$APP" "$STAGE/Sephr.app"
ln -s /Applications "$STAGE/Applications"

log "Re-verifying staged copy..."
codesign --verify --deep "$STAGE/Sephr.app"

# Size the writable image with ~40MB headroom over the staged content.
APP_KB=$(du -sk "$STAGE" | awk '{print $1}')
SIZE_KB=$(( APP_KB + 40000 ))

log "Creating writable DMG (${SIZE_KB} KB scratch)..."
hdiutil create \
    -srcfolder "$STAGE" \
    -volname "$VOLNAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -ov \
    "$DMG_TMP" >/dev/null

log "Mounting writable DMG..."
MOUNT_INFO=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP")
MOUNT_DIR=$(echo "$MOUNT_INFO" | awk -F'\t' '/\/Volumes\// {print $3}' | tail -1)
[ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ] || {
    echo "[dmg] failed to locate mount dir" >&2
    exit 1
}
log "Mounted at: $MOUNT_DIR"

log "Installing background + volume icon..."
mkdir -p "$MOUNT_DIR/.background"
cp "$BG_TIFF" "$MOUNT_DIR/.background/background.tiff"
# Use the app's icon as the mounted-volume icon (Finder sidebar + window).
cp sephr/Resources/AppIcon.icns "$MOUNT_DIR/.VolumeIcon.icns"
# Bless the volume so Finder honors .VolumeIcon.icns.
SetFile -a C "$MOUNT_DIR" 2>/dev/null || true

log "Styling Finder window via AppleScript..."
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 140, 860, 580}

        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set text size of theViewOptions to 12
        set label position of theViewOptions to bottom
        set shows item info of theViewOptions to false
        set shows icon preview of theViewOptions to false
        set background picture of theViewOptions to file ".background:background.tiff"

        set position of item "Sephr.app" of container window to {175, 230}
        set position of item "Applications" of container window to {485, 230}

        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Give Finder writes a moment to sync before unmounting.
sync; sleep 1

log "Unmounting..."
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

log "Compressing → $OUT"
rm -f "$OUT"
hdiutil convert "$DMG_TMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$OUT" >/dev/null

log "Verifying final DMG..."
hdiutil verify "$OUT" >/dev/null

log "Done."
ls -lh "$OUT"
shasum -a 256 "$OUT"
