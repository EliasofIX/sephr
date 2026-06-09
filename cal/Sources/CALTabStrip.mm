// Copyright (c) Sephr. All rights reserved.
// Phase 1 stub — CAL bridge for TabStrip is deferred to Phase 2 (the C ABI
// surface for TabStripModel/AutocompleteController/MediaSession isn't in
// chrome/sephr/cal_bridge/cal_bridge.h yet). The ObjC API still exists so
// callers in Sephr keep compiling; methods no-op or return empty values.
#import "CALTabStrip.h"
#import "CALInternal.h"

@implementation CALTabInfo
@end

@implementation CALTabStrip {
    NSString* _profileID;
}

+ (instancetype)tabStripForProfile:(NSString*)profileID {
    CALTabStrip* s = [[CALTabStrip alloc] init];
    s->_profileID = [profileID copy];
    return s;
}

- (void)activateTab:(NSInteger)i              { (void)i; }
- (void)closeTab:(NSInteger)i                 { (void)i; }
- (void)moveTabFrom:(NSInteger)f to:(NSInteger)t { (void)f; (void)t; }
- (void)pinTab:(NSInteger)i pinned:(BOOL)p    { (void)i; (void)p; }
- (NSInteger)addNewTabWithURL:(NSString*)u    { (void)u; return -1; }
- (NSInteger)count                            { return 0; }
- (NSInteger)activeIndex                      { return -1; }
@end
