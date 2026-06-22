// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CALExtension : NSObject
@property (nonatomic, copy) NSString* extensionID;
@property (nonatomic, copy) NSString* name;
@property (nonatomic, copy) NSString* version;
@property (nonatomic) BOOL isEnabled;
@property (nonatomic, strong, nullable) NSImage* icon;
@end

@interface CALExtensions : NSObject
+ (instancetype)sharedInstanceForProfile:(NSString*)profileID;
- (NSArray<CALExtension*>*)installed;
/// Installs a local CRX3 package. Asynchronous: returns YES once the install
/// is queued; the result surfaces via a registered change observer when the
/// extension loads (or is silently dropped if the package is invalid).
- (BOOL)installCRXAtPath:(NSString*)path error:(NSError**)error;
- (void)uninstall:(NSString*)extensionID;
- (void)setEnabled:(NSString*)extensionID enabled:(BOOL)enabled;

/// Register a change observer. Returns an opaque token; pass it to
/// -removeChangeObserver: to stop receiving callbacks. ALL registered
/// observers fire (on the main thread) whenever the installed set changes.
///
/// This replaces the old single-assignment `onExtensionsChanged` block: that
/// property was silently clobbered when more than one component (e.g. the
/// Settings extensions pane AND a sidebar page-settings panel) shared the same
/// profile-scoped instance, so only the last subscriber received live updates.
- (id)addChangeObserver:(void (^)(void))block;
- (void)removeChangeObserver:(nullable id)token;
@end

NS_ASSUME_NONNULL_END
