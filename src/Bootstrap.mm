// The constructor only schedules work. All UIKit work waits for an active scene.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#ifndef DNVOT_PROBE
#import "DNVOT.h"
#import "Runtime.hpp"
#endif

static NSString *DNBootState = @"constructor scheduled";
static NSUInteger DNBootPasses;

static UIWindow *DNActiveWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.01 || window.windowLevel != UIWindowLevelNormal || !window.rootViewController) continue;
            if (window.isKeyWindow) return window;
            fallback = window;
        }
    }
    return fallback;
}

@interface DNVOTBootstrap : NSObject
@property(nonatomic,strong) UIButton *launcher;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL announced;
- (void)refresh;
- (void)open;
@end

#ifndef DNVOT_PROBE
NSString *DNVOTBootstrapDiagnostics(void) {
    return [NSString stringWithFormat:@"Bootstrap: %@\nPasses: %lu\nBundle: %@\nExecutable: %@\nPlayer class present: %@\nRoot: %@\nLibrary: %@",
        DNBootState, (unsigned long)DNBootPasses, NSBundle.mainBundle.bundleIdentifier,
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"],
        NSClassFromString(@"YTPlayerViewController") ? @"YES" : @"NO",
        NSStringFromClass(DNActiveWindow().rootViewController.class), @"DNYouTubeVOT 0.3.1-alpha"];
}

static void DNVisit(UIViewController *vc, DNVOTBootstrap *bootstrap, NSMutableSet *visited, NSUInteger depth, NSUInteger *budget) {
    if (!vc || depth > 16 || !*budget || [visited containsObject:vc]) return;
    --*budget; [visited addObject:vc];
    NSString *name = NSStringFromClass(vc.class);
    if (vc.isViewLoaded && vc.view.window && !vc.view.hidden) {
        Class playerClass = NSClassFromString(@"YTPlayerViewController");
        if (playerClass && [vc isKindOfClass:playerClass]) [DNVOTController.shared observePlayer:vc];

    }
    // UIKit containment plus the exact watch-controller accessors seen in 21.40.5.
    for (UIViewController *child in vc.childViewControllers) DNVisit(child, bootstrap, visited, depth + 1, budget);
    DNVisit(vc.presentedViewController, bootstrap, visited, depth + 1, budget);
    if ([name hasPrefix:@"YTWatch"]) {
        for (NSString *selector in @[@"playerViewController", @"currentWatchViewController"]) {
            id candidate = DNObject(vc, selector);
            if ([candidate isKindOfClass:UIViewController.class]) DNVisit(candidate, bootstrap, visited, depth + 1, budget);
        }
    }
}
#endif

@implementation DNVOTBootstrap
- (void)open {
    @try {
#ifdef DNVOT_PROBE
        UIViewController *vc = DNActiveWindow().rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc || [vc isKindOfClass:UIAlertController.class]) return;
        NSString *message = [NSString stringWithFormat:@"Библиотека загружена. Перехваты YouTube и перевод не включены.\n\niOS: %@\nBundle: %@\nExecutable: %@",
            UIDevice.currentDevice.systemVersion, NSBundle.mainBundle.bundleIdentifier,
            [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"]];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"DNVOT: тест загрузки" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
#else
        [DNVOTController.shared showPanel];
#endif
    } @catch (NSException *e) { DNBootState = [@"panel exception: " stringByAppendingString:e.reason ?: e.name]; NSLog(@"[DNVOT] %@", DNBootState); }
}
- (void)refresh {
    @autoreleasepool {
        @try {
            DNBootPasses++;
            UIWindow *window = DNActiveWindow();
            if (!window) { DNBootState = @"waiting for foreground window"; return; }
#ifndef DNVOT_PROBE
            [DNVOTController shared];
            DNVOTInstallHooks();
            DNVOTInstallNativeUI();
            NSUInteger budget = 128;
            DNVisit(window.rootViewController, self, [NSMutableSet new], 0, &budget);
            DNBootState = DNVOTController.shared.player ? @"foreground; player attached" : @"foreground; searching for player";
#else
            DNBootState = @"probe loaded; no engine or hooks";
#endif
#ifdef DNVOT_PROBE
            if (!self.launcher) {
                self.launcher = [UIButton buttonWithType:UIButtonTypeSystem];
                self.launcher.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.82];
                self.launcher.tintColor = UIColor.whiteColor;
                self.launcher.layer.cornerRadius = 18;
                self.launcher.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
                self.launcher.accessibilityLabel = @"Открыть панель VOT";
[self.launcher setTitle:@"VOT TEST" forState:UIControlStateNormal];
                [self.launcher addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
            }
            // This fallback belongs to the normal app window, not a separate overlay window.
            if (self.launcher.superview != window) { [self.launcher removeFromSuperview]; [window addSubview:self.launcher]; }
            CGFloat x = CGRectGetWidth(window.bounds) - window.safeAreaInsets.right - 106;
            CGFloat y = CGRectGetHeight(window.bounds) - window.safeAreaInsets.bottom - 106;
            self.launcher.frame = CGRectMake(MAX(8, x), MAX(window.safeAreaInsets.top, y), 98, 36);
            [window bringSubviewToFront:self.launcher];
            if (!self.announced) { self.announced = YES; [self open]; }
#endif
        } @catch (NSException *e) { DNBootState = [@"bootstrap exception: " stringByAppendingString:e.reason ?: e.name]; NSLog(@"[DNVOT] %@", DNBootState); }
    }
}
@end

__attribute__((constructor)) static void DNBootstrapLoad(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) return;
            static DNVOTBootstrap *bootstrap;
            bootstrap = [DNVOTBootstrap new];
            [bootstrap refresh];
            bootstrap.timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) { [bootstrap refresh]; }];
            bootstrap.timer.tolerance = 0.15;
            [NSRunLoop.mainRunLoop addTimer:bootstrap.timer forMode:NSRunLoopCommonModes];
        }
    });
}
