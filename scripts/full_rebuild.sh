#!/usr/bin/env bash
# Full Sephr rebuild: bootstrap → Sephrium release → Sephr.app
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="$PWD/.last_full_rebuild_log"
exec > >(tee -a "$LOG") 2>&1

log() { printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

log "=== FULL REBUILD START ==="

log "Step 1/3: bootstrap (patches + uBlock fetch) — skip if tree ready"
if ! bash scripts/bootstrap.sh; then
    log "bootstrap reported errors; continuing if chromium tree exists"
fi

log "Step 2/3: Sephrium release build"
bash scripts/build_sephrium.sh --release

log "Step 3/3: make Sephr.app"
bash scripts/make_app.sh --release --skip-build

log "=== FULL REBUILD COMPLETE ==="
