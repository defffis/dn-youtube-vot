#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface DNVOTPreferences : NSObject
+ (instancetype)shared;
@property(nonatomic,readonly) NSString *transport; // computed from proxyMode
@property(nonatomic,copy) NSString *serverURL;
@property(nonatomic,copy) NSString *workerURL;
@property(nonatomic,copy) NSString *mediaProxyURL;
@property(nonatomic) NSInteger proxyMode; // 0 direct, 1 API worker, 2 API + Yandex audio
@property(nonatomic) BOOL legacyWorker;
@property(nonatomic) BOOL lively;
@property(nonatomic,readonly) NSString *token;
@property(nonatomic,readonly) NSString *accountName;
@property(nonatomic,readonly) BOOL authenticated;
- (void)save;
- (BOOL)saveToken:(NSString *)token name:(NSString *)name expires:(NSTimeInterval)expires;
- (void)logout;
- (void)reset;
- (NSURL *)translationAudioURL:(NSURL *)url;
- (NSURL *)sourceMediaURL:(NSURL *)url;
- (NSString *)configurationKey;
+ (NSString *)normalizedServer:(NSString *)text;
@end
@interface DNVOTServiceSettings : UITableViewController
@end
@interface DNVOTAccountSettings : UITableViewController
@end
@interface DNVOTSettings : UITableViewController
@property(nonatomic) BOOL quick;
@end
@interface DNVOTDiagnosticSettings : UITableViewController
@end
NSString *DNLanguageCode(NSString *value);
