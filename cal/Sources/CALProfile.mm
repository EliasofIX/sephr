// Copyright (c) Sephr. All rights reserved.
#import "CALProfile.h"
#import "CALInternal.h"

// Resolve `~/Library/Application Support/Sephr/Profiles/<id>` defensively.
// In a sandboxed bundle NSSearchPathForDirectoriesInDomains can return
// an empty array — passing nil into +pathWithComponents: would crash.
// Falls back to ~/Library/Application Support if the search returns nothing.
static NSString* CAL_ResolveProfilePath(NSString* profileID) {
    NSArray<NSString*>* roots = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* support = roots.firstObject;
    if (!support.length) {
        NSString* home = NSHomeDirectory() ?: @"/tmp";
        support = [home stringByAppendingPathComponent:
                            @"Library/Application Support"];
    }
    NSString* base = [support stringByAppendingPathComponent:@"Sephr"];
    base = [base stringByAppendingPathComponent:@"Profiles"];
    if (profileID.length) {
        base = [base stringByAppendingPathComponent:profileID];
    }
    return base;
}

@implementation CALProfile {
    NSString* _profileID;
    NSString* _profilePath;
    SephriumProfileRef _profileRef;
    NSMutableDictionary<NSString*, NSString*>* _cssInjections;  // host -> css
    NSMutableDictionary<NSString*, NSString*>* _jsInjections;   // host -> js
}

static NSMutableDictionary<NSString*, CALProfile*>* sProfiles;
static dispatch_once_t sProfilesOnce;

static void CAL_EnsureRegistry(void) {
    dispatch_once(&sProfilesOnce, ^{
        sProfiles = [NSMutableDictionary dictionary];
    });
}

// We deliberately avoid +initialize here. +initialize is auto-fired by the
// Obj-C runtime on first class-method dispatch, which during early process
// startup can re-enter through unexpected paths (e.g. the framework loader
// or any +[CALProfile someClassMethod] call inside another +initialize).
// dispatch_once is explicit and reentrancy-safe.

+ (instancetype)defaultProfile {
    return [self profileWithID:@"default"];
}

+ (instancetype)profileWithID:(NSString*)profileID {
    if (!profileID.length) profileID = @"default";
    CAL_EnsureRegistry();
    @synchronized (sProfiles) {
        CALProfile* existing = sProfiles[profileID];
        if (existing) return existing;
        CALProfile* p = [[CALProfile alloc] init];
        p->_profileID = [profileID copy];
        p->_profilePath = CAL_ResolveProfilePath(profileID);
        p->_cssInjections = [NSMutableDictionary dictionary];
        p->_jsInjections  = [NSMutableDictionary dictionary];
        [[NSFileManager defaultManager] createDirectoryAtPath:p->_profilePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        // SephriumProfileGet returns NULL until g_browser_process /
        // ProfileManager is initialised (i.e. before PostBrowserStart fires).
        // We still cache the CALProfile so Swift call-sites that ask for it
        // early get the same instance later; the bridge handle gets filled in
        // on the next call after the engine is up.
        const char* idC = profileID.UTF8String;
        const char* pathC = p->_profilePath.UTF8String;
        if (idC && pathC) {
            p->_profileRef = SephriumProfileGet(idC, pathC);
        }
        sProfiles[profileID] = p;
        return p;
    }
}

+ (void)deleteProfileWithID:(NSString*)profileID {
    if (!profileID.length) return;
    CAL_EnsureRegistry();
    CALProfile* p = nil;
    @synchronized (sProfiles) {
        p = sProfiles[profileID];
        [sProfiles removeObjectForKey:profileID];
    }
    if (!p) return;
    if (p->_profileRef) {
        SephriumProfileRelease(p->_profileRef);
        p->_profileRef = NULL;
    }
    if (p.profilePath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:p.profilePath
                                                   error:nil];
    }
}

- (NSString*)profileID   { return _profileID; }
- (NSString*)profilePath { return _profilePath; }
- (void*)bridgeHandle {
    // Lazy refresh: if a CALProfile was created before the engine was up,
    // its bridge handle is NULL. Try once more on every access so the
    // first WebContents create after bootstrap succeeds.
    if (!_profileRef && _profileID.length && _profilePath.length) {
        const char* idC = _profileID.UTF8String;
        const char* pathC = _profilePath.UTF8String;
        if (idC && pathC) {
            _profileRef = SephriumProfileGet(idC, pathC);
        }
    }
    return _profileRef;
}

- (NSArray*)recentHistoryWithLimit:(NSInteger)limit {
    // Wired via CALHistory; stub returns empty until HistoryService is bound.
    return @[];
}

- (void)clearHistory        { /* HistoryService::ClearAllHistory via bridge */ }
- (NSArray*)activeDownloads { return @[]; }

- (void)injectCSS:(NSString*)css forHost:(NSString*)host {
    if (!css.length || !host.length) return;
    _cssInjections[host] = css;
    // Propagated to renderers on next navigation via
    // content::RenderFrameHost::InsertStylesheet (Phase 2).
}

- (void)injectJS:(NSString*)js forHost:(NSString*)host {
    if (!js.length || !host.length) return;
    _jsInjections[host] = js;
}

- (void)removeInjectionsForHost:(NSString*)host {
    if (!host.length) return;
    [_cssInjections removeObjectForKey:host];
    [_jsInjections  removeObjectForKey:host];
}

@end
