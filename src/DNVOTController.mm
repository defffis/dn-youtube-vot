#import "DNVOT.h"
#import "Runtime.hpp"
#import "Preferences.h"
#import "FlightRecorder.h"
#import "LocalAudio.h"
#include "SyncPolicy.hpp"
#include "ControlState.hpp"
#include "PlaybackClock.hpp"
#include "LocalTransport.hpp"
#include <algorithm>

static NSString *const DNSettings = @"DNVoiceTranslation.v1";
static NSString *const DNUpdate = @"DNVoiceTranslationUpdated";
@interface DNVOTPanel : UIViewController
@end

@interface DNVOTController () <AVAudioPlayerDelegate>
@property(nonatomic,strong) DNVOTClient *client;
@property(nonatomic,strong) AVAudioPlayer *audio;
@property(nonatomic,strong) DNLocalAudioDownload *download;
@property(nonatomic,strong) NSURL *audioFile;
@property(nonatomic) int64_t downloadedBytes;
@property(nonatomic) int64_t expectedBytes;
@property(nonatomic) NSUInteger seekCommands;
@property(nonatomic) BOOL lastPlaySucceeded;
@property(nonatomic) double lastPlayAttempt;
@property(nonatomic) double lastAudioTime;
@property(nonatomic) double audioAdvanceAt;
@property(nonatomic,copy) NSString *audioError;
@property(nonatomic) NSTimeInterval requestStarted;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSCache<NSString *, NSURL *> *cache;
@property(nonatomic,copy) NSString *activeKey;
@property(nonatomic) BOOL settingVolume;
@property(nonatomic) BOOL ducking;
@property(nonatomic) float savedVolume;
@property(nonatomic) BOOL capturedVolume;
@property(nonatomic) BOOL seeking;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL partial;
@property(nonatomic) NSUInteger tickCount;
@property(nonatomic,copy) NSString *playbackGate;
@property(nonatomic) BOOL volumeApplied;
@property(nonatomic) NSUInteger playCommands;
@property(nonatomic) BOOL clockMoving;
@end
@implementation DNVOTController {
    dnvot::PlaybackClock _clock;
}
+ (instancetype)shared {
    static DNVOTController *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [DNVOTController new]; }); return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *settings = [NSUserDefaults.standardUserDefaults dictionaryForKey:DNSettings];
        self.fromLanguage = DNString(settings[@"from"]) ?: @"auto";
        self.toLanguage = DNString(settings[@"to"]) ?: @"ru";
        self.originalLevel = settings[@"original"] ? [settings[@"original"] floatValue] : 0.18f;
        self.translationLevel = settings[@"translated"] ? [settings[@"translated"] floatValue] : 1.0f;
        self.offset = [settings[@"offset"] doubleValue]; self.autoTranslate = [settings[@"auto"] boolValue];
        self.originalLevel = std::clamp(self.originalLevel, 0.0f, 1.0f);
        self.translationLevel = std::clamp(self.translationLevel, 0.0f, 1.0f);
        if (!std::isfinite(self.offset)) self.offset = 0;
        self.offset = std::clamp(self.offset, -5.0, 5.0);
        _clock.reset(); self.playbackGate = @"disabled"; self.statusText = @"Откройте видео и включите перевод";
        self.cache = [NSCache new]; self.cache.countLimit = 20;
        // Remove our abandoned temporary audio after a previous process crash.
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil]) {
            if ([name hasPrefix:@"DNVOT-audio-"] && [name hasSuffix:@".mp3"]) [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] error:nil];
        }
        self.client = [DNVOTClient new];
        __weak DNVOTController *weakSelf = self;
        self.client.status = ^(NSString *status) { DNVOTController *s = weakSelf; if (s.enabled) s.statusText = status; };
        self.client.audioReady = ^(NSURL *url, BOOL partial) {
            DNVOTController *s = weakSelf;
            if (!s.enabled || !s.activeKey.length) return;
            if (!partial) [s.cache setObject:url forKey:s.activeKey];
            [s loadAudio:url partial:partial];
        };
        self.client.failed = ^(NSString *error) {
            DNVOTController *s = weakSelf;
            if (!s.enabled) return;
            [s stop]; s.statusText = error;
        };
        self.timer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(__unused NSTimer *timer) {
            @try { [weakSelf tick]; }
            @catch (NSException *e) {
                NSLog(@"[DNVOT] tick exception: %@", e.reason);
                [weakSelf.audio pause];
                [weakSelf applyDucking:NO];
                weakSelf.enabled = NO;
                weakSelf.statusText = [@"Ошибка адаптера плеера: " stringByAppendingString:e.reason ?: e.name];
            }
        }];
        self.timer.tolerance = 0.03;
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(audioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(audioRouteChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
        for (NSString *name in @[UIApplicationDidEnterBackgroundNotification,UIApplicationWillEnterForegroundNotification,UIApplicationWillResignActiveNotification,UIApplicationDidBecomeActiveNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appLifecycle:) name:name object:nil];
        }
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mediaReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }
    return self;
}
- (void)record:(NSString *)event fields:(NSDictionary *)fields { [DNFlightRecorder.shared event:event fields:fields]; }
- (void)setStatusText:(NSString *)statusText {
    _statusText = [statusText copy];
    [self updateButton];
    [NSNotificationCenter.defaultCenter postNotificationName:DNUpdate object:self];
}
- (void)saveSettings {
    [NSUserDefaults.standardUserDefaults setObject:@{ @"from":self.fromLanguage ?: @"auto", @"to":self.toLanguage ?: @"ru", @"original":@(self.originalLevel), @"translated":@(self.translationLevel), @"offset":@(self.offset), @"auto":@(self.autoTranslate) } forKey:DNSettings];
    if (self.audio) self.audio.volume = self.translationLevel;
    [self applyDucking:self.ducking];
}
- (void)updateButton { DNVOTUpdateNativeButtons(); }
- (void)toggleTranslation { if (self.enabled) [self stop]; else [self start]; }
- (void)updateControlsButton:(UIButton *)button {
    BOOL ready = self.enabled && self.audio != nil;
    BOOL playing = ready && self.audio.playing && self.translationLevel > 0;
    auto state = dnvot::controlState(self.enabled, ready, playing, self.requestStarted, NSProcessInfo.processInfo.systemUptime);
    BOOL waiting = state.phase == dnvot::ControlPhase::waiting;
    NSString *title = nil;
    if (waiting) {
        NSUInteger elapsed = state.elapsed;
        title = [NSString stringWithFormat:@"%lu:%02lu", (unsigned long)(elapsed/60), (unsigned long)(elapsed%60)];
    }
    static UIImage *voiceIcon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ voiceIcon = [[UIImage systemImageNamed:@"waveform" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]; });
    UIImage *icon = waiting ? nil : voiceIcon;
    if (!waiting && !icon) title = @"VOT";
    NSString *oldTitle = [button titleForState:UIControlStateNormal];
    if (oldTitle != title && ![oldTitle isEqualToString:title]) [button setTitle:title forState:UIControlStateNormal];
    if ([button imageForState:UIControlStateNormal] != icon) [button setImage:icon forState:UIControlStateNormal];
    button.tintColor = playing ? UIColor.systemGreenColor : (ready ? UIColor.systemYellowColor : UIColor.whiteColor);
    [button setTitleColor:button.tintColor forState:UIControlStateNormal];
    button.accessibilityLabel = waiting ? @"Отменить подготовку перевода" : (playing ? @"Выключить воспроизводимый перевод" : (ready ? @"Перевод включён, воспроизведение приостановлено. Нажмите для выключения" : @"Включить перевод"));
    button.accessibilityHint = @"Удерживайте для настроек озвучки и громкости";
    button.accessibilityValue = self.statusText;
    button.enabled = self.videoID.length > 0;
    button.hidden = !self.videoID.length;
}
- (NSString *)currentID {
    NSString *videoID = DNString(DNObject(self.player, @"contentVideoID"));
    if (!DNVideoID(videoID) && !DNNumber(self.player, @"isPlayingAd")) videoID = DNString(DNObject(self.player, @"currentVideoID"));
    return DNVideoID(videoID) ? videoID : nil;
}
- (void)observePlayer:(id)player {
    if (!NSThread.isMainThread) {
        __weak id weak = player;
        dispatch_async(dispatch_get_main_queue(), ^{ if (weak) [self observePlayer:weak]; }); return;
    }
    if (![player isKindOfClass:UIViewController.class]) return;
    UIViewController *vc = player;
    if (!vc.isViewLoaded || !vc.view.window) return;
    if (self.player != player) {
        [self stop]; self.player = player; self.videoID = nil;
        _clock.reset();
    }
    [self mountButton];
}
- (void)mountButton { DNVOTUpdateNativeButtons(); }
- (void)playerPaused:(id)player {
    if (self.player != player) return;
    [self record:@"native_pause" fields:@{@"content":@(DNNumber(player,@"contentVideoMediaTime",-1))}];
    _clock.pause(NSProcessInfo.processInfo.systemUptime); self.playbackGate = @"video pause callback"; [self.audio pause]; [self applyDucking:NO];
}
- (void)playerResumed:(id)player { if (self.player == player) { _clock.resume(); self.lastPlayAttempt=-INFINITY; [self record:@"native_resume" fields:@{}]; } }
- (float)incomingVolume:(float)volume player:(id)player {
    if (self.player != player || self.settingVolume || !self.enabled) return volume;
    self.savedVolume = volume; self.capturedVolume = YES;
    return self.ducking ? volume * self.originalLevel : volume;
}
- (void)applyDucking:(BOOL)duck {
    id player = self.player;
    if (!self.capturedVolume && self.enabled && player) {
        self.savedVolume = (float)DNNumber(player, @"volume", 1); self.capturedVolume = YES;
    }
    BOOL wasDucking = self.ducking; self.ducking = duck;
    if (!player || !self.capturedVolume || (!duck && !wasDucking)) return;
    float target = duck ? self.savedVolume * self.originalLevel : self.savedVolume;
    if (fabs(DNNumber(player, @"volume", -1) - target) < 0.001) return;
    self.settingVolume = YES;
    self.volumeApplied = DNSetVolume(player, target);
    self.settingVolume = NO;
}
- (void)stop {
    [self record:@"translation_stop" fields:@{}];
    self.generation++; [self.client cancel]; [self.download cancel]; self.download=nil; [self.audio stop];
    [self applyDucking:NO]; self.audio = nil; self.enabled = NO; self.working = NO;
    if (self.audioFile) [NSFileManager.defaultManager removeItemAtURL:self.audioFile error:nil]; self.audioFile=nil;
    self.capturedVolume = NO; self.seeking = NO; self.activeKey = nil; self.playbackGate = @"disabled";
    self.statusText = @"Перевод выключен";
}
- (NSString *)cacheKey { return [NSString stringWithFormat:@"%@|%@|%@|%@", self.videoID, self.fromLanguage, self.toLanguage, DNVOTPreferences.shared.configurationKey]; }
- (NSURL *)sourceAudioWithItag:(NSInteger *)itag {
    id active = DNObject(self.player, @"activeVideo");
    id format = DNObject(active, @"selectedAudioFormat");
    id raw = DNObject(format, @"URL");
    NSURL *url = [raw isKindOfClass:NSURL.class] ? raw : [NSURL URLWithString:DNString(raw) ?: @""];
    if (url && [url.scheme.lowercaseString isEqual:@"https"] && DNNumber(format, @"DRMFamily", -1) == 0 && [url.host.lowercaseString hasSuffix:@".googlevideo.com"]) {
        *itag = (NSInteger)DNNumber(format, @"itag", 140); return url;
    }
    return nil;
}
- (void)start {
    [self tick];
    NSString *videoID = [self currentID];
    if (!videoID) { self.statusText = @"Сначала откройте обычное видео YouTube"; return; }
    id active = DNObject(self.player, @"activeVideo");
    if (DNNumber(DNObject(active, @"singleVideo"), @"isLivePlayback") || DNNumber(active, @"isPeggedToLive")) {
        self.statusText = @"Прямые эфиры пока не поддерживаются"; return;
    }
    double duration = DNNumber(self.player, @"currentVideoTotalMediaTime");
    if (duration <= 0 || duration > 14400) { self.statusText = @"Длительность видео недоступна или превышает 4 часа"; return; }
    if (![self.fromLanguage isEqualToString:@"auto"] && [self.fromLanguage isEqualToString:self.toLanguage]) {
        self.statusText = @"Выберите разные языки оригинала и перевода"; return;
    }
    [self stop]; self.videoID = videoID; self.enabled = YES; self.working = YES;
    self.requestStarted = NSProcessInfo.processInfo.systemUptime;
    self.playCommands=0;self.seekCommands=0;self.audioError=nil;
    [self record:@"translation_start" fields:@{@"video":videoID,@"source":self.fromLanguage,@"target":self.toLanguage}];
    self.activeKey = [self cacheKey];
    self.savedVolume = (float)DNNumber(self.player, @"volume", 1); self.capturedVolume = YES;
    NSURL *cached = [self.cache objectForKey:self.activeKey];
    if (cached) { [self loadAudio:cached partial:NO]; return; }
    NSInteger itag = 140; NSURL *source = [self sourceAudioWithItag:&itag];
    [self.client startVideo:videoID duration:duration from:self.fromLanguage to:self.toLanguage sourceAudio:source itag:itag];
}
- (void)loadAudio:(NSURL *)url partial:(BOOL)partial {
    self.generation++; self.seeking=NO;self.partial=partial;self.working=YES;
    [self.download cancel];[self.audio stop];[self applyDucking:NO];self.audio=nil;
    if (self.audioFile) [NSFileManager.defaultManager removeItemAtURL:self.audioFile error:nil];self.audioFile=nil;
    self.downloadedBytes=0;self.expectedBytes=0;
    self.playbackGate=@"downloading complete translated file";
    self.statusText=@"Загрузка файла озвучки…";
    NSUInteger generation=self.generation;
    __weak DNVOTController *weakSelf=self;
    DNLocalAudioDownload *download=[DNLocalAudioDownload new];self.download=download;
    download.progress=^(int64_t total,int64_t expected) {
        DNVOTController *s=weakSelf;if (!s || generation!=s.generation) return;
        s.downloadedBytes=total;s.expectedBytes=expected;
    };
    download.completion=^(NSURL *local,NSString *errorText) {
        DNVOTController *s=weakSelf;
        if (!s || generation!=s.generation || !s.enabled) { if (local) [NSFileManager.defaultManager removeItemAtURL:local error:nil];return; }
        s.download=nil;s.working=NO;
        if (!local) { if (s.activeKey) [s.cache removeObjectForKey:s.activeKey];[s stop];s.statusText=errorText ?: @"Не удалось загрузить озвучку";return; }
        s.audioFile=local;
        NSError *error=nil;
        AVAudioPlayer *audio=[[AVAudioPlayer alloc] initWithContentsOfURL:local error:&error];
        audio.enableRate=YES;audio.meteringEnabled=DNFlightRecorder.shared.recording;audio.delegate=s;audio.volume=s.translationLevel;
        BOOL prepared=audio && [audio prepareToPlay];
        [s record:@"audio_prepare" fields:@{@"ok":@(prepared),@"duration":@(audio.duration),@"channels":@(audio.numberOfChannels),@"sample_rate":@(audio.format.sampleRate),@"error_domain":error.domain ?: @"",@"error_code":@(error.code)}];
        if (!prepared) {
            [s stop];s.audioError=[NSString stringWithFormat:@"%@/%ld",error.domain ?: @"prepare",(long)error.code];s.statusText=@"Не удалось декодировать файл озвучки. Экспортируйте лог.";return;
        }
        s.audio=audio;s.lastAudioTime=NAN;s.audioAdvanceAt=0;s.lastPlayAttempt=-INFINITY;
        s.playbackGate=@"local audio ready";s.statusText=@"Озвучка загружена, ожидание воспроизведения видео";
        [s tick];
    };
    [download start:url];
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player!=self.audio) return;
    self.audioError=[NSString stringWithFormat:@"%@/%ld",error.domain ?: @"decode",(long)error.code];
    [self record:@"audio_decode_error" fields:@{@"domain":error.domain ?: @"",@"code":@(error.code)}];
    [self stop];self.statusText=@"Ошибка декодирования озвучки. Экспортируйте лог.";
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player!=self.audio) return;
    [self record:@"audio_finished" fields:@{@"success":@(flag),@"time":@(player.currentTime)}];
    [self applyDucking:NO];self.playbackGate=@"translated audio finished";[self updateButton];
}
- (void)tick {
    id player = self.player;
    if (!player) {
        if (self.enabled) [self stop];
        [self recordSample];
        DNVOTUpdateNativeButtons(); return;
    }
    NSString *videoID = [self currentID];
    if (![self.videoID isEqualToString:videoID]) {
        BOOL autoStart = self.autoTranslate && videoID.length;
        [self stop]; self.videoID = videoID; _clock.reset();
        if (autoStart) {
            NSUInteger generation = self.generation;
            dispatch_async(dispatch_get_main_queue(), ^{ if (generation == self.generation && [self.videoID isEqualToString:videoID]) [self start]; });
        }
    }
    self.tickCount++;
    if (!self.enabled || !self.audio) { [self recordSample];[self mountButton];return; }
    double time = DNNumber(player, @"contentVideoMediaTime", NAN);
    if (!std::isfinite(time)) time = DNNumber(player, @"currentVideoMediaTime", NAN);
    double now = NSProcessInfo.processInfo.systemUptime;
    BOOL moving = _clock.observe(time, now);
    self.clockMoving = moving;
    id active = DNObject(player, @"activeVideo");
    BOOL blocked = DNNumber(player, @"isPlayingAd") || DNNumber(player, @"isPlayingAdSurvey") || DNNumber(player, @"isPlayingAdIntro") || DNNumber(active, @"isExternalPlaybackActive") || DNNumber(player, @"isMDXActive");
    id rateModel = DNObject(player, @"activePlaybackRateModel");
    float rate = (float)DNNumber(rateModel, @"activeRate", 1);
    double audioTime = self.audio.currentTime;
    if (!std::isfinite(audioTime)) audioTime = 0;
    double duration = self.audio.duration;
    auto transport=dnvot::localTransport(time,audioTime,self.offset,rate,moving,blocked,duration,self.audio.playing,now,self.lastPlayAttempt);
    auto decision=transport.sync;
    self.playbackGate=@"local audio ready";
    if (blocked) self.playbackGate=@"ad or external playback";
    else if (!std::isfinite(time)) self.playbackGate=@"invalid content clock";
    else if (!transport.supported) self.playbackGate=@"local audio supports video rates 0.5 to 2.0";
    else if (!moving) self.playbackGate=_clock.paused ? @"video paused" : @"content clock not advancing";
    else if (!decision.audible) self.playbackGate=@"outside translated audio coverage or invalid rate";
    if (!decision.audible) {
        if (self.audio.playing) { [self.audio pause];[self record:@"audio_pause_gate" fields:@{@"gate":self.playbackGate}]; }
        [self applyDucking:NO];
    }
    // Local seeks are synchronous; never pause or recursively re-enter tick for a seek.
    if (decision.seek) {
        self.audio.currentTime=decision.target;self.seekCommands++;
        [self record:@"audio_seek" fields:@{@"target":@(decision.target),@"before":@(audioTime),@"after":@(self.audio.currentTime)}];
    }
    if (decision.audible) {
        if (fabsf(self.audio.rate-decision.rate)>0.005f) self.audio.rate=decision.rate;
        if (transport.play) {
            self.lastPlayAttempt=now;self.playCommands++;self.lastPlaySucceeded=[self.audio play];
            [self record:@"audio_play" fields:@{@"ok":@(self.lastPlaySucceeded),@"time":@(self.audio.currentTime),@"rate":@(self.audio.rate)}];
        }
        self.playbackGate=self.audio.playing ? @"playing local file" : @"local audio play failed or stopped";
        [self applyDucking:self.audio.playing && self.translationLevel>0];
    }
    [self recordSample];[self mountButton];
}
- (NSDictionary *)sessionFields {
    AVAudioSession *session=AVAudioSession.sharedInstance;
    NSMutableArray *outputs=[NSMutableArray new];
    for (AVAudioSessionPortDescription *port in session.currentRoute.outputs) [outputs addObject:port.portType];
    return @{@"category":session.category ?: @"",@"mode":session.mode ?: @"",@"options":@(session.categoryOptions),@"outputs":outputs,@"system_volume":@(session.outputVolume),@"sample_rate":@(session.sampleRate),@"output_channels":@(session.outputNumberOfChannels),@"other_audio":@(session.otherAudioPlaying),@"silence_hint":@(session.secondaryAudioShouldBeSilencedHint)};
}
- (void)recordSample {
    if (!DNFlightRecorder.shared.recording) { self.audio.meteringEnabled=NO;return; }
    self.audio.meteringEnabled=YES;[self.audio updateMeters];
    double audioTime=self.audio.currentTime;double now=NSProcessInfo.processInfo.systemUptime;
    id active=DNObject(self.player,@"activeVideo");
    if (std::isfinite(self.lastAudioTime) && audioTime>self.lastAudioTime+0.002 && audioTime-self.lastAudioTime<1.5) self.audioAdvanceAt=now;
    self.lastAudioTime=audioTime;
    NSMutableArray *meters=[NSMutableArray new];
    for (NSUInteger i=0;i<MIN(self.audio.numberOfChannels,8u);i++) [meters addObject:@{@"average_dbfs":@([self.audio averagePowerForChannel:i]),@"peak_dbfs":@([self.audio peakPowerForChannel:i])}];
    [self record:@"sample" fields:@{@"video":self.videoID ?: @"",@"video_time":@(DNNumber(self.player,@"contentVideoMediaTime",-1)),@"video_state":@(DNNumber(self.player,@"playerState",-1)),@"video_rate":@(DNNumber(DNObject(self.player,@"activePlaybackRateModel"),@"activeRate",-1)),@"ad":@(DNNumber(self.player,@"isPlayingAd")),@"ad_survey":@(DNNumber(self.player,@"isPlayingAdSurvey")),@"ad_intro":@(DNNumber(self.player,@"isPlayingAdIntro")),@"mdx":@(DNNumber(self.player,@"isMDXActive")),@"external":@(DNNumber(active,@"isExternalPlaybackActive")),@"native_attempting":@(DNNumber(active,@"attemptingToPlay",-1)),@"offset":@(self.offset),@"original_level":@(self.originalLevel),@"volume_setter_ok":@(self.volumeApplied),@"partial":@(self.partial),@"moving":@(self.clockMoving),@"paused":@(_clock.paused),@"gate":self.playbackGate ?: @"",@"enabled":@(self.enabled),@"backend":@"AVAudioPlayer/local",@"audio_time":@(audioTime),@"audio_playing":@(self.audio.playing),@"audio_rate":@(self.audio.rate),@"audio_volume":@(self.audio.volume),@"duration":@(self.audio.duration),@"audio_clock_age":@(self.audioAdvanceAt ? now-self.audioAdvanceAt : -1),@"meters":meters,@"original_volume":@(DNNumber(self.player,@"volume",-1)),@"saved_volume":@(self.savedVolume),@"ducking":@(self.ducking),@"play_commands":@(self.playCommands),@"seek_commands":@(self.seekCommands),@"downloaded":@(self.downloadedBytes),@"expected":@(self.expectedBytes),@"app_state":@(UIApplication.sharedApplication.applicationState),@"session":[self sessionFields]}];
}
- (void)audioRouteChanged:(NSNotification *)notification {
    [self record:@"route_change" fields:@{@"reason":notification.userInfo[AVAudioSessionRouteChangeReasonKey] ?: @0,@"session":[self sessionFields]}];
}
- (void)appLifecycle:(NSNotification *)notification { [self record:@"app_lifecycle" fields:@{@"name":notification.name}]; }
- (void)mediaReset:(__unused NSNotification *)notification {
    [self record:@"audio_media_services_reset" fields:@{}];
    if (self.enabled) { [self stop];self.statusText=@"Аудиосистема перезапущена. Включите перевод повторно."; }
}
- (void)audioInterruption:(NSNotification *)notification {
    [self record:@"audio_interruption" fields:@{@"type":notification.userInfo[AVAudioSessionInterruptionTypeKey] ?: @0,@"options":notification.userInfo[AVAudioSessionInterruptionOptionKey] ?: @0}];
    if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
        [self.audio pause]; _clock.pause(NSProcessInfo.processInfo.systemUptime); self.playbackGate = @"audio interruption"; [self applyDucking:NO];
    }
}
- (void)showPanel { [self showPanelFrom:nil]; }
- (void)showPanelFrom:(UIViewController *)presenter {
    if (presenter.navigationController) {
        [presenter.navigationController pushViewController:[DNVOTPanel new] animated:YES]; return;
    }
    UIViewController *vc = [self.player isKindOfClass:UIViewController.class] ? self.player : nil;
    if (!vc.isViewLoaded || !vc.view.window) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && !window.hidden && window.windowLevel == UIWindowLevelNormal) vc = window.rootViewController;
            }
        }
    }
    if (!vc.isViewLoaded || !vc.view.window) return;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class] && [((UINavigationController *)vc).topViewController isKindOfClass:DNVOTPanel.class]) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[DNVOTPanel new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) { nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent]; nav.sheetPresentationController.prefersGrabberVisible = YES; }
    [vc presentViewController:nav animated:YES completion:nil];
}
- (NSString *)diagnostics {
    return [NSString stringWithFormat:@"DN YouTube Voice Translation 0.2.3-alpha\nYouTube: %@\niOS: %@\nVideo: %@\nEnabled: %@\nStatus: %@\nBackend: AVAudioPlayer / complete local file\nPlayback gate: %@\nContent time: %.3f\nContent clock moving: %@\nSync user paused: %@\nAudio playing: %@\nAudio time: %.3f\nAudio duration: %.3f\nAudio rate: %.3f\nAudio channels: %lu\nTranslation volume: %.3f\nOriginal volume: %.3f\nOriginal saved volume: %.3f\nOriginal level: %.3f\nDucking: %@\nLast volume setter succeeded: %@\nPlay commands: %lu\nSeek commands: %lu\nLast play succeeded: %@\nAudio error: %@\nDownloaded bytes: %lld / %lld\nRecorder: %@\nSession: %@\n%@\n%@\n%@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],UIDevice.currentDevice.systemVersion,self.videoID ?: @"—",self.enabled ? @"YES" : @"NO",self.statusText,self.playbackGate,DNNumber(self.player,@"contentVideoMediaTime",-1),self.clockMoving ? @"YES" : @"NO",_clock.paused ? @"YES" : @"NO",self.audio.playing ? @"YES" : @"NO",self.audio.currentTime,self.audio.duration,self.audio.rate,(unsigned long)self.audio.numberOfChannels,self.audio.volume,DNNumber(self.player,@"volume",-1),self.savedVolume,self.originalLevel,self.ducking ? @"YES" : @"NO",self.volumeApplied ? @"YES" : @"NO",(unsigned long)self.playCommands,(unsigned long)self.seekCommands,self.lastPlaySucceeded ? @"YES" : @"NO",self.audioError ?: @"—",(long long)self.downloadedBytes,(long long)self.expectedBytes,DNFlightRecorder.shared.state,[self sessionFields],DNVOTBootstrapDiagnostics(),DNVOTNativeDiagnostics(),[self.client diagnostics]];
}
@end

@interface DNVOTPanel ()
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *offsetLabel;
@property(nonatomic,strong) UIButton *action;
@property(nonatomic,strong) UIStackView *stack;
@property(nonatomic,strong) UIButton *logStart;
@property(nonatomic,strong) UIButton *logStop;
@property(nonatomic,strong) UILabel *logStatus;
@property(nonatomic,strong) NSTimer *refreshTimer;
@end
@implementation DNVOTPanel
- (UILabel *)label:(NSString *)text detail:(BOOL)detail {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:detail ? UIFontTextStyleFootnote : UIFontTextStyleHeadline];
    label.textColor = detail ? UIColor.secondaryLabelColor : UIColor.labelColor; return label;
}
- (UIButton *)languageButton:(BOOL)source {
    DNVOTController *c = DNVOTController.shared;
    NSArray *codes = source ? @[@"auto",@"en",@"de",@"fr",@"es",@"it",@"pt",@"ja",@"ko",@"zh",@"tr",@"uk",@"pl"] : @[@"ru",@"en",@"kk"];
    NSDictionary *names = @{ @"auto":@"Определять автоматически", @"ru":@"Русский", @"en":@"Английский", @"kk":@"Казахский", @"de":@"Немецкий", @"fr":@"Французский", @"es":@"Испанский", @"it":@"Итальянский", @"pt":@"Португальский", @"ja":@"Японский", @"ko":@"Корейский", @"zh":@"Китайский", @"tr":@"Турецкий", @"uk":@"Украинский", @"pl":@"Польский" };
    NSString *current = source ? c.fromLanguage : c.toLanguage;
    if (![codes containsObject:current]) { current = source ? @"auto" : @"ru"; if (source) c.fromLanguage = current; else c.toLanguage = current; }
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [button setTitle:names[current] forState:UIControlStateNormal];
    __weak UIButton *weakButton = button; __weak DNVOTPanel *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSString *code in codes) {
        UIAction *a = [UIAction actionWithTitle:names[code] image:nil identifier:nil handler:^(__unused UIAction *action) {
            if (source) c.fromLanguage = code; else c.toLanguage = code;
            [weakButton setTitle:names[code] forState:UIControlStateNormal]; [c saveSettings];
            if (c.enabled) [c stop]; [weakSelf refresh];
        }];
        [actions addObject:a];
    }
    button.menu = [UIMenu menuWithChildren:actions]; button.showsMenuAsPrimaryAction = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:38].active = YES;
    return button;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Озвучка с переводом"; self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:scroll];
    self.stack = [UIStackView new]; self.stack.axis = UILayoutConstraintAxisVertical; self.stack.spacing = 12; self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20], [self.stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20], [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    self.statusLabel = [self label:@"" detail:YES]; self.statusLabel.accessibilityTraits |= UIAccessibilityTraitUpdatesFrequently;
    [self.stack addArrangedSubview:self.statusLabel];
    UIButton *account = [UIButton buttonWithType:UIButtonTypeSystem];
    [account setTitle:@"Аккаунт Яндекса и живые голоса" forState:UIControlStateNormal];
    [account addTarget:self action:@selector(openAccount) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:account];
    UIButton *server = [UIButton buttonWithType:UIButtonTypeSystem];
    [server setTitle:@"Сервер перевода" forState:UIControlStateNormal];
    [server addTarget:self action:@selector(openServer) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:server];
    [self.stack addArrangedSubview:[self label:@"Язык оригинала" detail:NO]]; [self.stack addArrangedSubview:[self languageButton:YES]];
    [self.stack addArrangedSubview:[self label:@"Перевести на" detail:NO]]; [self.stack addArrangedSubview:[self languageButton:NO]];
    DNVOTController *c = DNVOTController.shared;
    for (NSInteger i = 0; i < 2; i++) {
        NSString *title = i == 0 ? @"Громкость оригинала" : @"Громкость перевода";
        [self.stack addArrangedSubview:[self label:title detail:NO]];
        UISlider *slider = [UISlider new]; slider.minimumValue = 0; slider.maximumValue = 1;
        slider.value = i == 0 ? c.originalLevel : c.translationLevel; slider.tag = i; slider.accessibilityLabel = title;
        [slider addTarget:self action:@selector(volumeChanged:) forControlEvents:UIControlEventValueChanged]; [self.stack addArrangedSubview:slider];
    }
    self.offsetLabel = [self label:@"" detail:NO]; [self.stack addArrangedSubview:self.offsetLabel];
    UIStepper *offset = [UIStepper new]; offset.minimumValue = -5; offset.maximumValue = 5; offset.stepValue = 0.1; offset.value = c.offset; offset.accessibilityLabel = @"Смещение перевода в секундах";
    [offset addTarget:self action:@selector(offsetChanged:) forControlEvents:UIControlEventValueChanged]; [self.stack addArrangedSubview:offset];
    [self.stack addArrangedSubview:[self label:@"Положительное смещение воспроизводит перевод раньше, отрицательное — позже." detail:YES]];
    UIStackView *autoRow = [UIStackView new]; autoRow.axis = UILayoutConstraintAxisHorizontal; autoRow.spacing = 12;
    [autoRow addArrangedSubview:[self label:@"Переводить следующие видео" detail:NO]];
    UISwitch *autoSwitch = [UISwitch new]; autoSwitch.on = c.autoTranslate;
    [autoSwitch addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged]; [autoRow addArrangedSubview:autoSwitch]; [self.stack addArrangedSubview:autoRow];
    [self.stack addArrangedSubview:[self label:@"Для перевода ссылка на ролик, а при необходимости его аудио передаются Яндексу. Сервер, аккаунт и тип голоса выбираются в настройках VOT. Качество и доступность зависят от сервиса." detail:YES]];
    self.action = [UIButton buttonWithType:UIButtonTypeSystem]; self.action.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.action.heightAnchor constraintGreaterThanOrEqualToConstant:46].active = YES;
    [self.action addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside]; [self.stack addArrangedSubview:self.action];
    UIButton *diagnostics = [UIButton buttonWithType:UIButtonTypeSystem]; [diagnostics setTitle:@"Скопировать диагностику" forState:UIControlStateNormal];
    [diagnostics addTarget:self action:@selector(copyDiagnostics) forControlEvents:UIControlEventTouchUpInside]; [self.stack addArrangedSubview:diagnostics];
    [self.stack addArrangedSubview:[self label:@"Подробный лог" detail:NO]];
    self.logStatus=[self label:@"" detail:YES];[self.stack addArrangedSubview:self.logStatus];
    self.logStart=[UIButton buttonWithType:UIButtonTypeSystem];[self.logStart setTitle:@"Начать запись лога" forState:UIControlStateNormal];
    [self.logStart addTarget:self action:@selector(startLog) forControlEvents:UIControlEventTouchUpInside];[self.stack addArrangedSubview:self.logStart];
    self.logStop=[UIButton buttonWithType:UIButtonTypeSystem];[self.logStop setTitle:@"Остановить запись лога" forState:UIControlStateNormal];
    [self.logStop addTarget:self action:@selector(stopLog) forControlEvents:UIControlEventTouchUpInside];[self.stack addArrangedSubview:self.logStop];
    UIButton *exportButton=[UIButton buttonWithType:UIButtonTypeSystem];[exportButton setTitle:@"Экспортировать лог файлом" forState:UIControlStateNormal];
    [exportButton addTarget:self action:@selector(exportLog:) forControlEvents:UIControlEventTouchUpInside];[self.stack addArrangedSubview:exportButton];
    [self.stack addArrangedSubview:[self label:@"Запись продолжается после закрытия настроек, пока YouTube выполняется. Лимит: 15 минут / 12 МБ. В файле есть ID видео и технические события; токены, ссылки на аудио, аккаунт и само аудио не записываются. Экспорт открывает меню «Поделиться», в нём можно сохранить файл." detail:YES]];
    [self.stack addArrangedSubview:[self label:@"0.2.3-alpha · Диагностическая сборка · Проверка на устройстве ещё требуется" detail:YES]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:DNUpdate object:nil]; [self refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];[self.refreshTimer invalidate];__weak DNVOTPanel *weakSelf=self;
    self.refreshTimer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *t) { [weakSelf refresh]; }];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];[self.refreshTimer invalidate];self.refreshTimer=nil; }
- (void)dealloc { [self.refreshTimer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh {
    DNVOTController *c = DNVOTController.shared; self.statusLabel.text = c.statusText;
    self.logStatus.text=DNFlightRecorder.shared.state;self.logStart.enabled=!DNFlightRecorder.shared.recording;self.logStop.enabled=DNFlightRecorder.shared.recording;
    self.offsetLabel.text = [NSString stringWithFormat:@"Смещение перевода: %+.1f с", c.offset];
    [self.action setTitle:c.enabled ? @"Выключить перевод" : @"Включить перевод" forState:UIControlStateNormal];
}
- (void)volumeChanged:(UISlider *)slider {
    DNVOTController *c = DNVOTController.shared;
    if (slider.tag == 0) c.originalLevel = slider.value; else c.translationLevel = slider.value;
    [c saveSettings];
}
- (void)offsetChanged:(UIStepper *)stepper { DNVOTController.shared.offset = stepper.value; [DNVOTController.shared saveSettings]; [self refresh]; }
- (void)autoChanged:(UISwitch *)toggle { DNVOTController.shared.autoTranslate = toggle.on; [DNVOTController.shared saveSettings]; }
- (void)toggle { if (DNVOTController.shared.enabled) [DNVOTController.shared stop]; else [DNVOTController.shared start]; [self refresh]; }
- (void)startLog { [DNFlightRecorder.shared start]; }
- (void)stopLog { [DNFlightRecorder.shared stop]; }
- (void)exportLog:(UIButton *)sender {
    __weak DNVOTPanel *weakSelf=self;
    [DNFlightRecorder.shared exportFile:^(NSURL *url,NSString *error) {
        DNVOTPanel *s=weakSelf;if (!s || !s.view.window || s.presentedViewController) return;
        if (!url) { s.logStatus.text=error;return; }
        UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView=sender;share.popoverPresentationController.sourceRect=sender.bounds;
        [s presentViewController:share animated:YES completion:nil];
    }];
}
- (void)copyDiagnostics { UIPasteboard.generalPasteboard.string = [DNVOTController.shared diagnostics]; }
- (void)openAccount { [self.navigationController pushViewController:[DNVOTAccountSettings new] animated:YES]; }
- (void)openServer { [self.navigationController pushViewController:[DNVOTServiceSettings new] animated:YES]; }
- (void)close { if (self.navigationController.viewControllers.count > 1) [self.navigationController popViewControllerAnimated:YES]; else [self dismissViewControllerAnimated:YES completion:nil]; }
@end
