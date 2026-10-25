#import <Foundation/Foundation.h>

@interface DNLocalAudioDownload : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic,copy) void (^completion)(NSURL *, NSString *);
@property(nonatomic,copy) void (^progress)(int64_t, int64_t);
- (void)start:(NSURL *)url;
- (void)cancel;
@end
