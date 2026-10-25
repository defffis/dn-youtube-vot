#import "DNVOT.h"
#import "Runtime.hpp"

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
        return ^(id obj, BOOL animated) { ((void (*)(id, SEL, BOOL))original)(obj, sel, animated); DNObserve(obj); };
    });
    count += DNHook(cls, @"playbackController:didActivateVideo:withPlaybackData:", 'v', "@@@", ^id(IMP original, SEL sel) {
        return ^(id obj, id controller, id video, id data) {
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
    if (count) NSLog(@"[DNVOT] 0.2.1-alpha installed %lu native hooks", (unsigned long)count);
}
