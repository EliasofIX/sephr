// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Boots the Sephrium content process and installs CAL's
/// content::ContentMainDelegate.
///
/// Phase 2 Option A — Chromium owns the main run loop. `initialize` is a
/// thin forwarder to `ChromeMain` and NEVER RETURNS until shutdown. The
/// embedder must register its UI bring-up via `setUiBootCallback:` BEFORE
/// calling `initialize`; the closure fires from `PostBrowserStart`, on
/// the UI thread, once `g_browser_process` and the initial profile are
/// ready.
@interface CALEngineBootstrap : NSObject
/// Boots Chromium. NEVER call this method `initialize` — the Objective-C
/// runtime auto-fires `+initialize` on first class-method dispatch, which
/// would invoke `ChromeMain` before any other `CALEngineBootstrap` call
/// (including `setUiBootCallback:`) and leave the embedder unable to
/// register its UI bring-up.
+ (void)bootChromium;

/// Pass `nil` to clear. Calling this AFTER `bootChromium` is harmless but
/// the callback won't fire until the next process launch.
+ (void)setUiBootCallback:(nullable void (^)(void))callback;

/// Registers the handler invoked when the OS asks Sephr (as the system
/// default browser) to open a URL — a link from another app, a Handoff
/// hand-off, or the URL that cold-launched the app. The block receives the
/// URL string and runs on the main thread; the embedder turns it into a
/// real Sephr tab. URLs that arrived before this is registered (the
/// cold-launch race) are buffered Chromium-side and replayed in order the
/// moment you register. Pass `nil` to clear. Register from the UI-boot
/// callback, once the tab UI exists.
+ (void)setOpenExternalURLCallback:(nullable void (^)(NSString* url))callback;

+ (void)pumpOnce;
@end

NS_ASSUME_NONNULL_END
