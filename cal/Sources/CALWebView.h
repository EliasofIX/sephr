// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CALWebView;

typedef void (^CALNavigationCallback)(NSString* url, NSString* title);
typedef void (^CALLoadingCallback)(BOOL isLoading, double progress);
typedef void (^CALFaviconCallback)(NSImage* _Nullable favicon);
typedef void (^CALNewTabRequestCallback)(NSString* url);
// `url` is the destination of the link currently under the pointer, or nil
// when the cursor isn't over a link. Drives the Shift+hover link-peek.
typedef void (^CALTargetURLCallback)(NSString* _Nullable url);
// The page opened a popup via window.open(...) with popup window features —
// the shape OAuth/SSO sign-in uses (e.g. claude.ai's "Continue with
// Google"). `popup` is a live CALWebView wrapping the popup's WebContents
// with its opener relationship intact, so the popup's
// window.opener.postMessage(...) reaches this view's page. The receiver MUST
// retain and host it (Sephr shows it in a peek overlay); if it's dropped the
// popup is torn down and the sign-in can't complete.
typedef void (^CALPopupRequestCallback)(CALWebView* popup);
// The page called window.close() on this view's window. Chromium only
// delivers this for script-closable windows, so for an OAuth popup it's the
// self-close after the result was posted home. The host should dismiss
// whatever is showing this view (Sephr dismisses the peek).
typedef void (^CALCloseRequestCallback)(void);

@interface CALWebView : NSView

+ (instancetype)webViewWithURL:(NSURL*)url profile:(NSString*)profileID;

// Navigation
- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;

// State
@property (nonatomic, readonly) NSString* currentURL;
@property (nonatomic, readonly) NSString* currentTitle;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isLoading;
// YES while sleeping (WebContents destroyed, view + tab identity intact).
@property (nonatomic, readonly) BOOL isAsleep;
// YES if the page is currently playing audio (never YES while asleep).
@property (nonatomic, readonly) BOOL isAudible;

// Callbacks (dispatched on the main thread)
@property (nonatomic, copy, nullable) CALNavigationCallback onNavigation;
@property (nonatomic, copy, nullable) CALLoadingCallback   onLoading;
@property (nonatomic, copy, nullable) CALFaviconCallback   onFavicon;
@property (nonatomic, copy, nullable) CALNewTabRequestCallback onNewTabRequest;
@property (nonatomic, copy, nullable) CALTargetURLCallback onTargetURLChange;
@property (nonatomic, copy, nullable) CALPopupRequestCallback onPopupRequest;
@property (nonatomic, copy, nullable) CALCloseRequestCallback onCloseRequest;

// Lifecycle
- (void)focus;
- (void)blur;
- (void)freeze;
- (void)unfreeze;
// Tab sleeping: sleep destroys the WebContents (renderer process and
// memory released) but keeps this view and its sidebar/tab-model identity;
// wake recreates the contents at the last committed URL and re-attaches if
// the view is in a window. Both are idempotent no-ops when already in the
// requested state.
- (void)sleep;
- (void)wake;

// Thumbnail capture (async; completion runs on main)
- (void)captureThumbWithSize:(NSSize)size
                  completion:(void (^)(NSImage* _Nullable))completion;

// Debug only
- (void)openDevTools;

@end

NS_ASSUME_NONNULL_END
