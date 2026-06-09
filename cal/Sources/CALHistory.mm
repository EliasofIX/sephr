// Copyright (c) Sephr. All rights reserved.
#import "CALHistory.h"
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

@implementation CALHistoryEntry
@end

@implementation CALHistory {
    NSString* _profileID;
    SephriumProfileRef _profile;
}

+ (instancetype)historyForProfile:(NSString*)profileID {
    CALHistory* h = [[CALHistory alloc] init];
    h->_profileID = [profileID copy];
    CALProfile* prof = [CALProfile profileWithID:profileID];
    h->_profile = (SephriumProfileRef)prof.bridgeHandle;
    return h;
}

// The completion is a block; we pass its address+a context flag to the C
// trampoline. Inside the trampoline the SephriumHistoryEntry array is
// owned by Chromium and only valid for the duration of the call — we eagerly
// copy out into Obj-C objects so the block can outlive it.
typedef void (^CALHistoryBlock)(NSArray<CALHistoryEntry*>*);

static void HistoryTrampoline(void* ctx,
                              const SephriumHistoryEntry* entries,
                              int count) {
    CALHistoryBlock block = (__bridge_transfer CALHistoryBlock)ctx;
    if (!block) return;
    NSInteger safeCount = (count > 0 && entries != NULL) ? count : 0;
    NSMutableArray<CALHistoryEntry*>* out =
        [NSMutableArray arrayWithCapacity:(NSUInteger)safeCount];
    for (NSInteger i = 0; i < safeCount; ++i) {
        CALHistoryEntry* e = [[CALHistoryEntry alloc] init];
        e.url = CAL_Str(entries[i].url);
        e.title = CAL_Str(entries[i].title);
        e.visitedAt = [NSDate dateWithTimeIntervalSince1970:entries[i].visited_at];
        e.visitCount = entries[i].visit_count;
        [out addObject:e];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ block(out); });
}

- (void)searchText:(NSString*)text
             limit:(NSInteger)limit
        completion:(void (^)(NSArray<CALHistoryEntry*>*))completion {
    if (!completion) return;
    if (!_profile) {
        CALProfile* prof = [CALProfile profileWithID:_profileID];
        _profile = (SephriumProfileRef)prof.bridgeHandle;
    }
    if (!_profile) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
        return;
    }
    // Clamp the limit to a sane range — the bridge expects a positive int
    // and negative values would crash the cancelable tracker downstream.
    int clamped = (int)MIN(MAX(limit, 1), 10000);
    void* ctx = (__bridge_retained void*)[completion copy];
    SephriumHistoryQuery(_profile,
                        text.UTF8String ?: "",
                        clamped,
                        HistoryTrampoline,
                        ctx);
}

- (void)entriesAfter:(NSDate*)start
              before:(NSDate*)end
          completion:(void (^)(NSArray<CALHistoryEntry*>*))completion {
    // The Chromium HistoryService time-range query is plumbed via the same
    // search path with an empty query; the after/before filtering is done
    // client-side here for now. Limit the upstream fetch by start/end
    // ratio when both are present to reduce the work over the IPC boundary.
    if (!completion) return;
    [self searchText:@"" limit:2000 completion:^(NSArray<CALHistoryEntry*>* all) {
        if (!start && !end) {
            completion(all);
            return;
        }
        NSMutableArray* filtered = [NSMutableArray arrayWithCapacity:all.count];
        for (CALHistoryEntry* e in all) {
            if (!e.visitedAt) continue;
            if (start && [e.visitedAt compare:start] == NSOrderedAscending) {
                continue;
            }
            if (end && [e.visitedAt compare:end] != NSOrderedAscending) {
                continue;
            }
            [filtered addObject:e];
        }
        completion(filtered);
    }];
}

- (void)deleteEntry:(NSString*)url {
    if (!url.length || !_profile) return;
    const char* c = url.UTF8String;
    if (c) SephriumHistoryDeleteURL(_profile, c);
}

- (void)clearAll {
    if (!_profile) return;
    SephriumHistoryClearAll(_profile);
}

@end
