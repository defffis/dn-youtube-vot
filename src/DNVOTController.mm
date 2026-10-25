#import "DNVOT.h"
#import "Runtime.hpp"
#include "SyncPolicy.hpp"
#include <algorithm>

static NSString *const DNSettings = @"DNVoiceTranslation.v1";
static NSString *const DNUpdate = @"DNVoiceTranslationUpdated";
@interface DNVOTPanel : UIViewController
@end

@interface DNVOTController ()
@property(nonatomic,strong) DNVOTClient *client;
@property(nonatomic,strong) AVPlayer *audio;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSCache<NSString *, NSURL *> *cache;
@property(nonatomic,copy) NSString *activeKey;
@property(nonatomic) double lastMedia;
@property(nonatomic) double lastAdvance;
@property(nonatomic) BOOL userPaused;
@property(nonatomic) double pausedAt;
@property(nonatomic) BOOL settingVolume;
@property(nonatomic) BOOL ducking;
@property(nonatomic) float savedVolume;
@property(nonatomic) BOOL capturedVolume;
@property(nonatomic) BOOL seeking;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL partial;
@property(nonatomic) NSUInteger tickCount;
@end
@implementation DNVOTController
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
        self.lastMedia = NAN; self.lastAdvance = -100; self.statusText = @"Откройте видео и включите перевод";
        self.cache = [NSCache new]; self.cache.countLimit = 20;
        self.client = [DNVOTClient new];
        __weak DNVOTController *weakSelf = self;
        self.client.status = ^(NSString *status) { DNVOTController *s = weakSelf; if (s.enabled) s.statusText = status; };
        self.client.audioReady = ^(NSURL *url, BOOL partial) {
            DNVOTController *s = weakSelf;
            if (!s.enabled || !s.activeKey.length) return;
            if (!partial) [s.cache setObject:url forKey:s.activeKey];
            s.working = NO; [s loadAudio:url partial:partial];
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
    }
    return self;
}
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
- (void)updateButton {
    if (!self.button) return;
    NSString *title = self.enabled ? (self.working ? @"Перевод…" : @"Перевод ✓") : @"Перевод";
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.accessibilityValue = self.statusText;
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
        self.lastMedia = NAN; self.lastAdvance = -100; self.userPaused = NO;
    }
    [self mountButton];
}
- (void)mountButton {
    UIViewController *vc = [self.player isKindOfClass:UIViewController.class] ? self.player : nil;
    if (!vc.isViewLoaded || !vc.view.window) return;
    UIView *host = vc.view;
    if (!self.button) {
        self.button = [UIButton buttonWithType:UIButtonTypeSystem];
        self.button.translatesAutoresizingMaskIntoConstraints = NO;
        self.button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.72];
        self.button.tintColor = UIColor.whiteColor; self.button.layer.cornerRadius = 18;
        self.button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        self.button.accessibilityLabel = @"Озвучка видео с переводом";
        [self.button addTarget:self action:@selector(showPanel) forControlEvents:UIControlEventTouchUpInside];
    }
    if (self.button.superview != host) {
        [self.button removeFromSuperview]; [host addSubview:self.button];
        [NSLayoutConstraint activateConstraints:@[
            [self.button.leadingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.leadingAnchor constant:12],
            [self.button.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:48],
            [self.button.widthAnchor constraintEqualToConstant:112], [self.button.heightAnchor constraintEqualToConstant:38]
        ]];
    }
    [host bringSubviewToFront:self.button];
    self.button.hidden = !self.videoID.length || CGRectGetWidth(host.bounds) < 200 || CGRectGetHeight(host.bounds) < 130;
    [self updateButton];
}
- (void)playerPaused:(id)player {
    if (self.player != player) return;
    self.userPaused = YES; self.pausedAt = NSProcessInfo.processInfo.systemUptime; [self.audio pause]; [self applyDucking:NO];
}
- (void)playerResumed:(id)player { if (self.player == player) self.userPaused = NO; }
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
    DNSetVolume(player, target);
    self.settingVolume = NO;
}
- (void)stop {
    self.generation++; [self.client cancel]; [self.audio pause];
    [self applyDucking:NO]; self.audio = nil; self.enabled = NO; self.working = NO;
    self.capturedVolume = NO; self.seeking = NO; self.activeKey = nil;
    self.statusText = @"Перевод выключен";
}
- (NSString *)cacheKey { return [NSString stringWithFormat:@"%@|%@|%@", self.videoID, self.fromLanguage, self.toLanguage]; }
- (NSURL *)sourceAudioWithItag:(NSInteger *)itag {
    id active = DNObject(self.player, @"activeVideo");
    id format = DNObject(active, @"selectedAudioFormat");
    id raw = DNObject(format, @"URL");
    NSURL *url = [raw isKindOfClass:NSURL.class] ? raw : [NSURL URLWithString:DNString(raw) ?: @""];
    if (url && DNNumber(format, @"DRMFamily") == 0 && [url.host.lowercaseString hasSuffix:@".googlevideo.com"]) {
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
    self.activeKey = [self cacheKey];
    self.savedVolume = (float)DNNumber(self.player, @"volume", 1); self.capturedVolume = YES;
    NSURL *cached = [self.cache objectForKey:self.activeKey];
    if (cached) { self.working = NO; [self loadAudio:cached partial:NO]; self.statusText = @"Перевод загружен из кеша текущего сеанса"; return; }
    NSInteger itag = 140; NSURL *source = [self sourceAudioWithItag:&itag];
    [self.client startVideo:videoID duration:duration from:self.fromLanguage to:self.toLanguage sourceAudio:source itag:itag];
}
- (void)loadAudio:(NSURL *)url partial:(BOOL)partial {
    self.generation++; self.seeking = NO; self.partial = partial;
    [self.audio pause]; [self applyDucking:NO];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    item.audioTimePitchAlgorithm = AVAudioTimePitchAlgorithmSpectral;
    item.preferredForwardBufferDuration = 15;
    self.audio = [AVPlayer playerWithPlayerItem:item]; self.audio.volume = self.translationLevel;
    self.audio.automaticallyWaitsToMinimizeStalling = YES;
}
- (void)tick {
    id player = self.player;
    if (!player) {
        if (self.enabled) [self stop];
        [self.button removeFromSuperview]; return;
    }
    NSString *videoID = [self currentID];
    if (![self.videoID isEqualToString:videoID]) {
        BOOL autoStart = self.autoTranslate && videoID.length;
        [self stop]; self.videoID = videoID; self.lastMedia = NAN; self.lastAdvance = -100; self.userPaused = NO;
        if (autoStart) {
            NSUInteger generation = self.generation;
            dispatch_async(dispatch_get_main_queue(), ^{ if (generation == self.generation && [self.videoID isEqualToString:videoID]) [self start]; });
        }
    }
    if (self.tickCount++ % 5 == 0) [self mountButton];
    if (!self.enabled || !self.audio) return;
    AVPlayerItem *item = self.audio.currentItem;
    if (item.status == AVPlayerItemStatusFailed) {
        if (self.activeKey) [self.cache removeObjectForKey:self.activeKey];
        [self stop]; self.statusText = @"Не удалось воспроизвести перевод. Включите перевод повторно для обновления ссылки."; return;
    }
    double time = DNNumber(player, @"contentVideoMediaTime", NAN);
    if (!std::isfinite(time)) time = DNNumber(player, @"currentVideoMediaTime", NAN);
    double now = NSProcessInfo.processInfo.systemUptime;
    double delta = time - self.lastMedia;
    if (std::isfinite(time) && std::isfinite(self.lastMedia) && delta > 0.002 && delta < 1.5) self.lastAdvance = now;
    self.lastMedia = time;
    id active = DNObject(player, @"activeVideo");
    BOOL blocked = DNNumber(player, @"isPlayingAd") || DNNumber(player, @"isPlayingAdSurvey") || DNNumber(player, @"isPlayingAdIntro") || DNNumber(active, @"isExternalPlaybackActive") || DNNumber(player, @"isMDXActive");
    if (self.userPaused && now - self.pausedAt > 0.6 && delta > 0.002 && delta < 1.5 && DNNumber(active, @"attemptingToPlay", 0)) self.userPaused = NO;
    BOOL moving = !self.userPaused && DNNumber(active, @"attemptingToPlay", 1) && now - self.lastAdvance < 0.42;
    id rateModel = DNObject(player, @"activePlaybackRateModel");
    float rate = (float)DNNumber(rateModel, @"activeRate", 1);
    double audioTime = CMTimeGetSeconds(self.audio.currentTime);
    if (!std::isfinite(audioTime)) audioTime = 0;
    double duration = CMTimeGetSeconds(item.duration);
    auto decision = dnvot::sync(time, audioTime, self.offset, rate, moving, blocked,
                               item.status == AVPlayerItemStatusReadyToPlay, duration);
    if (!decision.audible || self.seeking) { [self.audio pause]; [self applyDucking:NO]; }
    if (!self.seeking && decision.seek && !blocked && item.status == AVPlayerItemStatusReadyToPlay) {
        self.seeking = YES; [self.audio pause]; [self applyDucking:NO];
        NSUInteger generation = self.generation;
        __weak DNVOTController *weakSelf = self;
        [self.audio seekToTime:CMTimeMakeWithSeconds(decision.target, 600) toleranceBefore:CMTimeMakeWithSeconds(0.035, 600) toleranceAfter:CMTimeMakeWithSeconds(0.035, 600) completionHandler:^(__unused BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DNVOTController *s = weakSelf;
                if (s && generation == s.generation) s.seeking = NO;
            });
        }]; return;
    }
    if (decision.audible && !self.seeking) {
        if (fabsf(self.audio.rate - decision.rate) > 0.005f) self.audio.rate = decision.rate;
        [self applyDucking:self.audio.timeControlStatus == AVPlayerTimeControlStatusPlaying && self.translationLevel > 0];
    }
}
- (void)audioInterruption:(NSNotification *)notification {
    if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
        [self.audio pause]; self.lastAdvance = -100; [self applyDucking:NO];
    }
}
- (void)showPanel {
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
    id active = DNObject(self.player, @"activeVideo");
    NSString *engine = [NSString stringWithFormat:@"DN YouTube Voice Translation 0.1.1-alpha\nYouTube: %@\niOS: %@\nPlayer: %@\nVideo: %@\nEnabled: %@\nStatus: %@\nPlayer state: %.0f\nContent time: %.3f\nRate: %.3f\nAudio state: %ld\nAudio time: %.3f\nAd: %.0f\nExternal playback: %.0f\nPartial translation: %@\nEngine: Yandex VOT / %@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], UIDevice.currentDevice.systemVersion, NSStringFromClass([self.player class]), self.videoID ?: @"—", self.enabled ? @"YES" : @"NO", self.statusText, DNNumber(self.player, @"playerState", -1), DNNumber(self.player, @"contentVideoMediaTime", -1), DNNumber(DNObject(self.player, @"activePlaybackRateModel"), @"activeRate", -1), (long)self.audio.timeControlStatus, self.audio ? CMTimeGetSeconds(self.audio.currentTime) : 0, DNNumber(self.player, @"isPlayingAd"), DNNumber(active, @"isExternalPlaybackActive"), self.partial ? @"YES" : @"NO", @"26.10.0.1796"];
    return [engine stringByAppendingFormat:@"\n%@", DNVOTBootstrapDiagnostics()];
}
@end

@interface DNVOTPanel ()
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *offsetLabel;
@property(nonatomic,strong) UIButton *action;
@property(nonatomic,strong) UIStackView *stack;
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
    [self.stack addArrangedSubview:[self label:@"Для перевода ссылка на ролик, а при необходимости его аудио передаются Яндексу. Используется стандартная озвучка VOT; качество и доступность зависят от сервиса." detail:YES]];
    self.action = [UIButton buttonWithType:UIButtonTypeSystem]; self.action.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.action.heightAnchor constraintGreaterThanOrEqualToConstant:46].active = YES;
    [self.action addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside]; [self.stack addArrangedSubview:self.action];
    UIButton *diagnostics = [UIButton buttonWithType:UIButtonTypeSystem]; [diagnostics setTitle:@"Скопировать диагностику" forState:UIControlStateNormal];
    [diagnostics addTarget:self action:@selector(copyDiagnostics) forControlEvents:UIControlEventTouchUpInside]; [self.stack addArrangedSubview:diagnostics];
    [self.stack addArrangedSubview:[self label:@"0.1.1-alpha · Диагностическая сборка · Проверка на устройстве ещё требуется" detail:YES]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:DNUpdate object:nil]; [self refresh];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh {
    DNVOTController *c = DNVOTController.shared; self.statusLabel.text = c.statusText;
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
- (void)copyDiagnostics { UIPasteboard.generalPasteboard.string = [DNVOTController.shared diagnostics]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
