#import <Foundation/Foundation.h>
@interface DNTranslationCache : NSObject
+ (NSURL *)find:(NSString *)key;
+ (NSURL *)store:(NSURL *)file key:(NSString *)key;
+ (void)clear;
+ (unsigned long long)bytes;
+ (void)pruneExpired;
+ (void)protect:(NSURL *)url;
@end
