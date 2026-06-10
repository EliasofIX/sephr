// Copyright (c) Sephr. All rights reserved.
// Proprietary — not for redistribution.
//
// CAL bridge — C ABI between the Sephrium framework (Chromium) and CAL
// (Sephr's Objective-C++ embedding layer). All types crossing this boundary
// are opaque pointers or POD; no C++ types, no Skia, no STL. CAL therefore
// links against this header alone — no Chromium internal headers leak into
// the Swift Package Manager build of CAL.

#ifndef CHROME_SEPHR_CAL_BRIDGE_CAL_BRIDGE_H_
#define CHROME_SEPHR_CAL_BRIDGE_CAL_BRIDGE_H_

#include <stddef.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define SEPHRIUM_EXPORT __attribute__((visibility("default")))

// ---- Lifecycle ------------------------------------------------------------

// Boots Chromium inside the calling process. CAL Phase 2: this is a thin
// wrapper around ChromeMain; once called it never returns until the
// browser process shuts down. Chromium owns the main run loop. Embedders
// must register their UI bring-up via SephriumSetUiBootCallback BEFORE
// calling this — that callback fires from PostBrowserStart, by which point
// the browser process and ProfileManager are ready.
SEPHRIUM_EXPORT void SephriumInitialize(int argc, const char* const* argv);

// Drains one pass of the Chromium UI message pump. Phase 2 Option A
// (Chromium owns the pump) makes this a no-op; kept for ABI stability.
SEPHRIUM_EXPORT void SephriumPumpOnce(void);

// Embedder UI bring-up — fired from PostBrowserStart, on the main thread,
// after g_browser_process and the initial profile are ready. Must be
// installed BEFORE SephriumInitialize. Pass NULL to clear (Chromium then
// runs headless until shutdown).
typedef void (*SephriumUiBootCallback)(void);
SEPHRIUM_EXPORT void SephriumSetUiBootCallback(SephriumUiBootCallback callback);

// External-URL routing — fired when the OS asks Sephr (as the system
// default browser) to open a URL: a link clicked in another app, a Handoff
// hand-off, or the URL that cold-launched the app. Chromium would otherwise
// open these in a native browser window; this callback hands them to the
// embedder so each becomes a real Sephr/CAL tab instead. `url` is transient
// (copy it before returning). Register from UI-boot once the tab UI exists;
// any URL that arrived earlier (the cold-launch race) is buffered on the
// Chromium side and replayed here in order the moment you register. Pass
// NULL to clear. `ctx` is passed back verbatim on every invocation.
typedef void (*SephriumOpenExternalURLCallback)(void* ctx, const char* url);
SEPHRIUM_EXPORT void
SephriumSetOpenExternalURLCallback(SephriumOpenExternalURLCallback callback,
                                   void* ctx);

// ---- Profile --------------------------------------------------------------

typedef struct SephriumProfileOpaque* SephriumProfileRef;

// Returns a retained handle to the BrowserContext for `profile_id`, creating
// it on disk at `disk_path` if needed. Returns NULL on failure.
SEPHRIUM_EXPORT SephriumProfileRef
SephriumProfileGet(const char* profile_id, const char* disk_path);

SEPHRIUM_EXPORT void SephriumProfileRelease(SephriumProfileRef profile);

// ---- WebContents ----------------------------------------------------------

typedef struct SephriumWebContentsOpaque* SephriumWebContentsRef;

SEPHRIUM_EXPORT SephriumWebContentsRef
SephriumWebContentsCreate(SephriumProfileRef profile, const char* initial_url);

SEPHRIUM_EXPORT void
SephriumWebContentsDestroy(SephriumWebContentsRef web_contents);

// Returns an unretained NSView* (cast to void*) — the renderer's native view.
// CAL adds it as a subview; the WebContents owns it.
SEPHRIUM_EXPORT void*
SephriumWebContentsGetNativeView(SephriumWebContentsRef web_contents);

// Returns an unretained NSWindow* (cast to void*) — the NSWindow that owns
// the WebContents' rendering surface. CAL embeds this as a borderless
// child window of the embedder's main NSWindow so the renderer's compositor
// (which is bound to its host NSWindow) keeps painting into a window that
// visually sits over the embedder's content area. Returns NULL if the host
// window can't be obtained (e.g. headless Browser teardown).
SEPHRIUM_EXPORT void*
SephriumWebContentsGetHostNSWindow(SephriumWebContentsRef web_contents);

SEPHRIUM_EXPORT void
SephriumWebContentsLoadURL(SephriumWebContentsRef web_contents, const char* url);

SEPHRIUM_EXPORT void SephriumWebContentsGoBack(SephriumWebContentsRef);
SEPHRIUM_EXPORT void SephriumWebContentsGoForward(SephriumWebContentsRef);
SEPHRIUM_EXPORT void SephriumWebContentsReload(SephriumWebContentsRef);
SEPHRIUM_EXPORT void SephriumWebContentsStop(SephriumWebContentsRef);

SEPHRIUM_EXPORT void
SephriumWebContentsSetSize(SephriumWebContentsRef, int width, int height);

SEPHRIUM_EXPORT void SephriumWebContentsFocus(SephriumWebContentsRef);
SEPHRIUM_EXPORT void
SephriumWebContentsSetFrozen(SephriumWebContentsRef, int frozen);

// Visibility ONLY — WasShown()/WasHidden() with no page-freeze and no
// focus change. Unlike SetFrozen/Focus (which DCHECK in the renderer host
// if called before the initial navigation commits), this is safe at any
// point in a WebContents' life. CAL drives it from CALWebView's window
// membership so the browser-side compositor gets a real hidden->visible
// transition when a tab's view enters a window — which is what forces the
// renderer to produce a frame for the newly-attached surface. WebContents
// are created hidden (see SephriumWebContentsCreate), so the first attach
// renders correctly instead of staying blank until a switch-away/back.
SEPHRIUM_EXPORT void
SephriumWebContentsSetVisible(SephriumWebContentsRef, int visible);

// Caller owns the returned char*; free with SephriumStringFree.
SEPHRIUM_EXPORT char* SephriumWebContentsCopyURL(SephriumWebContentsRef);
SEPHRIUM_EXPORT char* SephriumWebContentsCopyTitle(SephriumWebContentsRef);

// Returns 1 while the page is playing audio (used for sleep exemption).
SEPHRIUM_EXPORT int SephriumWebContentsIsAudible(SephriumWebContentsRef);

typedef void (*SephriumNavCallback)(void* ctx,
                                   const char* url,
                                   const char* title);

SEPHRIUM_EXPORT void
SephriumWebContentsSetNavCallback(SephriumWebContentsRef,
                                 SephriumNavCallback callback,
                                 void* ctx);

// Favicon — fires on the UI thread whenever the page's favicon download
// completes. `bgra` is a transient buffer; the embedder must copy out the
// pixels before returning. A NULL/empty payload means the lookup failed;
// embedders should clear any cached favicon for the page.
typedef void (*SephriumFaviconCallback)(void* ctx,
                                       const void* bgra,
                                       int width,
                                       int height,
                                       int row_bytes);

SEPHRIUM_EXPORT void
SephriumWebContentsSetFaviconCallback(SephriumWebContentsRef,
                                     SephriumFaviconCallback callback,
                                     void* ctx);

// Loading state — fires on the UI thread whenever the WebContents'
// `IsLoading()` flips. `is_loading` is 1 while a navigation is in
// progress (start → stop), 0 once the page has settled. Embedders use
// this to drive a top-of-page loading indicator without polling.
typedef void (*SephriumLoadingCallback)(void* ctx, int is_loading);

SEPHRIUM_EXPORT void
SephriumWebContentsSetLoadingCallback(SephriumWebContentsRef,
                                     SephriumLoadingCallback callback,
                                     void* ctx);

// Context-menu "Open Link in New Tab" — fires when the user picks that
// item from the right-click menu. Embedder spawns a real Sephr tab in
// the same space pointing at `url`. The C++ bridge owns the menu, the
// Copy Link / Copy Image URL / paste etc. items handle themselves; this
// callback is just for the tab-creation handoff to the Swift layer.
typedef void (*SephriumNewTabRequestCallback)(void* ctx, const char* url);

SEPHRIUM_EXPORT void
SephriumWebContentsSetNewTabRequestCallback(
    SephriumWebContentsRef,
    SephriumNewTabRequestCallback callback,
    void* ctx);

// Hovered-link target URL — fires on the UI thread whenever the renderer
// reports that the pointer moved onto (or off) a link, i.e. Chromium's
// WebContentsDelegate::UpdateTargetURL. `url` is the link's resolved
// destination while the cursor is over a link, and the empty string when
// the cursor leaves the link (status text cleared). The embedder uses this
// to know what a Shift+hover "peek" gesture should preview without having
// to click. Like the other callbacks `url` is transient — copy it before
// returning.
typedef void (*SephriumTargetURLCallback)(void* ctx, const char* url);

SEPHRIUM_EXPORT void
SephriumWebContentsSetTargetURLCallback(
    SephriumWebContentsRef,
    SephriumTargetURLCallback callback,
    void* ctx);

// Popup adoption — fires when the page calls window.open(...) with popup
// window features (Chromium disposition NEW_POPUP), e.g. an OAuth / SSO
// sign-in popup like claude.ai's "Continue with Google". The bridge lets
// Chromium create the popup WebContents so it keeps its opener relationship
// (window.opener) and shares the opener's browsing-context group — this is
// what makes the callback page's `window.opener.postMessage(token)` reach
// the page that opened it. `popup` is a fully-formed SephriumWebContentsRef
// the embedder ADOPTS: it must wrap it in a host view (Sephr shows it in a
// peek overlay) and owns it from here — i.e. it is responsible for calling
// SephriumWebContentsDestroy when the host goes away. If no callback is
// registered the popup is dropped (its contents destroyed) to avoid a leak.
typedef void (*SephriumPopupRequestCallback)(void* ctx,
                                            SephriumWebContentsRef popup);

SEPHRIUM_EXPORT void
SephriumWebContentsSetPopupRequestCallback(
    SephriumWebContentsRef,
    SephriumPopupRequestCallback callback,
    void* ctx);

// window.close() — fires when script asks to close this WebContents'
// window. Chromium only delivers this for windows the script is allowed to
// close (those it opened itself), so it's the signal an OAuth popup uses to
// dismiss itself once it has posted its result back to the opener. The
// embedder tears down whatever host is showing this WebContents (Sephr
// dismisses the peek, which deallocs the adopted view and destroys the
// contents).
typedef void (*SephriumCloseRequestCallback)(void* ctx);

SEPHRIUM_EXPORT void
SephriumWebContentsSetCloseRequestCallback(
    SephriumWebContentsRef,
    SephriumCloseRequestCallback callback,
    void* ctx);

// Snapshot — returned as raw BGRA8888 bytes; CAL wraps with CGImage→NSImage.
typedef void (*SephriumSnapshotCallback)(void* ctx,
                                        const void* bgra,
                                        int width,
                                        int height,
                                        int row_bytes);

SEPHRIUM_EXPORT void
SephriumWebContentsCaptureSnapshot(SephriumWebContentsRef,
                                  int width,
                                  int height,
                                  SephriumSnapshotCallback callback,
                                  void* ctx);

// ---- History --------------------------------------------------------------
//
// Phase 4 surface — drives Chromium's HistoryService.
// All calls dispatch onto the UI thread internally; callbacks fire back on
// the UI thread too. CAL is expected to forward to AppKit / dispatch back to
// its delegate from there.

typedef struct SephriumHistoryEntry {
  const char* url;
  const char* title;
  double visited_at;   // seconds since 1970
  int visit_count;
} SephriumHistoryEntry;

typedef void (*SephriumHistoryCallback)(void* ctx,
                                       const SephriumHistoryEntry* entries,
                                       int count);

// `search_text` empty → most-recent slice (up to `limit`).
SEPHRIUM_EXPORT void
SephriumHistoryQuery(SephriumProfileRef profile,
                    const char* search_text,
                    int limit,
                    SephriumHistoryCallback callback,
                    void* ctx);

SEPHRIUM_EXPORT void
SephriumHistoryDeleteURL(SephriumProfileRef profile, const char* url);

SEPHRIUM_EXPORT void SephriumHistoryClearAll(SephriumProfileRef profile);

// ---- Downloads ------------------------------------------------------------

typedef struct SephriumDownloadEntry {
  const char* identifier;
  const char* url;
  const char* target_path;
  const char* mime_type;
  long long total_bytes;
  long long received_bytes;
  int state;  // 0=in_progress 1=complete 2=cancelled 3=interrupted 4=paused
} SephriumDownloadEntry;

typedef void (*SephriumDownloadsCallback)(void* ctx,
                                         const SephriumDownloadEntry* entries,
                                         int count);

// Subscribe receives an initial snapshot of all current downloads, then a
// fresh full snapshot every time a download is added / updated / removed.
// Pass NULL callback to unsubscribe.
SEPHRIUM_EXPORT void
SephriumDownloadsSubscribe(SephriumProfileRef profile,
                          SephriumDownloadsCallback callback,
                          void* ctx);

SEPHRIUM_EXPORT void
SephriumDownloadPause(SephriumProfileRef profile, const char* identifier);
SEPHRIUM_EXPORT void
SephriumDownloadResume(SephriumProfileRef profile, const char* identifier);
SEPHRIUM_EXPORT void
SephriumDownloadCancel(SephriumProfileRef profile, const char* identifier);

// ---- Extensions -----------------------------------------------------------

typedef struct SephriumExtensionEntry {
  const char* identifier;
  const char* name;
  const char* version;
  int enabled;  // 0 = disabled, 1 = enabled
} SephriumExtensionEntry;

typedef void (*SephriumExtensionsCallback)(
    void* ctx,
    const SephriumExtensionEntry* entries,
    int count);

// Subscribe receives an initial snapshot of all installed extensions
// (enabled first, then disabled), then a fresh full snapshot whenever one is
// loaded / unloaded / installed / uninstalled. Pass NULL callback to
// unsubscribe.
SEPHRIUM_EXPORT void
SephriumExtensionsSubscribe(SephriumProfileRef profile,
                           SephriumExtensionsCallback callback,
                           void* ctx);

SEPHRIUM_EXPORT void
SephriumExtensionsSetEnabled(SephriumProfileRef profile,
                            const char* identifier,
                            int enabled);

SEPHRIUM_EXPORT void
SephriumExtensionsUninstall(SephriumProfileRef profile,
                           const char* identifier);

// Installs a local CRX3 package (off-store, silent). Asynchronous — the
// subscribe callback fires with the new list once it loads.
SEPHRIUM_EXPORT void
SephriumExtensionsInstallCRX(SephriumProfileRef profile, const char* path);

// ---- Omnibox / Autocomplete ----------------------------------------------

typedef struct SephriumOmniboxResult {
  const char* type;             // "url" "search" "history" "bookmark"
  const char* contents;         // user-visible primary text
  const char* description;      // secondary line, often the page title
  const char* destination_url;
} SephriumOmniboxResult;

typedef void (*SephriumOmniboxCallback)(void* ctx,
                                       const SephriumOmniboxResult* results,
                                       int count);

SEPHRIUM_EXPORT void
SephriumOmniboxQuery(SephriumProfileRef profile,
                    const char* input_text,
                    SephriumOmniboxCallback callback,
                    void* ctx);

// ---- String helper --------------------------------------------------------

SEPHRIUM_EXPORT void SephriumStringFree(char* s);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // CHROME_SEPHR_CAL_BRIDGE_CAL_BRIDGE_H_
