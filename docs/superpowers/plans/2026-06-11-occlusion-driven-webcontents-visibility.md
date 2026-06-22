# Occlusion-Driven WebContents Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Sephr's renderer + GPU processes from burning CPU (~40% of a core, measured) when the window is covered, minimized, Cmd+H-hidden, or on another Space, by marking WebContents hidden whenever their window is not actually on glass.

**Architecture:** Today `SephriumWebContentsSetVisible` is driven only by `viewDidMoveToWindow` in `cal/Sources/CALWebView.mm` (in-window → visible, detached → hidden), so a backgrounded window's active tab renders forever. The fix: each `CALWebView` observes `NSWindowDidChangeOcclusionStateNotification` for its current window and computes effective visibility = *in a window* AND *window occlusion state contains `.visible`*. macOS clears `NSWindowOcclusionStateVisible` for covered, minimized, app-hidden, and other-Space windows, so one signal covers every case — and because the logic lives in `CALWebView` itself, tabs, split panes, link peeks, and adopted OAuth popups are all covered with zero per-call-site work. No Chromium framework rebuild: the `_SephriumWebContentsSetVisible` C ABI already exists and is idempotent with exact 3-state transitions (commits `fc3b0a9`, `28465a0`).

**Tech Stack:** Objective-C++ (`cal/` layer, compiled into the app by SwiftPM via `scripts/build_sephr.sh`), AppKit occlusion API, bash QA script driven by `osascript`/System Events.

**Verification model:** This is AppKit windowing behavior — there is no unit-test harness in this repo (QA is script-driven: `qa_regression.sh`, `qa_userflow.sh`). The "failing test" is a new automated system test `scripts/qa_battery.sh` that loads a CPU-spinning page, hides/minimizes the app, and asserts renderer CPU collapses. It is written FIRST and must FAIL against the current build.

**Pre-existing constraints (from project memory — do not violate):**
- Never use AppleScript `quit` against Sephr — it hangs in Chromium's AppController. Use `pkill -9` like the existing QA scripts.
- The hidden→visible transition at first attach is load-bearing (blank-tab bug, 2026-06-06). The plan preserves it: webviews are created hidden, and the first `_updateEffectiveVisibility` in a non-occluded window IS that transition.
- The working tree is dirty with unrelated in-progress changes (`CALExtensions.mm`, settings panes, etc.). Commit ONLY the files this plan touches: `cal/Sources/CALWebView.mm` and `scripts/qa_battery.sh`. Never `git add -A`.
- If the rebuild produces phantom "undeclared identifier" errors in CAL: stale clang ModuleCache — `rm -rf .build/**/ModuleCache` and rebuild.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/qa_battery.sh` | Create | Automated system test: spin page → hide/minimize → assert renderer CPU drops → re-show → assert it recovers |
| `cal/Sources/CALWebView.mm` | Modify (`@interface CALWebView ()` block at :8-17, `viewDidMoveToWindow` at :262-305, `dealloc` at :341-343) | Occlusion observation + effective-visibility computation |

No other files change. `CALWebView.h` is untouched (everything added is private). `sephr_overlay/` is untouched (it mirrors the Chromium-side bridge, not `cal/`).

---

### Task 1: `scripts/qa_battery.sh` — the failing system test

**Files:**
- Create: `scripts/qa_battery.sh`

- [ ] **Step 1: Write the test script**

Create `scripts/qa_battery.sh` with the following content:

```bash
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
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/qa_battery.sh`

- [ ] **Step 3: Run against the CURRENT build to verify it fails for the right reason**

Precondition: quit any running Sephr instance first (the script `pkill -9`s it — don't run while the user has live work in Sephr; check with `ps -Ao comm | grep 'MacOS/Sephr$'` and confirm with the user if it's running).

Run: `scripts/qa_battery.sh`

Expected: **SPIN-VISIBLE, UNHIDE-RESUMED, DEMINI-RESUMED = PASS; HIDE-PARKED and MINI-PARKED = FAIL** (renderer stays ≥10% while hidden/minimized), exit code 2.

If SPIN-VISIBLE fails, the harness itself is broken (URL routing or thresholds) — fix the script before proceeding; do NOT continue to Task 2 with a harness that can't see the hot renderer. Known wrinkle: `open -a <app> <url>` routes through the default-browser path (works warm + cold per 2026-06-08); if the page doesn't open, fall back to making the URL the cold-launch argument: `open -a "$(pwd)/$APP" --args "http://localhost:$PORT/spin.html"` is NOT the routing path — instead just retry `open -a ... "http://..."` once after launch (warm open).

- [ ] **Step 4: Commit the failing test**

```bash
git add scripts/qa_battery.sh
git commit -m "test: qa_battery asserts renderer parks when app hidden/minimized

Currently FAILS (HIDE-PARKED, MINI-PARKED): visibility is only driven by
viewDidMoveToWindow, so occluded windows keep rendering. Guard for the
battery-drain root cause diagnosed 2026-06-11.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Occlusion-driven effective visibility in CALWebView

**Files:**
- Modify: `cal/Sources/CALWebView.mm` (class extension at :8-17, `viewDidMoveToWindow` at :262-305, `dealloc` at :341-343)

- [ ] **Step 1: Declare the two private methods in the class extension**

In `cal/Sources/CALWebView.mm`, the class extension currently reads (lines 8-17):

```objc
@interface CALWebView ()
// Register every bridge callback (nav/favicon/loading/new-tab/target-url/
// popup/close) against the current _webContents. Shared by the URL-creating
// initializer and the popup-adopting one.
- (void)_wireContentsCallbacks;
// Build a CALWebView around an already-live WebContents handed up by the
// bridge (an adopted window.open popup) instead of creating a fresh one.
+ (instancetype)_adoptingWebContents:(SephriumWebContentsRef)ref
                             profile:(NSString*)profileID;
@end
```

Add two declarations before `@end`:

```objc
// Push effective visibility (in a window AND that window at least partially
// on glass) down to the WebContents. The single funnel for WasShown/WasHidden.
- (void)_updateEffectiveVisibility;
// NSWindowDidChangeOcclusionStateNotification handler for the current window.
- (void)_windowOcclusionDidChange:(NSNotification*)note;
```

- [ ] **Step 2: Rewrite `viewDidMoveToWindow` and add the two methods**

Replace the entire current `viewDidMoveToWindow` (lines 262-305, from `- (void)viewDidMoveToWindow {` through its closing `}`) with:

```objc
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];

    // Re-target occlusion observation at the current window. macOS clears
    // NSWindowOcclusionStateVisible for covered, minimized, Cmd+H-hidden,
    // and other-Space windows, so this one notification covers every
    // "window not actually on glass" case — without it the active tab of a
    // backgrounded window kept producing frames forever (renderer ~12% +
    // GPU ~17% CPU, the 2026-06-11 battery-drain root cause). Registered
    // even while asleep (_webContents NULL) so a wake() in an occluded
    // window starts out hidden.
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self
                  name:NSWindowDidChangeOcclusionStateNotification
                object:nil];
    if (self.window) {
        [nc addObserver:self
               selector:@selector(_windowOcclusionDidChange:)
                   name:NSWindowDidChangeOcclusionStateNotification
                 object:self.window];
    }

    if (!_webContents) return;

    if (!self.window) {
        // Left the window (tab switched away, split torn down, overlay
        // dismissed, …). Mark the WebContents hidden so the renderer parks
        // its paint loop AND so the next re-attach is a clean
        // hidden->visible transition. The chromium subview stays parented
        // to us — only the visibility flips.
        SephriumWebContentsSetVisible(_webContents, 0);
        return;
    }

    if (!_chromiumViewAttached) {
        NSView* chromiumView =
            (__bridge NSView*)SephriumWebContentsGetNativeView(_webContents);
        if (chromiumView) {
            [chromiumView removeFromSuperview];
            chromiumView.autoresizingMask =
                NSViewWidthSizable | NSViewHeightSizable;
            chromiumView.frame = self.bounds;
            [self addSubview:chromiumView];
            SephriumWebContentsSetSize(_webContents,
                                      (int)self.bounds.size.width,
                                      (int)self.bounds.size.height);
            _lastReportedSize = self.bounds.size;
            // Only latch once the native view is actually attached, so a
            // pass where the renderer view wasn't ready yet retries instead
            // of wedging the tab detached forever.
            _chromiumViewAttached = YES;
        }
    }

    // Entered a window — push effective visibility. The WebContents was
    // created hidden (see SephriumWebContentsCreate), so when the window is
    // on glass THIS is the hidden->visible transition that forces the
    // renderer to produce a frame for the now-attached surface. Without it
    // the first display of a tab could stay blank until a switch-away/back
    // cycle (reload didn't help — reload doesn't change visibility). If the
    // window is occluded right now (e.g. session restore behind another
    // app), we stay hidden and the occlusion notification performs that
    // same transition at first expose. Visibility-only, no page-freeze /
    // focus, so it's safe even before the initial navigation has committed.
    [self _updateEffectiveVisibility];
}

- (void)_windowOcclusionDidChange:(NSNotification*)note {
    [self _updateEffectiveVisibility];
}

- (void)_updateEffectiveVisibility {
    if (!_webContents) return;
    BOOL onGlass =
        self.window != nil &&
        (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0;
    // The bridge's SetVisible is idempotent with exact 3-state transitions
    // (fc3b0a9 / 28465a0), so repeated same-value pushes are free.
    SephriumWebContentsSetVisible(_webContents, onGlass ? 1 : 0);
}
```

Everything inside the `!_chromiumViewAttached` block and the `!self.window` branch is byte-identical to today's code — the diff is: observer re-targeting at the top, `SephriumWebContentsSetVisible(_webContents, 1)` replaced by `[self _updateEffectiveVisibility]`, the adapted comment, and the two new methods.

- [ ] **Step 3: Remove the observer in dealloc**

Replace (lines 341-343):

```objc
- (void)dealloc {
    [self _teardownWebContents];
}
```

with:

```objc
- (void)dealloc {
    // Non-block observers have been auto-removed since 10.11, but the
    // codebase style is explicit teardown.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _teardownWebContents];
}
```

- [ ] **Step 4: Rebuild the app**

```bash
scripts/build_sephr.sh && scripts/make_app.sh
```

Expected: both succeed; `build/Sephr.app` is reassembled. If CAL throws phantom "undeclared identifier" errors, clear the stale module cache and retry: `rm -rf .build/**/ModuleCache && scripts/build_sephr.sh && scripts/make_app.sh`.

- [ ] **Step 5: Run the battery test — must now fully pass**

Run: `scripts/qa_battery.sh`

Expected: all 5 checks PASS, exit 0.

Contingency (only if HIDE-PARKED still fails while MINI-PARKED passes): that macOS version isn't delivering an occlusion notification on app-hide. Add app-level observers in the same place — in `viewDidMoveToWindow`'s observer-retarget block, additionally register `_windowOcclusionDidChange:` for `NSApplicationDidHideNotification` and `NSApplicationDidUnhideNotification` with `object:NSApp` (and extend `_updateEffectiveVisibility`'s `onGlass` with `&& !NSApp.isHidden`). Do not add this speculatively — only on observed failure.

- [ ] **Step 6: Run the existing regression + userflow suites**

```bash
scripts/qa_regression.sh
scripts/qa_userflow.sh
```

Expected: `qa_regression.sh` exit 0. `qa_userflow.sh`: no NEW failures — AppleScript-quit failures are pre-existing and expected (project memory 2026-06-08); compare against a pre-change run if unsure.

Pay particular attention to any blank-tab symptom in userflow output: the first-attach hidden→visible transition is the historically fragile path (2026-06-06). The rewrite preserves it (`_updateEffectiveVisibility` performs the same transition when the window is on glass).

- [ ] **Step 7: Manual covered-window spot check (the case scripts can't drive)**

With the new build running and the spin page loaded: fully cover the Sephr window with another app's window (e.g. a maximized terminal), wait ~15s, then:

```bash
ps -Ao pcpu=,comm= | grep -E 'Sephr Helper' | sort -rn | head -3
```

Expected: hottest renderer AND the GPU helper (`Sephr Helper` with `--type=gpu-process`) both ≤ ~3%. Uncover the window → spin resumes visually with no blank flash. Also flick the window to another Space and back: parked on the other Space, resumes on return.

- [ ] **Step 8: Commit**

```bash
git add cal/Sources/CALWebView.mm
git commit -m "fix: park WebContents when window is occluded/minimized/hidden

CALWebView now observes NSWindowDidChangeOcclusionStateNotification for
its window and pushes effective visibility (in-window AND on-glass) via
the existing SetVisible ABI. Fixes the battery-drain root cause: the
active tab of a covered/minimized/Cmd+H/other-Space window rendered
forever (renderer ~12% + GPU ~17% CPU sustained). Verified by
scripts/qa_battery.sh (hide + minimize park/resume) and qa_regression.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

Note: commit ONLY `cal/Sources/CALWebView.mm` — the tree has unrelated in-flight changes.

---

## Out of Scope (explicitly deferred, do not bundle)

1. **Stray on-screen "Chromium"-titled window** (1024×822, observed 2026-06-11) — likely an unadopted Chromium-created popup holding a permanently visible WebContents. Separate investigation; needs its own diagnosis pass against the popup-adoption path (memory: oauth-popup-peek-2026-06-07).
2. **Lowering `SephrPreferences.sleepAfterMinutes` default (30)** — product decision; occlusion parking removes most of the battery cost of the 30-minute window anyway.
3. **True 3-state `WasOccluded()` in the bridge** — would require a Sephrium framework rebuild + `chrome/app/framework.exports` additions (silent-strip gotcha). `WasHidden` already parks frame production identically; no battery benefit to justify the rebuild.

## Self-Review (completed)

- **Spec coverage:** root cause = no occlusion handling → Task 2 adds it at the only visibility funnel; verification = Task 1 system test + Task 2 steps 5-7 (hide, minimize, covered, Space). Gaps deliberately moved to Out of Scope.
- **Placeholders:** none — full script and full method bodies included.
- **Type consistency:** `_updateEffectiveVisibility` / `_windowOcclusionDidChange:` names match between declaration (Task 2 Step 1) and implementation (Step 2); `renderer_cpu`/`cpu_ge`/`cpu_le` used as defined in Task 1.
