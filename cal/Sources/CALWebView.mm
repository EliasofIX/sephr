// Copyright (c) Sephr. All rights reserved.
#import "CALWebView.h"
#import "CALProfile.h"
#import "CALInternal.h"

#import <CoreGraphics/CoreGraphics.h>

@interface CALWebView ()
// Register every bridge callback (nav/favicon/loading/new-tab/target-url/
// popup/close) against the current _webContents. Shared by the URL-creating
// initializer and the popup-adopting one.
- (void)_wireContentsCallbacks;
// Build a CALWebView around an already-live WebContents handed up by the
// bridge (an adopted window.open popup) instead of creating a fresh one.
+ (instancetype)_adoptingWebContents:(SephriumWebContentsRef)ref
                             profile:(NSString*)profileID;
// Push effective visibility (in a window AND that window at least partially
// on glass) down to the WebContents. The single funnel for WasShown/WasHidden.
- (void)_updateEffectiveVisibility;
// NSWindowDidChangeOcclusionStateNotification handler for the current window.
- (void)_windowOcclusionDidChange:(NSNotification*)note;
@end

// Defensive UTF-8 string wrapper. -stringWithUTF8String: returns nil if the
// input is not valid UTF-8; we fall back to lossy interpretation rather than
// surface a nil through the @"" branch (callers expecting a property to
// always have a value can otherwise nil-deref on call sites that forgot the
// nil check).
static inline NSString* CAL_StringSafe(const char* s) {
    if (!s) return @"";
    NSString* out = [NSString stringWithUTF8String:s];
    if (out) return out;
    NSData* data = [NSData dataWithBytes:s length:strlen(s)];
    out = [[NSString alloc] initWithData:data
                                encoding:NSUTF8StringEncoding];
    if (out) return out;
    out = [[NSString alloc] initWithData:data
                                encoding:NSISOLatin1StringEncoding];
    return out ?: @"";
}

@implementation CALWebView {
    SephriumWebContentsRef _webContents;
    NSString* _profileID;
    NSString* _currentURL;
    NSString* _currentTitle;
    BOOL _isLoading;
    // Desired per-tab mute. Mirrored to the WebContents and re-applied on
    // (re)wire so mute survives sleep/wake (the WebContents is destroyed on
    // sleep and recreated on wake). isAudioMuted reads live truth when a
    // WebContents exists, else falls back to this.
    BOOL _desiredMuted;
    BOOL _chromiumViewAttached;
    NSSize _lastReportedSize;  // for setFrameSize early-exit
    // Last media-session snapshot from CAL_MediaSessionCallback. Cached so
    // property reads are synchronous; cleared on sleep (the session dies
    // with the WebContents) so a stale "playing" can't outlive its page.
    BOOL _isMediaControllable;
    BOOL _isMediaPlaying;
    BOOL _canMediaPrevTrack;
    BOOL _canMediaNextTrack;
    NSString* _mediaTitle;
    NSString* _mediaArtist;
    // Trackpad swipe accumulator for smoother back/forward navigation
    CGFloat _swipeAccum;
    BOOL _swipeCommitted;
}

// All four trampolines re-enter Obj-C on the UI thread. They route the work
// through dispatch_async to main so callbacks running on Chromium's UI thread
// don't have to grab AppKit locks; the dispatch also lets us hop off any
// internal Chromium re-entrancy that calls SetUrl→Notify→OurTrampoline before
// the renderer has finished its current task.

static void CAL_NavCallback(void* ctx, const char* url, const char* title) {
    if (!ctx) return;
    // `view` is captured strongly by the block below — ARC retains it across
    // the dispatch_async, so the underlying instance can't be deallocated
    // mid-callback even if Swift drops its last reference simultaneously.
    CALWebView* view = (__bridge CALWebView*)ctx;
    NSString* u = CAL_StringSafe(url);
    NSString* t = CAL_StringSafe(title);
    dispatch_async(dispatch_get_main_queue(), ^{
        view->_currentURL = u;
        view->_currentTitle = t;
        if (view.onNavigation) view.onNavigation(u, t);
    });
}

// Builds an NSImage from a BGRA8888 buffer (the favicon bitmap Chromium
// hands us via WebContents::DownloadImage). The buffer is transient — we
// copy it via CFData before returning. Returns nil on null/empty input
// so callers can clear any cached favicon for the page.
static NSImage* CAL_ImageFromBGRA(const void* bgra,
                                   int w, int h, int row_bytes) {
    if (!bgra || w <= 0 || h <= 0 || row_bytes <= 0) return nil;
    // Defensive: reject implausibly large bitmaps (a corrupted row_bytes
    // could otherwise OOM the malloc inside CFDataCreate).
    if (w > 8192 || h > 8192 || row_bytes > 8192 * 4) return nil;
    if (row_bytes < w * 4) return nil;  // not enough bytes per row
    size_t byteCount = (size_t)row_bytes * (size_t)h;
    CFDataRef cfData = CFDataCreate(kCFAllocatorDefault,
                                    (const UInt8*)bgra, byteCount);
    if (!cfData) return nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSImage* img = nil;
    if (provider && cs) {
        CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst |
                            kCGBitmapByteOrder32Little;
        CGImageRef cg = CGImageCreate((size_t)w, (size_t)h, 8, 32,
                                      (size_t)row_bytes, cs, info,
                                      provider, NULL, false,
                                      kCGRenderingIntentDefault);
        if (cg) {
            img = [[NSImage alloc] initWithCGImage:cg
                                              size:NSMakeSize(w, h)];
            CGImageRelease(cg);
        }
    }
    if (cs) CGColorSpaceRelease(cs);
    if (provider) CGDataProviderRelease(provider);
    CFRelease(cfData);
    return img;
}

static void CAL_FaviconCallback(void* ctx,
                                 const void* bgra,
                                 int w, int h, int row_bytes) {
    if (!ctx) return;
    CALWebView* view = (__bridge CALWebView*)ctx;
    NSImage* img = CAL_ImageFromBGRA(bgra, w, h, row_bytes);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.onFavicon) view.onFavicon(img);
    });
}

static void CAL_LoadingCallback(void* ctx, int is_loading) {
    if (!ctx) return;
    CALWebView* view = (__bridge CALWebView*)ctx;
    BOOL loading = is_loading != 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        view->_isLoading = loading;
        if (view.onLoading) view.onLoading(loading, 0.0);
    });
}

static void CAL_AudioStateCallback(void* ctx, int is_audible) {
    if (!ctx) return;
    CALWebView* view = (__bridge CALWebView*)ctx;
    BOOL audible = is_audible != 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.onAudioStateChange) view.onAudioStateChange(audible);
    });
}

// Merged media-session snapshot (play/pause state + Media Session API
// metadata + track-skip availability). Strings are transient UTF-8 owned by
// the bridge — CAL_StringSafe copies them before the hop to main. Empty
// metadata surfaces as nil so Swift can `?? tab.title` cleanly.
static void CAL_MediaSessionCallback(void* ctx,
                                     int is_controllable,
                                     int is_playing,
                                     const char* title,
                                     const char* artist,
                                     const char* source_title,
                                     int can_prev_track,
                                     int can_next_track) {
    if (!ctx) return;
    (void)source_title;  // not surfaced yet — favicon + tab title cover it
    CALWebView* view = (__bridge CALWebView*)ctx;
    NSString* t = (title && title[0]) ? CAL_StringSafe(title) : nil;
    NSString* a = (artist && artist[0]) ? CAL_StringSafe(artist) : nil;
    BOOL controllable = is_controllable != 0;
    BOOL playing = is_playing != 0;
    BOOL canPrev = can_prev_track != 0;
    BOOL canNext = can_next_track != 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        view->_isMediaControllable = controllable;
        view->_isMediaPlaying = playing;
        view->_canMediaPrevTrack = canPrev;
        view->_canMediaNextTrack = canNext;
        view->_mediaTitle = t;
        view->_mediaArtist = a;
        if (view.onMediaSessionChange) view.onMediaSessionChange();
    });
}

static void CAL_NewTabRequestCallback(void* ctx, const char* url) {
    if (!ctx) return;
    CALWebView* view = (__bridge CALWebView*)ctx;
    NSString* u = CAL_StringSafe(url);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.onNewTabRequest) view.onNewTabRequest(u);
    });
}

// Hovered-link target URL. Chromium passes an empty string when the cursor
// leaves a link; we surface that as nil so Swift can clear its "what would
// peek preview" state cleanly rather than special-casing @"".
static void CAL_TargetURLCallback(void* ctx, const char* url) {
    if (!ctx) return;
    CALWebView* view = (__bridge CALWebView*)ctx;
    NSString* u = (url && url[0]) ? CAL_StringSafe(url) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.onTargetURLChange) view.onTargetURLChange(u);
    });
}

// window.open popup adopted by the bridge. `popup` is a live
// SephriumWebContentsRef the bridge handed us ownership of. We wrap it in a
// CALWebView and pass that to the opener's onPopupRequest so the embedder can
// host it. If no host is registered we must destroy the ref ourselves or the
// WebContents leaks. `opener` is captured strongly across the dispatch so it
// (and its _profileID ivar) stays valid; the ref stays valid because nothing
// owns/destroys it until we wrap it here.
static void CAL_PopupRequestCallback(void* ctx, SephriumWebContentsRef popup) {
    if (!ctx || !popup) return;
    CALWebView* opener = (__bridge CALWebView*)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!opener.onPopupRequest) {
            SephriumWebContentsDestroy(popup);
            return;
        }
        CALWebView* popupView =
            [CALWebView _adoptingWebContents:popup
                                     profile:opener->_profileID];
        opener.onPopupRequest(popupView);
    });
}

// window.close() on this view's window — the host should dismiss whatever is
// showing this view. Async to main so any teardown the host triggers (which
// may dealloc this view and destroy the WebContents) happens after the
// bridge's CloseContents has returned, never re-entrantly.
static void CAL_CloseRequestCallback(void* ctx) {
    if (!ctx) return;
    CALWebView* view = (__bridge CALWebView*)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.onCloseRequest) view.onCloseRequest();
    });
}

+ (instancetype)webViewWithURL:(NSURL*)url profile:(NSString*)profileID {
    CALWebView* view = [[CALWebView alloc] initWithFrame:NSZeroRect];
    view->_profileID = [profileID copy];
    view->_currentURL = [[url absoluteString] copy] ?: @"";
    view->_currentTitle = @"";
    view->_lastReportedSize = NSZeroSize;

    CALProfile* profile = [CALProfile profileWithID:profileID];
    SephriumProfileRef profileRef = (SephriumProfileRef)profile.bridgeHandle;

    // SephriumProfileGet returns NULL if g_browser_process isn't initialised
    // yet — this should only happen if a caller creates a CALWebView before
    // bootChromium → PostBrowserStart fires. We surface a usable-but-empty
    // view rather than crashing; the next code path that tries to load a
    // URL will no-op until the underlying contents exist.
    if (!profileRef) {
        NSLog(@"[sephr/CALWebView] WARNING: profile bridge handle is NULL "
              "for profileID=%@ — WebContents will not be created. Was "
              "+bootChromium called and PostBrowserStart fired before this "
              "view was created?", profileID);
        return view;
    }

    view->_webContents = SephriumWebContentsCreate(
        profileRef, [view->_currentURL UTF8String]);

    // NOTE: we DO NOT addSubview the chromium native view here. At this
    // point CALWebView is detached (frame=0x0, no window), so the
    // BrowserCompositorMac would configure for a null host window and
    // never reconnect. Instead, we attach the chromium view in
    // viewDidMoveToWindow — by which point CALWebView is already in an
    // NSWindow and the compositor configures properly.

    [view _wireContentsCallbacks];
    return view;
}

// Adopt a live WebContents handed up by the bridge (a window.open popup)
// rather than creating a fresh one. The contents already carries its opener
// relationship and has usually started navigating to its target, so we just
// snapshot its current URL/title and wire our callbacks. It's created
// detached (no window); the host adding this view to a window drives
// viewDidMoveToWindow → attach + SetVisible, same as a normal tab.
+ (instancetype)_adoptingWebContents:(SephriumWebContentsRef)ref
                             profile:(NSString*)profileID {
    CALWebView* view = [[CALWebView alloc] initWithFrame:NSZeroRect];
    view->_profileID = [profileID copy];
    view->_webContents = ref;
    view->_lastReportedSize = NSZeroSize;

    char* u = ref ? SephriumWebContentsCopyURL(ref) : NULL;
    view->_currentURL = CAL_StringSafe(u);
    if (u) SephriumStringFree(u);
    char* t = ref ? SephriumWebContentsCopyTitle(ref) : NULL;
    view->_currentTitle = CAL_StringSafe(t);
    if (t) SephriumStringFree(t);

    [view _wireContentsCallbacks];
    return view;
}

- (void)_wireContentsCallbacks {
    if (!_webContents) return;
    SephriumWebContentsSetNavCallback(
        _webContents, CAL_NavCallback, (__bridge void*)self);
    SephriumWebContentsSetFaviconCallback(
        _webContents, CAL_FaviconCallback, (__bridge void*)self);
    SephriumWebContentsSetLoadingCallback(
        _webContents, CAL_LoadingCallback, (__bridge void*)self);
    SephriumWebContentsSetAudioStateCallback(
        _webContents, CAL_AudioStateCallback, (__bridge void*)self);
    SephriumWebContentsSetMediaSessionCallback(
        _webContents, CAL_MediaSessionCallback, (__bridge void*)self);
    // Re-apply any desired mute to the (possibly freshly recreated) contents
    // so per-tab mute persists across sleep/wake.
    if (_desiredMuted)
        SephriumWebContentsSetAudioMuted(_webContents, 1);
    SephriumWebContentsSetNewTabRequestCallback(
        _webContents, CAL_NewTabRequestCallback, (__bridge void*)self);
    SephriumWebContentsSetTargetURLCallback(
        _webContents, CAL_TargetURLCallback, (__bridge void*)self);
    SephriumWebContentsSetPopupRequestCallback(
        _webContents, CAL_PopupRequestCallback, (__bridge void*)self);
    SephriumWebContentsSetCloseRequestCallback(
        _webContents, CAL_CloseRequestCallback, (__bridge void*)self);
}

- (BOOL)isFlipped { return YES; }

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

// Tear down the live WebContents, leaving the view reusable. Used by
// dealloc AND sleep.
//
// CRITICAL ordering — clear callbacks BEFORE destroying the WebContents.
// The bridge's holder destructor cancels in-flight observers, but any
// callback already on the dispatch queue would see a freed CALWebView via
// (__bridge void*)self. Setting them to NULL gives the bridge a chance to
// no-op those re-entries. (For sleep the view itself survives, but the
// contents ref the queued callback captured would be dangling.)
- (void)_teardownWebContents {
    if (!_webContents) return;
    SephriumWebContentsSetNavCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetFaviconCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetLoadingCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetAudioStateCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetMediaSessionCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetNewTabRequestCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetTargetURLCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetPopupRequestCallback(_webContents, NULL, NULL);
    SephriumWebContentsSetCloseRequestCallback(_webContents, NULL, NULL);
    // Detach the chromium NSView before we destroy its owning
    // WebContents. After destroy the underlying RenderWidgetHostView
    // is gone and any AppKit hit-testing into the still-retained
    // subview would walk freed memory.
    for (NSView* sub in [self.subviews copy]) {
        [sub removeFromSuperview];
    }
    // Un-latch the attach state so a later wake re-runs the
    // viewDidMoveToWindow attach path for the NEW native view (dealloc
    // doesn't care, sleep does).
    _chromiumViewAttached = NO;
    SephriumWebContentsRef wc = _webContents;
    _webContents = NULL;
    SephriumWebContentsDestroy(wc);
}

- (void)dealloc {
    // Non-block observers have been auto-removed since 10.11, but the
    // codebase style is explicit teardown.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _teardownWebContents];
}

- (BOOL)isAsleep { return _webContents == NULL && _profileID != nil; }

- (BOOL)isAudible {
    return _webContents && SephriumWebContentsIsAudible(_webContents) != 0;
}

- (BOOL)isAudioMuted {
    if (_webContents)
        return SephriumWebContentsIsAudioMuted(_webContents) != 0;
    return _desiredMuted;
}

- (void)setAudioMuted:(BOOL)muted {
    _desiredMuted = muted;
    if (_webContents)
        SephriumWebContentsSetAudioMuted(_webContents, muted ? 1 : 0);
}

- (BOOL)isMediaControllable { return _isMediaControllable; }
- (BOOL)isMediaPlaying      { return _isMediaPlaying; }
- (NSString*)mediaTitle     { return _mediaTitle; }
- (NSString*)mediaArtist    { return _mediaArtist; }
- (BOOL)canMediaPrevTrack   { return _canMediaPrevTrack; }
- (BOOL)canMediaNextTrack   { return _canMediaNextTrack; }

- (void)mediaResume {
    if (_webContents) SephriumWebContentsMediaResume(_webContents);
}
- (void)mediaSuspend {
    if (_webContents) SephriumWebContentsMediaSuspend(_webContents);
}
- (void)mediaNextTrack {
    if (_webContents) SephriumWebContentsMediaNextTrack(_webContents);
}
- (void)mediaPreviousTrack {
    if (_webContents) SephriumWebContentsMediaPreviousTrack(_webContents);
}

// The media session dies with the WebContents and the bridge can't signal
// that (its observer is torn down too) — clear the snapshot ourselves so a
// Now Playing UI doesn't keep showing a dead session, and ping the host.
// Called from sleep (never dealloc: firing a host callback out of dealloc
// would hand it a half-dead view).
- (void)_resetMediaSessionState {
    BOOL wasControllable = _isMediaControllable;
    _isMediaControllable = NO;
    _isMediaPlaying = NO;
    _canMediaPrevTrack = NO;
    _canMediaNextTrack = NO;
    _mediaTitle = nil;
    _mediaArtist = nil;
    if (wasControllable && self.onMediaSessionChange)
        self.onMediaSessionChange();
}

// Snapshot the committed URL, then destroy the WebContents. The view
// object (and its place in the tab model / sidebar) survives; wake
// recreates the contents at the snapshotted URL. _currentTitle is left
// as-is — CAL_NavCallback kept it current, so the sidebar label survives
// the nap too.
- (void)sleep {
    if (!_webContents) return;
    char* u = SephriumWebContentsCopyURL(_webContents);
    NSString* live = CAL_StringSafe(u);
    if (u) SephriumStringFree(u);
    if (live.length) _currentURL = [live copy];
    [self _teardownWebContents];
    [self _resetMediaSessionState];
}

// Recreate the WebContents at the last committed URL. Mirrors
// +webViewWithURL:profile: — created hidden/detached; if the view is
// currently in a window, re-run the attach path normally driven by
// viewDidMoveToWindow so it paints (it re-fetches the native view,
// re-parents it, pushes the current size and flips hidden->visible).
- (void)wake {
    if (_webContents) return;
    CALProfile* profile = [CALProfile profileWithID:_profileID];
    SephriumProfileRef profileRef = (SephriumProfileRef)profile.bridgeHandle;
    if (!profileRef) {
        NSLog(@"[sephr/CALWebView] wake: NULL profile ref for %@", _profileID);
        return;
    }
    _lastReportedSize = NSZeroSize;  // force the next SetSize through
    _webContents = SephriumWebContentsCreate(
        profileRef, [(_currentURL ?: @"about:blank") UTF8String]);
    [self _wireContentsCallbacks];
    if (self.window) {
        [self viewDidMoveToWindow];
    }
}

- (void)loadURL:(NSString*)url {
    if (_webContents && url.length) {
        const char* c = url.UTF8String;
        if (c) SephriumWebContentsLoadURL(_webContents, c);
    }
}
- (void)goBack    { if (_webContents) SephriumWebContentsGoBack(_webContents); }
- (void)goForward { if (_webContents) SephriumWebContentsGoForward(_webContents); }
- (void)reload    { if (_webContents) SephriumWebContentsReload(_webContents); }
- (void)reloadIgnoringCache { if (_webContents) SephriumWebContentsReloadBypassingCache(_webContents); }
- (void)stop      { if (_webContents) SephriumWebContentsStop(_webContents); }
- (void)freeze    { if (_webContents) SephriumWebContentsSetFrozen(_webContents, 1); }
- (void)unfreeze  { if (_webContents) SephriumWebContentsSetFrozen(_webContents, 0); }
- (void)focus     { if (_webContents) SephriumWebContentsFocus(_webContents); }
- (void)blur      { [self.window makeFirstResponder:nil]; }

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (!_webContents) return;
    // Avoid re-IPCing identical sizes — Chromium's Resize is idempotent on
    // the browser side but still walks the Mojo channel down to the
    // renderer. During an interactive window drag this fires every pixel
    // of mouse motion, so deduping cuts ~95% of those IPCs.
    if (newSize.width == _lastReportedSize.width &&
        newSize.height == _lastReportedSize.height) {
        return;
    }
    _lastReportedSize = newSize;
    int w = (int)newSize.width;
    int h = (int)newSize.height;
    if (w < 0) w = 0;
    if (h < 0) h = 0;
    SephriumWebContentsSetSize(_webContents, w, h);
    // autoresizingMask normally drives subview sizing, but if a parent
    // layout pushed a size update before the chromium NSView was added,
    // mirror once explicitly.
    if (!_chromiumViewAttached) {
        for (NSView* sub in self.subviews) {
            sub.frame = self.bounds;
        }
    }
}

- (NSString*)currentURL {
    if (!_webContents) return _currentURL ?: @"";
    char* c = SephriumWebContentsCopyURL(_webContents);
    NSString* s = CAL_StringSafe(c);
    if (c) SephriumStringFree(c);
    return s;
}

- (NSString*)currentTitle {
    if (!_webContents) return _currentTitle ?: @"";
    char* c = SephriumWebContentsCopyTitle(_webContents);
    NSString* s = CAL_StringSafe(c);
    if (c) SephriumStringFree(c);
    return s;
}

- (BOOL)canGoBack    { return NO; }    // wired up post-bootstrap
- (BOOL)canGoForward { return NO; }
- (BOOL)isLoading    { return _isLoading; }

typedef struct {
    void (^completion)(NSImage* _Nullable);
    NSSize size;
} SnapshotCtx;

static void CAL_SnapshotCallback(void* ctx,
                                 const void* bgra,
                                 int w,
                                 int h,
                                 int row_bytes) {
    if (!ctx) return;
    SnapshotCtx* sc = (SnapshotCtx*)ctx;
    void (^completion)(NSImage* _Nullable) = sc->completion;
    NSSize size = sc->size;
    sc->completion = nil;  // drop the block reference before free
    free(sc);

    NSImage* img = nil;
    if (bgra && w > 0 && h > 0 && row_bytes > 0 &&
        w <= 8192 && h <= 8192 && row_bytes <= 8192 * 4 &&
        row_bytes >= w * 4) {
        size_t byteCount = (size_t)row_bytes * (size_t)h;
        CFDataRef cfData = CFDataCreate(kCFAllocatorDefault,
                                        (const UInt8*)bgra, byteCount);
        if (cfData) {
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(cfData);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            if (provider && cs) {
                CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst |
                                    kCGBitmapByteOrder32Little;
                CGImageRef cg = CGImageCreate((size_t)w, (size_t)h, 8, 32,
                                              (size_t)row_bytes, cs, info,
                                              provider, NULL, false,
                                              kCGRenderingIntentDefault);
                if (cg) {
                    img = [[NSImage alloc] initWithCGImage:cg size:size];
                    CGImageRelease(cg);
                }
            }
            if (cs) CGColorSpaceRelease(cs);
            if (provider) CGDataProviderRelease(provider);
            CFRelease(cfData);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(img);
    });
}

- (void)captureThumbWithSize:(NSSize)size
                  completion:(void (^)(NSImage* _Nullable))completion {
    if (!completion) return;
    if (!_webContents || size.width <= 0 || size.height <= 0) {
        completion(nil);
        return;
    }
    SnapshotCtx* sc = (SnapshotCtx*)calloc(1, sizeof(SnapshotCtx));
    if (!sc) {
        completion(nil);
        return;
    }
    sc->completion = [completion copy];
    sc->size = size;
    SephriumWebContentsCaptureSnapshot(_webContents,
                                      (int)size.width, (int)size.height,
                                      CAL_SnapshotCallback, sc);
}

- (void)openDevTools {
    // TODO(phase 2): wire devtools_window via Sephrium C ABI.
}

@end
