#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface DNVOTClient : NSObject
@property(nonatomic,copy) void (^status)(NSString *);
@property(nonatomic,copy) void (^audioReady)(NSURL *, BOOL partial);
@property(nonatomic,copy) void (^failed)(NSString *);
- (void)startVideo:(NSString *)videoID duration:(double)duration from:(NSString *)from to:(NSString *)to sourceAudio:(NSURL *)audioURL itag:(NSInteger)itag;
- (void)cancel;
@end

@interface DNVOTController : NSObject
+ (instancetype)shared;
@property(nonatomic,weak) id player;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,copy) NSString *videoID;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL working;
@property(nonatomic) float originalLevel;
@property(nonatomic) float translationLevel;
@property(nonatomic) double offset;
@property(nonatomic,copy) NSString *fromLanguage;
@property(nonatomic,copy) NSString *toLanguage;
@property(nonatomic) BOOL autoTranslate;
- (void)observePlayer:(id)player;
- (void)playerPaused:(id)player;
- (void)playerResumed:(id)player;
- (float)incomingVolume:(float)volume player:(id)player;
- (void)start;
- (void)stop;
- (void)tick;
- (void)saveSettings;
- (void)showPanel;
- (NSString *)diagnostics;
@end

void DNVOTInstallHooks(void);
