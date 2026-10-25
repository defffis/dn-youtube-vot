#import "DNVOT.h"
#import "Preferences.h"
#import "FlightRecorder.h"
#import <SafariServices/SafariServices.h>

static NSArray<NSString *> *DNCodes(void) { return @[@"ru",@"en",@"kk",@"uk",@"be",@"de",@"fr",@"es",@"it",@"pt",@"pl",@"cs",@"sk",@"bg",@"sr",@"hr",@"sl",@"ro",@"hu",@"nl",@"sv",@"da",@"no",@"fi",@"el",@"tr",@"ar",@"he",@"fa",@"hi",@"id",@"ms",@"vi",@"th",@"zh",@"ja",@"ko"]; }
static NSString *DNLanguageName(NSString *code) {
    if ([code isEqual:@"auto"]) return @"Определять автоматически";
    static NSLocale *locale;static dispatch_once_t once;dispatch_once(&once, ^{ locale=[[NSLocale alloc] initWithLocaleIdentifier:@"ru"]; });return [locale localizedStringForLanguageCode:code] ?: code;
}
static UITableViewCell *DNCell(NSString *title,NSString *detail) {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.text=title;cell.textLabel.numberOfLines=0;cell.detailTextLabel.text=detail;cell.detailTextLabel.numberOfLines=0;return cell;
}
static void DNInfo(UIViewController *vc,NSString *text) {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"VOT" message:text preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[vc presentViewController:alert animated:YES completion:nil];
}
@interface DNLanguageSettings : UITableViewController
@property(nonatomic) NSInteger selection; // 0 source, 1 target, 2 auto exclusions
@property(nonatomic,strong) NSArray<NSString *> *codes;
@end
@implementation DNLanguageSettings
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@[@"Язык оригинала",@"Перевести на",@"Исключения автоперевода"][self.selection];
    self.codes=self.selection==0 ? [@[@"auto"] arrayByAddingObjectsFromArray:DNCodes()] : (self.selection==1 ? @[@"ru",@"en",@"kk"] : DNCodes());
}
- (NSInteger)tableView:(__unused UITableView *)t numberOfRowsInSection:(__unused NSInteger)s { return self.codes.count; }
- (NSString *)tableView:(__unused UITableView *)t titleForFooterInSection:(__unused NSInteger)s { return self.selection==2 ? @"Отмеченные языки пропускаются только при автоматическом запуске. Кнопка плеера переводит вручную независимо от исключений. Если язык неизвестен и исключения заданы, автоматический запуск пропускается." : nil; }
- (UITableViewCell *)tableView:(__unused UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    NSString *code=self.codes[p.row];DNVOTController *v=DNVOTController.shared;
    BOOL selected=self.selection==2 ? [v.excludedLanguages containsObject:code] : [code isEqual:self.selection==0 ? v.fromLanguage : v.toLanguage];
    UITableViewCell *c=DNCell(DNLanguageName(code),code);c.accessoryType=selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];NSString *code=self.codes[p.row];DNVOTController *v=DNVOTController.shared;
    if (self.selection==2) { NSMutableSet *set=[v.excludedLanguages mutableCopy] ?: [NSMutableSet new];if ([set containsObject:code]) [set removeObject:code];else [set addObject:code];v.excludedLanguages=set;[v autoSettingsChanged]; }
    else { if (self.selection==0) v.fromLanguage=code;else v.toLanguage=code;[v stop];[v autoSettingsChanged]; }
    [t reloadData];
}
@end

@implementation DNVOTSettings
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.quick ? @"Звук и языки" : @"VOT · Настройки";
    if (self.navigationController.viewControllers.firstObject==self) self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self.tableView reloadData]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)t { return self.quick ? 1 : 5; }
- (NSInteger)tableView:(__unused UITableView *)t numberOfRowsInSection:(NSInteger)s { return s==0 ? 5 : (s==1 || s==2 ? 2 : 3); }
- (NSString *)tableView:(__unused UITableView *)t titleForHeaderInSection:(NSInteger)s { return @[@"Озвучка",@"Автоматический перевод",@"Подключение",@"Обслуживание",@"О проекте"][s]; }
- (NSString *)tableView:(__unused UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s==0) return @"Перевод включается и выключается значком в плеере. Положительное смещение воспроизводит перевод раньше, отрицательное — позже.";
    if (s==1) return @"Применяется к текущему и следующим обычным видео. Язык берётся из аудиодорожки или автоматических субтитров. Если заданы исключения, неизвестный язык пропускается. Ручная кнопка работает всегда.";
    if (s==3) return @"Автоочистка включена: 24 часа от сохранения, прослушивание срок не продлевает. Текущая озвучка защищена до остановки. Очистка кеша останавливает озвучку; сброс также удаляет вход Яндекса. Логи сохраняются.";
    if (s==4) return @"DN YouTube VOT 0.3.1-alpha. Разработано на основе исследований протокола и решений voice-over-translation / vot.js. Авторы исходных проектов и MIT-уведомления указаны в репозитории.";
    return nil;
}
- (UITableViewCell *)tableView:(__unused UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    DNVOTController *v=DNVOTController.shared;DNVOTPreferences *prefs=DNVOTPreferences.shared;
    if (p.section==0) {
        if (p.row<2) { UITableViewCell *c=DNCell(p.row==0 ? @"Язык оригинала" : @"Перевести на",DNLanguageName(p.row==0 ? v.fromLanguage : v.toLanguage));c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c; }
        if (p.row<4) {
            BOOL original=p.row==2;float value=original ? v.originalLevel : v.translationLevel;
            UITableViewCell *c=DNCell(original ? @"Громкость оригинала" : @"Громкость перевода",[NSString stringWithFormat:@"%.0f%%",value*100]);
            UISlider *slider=[[UISlider alloc] initWithFrame:CGRectMake(0,0,145,36)];slider.minimumValue=0;slider.maximumValue=1;slider.value=value;slider.tag=original ? 0 : 1;slider.accessibilityLabel=c.textLabel.text;[slider addTarget:self action:@selector(volumeChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=slider;return c;
        }
        UITableViewCell *c=DNCell(@"Смещение перевода",[NSString stringWithFormat:@"%+.1f с",v.offset]);UIStepper *step=[UIStepper new];step.minimumValue=-5;step.maximumValue=5;step.stepValue=0.1;step.value=v.offset;step.accessibilityLabel=c.textLabel.text;[step addTarget:self action:@selector(offsetChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=step;return c;
    }
    if (p.section==1) {
        if (p.row==0) { UITableViewCell *c=DNCell(@"Автоматически переводить все видео",nil);UISwitch *sw=[UISwitch new];sw.on=v.autoTranslate;[sw addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=sw;return c; }
        NSMutableArray *names=[NSMutableArray new];for (NSString *code in [v.excludedLanguages.allObjects sortedArrayUsingSelector:@selector(compare:)]) [names addObject:DNLanguageName(code)];
        UITableViewCell *c=DNCell(@"Не переводить автоматически с этих языков",names.count ? [names componentsJoinedByString:@", "] : @"Исключений нет");c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c;
    }
    if (p.section==2) { UITableViewCell *c=DNCell(p.row==0 ? @"Аккаунт Яндекса и живые голоса" : @"Серверы и проксирование",p.row==0 ? (prefs.authenticated ? @"Вход выполнен · стандартный перевод доступен и без входа" : @"Стандартный перевод без авторизации") : @[@"Напрямую",@"API через свой Worker",@"API + озвучка через свой Worker"][prefs.proxyMode]);c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c; }
    if (p.section==3) {
        UITableViewCell *c=DNCell(@[@"Диагностика и запись лога",@"Очистить кеш переводов",@"Сбросить все настройки"][p.row],p.row==1 ? [NSString stringWithFormat:@"%.1f МБ",[v cacheBytes]/1048576.0] : nil);
        c.accessoryType=p.row==0 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;if (p.row==2) c.textLabel.textColor=UIColor.systemRedColor;return c;
    }
    UITableViewCell *c=DNCell(@[@"Автор патча · defffis на GitHub",@"Исходники DN YouTube VOT",@"Оригинальное расширение · ilyhalight/VOT"][p.row],nil);c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c;
}
- (void)volumeChanged:(UISlider *)sender {
    DNVOTController *v=DNVOTController.shared;if (sender.tag==0) v.originalLevel=sender.value;else v.translationLevel=sender.value;[v saveSettings];
    UIView *parent=sender.superview;while (parent && ![parent isKindOfClass:UITableViewCell.class]) parent=parent.superview;((UITableViewCell *)parent).detailTextLabel.text=[NSString stringWithFormat:@"%.0f%%",sender.value*100];
}
- (void)offsetChanged:(UIStepper *)sender { DNVOTController.shared.offset=sender.value;[DNVOTController.shared saveSettings];[self.tableView reloadData]; }
- (void)autoChanged:(UISwitch *)sender { DNVOTController.shared.autoTranslate=sender.on;[DNVOTController.shared autoSettingsChanged]; }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];
    if ((p.section==0 && p.row<2) || (p.section==1 && p.row==1)) { DNLanguageSettings *languages=[DNLanguageSettings new];languages.selection=p.section==1 ? 2 : p.row;[self.navigationController pushViewController:languages animated:YES];return; }
    if (p.section==2) { UIViewController *vc=p.row==0 ? [DNVOTAccountSettings new] : [DNVOTServiceSettings new];[self.navigationController pushViewController:vc animated:YES];return; }
    if (p.section==3) {
        if (p.row==0) { [self.navigationController pushViewController:[DNVOTDiagnosticSettings new] animated:YES];return; }
        BOOL reset=p.row==2;UIAlertController *a=[UIAlertController alertControllerWithTitle:reset ? @"Сбросить VOT?" : @"Очистить кеш?" message:reset ? @"Будут сброшены языки, громкость, автоперевод, серверы и прокси; удалены вход Яндекса и кеш озвучки. Логи сохранятся." : @"Скачанные переводы будут удалены, текущая озвучка остановится. Настройки, вход и логи сохранятся." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:reset ? @"Сбросить" : @"Очистить" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) { if (reset) [DNVOTController.shared resetSettings];else [DNVOTController.shared clearCache];[t reloadData]; }]];[self presentViewController:a animated:YES completion:nil];return;
    }
    if (p.section==4) {
        NSArray *links=@[@"https://github.com/defffis",@"https://github.com/defffis/dn-youtube-vot",@"https://github.com/ilyhalight/voice-over-translation"];
        [self presentViewController:[[SFSafariViewController alloc] initWithURL:[NSURL URLWithString:links[p.row]]] animated:YES completion:nil];
    }
}
@end

@interface DNVOTDiagnosticSettings ()
@property(nonatomic,strong) NSTimer *timer;
@end
@implementation DNVOTDiagnosticSettings
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad];self.title=@"Диагностика и лог"; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self.timer invalidate];__weak DNVOTDiagnosticSettings *weakSelf=self;self.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf.tableView reloadData]; }]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated];[self.timer invalidate];self.timer=nil; }
- (void)dealloc { [self.timer invalidate]; }
- (NSInteger)tableView:(__unused UITableView *)t numberOfRowsInSection:(__unused NSInteger)s { return 4; }
- (NSString *)tableView:(__unused UITableView *)t titleForHeaderInSection:(__unused NSInteger)s { return DNFlightRecorder.shared.state; }
- (NSString *)tableView:(__unused UITableView *)t titleForFooterInSection:(__unused NSInteger)s { return @"Запись идёт и после закрытия этого меню, пока процесс YouTube выполняется. Лимит 15 минут / 12 МБ. JSONL содержит ID видео и технические события; без OAuth, аккаунта, медиа-URL и самого аудио. Экспорт открывает «Поделиться» → «Сохранить в Файлы»."; }
- (UITableViewCell *)tableView:(__unused UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c=DNCell(@[@"Скопировать диагностику",@"Начать запись лога",@"Остановить запись лога",@"Экспортировать лог файлом"][p.row],nil);
    BOOL disabled=(p.row==1 && DNFlightRecorder.shared.recording) || (p.row==2 && !DNFlightRecorder.shared.recording);c.userInteractionEnabled=!disabled;c.textLabel.textColor=disabled ? UIColor.tertiaryLabelColor : UIColor.labelColor;return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];
    if (p.row==0) { UIPasteboard.generalPasteboard.string=DNVOTController.shared.diagnostics;DNInfo(self,@"Диагностика скопирована");return; }
    if (p.row==1) { [DNFlightRecorder.shared start];return; }
    if (p.row==2) { [DNFlightRecorder.shared stop];return; }
    __weak DNVOTDiagnosticSettings *weakSelf=self;
    [DNFlightRecorder.shared exportFile:^(NSURL *url,NSString *error) {
        DNVOTDiagnosticSettings *s=weakSelf;if (!s.view.window || s.presentedViewController) return;if (!url) { DNInfo(s,error);return; }
        UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];share.popoverPresentationController.sourceView=s.view;share.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(s.view.bounds),CGRectGetMidY(s.view.bounds),1,1);[s presentViewController:share animated:YES completion:nil];
    }];
}
@end
