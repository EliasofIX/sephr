#!/usr/bin/env bash
# Sephr bootstrap — prepares Sephrium build tree from a clean checkout.
#
# Reproducibly produces .chromium-src/src ready for build_sephrium.sh.
# Steps:
#   1.  depot_tools clone (gn/autoninja/cipd come from here at PATH)
#   2.  Chromium "lite" tarball download + extract  (~1.5 GB → ~8.8 GB)
#   3.  Toolchains: gn, clang, rust, llvm-objdump, node, esbuild
#   4.  Missing git sub-repos (the lite tarball ships sources only)
#   5.  Apply ungoogled-chromium patches (clean)
#   6.  Apply Sephr patches             (clean for active series)
#   7.  Domain substitution
#
# All steps are idempotent — re-running short-circuits past completed work.
# Bootstrap is the slowest stage; expect ~10–15 min on a fresh M-series Mac
# (network-bound). After this, build_sephrium.sh --fast runs the build itself.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CHROMIUM_VERSION="$(cat sephrium/chromium_version.txt)"
SRC=".chromium-src/src"
LOG_DIR=".chromium-src"

# Mac arm64 only for now — every toolchain URL/cipd ref below is platform-
# specific. Generalize when Sephr ships another host platform.
case "$(uname -ms)" in
    "Darwin arm64") ;;
    *) echo "[sephr] bootstrap.sh only supports darwin arm64 (got $(uname -ms))" >&2; exit 1 ;;
esac

log() { printf '\n[sephr] %s\n' "$*"; }

# ── 1 — depot_tools ────────────────────────────────────────────────────────
if [ ! -d "$HOME/depot_tools" ]; then
    log "Cloning depot_tools..."
    git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "$HOME/depot_tools"
fi
export PATH="$HOME/depot_tools:$PATH"

# Skip depot_tools' bundled git/python on mac — system ones are fine and the
# bundled ones can shadow recent fixes.
export DEPOT_TOOLS_UPDATE=1
hash -r

# ── 2 — Chromium tarball ───────────────────────────────────────────────────
mkdir -p .chromium-src
cd .chromium-src
TARBALL="chromium-${CHROMIUM_VERSION}-lite.tar.xz"
TARBALL_HASHES="${TARBALL}.hashes"
BASE_URL="https://commondatastorage.googleapis.com/chromium-browser-official"

if [ ! -f "$TARBALL" ]; then
    log "Downloading $TARBALL (~1.5 GB)..."
    curl -fL -o "${TARBALL}.partial" "$BASE_URL/$TARBALL"
    mv "${TARBALL}.partial" "$TARBALL"
fi
if [ ! -f "$TARBALL_HASHES" ]; then
    log "Downloading $TARBALL_HASHES..."
    curl -fL -o "$TARBALL_HASHES" "$BASE_URL/$TARBALL_HASHES"
fi

log "Verifying SHA-512 of $TARBALL against upstream hashes..."
EXPECTED="$(awk '/^sha512/ {print $2}' "$TARBALL_HASHES")"
ACTUAL="$(shasum -a 512 "$TARBALL" | awk '{print $1}')"
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "[sephr] FAIL: SHA-512 mismatch for $TARBALL" >&2
    echo "         expected: $EXPECTED" >&2
    echo "         actual:   $ACTUAL"   >&2
    exit 1
fi

if [ ! -d src ]; then
    log "Extracting tarball (~8.8 GB on disk)..."
    # Tarball top-level dir is chromium-<version>/. Strip it to land at src/.
    mkdir -p src
    tar --strip-components=1 -xJf "$TARBALL" -C src
fi

# Init src/ as a git repo with a single "chromium-baseline" commit BEFORE any
# patch is applied. apply_patches.py uses `git apply --3way` against this
# baseline so context drift in ungoogled patches auto-resolves via git's
# merge engine instead of forcing manual rebase. Cost: ~2 min of git add
# on first bootstrap, then idempotent. The baseline tag is what makes
# Chromium bumps cheap.
if [ ! -d src/.git ]; then
    log "Initializing src/ as git repo + chromium-baseline tag..."
    (
        cd src
        git init -q -b main
        # Skip the Chromium-internal massive symlink farm and node_modules.
        # We only need pristine baseline for 3-way merge; if a patch touches
        # an ignored path it falls through to the wiggle/patch tier.
        # chrome/sephr is the Sephr overlay symlink (section 4b) — exclude
        # it so the overlay never shows up in src/ git status.
        printf 'out/\n.cipd/\n.cache/\nchrome/sephr\n' > .git/info/exclude
        # Use -c so commit metadata doesn't depend on whatever the host
        # user has globally configured.
        git -c user.email=bootstrap@sephr -c user.name=sephr-bootstrap \
            add -A
        git -c user.email=bootstrap@sephr -c user.name=sephr-bootstrap \
            commit -q -m "chromium ${CHROMIUM_VERSION} (vanilla lite tarball)"
        git tag chromium-baseline
    )
fi
cd "$ROOT"

# ── 3 — Toolchains ─────────────────────────────────────────────────────────
# 3a. gn (cipd) — buildtools/mac/gn
GN_VERSION_GIT_REV="d8c2f07d653520568da7cace755a87dad241b72d"
if [ ! -x "$SRC/buildtools/mac/gn" ]; then
    log "Installing gn (cipd gn/gn/mac-arm64)..."
    mkdir -p "$SRC/buildtools/mac"
    printf '%s git_revision:%s\n' "gn/gn/mac-arm64" "$GN_VERSION_GIT_REV" \
        > /tmp/gn.cipd.ensure
    cipd ensure -root "$SRC/buildtools/mac" -ensure-file /tmp/gn.cipd.ensure
fi

# 3b. clang (script knows its own pin — sets up third_party/llvm-build)
if [ ! -x "$SRC/third_party/llvm-build/Release+Asserts/bin/clang" ]; then
    log "Fetching clang (tools/clang/scripts/update.py)..."
    python3 "$SRC/tools/clang/scripts/update.py"
fi

# 3c. rust (script knows its own pin)
if [ ! -x "$SRC/third_party/rust-toolchain/bin/rustc" ]; then
    log "Fetching rust (tools/rust/update_rust.py)..."
    python3 "$SRC/tools/rust/update_rust.py"
fi

# 3d. llvm-objdump — update.py's --package=objdump path looks for a .tgz
# (chromium tooling bug); the bucket actually ships .tar.xz, so fetch it
# manually. CLANG_REVISION is exposed by the clang update script.
if [ ! -x "$SRC/third_party/llvm-build/Release+Asserts/bin/llvm-objdump" ]; then
    log "Fetching llvm-objdump (manual workaround)..."
    CLANG_REV="$(python3 -c '
import sys, pathlib
sys.path.insert(0, str(pathlib.Path("'"$SRC"'/tools/clang/scripts").resolve()))
import update
print(update.PACKAGE_VERSION)
')"
    OBJDUMP_URL="https://commondatastorage.googleapis.com/chromium-browser-clang/Mac_arm64/llvmobjdump-${CLANG_REV}.tar.xz"
    curl -fL -o /tmp/llvmobjdump.tar.xz "$OBJDUMP_URL"
    tar -xJf /tmp/llvmobjdump.tar.xz -C "$SRC/third_party/llvm-build/Release+Asserts"
    rm -f /tmp/llvmobjdump.tar.xz
fi

# 3e. node mac_arm64 (gcs object — DEPS pins it by sha256)
if [ ! -x "$SRC/third_party/node/mac_arm64/node-darwin-arm64/bin/node" ]; then
    log "Fetching node mac_arm64..."
    NODE_OBJECT="6661e9b9bd7df6b45daf506c82d06d303597cb27"
    NODE_URL="https://commondatastorage.googleapis.com/chromium-nodejs/$NODE_OBJECT"
    mkdir -p "$SRC/third_party/node/mac_arm64"
    curl -fL -o "$SRC/third_party/node/mac_arm64/node-darwin-arm64.tar.gz" "$NODE_URL"
    tar -xzf "$SRC/third_party/node/mac_arm64/node-darwin-arm64.tar.gz" \
        -C "$SRC/third_party/node/mac_arm64"
fi

# 3f. esbuild (cipd)
ESBUILD_VERSION="version:3@0.25.1.chromium.2"
if [ ! -x "$SRC/third_party/devtools-frontend/src/third_party/esbuild/esbuild" ]; then
    log "Installing esbuild (cipd infra/3pp/tools/esbuild/mac-arm64)..."
    mkdir -p "$SRC/third_party/devtools-frontend/src/third_party/esbuild"
    printf '%s %s\n' "infra/3pp/tools/esbuild/mac-arm64" "$ESBUILD_VERSION" \
        > /tmp/esbuild.cipd.ensure
    cipd ensure -root "$SRC/third_party/devtools-frontend/src/third_party/esbuild" \
        -ensure-file /tmp/esbuild.cipd.ensure
fi

# ── 4 — Missing src sub-repos ──────────────────────────────────────────────
# The "lite" tarball ships only chromium itself — `gclient sync` would pull
# the remainder, but we deliberately don't. Mac targets need this one.
GTM_REV="42b12f10cd8342f5cb41a1e3e3a2f13fd9943b0d"
if [ ! -d "$SRC/third_party/google_toolbox_for_mac/src/.git" ]; then
    log "Cloning google_toolbox_for_mac @ ${GTM_REV:0:12}..."
    rm -rf "$SRC/third_party/google_toolbox_for_mac/src"
    git clone --no-checkout \
        https://chromium.googlesource.com/external/github.com/google/google-toolbox-for-mac.git \
        "$SRC/third_party/google_toolbox_for_mac/src"
    git -C "$SRC/third_party/google_toolbox_for_mac/src" checkout "$GTM_REV"
fi

# ── 4c — uBlock Origin (built-in component extension) ─────────────────────
bash scripts/fetch_ublock_origin.sh
python3 scripts/generate_ios_ublock_rules.py

# ── 4b — Sephr source overlay ──────────────────────────────────────────────
# CAL bridge sources live OUTSIDE the Chromium tree (sephr_overlay/) so a
# Chromium bump never touches our source layout. Drop them into the build
# tree as a symlink at //chrome/sephr → exposed to GN as
# //chrome/sephr/cal_bridge, which is the label patch 002 wires into
# chrome_dll deps and the path every `#include "chrome/sephr/..."` in the
# bridge assumes. (Historical note: this used to land at //sephr, which
# meant a clean bootstrap laid the bridge at a different GN path than the
# one the working tree built — reconciled 2026-06-12.)
# Symlink keeps edits live during dev; `git status` in src/ stays clean
# because the overlay path is excluded on the baseline init.
if [ -L "$SRC/sephr" ]; then
    # Pre-reconciliation location — remove so a stale //sephr label can't
    # mask broken //chrome/sephr wiring.
    log "Removing stale src/sephr symlink (overlay now at src/chrome/sephr)"
    rm "$SRC/sephr"
fi
if [ ! -e "$SRC/chrome/sephr" ]; then
    log "Linking sephr_overlay/ → src/chrome/sephr"
    ln -s "$ROOT/sephr_overlay" "$SRC/chrome/sephr"
elif [ -L "$SRC/chrome/sephr" ]; then
    # Re-point in case ROOT moved (the rebrand from Agena/Sephrium did this).
    ln -snf "$ROOT/sephr_overlay" "$SRC/chrome/sephr"
fi

# ── 5 — ungoogled-chromium patches ─────────────────────────────────────────
log "Applying ungoogled-chromium patches..."
python3 sephrium/apply_patches.py \
    --patch-dir sephrium/patches/ungoogled \
    --chromium-dir "$SRC" \
    --continue-on-error \
    >"$LOG_DIR/patch_ungoogled.log" 2>&1
tail -1 "$LOG_DIR/patch_ungoogled.log"

# ── 6 — Sephr patches ──────────────────────────────────────────────────────
log "Applying Sephr patches..."
python3 sephrium/apply_patches.py \
    --patch-dir sephrium/patches/sephr \
    --chromium-dir "$SRC" \
    --continue-on-error \
    >"$LOG_DIR/patch_sephr.log" 2>&1
tail -1 "$LOG_DIR/patch_sephr.log"

# ── 7 — Domain substitution ────────────────────────────────────────────────
# Idempotent: apply_domain_substitution writes a marker file when applied;
# re-running short-circuits.
if [ ! -f "$SRC/.domain_substitution_applied" ]; then
    log "Applying domain substitution..."
    python3 sephrium/apply_domain_substitution.py \
        --regex-file sephrium/domain_regex.list \
        --substitution-file sephrium/domain_substitution.list \
        apply "$SRC" \
        >"$LOG_DIR/domain_sub.log" 2>&1
    touch "$SRC/.domain_substitution_applied"
fi

log "── Bootstrap complete ──────────────────────────"
log "Next: scripts/build_sephrium.sh --fast"
log "──────────────────────────────────────────────"
