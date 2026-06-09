#!/usr/bin/env bash
# Deprecated — forwards to scripts/rebase.sh, which does the same job in one
# command (sync ungoogled, re-extract tarball if version changed, init git
# baseline, apply patches with three-tier strategy, build).
exec "$(dirname "$0")/rebase.sh" "$@"
