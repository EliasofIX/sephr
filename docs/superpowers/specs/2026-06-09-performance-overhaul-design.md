# Sephr Performance Overhaul — Design

**Date:** 2026-06-09
**Status:** Approved
**Scope decision:** Liquid Glass / `.glassEffect` is explicitly out of scope (user decision; evidence agrees — the main app process idles at ~0.1% CPU, so glass is not the burn).

## Problem

Sephr feels heavy "pretty much always": fans, memory, and energy drain even under light use.

### Measured evidence (2026-06-09, M-series Mac, macOS 26)

| Scenario | Renderer CPU | GPU process CPU |
|---|---|---|
| x.com/home visible in Helium (same machine) | 0.4% | ~0% |
| x.com/home visible in Sephr | 41% | 31% |
| Same tab in Sephr, window occluded | ~0% | ~0% |

- `/usr/bin/sample` of the busy renderer shows continuous full Blink style-recalc → layout → paint cycles (`ComputedStyleBase` equality checks, `GridTrackList::operator==`, `PaintArtifactCompositor::Layerizer`) while the window sits untouched.
- The main Sephr process (browser + Swift UI) stays at ~0.1% during the burn — the loop is not driven by Swift-side animation.
- Occlusion correctly throttles to zero, so visibility plumbing works; the compositor simply never reaches "no damage → idle" while visible.
- The packaged framework is the **Fast dev build** (`out/Fast`, `is_official_build=false`, no PGO/LTO). No Release binary currently exists.
- Boot switches disable `SpareRendererForSitePerProcess`, so every cross-site navigation/new tab pays full renderer-process startup.
- Code inspection (Swift layer): synchronous `SephriumWebContentsCopyURL` bridge calls fired from the URL field on every `.sephrTabModelChanged` notification (5–10×/sec during SPA loads); that notification is global and fans out to every tab cell (~150 cells refresh on any change); favicon cache does synchronous main-thread disk reads during session restore; whole-session JSON encodes on a 250ms debounce regardless of whether anything changed.
- No tab sleeping: long sessions accumulate live renderers for all 40+ restored tabs.

## Goal & success criteria

Energy/CPU parity with other Chromium browsers on the same machine (Helium is the benchmark):

1. **Idle, page visible:** renderer < 5% CPU and GPU process < 5% on a static page (stretch: match Helium's ~0%).
2. **Long session:** with 40+ tabs over 1 hour, live renderer count tracks recently-used tabs + exemptions, not total tabs; total app memory ≥ 30% below the like-for-like baseline measured by the harness.
3. **Interaction:** no synchronous bridge calls on the main thread in tab-switch / page-load hot paths; main app process CPU stays flat during rapid tab switching.
4. Every workstream is gated by a before/after measurement from the harness. No fix is "done" without numbers.

## Architecture overview

Five units, built in this order. The harness comes first; Workstreams A/B are engine-side and independent of C/D (Swift-side), so a stall in one does not block the others.

```
Harness ─→ A (repaint loop) ─→ B (Release build) ─→ C (Swift events) ─→ D (renderer lifecycle)
   └────────── every workstream gates on harness numbers ──────────┘
```

## Unit 0 — Measurement harness

**What:** `scripts/perf_snapshot.sh`. Codifies the manual diagnosis so every fix has a reproducible before/after.

**Behavior:**
- Launches `build/Sephr.app` (or attaches if running), waits a settle period (default 45s).
- Samples per-process CPU/RSS 3× via `top -l`/`ps -Axww`, classifying helpers by `--type=` (gpu-process, renderer, utility sub-types).
- Prints a comparison table; optionally captures hot stacks via `/usr/bin/sample` (full path — `sample` is shadowed by a Python script in this environment).
- Exit code reflects pass/fail against thresholds passed as flags (e.g. `--max-renderer 5 --max-gpu 5`) so gates are scriptable.

**Depends on:** nothing. **Consumers:** all workstreams.

## Unit A — Kill the continuous repaint loop

**What:** Diagnose and fix the visible-state frame production loop in the CAL embedding.

**Diagnosis plan (in order):**
1. Relaunch with `--remote-debugging-port=9222`; record a DevTools performance trace from another Chromium browser on a **static page** (`example.com`) to remove page noise. The trace shows what invalidates each frame.
2. Temporary file-based trace counters (established dev-loop pattern) in `cal_bridge.mm` for: `SetBounds` call rate, `SetVisible` churn, screen-info/device-scale updates, BeginFrame requests.

**Hypotheses, in priority order:**
- Per-frame bounds/frame updates from the Swift host view (NSView frame feedback loop).
- Hosted WebContents NSView/layer marked dirty every vsync by the embedding.
- Device-scale-factor flapping between CAL host and Chromium screen info (consistent with full style recalcs — env/viewport invalidation).
- Compositor pinned in "needs BeginFrames" state.

**Fix location:** live bridge source `.chromium-src/src/chrome/sephr/cal_bridge/`, re-synced to `sephr_overlay/`; prefer new code under `chrome/sephr/` over upstream patches (established project principle).

**Gate:** static page, visible, idle → renderer < 5% AND GPU process < 5% via harness.

## Unit B — Ship the Release (official) Chromium build

**What:** Build `out/Release` with the existing `sephrium/flags.gn` (`is_official_build=true`, PGO/LTO), package with `make_app.sh`, keep `out/Fast` for the dev loop.

**Notes:** one-time 3–5× build-time cost; expected recurring 15–30% CPU/energy reduction on web workloads. Watch for the known packaging gotchas: framework header lag (cp + clear module cache), signing posture in `make_app.sh`, `framework.exports` completeness.

**Gate:** app launches; `scripts/qa_regression.sh` passes; harness shows reduced CPU on a scripted browse versus the Fast build with the same workstream-A fix in place.

## Unit C — Swift event architecture (zero visual changes)

**C1. Fine-grained tab events.** Replace the single global `.sephrTabModelChanged` broadcast with typed events carrying `(tabID, change kind)`: `title`, `favicon`, `active`, `url`, plus a coalesced `structure` event for add/remove/reorder. Tab cells subscribe only to their own tab's events; the sidebar rebuilds only on `structure`. Interface: a small `TabEventBus` (Combine or NotificationCenter with userInfo — implementer's choice, but the public API is subscribe-by-tabID).

**C2. No synchronous bridge calls in hot paths.** `CALWebView` maintains a cached URL/title updated by the existing `onNavigation`/title callbacks; `currentURL`/`currentTitle` getters return the cache. The URL field (`SephrSidebarURLField.syncURL`) consumes events from C1 instead of re-querying the bridge. Correctness note: the sidebar-stability work established the URL bar must reflect the live URL — the cache is written by the same bridge callbacks that signal URL changes, so freshness is preserved; verify the popup-adoption and redirect paths update the cache too.

**C3. Favicon cache off the main thread.** Async disk reads with callback delivery; keep the synchronous in-memory fast path. Session restore with 40 tabs must perform zero main-thread disk reads.

**C4. Persistence dirty-flag.** Track a dirty bit per persist domain; skip whole-session JSON encodes when nothing changed. Keep the 250ms debounce.

**Explicitly unchanged:** all `.glassEffect` / NSGlassEffectView usage, all visuals, the DCTabBar, hover/peek behavior.

**Gate:** harness interaction scenario (rapid tab switching while a SPA loads) shows main app process CPU flat; `scripts/qa_userflow.sh` passes; URL bar reflects navigation/redirect/popup-adoption correctly.

## Unit D — Renderer lifecycle

**D1. Re-enable `SpareRendererForSitePerProcess`.** First determine why it was disabled (suspected collateral of the OAuth-popup-adoption work). If it conflicts with peek/popup adoption, scope the fix narrowly instead of disabling the feature globally. Win: new tabs/cross-site navigations stop paying full renderer startup.

**D2. Tab sleeping.** Tabs hidden longer than N minutes (default 30, user-configurable in Settings) have their WebContents destroyed; the `SephrTab` retains identity, last URL, title, and favicon, and restores lazily on activation (Arc/Edge sleeping-tabs UX). Exemptions: pinned/favorite tabs, tabs playing audio, tabs in an active split group. Requires a small CAL addition: destroy/recreate the WebContents under a stable `SephrTab`, restoring last committed URL (scroll restoration best-effort).

**Risk note:** D2 touches WebContents lifecycle, which has previously produced blank-tab/visibility bugs (hidden-create + `SetVisible` plumbing). It is deliberately last and independently shippable; it must reuse the existing hidden-create path rather than introducing a second lifecycle.

**Gate:** 40-tab session, 1 hour of mixed use → live renderer count ≤ recently-used + exemptions; total app memory ≥ 30% below the harness baseline captured at the start of Workstream D under the same session; no blank-tab regressions in `qa_userflow.sh`.

## Error handling & failure modes

- **Workstream A diagnosis dead-ends:** the trace + counters bound the search; if neither shows the invalidation source, fall back to bisecting with a minimal CAL host (the `smoke` target) to isolate Swift-host vs bridge vs Chromium-config cause.
- **Release build failures (B):** known-fragile points are dsym/toolchain (already handled in flags.gn comments) and export stripping; gate catches silent breakage via qa_regression.
- **Event migration (C):** keep the old global notification firing in parallel during migration (one release), assert-log any listener still consuming it, then remove.
- **Tab sleeping (D2):** feature-flagged in Settings with an off switch; restore failures must degrade to a normal navigation to the stored URL, never a blank tab.

## Testing

- Harness thresholds enforced per gate (above).
- `scripts/qa_regression.sh` + `scripts/qa_userflow.sh` after every workstream.
- Manual spot-checks tied to known-fragile paths: popup adoption (OAuth flow), PDF rendering, split view, link peek, default-browser cold launch.

## Out of scope

Liquid Glass usage, UI/visual redesign, web-facing feature changes, Chromium version bumps, devtools surfaces.
