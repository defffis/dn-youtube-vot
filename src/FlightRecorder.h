#import <Foundation/Foundation.h>

// Only structured, explicitly selected telemetry. No URLs, headers, tokens or audio.
@interface DNFlightRecorder : NSObject
+ (instancetype)shared;
@property(atomic,readonly) BOOL recording;
@property(atomic,readonly,copy) NSString *state;
- (void)start;
- (void)stop;
- (void)event:(NSString *)event fields:(NSDictionary *)fields;
- (void)exportFile:(void (^)(NSURL *, NSString *))completion;
@end
