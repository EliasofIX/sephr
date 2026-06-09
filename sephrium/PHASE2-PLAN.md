# CAL Phase 2 — Plan

Phase 1 (complete): C ABI link works. `sephr-smoke` launches an `NSWindow`
and links `Sephrium.framework` via the new `_Sephrium*` symbols, but the
window stays empty because `SephriumInitialize` is a no-op stub — no
`g_browser_process`, no `ProfileManager`, so `SephriumWebContentsCreate`
returns `null`.

Phase 2 closes that gap: actually boot Chromium inside the Sephr process
and render pages into `CALWebView`.

## The core problem

Chromium expects to **own** the main run loop. `content::ContentMain` /
`ChromeMain` block forever — they install their own `MessagePump`, run
init on the UI thread, and only return at process exit.

Sephr (Swift/AppKit) also expects to own the main run loop via
`NSApp.run()`. Two run loops can't both own the same thread.

Phase 2 has to reconcile this. There are two real options.

---

## Option A — Chromium owns the run loop (recommended)

The Sephr Swift `main()` calls `SephriumInitialize(argc, argv)` which calls
`ChromeMain` (via the framework's exported `_ChromeMain`). ChromeMain takes
over: it sets up `NSApplication` itself (Chromium has its own
`MessagePumpNSApplication` for macOS), runs init, then enters the run
loop. **It never returns.**

The Sephr UI is built from inside Chromium's run loop, after
`g_browser_process` and `ProfileManager` are ready. Hooking points:

- **`ChromeBrowserMainExtraParts`** — Chromium's official extension hook.
  Subclass it, override `PreMainMessageLoopRun()` and `PreBrowserStart()`,
  register from inside chrome's `ChromeBrowserMainParts::AddParts()`.
  This is where the Sephr window/AppDelegate gets created. (See
  `chrome/browser/chrome_browser_main_extra_parts*.cc` for the pattern.)
- **`SephriumInitialize`** becomes a thin wrapper around `ChromeMain` that
  registers our `ChromeBrowserMainExtraParts` subclass before invoking it.

### Pros
- Standard Chromium embedding model — Arc, Brave, Edge all do this.
- `g_browser_process`, `ProfileManager`, `BrowserContext`, threading,
  network, GPU process, all "just work" with no custom plumbing.
- `CALProfileRegistry::GetOrCreate` (already written in
  `cal_profile_registry.cc`) starts returning real `Profile*`s.

### Cons
- Sephr's Swift `main()` becomes a one-liner that hands off to
  ChromeMain. The `SephrApp` entry, `AppDelegate`, etc. need to move into
  a callback fired by the new `ChromeBrowserMainExtraParts`.
- Some AppKit lifecycle assumptions in Sephr (e.g.
  `NSApp.setActivationPolicy(.regular)` before app.run()) need to land
  inside the ExtraParts hook instead.

### Concrete work

1. **New patch `sephrium/patches/sephr/012-cal-browser-main-extra-parts.patch`**
   - `chrome/browser/sephr_browser_main_extra_parts.{h,cc}` — subclass
     of `ChromeBrowserMainExtraParts` that owns the Sephr UI bring-up
     callback. Exposes a C function `SephriumSetUiBootCallback(void(*)(void))`.
   - `chrome/browser/chrome_browser_main_mac.mm` — register the new
     ExtraParts (one-line patch in
     `ChromeBrowserMainPartsMac::AddParts`).

2. **`chrome/sephr/cal_bridge/cal_bridge.{h,mm}` updates**
   - `SephriumInitialize` body becomes:
     ```cpp
     content::ContentMainParams params(/*delegate=*/ChromeMainDelegate);
     params.argc = argc; params.argv = argv;
     content::ContentMain(std::move(params));
     ```
     Or, simpler: declare `extern "C" int ChromeMain(int, const char* const*);`
     and call it directly. ChromeMain is already exported from the
     framework; SephriumInitialize just becomes a forwarder that never
     returns.
   - Add `SephriumSetUiBootCallback` to the public C ABI so Sephr can
     register its UI bring-up before calling `SephriumInitialize`.
   - Add five symbols to `chrome/app/framework.exports`:
     `_SephriumSetUiBootCallback` plus any new ones added below.

3. **`sephr/Sources/App/SephrApp.swift` rewrite**
   - `main()` calls `CALEngineBootstrap.setUiBootCallback { … }` to register
     the AppKit setup, then calls `CALEngineBootstrap.initialize(argv:)`.
   - The closure is what previously ran in `main()`: `NSApp.delegate = …`,
     `setActivationPolicy(.regular)`, `app.activate(...)`.
   - Don't call `app.run()` — Chromium's pump is already running.

4. **Smoke harness becomes the runtime test**
   - `sephr-smoke` already does the right shape — only difference is
     `CALEngineBootstrap.initialize` no longer returns.
   - Verification: window appears, `https://example.com` paints,
     `onNavigation` callback fires with title "Example Domain".

### Risks
- Chromium's `ChromeMainDelegate` does a lot of chrome-specific init
  (signin, sync, extensions, autofill). For Phase 2 we let it all run —
  it's harmless background. Stripping it down is a Phase 3 concern.
- Sparkle and other AppKit-side observers register in `AppDelegate`.
  Those need to move into the ExtraParts callback so they observe the
  same NSApp instance Chromium owns.

### Estimate
1–2 engineer-days. Most of the time is in the ExtraParts wiring +
shaking out the run-loop assumptions in Sephr's existing Swift code.

---

## Option B — Sephr owns the run loop, drives Chromium with `BrowserMainRunner`

`SephriumInitialize` calls `content::BrowserMainRunner::Create()` +
`Initialize()`, which sets up `g_browser_process` synchronously and
returns. Then Sephr runs its own `NSApp.run()`, calling
`SephriumPumpOnce()` from a `CFRunLoopSource` to drain Chromium's task
queue.

### Pros
- Sephr keeps its existing `main()` shape. No ExtraParts patch.
- `SephriumInitialize` returns, so Phase 1's Swift code keeps working.

### Cons
- `BrowserMainRunner` is **not** a documented embedding API. It's an
  internal Chromium type used by browser_tests; the threading model
  is fragile and changes without notice.
- macOS `MessagePumpMac` integration is hairy. Mixing
  `CFRunLoopRun()` and Chromium's nested message pumps tends to break
  modal panels, drag-and-drop, sheet presentation.
- Every Chromium uplift (~6 weeks) risks a new run-loop incompat.

### When to pick this
Only if Phase 2 needs `SephriumInitialize` to return (e.g. for a unit
test harness, or if Sephr truly cannot give up `main()`). For the user
app, **Option A is correct**.

---

## Out of scope for Phase 2

- TabStrip / Omnibox / Media / Downloads / History / Extensions C ABIs
  (the original Phase 2 follow-ups in the Phase 1 plan). These are
  Phase 3 once the bootstrap works.
- Custom `BrowserContext` — Phase 2 leans on Chrome's `ProfileManager`,
  same as today. Custom contexts are Phase 4.
- Sparkle integration — keep current behaviour; reattach inside the
  ExtraParts callback.
- Renaming Chromium → Sephrium in the binary's product strings — separate
  rebrand patch.

## Pre-existing Sephr Swift drift (blocker before Phase 2 ships)

These are unrelated to CAL but block running the embedded app:

- `LittleSephrWindow.swift` calls `CALWebView.webView(with:profile:)` —
  the Swift name doesn't exist; should be `CALWebView(url:profile:)`.
- `SephrCommandBarViewModel.swift` calls `CALOmnibox.omnibox(...)`,
  `CALWebView.load(...)` — both stale.
- `SephrSpaceManager.swift` calls `CALProfile.deleteProfile(withID:)` —
  stale; the ObjC method is `deleteProfileWithID:`.
- `SephrSessionStore.swift` references `SephrDatabase.read`/`write` that
  don't exist on the type.
- `SephrLibraryPanel.swift` redundant Identifiable conformance.

Fix these before turning on the ExtraParts UI callback or Sephr will
crash on first window open.

## Verification (after Phase 2 lands)

1. `bash scripts/build_sephrium.sh --fast --target chrome` (full app build).
2. `swift build --product sephr-smoke -c release`.
3. `.build/release/sephr-smoke --url https://example.com`.
4. Window appears, example.com paints, stdout prints
   `Nav: https://example.com/ / Example Domain`.
5. `swift build -c release && .build/release/Sephr` (full app, after
   Swift drift fixes) — Sephr window appears with active CALWebView.

---

## Phase 2 progress log — 2026-06-03

Landed:
- `sephrium/patches/sephr/012-cal-browser-main-extra-parts.patch` — adds
  `chrome/browser/sephr_browser_main_extra_parts.{h,cc}` (ChromeBrowser­
  MainExtraParts subclass that fires a stored callback in PostBrowserStart),
  wires it via `chrome_browser_main.cc::AddParts()`, adds the new C entry
  `SephriumSetUiBootCallback`, and rewires `SephriumInitialize` to forward
  into `ChromeMain` (declared `extern "C" int ChromeMain(int, const char**)`).
- `chrome/app/framework.exports` now exports `_SephriumSetUiBootCallback`
  (21 `_Sephrium*` exports total). Gate passes; ad-hoc-signed inner dylib.
- `sephrium/package_framework.py` rewritten — copies the full
  `out/<mode>/Chromium Framework.framework` bundle (Helpers/, Resources/,
  Libraries/), adds `Sephrium` and `Headers` top-level symlinks, fixes the
  dylib install_name to `@rpath/Sephrium.framework/Sephrium`. (Codesign
  --deep complains about the extra `Sephrium` symlink at the framework
  root being "unsealed contents"; the inner dylib is signed separately.)
- `sephr-smoke` rebuilds and launches; first `SephriumInitialize` call now
  invokes `ChromeMain` and ChromeMain enters init.

### Unresolved blockers (next session)

1. **Host process can't both link AND dlopen the framework.** Behavior
   today on `sephr-smoke --url … --no-sandbox`:
   `Trying to load the allocator multiple times. This is *not* supported.`
   PartitionAlloc aborts because the framework is mapped twice — once via
   the SPM `-framework Sephrium` link in `Package.swift`, and a second time
   when `SetUpBundleOverrides()` dlopens `Versions/<v>/Chromium Framework`.
   chrome.exe avoids this by NOT linking the framework — it's a tiny
   bootstrap that dlopens + dlsyms `ChromeMain`. CAL is the awkward middle:
   it needs the framework's symbols at SPM build time. Two viable shapes:

   a. **Tiny C shim host**: replace `sephr-smoke` (and later `Sephr`) with a
      C entry point that dlopens `Sephrium.framework`, dlsyms
      `_SephriumInitialize` + `_SephriumSetUiBootCallback`, then calls them.
      CAL stays linked the way it is, but its load happens after the
      framework is already mapped — single mapping, PartitionAlloc happy.

   b. **Make CAL also dlopen-load**: CAL becomes a dylib that the shim
      loads after Sephrium. SPM-level changes, deeper rework.

   (a) is cheaper.

2. **Sandboxed helpers see "file system sandbox blocked open()" on the
   framework path** under the default profile. Visible BEFORE the
   allocator abort: Renderer + GPU + Network children all fail to dlopen
   the framework at the relative `Helpers/Chromium Helper.app/Contents/
   MacOS/../../../../Chromium Framework` path. The framework lives outside
   the macOS app bundle convention (it's under `.build/...`). Fix:
   (a) build a proper `Sephr.app` bundle for dev too (framework lives in
   `Sephr.app/Contents/Frameworks/`), or (b) `--no-sandbox` at the cost of
   sandbox-protected behavior — only safe for local dev.

3. **Codesign of the wrapped framework**. The strict Mac framework
   layout doesn't permit non-standard top-level symlinks (Apple expects
   only `Versions/` + the canonical `Resources`/`Helpers`/`<Name>`
   symlinks). Our `Sephrium` top-level symlink (needed for SPM
   `-framework Sephrium`) is flagged as "unsealed contents." Options:
   patch Chromium's `PRODUCT_FULLNAME_STRING` to `"Sephrium"` so the build
   naturally produces an Sephrium-named binary, or sign with
   `--preserve-metadata` and accept the unstamped wrapper.

Once 1+2 land, `sephr-smoke` is the natural P2 EXIT test.
