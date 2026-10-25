#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <cmath>
#include <cstring>

static inline const char *DNType(const char *t) {
    while (t && *t && strchr("rnNoORV", *t)) ++t;
    return t ?: "";
}
static inline BOOL DNMethod(id obj, SEL sel, char result, unsigned args = 2) {
    if (!obj) return NO;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != args) return NO;
    char type[128]; method_getReturnType(m, type, sizeof(type));
    return *DNType(type) == result;
}
static inline id DNObject(id obj, NSString *name) {
    SEL s = NSSelectorFromString(name);
    if (!DNMethod(obj, s, '@')) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, s); }
    @catch (__unused NSException *e) { return nil; }
}
static inline double DNNumber(id obj, NSString *name, double fallback = 0) {
    SEL s = NSSelectorFromString(name);
    Method m = obj ? class_getInstanceMethod(object_getClass(obj), s) : nullptr;
    if (!m || method_getNumberOfArguments(m) != 2) return fallback;
    char t[128]; method_getReturnType(m, t, sizeof(t));
    @try {
        double v;
        switch (*DNType(t)) {
            case 'd': v = ((double (*)(id, SEL))objc_msgSend)(obj, s); break;
            case 'f': v = ((float (*)(id, SEL))objc_msgSend)(obj, s); break;
            case 'q': v = ((long long (*)(id, SEL))objc_msgSend)(obj, s); break;
            case 'Q': v = ((unsigned long long (*)(id, SEL))objc_msgSend)(obj, s); break;
            case 'i': v = ((int (*)(id, SEL))objc_msgSend)(obj, s); break;
            case 'B': case 'c': v = ((BOOL (*)(id, SEL))objc_msgSend)(obj, s); break;
            default: return fallback;
        }
        return std::isfinite(v) ? v : fallback;
    } @catch (__unused NSException *e) { return fallback; }
}
static inline BOOL DNSetVolume(id obj, float v) {
    SEL s = NSSelectorFromString(@"setVolume:");
    if (!DNMethod(obj, s, 'v', 3)) return NO;
    Method m = class_getInstanceMethod(object_getClass(obj), s);
    char t[32]; method_getArgumentType(m, 2, t, sizeof(t));
    if (*DNType(t) != 'f') return NO;
    @try { ((void (*)(id, SEL, float))objc_msgSend)(obj, s, v); return YES; }
    @catch (__unused NSException *e) { return NO; }
}
static inline NSString *DNString(id value) { return [value isKindOfClass:NSString.class] ? value : nil; }
static inline BOOL DNVideoID(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 11) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet]].location == NSNotFound;
}
