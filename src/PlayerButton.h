#import <UIKit/UIKit.h>

@interface DNVOTPlayerButton : UIButton
@property(nonatomic) CGFloat glyphOffsetY;
- (void)updateLoading:(BOOL)loading progress:(double)progress;
@end
