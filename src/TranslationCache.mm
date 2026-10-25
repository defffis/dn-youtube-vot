#import "TranslationCache.h"
#import <CommonCrypto/CommonDigest.h>
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
    NSURL *url=[self path:key];NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    if (![a[NSFileType] isEqual:NSFileTypeRegular] || [a[NSFileSize] unsignedLongLongValue]==0) return nil;
    if ([NSDate.date timeIntervalSinceDate:a[NSFileModificationDate]]>86400) { [NSFileManager.defaultManager removeItemAtURL:url error:nil];return nil; }
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:NSDate.date} ofItemAtPath:url.path error:nil];return url;
}
+ (NSURL *)store:(NSURL *)file key:(NSString *)key {
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
    [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:target.path error:nil];return target;
}
+ (unsigned long long)bytes {
    unsigned long long total=0;for (NSURL *p in [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:0 error:nil]) total+=[[NSFileManager.defaultManager attributesOfItemAtPath:p.path error:nil][NSFileSize] unsignedLongLongValue];return total;
}
+ (void)clear { for (NSURL *p in [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:0 error:nil]) [NSFileManager.defaultManager removeItemAtURL:p error:nil]; }
@end
