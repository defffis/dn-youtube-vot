#import "FlightRecorder.h"
#include <cmath>

static id DNJSONSafe(id value) {
    if ([value isKindOfClass:NSNumber.class]) return std::isfinite([value doubleValue]) ? value : NSNull.null;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *safe=[NSMutableDictionary new];for (id key in value) safe[key]=DNJSONSafe(value[key]);return safe;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *safe=[NSMutableArray new];for (id item in value) [safe addObject:DNJSONSafe(item)];return safe;
    }
    return value ?: NSNull.null;
}

@interface DNFlightRecorder ()
@property(atomic,readwrite) BOOL recording;
@property(atomic,readwrite,copy) NSString *state;
@property(nonatomic,strong) NSFileHandle *file;
@property(nonatomic,strong) NSURL *url;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic) NSUInteger bytes;
@property(nonatomic) double started;
@end
@implementation DNFlightRecorder
+ (instancetype)shared {
    static DNFlightRecorder *r; static dispatch_once_t once;
    dispatch_once(&once, ^{ r=[DNFlightRecorder new]; r.queue=dispatch_queue_create("dnvot.flight-recorder",DISPATCH_QUEUE_SERIAL); r.state=@"Лог ещё не записан"; });return r;
}
- (NSURL *)directory {
    NSURL *dir=[[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"DNVOT-Logs" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];return dir;
}
- (void)closeWithState:(NSString *)state {
    self.recording=NO; [self.file closeAndReturnError:nil]; self.file=nil; self.state=state;
}
- (void)writeEvent:(NSString *)event fields:(NSDictionary *)fields {
    if (!self.file) return;
    double elapsed=NSProcessInfo.processInfo.systemUptime-self.started;
    if (self.bytes>=12*1024*1024 || elapsed>=900) { [self closeWithState:@"Лог остановлен: достигнут лимит 15 минут / 12 МБ"];return; }
    NSDictionary *row=@{@"t":@(elapsed),@"event":event,@"fields":DNJSONSafe(fields ?: @{})};
    NSData *json=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingFragmentsAllowed error:nil];
    if (!json) return;
    NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];
    NSError *error=nil;
    if (![self.file writeData:line error:&error]) { [self closeWithState:@"Ошибка записи лога на диск"];return; }
    self.bytes+=line.length;
}
- (void)start {
    dispatch_async(self.queue, ^{
        if (self.recording) return;
        // Bound disk use: keep only the previous recording and this one.
        NSURL *dir=[self directory];
        for (NSURL *old in [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![old isEqual:self.url]) [NSFileManager.defaultManager removeItemAtURL:old error:nil];
        }
        NSURL *url=[dir URLByAppendingPathComponent:[NSString stringWithFormat:@"DNVOT-0.3.1-%@.jsonl",NSUUID.UUID.UUIDString]];
        if (![NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}]) { self.state=@"Не удалось создать лог";return; }
        self.file=[NSFileHandle fileHandleForWritingToURL:url error:nil];
        if (!self.file) { self.state=@"Не удалось открыть лог";return; }
        self.url=url;self.bytes=0;self.started=NSProcessInfo.processInfo.systemUptime;self.recording=YES;self.state=@"Запись лога идёт";
        [self writeEvent:@"recording_start" fields:@{@"version":@"0.3.1-alpha",@"utc":[[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date],@"privacy":@"No OAuth, URLs, account names, headers or audio. Video ID and playback telemetry included.",@"ios":NSProcessInfo.processInfo.operatingSystemVersionString,@"youtube":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—"}];
    });
}
- (void)stop {
    dispatch_async(self.queue, ^{ if (!self.file) return;[self writeEvent:@"recording_stop" fields:@{}];[self closeWithState:@"Лог остановлен, можно экспортировать"]; });
}
- (void)event:(NSString *)event fields:(NSDictionary *)fields {
    // Serialize on one background queue; never read UIKit/private player objects here.
    NSDictionary *snapshot=[fields copy];
    dispatch_async(self.queue, ^{ [self writeEvent:event fields:snapshot]; });
}
- (void)exportFile:(void (^)(NSURL *, NSString *))completion {
    dispatch_async(self.queue, ^{
        NSURL *copy=nil;NSString *error=nil;
        if (!self.url) error=@"Сначала запишите лог";
        else {
            NSError *flushError=nil;[self.file synchronizeAndReturnError:&flushError];
            if (flushError) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,@"Не удалось записать лог перед экспортом"); });return; }
            copy=[[self directory] URLByAppendingPathComponent:[NSString stringWithFormat:@"DNVOT-export-%@.jsonl",NSUUID.UUID.UUIDString]];
            if (![NSFileManager.defaultManager copyItemAtURL:self.url toURL:copy error:nil]) { copy=nil;error=@"Не удалось подготовить файл лога"; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(copy,error); });
    });
}
@end
