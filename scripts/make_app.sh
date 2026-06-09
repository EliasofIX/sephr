#!/usr/bin/env bash
# Assembles Sephr.app from the SPM Sephr binary + the packaged
# Sephrium framework + Sparkle. Produces build/Sephr.app.
#
# Required structure (Apple conventions + Chromium constraints):
#
#   Sephr.app/
#     Contents/
#       Info.plist
#       MacOS/
#         Sephr                         (SPM-built executable)
#       Frameworks/
#         Sephr Framework.framework/    ← real bundle; helpers hard-code
#                                         this name in their dlopen
#                                         relative path (driven by the
#                                         BRANDING patch 014)
#           Versions/<v>/
#             Sephr Framework           (the dylib)
#             Helpers/ Resources/ Libraries/
#         Sephrium.framework -> Sephr Framework.framework
#                                      ← symlink so CAL's `-framework
#                                         Sephrium` LC_LOAD_DYLIB resolves
#         Sparkle.framework/            (auto-update)
#       Resources/
#         (icon + Assets.xcassets)
#
# Pass --release to package out/Release of the framework; otherwise
# out/Fast (matches build_sephrium.sh --fast). Codesigning is ad-hoc by
# default; pass --sign <identity> to use a Developer ID.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="--fast"
SIGN_IDENTITY="-"
SKIP_BUILD=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --release) MODE="--release"; shift ;;
        --fast)    MODE="--fast"; shift ;;
        --sign)    SIGN_IDENTITY="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        *) echo "[sephr] unknown arg: $1" >&2; exit 1 ;;
    esac
done

log() { printf '\n[sephr] %s\n' "$*"; }

CHROMIUM_VERSION="$(cat sephrium/chromium_version.txt)"
APP="build/Sephr.app"

# ── 1. Build inputs ────────────────────────────────────────────────────────
SWIFT_CONFIG="release"
if [ "$SKIP_BUILD" = "0" ]; then
    log "Building Sephrium framework ($MODE)..."
    bash scripts/build_sephrium.sh "$MODE"

    log "Building Sephr (swift build -c $SWIFT_CONFIG)..."
    swift build --product Sephr -c "$SWIFT_CONFIG"
fi

SEPHR_BIN=".build/$SWIFT_CONFIG/Sephr"
if [ ! -x "$SEPHR_BIN" ]; then
    echo "[sephr] missing $SEPHR_BIN — pass --skip-build only if it's there" >&2
    exit 1
fi

# Phase-2 packaging produces two sibling artefacts in build/:
#   * Sephr Framework.framework — the real bundle (helpers expect this
#     name; SetUpBundleOverrides in chrome_main.cc looks here too). The
#     "Sephr" prefix comes from the BRANDING patch (014) —
#     PRODUCT_FULLNAME=Sephr threads through chrome_framework's GN
#     bundle-name template.
#   * Sephrium.framework — a stub symlink wrapper for CAL link only.
# The .app bundle wants the real one + a stub sibling so dyld's @rpath
# resolution and helpers' hard-coded dlopen path both land correctly.
FW_REAL="build/Sephr Framework.framework"
if [ ! -d "$FW_REAL" ]; then
    echo "[sephr] no real framework at $FW_REAL — run scripts/build_sephrium.sh" >&2
    exit 1
fi
log "Framework source: $FW_REAL"

SPARKLE=".build/$SWIFT_CONFIG/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
    echo "[sephr] missing $SPARKLE — Sparkle wasn't bundled by SPM" >&2
    exit 1
fi

# ── 2. Lay out Sephr.app ───────────────────────────────────────────────────
log "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Resources"

# Executable
cp "$SEPHR_BIN" "$APP/Contents/MacOS/Sephr"

# Info.plist — the canonical one lives in sephr/Resources/. SPM doesn't
# auto-install it into the bundle so we copy explicitly.
cp sephr/Resources/Info.plist "$APP/Contents/Info.plist"

# Resources — Assets.xcassets + compiled AppIcon.icns. SPM doesn't
# compile xcassets to a .car, so we ship the raw catalog for
# NSImage(named:) lookups and the .icns for the Finder/Dock icon
# (Info.plist's CFBundleIconFile = "AppIcon" picks up Resources/AppIcon.icns).
if [ -d sephr/Resources/Assets.xcassets ]; then
    cp -R sephr/Resources/Assets.xcassets "$APP/Contents/Resources/"
fi
if [ -f sephr/Resources/AppIcon.icns ]; then
    cp sephr/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Framework — copy the canonical Sephr Framework.framework bundle
# preserving its internal symlink chain.
log "Copying Sephr Framework.framework (~510 MB)..."
cp -R "$FW_REAL" "$APP/Contents/Frameworks/Sephr Framework.framework"

# Sephrium.framework — NOT bundled at runtime.
#
# build/Sephrium.framework exists only as a link-time shim for CAL's
# `-framework Sephrium` clang/swift invocation: its Sephrium binary is a
# symlink to ../Sephr Framework.framework/Sephr Framework. After the
# 2026-06-05 BRANDING rebuild the inner framework directly exports the
# _Sephrium* C ABI (no thunks needed), and package_framework.py sets its
# install_name to @rpath/Sephr Framework.framework/Sephr Framework — so
# Sephr's LC_LOAD_DYLIB resolves straight to the real framework and the
# runtime never references @rpath/Sephrium.framework. Shipping the shim
# would only re-introduce a sign-broken bundle (codesign rejects a
# framework whose main binary is a symlink).

# Sparkle
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# ── 3. Code-sign ───────────────────────────────────────────────────────────
log "Code-signing (identity: $SIGN_IDENTITY)..."
ENTITLEMENTS="sephr/Resources/Sephr.entitlements"

# Signing posture is mode-dependent:
#
# Ad-hoc (SIGN_IDENTITY="-"): AMFI rejects ad-hoc binaries that claim
# entitlements like com.apple.security.cs.disable-library-validation or
# keychain-access-groups — those require a real Developer ID +
# provisioning profile. Claiming them under ad-hoc results in SIGKILL
# at launch (exit 137, no log). It also rejects --options=runtime
# (hardened runtime) for the same reason. Ad-hoc-to-ad-hoc library
# loads work without any of that; we sign plain and entitlements stay
# off — keychain-access-groups would be silently ignored anyway, so
# nothing of value is lost in this tier.
#
# Developer ID (SIGN_IDENTITY=real cert): use the full posture —
# entitlements + hardened runtime — so the bundle is notarization-
# ready and the platform authenticator's keychain access group binds.
if [ "$SIGN_IDENTITY" = "-" ]; then
    sign_with_ents() {
        codesign --force --sign "$SIGN_IDENTITY" "$@"
    }
    sign_plain() {
        codesign --force --sign "$SIGN_IDENTITY" "$@"
    }
else
    sign_with_ents() {
        codesign --force --sign "$SIGN_IDENTITY" \
            --entitlements "$ENTITLEMENTS" --options=runtime "$@"
    }
    sign_plain() {
        codesign --force --sign "$SIGN_IDENTITY" --options=runtime "$@"
    }
fi

shopt -s nullglob

# Inner dylib first (the helpers dlopen this — its signature must be
# baseline before we sign the helpers).
CF="$APP/Contents/Frameworks/Sephr Framework.framework"
sign_plain "$CF/Versions/$CHROMIUM_VERSION/Sephr Framework" || true

# Helpers — each needs the disable-library-validation entitlement so it
# can dlopen the (differently-signed) framework dylib above. Re-sign
# both the .app helpers and the raw executables.
for h in "$CF/Helpers/"*.app; do
    sign_with_ents "$h" || true
done
for h in "$CF/Helpers/"*; do
    [ -f "$h" ] && [ -x "$h" ] && sign_with_ents "$h" || true
done

# Framework + Sparkle bundles wrapping signature (no entitlements on the
# wrapper — they don't load anything themselves).
sign_plain "$CF" || true
sign_plain "$APP/Contents/Frameworks/Sparkle.framework" || true

# Sephrium.framework is intentionally NOT bundled (see the layout
# section above) so there is nothing to sign here.

# Top-level Sephr executable.
sign_with_ents "$APP" || true

# ── 4. Register with LaunchServices ─────────────────────────────────────────
# So the freshly-built bundle is discoverable as an http(s) handler — i.e.
# it shows up in System Settings → Desktop & Dock → "Default web browser"
# and `open -a Sephr <url>` resolves — without a logout/reboot. The plist
# now declares http/https in CFBundleURLTypes; lsregister -f makes
# LaunchServices re-read it from this exact path.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    log "Registering with LaunchServices..."
    "$LSREGISTER" -f "$APP" || true
fi

log "Done: $APP"
log "Launch:     open $APP"
log "From CLI:   $APP/Contents/MacOS/Sephr"
