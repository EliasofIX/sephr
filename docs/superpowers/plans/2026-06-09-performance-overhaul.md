# Sephr Performance Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Sephr's CPU/energy profile to parity with other Chromium browsers: kill the continuous repaint loop (41% renderer / 31% GPU at idle today), ship the official Release build, replace the global notification broadcast with per-tab events, and add renderer lifecycle management (spare renderer + sleeping tabs).

**Architecture:** Five sequenced workstreams from the approved spec (`docs/superpowers/specs/2026-06-09-performance-overhaul-design.md`): measurement harness → repaint-loop fix (CAL bridge / Chromium embedding) → Release build → Swift event architecture → renderer lifecycle. Each workstream gates on numbers from the harness.

**Tech Stack:** Bash + macOS `top`/`ps`/`/usr/bin/sample` (harness); ObjC++ CAL bridge in `.chromium-src/src/chrome/sephr/cal_bridge/` + `cal/Sources/`; Chromium GN/ninja (`sephrium/flags.gn`); Swift 5.9 SPM app in `sephr/Sources/`; XCTest via a new `SephrKit` library target.

**Critical context for every task:**
- The compiled bridge source is `.chromium-src/src/chrome/sephr/cal_bridge/` — edit THAT copy, then re-sync `sephr_overlay/cal_bridge/` (it is a backup mirror).
- New C ABI exports MUST be added to `.chromium-src/src/chrome/app/framework.exports` or they are silently stripped.
- After a framework rebuild: re-copy packaged headers and clear `.build/**/ModuleCache` (stale-module-cache gotcha).
- Re-signing a launched `build/Sephr.app` fails with `com.apple.provenance` errors → `xattr -cr build/Sephr.app && codesign ...` (dev-loop gotcha). Always quit Sephr before repackaging.
- `sample` (no path) is shadowed by a Python script on this machine — always use `/usr/bin/sample`.
- Liquid Glass / `.glassEffect` code is OUT OF SCOPE. Do not touch it, even if it looks expensive.
- This machine also has Helium.app (another Chromium browser) — the reference for "good" idle numbers.

---

## Task 0: Initialize git repository

The project directory is not a git repo (no `.git` anywhere up the tree), but this plan requires frequent commits.

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Init repo and write .gitignore**

```bash
cd /Users/eliasgansbuhler/dcav/Sephr
git init
```

Create `.gitignore`:

```gitignore
.build/
build/
.chromium-src/
*.log
.DS_Store
/tmp/
```

(`vendor/`, `sephr_overlay/`, `sephrium/`, scripts and all Swift sources ARE tracked. `.chromium-src/` is the 22 GB Chromium tree — never tracked; its Sephr-owned bridge code is mirrored in `sephr_overlay/`.)

- [ ] **Step 2: Initial commit**

```bash
git add -A
git commit -m "chore: initial commit of Sephr tree (pre performance overhaul)"
```

Expected: commit succeeds; `git status` clean except ignored dirs.

---

## Task 1: Measurement harness `scripts/perf_snapshot.sh`

**Files:**
- Create: `scripts/perf_snapshot.sh`

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
# perf_snapshot.sh — reproducible CPU/RSS snapshot of Sephr's process tree.
#
# Usage:
#   scripts/perf_snapshot.sh [--launch] [--settle N] [--url URL]
#                            [--max-renderer PCT] [--max-gpu PCT] [--stacks]
#
# Exit code: 0 if within thresholds (or none given), 1 otherwise.
set -euo pipefail

APP="build/Sephr.app"
SETTLE=45; LAUNCH=0; URL=""; MAX_RENDERER=""; MAX_GPU=""; STACKS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --launch) LAUNCH=1 ;;
    --settle) SETTLE="$2"; shift ;;
    --url) URL="$2"; shift ;;
    --max-renderer) MAX_RENDERER="$2"; shift ;;
    --max-gpu) MAX_GPU="$2"; shift ;;
    --stacks) STACKS=1 ;;
    *) echo "unknown arg $1"; exit 2 ;;
  esac; shift
done

if [ "$LAUNCH" = 1 ]; then
  open "$APP"
  sleep 10
fi
if [ -n "$URL" ]; then
  open -a "$APP" "$URL"   # routes through the default-browser external-URL path
fi
echo "settling ${SETTLE}s..."
sleep "$SETTLE"

# Three top samples, 3s apart; average per PID.
TMP=$(mktemp)
for i in 1 2 3; do
  top -l 1 -stats pid,cpu,command 2>/dev/null | grep -i "sephr" >> "$TMP" || true
  sleep 3
done

echo ""
echo "PID    TYPE              CPU%(avg)  RSS(MB)"
FAIL=0
ps -Axww -o pid,rss,command | grep -i "Sephr" | grep -v grep | grep -v perf_snapshot | \
while read -r PID RSS CMD; do
  case "$CMD" in
    *--type=gpu-process*)            TYPE="gpu-process" ;;
    *--type=renderer*)               TYPE="renderer" ;;
    *--type=utility*network*)        TYPE="util:network" ;;
    *--type=utility*storage*)        TYPE="util:storage" ;;
    *--type=utility*)                TYPE="utility" ;;
    *Sephr\ Helper*)                 TYPE="helper:other" ;;
    *)                               TYPE="browser/main" ;;
  esac
  AVG=$(awk -v p="$PID" '$1==p {s+=$2; n++} END {if(n) printf "%.1f", s/n; else print "0.0"}' "$TMP")
  printf "%-6s %-17s %-10s %s\n" "$PID" "$TYPE" "$AVG" "$((RSS/1024))"
  if [ -n "$MAX_RENDERER" ] && [ "$TYPE" = "renderer" ] && \
     awk -v a="$AVG" -v m="$MAX_RENDERER" 'BEGIN{exit !(a>m)}'; then
    echo "  ^^ FAIL: renderer ${AVG}% > ${MAX_RENDERER}%"; FAIL=1
  fi
  if [ -n "$MAX_GPU" ] && [ "$TYPE" = "gpu-process" ] && \
     awk -v a="$AVG" -v m="$MAX_GPU" 'BEGIN{exit !(a>m)}'; then
    echo "  ^^ FAIL: gpu ${AVG}% > ${MAX_GPU}%"; FAIL=1
  fi
  if [ "$STACKS" = 1 ] && awk -v a="$AVG" 'BEGIN{exit !(a>10)}'; then
    /usr/bin/sample "$PID" 3 -file "/tmp/sephr_sample_${PID}.txt" >/dev/null 2>&1 || true
    echo "  hot stacks -> /tmp/sephr_sample_${PID}.txt"
  fi
  echo "$FAIL" > "$TMP.fail"
done
rm -f "$TMP"
FAIL=$(cat "$TMP.fail" 2>/dev/null || echo 0); rm -f "$TMP.fail"
exit "$FAIL"
```

```bash
chmod +x scripts/perf_snapshot.sh
```

- [ ] **Step 2: Verify it runs and classifies processes**

Quit Sephr if running, then:

```bash
scripts/perf_snapshot.sh --launch --settle 30
```

Expected: table listing `browser/main`, `gpu-process`, ≥1 `renderer`, `util:network`, `util:storage` rows with plausible CPU/RSS numbers. With the repaint bug still present, renderer and gpu-process rows show high CPU (tens of %) — that's the bug, not a script failure.

- [ ] **Step 3: Verify threshold failure mode**

```bash
scripts/perf_snapshot.sh --settle 10 --max-renderer 5 --max-gpu 5; echo "exit=$?"
```

Expected: `exit=1` with FAIL lines (bug still present — this proves the gate works).

- [ ] **Step 4: Commit**

```bash
git add scripts/perf_snapshot.sh
git commit -m "feat: perf_snapshot.sh measurement harness"
```

---

## Task 2: Capture the baseline

**Files:**
- Create: `docs/perf/2026-06-09-baseline.md`

- [ ] **Step 1: Record baseline numbers**

With the user's normal session, run:

```bash
mkdir -p docs/perf
scripts/perf_snapshot.sh --launch --settle 60 --stacks | tee /tmp/baseline_out.txt
```

Write `docs/perf/2026-06-09-baseline.md` containing: the harness table verbatim, the framework build flavor (`Fast`), and the already-measured reference points (Sephr x.com visible: renderer 41% / gpu 31%; Helium same page: 0.4% / ~0%; Sephr occluded: ~0%).

- [ ] **Step 2: Commit**

```bash
git add docs/perf/2026-06-09-baseline.md
git commit -m "docs: performance baseline before overhaul"
```

---

## Task 3: Repaint-loop diagnosis — startup tracing on a static page

No code change; produces the evidence that picks the fix branch in Task 4. Known facts: full Blink style→layout→paint every frame while visible; browser process idle (~0.1%); throttles correctly when occluded; `setFrameSize` already dedupes, so per-frame Swift→bridge resize calls are NOT the likely cause.

**Files:**
- Create: `scripts/perf_trace_analyze.py`

- [ ] **Step 1: Capture a 15s trace on a static page**

Quit Sephr, then (CALEngineBootstrap merges `NSProcessInfo` arguments, so `open --args` switches reach Chromium):

```bash
open build/Sephr.app --args \
  --trace-startup=cc,viz,gpu,blink,toplevel \
  --trace-startup-duration=15 \
  --trace-startup-file=/tmp/sephr-trace.json
sleep 5 && open -a build/Sephr.app "https://example.com"
sleep 25   # trace runs 15s then flushes
ls -la /tmp/sephr-trace.json
```

Expected: trace file exists, multi-MB. If it's missing, fall back to recording via `--remote-debugging-port=9222` + DevTools from Helium (`chrome://inspect` → trace), but try the file route first.

- [ ] **Step 2: Write the analyzer**

```python
#!/usr/bin/env python3
"""Summarize a Chromium trace: who produces frames and why.
Usage: perf_trace_analyze.py /tmp/sephr-trace.json"""
import json, sys, collections

data = json.load(open(sys.argv[1]))
events = data["traceEvents"] if isinstance(data, dict) else data
names = collections.Counter()
durs = collections.defaultdict(float)
for e in events:
    n = e.get("name", "?")
    names[n] += 1
    durs[n] += e.get("dur", 0) / 1000.0  # ms

print("== top by count ==")
for n, c in names.most_common(25):
    print(f"{c:8d}  {durs[n]:10.1f}ms  {n}")

# The verdicts that matter:
interesting = ["BeginFrame", "Scheduler::BeginFrame", "Commit",
               "UpdateLayoutTree", "LocalFrameView::RunStyleAndLayoutLifecyclePhases",
               "Paint", "ProxyMain::BeginMainFrame", "Graphics.Pipeline",
               "NeedsBeginFrameChanged", "SetNeedsRedraw",
               "WebContentsImpl::UpdateWebContentsVisibility"]
print("\n== frame-pipeline signals ==")
for key in interesting:
    hits = [(n, c) for n, c in names.items() if key.lower() in n.lower()]
    for n, c in hits:
        print(f"{c:8d}  {n}")
```

```bash
chmod +x scripts/perf_trace_analyze.py
python3 scripts/perf_trace_analyze.py /tmp/sephr-trace.json | tee /tmp/trace_summary.txt
```

- [ ] **Step 3: Interpret — write the verdict down**

In a 15s visible-idle trace of a static page, a healthy browser shows a few dozen BeginFrames then silence. The bug shows ~900+ (60Hz) or ~1800+ (120Hz) BeginFrames with `UpdateLayoutTree`/`RunStyleAndLayoutLifecyclePhases` counts in the same order of magnitude. Identify which of these holds and record it in `/tmp/trace_summary.txt` + the task report:

- **(a) Constant invalidation from the page-side:** high `Schedule*`/`SetNeedsAnimate`/`SetNeedsCommit` originating in Blink with a JS/animation source visible in the trace. (Unlikely on example.com — if you see this on example.com, something injects work into every page; check `cal_extensions_bridge.cc` observers.)
- **(b) Browser keeps requesting frames:** continuous `SetNeedsBeginFrames(true)` / `NeedsBeginFrameChanged` from the browser compositor (`viz` category) with no corresponding damage. Embedding-side visibility/occlusion misreport — go to Task 4 branch B.
- **(c) Screen-info / scale churn:** repeated `UpdateWebContentsVisibility`, `ScreenInfoChanged`, `SynchronizeVisualProperties` events each frame — visual-property flapping between CAL host and Chromium. Go to Task 4 branch C.

- [ ] **Step 4: Commit the analyzer**

```bash
git add scripts/perf_trace_analyze.py
git commit -m "feat: trace analyzer for frame-pipeline diagnosis"
```

**CHECKPOINT: report the (a)/(b)/(c) verdict (with the trace numbers) before starting Task 4. If the trace is ambiguous or shows something not listed, STOP and escalate with /tmp/trace_summary.txt contents.**

---

## Task 4: Repaint-loop fix (branch chosen by Task 3)

**Files:**
- Modify: `.chromium-src/src/chrome/sephr/cal_bridge/cal_bridge.mm` (and/or `cal/Sources/CALWebView.mm` for branch C)
- Mirror: `sephr_overlay/cal_bridge/` (same edits)

General shape of each branch (the executor adapts to what the trace showed — the loop's exact trigger determines the precise edit; the STOP rule below bounds the risk):

**Branch B — browser compositor never idles.** The known-weird spot: `viewDidMoveToWindow` (CALWebView.mm:304) calls `SephriumWebContentsSetVisible(_webContents, 1)` unconditionally on every window move, and `SephriumWebContentsSetVisible` calls `WasShown()` with no current-state check. Repeated `WasShown` forces repeated frame requests. Fix: make visibility idempotent at the bridge:

```objc++
// cal_bridge.mm — SephriumWebContentsSetVisible
extern "C" void SephriumWebContentsSetVisible(SephriumWebContentsRef ref,
                                             int visible) {
  if (!ref) return;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return;
  // Idempotence: WasShown()/WasHidden() are not free — a redundant
  // WasShown re-requests frames from the compositor. Only transition on
  // an actual state change.
  const bool currently_visible =
      c->GetVisibility() == content::Visibility::VISIBLE;
  if (visible && !currently_visible) {
    c->WasShown();
  } else if (!visible && currently_visible) {
    c->WasHidden();
  }
}
```

Also audit (same file): every other `WasShown()` call site found at lines ~790, ~963 — apply the same guard. If the trace instead shows the *occlusion tracker* fighting the bridge (alternating VISIBLE/OCCLUDED), the fix is to stop the double-driver: let the CAL `SetVisible` path be the only visibility driver by checking `WebContents::GetVisibility()` before each transition (same guard as above — the guard breaks the ping-pong in both cases).

**Branch C — visual-property churn.** Find what flaps (size? scale?) from the trace's `SynchronizeVisualProperties` args. If scale: the chromium NSView lives inside CALWebView whose window may report changing `backingScaleFactor` during glass/overlay compositing. Fix: dedupe in `SephriumWebContentsSetSize` exactly like `setFrameSize` already does host-side:

```objc++
// cal_bridge.mm — in the holder struct, add:
//   gfx::Rect last_bounds_;
// then in SephriumWebContentsSetSize:
extern "C" void SephriumWebContentsSetSize(SephriumWebContentsRef ref,
                                          int w, int h) {
  if (!ref) return;
  auto* holder = AsHolder(ref);
  content::WebContents* c = holder->contents();
  if (!c) return;
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  gfx::Rect bounds(0, 0, w, h);
  if (holder->last_bounds_ == bounds) return;  // drop no-op resizes
  holder->last_bounds_ = bounds;
  c->Resize(bounds);
}
```

**Branch A — page-side injection.** Inspect `cal_extensions_bridge.cc` / `CreateExtensionWebContentsObserver` wiring for anything that pokes the page per-frame; remove the per-frame poke. (No pre-written code — depends entirely on what the trace shows.)

- [ ] **Step 1: Apply the branch fix in `.chromium-src/src/chrome/sephr/cal_bridge/`** (code above for B/C)

- [ ] **Step 2: ALSO add the IsAudible export now** (consumed by Task 12, added now to avoid a second framework rebuild):

```objc++
// cal_bridge.mm — near the other WebContents getters:
extern "C" int SephriumWebContentsIsAudible(SephriumWebContentsRef ref) {
  if (!ref) return 0;
  content::WebContents* c = AsHolder(ref)->contents();
  if (!c) return 0;
  return c->IsCurrentlyAudible() ? 1 : 0;
}
```

Add `_SephriumWebContentsIsAudible` to `.chromium-src/src/chrome/app/framework.exports` (MANDATORY — silently stripped otherwise). Add the declaration to the CAL public header used by `cal/Sources` (the packaged `cal_headers` copy AND the source header):

```c
// Returns 1 while the page is playing audio (used for sleep exemption).
int SephriumWebContentsIsAudible(SephriumWebContentsRef ref);
```

- [ ] **Step 3: Rebuild the Fast framework + repackage**

```bash
scripts/build_sephrium.sh          # Fast build
scripts/make_app.sh
rm -rf .build/**/ModuleCache       # stale module cache gotcha
```

Expected: build completes; `nm` check that the export survived:

```bash
nm -gU ".chromium-src/src/out/Fast/Sephr Framework.framework/Versions/Current/Sephr Framework" | grep SephriumWebContentsIsAudible
```

Expected: one line. If empty → framework.exports entry missing.

- [ ] **Step 4: Verify the gate (Workstream A gate)**

```bash
scripts/perf_snapshot.sh --launch --settle 45 --url "https://example.com" --max-renderer 5 --max-gpu 5
echo "exit=$?"
```

Expected: `exit=0`, renderer and gpu-process < 5%. If still failing, re-run Task 3's trace — the remaining producer will now dominate the summary — and iterate ONCE more. **If two fix iterations don't reach the gate, STOP and escalate with both trace summaries.**

- [ ] **Step 5: Re-sync the overlay mirror + commit**

```bash
rsync -a --delete .chromium-src/src/chrome/sephr/cal_bridge/ sephr_overlay/cal_bridge/
git add sephr_overlay/ scripts/
git commit -m "fix: kill continuous repaint loop (visibility idempotence) + IsAudible export"
```

---

## Task 5: Regression check after the repaint fix

- [ ] **Step 1: Run the QA scripts**

```bash
scripts/qa_regression.sh && scripts/qa_userflow.sh
```

Expected: both pass.

- [ ] **Step 2: Manual fragile-path spot checks** (each previously bitten by visibility changes): switch between two tabs repeatedly (no blank tabs); open a PDF; shift-click link peek; OAuth popup ("Continue with Google" on claude.ai or any Google-auth site) paints. Record pass/fail for each in the task report.

---

## Task 6: Build and ship the Release (official) framework

The one-time build is 3–5× the Fast build (hours). Start it in the background and continue with Task 7+ (Swift-side work does not need the new framework).

- [ ] **Step 1: Kick off the Release build in the background**

```bash
nohup scripts/build_sephrium.sh --release > /tmp/sephrium_release_build.log 2>&1 &
echo $! > /tmp/release_build.pid
```

Monitor: `tail -f /tmp/sephrium_release_build.log`. Known-fragile points: dsymutil (already disabled via `enable_dsyms=false`), LTO link memory pressure.

- [ ] **Step 2 (after build completes): Package the Release framework**

```bash
python3 sephrium/package_framework.py --release
scripts/make_app.sh
rm -rf .build/**/ModuleCache
```

Verify the packaged binary is the Release one (sizes differ from Fast):

```bash
nm -gU ".chromium-src/src/out/Release/Sephr Framework.framework/Versions/Current/Sephr Framework" | grep -c "_Sephrium"
stat -f "%z %N" "build/Sephr.app/Contents/Frameworks/Sephr Framework.framework/Versions/Current/Sephr Framework" \
                ".chromium-src/src/out/Release/Sephr Framework.framework/Versions/Current/Sephr Framework"
```

Expected: export count ≥ the gate count (30+); packaged size == out/Release size (NOT out/Fast).

- [ ] **Step 3: Gate**

```bash
scripts/qa_regression.sh
scripts/perf_snapshot.sh --launch --settle 45 --url "https://example.com" --max-renderer 5 --max-gpu 5
```

Expected: pass + harness CPU at-or-below the Task 4 numbers. Append the table to `docs/perf/2026-06-09-baseline.md` under "After Release build".

- [ ] **Step 4: Commit**

```bash
git add docs/perf/
git commit -m "feat: ship official Release framework (PGO/LTO)"
```

---

## Task 7: `SephrKit` library target + `TabEventBus` (TDD)

SPM cannot import executable targets into tests, so the new pure-Swift units live in a small library target that both the app and tests import.

**Files:**
- Modify: `Package.swift`
- Create: `sephrkit/Sources/SephrKit/TabEventBus.swift`
- Test: `sephrkit/Tests/SephrKitTests/TabEventBusTests.swift`

- [ ] **Step 1: Add the targets to Package.swift**

In `products:` add:

```swift
.library(name: "SephrKit", targets: ["SephrKit"]),
```

In `targets:` add:

```swift
.target(name: "SephrKit", path: "sephrkit/Sources/SephrKit"),
.testTarget(name: "SephrKitTests",
            dependencies: ["SephrKit"],
            path: "sephrkit/Tests/SephrKitTests"),
```

And add `"SephrKit"` to the `Sephr` executable target's `dependencies` array.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import SephrKit

final class TabEventBusTests: XCTestCase {
    func testPerTabSubscriberReceivesOnlyItsTabsEvents() {
        let bus = TabEventBus()
        let tabA = UUID(), tabB = UUID()
        var received: [TabEvent] = []
        let token = bus.subscribe(tabID: tabA) { received.append($0) }
        bus.post(TabEvent(tabID: tabA, kind: .title))
        bus.post(TabEvent(tabID: tabB, kind: .title))
        bus.post(TabEvent(tabID: tabA, kind: .url))
        XCTAssertEqual(received.map(\.kind), [.title, .url])
        _ = token
    }

    func testStructureSubscriberReceivesStructureEvents() {
        let bus = TabEventBus()
        var count = 0
        let token = bus.subscribeStructure { count += 1 }
        bus.postStructure()
        bus.postStructure()
        XCTAssertEqual(count, 2)
        _ = token
    }

    func testTokenDeallocUnsubscribes() {
        let bus = TabEventBus()
        let tab = UUID()
        var count = 0
        var token: TabEventToken? = bus.subscribe(tabID: tab) { _ in count += 1 }
        bus.post(TabEvent(tabID: tab, kind: .favicon))
        token = nil
        bus.post(TabEvent(tabID: tab, kind: .favicon))
        XCTAssertEqual(count, 1)
        _ = token
    }
}
```

- [ ] **Step 3: Run, verify failure**

```bash
swift test --filter TabEventBusTests 2>&1 | tail -5
```

Expected: compile failure — `TabEventBus` not defined.

- [ ] **Step 4: Implement**

```swift
import Foundation

/// Per-tab change kinds. `structure` (add/remove/reorder) has its own
/// channel — see `subscribeStructure`.
public struct TabEvent {
    public enum Kind { case title, favicon, active, url, loading }
    public let tabID: UUID
    public let kind: Kind
    public init(tabID: UUID, kind: Kind) {
        self.tabID = tabID
        self.kind = kind
    }
}

/// Keep the token alive for the lifetime of the subscription;
/// dropping it unsubscribes.
public final class TabEventToken {
    fileprivate let id = UUID()
    fileprivate weak var bus: TabEventBus?
    fileprivate let tabID: UUID?   // nil = structure subscription
    fileprivate init(bus: TabEventBus, tabID: UUID?) {
        self.bus = bus
        self.tabID = tabID
    }
    deinit { bus?.unsubscribe(token: self) }
}

/// Main-thread-only fine-grained tab event bus. Replaces the global
/// `.sephrTabModelChanged` broadcast: cells subscribe to their own tab,
/// the sidebar subscribes to structure only.
public final class TabEventBus {
    public static let shared = TabEventBus()
    private var perTab: [UUID: [(UUID, (TabEvent) -> Void)]] = [:]
    private var structure: [(UUID, () -> Void)] = []
    public init() {}

    public func subscribe(tabID: UUID,
                          handler: @escaping (TabEvent) -> Void) -> TabEventToken {
        let token = TabEventToken(bus: self, tabID: tabID)
        perTab[tabID, default: []].append((token.id, handler))
        return token
    }

    public func subscribeStructure(handler: @escaping () -> Void) -> TabEventToken {
        let token = TabEventToken(bus: self, tabID: nil)
        structure.append((token.id, handler))
        return token
    }

    public func post(_ event: TabEvent) {
        perTab[event.tabID]?.forEach { $0.1(event) }
    }

    public func postStructure() {
        structure.forEach { $0.1() }
    }

    fileprivate func unsubscribe(token: TabEventToken) {
        if let tabID = token.tabID {
            perTab[tabID]?.removeAll { $0.0 == token.id }
            if perTab[tabID]?.isEmpty == true { perTab[tabID] = nil }
        } else {
            structure.removeAll { $0.0 == token.id }
        }
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

```bash
swift test --filter TabEventBusTests 2>&1 | tail -5
```

Expected: `Executed 3 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift sephrkit/
git commit -m "feat: SephrKit target with fine-grained TabEventBus (tested)"
```

---

## Task 8: Emit typed events from the model and tab callbacks

Migration safety: the legacy `.sephrTabModelChanged` notification KEEPS firing in parallel for one release; observers are migrated in Task 9; the legacy posts are removed in Task 10 only after qa passes.

**Files:**
- Modify: `sephr/Sources/Tabs/SephrTabModel.swift` (emit() at ~line 470)
- Modify: `sephr/Sources/Tabs/SephrTab.swift` (callbacks at ~lines 103–130; favicon ~114)

- [ ] **Step 1: Add typed emission alongside the legacy notification**

`SephrTabModel.swift` — replace `emit()` (line 470) with:

```swift
import SephrKit  // top of file

/// Structure-level change (add/remove/reorder/move). Tab-scoped changes
/// (title/url/favicon/active/loading) post TabEvent directly and must
/// NOT call this.
private func emit() {
    TabEventBus.shared.postStructure()
    // Legacy broadcast — removed in the cleanup task once all
    // observers are migrated to TabEventBus.
    NotificationCenter.default.post(name: .sephrTabModelChanged,
                                     object: nil)
}
```

Where the model mutates a tab's `isActive` (the activate/select method — find it via `grep -n "isActive = true" sephr/Sources/Tabs/SephrTabModel.swift`), additionally post:

```swift
TabEventBus.shared.post(TabEvent(tabID: tab.id, kind: .active))
```

(for both the newly-active and previously-active tab).

- [ ] **Step 2: Tab callbacks post per-tab events**

`SephrTab.swift` `getOrCreateWebView()` — in `onNavigation` (lines 103–113), replace the `NotificationCenter` post with:

```swift
wv.onNavigation = { [weak self] (url: String, title: String) in
    guard let self else { return }
    self.url = url
    self.title = title.isEmpty ? self.title : title
    SephrTabModel.shared.persist()
    TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .url))
    TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .title))
    // Legacy (removed in cleanup task):
    NotificationCenter.default.post(name: .sephrTabModelChanged, object: nil)
}
```

`onFavicon` (lines 114–124) — same pattern with `kind: .favicon`. `onLoading` (lines 125–130) — add `TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .loading))` (keep the existing `.sephrTabLoadingChanged` post for now). Add `import SephrKit` to the file.

- [ ] **Step 3: Build + run**

```bash
swift build 2>&1 | tail -3
```

Expected: builds clean. Launch and click around — behavior unchanged (both event systems firing).

- [ ] **Step 4: Commit**

```bash
git add sephr/Sources/Tabs/
git commit -m "feat: post fine-grained TabEvents alongside legacy broadcast"
```

---

## Task 9: Migrate observers — tab cells and URL field

**Files:**
- Modify: `sephr/Sources/Sidebar/SephrTabCell.swift` (observer at lines 46–48, handler 173–187)
- Modify: `sephr/Sources/Sidebar/SephrSidebarURLField.swift` (observer at 115–117, syncURL at 126–151)
- Modify: `sephr/Sources/Sidebar/SephrSidebarView.swift` (global observer → structure subscription)

- [ ] **Step 1: SephrTabCell subscribes to its own tab only**

Replace the `NotificationCenter.addObserver(... .sephrTabModelChanged ...)` (lines 46–48) with:

```swift
import SephrKit  // top of file

// in init, replacing the addObserver call:
eventToken = TabEventBus.shared.subscribe(tabID: tab.id) { [weak self] event in
    self?.onTabEvent(event)
}
```

Add the ivar `private var eventToken: TabEventToken?` and split the old monolithic handler (lines 173–187) by kind:

```swift
private func onTabEvent(_ event: TabEvent) {
    switch event.kind {
    case .active:
        refreshAppearance()
    case .favicon:
        refreshFavicon()
    case .title, .url:
        let newTitle = tab.title.isEmpty ? tab.url : tab.title
        if titleLabel.stringValue != newTitle {
            titleLabel.stringValue = newTitle
        }
    case .loading:
        break  // loading spinner already driven by .sephrTabLoadingChanged
    }
}
```

Remove the corresponding `NotificationCenter.default.removeObserver` for the old name if present. Do NOT touch any glass-pill code beyond the call-sites above.

- [ ] **Step 2: URL field syncs only on active/url events**

`SephrSidebarURLField.swift` — replace the observer (lines 115–117) with:

```swift
import SephrKit  // top of file

// in init, replacing the addObserver call — re-subscribed on active-tab
// change because per-tab subscription follows the active tab:
structureToken = TabEventBus.shared.subscribeStructure { [weak self] in
    self?.resubscribeToActiveTab()
    self?.syncURL()
}
resubscribeToActiveTab()
```

Add:

```swift
private var structureToken: TabEventToken?
private var activeTabToken: TabEventToken?
private var lastSubscribedTabID: UUID?

private func resubscribeToActiveTab() {
    let active = SephrTabModel.shared.activeTab()
    guard active?.id != lastSubscribedTabID else { return }
    lastSubscribedTabID = active?.id
    activeTabToken = nil
    if let active {
        activeTabToken = TabEventBus.shared.subscribe(tabID: active.id) {
            [weak self] event in
            if event.kind == .url || event.kind == .active {
                self?.syncURL()
            }
        }
    }
    syncURL()
}
```

`syncURL()` itself is unchanged — the live `currentURL` read stays (it's a cheap in-process `GetLastCommittedURL`, and the redirect-correctness comment at lines 128–134 explains why the live read is required). The win is call FREQUENCY: from every model change (5–10/sec during loads) to only url/active changes of the active tab.

ALSO: the model needs to post `.active` events when activation changes for this to work — verify Task 8 Step 1 covered the activate path; if `syncURL` stops updating on tab click, that's the symptom.

- [ ] **Step 3: Sidebar — structure only**

In `SephrSidebarView.swift`, find the `.sephrTabModelChanged` observer (`grep -n "sephrTabModelChanged" sephr/Sources/Sidebar/SephrSidebarView.swift`). Replace it with `TabEventBus.shared.subscribeStructure { ... same handler ... }` storing the token in an ivar. The existing structure-key guard inside the handler stays as a second line of defense.

- [ ] **Step 4: Build, launch, verify behavior**

```bash
swift build 2>&1 | tail -3
scripts/qa_userflow.sh
```

Manual: click between tabs (URL bar updates, active pill moves), load a SPA (x.com) and confirm title/favicon update in the sidebar, type in the URL bar while a page loads (text NOT stomped — the mid-edit guard at line 143 must still hold).

- [ ] **Step 5: Commit**

```bash
git add sephr/Sources/Sidebar/
git commit -m "feat: migrate sidebar + URL field to per-tab TabEventBus"
```

---

## Task 10: Remove the legacy broadcast + measure the interaction win

- [ ] **Step 1: Find any remaining `.sephrTabModelChanged` consumers**

```bash
grep -rn "sephrTabModelChanged" sephr/Sources/ | grep -v "post(name"
```

Migrate each remaining observer the same way as Task 9 (per-tab token if it cares about one tab, structure token otherwise). Then delete the legacy `NotificationCenter.default.post(name: .sephrTabModelChanged, ...)` lines from `SephrTabModel.emit()` and `SephrTab.getOrCreateWebView()` callbacks, and finally the `Notification.Name` declaration itself (`grep -rn "sephrTabModelChanged" sephr/` must return zero hits).

- [ ] **Step 2: Full verification**

```bash
swift build 2>&1 | tail -3
scripts/qa_userflow.sh && scripts/qa_regression.sh
```

- [ ] **Step 3: Interaction gate (Workstream C gate)**

While rapidly switching among 5 tabs with x.com loading: `browser/main` row of `scripts/perf_snapshot.sh --settle 15` stays in single digits. Record the number in `docs/perf/2026-06-09-baseline.md` under "After event migration".

- [ ] **Step 4: Commit**

```bash
git add sephr/ docs/perf/
git commit -m "feat: remove global tab-model broadcast; per-tab events only"
```

---

## Task 11: Favicon reads off the critical path + persistence change-counter

**Files:**
- Modify: `sephr/Sources/Persistence/SephrFaviconCache.swift`
- Modify: `sephr/Sources/Tabs/SephrTab.swift:61,90` (init/decode favicon reads)
- Modify: `sephr/Sources/Tabs/SephrTabModel.swift` (persist/writeNow, lines 479–507)

- [ ] **Step 1: Add async favicon API; make session-restore use it**

`SephrFaviconCache.swift` — keep `get(for:)` (other callers rely on sync), add:

```swift
/// Memory-only synchronous lookup — never touches disk. Safe on any
/// thread at any frequency.
func cached(for urlString: String) -> NSImage? {
    guard let host = Self.host(for: urlString) else { return nil }
    return queue.sync { memoryCache[host] }
}

/// Async disk-backed lookup. Completion fires on the main queue.
func load(for urlString: String,
          completion: @escaping @Sendable (NSImage?) -> Void) {
    guard let host = Self.host(for: urlString) else {
        completion(nil); return
    }
    queue.async { [self] in
        var result: NSImage? = memoryCache[host]
        if result == nil, !negativeCache.contains(host) {
            let file = directory.appendingPathComponent("\(host).png")
            if let data = try? Data(contentsOf: file),
               let image = NSImage(data: data) {
                memoryCache[host] = image
                result = image
            } else {
                negativeCache.insert(host)
            }
        }
        DispatchQueue.main.async { completion(result) }
    }
}
```

`SephrTab.swift` lines 61 and 90 — replace `self.favicon = SephrFaviconCache.shared.get(for: url)` with:

```swift
self.favicon = SephrFaviconCache.shared.cached(for: url)
// Disk lookup off the init path; the cell repaints via the favicon event.
SephrFaviconCache.shared.load(for: url) { [weak self] image in
    guard let self, let image, self.favicon == nil else { return }
    self.favicon = image
    TabEventBus.shared.post(TabEvent(tabID: self.id, kind: .favicon))
}
```

(Line 90's decode-path version is identical but uses `self.url`. NOTE: `init(from:)` may run off-main; `load`'s completion hops to main, so posting the event there is safe.)

- [ ] **Step 2: Persistence change-counter**

`SephrTabModel.swift` — add ivars and guard `writeNow()`:

```swift
/// Bumped by persist(); writeNow() skips the encode when nothing new
/// was marked dirty since the last successful write.
private var changeCounter: UInt64 = 0
private var lastWrittenCounter: UInt64 = 0
```

In `persist()` (line 479), first line: `changeCounter &+= 1`. In `writeNow()` (line 503):

```swift
private func writeNow() {
    persistPending = nil
    guard changeCounter != lastWrittenCounter else { return }
    lastWrittenCounter = changeCounter
    SephrSessionStore.shared.saveSession(tabs: allTabs,
                                          folders: allFolders)
}
```

- [ ] **Step 3: Build + verify**

```bash
swift build 2>&1 | tail -3
```

Launch with the 40-tab session: sidebar favicons appear (some a beat later — that's the async load), navigation still persists across relaunch (navigate, quit, relaunch, URL kept).

- [ ] **Step 4: Commit**

```bash
git add sephr/Sources/
git commit -m "perf: async favicon disk reads + persistence change-counter"
```

---

## Task 12: Re-enable the spare renderer

**Files:**
- Modify: `cal/Sources/CALEngineBootstrap.mm:203`

- [ ] **Step 1: Remove `SpareRendererForSitePerProcess` from the disable list**

Line 203 currently:

```objc
@"--disable-features=DefaultBrowserPromptRefresh,SavePageAsMHTML,SpareRendererForSitePerProcess,FedCm,FedCmAutoSelectedFlag,FedCmIdAssertionEndpoint",
```

becomes:

```objc
@"--disable-features=DefaultBrowserPromptRefresh,SavePageAsMHTML,FedCm,FedCmAutoSelectedFlag,FedCmIdAssertionEndpoint",
```

(No record of WHY it was disabled exists in the file's comments — the suspected reason is popup-adoption collateral. Step 2 tests exactly that.)

- [ ] **Step 2: Build and test the fragile paths**

```bash
swift build 2>&1 | tail -3
scripts/qa_userflow.sh
```

Manual, specifically the popup-adoption path (the suspected reason it was disabled): trigger an OAuth popup ("Continue with Google") — it must adopt into a peek with the opener relationship intact (sign-in completes). Also: open 3 new tabs to different sites quickly — they should paint noticeably faster than before (spare renderer pre-warmed). **If popup adoption breaks, revert this change, document the conflict in the plan file, and skip — do not hack around it inside this task.**

- [ ] **Step 3: Commit**

```bash
git add cal/Sources/CALEngineBootstrap.mm
git commit -m "perf: re-enable SpareRendererForSitePerProcess"
```

---

## Task 13: Tab sleeping — CAL sleep/wake

**Files:**
- Modify: `cal/Sources/CALWebView.mm` (factor teardown out of dealloc, lines 307–332; add sleep/wake)
- Modify: `cal/Sources/CALWebView.h` (or the class's public header in `cal/Sources/` — declare `sleep`/`wake`/`isAsleep`/`isAudible`)

- [ ] **Step 1: Factor `_teardownWebContents` out of `dealloc`**

The body of `dealloc` (lines 307–332: NULL all callbacks → remove subviews → destroy) moves verbatim into:

```objc
// Tear down the live WebContents, leaving the view reusable. Used by
// dealloc AND sleep — the CRITICAL callback-NULLing-before-destroy
// ordering (see dealloc comment) applies to both.
- (void)_teardownWebContents {
    if (!_webContents) return;
    SephriumWebContentsSetNavCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetFaviconCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetLoadingCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetNewTabRequestCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetTargetURLCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetPopupRequestCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetCloseRequestCallback(_webContents, NULL, NULL);
    for (NSView* sub in [self.subviews copy]) {
        [sub removeFromSuperview];
    }
    _chromiumViewAttached = NO;
    SephriumWebContentsRef wc = _webContents;
    _webContents = NULL;
    SephriumWebContentsDestroy(wc);
}

- (void)dealloc {
    [self _teardownWebContents];
}
```

- [ ] **Step 2: Add sleep / wake / isAudible**

```objc
- (BOOL)isAsleep { return _webContents == NULL && _profileID != nil; }

- (BOOL)isAudible {
    return _webContents && SephriumWebContentsIsAudible(_webContents);
}

// Snapshot the committed URL, then destroy the WebContents. The view
// object (and its place in the tab model / sidebar) survives; wake
// recreates the contents at the snapshotted URL.
- (void)sleep {
    if (!_webContents) return;
    char* u = SephriumWebContentsCopyURL(_webContents);
    NSString* live = CAL_StringSafe(u);
    if (u) SephriumStringFree(u);
    if (live.length) _currentURL = [live copy];
    [self _teardownWebContents];
}

// Recreate the WebContents at the last committed URL. Mirrors
// +webViewWithURL:profile: — created hidden/detached; if the view is
// currently in a window, re-attach immediately so it paints.
- (void)wake {
    if (_webContents) return;
    CALProfile* profile = [CALProfile profileWithID:_profileID];
    SephriumProfileRef profileRef = (SephriumProfileRef)profile.bridgeHandle;
    if (!profileRef) {
        NSLog(@"[sephr/CALWebView] wake: NULL profile ref for %@", _profileID);
        return;
    }
    _webContents = SephriumWebContentsCreate(
        profileRef, [(_currentURL ?: @"about:blank") UTF8String]);
    [self _wireContentsCallbacks];
    if (self.window) {
        // Re-run the attach path normally driven by viewDidMoveToWindow.
        [self viewDidMoveToWindow];
    }
}
```

Declare all four in the public header.

- [ ] **Step 3: Build + smoke-test by hand**

```bash
swift build 2>&1 | tail -3
```

Then in the app (temporarily, via the debugger or a hidden menu action calling `tab.webView?.sleep()` / `wake()`): sleeping the active tab blanks it; waking restores the page at its URL; switching away and back after wake paints (no blank-tab regression — this is the historically fragile path; the wake path MUST reuse `viewDidMoveToWindow`, never a second attach implementation).

- [ ] **Step 4: Commit**

```bash
git add cal/Sources/
git commit -m "feat: CALWebView sleep/wake (WebContents destroy/recreate)"
```

---

## Task 14: Tab sleeping — policy, preference, and Settings toggle

**Files:**
- Modify: `sephr/Sources/Tabs/SephrTabModel.swift` (extend the auto-archive timer, lines 441–458)
- Modify: the preferences store (`grep -rn "archiveAfterDays" sephr/Sources/` to find `SephrPreferences`)
- Modify: `sephr/Sources/Settings/SephrSettingsPanes.swift` (add the toggle near the archive setting)
- Modify: `sephr/Sources/Tabs/SephrTab.swift` (lastAccessedAt is already tracked; sleeping touches webView only)

- [ ] **Step 1: Preference**

In `SephrPreferences` (same pattern as `archiveAfterDays`):

```swift
/// Minutes a hidden tab keeps its live renderer before sleeping.
/// 0 disables tab sleeping entirely.
static var sleepAfterMinutes: Int {
    get { UserDefaults.standard.object(forKey: "sephr.sleepAfterMinutes")
            as? Int ?? 30 }
    set { UserDefaults.standard.set(newValue,
            forKey: "sephr.sleepAfterMinutes") }
}
```

- [ ] **Step 2: Sleep sweep on the existing 60s timer**

`SephrTabModel.swift` — in `runAutoArchive()` (line 448), after the archive loop add:

```swift
runSleepSweep()
```

and add:

```swift
/// Sleep renderers of long-hidden tabs. Exemptions: active tab,
/// pinned tabs, tabs playing audio, members of an active split group.
/// Failure mode is benign: a slept tab re-navigates to its stored URL
/// on activation (wake), never a blank tab.
private func runSleepSweep() {
    let minutes = SephrPreferences.sleepAfterMinutes
    guard minutes > 0 else { return }
    let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
    for tab in allTabs {
        guard let wv = tab.webView, !wv.isAsleep else { continue }
        guard !tab.isActive, !tab.isPinned else { continue }
        guard !wv.isAudible else { continue }
        guard !SephrSplitManager.shared.isInActiveSplit(tab.id) else { continue }
        guard tab.lastAccessedAt < cutoff else { continue }
        wv.sleep()
    }
}
```

(If `SephrSplitManager` has no `isInActiveSplit(_:)`, add it — a membership check over its current split groups; `grep -n "func " sephr/Sources/SplitView/SephrSplitManager.swift` to match its API style.)

- [ ] **Step 3: Wake on activation**

In the model's tab-activation method (same one that posts `.active` in Task 8), before making the tab visible:

```swift
if let wv = tab.webView, wv.isAsleep { wv.wake() }
```

(`getOrCreateWebView()` already handles tabs whose webView was never created; wake handles the slept case.)

- [ ] **Step 4: Settings toggle**

In `SephrSettingsPanes.swift`, next to the existing archive-days control (match its exact DCDesign/DCComponents style — `grep -n "archiveAfterDays" sephr/Sources/Settings/SephrSettingsPanes.swift`): a labeled stepper/picker for "Put inactive tabs to sleep after" with choices Off(0)/15/30/60 minutes bound to `SephrPreferences.sleepAfterMinutes`. Do not restyle anything else.

- [ ] **Step 5: Verify (Workstream D gate)**

```bash
swift build 2>&1 | tail -3
scripts/qa_userflow.sh
```

Manual with `sleepAfterMinutes` temporarily set to 1: open 6 tabs, use 2, wait ~2 min → Activity Monitor / harness shows renderer count dropped; clicking a slept tab restores its page (URL bar correct, content paints, no blank). YouTube playing audio in a background tab does NOT sleep. Then the soak: restore the 40-tab session, browse normally 1 hour, run `scripts/perf_snapshot.sh --settle 30` → live renderer count ≤ recently-used + exemptions; total RSS ≥30% below the Task 2 baseline table. Append to `docs/perf/2026-06-09-baseline.md`.

- [ ] **Step 6: Commit**

```bash
git add sephr/Sources/ docs/perf/
git commit -m "feat: sleeping tabs (30min default, audio/pin/split/active exempt)"
```

---

## Task 15: Final regression + docs

- [ ] **Step 1: Full pass**

```bash
scripts/qa_regression.sh && scripts/qa_userflow.sh
scripts/perf_snapshot.sh --launch --settle 45 --url "https://example.com" --max-renderer 5 --max-gpu 5
```

All green. Fragile-path manual sweep one more time: PDF, link peek, OAuth popup, split view, default-browser cold launch (`open "https://example.com"` with Sephr as default while quit).

- [ ] **Step 2: Final perf report**

Update `docs/perf/2026-06-09-baseline.md` with the complete before/after table for every gate. Commit:

```bash
git add docs/
git commit -m "docs: final performance overhaul report"
```

---

## Self-review notes (already applied)

- Spec coverage: Unit 0→Task 1-2; Unit A→Tasks 3-5; Unit B→Task 6; Unit C (C1→7-8, C2→9, C3/C4→11, legacy removal→10); Unit D (D1→12, D2→13-14); error-handling table → STOP/escalate checkpoints in Tasks 3, 4, 12; testing section→Tasks 5, 10, 15.
- The spec's "C2 cache currentURL" was adjusted with evidence: `CopyURL` is a cheap in-process call and the live read is REQUIRED for redirect correctness (documented in the code at SephrSidebarURLField.swift:128-134). The implemented fix reduces call frequency via event filtering — same goal (no hot-path overhead), corrected mechanism.
- Task 4 contains branch code rather than one fixed diff because Workstream A is diagnostic by design; the trace verdict in Task 3 selects the branch, and an explicit escalation bound (two iterations) prevents open-ended fishing.
