#import "DNVOT.h"
#import "Runtime.hpp"

static BOOL DNHook(Class cls, NSString *name, char result, const char *args, id (^factory)(IMP, SEL)) {
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
    return YES;
}
static void DNObserve(id obj) {
    __weak id weak = obj;
    dispatch_async(dispatch_get_main_queue(), ^{ if (weak) [DNVOTController.shared observePlayer:weak]; });
}
void DNVOTInstallHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = NSClassFromString(@"YTPlayerViewController");
    if (!cls) return;
    installed = YES;
    NSUInteger count = 0;
    count += DNHook(cls, @"viewDidAppear:", 'v', "B", ^id(IMP original, SEL sel) {
        return ^(id obj, BOOL animated) { ((void (*)(id, SEL, BOOL))original)(obj, sel, animated); DNObserve(obj); };
    });
    count += DNHook(cls, @"loadView", 'v', "", ^id(IMP original, SEL sel) {
        return ^(id obj) { ((void (*)(id, SEL))original)(obj, sel); DNObserve(obj); };
    });
    count += DNHook(cls, @"playbackController:didActivateVideo:withPlaybackData:", 'v', "@@@", ^id(IMP original, SEL sel) {
        return ^(id obj, id controller, id video, id data) {
            ((void (*)(id, SEL, id, id, id))original)(obj, sel, controller, video, data); DNObserve(obj);
        };
    });
    count += DNHook(cls, @"currentVideoID", '@', "", ^id(IMP original, SEL sel) {
        return ^id(id obj) {
            id value = ((id (*)(id, SEL))original)(obj, sel);
            if (!NSThread.isMainThread || DNVOTController.shared.player != obj) DNObserve(obj);
            return value;
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
    NSLog(@"[DNVOT] 0.1.0-alpha loaded; native hooks: %lu; no third-party tweak dependency", (unsigned long)count);
}
__attribute__((constructor)) static void DNVOTLoad(void) {
    if (![[NSBundle.mainBundle.executablePath lastPathComponent] isEqualToString:@"YouTube"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [DNVOTController shared]; DNVOTInstallHooks();
    });
}
