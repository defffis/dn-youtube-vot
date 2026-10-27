#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface DNVOTClient : NSObject
@property(nonatomic,copy) void (^status)(NSString *);
@property(nonatomic,copy) void (^audioReady)(NSURL *, BOOL partial);
@property(nonatomic,copy) void (^failed)(NSString *);
@property(nonatomic,readonly) double serverRemainingTime; // -1 when no usable estimate
- (void)startVideo:(NSString *)videoID duration:(double)duration from:(NSString *)from to:(NSString *)to sourceAudio:(NSURL *)audioURL itag:(NSInteger)itag;
- (void)cancel;
- (NSString *)diagnostics;
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
@property(nonatomic,copy) NSSet<NSString *> *excludedLanguages;
- (void)observePlayer:(id)player;
- (void)playerPaused:(id)player;
- (void)playerResumed:(id)player;
- (float)incomingVolume:(float)volume player:(id)player;
- (void)start;
- (void)stop;
- (void)tick;
- (void)saveSettings;
- (void)autoSettingsChanged;
- (void)clearCache;
- (unsigned long long)cacheBytes;
- (void)resetSettings;
- (void)showPanel;
- (void)showPanelFrom:(UIViewController *)presenter;
- (void)toggleTranslation;
- (void)updateControlsButton:(UIButton *)button;
- (NSString *)diagnostics;
@end

void DNVOTInstallHooks(void);
NSString *DNVOTBootstrapDiagnostics(void);
BOOL DNVOTHook(Class cls, NSString *name, char result, const char *args, id (^factory)(IMP, SEL));
void DNVOTInstallNativeUI(void);
void DNVOTUpdateNativeButtons(void);
NSString *DNVOTNativeDiagnostics(void);
NSString *DNVOTPlayerIdentifier(id object);
NSString *DNVOTUnsupportedPlayerContext(id player);
