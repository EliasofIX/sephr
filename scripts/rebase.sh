#!/usr/bin/env bash
# Sephr — one-command Chromium rebase.
#
# Goal: pulling Chromium updates = running this script.
#
# Usage:
#   scripts/rebase.sh                # use sephrium/chromium_version.txt as-is
#   scripts/rebase.sh <version>      # bump to <version>, then rebase
#                                    # e.g. 148.0.7755.42
#
# What this does (all idempotent; safe to re-run):
#   1. Pin Chromium version (if a version arg was given).
#   2. Sync vendor/ungoogled-chromium and copy in its patches + lists.
#      Picks the highest ungoogled tag matching the Chromium version.
#   3. Rebuild .chromium-src/src from the new tarball (only if version
#      changed or src/ is missing).
#   4. Init src/ as a git repo + chromium-baseline tag (skips if present).
#   5. Apply ungoogled patches with the three-tier strategy
#      (git-3way → wiggle → patch -p1).
#   6. Apply Sephr patches the same way; bail if any fail (Sephr patches
#      should always be clean — failure means manual rebase needed).
#   7. Domain substitution.
#   8. Build chrome_framework (the cheapest "did this actually work" test).
#
# What fails LOUDLY (intentional):
#   • No ungoogled tag for the requested Chromium version. Run with
#     UNGOOGLED_FORCE_LATEST=1 to take origin/main if you know what you
#     are doing.
#   • Sephr patches that don't apply clean. That means the Chromium
#     bump shifted internals enough that the CAL bridge or the keychain
#     patch can't reach their old anchors; manual hunk fix-up needed.
#
# What fails QUIETLY into the report (by design):
#   • ungoogled patches that don't apply at all are recorded in
#     sephrium/patches/rejects.log but do not abort the rebase. The
#     build step is the source of truth for whether the tree is usable.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

NEW_VERSION="${1:-}"
if [ -n "$NEW_VERSION" ]; then
    echo "$NEW_VERSION" > sephrium/chromium_version.txt
    echo "[sephr] Pinned Chromium version → $NEW_VERSION"
fi
CHROMIUM_VERSION="$(cat sephrium/chromium_version.txt)"

# ── 1. Sync ungoogled ──────────────────────────────────────────────────────
./scripts/sync_ungoogled.sh

# ── 2. Tarball + tree ──────────────────────────────────────────────────────
# bootstrap.sh is idempotent: short-circuits past any step whose output
# already exists. If the Chromium version changed, the new tarball will
# download and (since src/ already exists with the old contents) skip
# extraction — so we have to clear the tree explicitly on a version bump.
if [ -d .chromium-src/src ]; then
    EXISTING_VERSION=""
    if [ -f .chromium-src/src/chrome/VERSION ]; then
        EXISTING_VERSION="$(awk -F= '
            /^MAJOR=/ { m=$2 } /^MINOR=/ { n=$2 }
            /^BUILD=/ { b=$2 } /^PATCH=/ { p=$2 }
            END { printf "%s.%s.%s.%s", m, n, b, p }
        ' .chromium-src/src/chrome/VERSION)"
    fi
    if [ "$EXISTING_VERSION" != "$CHROMIUM_VERSION" ]; then
        echo "[sephr] src/ is Chromium $EXISTING_VERSION; bumping to $CHROMIUM_VERSION."
        echo "[sephr] Removing existing src/ for re-extract (preserves tarball cache)."
        rm -rf .chromium-src/src
    else
        echo "[sephr] src/ already at Chromium $CHROMIUM_VERSION."
        # Reset to baseline so we re-apply patches on a clean tree. This is
        # what makes "scripts/rebase.sh" idempotent across runs — it always
        # starts from vanilla and re-lays every patch with the latest tier
        # strategy.
        if [ -d .chromium-src/src/.git ] && \
           git -C .chromium-src/src rev-parse --verify --quiet chromium-baseline > /dev/null; then
            echo "[sephr] Resetting src/ to chromium-baseline..."
            (
                cd .chromium-src/src
                git reset -q --hard chromium-baseline
                git clean -qfdx -e out -e .cipd -e .cache
            )
            rm -f .chromium-src/src/.domain_substitution_applied
        fi
    fi
fi

# Run the full bootstrap (idempotent; downloads new tarball, extracts,
# inits git baseline, applies patches, runs domain sub).
./scripts/bootstrap.sh

# ── 3. Build (the verify gate) ─────────────────────────────────────────────
echo "[sephr] Bootstrap finished; building chrome_framework as smoke check..."
python3 sephrium/build.py --fast

# ── 4. Report ──────────────────────────────────────────────────────────────
SUMMARY="sephrium/patches/apply-summary.log"
echo
echo "[sephr] ── Rebase complete ──────────────────────────"
echo "[sephr] Chromium version : $CHROMIUM_VERSION"
echo "[sephr] Ungoogled ref    : $(cat sephrium/ungoogled_ref.txt 2>/dev/null || echo '?')"
echo "[sephr] Patch summary    : $SUMMARY"
if [ -f sephrium/patches/rejects.log ]; then
    REJECTS="$(wc -l < sephrium/patches/rejects.log)"
    echo "[sephr] ungoogled rejects : $REJECTS  (see sephrium/patches/rejects.log)"
fi
echo "[sephr] Framework built  : build/Sephrium.framework"
echo "[sephr] ─────────────────────────────────────────────"
