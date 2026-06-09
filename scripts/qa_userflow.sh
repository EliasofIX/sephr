#!/usr/bin/env bash
# Sephr user-flow smoke — drives the running app through realistic
# interactions and checks the side effects on disk + helper count.
#
# Coverage:
#   * Launch + default tab → at least one Renderer helper spawns,
#     History DB grows after a page load
#   * Multiple-launch stability: 3 consecutive launches without
#     orphaned helpers between them
#   * Quit-via-Cocoa (AppleScript `tell ... quit`) → all helpers exit
#   * Re-launch after quit → state survives (Cookies/History intact)
#
# Doesn't try to drive AppKit text fields (no Accessibility/AppleScript
# permission assumed). For URL-bar smoke that needs AX, see future
# sephr-driver.

set -u
cd "$(dirname "$0")/.."

APP="build/Sephr.app"
PROFILE="$HOME/Library/Application Support/Sephr/Profiles/Default"
FAILED=0

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }

cleanup() {
    osascript -e 'tell application "Sephr" to quit' 2>/dev/null || true
    sleep 2
    pkill -9 -f 'Sephr.app/Contents/MacOS/Sephr' 2>/dev/null || true
    pkill -9 -f 'Sephr Helper' 2>/dev/null || true
}
trap cleanup EXIT

helper_count() {
    ps -ef | grep -c '[S]ephr Helper'
}

start_sephr() {
    "$APP/Contents/MacOS/Sephr" > "$1" 2>&1 &
    echo $!
}

# 1) cold start with empty profile-history
cleanup; sleep 1
ROWS_BEFORE=$(sqlite3 "$PROFILE/History" \
    "SELECT count(*) FROM urls" 2>/dev/null || echo 0)
echo "History rows before: $ROWS_BEFORE"
PID=$(start_sephr /tmp/qa_uf_1.log)
sleep 8

[ "$(helper_count)" -ge 4 ] && pass "≥4 helpers after 8s" \
                             || fail "only $(helper_count) helpers"

pgrep -f 'Sephr Helper.*type=renderer' >/dev/null \
    && pass "renderer spawned (default tab loading)" \
    || fail "no renderer"

# Give the default tab time to commit a navigation to disk.
sleep 5
ROWS_AFTER=$(sqlite3 "$PROFILE/History" \
    "SELECT count(*) FROM urls" 2>/dev/null || echo 0)
echo "History rows after: $ROWS_AFTER"
[ "$ROWS_AFTER" -gt "$ROWS_BEFORE" ] \
    && pass "History DB grew ($ROWS_BEFORE → $ROWS_AFTER)" \
    || fail "History DB didn't grow"

# 2) Cocoa quit drains the tree
osascript -e 'tell application "Sephr" to quit' 2>/dev/null
for i in 1 2 3 4 5 6 7 8; do
    [ "$(helper_count)" -eq 0 ] && break
    sleep 1
done
[ "$(helper_count)" -eq 0 ] \
    && pass "all helpers exited after Cocoa quit" \
    || fail "$(helper_count) helpers still running 8s after quit"

# 3) Re-launch and verify Cookies + History survive
PID=$(start_sephr /tmp/qa_uf_2.log)
sleep 6
[ -s "$PROFILE/Cookies" ] && pass "Cookies DB > 0 bytes after relaunch" \
                          || fail "Cookies DB missing/empty"
ROWS_RELAUNCH=$(sqlite3 "$PROFILE/History" \
    "SELECT count(*) FROM urls" 2>/dev/null || echo 0)
[ "$ROWS_RELAUNCH" -ge "$ROWS_AFTER" ] \
    && pass "History survives relaunch ($ROWS_RELAUNCH rows)" \
    || fail "History rows lost: $ROWS_RELAUNCH < $ROWS_AFTER"

# 4) Stability — open + quit 3 times in a row, no stragglers
osascript -e 'tell application "Sephr" to quit' 2>/dev/null
sleep 3
for run in 1 2 3; do
    P=$(start_sephr "/tmp/qa_uf_stab_${run}.log")
    sleep 5
    if ! ps -p "$P" >/dev/null; then
        fail "stability run #$run: process died"
        break
    fi
    osascript -e 'tell application "Sephr" to quit' 2>/dev/null
    sleep 4
    if [ "$(helper_count)" -gt 0 ]; then
        fail "stability run #$run: $(helper_count) orphaned helpers"
    else
        pass "stability run #$run: clean launch + quit"
    fi
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED check(s) failed"
exit "$FAILED"
