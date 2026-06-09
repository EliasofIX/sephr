// Copyright (c) Sephr. All rights reserved.
#import "CALThumbnails.h"
#import "CALWebView.h"

@implementation CALThumbnails
+ (void)captureFromWebView:(CALWebView*)webView
                      size:(NSSize)size
                completion:(void (^)(NSImage* _Nullable))completion {
    if (!completion) return;  // fire-and-forget callers
    if (!webView || size.width <= 0 || size.height <= 0) {
        completion(nil);
        return;
    }
    [webView captureThumbWithSize:size completion:completion];
}
@end
