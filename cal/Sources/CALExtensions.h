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
/// is queued; the result surfaces via `onExtensionsChanged` when the
/// extension loads (or is silently dropped if the package is invalid).
- (BOOL)installCRXAtPath:(NSString*)path error:(NSError**)error;
- (void)uninstall:(NSString*)extensionID;
- (void)setEnabled:(NSString*)extensionID enabled:(BOOL)enabled;
@property (nonatomic, copy, nullable) void (^onExtensionsChanged)(void);
@end

NS_ASSUME_NONNULL_END
