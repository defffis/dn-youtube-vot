#import "DNVOT.h"
#import "Runtime.hpp"
#import "Preferences.h"

static const NSUInteger DNCategory = 0x444e5654; // DNVT; independent settings category
static const void *DNButtonKey = &DNButtonKey;
static const void *DNMenuFooterKey = &DNMenuFooterKey;
static NSHashTable<UIButton *> *DNButtons;
static NSUInteger DNUIHooks;
static NSUInteger DNSettingsBuilt;
static NSUInteger DNPlayerMenus;
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

static UIButton *DNControlsButton(id overlay) {
    UIButton *button=objc_getAssociatedObject(overlay,DNButtonKey);
    if (button) return button;
    UIImage *image=[UIImage systemImageNamed:@"waveform.bubble"];
    SEL factory=NSSelectorFromString(@"buttonWithImage:accessibilityLabel:verticalContentPadding:");
    if (!DNSignature(overlay,NSStringFromSelector(factory),'@',"@@d")) return nil;
    id raw=((id(*)(id,SEL,id,id,double))objc_msgSend)(overlay,factory,image,@"Включить озвучку с переводом",0);
    if (![raw isKindOfClass:UIButton.class]) return nil;
    button=raw;button.accessibilityIdentifier=@"DNVOT.PlayerToggle";button.tintColor=UIColor.whiteColor;
    button.titleLabel.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth=YES;
    [button addTarget:DNVOTUIActions.shared action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *hold=[[UILongPressGestureRecognizer alloc] initWithTarget:DNVOTUIActions.shared action:@selector(hold:)];hold.minimumPressDuration=0.55;[button addGestureRecognizer:hold];
    id container=DNObject(overlay,@"topControlsAccessibilityContainerView");
    if (![container isKindOfClass:UIView.class]) container=overlay;
    if (![container isKindOfClass:UIView.class]) return nil;
    [(UIView *)container addSubview:button];
    objc_setAssociatedObject(overlay,DNButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!DNButtons) DNButtons=[NSHashTable weakObjectsHashTable];[DNButtons addObject:button];
    [DNVOTController.shared updateControlsButton:button];button.alpha=DNNumber(overlay,@"isOverlayVisible") ? 1 : 0;return button;
}
void DNVOTUpdateNativeButtons(void) { for (UIButton *button in DNButtons) [DNVOTController.shared updateControlsButton:button]; }

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
    id playback=DNSettingItem(@"Озвучка и громкость", ^NSString *{return @"Языки, уровни звука, смещение, автоперевод";},^BOOL(__unused id cell,__unused NSUInteger index){[DNVOTController.shared showPanelFrom:vc];return YES;});
    id account=DNSettingItem(@"Аккаунт Яндекса",^NSString *{return DNVOTPreferences.shared.authenticated ? DNVOTPreferences.shared.accountName : @"Войти · живые голоса";},^BOOL(__unused id cell,__unused NSUInteger index){UIViewController *parent=vc;if (parent.navigationController) [parent.navigationController pushViewController:[DNVOTAccountSettings new] animated:YES];else [DNVOTController.shared showPanelFrom:parent];return YES;});
    id server=DNSettingItem(@"Сервер перевода",^NSString *{return DNVOTPreferences.shared.serverURL;},^BOOL(__unused id cell,__unused NSUInteger index){UIViewController *parent=vc;if (parent.navigationController) [parent.navigationController pushViewController:[DNVOTServiceSettings new] animated:YES];else [DNVOTController.shared showPanelFrom:parent];return YES;});
    if (!playback || !account || !server) return NO;
    [items addObjectsFromArray:@[playback,account,server]];
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
NSString *DNVOTNativeDiagnostics(void) {return [NSString stringWithFormat:@"Native UI hooks: %lu\nSettings sections built: %lu\nPlayer buttons: %lu\nPlayer menus decorated: %lu",(unsigned long)DNUIHooks,(unsigned long)DNSettingsBuilt,(unsigned long)DNButtons.count,(unsigned long)DNPlayerMenus];}
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
    DNUIHooks+=DNVOTHook(overlay,@"setTopOverlayVisible:isAutonavCanceledState:",'v',"BB",^id(IMP original,SEL sel){return ^(id obj,BOOL visible,BOOL cancelled){((void(*)(id,SEL,BOOL,BOOL))original)(obj,sel,visible,cancelled);UIButton *button=objc_getAssociatedObject(obj,DNButtonKey);button.alpha=visible && !cancelled ? 1 : 0;};});
    DNUIHooks+=DNVOTHook(overlay,@"didPressOverflow:",'v',"@",^id(IMP original,SEL sel){return ^(id obj,id sender){DNMenuIntent=NSProcessInfo.processInfo.systemUptime+3;((void(*)(id,SEL,id))original)(obj,sel,sender);};});
    DNUIHooks+=DNVOTHook(NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController"),@"didPressOverflow:",'v',"@",^id(IMP original,SEL sel){return ^(id obj,id sender){DNMenuIntent=NSProcessInfo.processInfo.systemUptime+3;((void(*)(id,SEL,id))original)(obj,sel,sender);};});
    DNUIHooks+=DNVOTHook(NSClassFromString(@"YTMainAppVideoPlayerOverlayView"),@"setOverflowMenuView:",'v',"@",^id(IMP original,SEL sel){return ^(id obj,id view){((void(*)(id,SEL,id))original)(obj,sel,view);@try{DNAddMenuFooter(view);}@catch(__unused NSException *e){}};});
    for (NSString *method in @[@"presentFromViewController:animated:completion:",@"presentFromView:animated:completion:"]) {
        DNUIHooks+=DNVOTHook(NSClassFromString(@"YTActionSheetController"),method,'v',"@B@",^id(IMP original,SEL sel){return ^(id obj,id presenter,BOOL animated,id completion){@try{DNAddSheetAction(obj);}@catch(__unused NSException *e){}((void(*)(id,SEL,id,BOOL,id))original)(obj,sel,presenter,animated,completion);};});
    }
}
