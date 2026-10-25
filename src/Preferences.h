#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface DNVOTPreferences : NSObject
+ (instancetype)shared;
@property(nonatomic,copy) NSString *transport; // direct or worker
@property(nonatomic,copy) NSString *serverURL;
@property(nonatomic) BOOL lively;
@property(nonatomic,readonly) NSString *token;
@property(nonatomic,readonly) NSString *accountName;
@property(nonatomic,readonly) BOOL authenticated;
- (void)save;
- (BOOL)saveToken:(NSString *)token name:(NSString *)name expires:(NSTimeInterval)expires;
- (void)logout;
- (NSString *)configurationKey;
+ (NSString *)normalizedServer:(NSString *)text;
@end
@interface DNVOTServiceSettings : UITableViewController
@end
@interface DNVOTAccountSettings : UITableViewController
@end
