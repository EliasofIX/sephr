#!/usr/bin/env bash
# Sephr battery QA — asserts that renderer CPU collapses when the app's
# windows leave the screen (hidden / minimized) and recovers on re-show.
#
# Root cause this guards: visibility was driven only by viewDidMoveToWindow,
# so a covered/minimized/hidden window's active tab kept producing frames
# forever (GPU ~17% + renderers ~12% measured on 2026-06-11).
#
# Checks (each prefixed [PASS]/[FAIL], exit code = failure count):
#   SPIN-VISIBLE   renderer CPU >= 10% with an animation page frontmost
#   HIDE-PARKED    after Cmd+H (System Events), renderer CPU <= 2%
#   UNHIDE-RESUMED after unhide, renderer CPU >= 10% again
#   MINI-PARKED    after AXMinimized=true, renderer CPU <= 2%
#   DEMINI-RESUMED after AXMinimized=false, renderer CPU >= 10% again
#
# NOTE: never AppleScript-quit Sephr (hangs in Chromium AppController);
# pkill -9 like the other QA scripts.

set -u
cd "$(dirname "$0")/.."

APP="build/Sephr.app"
PORT=8943
FAILED=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }

cleanup() {
    pkill -9 -f 'Sephr.app/Contents/MacOS/Sephr' 2>/dev/null || true
    pkill -9 -f 'Sephr Helper' 2>/dev/null || true
    [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null || true
}
trap cleanup EXIT

[ -d "$APP" ] || { fail "missing $APP — run make_app.sh first"; exit 1; }

# ── Spin page: rAF + canvas paint keeps a renderer hot while visible ──────
SPIN_DIR=$(mktemp -d /tmp/sephr_qa_battery.XXXXXX)
cat > "$SPIN_DIR/spin.html" <<'HTML'
<!doctype html><title>spin</title>
<canvas id="c" width="800" height="600"></canvas>
<script>
const ctx = document.getElementById('c').getContext('2d');
let i = 0;
(function frame() {
  i++;
  for (let y = 0; y < 600; y += 20)
    for (let x = 0; x < 800; x += 20) {
      ctx.fillStyle = `hsl(${(i + x + y) % 360},90%,50%)`;
      ctx.fillRect(x, y, 18, 18);
    }
  requestAnimationFrame(frame);
})();
</script>
HTML

python3 -m http.server "$PORT" --directory "$SPIN_DIR" >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1

cleanup_app_only() {
    pkill -9 -f 'Sephr.app/Contents/MacOS/Sephr' 2>/dev/null || true
    pkill -9 -f 'Sephr Helper' 2>/dev/null || true
}
cleanup_app_only
sleep 1

open -a "$(pwd)/$APP" "http://localhost:$PORT/spin.html"
sleep 12   # cold launch + navigation + decaying %cpu warm-up

# Hottest renderer's %cpu (ps pcpu = decaying average ≈ recent CPU).
renderer_cpu() {
    ps -Ao pcpu=,comm= \
        | grep 'Sephr Helper (Renderer)' \
        | awk '{print $1}' | sort -rn | head -1
}
# bc-free float compare: cpu_ge 10 → hottest renderer >= 10%
cpu_ge() { [ -n "$(renderer_cpu)" ] && awk -v a="$(renderer_cpu)" -v b="$1" 'BEGIN{exit !(a>=b)}'; }
cpu_le() { [ -n "$(renderer_cpu)" ] && awk -v a="$(renderer_cpu)" -v b="$1" 'BEGIN{exit !(a<=b)}'; }

se() { osascript -e "tell application \"System Events\" to $1"; }

cpu_ge 10 && pass "SPIN-VISIBLE renderer >= 10% ($(renderer_cpu)%)" \
          || fail "SPIN-VISIBLE renderer < 10% ($(renderer_cpu)%) — spin page not painting?"

# ── Hide (Cmd+H equivalent) ────────────────────────────────────────────────
se 'set visible of application process "Sephr" to false'
sleep 20   # let the decaying average fall
cpu_le 2 && pass "HIDE-PARKED renderer <= 2% ($(renderer_cpu)%)" \
         || fail "HIDE-PARKED renderer still hot while app hidden ($(renderer_cpu)%)"

se 'set visible of application process "Sephr" to true'
open -a "$(pwd)/$APP"   # ensure ordered front
sleep 12
cpu_ge 10 && pass "UNHIDE-RESUMED renderer >= 10% ($(renderer_cpu)%)" \
          || fail "UNHIDE-RESUMED renderer did not resume ($(renderer_cpu)%)"

# ── Minimize ───────────────────────────────────────────────────────────────
se 'set value of attribute "AXMinimized" of window 1 of application process "Sephr" to true'
sleep 20
cpu_le 2 && pass "MINI-PARKED renderer <= 2% ($(renderer_cpu)%)" \
         || fail "MINI-PARKED renderer still hot while minimized ($(renderer_cpu)%)"

se 'set value of attribute "AXMinimized" of window 1 of application process "Sephr" to false'
open -a "$(pwd)/$APP"
sleep 12
cpu_ge 10 && pass "DEMINI-RESUMED renderer >= 10% ($(renderer_cpu)%)" \
          || fail "DEMINI-RESUMED renderer did not resume ($(renderer_cpu)%)"

rm -rf "$SPIN_DIR"
echo "qa_battery: $FAILED failure(s)"
exit "$FAILED"
