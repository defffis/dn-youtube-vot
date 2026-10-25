#import "Preferences.h"
#import "DNVOT.h"
#import <Security/Security.h>
#import <SafariServices/SafariServices.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const DNServiceSettingsKey = @"DNVoiceTranslation.Service.v1";
static NSString *const DNAccountMetaKey = @"DNVoiceTranslation.Account.v1";
static NSString *const DNKeychainService = @"DNYouTubeVOT.YandexOAuth";
static NSString *const DNClientID = @"1666fbe22f3749c581002a4f97b2592d"; // upstream VOT public OAuth client
static NSString *const DNRedirect = @"https://oauth.yandex.ru/verification_code";
static NSString *DNBase64URL(NSData *data) {
    return [[[[data base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSDictionary *DNKeychainQuery(void) { return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:DNKeychainService,(__bridge id)kSecAttrAccount:@"oauth"}; }
static void DNMessage(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [vc presentViewController:a animated:YES completion:nil];
}
@implementation DNVOTPreferences
+ (instancetype)shared { static DNVOTPreferences *p; static dispatch_once_t once; dispatch_once(&once, ^{ p = [self new]; }); return p; }
- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:DNServiceSettingsKey];
        self.transport = [d[@"transport"] isEqual:@"worker"] ? @"worker" : @"direct";
        self.serverURL = [DNVOTPreferences normalizedServer:d[@"server"]] ?: @"https://api.browser.yandex.ru";
        self.lively = [d[@"lively"] boolValue];
    } return self;
}
+ (NSString *)normalizedServer:(NSString *)text {
    if (![text isKindOfClass:NSString.class]) return nil;
    NSURLComponents *u = [NSURLComponents componentsWithString:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if (![u.scheme.lowercaseString isEqual:@"https"] || !u.host.length || u.user.length || u.password.length || u.query || u.fragment) return nil;
    NSString *s = u.string; while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1]; return s;
}
- (void)save {
    [DNVOTController.shared stop];
    [NSUserDefaults.standardUserDefaults setObject:@{@"transport":self.transport,@"server":self.serverURL,@"lively":@(self.lively)} forKey:DNServiceSettingsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:@"DNVoiceTranslationUpdated" object:nil];
}
- (NSString *)token {
    NSDictionary *meta = [NSUserDefaults.standardUserDefaults dictionaryForKey:DNAccountMetaKey];
    NSTimeInterval expires = [meta[@"expires"] doubleValue];
    if (expires > 0 && expires <= NSDate.date.timeIntervalSince1970) return nil;
    NSMutableDictionary *q = [DNKeychainQuery() mutableCopy];q[(__bridge id)kSecReturnData]=@YES;q[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nil; OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status != errSecSuccess) return nil;
    NSData *data = CFBridgingRelease(result); return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
- (BOOL)authenticated { return self.token.length > 0; }
- (NSString *)accountName { return [NSUserDefaults.standardUserDefaults dictionaryForKey:DNAccountMetaKey][@"name"] ?: @"Аккаунт Яндекса"; }
- (BOOL)saveToken:(NSString *)token name:(NSString *)name expires:(NSTimeInterval)expires {
    if (!token.length || token.length > 4096 || [token rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NO;
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attrs = @{(__bridge id)kSecValueData:data,(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)DNKeychainQuery(), (__bridge CFDictionaryRef)attrs);
    if (result == errSecItemNotFound) { NSMutableDictionary *q=[DNKeychainQuery() mutableCopy];[q addEntriesFromDictionary:attrs];result=SecItemAdd((__bridge CFDictionaryRef)q,nil); }
    if (result != errSecSuccess) return NO;
    [NSUserDefaults.standardUserDefaults setObject:@{@"name":name ?: @"Аккаунт Яндекса",@"expires":@(expires)} forKey:DNAccountMetaKey];
    [self save]; return YES;
}
- (void)logout { SecItemDelete((__bridge CFDictionaryRef)DNKeychainQuery());[NSUserDefaults.standardUserDefaults removeObjectForKey:DNAccountMetaKey];self.lively=NO;[self save]; }
- (NSString *)configurationKey { return [NSString stringWithFormat:@"%@|%@|%d|%@",self.transport,self.serverURL,self.lively,self.authenticated ? self.accountName : @"anonymous"]; }
@end

@implementation DNVOTServiceSettings
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad];self.title=@"Сервер перевода"; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)t { return 2; }
- (NSInteger)tableView:(__unused UITableView *)t numberOfRowsInSection:(NSInteger)s { return s==0 ? 2 : 2; }
- (NSString *)tableView:(__unused UITableView *)t titleForHeaderInSection:(NSInteger)s { return s==0 ? @"Транспорт" : @"Адрес сервера"; }
- (NSString *)tableView:(__unused UITableView *)t titleForFooterInSection:(NSInteger)s { return s==0 ? @"Прямой API — обычные заголовки VOT. Worker — бинарное тело и X-VOT-Headers (современный vot-worker)." : @"Выбранному серверу передаются ссылка и при необходимости аудио. OAuth передаётся только напрямую api.browser.yandex.ru. Наличие сервера не гарантирует успешный перевод."; }
- (UITableViewCell *)tableView:(__unused UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];DNVOTPreferences *v=DNVOTPreferences.shared;
    if (p.section==0) { c.textLabel.text=p.row==0 ? @"Прямой API" : @"VOT Worker";BOOL worker=[v.transport isEqual:@"worker"];c.accessoryType=(worker==(p.row==1)) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone; }
    else { c.textLabel.text=@[@"Яндекс напрямую",@"Свой HTTPS-сервер"][p.row];c.detailTextLabel.text=p.row==1 ? v.serverURL : @"https://api.browser.yandex.ru";c.detailTextLabel.numberOfLines=0; }
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];DNVOTPreferences *v=DNVOTPreferences.shared;
    if (p.section==0) { v.transport=p.row==0 ? @"direct" : @"worker";[v save];[t reloadData];return; }
    if (p.row==0) { v.transport=@"direct";v.serverURL=@"https://api.browser.yandex.ru";[v save];[t reloadData];return; }
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"HTTPS-сервер VOT" message:@"Базовый адрес без query и логина. Выберите подходящий транспорт выше." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.text=v.serverURL;f.keyboardType=UIKeyboardTypeURL;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Сохранить" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){NSString *url=[DNVOTPreferences normalizedServer:a.textFields.firstObject.text];if (!url) { DNMessage(self,@"Неверный адрес",@"Нужен HTTPS-адрес без логина, query и fragment.");return;}v.serverURL=url;[v save];[t reloadData];}]];[self presentViewController:a animated:YES completion:nil];
}
@end

@interface DNVOTAccountSettings () <SFSafariViewControllerDelegate>
@property(nonatomic,copy) NSString *verifier;
@property(nonatomic) NSTimeInterval verifierExpiry;
@property(nonatomic,copy) NSString *notice;
@property(nonatomic,strong) NSURLSession *authSession;
@property(nonatomic) NSUInteger generation;
@end
@interface DNVOTAuthNoRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation DNVOTAuthNoRedirect
- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response newRequest:(__unused NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion { completion(nil); }
@end
@implementation DNVOTAccountSettings
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad];self.title=@"Аккаунт Яндекса";NSURLSessionConfiguration *c=NSURLSessionConfiguration.ephemeralSessionConfiguration;c.timeoutIntervalForRequest=30;c.HTTPCookieStorage=nil;c.HTTPShouldSetCookies=NO;self.authSession=[NSURLSession sessionWithConfiguration:c delegate:[DNVOTAuthNoRedirect new] delegateQueue:nil]; }
- (void)dealloc { [self.authSession invalidateAndCancel]; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)t { return 2; }
- (NSInteger)tableView:(__unused UITableView *)t numberOfRowsInSection:(NSInteger)s { return s==0 ? 4 : 1; }
- (NSString *)tableView:(__unused UITableView *)t titleForHeaderInSection:(NSInteger)s { return s==0 ? (DNVOTPreferences.shared.authenticated ? DNVOTPreferences.shared.accountName : @"Вход не выполнен") : @"Озвучка"; }
- (NSString *)tableView:(__unused UITableView *)t titleForFooterInSection:(NSInteger)s { return s==0 ? (self.notice ?: @"Вход открывается на сайте Яндекса. Скопируйте показанный код, закройте браузер и введите код здесь. Токен хранится в Keychain, пароль приложение не запрашивает.") : @"Живые голоса требуют входа и прямого API Яндекса. Для других серверов OAuth не отправляется."; }
- (UITableViewCell *)tableView:(__unused UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (p.section==0) { c.textLabel.text=@[@"Войти через Яндекс",@"Ввести код подтверждения",@"Ввести OAuth-токен вручную",@"Выйти из VOT"][p.row];c.textLabel.textColor=p.row==3 ? UIColor.systemRedColor : UIColor.labelColor; }
    else { c.textLabel.text=@"Живые голоса";UISwitch *s=[UISwitch new];s.on=DNVOTPreferences.shared.lively;[s addTarget:self action:@selector(livelyChanged:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s; }
    return c;
}
- (void)livelyChanged:(UISwitch *)s {
    DNVOTPreferences *p=DNVOTPreferences.shared;
    if (s.on && !p.authenticated) { s.on=NO;DNMessage(self,@"Нужен вход",@"Сначала войдите в Яндекс.");return; }
    if (s.on && (![p.transport isEqual:@"direct"] || ![p.serverURL isEqual:@"https://api.browser.yandex.ru"])) { s.on=NO;DNMessage(self,@"Выберите Яндекс напрямую",@"OAuth не передаётся выбранному стороннему серверу.");return; }
    p.lively=s.on;[p save];
}
- (void)beginLogin {
    self.generation++;
    uint8_t random[32];if (SecRandomCopyBytes(kSecRandomDefault,sizeof(random),random)!=errSecSuccess) { DNMessage(self,@"Не удалось начать вход",@"Повторите попытку.");return; }
    self.verifier=DNBase64URL([NSData dataWithBytes:random length:sizeof(random)]);self.verifierExpiry=NSDate.date.timeIntervalSince1970+600;
    NSData *v=[self.verifier dataUsingEncoding:NSUTF8StringEncoding];uint8_t hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(v.bytes,(CC_LONG)v.length,hash);
    NSURLComponents *url=[NSURLComponents componentsWithString:@"https://oauth.yandex.ru/authorize"];
    NSDictionary *params=@{@"client_id":DNClientID,@"response_type":@"code",@"redirect_uri":DNRedirect,@"state":NSUUID.UUID.UUIDString,@"code_challenge":DNBase64URL([NSData dataWithBytes:hash length:sizeof(hash)]),@"code_challenge_method":@"S256",@"force_confirm":@"1"};
    NSMutableArray *items=[NSMutableArray new];for (NSString *key in params) [items addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];url.queryItems=items;
    SFSafariViewController *browser=[[SFSafariViewController alloc] initWithURL:url.URL];browser.delegate=self;[self presentViewController:browser animated:YES completion:nil];
}
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
    // The code is entered explicitly, never scraped from web pages.
    self.notice=@"Скопируйте код со страницы Яндекса и выберите «Ввести код подтверждения».";[self.tableView reloadData];
}
- (void)prompt:(BOOL)token {
    if (!token && (!self.verifier.length || self.verifierExpiry<NSDate.date.timeIntervalSince1970)) { DNMessage(self,@"Начните вход заново",@"Сначала откройте «Войти через Яндекс», затем введите полученный код.");return; }
    UIAlertController *a=[UIAlertController alertControllerWithTitle:token ? @"OAuth-токен" : @"Код Яндекса" message:token ? @"Вставьте свой токен. Он проверяется напрямую Яндексом и сохраняется в Keychain." : @"Введите код со страницы Яндекса, открытой из VOT." preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.secureTextEntry=YES;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:token ? @"Проверить и сохранить" : @"Войти" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){NSString *value=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if (token) [self validateToken:value expires:0];else [self exchangeCode:value];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)exchangeCode:(NSString *)code {
    if (!code.length || !self.verifier.length || self.verifierExpiry<NSDate.date.timeIntervalSince1970) return;
    NSUInteger generation=++self.generation;
    NSURLComponents *form=[NSURLComponents new];form.queryItems=@[[NSURLQueryItem queryItemWithName:@"grant_type" value:@"authorization_code"],[NSURLQueryItem queryItemWithName:@"code" value:code],[NSURLQueryItem queryItemWithName:@"client_id" value:DNClientID],[NSURLQueryItem queryItemWithName:@"redirect_uri" value:DNRedirect],[NSURLQueryItem queryItemWithName:@"code_verifier" value:self.verifier]];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.yandex.ru/token"]];r.HTTPMethod=@"POST";[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];r.HTTPBody=[[form.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"] dataUsingEncoding:NSUTF8StringEncoding];
    self.notice=@"Обмен кода…";[self.tableView reloadData];__weak DNVOTAccountSettings *weakSelf=self;
    [[self.authSession dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{DNVOTAccountSettings *s=weakSelf;if (!s || generation!=s.generation) return;
            NSDictionary *j=data.length<65536 ? [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:0 error:nil] : nil;
            if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode!=200 || ![j isKindOfClass:NSDictionary.class] || ![j[@"access_token"] isKindOfClass:NSString.class]) { s.notice=@"Яндекс отклонил код или сеть недоступна. Начните вход заново.";[s.tableView reloadData];return; }
            s.verifier=nil;NSTimeInterval lifetime=[j[@"expires_in"] isKindOfClass:NSNumber.class] ? [j[@"expires_in"] doubleValue] : 0;[s validateToken:j[@"access_token"] expires:lifetime>0 ? NSDate.date.timeIntervalSince1970+lifetime : 0];
        });
    }] resume];
}
- (void)validateToken:(NSString *)token expires:(NSTimeInterval)expires {
    if (!token.length || token.length>4096 || [token rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound) { DNMessage(self,@"Неверный токен",@"Проверьте значение.");return; }
    NSUInteger generation=++self.generation;self.notice=@"Проверка аккаунта…";[self.tableView reloadData];
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://login.yandex.ru/info?format=json"]];[r setValue:[@"OAuth " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    __weak DNVOTAccountSettings *weakSelf=self;
    [[self.authSession dataTaskWithRequest:r completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){dispatch_async(dispatch_get_main_queue(),^{DNVOTAccountSettings *s=weakSelf;if (!s || generation!=s.generation) return;
        NSDictionary *j=data.length<65536 ? [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:0 error:nil] : nil;
        if (error || ![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode!=200 || ![j isKindOfClass:NSDictionary.class] || ![j[@"login"] isKindOfClass:NSString.class]) {s.notice=@"Не удалось подтвердить аккаунт. Токен не сохранён.";[s.tableView reloadData];return;}
        s.notice=[DNVOTPreferences.shared saveToken:token name:j[@"login"] expires:expires] ? @"Вход выполнен. Можно включить живые голоса." : @"Keychain недоступен при этой подписи. Токен не сохранён.";[s.tableView reloadData];
    });}] resume];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES];if (p.section) return;
    if (p.row==0) [self beginLogin];else if (p.row<3) [self prompt:p.row==2];else {self.generation++;self.verifier=nil;[DNVOTPreferences.shared logout];self.notice=@"Токен VOT удалён с устройства.";[t reloadData];}
}
@end
