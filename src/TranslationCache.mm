#import "TranslationCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "FlightRecorder.h"
#include "CachePolicy.hpp"
static NSURL *DNProtectedCacheFile;
@implementation DNTranslationCache
+ (NSURL *)directory {
    NSURL *dir=[[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"DNVOT-Audio" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];return dir;
}
+ (NSURL *)path:(NSString *)key {
    NSData *data=[key dataUsingEncoding:NSUTF8StringEncoding];unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    NSMutableString *name=[NSMutableString new];for (unsigned char b:hash) [name appendFormat:@"%02x",b];
    return [[self directory] URLByAppendingPathComponent:[name stringByAppendingString:@".mp3"]];
}
+ (NSURL *)find:(NSString *)key {
    [self pruneExpired];
    NSURL *url=[self path:key];NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (![a[NSFileType] isEqual:NSFileTypeRegular] || [a[NSFileSize] unsignedLongLongValue]==0) return nil;
    if (dnvot::cacheExpired(NSDate.date.timeIntervalSince1970,[a[NSFileCreationDate] timeIntervalSince1970],[a[NSFileModificationDate] timeIntervalSince1970])) return nil;
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:NSDate.date} ofItemAtPath:url.path error:nil];return url;
}
+ (NSURL *)store:(NSURL *)file key:(NSString *)key {
    [self pruneExpired];
    NSURL *target=[self path:key];NSFileManager *fm=NSFileManager.defaultManager;
    NSArray *files=[fm contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:0 error:nil];
    files=[files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b) {
        NSDate *x=[fm attributesOfItemAtPath:a.path error:nil][NSFileModificationDate];NSDate *y=[fm attributesOfItemAtPath:b.path error:nil][NSFileModificationDate];return [x compare:y];
    }];
    unsigned long long incoming=[[fm attributesOfItemAtPath:file.path error:nil][NSFileSize] unsignedLongLongValue];
    unsigned long long used=[self bytes];
    for (NSURL *old in files) {
        if (used+incoming<=128ull*1024*1024 && ![old isEqual:target]) continue;
        unsigned long long size=[[fm attributesOfItemAtPath:old.path error:nil][NSFileSize] unsignedLongLongValue];
        if ([fm removeItemAtURL:old error:nil]) used=used>=size ? used-size : 0;
    }
    if (![fm moveItemAtURL:file toURL:target error:nil]) return file;
    NSDate *saved=NSDate.date;
    [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication,NSFileCreationDate:saved,NSFileModificationDate:saved} ofItemAtPath:target.path error:nil];return target;
}
+ (unsigned long long)bytes {
    [self pruneExpired];
    unsigned long long total=0;for (NSURL *p in [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:0 error:nil]) total+=[[NSFileManager.defaultManager attributesOfItemAtPath:p.path error:nil][NSFileSize] unsignedLongLongValue];return total;
}
+ (void)clear { for (NSURL *p in [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:0 error:nil]) [NSFileManager.defaultManager removeItemAtURL:p error:nil]; }
+ (void)protect:(NSURL *)url { DNProtectedCacheFile=url; }
+ (void)pruneExpired {
    NSFileManager *fm=NSFileManager.defaultManager;NSUInteger removed=0,failed=0;
    double now=NSDate.date.timeIntervalSince1970;
    for (NSURL *url in [fm contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:0 error:nil]) {
        if (![url.pathExtension isEqual:@"mp3"]) continue;
        NSDictionary *a=[fm attributesOfItemAtPath:url.path error:nil];
        if (![a[NSFileType] isEqual:NSFileTypeRegular]) continue;
        BOOL active=[url.path isEqual:DNProtectedCacheFile.path];
        if (!dnvot::cacheMayDelete(now,[a[NSFileCreationDate] timeIntervalSince1970],[a[NSFileModificationDate] timeIntervalSince1970],active)) continue;
        if ([fm removeItemAtURL:url error:nil]) removed++;else failed++;
    }
    if (removed || failed) [DNFlightRecorder.shared event:@"cache_cleanup" fields:@{@"removed":@(removed),@"failed":@(failed),@"ttl_seconds":@(dnvot::cacheTTL)}];
}
@end
