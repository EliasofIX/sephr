// Copyright (c) Sephr. All rights reserved.
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CALMediaPlaybackState) {
    CALMediaPlaybackStateStopped,
    CALMediaPlaybackStatePlaying,
    CALMediaPlaybackStatePaused,
};

@interface CALMediaSession : NSObject
@property (nonatomic, copy) NSString* title;
@property (nonatomic, copy, nullable) NSString* artist;
@property (nonatomic, strong, nullable) NSImage* artwork;
@property (nonatomic) CALMediaPlaybackState playbackState;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval currentTime;
@end

@interface CALMedia : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, copy, nullable)
    void (^onMediaChange)(CALMediaSession* _Nullable);
- (void)play;
- (void)pause;
- (void)nextTrack;
- (void)previousTrack;
- (void)seekTo:(NSTimeInterval)time;
@end

NS_ASSUME_NONNULL_END
