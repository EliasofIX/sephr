// Copyright (c) Sephr. All rights reserved.
// Phase 4 — wired to SephriumOmniboxQuery / AutocompleteController.
#import "CALOmnibox.h"
#import "CALInternal.h"

static inline NSString* CAL_Str(const char* s) {
    if (!s) return @"";
    NSString* out = [NSString stringWithUTF8String:s];
    if (out) return out;
    NSData* data = [NSData dataWithBytes:s length:strlen(s)];
    out = [[NSString alloc] initWithData:data
                                encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

@implementation CALOmniboxResult
@end

@implementation CALOmnibox {
    NSString* _profileID;
    SephriumProfileRef _profile;
}

+ (instancetype)omniboxForProfile:(NSString*)profileID {
    CALOmnibox* o = [[CALOmnibox alloc] init];
    o->_profileID = [profileID copy];
    CALProfile* prof = [CALProfile profileWithID:profileID];
    o->_profile = (SephriumProfileRef)prof.bridgeHandle;
    return o;
}

typedef void (^CALOmniboxBlock)(NSArray<CALOmniboxResult*>*);

static void OmniboxTrampoline(void* ctx,
                              const SephriumOmniboxResult* results,
                              int count) {
    // __bridge_transfer consumes the retained ctx. Even on a zero-count
    // callback (Phase 4 short-circuit) the block must run once so the
    // caller's completion is invoked exactly once.
    CALOmniboxBlock block = (__bridge_transfer CALOmniboxBlock)ctx;
    if (!block) return;
    NSInteger safeCount = (count > 0 && results != NULL) ? count : 0;
    NSMutableArray<CALOmniboxResult*>* out =
        [NSMutableArray arrayWithCapacity:(NSUInteger)safeCount];
    for (NSInteger i = 0; i < safeCount; ++i) {
        CALOmniboxResult* r = [[CALOmniboxResult alloc] init];
        r.type = CAL_Str(results[i].type);
        r.text = CAL_Str(results[i].contents);
        // resultDescription is optional in the API — keep nil when the
        // C bridge gives us an empty/null description so the SwiftUI
        // side can layout-skip the second line.
        r.resultDescription =
            (results[i].description && *results[i].description)
                ? CAL_Str(results[i].description)
                : nil;
        r.url  = CAL_Str(results[i].destination_url);
        [out addObject:r];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ block(out); });
}

- (void)queryText:(NSString*)text
       completion:(void (^)(NSArray<CALOmniboxResult*>*))completion {
    if (!completion) return;
    if (!_profile) {
        // Engine not booted yet — try once to lazy-resolve via the cached
        // CALProfile, otherwise return an empty result rather than calling
        // into a null handle.
        CALProfile* prof = [CALProfile profileWithID:_profileID];
        _profile = (SephriumProfileRef)prof.bridgeHandle;
    }
    if (!_profile) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
        return;
    }
    void* ctx = (__bridge_retained void*)[completion copy];
    SephriumOmniboxQuery(_profile, text.UTF8String ?: "",
                        OmniboxTrampoline, ctx);
}

- (NSString*)defaultSearchURLForQuery:(NSString*)query {
    if (!query.length) return @"";
    NSString* escaped = [query stringByAddingPercentEncodingWithAllowedCharacters:
                            [NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
    return [@"https://duckduckgo.com/?q=" stringByAppendingString:escaped];
}

@end
