#import "DNVOT.h"
#import "Runtime.hpp"
#import "FlightRecorder.h"
#include "PlayerPolicy.hpp"

static NSString *DNExcludedClass(id object) {
    for (Class cls=object_getClass(object);cls;cls=class_getSuperclass(cls)) {
        NSString *name=NSStringFromClass(cls);
        if (dnvot::excludedPlaybackClass(name.UTF8String ?: "")) return name;
    }
    return nil;
}
NSString *DNVOTUnsupportedPlayerContext(id player) {
    NSString *reason=DNExcludedClass(DNObject(player,@"activeVideoPlayerOverlay"));
    if (reason) return reason;
    UIViewController *vc=[player isKindOfClass:UIViewController.class] ? player : nil;
    for (NSUInteger depth=0;vc && depth<12;depth++,vc=vc.parentViewController) {
        reason=DNExcludedClass(vc);
        if (reason) return reason;
    }
    return nil;
}

static const void *DNIdentityKey=&DNIdentityKey;
NSString *DNVOTPlayerIdentifier(id object) {
    if (!object) return @"none";
    NSString *label=objc_getAssociatedObject(object,DNIdentityKey);
    if (!label) { static NSUInteger sequence=0;label=[NSString stringWithFormat:@"%@#%lu",NSStringFromClass([object class]),(unsigned long)++sequence];objc_setAssociatedObject(object,DNIdentityKey,label,OBJC_ASSOCIATION_COPY_NONATOMIC); }
    return label;
}
static void DNPlayerEvent(NSString *event,id object,id context) {
    if (!NSThread.isMainThread) {
        [DNFlightRecorder.shared event:event fields:@{@"class":NSStringFromClass([object class]),@"main_thread":@NO}];return;
    }
    [DNFlightRecorder.shared event:event fields:@{@"player":DNVOTPlayerIdentifier(object),@"context_class":context ? NSStringFromClass([context class]) : @"none",@"video":DNVOTController.shared.videoID ?: @"",@"translation_enabled":@(DNVOTController.shared.enabled)}];
}

BOOL DNVOTHook(Class cls, NSString *name, char result, const char *args, id (^factory)(IMP, SEL)) {
    if (!cls) return NO;
    static NSMutableSet<NSString *> *installed;
    if (!installed) installed = [NSMutableSet new];
    NSString *key = [NSString stringWithFormat:@"%@/%d/%@", NSStringFromClass(cls), class_isMetaClass(cls), name];
    if ([installed containsObject:key]) return NO;
    SEL sel = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != strlen(args) + 2) return NO;
    char type[64]; method_getReturnType(method, type, sizeof(type));
    if (*DNType(type) != result) return NO;
    for (unsigned i = 0; i < strlen(args); i++) {
        method_getArgumentType(method, i + 2, type, sizeof(type));
        if (*DNType(type) != args[i]) return NO;
    }
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(factory(original, sel));
    // Add a class-local override if the original implementation is inherited.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    }
    [installed addObject:key];
    return YES;
}
#define DNHook DNVOTHook
static void DNObserve(id obj) {
    __weak id weak = obj;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { if (weak) [DNVOTController.shared observePlayer:weak]; }
        @catch (NSException *e) { NSLog(@"[DNVOT] observe failed: %@", e.reason); }
    });
}
void DNVOTInstallHooks(void) {
    Class cls = NSClassFromString(@"YTPlayerViewController");
    if (!cls) return;
    NSUInteger count = 0;
    count += DNHook(cls, @"viewDidAppear:", 'v', "B", ^id(IMP original, SEL sel) {
        return ^(id obj, BOOL animated) { DNPlayerEvent(@"native_player_appeared",obj,nil); ((void (*)(id, SEL, BOOL))original)(obj, sel, animated); DNObserve(obj); };
    });
    count += DNHook(cls, @"playbackController:didActivateVideo:withPlaybackData:", 'v', "@@@", ^id(IMP original, SEL sel) {
        return ^(id obj, id controller, id video, id data) {
            DNPlayerEvent(@"native_video_activation",obj,video);
            ((void (*)(id, SEL, id, id, id))original)(obj, sel, controller, video, data); DNObserve(obj);
        };
    });
    count += DNHook(cls, @"play", 'v', "", ^id(IMP original, SEL sel) {
        return ^(id obj) {
            ((void (*)(id, SEL))original)(obj, sel);
            if (NSThread.isMainThread) [DNVOTController.shared playerResumed:obj];
            DNObserve(obj);
        };
    });
    count += DNHook(cls, @"pause", 'v', "", ^id(IMP original, SEL sel) {
        return ^(id obj) {
            ((void (*)(id, SEL))original)(obj, sel);
            if (NSThread.isMainThread) [DNVOTController.shared playerPaused:obj];
        };
    });
    count += DNHook(cls, @"pauseWithStoppageReason:", 'v', "i", ^id(IMP original, SEL sel) {
        return ^(id obj, int reason) {
            ((void (*)(id, SEL, int))original)(obj, sel, reason);
            if (NSThread.isMainThread) [DNVOTController.shared playerPaused:obj];
        };
    });
    count += DNHook(cls, @"setVolume:", 'v', "f", ^id(IMP original, SEL sel) {
        return ^(id obj, float volume) {
            float actual = NSThread.isMainThread ? [DNVOTController.shared incomingVolume:volume player:obj] : volume;
            ((void (*)(id, SEL, float))original)(obj, sel, actual);
        };
    });
    // Observe the native reload method; never initiate a reload from VOT.
    count += DNHook(NSClassFromString(@"YTSingleVideoController"), @"reloadPlayerWithContext:", 'v', "@", ^id(IMP original,SEL sel) {
        return ^(id obj,id context) { DNPlayerEvent(@"native_player_reload",obj,context);((void(*)(id,SEL,id))original)(obj,sel,context); };
    });
    if (count) NSLog(@"[DNVOT] 0.4.2 installed %lu native hooks", (unsigned long)count);
}
