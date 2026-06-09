#!/bin/bash
# perf_snapshot.sh -- Sephr CPU/RSS measurement harness.
#
# Usage: scripts/perf_snapshot.sh [--launch] [--settle N] [--url URL]
#                                 [--max-renderer PCT] [--max-gpu PCT] [--stacks]
# Exit code: 0 if within thresholds (or none given), 1 otherwise.
set -euo pipefail

APP="build/Sephr.app"
SETTLE=45
LAUNCH=0
URL=""
MAX_RENDERER=""
MAX_GPU=""
STACKS=0

usage() {
  cat <<'EOF'
Usage: scripts/perf_snapshot.sh [--launch] [--settle N] [--url URL]
                                [--max-renderer PCT] [--max-gpu PCT] [--stacks]
Exit code: 0 if within thresholds (or none given), 1 otherwise.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --launch) LAUNCH=1 ;;
    --settle) SETTLE="$2"; shift ;;
    --url) URL="$2"; shift ;;
    --max-renderer) MAX_RENDERER="$2"; shift ;;
    --max-gpu) MAX_GPU="$2"; shift ;;
    --stacks) STACKS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Run from the repo root so build/Sephr.app resolves regardless of cwd.
cd "$(dirname "$0")/.."

if [ "$LAUNCH" = 1 ]; then
  open "$APP"
  sleep 10
fi

if [ -n "$URL" ]; then
  open -a "$APP" "$URL"
fi

echo "settling ${SETTLE}s..."
sleep "$SETTLE"

TMP="$(mktemp -d /tmp/sephr_perf.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Three CPU samples 3s apart, averaged per PID.
# NOTE: macOS `top -l 1` reports 0.0% CPU for every process (the first sample
# has no delta to measure against), so a bare -l 1 snapshot is useless. We take
# 4 samples at 3s intervals in one invocation and discard the first, leaving
# three real delta samples 3s apart.
echo "sampling CPU (3 samples, 3s apart)..."
top -l 4 -s 3 -stats pid,cpu,command > "$TMP/top.txt"

awk '
  /^Processes:/ { blk++ }
  blk >= 2 && $1 ~ /^[0-9]+$/ { sum[$1] += $2; cnt[$1]++ }
  END { for (p in sum) printf "%s %.1f\n", p, sum[p] / cnt[p] }
' "$TMP/top.txt" > "$TMP/avg.txt"

avg_cpu_for() {
  awk -v p="$1" '$1 == p { print $2; f = 1 } END { if (!f) print "0.0" }' "$TMP/avg.txt"
}

classify() {
  local cmd="$1"
  case "$cmd" in
    *--type=gpu-process*) echo "gpu-process" ;;
    *--type=renderer*)    echo "renderer" ;;
    *--type=utility*)
      case "$cmd" in
        *network.mojom*) echo "util:network" ;;
        *storage.mojom*) echo "util:storage" ;;
        *)               echo "utility" ;;
      esac ;;
    *"Sephr Helper"*)     echo "helper:other" ;;
    *)                    echo "browser/main" ;;
  esac
}

# float comparison: returns 0 if $1 > $2
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# Snapshot the Sephr process list (excluding grep and this script). Done with
# process substitution -- NOT `ps | ... | while read` -- so the loop runs in
# the current shell and FAIL/HIGH_PIDS survive past `done`.
FAIL=0
HIGH_PIDS=""
printf '%-8s %-14s %8s %10s\n' "PID" "TYPE" "CPU%" "RSS(MB)"
while read -r pid rss cmd; do
  [ -n "${pid:-}" ] || continue
  type="$(classify "$cmd")"
  cpu="$(avg_cpu_for "$pid")"
  rss_mb=$(( rss / 1024 ))
  printf '%-8s %-14s %8s %10s\n' "$pid" "$type" "$cpu" "$rss_mb"

  if [ -n "$MAX_RENDERER" ] && [ "$type" = "renderer" ] && gt "$cpu" "$MAX_RENDERER"; then
    echo "FAIL: renderer pid $pid avg CPU ${cpu}% > ${MAX_RENDERER}%"
    FAIL=1
  fi
  if [ -n "$MAX_GPU" ] && [ "$type" = "gpu-process" ] && gt "$cpu" "$MAX_GPU"; then
    echo "FAIL: gpu-process pid $pid avg CPU ${cpu}% > ${MAX_GPU}%"
    FAIL=1
  fi
  if [ "$STACKS" = 1 ] && gt "$cpu" 10; then
    HIGH_PIDS="$HIGH_PIDS $pid"
  fi
done < <(ps -Axww -o pid=,rss=,command= | grep "Sephr" | grep -v -e grep -e perf_snapshot || true)

if [ "$STACKS" = 1 ] && [ -n "$HIGH_PIDS" ]; then
  for pid in $HIGH_PIDS; do
    out="/tmp/sephr_sample_${pid}.txt"
    if /usr/bin/sample "$pid" 3 -file "$out" >/dev/null 2>&1; then
      echo "stack sample: $out"
    else
      echo "stack sample FAILED for pid $pid" >&2
    fi
  done
fi

exit "$FAIL"
