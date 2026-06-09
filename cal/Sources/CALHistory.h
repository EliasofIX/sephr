// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CALHistoryEntry : NSObject
@property (nonatomic, copy) NSString* url;
@property (nonatomic, copy) NSString* title;
@property (nonatomic, strong) NSDate* visitedAt;
@property (nonatomic) NSInteger visitCount;
@end

@interface CALHistory : NSObject
+ (instancetype)historyForProfile:(NSString*)profileID;

- (void)searchText:(NSString*)text
             limit:(NSInteger)limit
        completion:(void (^)(NSArray<CALHistoryEntry*>*))completion;

- (void)entriesAfter:(NSDate*)start
              before:(NSDate*)end
          completion:(void (^)(NSArray<CALHistoryEntry*>*))completion;

- (void)deleteEntry:(NSString*)url;
- (void)clearAll;
@end

NS_ASSUME_NONNULL_END
