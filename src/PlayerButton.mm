#import "PlayerButton.h"
#import <QuartzCore/QuartzCore.h>
#include <cmath>

@interface DNVOTPlayerButton ()
@property(nonatomic,strong) CAShapeLayer *wave;
@property(nonatomic,strong) CAShapeLayer *track;
@property(nonatomic,strong) CAShapeLayer *arc;
@property(nonatomic) BOOL loading;
@property(nonatomic) double progress;
- (void)refreshAnimation;
- (void)refreshColors;
@end

@implementation DNVOTPlayerButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.wave=[CAShapeLayer layer];self.track=[CAShapeLayer layer];self.arc=[CAShapeLayer layer];
        for (CAShapeLayer *shape in @[self.wave,self.track,self.arc]) {
            shape.fillColor=UIColor.clearColor.CGColor;
            shape.lineWidth=1.8;shape.lineCap=kCALineCapRound;
            shape.contentsScale=UIScreen.mainScreen.scale;
            [self.layer addSublayer:shape];
        }
        self.progress=-1;
        self.track.hidden=YES;self.arc.hidden=YES;
        self.isAccessibilityElement=YES;
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        for (NSString *name in @[UIApplicationDidEnterBackgroundNotification,UIApplicationDidBecomeActiveNotification,UIAccessibilityReduceMotionStatusDidChangeNotification])
            [center addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
        [self refreshColors];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (CGSize)intrinsicContentSize { return self.bounds.size; }
- (CGSize)sizeThatFits:(__unused CGSize)size { return self.bounds.size; }
- (BOOL)pointInside:(CGPoint)point withEvent:(__unused UIEvent *)event {
    CGRect hit=CGRectInset(self.bounds,-fmax(0,(44-CGRectGetWidth(self.bounds))/2),-fmax(0,(44-CGRectGetHeight(self.bounds))/2));
    return CGRectContainsPoint(hit,point);
}
- (void)setGlyphOffsetY:(CGFloat)value {
    value=std::isfinite(value) ? fmax(-8,fmin(8,value)) : 0;
    if (fabs(_glyphOffsetY-value)<0.01) return;
    _glyphOffsetY=value;[self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGFloat x=CGRectGetMidX(self.bounds),y=CGRectGetMidY(self.bounds)+self.glyphOffsetY;
    UIBezierPath *wave=[UIBezierPath bezierPath];
    const CGFloat heights[]={6,12,20,12,6};
    for (NSUInteger i=0;i<5;i++) {
        CGFloat left=x+(CGFloat(i)-2)*4;
        [wave moveToPoint:CGPointMake(left,y-heights[i]/2)];
        [wave addLineToPoint:CGPointMake(left,y+heights[i]/2)];
    }
    self.wave.frame=self.bounds;self.wave.path=wave.CGPath;
    CGRect ring=CGRectMake(0,0,24,24);
    UIBezierPath *path=[UIBezierPath bezierPathWithArcCenter:CGPointMake(12,12) radius:10 startAngle:-M_PI_2 endAngle:3*M_PI_2 clockwise:YES];
    for (CAShapeLayer *shape in @[self.track,self.arc]) {
        shape.bounds=ring;shape.position=CGPointMake(x,y);shape.path=path.CGPath;
    }
    [CATransaction commit];
    [self refreshAnimation];
}
- (void)refreshColors {
    if (!self.wave) return;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    UIColor *color=self.tintColor ?: UIColor.whiteColor;
    self.wave.strokeColor=color.CGColor;self.arc.strokeColor=color.CGColor;
    self.track.strokeColor=[color colorWithAlphaComponent:0.22].CGColor;
    self.wave.opacity=self.highlighted ? 0.55 : 1;
    self.arc.opacity=self.highlighted ? 0.55 : 1;
    [CATransaction commit];
}
- (void)tintColorDidChange { [super tintColorDidChange];[self refreshColors]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted];[self refreshColors]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden];[self refreshAnimation]; }
- (void)setAlpha:(CGFloat)alpha { [super setAlpha:alpha];[self refreshAnimation]; }
- (void)didMoveToWindow { [super didMoveToWindow];[self refreshAnimation]; }
- (void)environmentChanged:(__unused NSNotification *)notification { [self refreshAnimation]; }
- (void)refreshAnimation {
    if (!self.arc) return;
    BOOL visible=self.window!=nil;
    for (UIView *view=self;view;view=view.superview) {
        if (view.hidden || view.alpha<0.01) { visible=NO;break; }
    }
    BOOL animate=self.loading && self.progress<0 && visible && !UIAccessibilityIsReduceMotionEnabled() && UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    if (!animate) {
        if ([self.arc animationForKey:@"DNVOT.LoadingRotation"]) [self.arc removeAnimationForKey:@"DNVOT.LoadingRotation"];
        return;
    }
    if ([self.arc animationForKey:@"DNVOT.LoadingRotation"]) return;
    CABasicAnimation *rotation=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rotation.fromValue=@0;rotation.toValue=@(2*M_PI);rotation.duration=1.1;rotation.repeatCount=HUGE_VALF;
    [self.arc addAnimation:rotation forKey:@"DNVOT.LoadingRotation"];
}
- (void)updateLoading:(BOOL)loading progress:(double)progress {
    self.loading=loading;
    self.progress=std::isfinite(progress) && progress>=0 ? fmin(progress,0.99) : -1;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.wave.hidden=loading;self.track.hidden=!loading;self.arc.hidden=!loading;
    self.arc.strokeStart=0;self.arc.strokeEnd=self.progress<0 ? 0.25 : self.progress;
    [CATransaction commit];
    [self refreshColors];[self refreshAnimation];
}
@end
