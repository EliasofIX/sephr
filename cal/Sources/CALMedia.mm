// Copyright (c) Sephr. All rights reserved.
// Phase 1 stub — content::MediaSession C ABI is Phase 2 work.
#import "CALMedia.h"
#import "CALInternal.h"

@implementation CALMediaSession
@end

@implementation CALMedia

+ (instancetype)sharedInstance {
    static CALMedia* s;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[CALMedia alloc] init]; });
    return s;
}

- (void)play                          { /* no-op (Phase 2) */ }
- (void)pause                         { /* no-op (Phase 2) */ }
- (void)nextTrack                     { /* no-op (Phase 2) */ }
- (void)previousTrack                 { /* no-op (Phase 2) */ }
- (void)seekTo:(NSTimeInterval)time   { (void)time; }

@end
