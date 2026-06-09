// Copyright (c) Sephr. All rights reserved.
#import "CALDownloads.h"
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

@implementation CALDownload
@end

@implementation CALDownloads {
    NSString* _profileID;
    SephriumProfileRef _profile;
    NSMutableArray<CALDownload*>* _downloads;
}

static NSMutableDictionary<NSString*, CALDownloads*>* sInstances;
static dispatch_once_t sInstancesOnce;

static void CAL_EnsureInstances(void) {
    dispatch_once(&sInstancesOnce, ^{
        sInstances = [NSMutableDictionary dictionary];
    });
}

+ (instancetype)sharedInstanceForProfile:(NSString*)profileID {
    if (!profileID.length) profileID = @"default";
    CAL_EnsureInstances();
    @synchronized (sInstances) {
        CALDownloads* d = sInstances[profileID];
        if (d) return d;
        d = [[CALDownloads alloc] init];
        d->_profileID = [profileID copy];
        d->_downloads = [NSMutableArray array];
        CALProfile* prof = [CALProfile profileWithID:profileID];
        d->_profile = (SephriumProfileRef)prof.bridgeHandle;
        sInstances[profileID] = d;
        if (d->_profile) {
            [d subscribe];
        }
        // If the bridge handle is NULL (engine not booted yet), the cached
        // instance will subscribe lazily the first time the bridge becomes
        // available — see -currentDownloads / -subscribeIfNeeded.
        return d;
    }
}

static int MapStateToCAL(int s) {
    switch (s) {
        case 0: return CALDownloadStateInProgress;
        case 1: return CALDownloadStateComplete;
        case 2: return CALDownloadStateCanceled;
        case 3: return CALDownloadStateInterrupted;
        case 4: return CALDownloadStatePaused;
        default: return CALDownloadStateInProgress;
    }
}

static void DownloadsTrampoline(void* ctx,
                                const SephriumDownloadEntry* entries,
                                int count) {
    if (!ctx) return;
    CALDownloads* self_ = (__bridge CALDownloads*)ctx;
    NSInteger safeCount = (count > 0 && entries != NULL) ? count : 0;
    NSMutableArray<CALDownload*>* snap =
        [NSMutableArray arrayWithCapacity:(NSUInteger)safeCount];
    for (NSInteger i = 0; i < safeCount; ++i) {
        CALDownload* d = [[CALDownload alloc] init];
        d.identifier = CAL_Str(entries[i].identifier);
        d.sourceURL  = CAL_Str(entries[i].url);
        d.targetPath = CAL_Str(entries[i].target_path);
        d.mimeType   = CAL_Str(entries[i].mime_type);
        d.totalBytes = entries[i].total_bytes;
        d.receivedBytes = entries[i].received_bytes;
        d.state = (CALDownloadState)MapStateToCAL(entries[i].state);
        [snap addObject:d];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self_) {
            [self_ replaceDownloads:snap];
        }
        if (self_.onDownloadsChanged) self_.onDownloadsChanged(snap);
    });
}

- (void)subscribe {
    if (!_profile) return;
    SephriumDownloadsSubscribe(_profile, DownloadsTrampoline,
                              (__bridge void*)self);
}

- (void)subscribeIfNeeded {
    if (_profile) return;
    CALProfile* prof = [CALProfile profileWithID:_profileID];
    _profile = (SephriumProfileRef)prof.bridgeHandle;
    if (_profile) [self subscribe];
}

- (void)replaceDownloads:(NSArray<CALDownload*>*)snap {
    [_downloads removeAllObjects];
    if (snap.count) [_downloads addObjectsFromArray:snap];
}

- (NSArray<CALDownload*>*)currentDownloads {
    [self subscribeIfNeeded];
    @synchronized (self) { return [_downloads copy]; }
}

- (void)pause:(NSString*)identifier  {
    if (!identifier.length || !_profile) return;
    const char* c = identifier.UTF8String;
    if (c) SephriumDownloadPause(_profile, c);
}
- (void)resume:(NSString*)identifier {
    if (!identifier.length || !_profile) return;
    const char* c = identifier.UTF8String;
    if (c) SephriumDownloadResume(_profile, c);
}
- (void)cancel:(NSString*)identifier {
    if (!identifier.length || !_profile) return;
    const char* c = identifier.UTF8String;
    if (c) SephriumDownloadCancel(_profile, c);
}

- (void)revealInFinder:(NSString*)identifier {
    if (!identifier.length) return;
    NSString* targetPath = nil;
    @synchronized (self) {
        for (CALDownload* d in _downloads) {
            if ([d.identifier isEqualToString:identifier]) {
                targetPath = [d.targetPath copy];
                break;
            }
        }
    }
    if (targetPath.length) {
        [[NSWorkspace sharedWorkspace] selectFile:targetPath
                         inFileViewerRootedAtPath:@""];
    }
}

@end
