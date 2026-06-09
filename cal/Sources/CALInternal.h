// Copyright (c) Sephr. All rights reserved.
// Internal ObjC++ header — single bridge import for CAL implementation files.
// Never expose this file to Swift targets.

#pragma once

#import "cal_bridge.h"

#ifdef __OBJC__
#import "CALProfile.h"

// Internal-only accessor — the SephriumProfileRef CAL.mm files pass to
// SephriumWebContentsCreate. Kept off the public CALProfile.h so the Swift
// surface stays opaque-handle-free.
@interface CALProfile (CALInternal)
@property (nonatomic, readonly) void* bridgeHandle;
@end
#endif
