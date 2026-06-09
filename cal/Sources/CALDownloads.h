// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CALDownloadState) {
    CALDownloadStateInProgress,
    CALDownloadStatePaused,
    CALDownloadStateComplete,
    CALDownloadStateCanceled,
    CALDownloadStateInterrupted,
};

@interface CALDownload : NSObject
@property (nonatomic, copy) NSString* identifier;
@property (nonatomic, copy) NSString* sourceURL;
@property (nonatomic, copy) NSString* targetPath;
@property (nonatomic, copy, nullable) NSString* mimeType;
@property (nonatomic) long long totalBytes;
@property (nonatomic) long long receivedBytes;
@property (nonatomic) CALDownloadState state;
@property (nonatomic) NSDate* startedAt;
@end

@interface CALDownloads : NSObject
+ (instancetype)sharedInstanceForProfile:(NSString*)profileID;
@property (nonatomic, copy, nullable)
    void (^onDownloadsChanged)(NSArray<CALDownload*>* downloads);

- (NSArray<CALDownload*>*)currentDownloads;
- (void)pause:(NSString*)identifier;
- (void)resume:(NSString*)identifier;
- (void)cancel:(NSString*)identifier;
- (void)revealInFinder:(NSString*)identifier;
@end

NS_ASSUME_NONNULL_END
