// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CALWebView;

/// Asynchronous, throttled page thumbnail capture.
@interface CALThumbnails : NSObject
+ (void)captureFromWebView:(CALWebView*)webView
                      size:(NSSize)size
                completion:(void (^)(NSImage* _Nullable))completion;
@end

NS_ASSUME_NONNULL_END
