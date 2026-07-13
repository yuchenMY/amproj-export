// WebHome.m — AyakaMeow WebHome (纯 ObjC 注入 dylib, 不依赖 logos/Substrate/hook)
//
// 目标(参考 AutSheng / Am X): 保留 AM 原生的顶栏 + 自定义底部 tab 栏,只把中间那块
// 空白的 feed 区(FeedVC,原生依赖被墙的 Firebase Firestore 所以空白)填成你的网页内容
// (https://am.ayakameow.cn/home)。切到"项目/模板"等 tab 仍是原生。
//
// 做法: 运行时按类名找到 FeedVC 实例(NSStringFromClass 含 "FeedVC"),把一个承载
// WKWebView 的子控制器 addChildViewController 进去、铺满它的 view。因为 FeedVC.view
// 只在主页 tab 显示,所以天然"只在主页出现、切别的 tab 自动让开",无需 hook 自定义 tab 栏。
//
// 兜底: 万一找不到 FeedVC(结构变动),退回"全屏覆盖窗口"(穿透 + 右下角切换按钮),
// 保证绝不白屏、原生仍可达。
//
// 首页地址改 kHomeURL。

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kHomeURL = @"https://am.ayakameow.cn/home";
static const NSTimeInterval kInstallDelay = 0.30;

static UIColor *AMBg(void)   { return [UIColor colorWithRed:0.957 green:0.961 blue:0.973 alpha:1.0]; } // #f4f5f8 浅色, 与 H5 一致
static UIColor *AMPink(void) { return [UIColor colorWithRed:0.94 green:0.40 blue:0.58 alpha:1.0]; }  // #f06595

#pragma mark - 穿透视图/窗口(仅"全屏兜底"模式用)

@interface AMPassthroughView : UIView
@end
@implementation AMPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

@interface AMOverlayWindow : UIWindow
@end
@implementation AMOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil; // 空白 -> 穿透到下层原生
    return hit;
}
@end

#pragma mark - 承载网页的控制器(既可作为 FeedVC 的子控制器嵌入, 也可作为兜底窗口的 root)

@interface AMHomeController : UIViewController <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, assign) BOOL embedded;   // YES=嵌进原生 FeedVC(无浮动按钮/无穿透); NO=全屏兜底
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UIActivityIndicatorView *spin;
@property (nonatomic, strong) UIView *errorView;
@property (nonatomic, strong) UIButton *toggle;
@property (nonatomic, strong) UIRefreshControl *refresh;
@property (nonatomic, strong) id msgProxy;
@property (nonatomic, assign) BOOL webShown;
@end

// 弱代理: 断开 WKUserContentController<->controller 循环引用。
@interface AMMsgProxy : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) AMHomeController *owner;
@end
@implementation AMMsgProxy
- (void)userContentController:(WKUserContentController *)uc didReceiveScriptMessage:(WKScriptMessage *)m {
    [self.owner userContentController:uc didReceiveScriptMessage:m];
}
@end

@implementation AMHomeController

- (void)loadView {
    // 嵌入模式用普通视图(铺满 FeedVC); 兜底模式用穿透视图(空白处触摸落到原生)。
    self.view = self.embedded ? [[UIView alloc] init] : (UIView *)[[AMPassthroughView alloc] init];
    self.view.backgroundColor = self.embedded ? AMBg() : [UIColor clearColor];
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidLoad {
    [super viewDidLoad];

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    AMMsgProxy *proxy = [[AMMsgProxy alloc] init];
    proxy.owner = self; self.msgProxy = proxy;
    [cfg.userContentController addScriptMessageHandler:proxy name:@"amnative"];
    cfg.allowsInlineMediaPlayback = YES;

    WKWebView *web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    web.navigationDelegate = self;
    web.opaque = NO;
    web.backgroundColor = AMBg();
    web.scrollView.backgroundColor = AMBg();
    if (@available(iOS 11.0, *)) web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
    [self.view addSubview:web];
    self.web = web;

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    rc.tintColor = AMPink();
    [rc addTarget:self action:@selector(onRefresh) forControlEvents:UIControlEventValueChanged];
    web.scrollView.refreshControl = rc;
    self.refresh = rc;

    UIActivityIndicatorView *spin;
    if (@available(iOS 13.0, *)) spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    else                        spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    spin.color = AMPink();
    spin.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:spin];
    [NSLayoutConstraint activateConstraints:@[
        [spin.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [spin.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
    self.spin = spin;

    // 只有"全屏兜底"模式才加右下角浮动切换按钮; 嵌入模式靠原生 tab 栏导航。
    if (!self.embedded) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        b.layer.cornerRadius = 20; b.layer.borderWidth = 1;
        b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 14);
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
        [NSLayoutConstraint activateConstraints:@[
            [b.heightAnchor constraintEqualToConstant:40],
            [b.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14],
            [b.bottomAnchor   constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor  constant:-72],
        ]];
        self.toggle = b;
    }

    self.webShown = YES;
    [self loadHome];
    [self reflectMode];
}

#pragma mark 加载 / 刷新 / 错误

- (void)loadHome {
    [self hideError];
    [self.spin startAnimating];
    NSURL *u = [NSURL URLWithString:kHomeURL];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u
                                                    cachePolicy:NSURLRequestReloadRevalidatingCacheData
                                                timeoutInterval:20.0];
    [self.web loadRequest:r];
}
- (void)onRefresh { [self.web reloadFromOrigin]; }
- (void)onRetry   { [self loadHome]; }

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    [self.spin stopAnimating]; [self.refresh endRefreshing]; [self hideError];
}
- (void)webView:(WKWebView *)wv didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e { [self showError]; }
- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)n withError:(NSError *)e { [self showError]; }

- (void)hideError { [self.errorView removeFromSuperview]; self.errorView = nil; }

- (void)showError {
    [self.spin stopAnimating]; [self.refresh endRefreshing];
    if (self.errorView) return;
    UIView *ev = [[UIView alloc] initWithFrame:self.view.bounds];
    ev.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ev.backgroundColor = AMBg();

    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    l.font = [UIFont systemFontOfSize:15];
    l.text = @"🐱\n首页加载失败\n检查网络后点下方重试";
    [ev addSubview:l];

    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    rb.translatesAutoresizingMaskIntoConstraints = NO;
    [rb setTitle:@"重试" forState:UIControlStateNormal];
    [rb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    rb.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    rb.backgroundColor = AMPink(); rb.layer.cornerRadius = 12;
    rb.contentEdgeInsets = UIEdgeInsetsMake(11, 34, 11, 34);
    [rb addTarget:self action:@selector(onRetry) forControlEvents:UIControlEventTouchUpInside];
    [ev addSubview:rb];

    [self.view addSubview:ev];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:ev.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:ev.centerYAnchor constant:-30],
        [l.widthAnchor  constraintLessThanOrEqualToAnchor:ev.widthAnchor multiplier:0.86],
        [rb.centerXAnchor constraintEqualToAnchor:ev.centerXAnchor],
        [rb.topAnchor constraintEqualToAnchor:l.bottomAnchor constant:22],
    ]];
    self.errorView = ev;
    if (self.toggle) [self.view bringSubviewToFront:self.toggle];
}

#pragma mark 切换(仅兜底模式)

- (void)onToggle { self.webShown = !self.webShown; [self reflectMode]; }

- (void)userContentController:(WKUserContentController *)uc didReceiveScriptMessage:(WKScriptMessage *)m {
    NSString *action = nil;
    if ([m.body isKindOfClass:[NSString class]]) action = (NSString *)m.body;
    else if ([m.body isKindOfClass:[NSDictionary class]]) action = ((NSDictionary *)m.body)[@"action"];
    if (self.embedded) return; // 嵌入模式不需要 JS 切原生(原生 tab 栏就在)
    if ([action isEqualToString:@"openEditor"] || [action isEqualToString:@"native"]) { self.webShown = NO; [self reflectMode]; }
    else if ([action isEqualToString:@"home"] || [action isEqualToString:@"web"]) { self.webShown = YES; [self reflectMode]; }
    else if ([action isEqualToString:@"reload"]) { [self loadHome]; }
}

- (void)reflectMode {
    if (self.embedded) return; // 嵌入模式恒显示
    BOOL shown = self.webShown;
    self.web.hidden = !shown;
    self.errorView.hidden = !shown;
    if (!shown) [self.spin stopAnimating];
    [self.toggle setTitle:(shown ? @"编辑器 ›" : @"🐱 首页") forState:UIControlStateNormal];
    [self.view bringSubviewToFront:self.toggle];
}

@end

#pragma mark - 运行时查找 VC / keyWindow

static UIViewController *AMFindVC(UIViewController *root, NSString *sub) {
    if (!root) return nil;
    @try {
        if ([NSStringFromClass([root class]) containsString:sub]) return root;
    } @catch (__unused NSException *e) {}
    for (UIViewController *c in root.childViewControllers) {
        UIViewController *r = AMFindVC(c, sub); if (r) return r;
    }
    UIViewController *p = root.presentedViewController;
    if (p) { UIViewController *r = AMFindVC(p, sub); if (r) return r; }
    return nil;
}

static UIWindow *AMAppKeyWindow(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
                if (!key) key = w;
            }
            if (key) break;
        }
    }
    if (!key) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) { if (w.isKeyWindow) { key = w; break; } }
        if (!key) key = UIApplication.sharedApplication.keyWindow;
        #pragma clang diagnostic pop
    }
    return key;
}

#pragma mark - 把底部 "Home v19D" 改成 "主页"(底包 mod 运行时贴的标签)

static void AMRenameHomeTab(UIView *root) {
    if (!root) return;
    if ([root isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)root).text;
        if (t && [t hasPrefix:@"Home v"]) ((UILabel *)root).text = @"主页";
    } else if ([root isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)root;
        NSString *t = b.currentTitle ? b.currentTitle : b.titleLabel.text;
        if (t && [t hasPrefix:@"Home v"]) [b setTitle:@"主页" forState:UIControlStateNormal];
    }
    for (UIView *sub in root.subviews) AMRenameHomeTab(sub);
}
static UIWindow *AMAppKeyWindow(void); // 前向声明
static void AMScheduleTabRename(void) {
    double delays[] = {0.0, 0.6, 1.5, 3.0};
    for (int i = 0; i < 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ UIWindow *w = AMAppKeyWindow(); if (w) AMRenameHomeTab(w); });
    }
}

#pragma mark - 卡密激活 gate(启动先验卡密, 通过才放进 App)

static NSString *const kBase   = @"https://am.ayakameow.cn";
static NSString *const kDefKey = @"amwh_card_key";
static NSString *const kDefExp = @"amwh_card_exp";
static BOOL      gUnlocked   = NO;
static UIWindow *gGateWindow = nil;
static UIWindow *gAppWindow  = nil;

static void AMInstall(void);         // 前向声明(解锁后装网页首页)

static NSString *AMDeviceID(void) {
    NSString *idv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    return idv.length ? idv : @"unknown-device";
}

// POST JSON -> 主线程回调 cb(ok, json)。
static void AMPost(NSString *path, NSDictionary *body, void (^cb)(BOOL ok, NSDictionary *json)) {
    NSURL *u = [NSURL URLWithString:[kBase stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:15.0];
    r.HTTPMethod = @"POST";
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:r
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *json = nil; BOOL ok = NO;
        if (data) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) { json = j; ok = [json[@"ok"] boolValue]; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ cb(ok && !err, json); });
    }];
    [t resume];
}

#pragma mark - 全局接管: Oracle NSURLProtocol + 假用户 + 登录弹窗清理

// 策略:
//   A. NSURLProtocol 拦截 oracle.bendingspoonsapps.com → am.ayakameow.cn
//   B. 伪造 FIRAuth.currentUser → 跳过 AppID 登录
//   C. 窗口扫描 → 清除遗留登录弹窗
//
// NSURLProtocol 在 +load 注册(dyld 加载 dylib 时触发), 早于任何 App 代码

// ---- A: NSURLProtocol 重定向 Oracle → am.ayakameow.cn ----
@interface AMOracleRedirectProtocol : NSURLProtocol
@end
@implementation AMOracleRedirectProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)req {
    NSString *host = req.URL.host;
    if ([host containsString:@"oracle.bendingspoonsapps.com"]) return YES;
    if ([host containsString:@"janus.bendingspoons.com"]) return YES;
    return NO;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)req { return req; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b { return NO; }

- (void)startLoading {
    NSURL *orig = self.request.URL;
    NSString *newHost = nil;
    if ([orig.host containsString:@"oracle.bendingspoonsapps.com"]) newHost = @"am.ayakameow.cn";
    else if ([orig.host containsString:@"janus.bendingspoons.com"]) newHost = @"am.ayakameow.cn/api/oracle/janus";
    if (!newHost) { [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"AM" code:-1 userInfo:nil]]; return; }

    NSURLComponents *c = [NSURLComponents componentsWithURL:orig resolvingAgainstBaseURL:NO];
    c.scheme = @"https"; c.host = newHost;
    if ([newHost containsString:@"/"]) { NSRange r = [newHost rangeOfString:@"/"]; c.host = [newHost substringToIndex:r.location]; c.path = [NSString stringWithFormat:@"%@%@", [newHost substringFromIndex:r.location], c.path]; }
    NSMutableURLRequest *r = [self.request mutableCopy]; r.URL = c.URL;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        if (err) { [self.client URLProtocol:self didFailWithError:err]; }
        else {
            [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (d) [self.client URLProtocol:self didLoadData:d];
            [self.client URLProtocolDidFinishLoading:self];
        }
    }];
    [task resume];
}
- (void)stopLoading {}
@end

// ---- B: 伪造 Firebase 用户(跳过 AppID 登录) ----
@interface AMFakeFirebaseUser : NSObject
@end
@implementation AMFakeFirebaseUser
- (NSString *)uid { return @"ayakameow-pro"; }
- (BOOL)isAnonymous { return NO; }
- (BOOL)isEmailVerified { return YES; }
@end

static id (*orig_FIRAuth_currentUser)(id, SEL);
static id hooked_FIRAuth_currentUser(id self, SEL _cmd) {
    id real = orig_FIRAuth_currentUser(self, _cmd);
    if (real) return real;
    static AMFakeFirebaseUser *fu = nil;
    if (!fu) fu = [AMFakeFirebaseUser new];
    return fu;
}

static void AMInstallLoginBypass(void) {
    Class c = NSClassFromString(@"FIRAuth");
    if (!c) return;
    Method m = class_getInstanceMethod(c, @selector(currentUser));
    if (!m || orig_FIRAuth_currentUser) return;
    orig_FIRAuth_currentUser = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_FIRAuth_currentUser);
}

// ---- 安装所有 Hook ----
static void AMInstallAllHooks(void) {
    [NSURLProtocol registerClass:[AMOracleRedirectProtocol class]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ AMInstallLoginBypass(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ AMInstallLoginBypass(); });
}

static void AMUnlock(void) {
    gUnlocked = YES;
    if (gGateWindow) { gGateWindow.hidden = YES; gGateWindow = nil; }
    if (gAppWindow) [gAppWindow makeKeyAndVisible];
    AMInstall();
}

@interface AMGateController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UILabel *status;
@end
@implementation AMGateController
- (void)loadView { self.view = [[UIView alloc] init]; self.view.backgroundColor = AMBg(); }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }
- (void)viewDidLoad {
    [super viewDidLoad];
    UILabel *logo = [[UILabel alloc] init]; logo.text = @"🐱"; logo.font = [UIFont systemFontOfSize:60]; logo.textAlignment = NSTextAlignmentCenter;
    UILabel *title = [[UILabel alloc] init]; title.text = @"激活 AyakaMeow"; title.font = [UIFont boldSystemFontOfSize:22]; title.textColor = [UIColor colorWithWhite:0.12 alpha:1]; title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = [[UILabel alloc] init]; sub.text = @"输入卡密即可解锁使用"; sub.font = [UIFont systemFontOfSize:14]; sub.textColor = [UIColor colorWithWhite:0.5 alpha:1]; sub.textAlignment = NSTextAlignmentCenter;

    UITextField *f = [[UITextField alloc] init];
    f.placeholder = @"AYK-XXXX-XXXX"; f.textAlignment = NSTextAlignmentCenter;
    f.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters; f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.borderStyle = UITextBorderStyleRoundedRect; f.font = [UIFont systemFontOfSize:18]; f.delegate = self; f.returnKeyType = UIReturnKeyGo;
    [f.heightAnchor constraintEqualToConstant:48].active = YES;

    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:@"激 活" forState:UIControlStateNormal]; [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17]; b.backgroundColor = AMPink(); b.layer.cornerRadius = 12;
    [b addTarget:self action:@selector(onActivate) forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:50].active = YES;

    UILabel *st = [[UILabel alloc] init]; st.numberOfLines = 0; st.textAlignment = NSTextAlignmentCenter; st.font = [UIFont systemFontOfSize:13]; st.textColor = AMPink();

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo, title, sub, f, b, st]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:22 afterView:sub]; [stack setCustomSpacing:18 afterView:f];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-40],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:36],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-36],
    ]];
    self.field = f; self.btn = b; self.status = st;

    // 预填上次的卡密(到期换卡时方便看); 不自动联网校验 —— 启动放行由 AMBoot 本地判定。
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kDefKey];
    if (saved.length) f.text = saved;
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self onActivate]; return NO; }
- (void)setBusy:(BOOL)busy msg:(NSString *)msg ok:(BOOL)ok {
    self.btn.enabled = !busy;
    self.status.textColor = ok ? AMPink() : [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1];
    self.status.text = msg ? msg : @"";
}
- (void)verifySaved {
    [self setBusy:YES msg:@"验证中…" ok:YES];
    NSString *code = self.field.text ? self.field.text : @"";
    [self.field resignFirstResponder];
    AMPost(@"/api/verify", @{ @"code": code, @"device": AMDeviceID() }, ^(BOOL ok, NSDictionary *json) {
        if (ok) {
            id exp = json[@"expires_at"]; if (exp) [[NSUserDefaults standardUserDefaults] setObject:exp forKey:kDefExp];
            AMUnlock(); return;
        }
        BOOL soft = json && [json[@"soft"] boolValue];
        double exp = [[NSUserDefaults standardUserDefaults] doubleForKey:kDefExp];
        double now = [[NSDate date] timeIntervalSince1970] * 1000.0;
        if (soft && exp > now) { AMUnlock(); return; } // 断网/服务器忙 + 本地未到期 -> 宽限放行
        if (!soft) [[NSUserDefaults standardUserDefaults] removeObjectForKey:kDefKey];
        [self setBusy:NO msg:(soft ? @"网络异常, 请重试" : (json[@"message"] ? json[@"message"] : @"卡密无效或已到期")) ok:NO];
    });
}
- (void)onActivate {
    NSString *code = [(self.field.text ? self.field.text : @"") uppercaseString];
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (code.length < 6) { [self setBusy:NO msg:@"请输入完整卡密" ok:NO]; return; }
    [self setBusy:YES msg:@"激活中…" ok:YES];
    [self.field resignFirstResponder];
    AMPost(@"/api/activate", @{ @"code": code, @"device": AMDeviceID() }, ^(BOOL ok, NSDictionary *json) {
        if (ok) {
            [[NSUserDefaults standardUserDefaults] setObject:code forKey:kDefKey];
            id exp = json[@"expires_at"]; if (exp) [[NSUserDefaults standardUserDefaults] setObject:exp forKey:kDefExp];
            AMUnlock(); return;
        }
        [self setBusy:NO msg:(json[@"message"] ? json[@"message"] : @"激活失败, 请检查卡密") ok:NO];
    });
}
@end

// 定时扫描并干掉 Firebase Auth / 原版登录等弹窗, 确保卡密页始终在最上层
static void AMDismissAuthTick(void) {
    if (!gGateWindow) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)scene).windows) {
            if (win == gGateWindow) continue;
            if (win.windowLevel >= gGateWindow.windowLevel) win.windowLevel = gGateWindow.windowLevel - 100;
            if (!win.hidden && win != gAppWindow) win.hidden = YES;
        }
    }
    UIViewController *root = gAppWindow.rootViewController;
    while (root.presentedViewController) {
        [root.presentedViewController dismissViewControllerAnimated:NO completion:nil];
    }
}

static void AMDismissAuthScreens(void) {
    AMDismissAuthTick();
    static dispatch_source_t timer = nil;
    if (!timer) {
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC, 0.05 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ AMDismissAuthTick(); });
        dispatch_resume(timer);
    }
}

static void AMShowGate(void) {
    if (gGateWindow) return;
    UIWindow *app = AMAppKeyWindow();
    gAppWindow = app;
    // 先干掉任何已弹出的登录页
    AMDismissAuthScreens();
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) { if (app.windowScene) w = [[UIWindow alloc] initWithWindowScene:app.windowScene]; }
    if (!w) w = [[UIWindow alloc] initWithFrame:(app ? app.bounds : UIScreen.mainScreen.bounds)];
    w.windowLevel = UIWindowLevelAlert + 999; // 最高层级, 盖住 Firebase Auth + 原版登录
    w.backgroundColor = AMBg();
    w.rootViewController = [[AMGateController alloc] init];
    [w makeKeyAndVisible];
    gGateWindow = w;
}

// 启动决策:
//  - 已解锁 -> 装首页;
//  - 本地存过卡密且未到期 -> 直接放行, **完全不联网重验**(退出重进/断网/加速器都不影响);
//  - 没卡密 或 本地已到期 -> 弹激活页要卡密(只有首次激活那下才联网, 见 AMGateController)。
static void AMBoot(void) {
    if (gUnlocked) { AMInstall(); return; }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *key = [ud stringForKey:kDefKey];
    double exp = [ud doubleForKey:kDefExp];
    double now = [[NSDate date] timeIntervalSince1970] * 1000.0;
    if (key.length > 0 && (exp <= 0 || exp > now)) { AMUnlock(); return; } // 本地放行, 零联网
    AMShowGate();
}

#pragma mark - 安装(主: 嵌入 FeedVC; 兜底: 全屏覆盖窗口)

static AMHomeController *gHome = nil;
static UIWindow *gOverlayWindow = nil;
static BOOL gInstalled = NO;
static int  gTries = 0;

static void AMEmbedInFeed(UIViewController *feed) {
    gHome = [[AMHomeController alloc] init];
    gHome.embedded = YES;
    [feed addChildViewController:gHome];
    gHome.view.translatesAutoresizingMaskIntoConstraints = NO;
    [feed.view addSubview:gHome.view];
    [NSLayoutConstraint activateConstraints:@[
        [gHome.view.topAnchor      constraintEqualToAnchor:feed.view.topAnchor],
        [gHome.view.leadingAnchor  constraintEqualToAnchor:feed.view.leadingAnchor],
        [gHome.view.trailingAnchor constraintEqualToAnchor:feed.view.trailingAnchor],
        [gHome.view.bottomAnchor   constraintEqualToAnchor:feed.view.bottomAnchor],
    ]];
    [gHome didMoveToParentViewController:feed];
}

static void AMFallbackOverlay(UIWindow *appWin) {
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        if (appWin.windowScene) w = [[AMOverlayWindow alloc] initWithWindowScene:appWin.windowScene];
    }
    if (!w) w = [[AMOverlayWindow alloc] initWithFrame:appWin.bounds];
    w.frame = appWin.bounds;
    w.windowLevel = UIWindowLevelNormal + 100;
    w.backgroundColor = [UIColor clearColor];
    gHome = [[AMHomeController alloc] init];
    gHome.embedded = NO;
    w.rootViewController = gHome;
    [w makeKeyAndVisible];
    [appWin makeKeyAndVisible];
    w.hidden = NO;
    gOverlayWindow = w;
}

static void AMInstall(void) {
    if (gInstalled) return;
    UIWindow *w = AMAppKeyWindow();
    if (!w || !w.rootViewController) {
        if (gTries++ < 60) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                                          dispatch_get_main_queue(), ^{ AMInstall(); });
        return;
    }
    // 主路径: 找到原生 FeedVC, 把网页铺进它的 view(保留原生顶/底栏, 天然只在主页显示)。
    UIViewController *feed = AMFindVC(w.rootViewController, @"FeedVC");
    if (feed && feed.isViewLoaded) {
        gInstalled = YES;
        AMEmbedInFeed(feed);
        AMScheduleTabRename();
        return;
    }
    // 还没就绪就重试, ~15s。
    if (gTries++ < 60) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ AMInstall(); });
        return;
    }
    // 兜底: 一直找不到 FeedVC -> 全屏覆盖窗口, 绝不白屏。
    gInstalled = YES;
    AMFallbackOverlay(w);
    AMScheduleTabRename();
}

#pragma mark - 构造器

__attribute__((constructor))
static void AMInit(void) {
    @autoreleasepool {
        // Oracle 重定向 + 假用户 + 登录弹窗清理
        AMInstallAllHooks();

        void (^arm)(NSNotificationName) = ^(NSNotificationName name) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInstallDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ AMBoot(); });
            }];
        };
        arm(UIApplicationDidFinishLaunchingNotification);
        arm(UIApplicationDidBecomeActiveNotification);
    }
}
