#import "DNVOT.h"
#import "Preferences.h"
#import "FlightRecorder.h"
#import <CommonCrypto/CommonHMAC.h>
#include "VOTWire.hpp"
#include <algorithm>

static NSString *const DNComponent = @"26.10.0.1796";
static NSString *const DNUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 YaBrowser/26.8.0.0 Safari/537.36";
static const NSUInteger DNMaxAudio = 32 * 1024 * 1024;
static NSData *DNData(const dnvot::Bytes &b) { return [NSData dataWithBytes:b.data() length:b.size()]; }
static std::string DNUTF8(NSString *s) { return s.UTF8String ?: ""; }
static NSString *DNText(const std::string &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
static NSString *DNSign(NSData *data) {
    const char *key = "bt8xH3VOlb4mqf0nqAibnDOoiPlXsisf";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), data.bytes, data.length, digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:64];
    for (unsigned char c : digest) [out appendFormat:@"%02x", c];
    return out;
}

@interface DNAudioDownload : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDownloadTask *task;
@property(nonatomic,copy) void (^completion)(NSData *, NSString *);
@property(nonatomic,copy) void (^progress)(double);
@property(nonatomic) BOOL completed;
- (void)start:(NSURL *)url;
- (void)cancel;
@end
@implementation DNAudioDownload
- (void)finish:(NSData *)data error:(NSString *)error {
    if (self.completed) return;
    self.completed = YES;
    if (self.completion) self.completion(data, error);
    self.completion = nil; self.progress = nil;
    [self.session invalidateAndCancel]; self.task = nil; self.session = nil;
}
- (void)start:(NSURL *)url {
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.timeoutIntervalForRequest = 40; c.timeoutIntervalForResource = 120;
    c.HTTPCookieStorage = nil; c.HTTPShouldSetCookies = NO;
    self.session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    self.task = [self.session downloadTaskWithRequest:request]; [self.task resume];
}
- (void)cancel { [self finish:nil error:@"Загрузка отменена"]; }
- (void)URLSession:(__unused NSURLSession *)session downloadTask:(__unused NSURLSessionDownloadTask *)task didWriteData:(__unused int64_t)bytes totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    if (total > (int64_t)DNMaxAudio || expected > (int64_t)DNMaxAudio) {
        [self finish:nil error:@"Исходное аудио превышает 32 МБ"]; return;
    }
    if (self.progress && expected > 0) self.progress((double)total / expected);
}
- (void)URLSession:(__unused NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)url {
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)task.response;
    if (![response isKindOfClass:NSHTTPURLResponse.class]) { [self finish:nil error:@"YouTube не отдал HTTP-аудиопоток"]; return; }
    BOOL fullResponse=response.statusCode==200;
    if (response.statusCode==206) {
        unsigned long long first=1,last=0,total=0;
        NSString *range=[response valueForHTTPHeaderField:@"Content-Range"];
        fullResponse=range && sscanf(range.UTF8String,"bytes %llu-%llu/%llu",&first,&last,&total)==3 && first==0 && total>0 && last==total-1 && total<=DNMaxAudio;
    }
    if (!fullResponse) { [self finish:nil error:[NSString stringWithFormat:@"YouTube не отдал полный аудиопоток (HTTP %ld)",(long)response.statusCode]]; return; }
    NSNumber *size = nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue > DNMaxAudio) { [self finish:nil error:@"Исходное аудио превышает 32 МБ"]; return; }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (response.statusCode==206 && response.expectedContentLength>0 && data.length!=(NSUInteger)response.expectedContentLength) { [self finish:nil error:@"Исходный аудиопоток загрузился не полностью"];return; }
    if (!data.length || data.length > DNMaxAudio) { [self finish:nil error:@"Не удалось прочитать исходное аудио"]; return; }
    [self finish:data error:nil];
}
- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) [self finish:nil error:[NSString stringWithFormat:@"Source download network error %ld",(long)error.code]];
}
@end

@interface DNVOTClient ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableSet<NSURLSessionTask *> *tasks;
@property(nonatomic,strong) DNAudioDownload *download;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,copy) NSString *uuid;
@property(nonatomic,copy) NSString *secret;
@property(nonatomic) NSTimeInterval sessionExpiry;
@property(nonatomic,copy) NSString *videoURL;
@property(nonatomic,copy) NSString *from;
@property(nonatomic,copy) NSString *to;
@property(nonatomic,strong) NSURL *sourceURL;
@property(nonatomic) NSInteger itag;
@property(nonatomic) double duration;
@property(nonatomic) NSInteger attempts;
@property(nonatomic) BOOL attemptedAudio;
@property(nonatomic) BOOL usedServerFallback;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic,copy) NSString *lastAudio;
@property(nonatomic,copy) NSString *host;
@property(nonatomic,copy) NSString *transport;
@property(nonatomic,copy) NSString *apiToken;
@property(nonatomic) BOOL lively;
@property(nonatomic) BOOL legacyWorker;
@property(nonatomic,strong) NSMutableArray<NSString *> *trace;
@property(nonatomic,copy) NSString *sourceFailure;
@end
@interface DNVOTNoRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation DNVOTNoRedirect
- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response newRequest:(__unused NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion { completion(nil); }
@end
@implementation DNVOTClient
- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 120;
        config.HTTPCookieStorage = nil; config.HTTPShouldSetCookies = NO;
        self.session = [NSURLSession sessionWithConfiguration:config delegate:[DNVOTNoRedirect new] delegateQueue:nil];
        self.tasks = [NSMutableSet set];
        self.trace = [NSMutableArray new];
    }
    return self;
}
- (void)cancel {
    self.generation++;
    self.apiToken = nil;
    for (NSURLSessionTask *task in self.tasks) [task cancel];
    [self.tasks removeAllObjects];
    [self.download cancel]; self.download = nil;
}
- (void)traceEvent:(NSString *)event { [DNFlightRecorder.shared event:@"vot_network" fields:@{@"summary":event}]; [self.trace addObject:event];if (self.trace.count>14) [self.trace removeObjectAtIndex:0]; }
- (NSString *)diagnostics {
    return [NSString stringWithFormat:@"Transport: %@\nServer: %@\nLively requested: %@\nSource URL available: %@\nSource itag: %ld\nSource failure: %@\nNetwork trace (last requested video):\n%@",self.transport ?: @"—",self.host ?: @"—",self.lively ? @"YES" : @"NO",self.sourceURL ? @"YES" : @"NO",(long)self.itag,self.sourceFailure ?: @"—",[[self.trace componentsJoinedByString:@"\n"] stringByAppendingFormat:@"\nNetwork trace video: %@\nProxy mode: %ld\nWorker protocol: %@\nSource media proxy: %@",self.videoURL.lastPathComponent ?: @"—",(long)DNVOTPreferences.shared.proxyMode,self.legacyWorker ? @"legacy JSON" : @"modern X-VOT-Headers",DNVOTPreferences.shared.mediaProxyURL.length ? @"configured" : @"off"]];
}
- (void)request:(NSString *)path body:(NSData *)body signedRequest:(BOOL)signedRequest method:(NSString *)method json:(BOOL)json completion:(void (^)(NSData *, NSString *))completion {
    NSUInteger generation = self.generation;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self.host stringByAppendingString:path]]];
    request.HTTPMethod = method; request.HTTPBody = body;
    [request setValue:DNUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:json ? @"application/json" : @"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:json ? @"application/json" : @"application/x-protobuf" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [request setValue:@"en" forHTTPHeaderField:@"Accept-Language"];
    if (!json) [request setValue:DNSign(body) forHTTPHeaderField:@"Vtrans-Signature"];
    if (signedRequest) {
        NSString *token = [NSString stringWithFormat:@"%@:%@:%@", self.uuid, path, DNComponent];
        [request setValue:self.secret forHTTPHeaderField:@"Sec-Vtrans-Sk"];
        [request setValue:[NSString stringWithFormat:@"%@:%@", DNSign([token dataUsingEncoding:NSUTF8StringEncoding]), token] forHTTPHeaderField:@"Sec-Vtrans-Token"];
    }
    if (self.lively && [path isEqual:@"/video-translation/translate"] && self.apiToken.length) [request setValue:[@"OAuth " stringByAppendingString:self.apiToken] forHTTPHeaderField:@"Authorization"];
    if ([self.transport isEqual:@"worker"]) {
        NSDictionary *headers=request.allHTTPHeaderFields;
        if (self.legacyWorker) {
            if (body.length>8*1024*1024) { completion(nil,@"Legacy Worker: тело запроса больше 8 МБ. Используйте современный Worker.");return; }
            id payload=nil;
            if (json) payload=[NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingFragmentsAllowed error:nil];
            else { NSMutableArray *bytes=[NSMutableArray arrayWithCapacity:body.length];const uint8_t *p=(const uint8_t *)body.bytes;for (NSUInteger i=0;i<body.length;i++) [bytes addObject:@(p[i])];payload=bytes; }
            if (!payload) { completion(nil,@"Не удалось сформировать запрос Legacy Worker");return; }
            request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"headers":headers,@"body":payload} options:0 error:nil];
            request.allHTTPHeaderFields=@{@"Content-Type":@"application/json",@"Accept":json ? @"application/json" : @"application/x-protobuf"};
        } else {
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:headers options:0 error:nil];
            request.allHTTPHeaderFields=@{@"X-VOT-Headers":[encoded base64EncodedStringWithOptions:0],@"User-Agent":@"vot.js/3.2.0",@"Content-Type":json ? @"application/json" : @"application/x-protobuf"};
        }
    }
    [self traceEvent:[NSString stringWithFormat:@"%@ %@ bytes=%lu",method,path,(unsigned long)body.length]];
    __weak DNVOTClient *weakSelf = self;
    __block __weak NSURLSessionDataTask *weakTask;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DNVOTClient *strong = weakSelf;
            if (!strong) return;
            if (weakTask) [strong.tasks removeObject:weakTask];
            if (generation != strong.generation) return;
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (error) { [strong traceEvent:[NSString stringWithFormat:@"network code=%ld",(long)error.code]];completion(nil, [NSString stringWithFormat:@"Ошибка сети (%ld)", (long)error.code]); return; }
            [strong traceEvent:[NSString stringWithFormat:@"%@ HTTP %ld",path,[http isKindOfClass:NSHTTPURLResponse.class] ? (long)http.statusCode : 0L]];
            if (![http isKindOfClass:NSHTTPURLResponse.class] || http.statusCode != 200) {
                if (http.statusCode == 401 || http.statusCode == 403) { strong.secret = nil; strong.sessionExpiry = 0; }
                completion(nil, [NSString stringWithFormat:@"Сервис перевода вернул HTTP %ld", (long)http.statusCode]); return;
            }
            if (!data.length || data.length > 2 * 1024 * 1024) { completion(nil, @"Некорректный ответ сервиса перевода"); return; }
            completion(data, nil);
        });
    }];
    weakTask = task; [self.tasks addObject:task]; [task resume];
}
- (void)ensureSession:(void (^)(BOOL))completion {
    if (self.secret.length && self.sessionExpiry > NSDate.date.timeIntervalSince1970) { completion(YES); return; }
    self.uuid = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
    NSData *body = DNData(dnvot::session(DNUTF8(self.uuid)));
    [self request:@"/session/create" body:body signedRequest:NO method:@"POST" json:NO completion:^(NSData *data, NSString *error) {
        if (error) { if (self.failed) self.failed(error); completion(NO); return; }
        try {
            auto fields = dnvot::parse((const uint8_t *)data.bytes, data.length);
            self.secret = DNText(dnvot::text(fields, 1));
            NSUInteger expires = dnvot::value(fields, 2);
            if (!self.secret.length || expires < 1) throw std::runtime_error("Missing session");
            self.sessionExpiry = NSDate.date.timeIntervalSince1970 + std::max(1.0, (double)expires - 30);
            completion(YES);
        } catch (...) { if (self.failed) self.failed(@"Не удалось прочитать сессию перевода"); completion(NO); }
    }];
}
- (void)startVideo:(NSString *)videoID duration:(double)duration from:(NSString *)from to:(NSString *)to sourceAudio:(NSURL *)audioURL itag:(NSInteger)itag {
    [self cancel];
    DNVOTPreferences *prefs=DNVOTPreferences.shared;
    self.host=[DNVOTPreferences normalizedServer:prefs.proxyMode>0 ? prefs.workerURL : prefs.serverURL];self.transport=prefs.transport;self.legacyWorker=prefs.legacyWorker;
    self.lively=prefs.lively && prefs.proxyMode==0 && [self.host isEqual:@"https://api.browser.yandex.ru"];self.apiToken=nil;self.secret=nil;self.sessionExpiry=0;
    [self.trace removeAllObjects];self.sourceFailure=nil;
    if (prefs.lively && !self.lively) [self traceEvent:@"standard voice for selected route; no OAuth forwarded"];
    if (!self.host) {if (self.failed) self.failed(@"Некорректный HTTPS-сервер VOT");return;}
    if (self.lively) {
        if (![self.host isEqual:@"https://api.browser.yandex.ru"] || ![self.transport isEqual:@"direct"]) {if (self.failed) self.failed(@"Для живых голосов выберите «Яндекс напрямую». OAuth не отправляется стороннему серверу.");return;}
        self.apiToken=prefs.token;
        if (!self.apiToken.length) {if (self.failed) self.failed(@"Войдите в Яндекс в настройках VOT или выключите живые голоса.");return;}
    }
    self.videoURL = [@"https://youtu.be/" stringByAppendingString:videoID];
    self.duration = duration; self.from = from; self.to = to; self.sourceURL = audioURL; self.itag = itag;
    self.attempts = 0; self.attemptedAudio = NO; self.usedServerFallback = NO; self.lastAudio = nil;
    self.started = NSDate.date.timeIntervalSince1970;
    if (self.status) self.status(@"Подключение к сервису перевода…");
    [self poll];
}
- (void)later:(double)seconds {
    NSUInteger generation = self.generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(std::clamp(seconds, 3.0, 20.0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self.generation) [self poll];
    });
}
- (void)poll {
    if (NSDate.date.timeIntervalSince1970 - self.started > 15 * 60 || self.attempts > 200) {
        if (self.failed) self.failed(@"Перевод не готов за 15 минут. Попробуйте позже."); return;
    }
    [self ensureSession:^(BOOL ok) {
        if (!ok) return;
        // Match vot.js: the live API expects this flag on every poll.
        self.attempts++;
        BOOL first = YES;
        auto bytes = dnvot::translation(DNUTF8(self.videoURL), self.duration,
                                      DNUTF8([self.from isEqualToString:@"auto"] ? @"en" : self.from),
                                      DNUTF8(self.to), first, ![self.from isEqualToString:@"auto"],
                                      DNUTF8(self.sourceURL.absoluteString), self.lively);
        [self request:@"/video-translation/translate" body:DNData(bytes) signedRequest:YES method:@"POST" json:NO completion:^(NSData *data, NSString *error) {
            if (error) { if (self.failed) self.failed(error); return; }
            try {
                auto fields = dnvot::parse((const uint8_t *)data.bytes, data.length);
                NSInteger status = dnvot::value(fields, 4);
                [self traceEvent:[NSString stringWithFormat:@"VOT status=%ld retry=%llu",(long)status,(unsigned long long)dnvot::value(fields,12)]];
                double remaining = std::min(1200.0, (double)dnvot::value(fields, 5, 10));
                NSString *translationID = DNText(dnvot::text(fields, 7));
                if (status == 1 || status == 5) {
                    NSString *urlText = DNText(dnvot::text(fields, 1));
                    NSURL *url = [NSURL URLWithString:urlText];
                    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || url.user.length || url.password.length) throw std::runtime_error("Invalid audio URL");
                    if (![self.lastAudio isEqualToString:urlText]) {
                        self.lastAudio = urlText;
                        if (self.audioReady) self.audioReady(url, status == 5);
                    }
                    if (self.status) self.status(status == 5 ? @"Доступна часть перевода; остальная дорожка готовится…" : @"Перевод готов");
                    if (status == 5) [self later:remaining];
                } else if (status == 2 || status == 3) {
                    if (self.status) self.status([NSString stringWithFormat:@"Перевод готовится. Оценка сервиса: %.0f с", remaining]);
                    [self later:remaining];
                } else if (status == 6) {
                    if (!translationID.length) throw std::runtime_error("Missing translation ID");
                    if (!self.attemptedAudio) [self provideAudio:translationID];
                    else {
                        if (self.status) self.status(@"Сервис обрабатывает исходное аудио…");
                        [self later:remaining];
                    }
                } else if (status == 7) {
                    if (self.failed) self.failed(@"Яндекс требует вход. Откройте VOT → Аккаунт Яндекса.");
                } else {
                    NSString *message = DNText(dnvot::text(fields, 9));
                    if (message.length > 180) message = [message substringToIndex:180];
                    if (self.failed) self.failed(message.length ? [@"Яндекс: " stringByAppendingString:message] : @"Яндекс не смог перевести это видео");
                }
            } catch (...) { if (self.failed) self.failed(@"Формат ответа сервиса изменился или ответ повреждён"); }
        }];
    }];
}
- (void)uploadAudio:(NSData *)audio translation:(NSString *)translationID fallback:(BOOL)fallback {
    NSString *fileID;
    if (fallback) fileID = [@"fallback-empty-audio:video-translation:" stringByAppendingString:[self.videoURL lastPathComponent]];
    else {
        NSDictionary *metadata = @{ @"downloadType": @"web_api_get_all_generating_urls_data_from_iframe", @"itag": @(self.itag ?: 140), @"minChunkSize": @5295308, @"fileSize": [NSString stringWithFormat:@"%lu", (unsigned long)audio.length] };
        fileID = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil] encoding:NSUTF8StringEncoding];
    }
    auto bytes = dnvot::audio(DNUTF8(translationID), DNUTF8(self.videoURL), DNUTF8(fileID), (const uint8_t *)audio.bytes, audio.length);
    [self request:@"/video-translation/audio" body:DNData(bytes) signedRequest:YES method:@"PUT" json:NO completion:^(NSData *data, NSString *error) {
        if (error) {
            if (!fallback) [self serverFallback:translationID];
            else if (self.failed) self.failed(error);
            return;
        }
        try {
            auto fields = dnvot::parse((const uint8_t *)data.bytes, data.length);
            auto result = dnvot::value(fields, 1);
            if (result != 1 && result != 2) throw std::runtime_error("Audio rejected");
            if (self.status) self.status(fallback ? @"Яндекс получает аудио самостоятельно; это может занять несколько минут…" : @"Аудио передано. Подготовка перевода…");
            [self later:5];
        } catch (...) {
            if (!fallback) [self serverFallback:translationID];
            else if (self.failed) self.failed(@"Сервис не принял запрос исходного аудио");
        }
    }];
}
- (void)serverFallback:(NSString *)translationID {
    if (self.usedServerFallback) { if (self.failed) self.failed(@"Не удалось передать исходное аудио"); return; }
    self.usedServerFallback = YES;
    [self traceEvent:@"server audio fallback"];
    if (self.status) self.status(@"Прямой поток недоступен. Запрашивается серверное получение аудио…");
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"video_url": self.videoURL } options:0 error:nil];
    [self request:@"/video-translation/fail-audio-js" body:body signedRequest:NO method:@"PUT" json:YES completion:^(NSData *data, NSString *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (error || ![json isKindOfClass:NSDictionary.class] || [json[@"status"] integerValue] != 1) {
            if (self.failed) self.failed(error ?: @"Не удалось запросить серверное получение аудио"); return;
        }
        [self uploadAudio:NSData.data translation:translationID fallback:YES];
    }];
}
- (void)provideAudio:(NSString *)translationID {
    self.attemptedAudio = YES;
    NSString *host = self.sourceURL.host.lowercaseString;
    if (![self.sourceURL.scheme.lowercaseString isEqualToString:@"https"] || ![host hasSuffix:@".googlevideo.com"]) { self.sourceFailure=@"No supported googlevideo audio URL from native player";[self serverFallback:translationID]; return; }
    if (self.status) self.status(@"Загрузка исходного аудио для перевода…");
    self.download = [DNAudioDownload new];
    NSUInteger generation = self.generation;
    __weak DNVOTClient *weakSelf = self;
    self.download.progress = ^(double fraction) {
        DNVOTClient *strong = weakSelf;
        if (strong && strong.generation == generation && strong.status) strong.status([NSString stringWithFormat:@"Загрузка исходного аудио: %.0f%%", fraction * 100]);
    };
    self.download.completion = ^(NSData *audio, NSString *error) {
        DNVOTClient *strong = weakSelf;
        if (!strong || strong.generation != generation) return;
        strong.download = nil;
        if (error || !audio.length) { strong.sourceFailure=error ?: @"Empty source audio";[strong serverFallback:translationID]; return; }
        [strong traceEvent:[NSString stringWithFormat:@"source audio bytes=%lu",(unsigned long)audio.length]];
        if (strong.status) strong.status(@"Передача аудио сервису перевода…");
        [strong uploadAudio:audio translation:translationID fallback:NO];
    };
    [self.download start:[DNVOTPreferences.shared sourceMediaURL:self.sourceURL]];
}
@end
