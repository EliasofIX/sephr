#!/usr/bin/env bash
# Sync sephrium/patches/ungoogled/ from upstream ungoogled-chromium.
#
# Usage:
#   scripts/sync_ungoogled.sh                  # pin to the tag matching
#                                              # sephrium/chromium_version.txt
#   scripts/sync_ungoogled.sh <ref>            # explicit ref (tag/branch/sha)
#   UNGOOGLED_FORCE_LATEST=1 scripts/sync_ungoogled.sh
#                                              # ignore version pin, take main
#
# What this does:
#   1. Clones vendor/ungoogled-chromium on first run (depth-1 main + tags).
#   2. Fetches and checks out the ref. By default the ref is derived from
#      sephrium/chromium_version.txt — ungoogled tags are `<chromium>-<rev>`.
#   3. Rsyncs vendor/.../patches/ → sephrium/patches/ungoogled/ and copies
#      the domain/pruning lists.
#
# Does NOT re-apply patches — use scripts/rebase.sh (or the next bootstrap)
# for that.
set -euo pipefail

cd "$(dirname "$0")/.."

REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium.git"
VENDOR="vendor/ungoogled-chromium"
CHROMIUM_VERSION="$(cat sephrium/chromium_version.txt)"

# Init clone on first run.
if [ ! -d "$VENDOR/.git" ]; then
    echo "[sephr] vendor/ungoogled-chromium missing — cloning..."
    mkdir -p vendor
    rm -rf "$VENDOR"
    git clone --filter=blob:none "$REPO_URL" "$VENDOR"
fi

# Always refresh tags + main before deciding what to check out.
git -C "$VENDOR" fetch --tags --force origin

# Decide which ref to use.
if [ -n "${1:-}" ]; then
    REF="$1"
elif [ "${UNGOOGLED_FORCE_LATEST:-0}" = "1" ]; then
    REF="origin/main"
else
    # ungoogled tags are `<chromium-version>-<rev>` (e.g. 147.0.7727.101-1).
    # Pick the highest-rev tag for our pinned Chromium version.
    REF="$(git -C "$VENDOR" tag --list "${CHROMIUM_VERSION}-*" \
            | sort -t- -k2 -n | tail -1)"
    if [ -z "$REF" ]; then
        echo "[sephr] no ungoogled tag matches Chromium $CHROMIUM_VERSION yet." >&2
        echo "[sephr] options:" >&2
        echo "[sephr]   • wait for ungoogled-chromium to tag this Chromium release," >&2
        echo "[sephr]   • run with UNGOOGLED_FORCE_LATEST=1 to take origin/main," >&2
        echo "[sephr]   • pass an explicit ref:  scripts/sync_ungoogled.sh <tag-or-sha>" >&2
        exit 1
    fi
    echo "[sephr] picked ungoogled ref: $REF"
fi

git -C "$VENDOR" checkout -q --detach "$REF"

# Capture which ref we landed on for downstream observability.
echo "$REF" > sephrium/ungoogled_ref.txt
git -C "$VENDOR" rev-parse HEAD > sephrium/ungoogled_sha.txt

rsync -a --delete \
    "$VENDOR/patches/" \
    sephrium/patches/ungoogled/

# Refresh domain lists too — they live at the repo root of
# ungoogled-chromium and change more often than the patches.
cp "$VENDOR/domain_substitution.list" sephrium/
cp "$VENDOR/domain_regex.list"        sephrium/
cp "$VENDOR/pruning.list"             sephrium/
cp "$VENDOR/downloads.ini"            sephrium/

echo "[sephr] ungoogled-chromium synced @ $REF ($(git -C "$VENDOR" rev-parse --short HEAD))"
echo "[sephr] Next: scripts/rebase.sh   (or re-run scripts/bootstrap.sh for a fresh tree)"
