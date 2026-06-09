// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps an Sephrium BrowserContext. Each isolated Space gets its own
/// CALProfile (separate cookies, localStorage, and disk cache). The
/// "default" profile is shared across non-isolated spaces.
@interface CALProfile : NSObject

@property (nonatomic, copy, readonly) NSString* profileID;
@property (nonatomic, copy, readonly) NSString* profilePath;

+ (instancetype)defaultProfile;
+ (instancetype)profileWithID:(NSString*)profileID;
+ (void)deleteProfileWithID:(NSString*)profileID;

- (NSArray*)recentHistoryWithLimit:(NSInteger)limit;
- (void)clearHistory;
- (NSArray*)activeDownloads;

// Boosts — per-host CSS/JS injection.
- (void)injectCSS:(NSString*)css forHost:(NSString*)host;
- (void)injectJS:(NSString*)js  forHost:(NSString*)host;
- (void)removeInjectionsForHost:(NSString*)host;

@end

NS_ASSUME_NONNULL_END
