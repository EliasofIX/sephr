// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CALTabInfo : NSObject
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString* url;
@property (nonatomic, copy) NSString* title;
@property (nonatomic) BOOL isActive;
@property (nonatomic) BOOL isPinned;
@end

typedef void (^CALTabStripChangeCallback)(NSArray<CALTabInfo*>* tabs);

/// Thin Objective-C wrapper around sephr::cal::CALTabStripBridge.
/// Owns one TabStripModel's lifetime for the containing window.
@interface CALTabStrip : NSObject
+ (instancetype)tabStripForProfile:(NSString*)profileID;

- (void)activateTab:(NSInteger)index;
- (void)closeTab:(NSInteger)index;
- (void)moveTabFrom:(NSInteger)fromIndex to:(NSInteger)toIndex;
- (void)pinTab:(NSInteger)index pinned:(BOOL)pinned;
- (NSInteger)addNewTabWithURL:(NSString*)url;

@property (nonatomic, readonly) NSInteger count;
@property (nonatomic, readonly) NSInteger activeIndex;
@property (nonatomic, copy, nullable) CALTabStripChangeCallback onChange;
@end

NS_ASSUME_NONNULL_END
