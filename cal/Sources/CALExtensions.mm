// Copyright (c) Sephr. All rights reserved.
#import "CALExtensions.h"
#import "CALInternal.h"

static inline NSString* CAL_ExtStr(const char* s) {
    if (!s) return @"";
    NSString* out = [NSString stringWithUTF8String:s];
    if (out) return out;
    NSData* data = [NSData dataWithBytes:s length:strlen(s)];
    out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

@implementation CALExtension
@end

@implementation CALExtensions {
    NSString* _profileID;
    SephriumProfileRef _profile;
    NSMutableArray<CALExtension*>* _extensions;
}

static NSMutableDictionary<NSString*, CALExtensions*>* sInstances;
static dispatch_once_t sInstancesOnce;

// dispatch_once over +initialize — see project memory: +initialize side
// effects in the multi-init bootstrap path bit us once already.
+ (instancetype)sharedInstanceForProfile:(NSString*)profileID {
    if (!profileID.length) profileID = @"default";
    dispatch_once(&sInstancesOnce, ^{
        sInstances = [NSMutableDictionary dictionary];
    });
    @synchronized (sInstances) {
        CALExtensions* e = sInstances[profileID];
        if (e) return e;
        e = [[CALExtensions alloc] init];
        e->_profileID  = [profileID copy];
        e->_extensions = [NSMutableArray array];
        CALProfile* prof = [CALProfile profileWithID:profileID];
        e->_profile = (SephriumProfileRef)prof.bridgeHandle;
        sInstances[profileID] = e;
        if (e->_profile) [e subscribe];
        // If the bridge handle is NULL (engine not booted yet) we subscribe
        // lazily the first time -installed is read — see -subscribeIfNeeded.
        return e;
    }
}

static void ExtensionsTrampoline(void* ctx,
                                 const SephriumExtensionEntry* entries,
                                 int count) {
    if (!ctx) return;
    CALExtensions* self_ = (__bridge CALExtensions*)ctx;
    NSInteger safe = (count > 0 && entries != NULL) ? count : 0;
    NSMutableArray<CALExtension*>* snap =
        [NSMutableArray arrayWithCapacity:(NSUInteger)safe];
    for (NSInteger i = 0; i < safe; ++i) {
        CALExtension* x = [[CALExtension alloc] init];
        x.extensionID = CAL_ExtStr(entries[i].identifier);
        x.name        = CAL_ExtStr(entries[i].name);
        x.version     = CAL_ExtStr(entries[i].version);
        x.isEnabled   = entries[i].enabled != 0;
        [snap addObject:x];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self_) {
            [self_->_extensions removeAllObjects];
            if (snap.count) [self_->_extensions addObjectsFromArray:snap];
        }
        if (self_.onExtensionsChanged) self_.onExtensionsChanged();
    });
}

- (void)subscribe {
    if (!_profile) return;
    SephriumExtensionsSubscribe(_profile, ExtensionsTrampoline,
                                (__bridge void*)self);
}

- (void)subscribeIfNeeded {
    if (_profile) return;
    CALProfile* prof = [CALProfile profileWithID:_profileID];
    _profile = (SephriumProfileRef)prof.bridgeHandle;
    if (_profile) [self subscribe];
}

- (NSArray<CALExtension*>*)installed {
    [self subscribeIfNeeded];
    @synchronized (self) { return [_extensions copy]; }
}

- (BOOL)installCRXAtPath:(NSString*)path error:(NSError**)error {
    if (!path.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"CALExtensionsErrorDomain"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"No file path"
            }];
        }
        return NO;
    }
    [self subscribeIfNeeded];
    if (!_profile) {
        if (error) {
            *error = [NSError errorWithDomain:@"CALExtensionsErrorDomain"
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Browser engine not ready yet"
            }];
        }
        return NO;
    }
    const char* c = path.UTF8String;
    if (c) SephriumExtensionsInstallCRX(_profile, c);
    return YES;
}

- (void)uninstall:(NSString*)extensionID {
    if (!extensionID.length || !_profile) return;
    const char* c = extensionID.UTF8String;
    if (c) SephriumExtensionsUninstall(_profile, c);
}

- (void)setEnabled:(NSString*)extensionID enabled:(BOOL)enabled {
    if (!extensionID.length || !_profile) return;
    const char* c = extensionID.UTF8String;
    if (c) SephriumExtensionsSetEnabled(_profile, c, enabled ? 1 : 0);
}

@end
