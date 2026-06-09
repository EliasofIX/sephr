// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CALOmniboxResult : NSObject
@property (nonatomic, copy) NSString* type;  // "url" "search" "history" "bookmark"
@property (nonatomic, copy) NSString* text;
@property (nonatomic, copy) NSString* url;
@property (nonatomic, copy, nullable) NSString* resultDescription;
@property (nonatomic, strong, nullable) NSImage* favicon;
@end

@interface CALOmnibox : NSObject
+ (instancetype)omniboxForProfile:(NSString*)profileID;
- (void)queryText:(NSString*)text
       completion:(void (^)(NSArray<CALOmniboxResult*>*))completion;
- (NSString*)defaultSearchURLForQuery:(NSString*)query;
@end

NS_ASSUME_NONNULL_END
