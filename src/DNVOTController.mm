#import "DNVOT.h"
#import "Runtime.hpp"
#import "Preferences.h"
#import "FlightRecorder.h"
#import "LocalAudio.h"
#import "TranslationCache.h"
#import "PlayerButton.h"
#include "FeaturePolicy.hpp"
#include "AutoStartGate.hpp"
#include "SyncPolicy.hpp"
#include "ControlState.hpp"
#include "PreparationState.hpp"
#include "PlaybackClock.hpp"
#include "LocalTransport.hpp"
#include <algorithm>

static NSString *const DNSettings = @"DNVoiceTranslation.v1";
static NSString *const DNUpdate = @"DNVoiceTranslationUpdated";

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
@property(nonatomic,copy) NSString *autoHandledVideo;
@property(nonatomic) double autoCandidateSince;
@property(nonatomic) BOOL autoStarted;
@property(nonatomic,copy) NSString *detectedLanguage;
@property(nonatomic,copy) NSString *languageSource;
@property(nonatomic) double cacheSweepAt;
@property(nonatomic) BOOL autoStartReady;
@property(nonatomic,copy) NSString *lastNativePlayerState;
@end
@implementation DNVOTController {
    dnvot::PlaybackClock _clock;
    dnvot::AutoStartGate _autoGate;
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
        NSArray *excluded=[settings[@"excluded"] isKindOfClass:NSArray.class] ? settings[@"excluded"] : @[];
        NSMutableSet *languages=[NSMutableSet new];for (id v in excluded) { NSString *code=DNLanguageCode(v);if (code) [languages addObject:code]; }self.excludedLanguages=languages;
        _clock.reset(); self.playbackGate = @"disabled"; self.statusText = @"Откройте видео и включите перевод";
        [DNTranslationCache pruneExpired];self.cacheSweepAt=NSProcessInfo.processInfo.systemUptime+60;
        // Remove our abandoned temporary audio after a previous process crash.
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil]) {
            if ([name hasPrefix:@"DNVOT-audio-"] && [name hasSuffix:@".mp3"]) [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name] error:nil];
        }
        self.client = [DNVOTClient new];
        __weak DNVOTController *weakSelf = self;
        self.client.status = ^(NSString *status) { DNVOTController *s = weakSelf; if (s.enabled) s.statusText = s.download && !s.audio ? @"Загрузка файла озвучки…" : status; };
        self.client.audioReady = ^(NSURL *url, BOOL partial) {
            DNVOTController *s = weakSelf;
            if (!s.enabled || !s.activeKey.length) return;
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
    if ([_statusText isEqualToString:statusText]) return;
    _statusText = [statusText copy];
    [self updateButton];
    [NSNotificationCenter.defaultCenter postNotificationName:DNUpdate object:self];
}
- (void)saveSettings {
    [NSUserDefaults.standardUserDefaults setObject:@{ @"from":self.fromLanguage ?: @"auto", @"to":self.toLanguage ?: @"ru", @"original":@(self.originalLevel), @"translated":@(self.translationLevel), @"offset":@(self.offset), @"auto":@(self.autoTranslate), @"excluded":self.excludedLanguages.allObjects ?: @[] } forKey:DNSettings];
    if (self.audio) self.audio.volume = self.translationLevel;
    [self applyDucking:self.ducking];
}
- (void)updateButton { DNVOTUpdateNativeButtons(); }
- (void)toggleTranslation { self.autoHandledVideo=self.videoID;if (self.enabled) [self stop];else [self start]; }
- (void)autoSettingsChanged {
    self.autoHandledVideo=nil;self.autoCandidateSince=0;
    if (self.autoStarted && (!self.autoTranslate || [self.excludedLanguages containsObject:self.detectedLanguage ?: @""])) { [self stop];self.autoHandledVideo=self.videoID; }
    [self saveSettings];
}
- (void)discardAudioFile {
    [DNTranslationCache protect:nil];[DNTranslationCache pruneExpired];
    if ([self.audioFile.lastPathComponent hasPrefix:@"DNVOT-audio-"]) [NSFileManager.defaultManager removeItemAtURL:self.audioFile error:nil];self.audioFile=nil;
}
- (void)clearCache { [self stop];self.autoHandledVideo=self.videoID;[DNTranslationCache clear];self.statusText=[DNTranslationCache bytes]==0 ? @"Кеш озвучки очищен" : @"Часть кеша удалить не удалось"; }
- (unsigned long long)cacheBytes { return [DNTranslationCache bytes]; }
- (void)resetSettings {
    [self clearCache];[DNVOTPreferences.shared reset];
    self.fromLanguage=@"auto";self.toLanguage=@"ru";self.originalLevel=0.18f;self.translationLevel=1;self.offset=0;self.autoTranslate=NO;self.excludedLanguages=[NSSet set];self.autoHandledVideo=self.videoID;
    [self saveSettings];self.statusText=@"Настройки VOT сброшены, кеш и вход Яндекса очищены";
}
- (void)updateControlsButton:(UIButton *)button {
    BOOL ready = self.enabled && self.audio != nil;
    BOOL playing = ready && self.audio.playing && self.translationLevel > 0;
    auto state = dnvot::controlState(self.enabled, ready, playing, self.requestStarted, NSProcessInfo.processInfo.systemUptime);
    BOOL waiting = state.phase == dnvot::ControlPhase::waiting;
    auto preparation=dnvot::preparationState(self.enabled,ready,self.download!=nil,self.downloadedBytes,self.expectedBytes);
    // Keep the same outline glyph for on/off; the controls row uses no filled badge.
    [button setTitle:nil forState:UIControlStateNormal];
    [button setImage:nil forState:UIControlStateNormal];
    button.tintColor = self.enabled ? UIColor.whiteColor : [UIColor colorWithWhite:0.65 alpha:1];
    if ([button isKindOfClass:DNVOTPlayerButton.class]) [(DNVOTPlayerButton *)button updateLoading:waiting progress:preparation.fraction];
    button.selected=self.enabled;
    if (self.enabled) button.accessibilityTraits|=UIAccessibilityTraitSelected;else button.accessibilityTraits&=~UIAccessibilityTraitSelected;
    button.accessibilityLabel = waiting ? @"Отменить подготовку перевода" : (playing ? @"Выключить воспроизводимый перевод" : (ready ? @"Перевод включён, воспроизведение приостановлено. Нажмите для выключения" : @"Включить перевод"));
    button.accessibilityHint = @"Удерживайте для настроек озвучки и громкости";
    button.accessibilityValue = waiting && preparation.fraction>=0 ? [NSString stringWithFormat:@"Загрузка озвучки: %.0f%%. %@",floor(preparation.fraction*100),self.statusText ?: @""] : self.statusText;
    button.enabled = self.videoID.length > 0;
    button.hidden = !self.videoID.length;
}
- (NSString *)currentID {
    NSString *videoID = DNString(DNObject(self.player, @"contentVideoID"));
    if (!DNVideoID(videoID) && !DNNumber(self.player, @"isPlayingAd")) videoID = DNString(DNObject(self.player, @"currentVideoID"));
    return DNVideoID(videoID) ? videoID : nil;
}
- (void)resetVideoDiagnostics {
    self.downloadedBytes=0;self.expectedBytes=0;self.playCommands=0;self.seekCommands=0;self.lastPlaySucceeded=NO;self.lastPlayAttempt=-INFINITY;self.audioAdvanceAt=0;self.lastAudioTime=NAN;self.audioError=nil;
}
- (void)observePlayer:(id)player {
    if (!NSThread.isMainThread) {
        __weak id weak = player;
        dispatch_async(dispatch_get_main_queue(), ^{ if (weak) [self observePlayer:weak]; }); return;
    }
    if (![player isKindOfClass:UIViewController.class]) return;
    NSString *unsupported=DNVOTUnsupportedPlayerContext(player);
    if (unsupported) {
        static const void *ignoredKey=&ignoredKey;
        if (!objc_getAssociatedObject(player,ignoredKey)) {
            objc_setAssociatedObject(player,ignoredKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [self record:@"player_candidate_ignored" fields:@{@"player":DNVOTPlayerIdentifier(player),@"context":unsupported}];
        }
        return;
    }
    UIViewController *vc = player;
    if (!vc.isViewLoaded || !vc.view.window) return;
    if (self.player != player) {
        [self record:@"player_attachment" fields:@{@"previous":DNVOTPlayerIdentifier(self.player),@"next":DNVOTPlayerIdentifier(player)}];
        [self stop];[self resetVideoDiagnostics];_autoGate.reset(); self.player = player; self.videoID = nil;self.autoHandledVideo=nil;self.autoCandidateSince=0;
        _clock.reset();
    }
    [self mountButton];
}
- (void)mountButton { DNVOTUpdateNativeButtons(); }
- (void)playerPaused:(id)player {
    if (self.player != player) return;
    [self record:@"native_pause" fields:@{@"content":@(DNNumber(player,@"contentVideoMediaTime",-1))}];
    _autoGate.reset();self.autoStartReady=NO;
    if (!self.enabled) { self.playbackGate=@"disabled";return; }
    _clock.pause(NSProcessInfo.processInfo.systemUptime);self.clockMoving=NO; self.playbackGate = @"video pause callback"; [self.audio pause]; [self applyDucking:NO];
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
    [self record:@"original_volume_command" fields:@{@"target":@(target),@"duck":@(duck),@"player":DNVOTPlayerIdentifier(player)}];
    self.settingVolume = YES;
    self.volumeApplied = DNSetVolume(player, target);
    self.settingVolume = NO;
}
- (void)stop {
    if (self.enabled || self.working || self.audio || self.download) [self record:@"translation_stop" fields:@{}];
    self.generation++; [self.client cancel]; [self.download cancel]; self.download=nil; [self.audio stop];
    [self applyDucking:NO]; self.audio = nil; self.enabled = NO; self.working = NO;
    [self discardAudioFile];
    self.clockMoving=NO;_clock.reset();self.autoStarted=NO;
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
    NSString *videoID = [self currentID];self.autoHandledVideo=videoID;
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
    [self resetVideoDiagnostics];
    [self record:@"translation_start" fields:@{@"video":videoID,@"source":self.fromLanguage,@"target":self.toLanguage}];
    self.activeKey = [self cacheKey];
    self.savedVolume = (float)DNNumber(self.player, @"volume", 1); self.capturedVolume = YES;
    NSURL *cached=[DNTranslationCache find:self.activeKey];
    if (cached) { [self record:@"translation_cache_hit" fields:@{@"local_file":@(cached.isFileURL)}];[self loadAudio:cached partial:NO]; return; }
    NSInteger itag = 140; NSURL *source = [self sourceAudioWithItag:&itag];
    [self.client startVideo:videoID duration:duration from:self.fromLanguage to:self.toLanguage sourceAudio:source itag:itag];
}
- (void)loadAudio:(NSURL *)url partial:(BOOL)partial {
    self.generation++; self.seeking=NO;self.partial=partial;self.working=YES;
    [self.download cancel];[self.audio stop];[self applyDucking:NO];self.audio=nil;
    [self discardAudioFile];
    self.downloadedBytes=0;self.expectedBytes=0;
    self.playbackGate=url.isFileURL ? @"opening cached translated file" : @"downloading complete translated file";
    self.statusText=@"Загрузка файла озвучки…";
    NSUInteger generation=self.generation;
    __weak DNVOTController *weakSelf=self;
    DNLocalAudioDownload *download=[DNLocalAudioDownload new];self.download=download;
    download.progress=^(int64_t total,int64_t expected) {
        DNVOTController *s=weakSelf;if (!s || generation!=s.generation) return;
        s.downloadedBytes=total;s.expectedBytes=expected;
        [s updateButton];
    };
    void (^ready)(NSURL *,NSString *)=^(NSURL *local,NSString *errorText) {
        DNVOTController *s=weakSelf;
        if (!s || generation!=s.generation || !s.enabled) { if (local) [NSFileManager.defaultManager removeItemAtURL:local error:nil];return; }
        s.download=nil;s.working=NO;
        if (!local) { [s stop];s.statusText=errorText ?: @"Не удалось загрузить озвучку";return; }
        if (!partial && !url.isFileURL) local=[DNTranslationCache store:local key:s.activeKey];
        s.audioFile=local;[DNTranslationCache protect:local];
        NSError *error=nil;
        AVAudioPlayer *audio=[[AVAudioPlayer alloc] initWithContentsOfURL:local error:&error];
        audio.enableRate=YES;audio.meteringEnabled=DNFlightRecorder.shared.recording;audio.delegate=s;audio.volume=s.translationLevel;
        BOOL prepared=audio && [audio prepareToPlay];
        [s record:@"audio_prepare" fields:@{@"ok":@(prepared),@"duration":@(audio.duration),@"channels":@(audio.numberOfChannels),@"sample_rate":@(audio.format.sampleRate),@"error_domain":error.domain ?: @"",@"error_code":@(error.code)}];
        if (!prepared) {
            [NSFileManager.defaultManager removeItemAtURL:s.audioFile error:nil];
            [s stop];s.audioError=[NSString stringWithFormat:@"%@/%ld",error.domain ?: @"prepare",(long)error.code];s.statusText=@"Не удалось декодировать файл озвучки. Экспортируйте лог.";return;
        }
        s.audio=audio;s.lastAudioTime=NAN;s.audioAdvanceAt=0;s.lastPlayAttempt=-INFINITY;
        s.playbackGate=@"local audio ready";s.statusText=@"Озвучка загружена, ожидание воспроизведения видео";
        [s tick];
    };
    if (url.isFileURL) { ready(url,nil);return; }
    download.completion=ready;
    [download start:[DNVOTPreferences.shared translationAudioURL:url]];
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player!=self.audio) return;
    self.audioError=[NSString stringWithFormat:@"%@/%ld",error.domain ?: @"decode",(long)error.code];
    [self record:@"audio_decode_error" fields:@{@"domain":error.domain ?: @"",@"code":@(error.code)}];
    [NSFileManager.defaultManager removeItemAtURL:self.audioFile error:nil];
    [self stop];self.statusText=@"Ошибка декодирования озвучки. Экспортируйте лог.";
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player!=self.audio) return;
    [self record:@"audio_finished" fields:@{@"success":@(flag),@"time":@(player.currentTime)}];
    [self applyDucking:NO];self.playbackGate=@"translated audio finished";[self updateButton];
}
static id DNField(id object,NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
- (NSString *)resolveLanguage {
    id active=DNObject(self.player,@"activeVideo");
    id format=DNObject(active,@"selectedAudioFormat");id track=DNField(format,@"audioTrack");
    for (NSString *field in @[@"languageCode",@"language",@"id",@"id_p",@"ID"]) {
        NSString *code=DNLanguageCode(DNField(track,field));if (code) { self.languageSource=@"selected audio track";return code; }
    }
    id available=DNObject(active,@"availableCaptionTracks");
    if ([available isKindOfClass:NSArray.class]) for (id caption in available) {
        NSString *vss=DNString(DNObject(caption,@"VSSID"));
        if (![vss hasPrefix:@"a."]) continue;
        NSString *code=DNLanguageCode(DNObject(caption,@"languageCode")) ?: DNLanguageCode([vss substringFromIndex:2]);
        if (code) { self.languageSource=@"native automatic captions";return code; }
    }
    id captions=DNObject(active,@"playerCaptions");
    id renderer=DNField(captions,@"playerCaptionsTracklistRenderer") ?: captions;
    id tracks=DNField(renderer,@"captionTracksArray");
    if ([tracks isKindOfClass:NSArray.class]) for (id caption in tracks) {
        NSString *vss=DNString(DNField(caption,@"vssId")) ?: DNString(DNField(caption,@"vssID"));
        if ([DNString(DNField(caption,@"kind")) isEqual:@"asr"] || [vss hasPrefix:@"a."]) {
            NSString *code=DNLanguageCode(DNField(caption,@"languageCode"));if (!code && [vss hasPrefix:@"a."]) code=DNLanguageCode([vss substringFromIndex:2]);if (code) { self.languageSource=@"automatic captions";return code; }
        }
    }
    NSString *manual=DNLanguageCode(self.fromLanguage);
    self.languageSource=manual ? @"explicit source setting" : @"unknown";return manual;
}
- (void)evaluateAutoTranslation {
    if (!self.autoTranslate || self.enabled || self.working || !self.videoID.length || [self.autoHandledVideo isEqual:self.videoID]) return;
    double now=NSProcessInfo.processInfo.systemUptime;if (!self.autoCandidateSince) self.autoCandidateSince=now;
    self.detectedLanguage=[self resolveLanguage];
    double duration=DNNumber(self.player,@"currentVideoTotalMediaTime");
    BOOL ready=duration>0 && !DNNumber(self.player,@"isPlayingAd");
    auto action=dnvot::autoAction(ready,self.detectedLanguage.length,[self.excludedLanguages containsObject:self.detectedLanguage ?: @""],self.excludedLanguages.count>0,now-self.autoCandidateSince);
    if (action==dnvot::AutoAction::wait) return;
    if (action==dnvot::AutoAction::start && !self.autoStartReady) {
        self.statusText=@"Автоперевод: ожидание устойчивого воспроизведения видео";return;
    }
    self.autoHandledVideo=self.videoID;
    [self record:@"auto_decision" fields:@{@"language":self.detectedLanguage ?: @"unknown",@"source":self.languageSource ?: @"unknown",@"action":@(static_cast<int>(action))}];
    if (action==dnvot::AutoAction::excluded) { self.statusText=[NSString stringWithFormat:@"Автоперевод пропущен: язык %@ в исключениях. Можно включить кнопкой.",self.detectedLanguage];return; }
    if (action==dnvot::AutoAction::unknown) { self.statusText=@"Автоперевод пропущен: язык неизвестен, заданы исключения. Можно включить кнопкой.";return; }
    NSUInteger generation=self.generation;NSString *video=self.videoID;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation==self.generation && !self.enabled && self.autoTranslate && [self.videoID isEqual:video]) {
            if (self.autoStartReady) { [self start];self.autoStarted=self.enabled; }
            else self.autoHandledVideo=nil;
        }
    });
}
- (void)tick {
    double sweepNow=NSProcessInfo.processInfo.systemUptime;
    if (sweepNow>=self.cacheSweepAt) { [DNTranslationCache pruneExpired];self.cacheSweepAt=sweepNow+60; }
    id player = self.player;
    if (!player || DNVOTUnsupportedPlayerContext(player)) {
        if (self.enabled) [self stop];
        self.player=nil;self.videoID=nil;_autoGate.reset();self.autoStartReady=NO;
        [self recordSample];
        DNVOTUpdateNativeButtons(); return;
    }
    NSString *videoID = [self currentID];
    if (!dnvot::sameVideo(self.videoID.UTF8String ?: "",videoID.UTF8String ?: "")) {
        [self stop];[self resetVideoDiagnostics];self.videoID=videoID;self.autoHandledVideo=nil;self.autoCandidateSince=0;self.detectedLanguage=nil;self.languageSource=nil;
    }
    double nativeTime=DNNumber(player,@"contentVideoMediaTime",NAN);
    if (!std::isfinite(nativeTime)) nativeTime=DNNumber(player,@"currentVideoMediaTime",NAN);
    self.autoStartReady=_autoGate.observe(self.videoID.UTF8String ?: "",nativeTime,sweepNow);
    NSString *nativeState=[NSString stringWithFormat:@"%@/%@/%.0f",DNVOTPlayerIdentifier(player),self.videoID ?: @"",DNNumber(player,@"playerState",-1)];
    if (![nativeState isEqual:self.lastNativePlayerState]) {
        self.lastNativePlayerState=nativeState;
        [self record:@"native_state_transition" fields:@{@"player":DNVOTPlayerIdentifier(player),@"video":self.videoID ?: @"",@"state":@(DNNumber(player,@"playerState",-1)),@"content":@(std::isfinite(nativeTime) ? nativeTime : -1),@"translation_enabled":@(self.enabled),@"has_translation_audio":@(self.audio!=nil)}];
    }
    [self evaluateAutoTranslation];
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
    auto preparation=dnvot::preparationState(self.enabled,self.audio!=nil,self.download!=nil,self.downloadedBytes,self.expectedBytes);
    [self record:@"sample" fields:@{@"video":self.videoID ?: @"",@"video_time":@(DNNumber(self.player,@"contentVideoMediaTime",-1)),@"video_state":@(DNNumber(self.player,@"playerState",-1)),@"video_rate":@(DNNumber(DNObject(self.player,@"activePlaybackRateModel"),@"activeRate",-1)),@"ad":@(DNNumber(self.player,@"isPlayingAd")),@"ad_survey":@(DNNumber(self.player,@"isPlayingAdSurvey")),@"ad_intro":@(DNNumber(self.player,@"isPlayingAdIntro")),@"mdx":@(DNNumber(self.player,@"isMDXActive")),@"external":@(DNNumber(active,@"isExternalPlaybackActive")),@"native_attempting":@(DNNumber(active,@"attemptingToPlay",-1)),@"offset":@(self.offset),@"original_level":@(self.originalLevel),@"volume_setter_ok":@(self.volumeApplied),@"partial":@(self.partial),@"moving":@(self.clockMoving),@"paused":@(_clock.paused),@"gate":self.playbackGate ?: @"",@"enabled":@(self.enabled),@"backend":@"AVAudioPlayer/local",@"audio_time":@(audioTime),@"audio_playing":@(self.audio.playing),@"audio_rate":@(self.audio.rate),@"audio_volume":@(self.audio.volume),@"duration":@(self.audio.duration),@"audio_clock_age":@(self.audioAdvanceAt ? now-self.audioAdvanceAt : -1),@"meters":meters,@"original_volume":@(DNNumber(self.player,@"volume",-1)),@"saved_volume":@(self.savedVolume),@"ducking":@(self.ducking),@"play_commands":@(self.playCommands),@"seek_commands":@(self.seekCommands),@"downloaded":@(self.downloadedBytes),@"expected":@(self.expectedBytes),@"preparation":preparation.phase==dnvot::PreparationPhase::none ? @"none" : (preparation.phase==dnvot::PreparationPhase::service ? @"service" : @"download"),@"download_fraction":@(preparation.fraction),@"service_eta_seconds":@(self.client.serverRemainingTime),@"app_state":@(UIApplication.sharedApplication.applicationState),@"session":[self sessionFields]}];
}
- (void)audioRouteChanged:(NSNotification *)notification {
    [self record:@"route_change" fields:@{@"reason":notification.userInfo[AVAudioSessionRouteChangeReasonKey] ?: @0,@"session":[self sessionFields]}];
}
- (void)appLifecycle:(NSNotification *)notification {
    [self record:@"app_lifecycle" fields:@{@"name":notification.name}];
    if ([notification.name isEqual:UIApplicationWillEnterForegroundNotification]) { [DNTranslationCache pruneExpired];self.cacheSweepAt=NSProcessInfo.processInfo.systemUptime+60; }
}
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
        [presenter.navigationController pushViewController:[DNVOTSettings new] animated:YES]; return;
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
    if ([vc isKindOfClass:UINavigationController.class] && [((UINavigationController *)vc).topViewController isKindOfClass:DNVOTSettings.class]) return;
    DNVOTSettings *settings=[DNVOTSettings new];settings.quick=presenter==nil;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) { nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent]; nav.sheetPresentationController.prefersGrabberVisible = YES; }
    [vc presentViewController:nav animated:YES completion:nil];
}
- (NSString *)diagnostics {
    self.detectedLanguage=[self resolveLanguage];
    return [NSString stringWithFormat:@"DN YouTube Voice Translation 0.4.2-test.1\nYouTube: %@\niOS: %@\nVideo: %@\nEnabled: %@\nStatus: %@\nBackend: AVAudioPlayer / complete local file\nPlayback gate: %@\nContent time: %.3f\nContent clock moving: %@\nSync user paused: %@\nAudio playing: %@\nAudio time: %.3f\nAudio duration: %.3f\nAudio rate: %.3f\nAudio channels: %lu\nTranslation volume: %.3f\nOriginal volume: %.3f\nOriginal saved volume: %.3f\nOriginal level: %.3f\nDucking: %@\nLast volume setter succeeded: %@\nPlay commands: %lu\nSeek commands: %lu\nLast play succeeded: %@\nAudio error: %@\nDownloaded bytes: %lld / %lld\nRecorder: %@\nSession: %@\n%@\n%@\n%@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],UIDevice.currentDevice.systemVersion,self.videoID ?: @"—",self.enabled ? @"YES" : @"NO",self.statusText,self.playbackGate,DNNumber(self.player,@"contentVideoMediaTime",-1),self.clockMoving ? @"YES" : @"NO",_clock.paused ? @"YES" : @"NO",self.audio.playing ? @"YES" : @"NO",self.audio.currentTime,self.audio.duration,self.audio.rate,(unsigned long)self.audio.numberOfChannels,self.audio.volume,DNNumber(self.player,@"volume",-1),self.savedVolume,self.originalLevel,self.ducking ? @"YES" : @"NO",self.volumeApplied ? @"YES" : @"NO",(unsigned long)self.playCommands,(unsigned long)self.seekCommands,self.playCommands ? (self.lastPlaySucceeded ? @"YES" : @"NO") : @"— (no attempt for this video)",self.audioError ?: @"—",(long long)self.downloadedBytes,(long long)self.expectedBytes,DNFlightRecorder.shared.state,[self sessionFields],DNVOTBootstrapDiagnostics(),DNVOTNativeDiagnostics(),[[self.client diagnostics] stringByAppendingFormat:@"\nAuto translate: %@\nExcluded: %@\nDetected language: %@ (%@)\nCache bytes: %llu\nCache auto-clean: ON / 24h from save\nAuto start gate: %@\nPlayer instance: %@",self.autoTranslate ? @"YES" : @"NO",[self.excludedLanguages.allObjects componentsJoinedByString:@","],self.detectedLanguage ?: @"unknown",self.languageSource ?: @"unknown",[self cacheBytes],self.autoStartReady ? @"ready" : @"waiting for sustained progress",DNVOTPlayerIdentifier(self.player)]];
}
@end

