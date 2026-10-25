#import "LocalAudio.h"
#import "FlightRecorder.h"

static const int64_t DNLocalLimit=128*1024*1024;
@interface DNLocalAudioDownload ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDownloadTask *task;
@property(nonatomic) BOOL finished;
@end
@implementation DNLocalAudioDownload
- (void)finish:(NSURL *)url error:(NSString *)error {
    if (self.finished) return;self.finished=YES;
    [DNFlightRecorder.shared event:@"audio_download_finish" fields:@{@"ok":@(url!=nil),@"reason":error ?: @""}];
    if (self.completion) self.completion(url,error);
    self.completion=nil;self.progress=nil;
    [self.session invalidateAndCancel];self.session=nil;self.task=nil;
}
- (void)start:(NSURL *)url {
    if (![url.scheme.lowercaseString isEqual:@"https"]) { [self finish:nil error:@"Нужен HTTPS-файл перевода"];return; }
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;
    config.timeoutIntervalForRequest=40;config.timeoutIntervalForResource=240;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.task=[self.session downloadTaskWithURL:url];[self.task resume];
    [DNFlightRecorder.shared event:@"audio_download_start" fields:@{}];
}
- (void)cancel { self.completion=nil;[self finish:nil error:nil]; }
- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    completion([request.URL.scheme.lowercaseString isEqual:@"https"] ? request : nil);
}
- (void)URLSession:(__unused NSURLSession *)session downloadTask:(__unused NSURLSessionDownloadTask *)task didWriteData:(__unused int64_t)bytes totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    if (total>DNLocalLimit || expected>DNLocalLimit) { [self finish:nil error:@"Файл перевода превышает 128 МБ"];return; }
    if (self.progress) self.progress(total,expected);
}
- (void)URLSession:(__unused NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)url {
    NSHTTPURLResponse *http=(NSHTTPURLResponse *)task.response;
    NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [DNFlightRecorder.shared event:@"audio_download_response" fields:@{@"http":@([http isKindOfClass:NSHTTPURLResponse.class] ? http.statusCode : 0),@"bytes":size ?: @0}];
    // A full file is required for local sample decoding and arbitrary seeking.
    if (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode!=200 || size.longLongValue<=0 || size.longLongValue>DNLocalLimit || (http.expectedContentLength>0 && size.longLongValue!=http.expectedContentLength)) {
        [self finish:nil error:@"Сервер не отдал полный файл перевода (HTTP 200)"];return;
    }
    NSURL *local=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"DNVOT-audio-%@.mp3",NSUUID.UUID.UUIDString]]];
    if (![NSFileManager.defaultManager moveItemAtURL:url toURL:local error:nil]) { [self finish:nil error:@"Не удалось сохранить файл перевода"];return; }
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:local.path error:nil];
    [self finish:local error:nil];
}
- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && !self.finished) {
        [DNFlightRecorder.shared event:@"audio_download_error" fields:@{@"domain":error.domain,@"code":@(error.code)}];
        [self finish:nil error:[NSString stringWithFormat:@"Ошибка загрузки озвучки (%ld)",(long)error.code]];
    }
}
@end
