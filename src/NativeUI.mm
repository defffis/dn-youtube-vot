#import "DNVOT.h"
#import "Runtime.hpp"
#import "Preferences.h"

static const NSUInteger DNCategory = 0x444e5654; // DNVT; independent settings category
static const void *DNButtonKey = &DNButtonKey;
static const void *DNOwnerKey = &DNOwnerKey;
static const void *DNMenuFooterKey = &DNMenuFooterKey;
static NSHashTable<UIButton *> *DNButtons;
static NSUInteger DNUIHooks;
static NSUInteger DNSettingsBuilt;
static NSUInteger DNPlayerMenus;
static NSUInteger DNLayoutPasses;
static NSTimeInterval DNMenuIntent;

static id DNAppendCategory(id raw) {
    if (![raw isKindOfClass:NSArray.class]) return raw;
    NSMutableArray *a=[raw mutableCopy];if (![a containsObject:@(DNCategory)]) [a addObject:@(DNCategory)];return a;
}
static BOOL DNSignature(id object, NSString *name, char result, const char *args) {
    SEL sel=NSSelectorFromString(name);Method m=object ? class_getInstanceMethod(object_getClass(object),sel) : nullptr;
    if (!m || method_getNumberOfArguments(m)!=strlen(args)+2) return NO;
    char type[128];method_getReturnType(m,type,sizeof(type));if (*DNType(type)!=result) return NO;
    for (unsigned i=0;i<strlen(args);i++) {method_getArgumentType(m,i+2,type,sizeof(type));if (*DNType(type)!=args[i]) return NO;}return YES;
}
static id DNIvarObject(id object, const char *name) {
    Ivar ivar=object ? class_getInstanceVariable(object_getClass(object),name) : nullptr;
    if (!ivar || *DNType(ivar_getTypeEncoding(ivar))!='@') return nil;
    return object_getIvar(object,ivar);
}

@interface DNVOTUIActions : NSObject
+ (instancetype)shared;
- (void)toggle;
- (void)settings;
- (void)hold:(UILongPressGestureRecognizer *)gesture;
@end
@implementation DNVOTUIActions
+ (instancetype)shared {static DNVOTUIActions *s;static dispatch_once_t once;dispatch_once(&once,^{s=[self new];});return s;}
- (void)toggle { [DNVOTController.shared toggleTranslation]; }
- (void)settings { [DNVOTController.shared showPanel]; }
- (void)hold:(UILongPressGestureRecognizer *)gesture { if (gesture.state==UIGestureRecognizerStateBegan) [self settings]; }
@end

@interface DNVOTButtonOwner : NSObject
@property(nonatomic,weak) UIView *overlay;
@property(nonatomic,copy) NSString *reference;
@end
@implementation DNVOTButtonOwner
@end

@interface DNVOTPlayerButton : UIButton
@end
@implementation DNVOTPlayerButton
- (CGSize)intrinsicContentSize { return CGSizeMake(44,44); }
- (CGSize)sizeThatFits:(__unused CGSize)size { return CGSizeMake(44,44); }
@end

static UIView *DNReference(id overlay, NSString **selector) {
    for (NSString *name in @[@"overflowButton",@"closedCaptionsOrSubtitlesButton",@"playbackRouteButton"]) {
        id view=DNObject(overlay,name);
        if ([view isKindOfClass:UIView.class] && [(UIView *)view isDescendantOfView:overlay]) {
            if (selector) *selector=name;
            return view;
        }
    }
    return nil;
}
static UIButton *DNControlsButton(id overlay) {
    UIButton *button=objc_getAssociatedObject(overlay,DNButtonKey);
    if (button) return button;
    if (![overlay isKindOfClass:UIView.class]) return nil;
    // Native layout reads each control's current width/height; it does not sizeToFit.
    // Keep sizing/image/visibility under our control rather than YTQTMButton internals.
    button=[[DNVOTPlayerButton alloc] initWithFrame:CGRectMake(0,0,44,44)];
    button.autoresizingMask=UIViewAutoresizingNone;
    button.translatesAutoresizingMaskIntoConstraints=YES;
    button.accessibilityIdentifier=@"DNVOT.PlayerToggle";
    button.backgroundColor=UIColor.clearColor;
    button.tintColor=UIColor.whiteColor;
    button.titleLabel.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth=YES;
    button.imageView.contentMode=UIViewContentModeScaleAspectFit;
    button.exclusiveTouch=YES;
    [button addTarget:DNVOTUIActions.shared action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *hold=[[UILongPressGestureRecognizer alloc] initWithTarget:DNVOTUIActions.shared action:@selector(hold:)];hold.minimumPressDuration=0.55;[button addGestureRecognizer:hold];
    UIView *reference=DNReference(overlay,nil);
    id container=DNObject(overlay,@"topControlsAccessibilityContainerView");
    if (![container isKindOfClass:UIView.class]) container=reference.superview;
    if (![container isKindOfClass:UIView.class]) container=overlay;
    [(UIView *)container addSubview:button];
    DNVOTButtonOwner *owner=[DNVOTButtonOwner new];owner.overlay=overlay;
    objc_setAssociatedObject(button,DNOwnerKey,owner,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay,DNButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!DNButtons) DNButtons=[NSHashTable weakObjectsHashTable];[DNButtons addObject:button];
    [DNVOTController.shared updateControlsButton:button];
    button.alpha=reference ? reference.alpha : (DNNumber(overlay,@"isOverlayVisible") ? 1 : 0);
    return button;
}
static void DNRefreshButton(UIView *overlay, BOOL requestLayout) {
    UIButton *button=objc_getAssociatedObject(overlay,DNButtonKey);
    if (!button) return;
    DNVOTButtonOwner *owner=objc_getAssociatedObject(button,DNOwnerKey);
    NSString *name=nil;UIView *reference=DNReference(overlay,&name);owner.reference=name;
    id rawHost=DNObject(overlay,@"topControlsAccessibilityContainerView");
    UIView *host=[rawHost isKindOfClass:UIView.class] ? rawHost : reference.superview;
    BOOL changed=NO;
    if (host && button.superview!=host) { [button removeFromSuperview];[host addSubview:button];changed=YES; }
    if (CGRectGetWidth(button.bounds)!=44 || CGRectGetHeight(button.bounds)!=44) {
        button.bounds=CGRectMake(0,0,44,44);changed=YES;
    }
    BOOL hidden=button.hidden;
    [DNVOTController.shared updateControlsButton:button];
    button.hidden=button.hidden || (reference && reference.hidden);
    button.alpha=reference ? reference.alpha : (DNNumber(overlay,@"isOverlayVisible") ? 1 : 0);
    button.userInteractionEnabled=YES;
    if (hidden!=button.hidden) changed=YES;
    [button.superview bringSubviewToFront:button];
    // A video ID may become available after native layout skipped the initially hidden button.
    if (requestLayout && changed) [overlay setNeedsLayout];
}
void DNVOTUpdateNativeButtons(void) {
    for (UIButton *button in DNButtons.allObjects) {
        DNVOTButtonOwner *owner=objc_getAssociatedObject(button,DNOwnerKey);
        if (owner.overlay) DNRefreshButton(owner.overlay,YES);
    }
}

static id DNSettingItem(NSString *title, NSString *(^detail)(void), BOOL (^action)(id,NSUInteger)) {
    Class cls=NSClassFromString(@"YTSettingsSectionItem");NSString *name=@"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:";
    if (!DNSignature(cls,name,'@',"@@@@")) return nil;
    return ((id(*)(id,SEL,id,id,id,id))objc_msgSend)(cls,NSSelectorFromString(name),title,@"DNVOT.Settings",detail,action);
}
static BOOL DNBuildSettings(id manager) {
    id delegate=DNIvarObject(manager,"_dataDelegate");
    NSString *setter=@"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:";
    if (!DNSignature(delegate,setter,'v',"@Q@@@B")) return NO;
    __weak UIViewController *vc=[delegate isKindOfClass:UIViewController.class] ? delegate : nil;
    NSMutableArray *items=[NSMutableArray new];
    id settings=DNSettingItem(@"Настройки VOT", ^NSString *{return @"Звук, автоперевод, серверы, аккаунт и диагностика";},^BOOL(__unused id cell,__unused NSUInteger index){[DNVOTController.shared showPanelFrom:vc];return YES;});
    if (!settings) return NO;[items addObject:settings];
    ((void(*)(id,SEL,id,NSUInteger,id,id,id,BOOL))objc_msgSend)(delegate,NSSelectorFromString(setter),items,DNCategory,@"VOT · Перевод видео",nil,nil,NO);
    DNSettingsBuilt++;return YES;
}

static void DNAddMenuFooter(UIView *view) {
    if (![view isKindOfClass:UIView.class] || objc_getAssociatedObject(view,DNMenuFooterKey)) return;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.backgroundColor=UIColor.secondarySystemBackgroundColor;button.translatesAutoresizingMaskIntoConstraints=NO;
    [button setTitle:@"VOT · Озвучка и громкость" forState:UIControlStateNormal];[button addTarget:DNVOTUIActions.shared action:@selector(settings) forControlEvents:UIControlEventTouchUpInside];
    [view addSubview:button];[NSLayoutConstraint activateConstraints:@[[button.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],[button.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],[button.bottomAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.bottomAnchor],[button.heightAnchor constraintEqualToConstant:48]]];
    // Reserve space in scrollable menu content so existing entries remain reachable.
    NSMutableArray<UIView *> *queue=[view.subviews mutableCopy];NSUInteger budget=96;
    while (queue.count && budget--) {UIView *v=queue.lastObject;[queue removeLastObject];if (v==button) continue;if ([v isKindOfClass:UIScrollView.class]) {UIScrollView *scroll=(UIScrollView *)v;UIEdgeInsets inset=scroll.contentInset;inset.bottom+=48;scroll.contentInset=inset;}else [queue addObjectsFromArray:v.subviews];}
    objc_setAssociatedObject(view,DNMenuFooterKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);DNPlayerMenus++;DNMenuIntent=0;
}
static void DNAddSheetAction(id sheet) {
    if (NSProcessInfo.processInfo.systemUptime>DNMenuIntent || !DNSignature(sheet,@"addAction:",'v',"@")) return;
    Class cls=NSClassFromString(@"YTActionSheetAction");NSString *name=@"actionWithTitle:style:handler:";
    if (!DNSignature(cls,name,'@',"@q@")) return;
    for (id action in DNObject(sheet,@"actions")) {if ([DNString(DNObject(action,@"title")) isEqual:@"VOT · Озвучка и громкость"]) return;}
    void (^handler)(id)=^(__unused id action){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[DNVOTController.shared showPanel];});};
    id action=((id(*)(id,SEL,id,NSInteger,id))objc_msgSend)(cls,NSSelectorFromString(name),@"VOT · Озвучка и громкость",0,handler);
    if (action) {((void(*)(id,SEL,id))objc_msgSend)(sheet,NSSelectorFromString(@"addAction:"),action);DNMenuIntent=0;DNPlayerMenus++;}
}
NSString *DNVOTNativeDiagnostics(void) {
    NSMutableString *report=[NSMutableString stringWithFormat:@"Native UI hooks: %lu\nSettings sections built: %lu\nPlayer buttons: %lu\nPlayer menus decorated: %lu\nPlayer layout passes: %lu",(unsigned long)DNUIHooks,(unsigned long)DNSettingsBuilt,(unsigned long)DNButtons.count,(unsigned long)DNPlayerMenus,(unsigned long)DNLayoutPasses];
    NSUInteger index=0;
    for (UIButton *button in DNButtons.allObjects) {
        DNVOTButtonOwner *owner=objc_getAssociatedObject(button,DNOwnerKey);
        CGFloat effective=1;BOOL hidden=NO;UIView *view=button;
        for (NSUInteger depth=0;view && depth<32;depth++,view=view.superview) {effective*=view.alpha;hidden|=view.hidden;}
        CGRect visible=button.window ? [button convertRect:button.bounds toView:button.window] : CGRectZero;
        [report appendFormat:@"\nButton %lu: frame=%@ bounds=%@ parent=%@ alpha=%.2f effective=%.2f hidden=%@ window=%@ reference=%@ screen=%@",(unsigned long)++index,NSStringFromCGRect(button.frame),NSStringFromCGRect(button.bounds),NSStringFromClass(button.superview.class),button.alpha,effective,hidden ? @"YES" : @"NO",button.window ? @"YES" : @"NO",owner.reference ?: @"—",NSStringFromCGRect(visible)];
    }
    return report;
}
void DNVOTInstallNativeUI(void) {
    DNUIHooks+=DNVOTHook(object_getClass(NSClassFromString(@"YTAppSettingsPresentationData")),@"settingsCategoryOrder",'@',"",^id(IMP original,SEL sel){return ^id(id obj){return DNAppendCategory(((id(*)(id,SEL))original)(obj,sel));};});
    Class groups=NSClassFromString(@"YTSettingsGroupData");
    DNUIHooks+=DNVOTHook(object_getClass(groups),@"tweaks",'@',"",^id(IMP original,SEL sel){return ^id(id obj){return DNAppendCategory(((id(*)(id,SEL))original)(obj,sel));};});
    DNUIHooks+=DNVOTHook(groups,@"orderedCategories",'@',"",^id(IMP original,SEL sel){return ^id(id obj){id list=((id(*)(id,SEL))original)(obj,sel);if (DNNumber(obj,@"type")==1 && !class_getClassMethod(groups,NSSelectorFromString(@"tweaks"))) return DNAppendCategory(list);return list;};});
    DNUIHooks+=DNVOTHook(NSClassFromString(@"YTSettingsSectionItemManager"),@"updateSectionForCategory:withEntry:",'v',"Q@",^id(IMP original,SEL sel){return ^(id obj,NSUInteger category,id entry){if (category==DNCategory) {@try{DNBuildSettings(obj);}@catch(NSException *e){NSLog(@"[DNVOT] settings adapter: %@",e.name);}return;}((void(*)(id,SEL,NSUInteger,id))original)(obj,sel,category,entry);};});
    Class overlay=NSClassFromString(@"YTMainAppControlsOverlayView");
    for (NSString *getter in @[@"topControls",@"topButtonControls"]) {
        DNUIHooks+=DNVOTHook(overlay,getter,'@',"",^id(IMP original,SEL sel){return ^id(id obj){id raw=((id(*)(id,SEL))original)(obj,sel);if (!NSThread.isMainThread || ![raw isKindOfClass:NSArray.class]) return raw;@try{UIButton *button=DNControlsButton(obj);NSMutableArray *list=[raw mutableCopy];if (button && ![list containsObject:button]) [list insertObject:button atIndex:0];return list;}@catch(__unused NSException *e){return raw;}};});
    }
    DNUIHooks+=DNVOTHook(overlay,@"layoutSubviews",'v',"",^id(IMP original,SEL sel){return ^(id obj){
        @try { DNControlsButton(obj);DNRefreshButton(obj,NO); } @catch (__unused NSException *e) {}
        ((void(*)(id,SEL))original)(obj,sel);DNLayoutPasses++;
        @try { DNRefreshButton(obj,NO); } @catch (__unused NSException *e) {}
    };});
    DNUIHooks+=DNVOTHook(overlay,@"setTopOverlayVisible:isAutonavCanceledState:",'v',"BB",^id(IMP original,SEL sel){return ^(id obj,BOOL visible,BOOL cancelled){((void(*)(id,SEL,BOOL,BOOL))original)(obj,sel,visible,cancelled);@try{DNRefreshButton(obj,YES);}@catch(__unused NSException *e){}};});
    DNUIHooks+=DNVOTHook(overlay,@"setOverlayVisible:",'v',"B",^id(IMP original,SEL sel){return ^(id obj,BOOL visible){((void(*)(id,SEL,BOOL))original)(obj,sel,visible);@try{DNRefreshButton(obj,YES);}@catch(__unused NSException *e){}};});
    DNUIHooks+=DNVOTHook(overlay,@"setVideoControlsVisibility:",'v',"q",^id(IMP original,SEL sel){return ^(id obj,NSInteger visibility){((void(*)(id,SEL,NSInteger))original)(obj,sel,visibility);@try{DNRefreshButton(obj,YES);}@catch(__unused NSException *e){}};});
    DNUIHooks+=DNVOTHook(overlay,@"didPressOverflow:",'v',"@",^id(IMP original,SEL sel){return ^(id obj,id sender){DNMenuIntent=NSProcessInfo.processInfo.systemUptime+3;((void(*)(id,SEL,id))original)(obj,sel,sender);};});
    DNUIHooks+=DNVOTHook(NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController"),@"didPressOverflow:",'v',"@",^id(IMP original,SEL sel){return ^(id obj,id sender){DNMenuIntent=NSProcessInfo.processInfo.systemUptime+3;((void(*)(id,SEL,id))original)(obj,sel,sender);};});
    DNUIHooks+=DNVOTHook(NSClassFromString(@"YTMainAppVideoPlayerOverlayView"),@"setOverflowMenuView:",'v',"@",^id(IMP original,SEL sel){return ^(id obj,id view){((void(*)(id,SEL,id))original)(obj,sel,view);@try{DNAddMenuFooter(view);}@catch(__unused NSException *e){}};});
    for (NSString *method in @[@"presentFromViewController:animated:completion:",@"presentFromView:animated:completion:"]) {
        DNUIHooks+=DNVOTHook(NSClassFromString(@"YTActionSheetController"),method,'v',"@B@",^id(IMP original,SEL sel){return ^(id obj,id presenter,BOOL animated,id completion){@try{DNAddSheetAction(obj);}@catch(__unused NSException *e){}((void(*)(id,SEL,id,BOOL,id))original)(obj,sel,presenter,animated,completion);};});
    }
}
