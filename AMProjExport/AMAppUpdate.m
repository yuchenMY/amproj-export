// 猫鹤 AM · 复用网站设备授权、签名排队和系统 OTA 安装确认。
#import "AMAppUpdate.h"
#import "AMAppUpdatePolicy.h"
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>

static NSString *const AMUpdateOrigin = @"https://am.ayakameow.cn";
static UIColor *AMUpdateInk(void) { return [UIColor colorWithRed:0.125 green:0.133 blue:0.22 alpha:1]; }
static UIColor *AMUpdateAccent(void) { return [UIColor colorWithRed:0.07 green:0.56 blue:0.51 alpha:1]; }
static UIColor *AMUpdateMuted(void) { return [UIColor colorWithRed:0.36 green:0.38 blue:0.44 alpha:1]; }
static UIFont *AMUpdateFont(CGFloat size, UIFontWeight weight, UIFontTextStyle style) {
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
}

static NSMutableDictionary *AMUpdateKeychainQuery(void) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:[NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".app-update"],
        (__bridge id)kSecAttrAccount:@"installation"} mutableCopy];
}
static NSString *AMUpdateSavedToken(void) {
    NSMutableDictionary *query = AMUpdateKeychainQuery(); query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(result) encoding:NSUTF8StringEncoding];
}
static void AMUpdateSaveToken(NSString *token) {
    NSMutableDictionary *query = AMUpdateKeychainQuery();
    NSDictionary *attributes = @{(__bridge id)kSecValueData:[token dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (result == errSecItemNotFound) { [query addEntriesFromDictionary:attributes]; SecItemAdd((__bridge CFDictionaryRef)query, NULL); }
}
static NSString *AMUpdateProfileTeam(void) {
    NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"embedded" withExtension:@"mobileprovision"]];
    return AMAppUpdateProfileTeamFromData(data);
}

@interface AMAppUpdateController : UIViewController <NSURLSessionTaskDelegate, WKNavigationDelegate, WKUIDelegate, SFSafariViewControllerDelegate>
@property(nonatomic) NSURL *website;
@property(nonatomic) BOOL retiredBeta;
@property(nonatomic) UILabel *status;
@property(nonatomic) UILabel *phaseTitle;
@property(nonatomic) NSArray<UILabel *> *stepNumbers;
@property(nonatomic) NSArray<UILabel *> *stepNames;
@property(nonatomic) UIActivityIndicatorView *spinner;
@property(nonatomic) UIButton *action;
@property(nonatomic) WKWebView *web;
@property(nonatomic) UIView *webHost;
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) NSString *token;
@property(nonatomic) NSString *bundle;
@property(nonatomic) NSString *channel;
@property(nonatomic) NSString *targetBundle;
@property(nonatomic) NSInteger releaseCode;
@property(nonatomic) NSString *pendingKey;
@property(nonatomic) NSString *requestId;
@property(nonatomic) NSURL *manifest;
@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL associationRulesFailed;
@property(nonatomic) BOOL useInstallPage;
@property(nonatomic) NSDate *deadline;
@property(nonatomic) id foregroundObserver;
@end

@implementation AMAppUpdateController
- (void)buildUpdateView {
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor colorWithRed:0.965 green:0.969 blue:0.973 alpha:1];
    self.view.tintColor = AMUpdateAccent();
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground]; appearance.backgroundColor = self.view.backgroundColor;
    appearance.shadowColor = UIColor.clearColor; appearance.titleTextAttributes = @{NSForegroundColorAttributeName:AMUpdateInk()};
    self.navigationItem.standardAppearance = appearance; self.navigationItem.scrollEdgeAppearance = appearance;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.app" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:25 weight:UIImageSymbolWeightMedium]]];
    icon.tintColor = AMUpdateAccent(); icon.contentMode = UIViewContentModeCenter;
    icon.backgroundColor = [UIColor colorWithRed:0.90 green:0.97 blue:0.95 alpha:1]; icon.layer.cornerRadius = 16;
    icon.accessibilityElementsHidden = YES;
    [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:56], [icon.heightAnchor constraintEqualToConstant:56]]];
    UILabel *title = [UILabel new]; title.text = @"更新猫鹤 AM"; title.textColor = AMUpdateInk(); title.numberOfLines = 0;
    title.font = AMUpdateFont(24, UIFontWeightBold, UIFontTextStyleTitle2);
    UILabel *subtitle = [UILabel new]; subtitle.text = @"完成下方步骤，继续使用最新功能。"; subtitle.textColor = AMUpdateMuted(); subtitle.numberOfLines = 0;
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    UIStackView *headings = [[UIStackView alloc] initWithArrangedSubviews:@[title,subtitle]]; headings.axis = UILayoutConstraintAxisVertical; headings.spacing = 6;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[icon,headings]]; header.spacing = 14; header.alignment = UIStackViewAlignmentCenter;

    NSMutableArray *numbers = [NSMutableArray array], *names = [NSMutableArray array], *steps = [NSMutableArray array];
    for (NSString *name in @[@"关联设备",@"准备更新",@"确认安装"]) {
        UILabel *number = [UILabel new]; number.textAlignment = NSTextAlignmentCenter; number.layer.cornerRadius = 14; number.clipsToBounds = YES;
        number.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; number.accessibilityElementsHidden = YES;
        [NSLayoutConstraint activateConstraints:@[[number.widthAnchor constraintEqualToConstant:28], [number.heightAnchor constraintEqualToConstant:28]]];
        UILabel *caption = [UILabel new]; caption.text = name; caption.textAlignment = NSTextAlignmentCenter; caption.numberOfLines = 0;
        caption.font = AMUpdateFont(12, UIFontWeightMedium, UIFontTextStyleCaption1);
        UIStackView *step = [[UIStackView alloc] initWithArrangedSubviews:@[number,caption]]; step.axis = UILayoutConstraintAxisVertical; step.alignment = UIStackViewAlignmentCenter; step.spacing = 8;
        [numbers addObject:number]; [names addObject:caption]; [steps addObject:step];
    }
    self.stepNumbers = numbers; self.stepNames = names;
    UIStackView *stepper = [[UIStackView alloc] initWithArrangedSubviews:steps]; stepper.distribution = UIStackViewDistributionFillEqually; stepper.alignment = UIStackViewAlignmentTop; stepper.spacing = 8;
    UIView *divider = [UIView new]; divider.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1]; [divider.heightAnchor constraintEqualToConstant:1].active = YES;
    self.phaseTitle = [UILabel new]; self.phaseTitle.font = AMUpdateFont(20, UIFontWeightSemibold, UIFontTextStyleHeadline); self.phaseTitle.textColor = AMUpdateInk(); self.phaseTitle.numberOfLines = 0;
    self.phaseTitle.accessibilityTraits = UIAccessibilityTraitHeader;
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium]; self.spinner.color = AMUpdateAccent(); self.spinner.hidesWhenStopped = YES;
    UIStackView *phase = [[UIStackView alloc] initWithArrangedSubviews:@[self.phaseTitle,self.spinner]]; phase.spacing = 12; phase.alignment = UIStackViewAlignmentCenter;
    [self.spinner setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.status = [UILabel new]; self.status.numberOfLines = 0; self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; self.status.textColor = AMUpdateMuted();
    self.action = [UIButton buttonWithType:UIButtonTypeSystem]; self.action.titleLabel.font = AMUpdateFont(16, UIFontWeightSemibold, UIFontTextStyleBody); self.action.titleLabel.numberOfLines = 0; self.action.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.action.contentEdgeInsets = UIEdgeInsetsMake(15, 16, 15, 16); self.action.layer.cornerRadius = 14;
    [self.action.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
    [self.action setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; [self.action setTitleColor:AMUpdateAccent() forState:UIControlStateDisabled];
    [self.action setTitle:@"正在处理…" forState:UIControlStateDisabled];
    [self.action addTarget:self action:@selector(performAction) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[stepper,divider,phase,self.status,self.action]]; card.axis = UILayoutConstraintAxisVertical; card.spacing = 16;
    card.layoutMarginsRelativeArrangement = YES; card.layoutMargins = UIEdgeInsetsMake(24, 20, 20, 20);
    card.backgroundColor = UIColor.whiteColor; card.layer.cornerRadius = 24;
    [card setCustomSpacing:24 afterView:stepper]; [card setCustomSpacing:24 afterView:divider]; [card setCustomSpacing:10 afterView:phase]; [card setCustomSpacing:24 afterView:self.status];
    UILabel *hint = [UILabel new]; hint.text = self.retiredBeta ? @"正式版会单独安装。请先备份工程，导入正式版并检查后，再删除 Beta。" : @"请保留原应用，覆盖安装可保留本机工程。\n若证书临近到期或可能失效，建议提前备份重要工程。";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; hint.textColor = AMUpdateMuted(); hint.numberOfLines = 0;
    for (UILabel *label in @[title,subtitle,self.phaseTitle,self.status,hint]) { label.adjustsFontForContentSizeCategory = YES; [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical]; }
    for (UILabel *label in names) label.adjustsFontForContentSizeCategory = YES;
    self.action.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.webHost = [UIView new]; self.webHost.hidden = YES; self.webHost.backgroundColor = UIColor.whiteColor; self.webHost.layer.cornerRadius = 20; self.webHost.clipsToBounds = YES;
    NSLayoutConstraint *webHeight = [self.webHost.heightAnchor constraintEqualToConstant:420]; webHeight.priority = UILayoutPriorityDefaultHigh; webHeight.active = YES;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[header,card,hint,self.webHost]]; content.axis = UILayoutConstraintAxisVertical; content.spacing = 20; [content setCustomSpacing:28 afterView:header]; content.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll]; [scroll addSubview:content];
    NSLayoutConstraint *width = [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]; width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20], [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [content.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor], width, [content.widthAnchor constraintLessThanOrEqualToConstant:520],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20], [content.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
}
- (void)setStage:(NSInteger)stage title:(NSString *)title {
    self.phaseTitle.text = title;
    for (NSUInteger index = 0; index < self.stepNumbers.count; index++) {
        UILabel *number = self.stepNumbers[index], *name = self.stepNames[index];
        number.text = index < stage ? @"✓" : [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
        number.backgroundColor = index <= stage ? [UIColor colorWithRed:0.90 green:0.97 blue:0.95 alpha:1] : [UIColor colorWithWhite:0.95 alpha:1];
        number.textColor = index <= stage ? AMUpdateAccent() : AMUpdateMuted(); name.textColor = index == stage ? AMUpdateInk() : AMUpdateMuted();
        name.accessibilityLabel = [NSString stringWithFormat:@"%@，%@",name.text,index < stage ? @"已完成" : (index == stage ? @"当前步骤" : @"待进行")];
    }
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"软件更新";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    self.bundle = NSBundle.mainBundle.bundleIdentifier; self.channel = info[@"AMProjReleaseChannel"]; self.releaseCode = [info[@"AMProjReleaseCode"] integerValue];
    self.targetBundle = self.retiredBeta ? @"com.ayakameow.am" : self.bundle;
    self.pendingKey = [NSString stringWithFormat:@"AMAppUpdateRequest-%@-%@-%ld",self.bundle,self.channel,(long)self.releaseCode];
    [self buildUpdateView];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 40; config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    __weak typeof(self) weakSelf = self;
    self.foregroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (weakSelf.web && !weakSelf.busy) { [weakSelf.web reload]; }
    }];
    NSString *bundled = [info[@"AMAppUpdate"] isKindOfClass:NSDictionary.class] ? info[@"AMAppUpdate"][@"token"] : nil;
    NSString *team = AMUpdateProfileTeam();
    for (NSString *candidate in @[bundled ?: @"", AMUpdateSavedToken() ?: @""]) {
        NSDictionary *claim = AMAppUpdateClaim(candidate, self.bundle, self.channel, self.releaseCode);
        if (claim && [claim[@"teamId"] isEqual:team]) { self.token = candidate; break; }
    }
    if (self.token.length && !self.retiredBeta) [self prepare]; else [self showAssociation];
}
- (void)setBusy:(BOOL)busy message:(NSString *)message {
    self.busy = busy; self.action.enabled = !busy; self.status.text = message;
    self.action.backgroundColor = busy ? [UIColor colorWithRed:0.90 green:0.97 blue:0.95 alpha:1] : AMUpdateInk();
    if (busy) [self.spinner startAnimating]; else [self.spinner stopAnimating];
}
- (void)close {
    self.stopped = YES; [self.task cancel]; [self.session invalidateAndCancel];
    if (self.foregroundObserver) [NSNotificationCenter.defaultCenter removeObserver:self.foregroundObserver];
    self.foregroundObserver = nil; self.web.navigationDelegate = nil; self.web.UIDelegate = nil;
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)request:(NSURL *)url body:(NSDictionary *)body completion:(void (^)(NSDictionary *, NSInteger, NSError *))completion {
    if (self.stopped || !AMAppUpdateTrustedURL(url, @"/api/")) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (body) {
        request.HTTPMethod = @"POST"; [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        if (self.token.length && ([@[@"/api/app-update/prepare",@"/api/app-update/ready"] containsObject:url.path])) [request setValue:[@"Bearer " stringByAppendingString:self.token] forHTTPHeaderField:@"Authorization"];
    }
    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf && !weakSelf.stopped) completion([object isKindOfClass:NSDictionary.class] ? object : nil, status, error); });
    }]; [self.task resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response;
    // Update credentials must never follow an HTTP redirect, including same-host paths.
    completionHandler(nil);
}
- (void)performAction {
    if (self.associationRulesFailed) [self loadAssociationPage];
    else if (self.manifest) [self install];
    else if (self.web) [self associate];
    else [self prepare];
}
- (void)prepare {
    if (self.busy || self.stopped) return;
    [self setStage:1 title:@"准备更新"];
    self.requestId = [NSUserDefaults.standardUserDefaults stringForKey:self.pendingKey];
    if (!self.requestId.length) { self.requestId = NSUUID.UUID.UUIDString; [NSUserDefaults.standardUserDefaults setObject:self.requestId forKey:self.pendingKey]; }
    [self.action setTitle:@"重试更新" forState:UIControlStateNormal];
    [self setBusy:YES message:@"正在检查设备授权和最新安装包…"];
    [self request:[NSURL URLWithString:[AMUpdateOrigin stringByAppendingString:@"/api/app-update/prepare"]] body:@{@"requestId":self.requestId} completion:^(NSDictionary *data, NSInteger status, NSError *error) {
        if (error || status != 200 || ![data[@"ok"] isEqual:@YES]) {
            if (status == 410) [NSUserDefaults.standardUserDefaults removeObjectForKey:self.pendingKey];
            if (status == 401) { self.token = nil; [self showAssociation]; return; }
            [self setBusy:NO message:[data[@"error"] isKindOfClass:NSString.class] ? data[@"error"] : @"暂时无法连接更新服务，请检查网络后重试。"]; return;
        }
        if ([data[@"current"] isEqual:@YES]) { [self setBusy:NO message:@"网站当前发布的安装包没有比本机更新的版本。请稍后重新检查。"]; return; }
        NSURL *statusURL = [data[@"statusUrl"] isKindOfClass:NSString.class] ? [NSURL URLWithString:data[@"statusUrl"]] : nil;
        NSURL *manifest = [data[@"manifestUrl"] isKindOfClass:NSString.class] ? [NSURL URLWithString:data[@"manifestUrl"]] : nil;
        if (!AMAppUpdateTrustedURL(statusURL, @"/api/public/jobs/") || !AMAppUpdateTrustedURL(manifest, @"/ota/manifest/")) {
            [self setBusy:NO message:@"更新服务返回了无效安装地址，请联系管理员。"]; return;
        }
        self.manifest = manifest; self.deadline = [NSDate dateWithTimeIntervalSinceNow:600]; [self poll:statusURL];
    }];
}
- (void)poll:(NSURL *)url {
    if (self.stopped) return;
    [self request:url body:nil completion:^(NSDictionary *data, NSInteger status, NSError *error) {
        if (error || status != 200 || ![data[@"job"] isKindOfClass:NSDictionary.class]) {
            self.manifest = nil; [self setBusy:NO message:@"读取更新进度失败，可重试继续原任务。"]; return;
        }
        NSDictionary *job = data[@"job"]; NSString *phase = job[@"status"];
        if ([phase isEqual:@"succeeded"]) {
            if (![job[@"signed_bundle_id"] isEqual:self.targetBundle]) { self.manifest = nil; [self setBusy:NO message:@"安装包与目标应用不匹配，已停止更新。"]; return; }
            [self setBusy:NO message:@"安装包已准备好，正在请求系统安装确认。确认后由 iOS 继续下载和覆盖安装，请保留原应用。"];
            [self.action setTitle:@"再次请求安装" forState:UIControlStateNormal]; [self install]; return;
        }
        if ([phase isEqual:@"failed"]) {
            self.manifest = nil; [NSUserDefaults.standardUserDefaults removeObjectForKey:self.pendingKey];
            [self setBusy:NO message:[job[@"error_message"] isKindOfClass:NSString.class] ? job[@"error_message"] : @"安装包签名失败，请重试或联系管理员。"]; return;
        }
        if (![@[@"queued",@"running"] containsObject:phase]) { self.manifest = nil; [self setBusy:NO message:@"更新任务状态异常，请稍后重试。"]; return; }
        if (self.deadline.timeIntervalSinceNow <= 0) { self.manifest = nil; [self setBusy:NO message:@"安装包准备时间较长，可稍后重试继续原任务。"]; return; }
        [self setBusy:YES message:[phase isEqual:@"queued"] ? @"更新任务排队中，请稍候…" : @"正在为此设备签名并校验安装包，请稍候…"];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf poll:url]; });
    }];
}
- (void)install {
    if (self.busy || !AMAppUpdateTrustedURL(self.manifest, @"/ota/manifest/")) return;
    [self setBusy:YES message:@"正在核对网站当前安装包…"];
    [self request:[NSURL URLWithString:[AMUpdateOrigin stringByAppendingString:@"/api/app-update/ready"]] body:@{@"requestId":self.requestId ?: @""} completion:^(NSDictionary *data, NSInteger status, NSError *error) {
        NSURL *manifest = [data[@"manifestUrl"] isKindOfClass:NSString.class] ? [NSURL URLWithString:data[@"manifestUrl"]] : nil;
        if (error || status != 200 || !AMAppUpdateTrustedURL(manifest, @"/ota/manifest/")) {
            self.manifest = nil;
            if (status == 404 || status == 410) [NSUserDefaults.standardUserDefaults removeObjectForKey:self.pendingKey];
            [self.action setTitle:@"重新检查更新" forState:UIControlStateNormal];
            [self setBusy:NO message:[data[@"error"] isKindOfClass:NSString.class] ? data[@"error"] : @"暂时无法核对当前安装包，请检查网络后重试。"]; return;
        }
        self.manifest = manifest; [self requestSystemInstall];
    }];
}
- (void)requestSystemInstall {
    [self setStage:2 title:@"确认安装"];
    if (self.useInstallPage) { [self showInstallPage]; return; }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"itms-services://"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"action" value:@"download-manifest"], [NSURLQueryItem queryItemWithName:@"url" value:self.manifest.absoluteString]];
    [self setBusy:YES message:@"正在请求系统安装确认…"];
    [UIApplication.sharedApplication openURL:components.URL options:@{} completionHandler:^(BOOL opened) {
        if (self.stopped) return;
        if (!opened) {
            NSLog(@"[AMAppUpdate] system install URL declined; using validated installation page");
            self.useInstallPage = YES;
            [self showInstallPage]; return;
        }
        [self setBusy:NO message:self.retiredBeta ? @"正式版安装请求已交给系统。请确认安装，之后将备份导入正式版并检查工程，再删除 Beta。" : @"安装请求已交给系统，请在系统提示中确认。下载和安装进度请返回桌面查看；应用可能在覆盖安装时被系统关闭。"];
    }];
}
- (void)showInstallPage {
    NSURL *page = AMAppUpdateInstallPage(self.manifest);
    if (self.stopped) return;
    if (!page || self.presentedViewController || !self.viewIfLoaded.window) {
        [self setBusy:NO message:@"暂时无法打开安装确认，请关闭此页后重新检查更新。"]; return;
    }
    // 仅复用刚通过 ready 校验的同一任务；登记页的 WebKit 限制保持独立。
    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:page];
    browser.delegate = self;
    browser.preferredControlTintColor = [UIColor colorWithRed:0.06 green:0.57 blue:0.54 alpha:1];
    [self.action setTitle:@"继续安装" forState:UIControlStateNormal];
    [self setBusy:NO message:self.retiredBeta ? @"正式版已准备好，请在安装页点“安装到 iPhone”并确认。正式版单独安装，请先保留 Beta 和备份，确认工程导入正常后再删除 Beta。" : @"安装包已准备好，请在安装页点“安装到 iPhone”，再确认系统安装。正常覆盖更新会保留工程，请勿删除原应用。"];
    [self presentViewController:browser animated:YES completion:nil];
}
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
    if (!self.stopped) [self setBusy:NO message:@"如已确认系统安装，请返回桌面查看进度；如未出现确认，可点“继续安装”重试。"];
}
- (NSString *)associationMessage {
    return self.retiredBeta ? @"Beta 已结束。请先备份工程，在下方登记设备后安装正式版。正式版会单独安装，确认工程导入正常后再删除 Beta。" : @"本次安装尚未关联网站签名服务。请在下方完成一次设备登记，再点“完成登记，继续更新”。证书由服务器保管，之后可直接在 App 内更新。";
}
- (void)showAssociation {
    [self setStage:0 title:@"关联此设备"];
    [self setBusy:NO message:[self associationMessage]];
    [self.action setTitle:self.retiredBeta ? @"完成登记，安装正式版" : @"完成登记，继续更新" forState:UIControlStateNormal];
    if (self.web) return;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // This page only associates device authorization; web signing/OTA cannot bypass native identity checks.
    NSString *css = @"#install-button,#install-link,#job-status{display:none!important}";
    NSString *script = [NSString stringWithFormat:@"document.addEventListener('DOMContentLoaded',function(){var s=document.createElement('style');s.textContent='%@';document.head.appendChild(s);});",css];
    [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    self.webHost.hidden = NO;
    self.web = [[WKWebView alloc] initWithFrame:self.webHost.bounds configuration:configuration];
    self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.web.navigationDelegate = self; self.web.UIDelegate = self; [self.webHost addSubview:self.web];
    [self loadAssociationPage];
}
- (void)loadAssociationPage {
    if (self.stopped || self.busy || !self.web) return;
    self.associationRulesFailed = NO;
    [self setBusy:YES message:@"正在打开设备登记页…"];
    NSURL *url = AMAppUpdateTrustedURL(self.website, @"/") ? self.website : [NSURL URLWithString:AMUpdateOrigin];
    __weak typeof(self) weakSelf = self;
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"AMUpdateAssociationOnly-v2" encodedContentRuleList:AMAppUpdateAssociationRules() completionHandler:^(WKContentRuleList *list, NSError *error) {
        if (weakSelf.stopped || !weakSelf) return;
        if (error || !list) {
            NSLog(@"[AMAppUpdate] association rules failed: %@/%ld", error.domain, (long)error.code);
            weakSelf.associationRulesFailed = YES;
            [weakSelf.action setTitle:@"重新加载登记页" forState:UIControlStateNormal];
            [weakSelf setBusy:NO message:@"设备登记页未能加载，请点击下方按钮重试。"]; return;
        }
        [weakSelf.web.configuration.userContentController addContentRuleList:list];
        [weakSelf.web loadRequest:[NSURLRequest requestWithURL:url]];
        [weakSelf.action setTitle:weakSelf.retiredBeta ? @"完成登记，安装正式版" : @"完成登记，继续更新" forState:UIControlStateNormal];
        [weakSelf setBusy:NO message:[weakSelf associationMessage]];
    }];
}
- (void)associate {
    if (self.busy || !AMAppUpdateTrustedURL(self.web.URL, @"/")) return;
    NSString *team = AMUpdateProfileTeam();
    if (!team.length && !self.retiredBeta) { [self setBusy:NO message:@"无法读取本机签名身份，暂时无法关联覆盖更新。请先备份工程并联系管理员。"]; return; }
    [self setBusy:YES message:@"正在关联此设备的安装授权…"];
    [self.web evaluateJavaScript:@"localStorage.getItem('meow_install_udid_request')" completionHandler:^(id session, NSError *scriptError) {
        if (self.stopped) return;
        if (scriptError || ![session isKindOfClass:NSString.class] || [session length] != 48) { [self setBusy:NO message:@"请先在下方完成设备登记，再继续更新。"]; return; }
        [self request:[NSURL URLWithString:[AMUpdateOrigin stringByAppendingString:@"/api/app-update/link"]] body:@{@"websiteSession":session,@"bundleId":self.bundle,@"channel":self.channel ?: @"",@"release":@(self.releaseCode),@"teamId":team ?: @"",@"migration":@(self.retiredBeta)} completion:^(NSDictionary *data, NSInteger status, NSError *error) {
            NSString *token = [data[@"token"] isKindOfClass:NSString.class] ? data[@"token"] : nil;
            NSDictionary *claim = AMAppUpdateClaim(token, self.targetBundle, self.retiredBeta ? @"stable" : self.channel, self.retiredBeta ? 0 : self.releaseCode);
            if (error || status != 200 || !claim || (!self.retiredBeta && ![claim[@"teamId"] isEqual:team])) {
                [self setBusy:NO message:[data[@"error"] isKindOfClass:NSString.class] ? data[@"error"] : @"设备关联未完成，请完成下方登记或联系管理员检查签名身份。"]; return;
            }
            self.token = token; if (!self.retiredBeta) AMUpdateSaveToken(token); self.web.navigationDelegate = nil; self.web.UIDelegate = nil;
            [self.web removeFromSuperview]; self.web = nil; self.webHost.hidden = YES; self.busy = NO; [self prepare];
        }];
    }];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    BOOL trusted = AMAppUpdateTrustedURL(url, @"/");
    BOOL profile = trusted && [url.path hasPrefix:@"/udid/mobileconfig/"];
    BOOL install = [url.path hasPrefix:@"/install/"] || [url.path hasPrefix:@"/ota/"] || [url.path hasPrefix:@"/api/public/sign/"];
    if (trusted && !profile && !install) { decisionHandler(WKNavigationActionPolicyAllow); return; }
    decisionHandler(WKNavigationActionPolicyCancel);
    if (profile) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL opened) {
            if (!opened) [self setBusy:NO message:@"系统未能打开此操作，请重试或联系管理员。"];
        }];
    }
    (void)webView;
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!action.targetFrame) [webView loadRequest:action.request];
    (void)configuration; (void)windowFeatures; return nil;
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) [self setBusy:NO message:@"安装服务加载失败，请检查网络后重试。"]; (void)webView; (void)navigation;
}
@end

void AMAppUpdatePresent(UIViewController *presenter, NSURL *website, BOOL retiredBeta) {
    if (!presenter.viewIfLoaded.window || presenter.presentedViewController) return;
    AMAppUpdateController *update = [AMAppUpdateController new]; update.website = website; update.retiredBeta = retiredBeta;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:update];
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    navigation.modalPresentationStyle = UIModalPresentationFullScreen; navigation.modalInPresentation = YES;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
