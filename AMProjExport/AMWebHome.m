#import "AMWebHome.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const AMWebHomeURLString = @"https://amhome.meowcr.cn/home";
static const void *AMWebHomeControllerKey = &AMWebHomeControllerKey;
static const void *AMWebHomeOriginalIMPKey = &AMWebHomeOriginalIMPKey;

static BOOL AMWebHomeAttachToFeedController(UIViewController *feed);

static BOOL AMWebHomeIsTrustedURL(NSURL *url) {
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"amhome.meowcr.cn"]) {
        return NO;
    }
    return url.port == nil || url.port.integerValue == 443;
}

static void AMWebHomeCollectTabControllers(
    UIViewController *controller, NSMutableSet<NSValue *> *visited,
    NSMutableArray<UITabBarController *> *tabs, NSUInteger depth) {
    if (!controller || depth > 24) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if ([controller isKindOfClass:UITabBarController.class]) {
        [tabs addObject:(UITabBarController *)controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        AMWebHomeCollectTabControllers(child, visited, tabs, depth + 1);
    }
    AMWebHomeCollectTabControllers(controller.presentedViewController, visited,
                                   tabs, depth + 1);
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
            AMWebHomeCollectTabControllers(child, visited, tabs, depth + 1);
        }
    }
}

static BOOL AMWebHomeSelectProjectsTab(void) {
    NSMutableArray<UITabBarController *> *tabs = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01) {
                    AMWebHomeCollectTabControllers(window.rootViewController,
                                                   visited, tabs, 0);
                }
            }
        }
    } else {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (!window.hidden && window.alpha > 0.01) {
                AMWebHomeCollectTabControllers(window.rootViewController,
                                               visited, tabs, 0);
            }
        }
    }

    UITabBarController *bestTabs = nil;
    UIViewController *bestBranch = nil;
    NSInteger bestScore = 0;
    for (UITabBarController *tabController in tabs) {
        for (UIViewController *branch in tabController.viewControllers) {
            NSString *title = branch.tabBarItem.title.lowercaseString ?: @"";
            NSString *className = NSStringFromClass(branch.class).lowercaseString ?: @"";
            NSInteger score = 0;
            if ([title containsString:@"\u9879\u76ee"] ||
                [title containsString:@"project"]) score += 100;
            if ([className containsString:@"projectsvc"] ||
                [className containsString:@"projectslistvc"]) score += 50;
            if (score > bestScore) {
                bestScore = score;
                bestTabs = tabController;
                bestBranch = branch;
            }
        }
    }
    if (!bestTabs || !bestBranch) return NO;
    bestTabs.selectedViewController = bestBranch;
    [bestBranch.viewIfLoaded setNeedsLayout];
    [bestTabs.viewIfLoaded setNeedsLayout];
    return YES;
}

@interface AMWebHomeMessageProxy : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation AMWebHomeMessageProxy

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController
               didReceiveScriptMessage:message];
}

@end

@interface AMWebHomeController : UIViewController
    <WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIView *errorView;
@property(nonatomic, strong) AMWebHomeMessageProxy *messageProxy;
@end

@implementation AMWebHomeController

- (void)loadView {
    self.view = [UIView new];
    self.view.backgroundColor = [UIColor colorWithRed:0.961
                                                green:0.965
                                                 blue:0.973
                                                alpha:1.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.messageProxy = [AMWebHomeMessageProxy new];
    self.messageProxy.target = self;
    [configuration.userContentController addScriptMessageHandler:self.messageProxy
                                                              name:@"amnative"];
    configuration.allowsInlineMediaPlayback = YES;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero
                                      configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = self.view.backgroundColor;
    self.webView.scrollView.backgroundColor = self.view.backgroundColor;
    if (@available(iOS 11.0, *)) {
        self.webView.scrollView.contentInsetAdjustmentBehavior =
            UIScrollViewContentInsetAdjustmentNever;
    }
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = [UIColor colorWithRed:0.906
                                                    green:0.373
                                                     blue:0.553
                                                    alpha:1.0];
    [self.refreshControl addTarget:self action:@selector(refreshHome)
                  forControlEvents:UIControlEventValueChanged];
    self.webView.scrollView.refreshControl = self.refreshControl;

    UIActivityIndicatorViewStyle style = UIActivityIndicatorViewStyleWhiteLarge;
    if (@available(iOS 13.0, *)) style = UIActivityIndicatorViewStyleLarge;
    self.activityIndicator =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:style];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.color = self.refreshControl.tintColor;
    [self.view addSubview:self.activityIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor
            constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor
            constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
    [self loadHome];
}

- (void)dealloc {
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"amnative"];
}

- (void)loadHome {
    [self hideError];
    [self.activityIndicator startAnimating];
    NSURL *url = [NSURL URLWithString:AMWebHomeURLString];
    if (!url) {
        [self showError];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:url cachePolicy:NSURLRequestReloadRevalidatingCacheData
        timeoutInterval:20.0];
    [request setValue:@"ios" forHTTPHeaderField:@"X-AM-Platform"];
    [self.webView loadRequest:request];
}

- (void)refreshHome {
    [self.webView reloadFromOrigin];
}

- (void)retryHome {
    [self loadHome];
}

- (void)openNativeEditor {
    // The embedded home has no editor controller of its own. Switch to the
    // native Projects tab when it is discoverable; otherwise reveal the
    // underlying FeedVC instead of leaving a dead web view on screen.
    if (AMWebHomeSelectProjectsTab()) return;

    // FeedVC is already the native home branch underneath this overlay. If a
    // projects tab cannot be identified on this build, reveal native AM here.
    self.view.hidden = YES;
}

- (void)hideError {
    [self.errorView removeFromSuperview];
    self.errorView = nil;
}

- (void)showError {
    [self.activityIndicator stopAnimating];
    [self.refreshControl endRefreshing];
    if (self.errorView) return;

    UIView *errorView = [UIView new];
    errorView.translatesAutoresizingMaskIntoConstraints = NO;
    errorView.backgroundColor = self.view.backgroundColor;
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"主页加载失败\n请检查网络后重试";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont systemFontOfSize:15.0];
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    retry.layer.cornerRadius = 8.0;
    retry.backgroundColor = self.refreshControl.tintColor;
    retry.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [retry setTitle:@"重新加载" forState:UIControlStateNormal];
    [retry setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [retry addTarget:self action:@selector(retryHome)
       forControlEvents:UIControlEventTouchUpInside];
    [errorView addSubview:label];
    [errorView addSubview:retry];
    [self.view addSubview:errorView];
    [NSLayoutConstraint activateConstraints:@[
        [errorView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [errorView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [errorView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [errorView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [label.centerXAnchor constraintEqualToAnchor:errorView.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:errorView.centerYAnchor
                                            constant:-28.0],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:errorView.widthAnchor
                                                  multiplier:0.86],
        [retry.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:18.0],
        [retry.centerXAnchor constraintEqualToAnchor:errorView.centerXAnchor],
        [retry.widthAnchor constraintEqualToConstant:128.0],
        [retry.heightAnchor constraintEqualToConstant:42.0],
    ]];
    self.errorView = errorView;
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;
    (void)navigation;
    [self.activityIndicator stopAnimating];
    [self.refreshControl endRefreshing];
    [self hideError];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
             withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    (void)error;
    [self showError];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                        withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    (void)error;
    [self showError];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if (AMWebHomeIsTrustedURL(url)) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (!url) {
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"] ||
        [scheme isEqualToString:@"mailto"] || [scheme isEqualToString:@"tel"]) {
        [UIApplication.sharedApplication openURL:url options:@{}
                              completionHandler:nil];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    if (![message.name isEqualToString:@"amnative"] ||
        ![message.body isKindOfClass:NSDictionary.class]) return;
    id rawAction = ((NSDictionary *)message.body)[@"action"];
    if (![rawAction isKindOfClass:NSString.class]) return;
    NSString *action = rawAction;
    if ([action isEqualToString:@"openEditor"] ||
        [action isEqualToString:@"open-editor"]) {
        [self openNativeEditor];
    } else if ([action isEqualToString:@"reload"] ||
               [action isEqualToString:@"home"]) {
        self.view.hidden = NO;
        [self loadHome];
    }
}

@end

static IMP AMWebHomeOriginalViewDidAppear(Class cls) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject((id)current,
                                                   AMWebHomeOriginalIMPKey);
        if (value) return value.pointerValue;
    }
    return NULL;
}

static void AMWebHomeFeedViewDidAppear(id self, SEL selector, BOOL animated) {
    IMP original = AMWebHomeOriginalViewDidAppear(object_getClass(self));
    if (original) ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
    if ([self isKindOfClass:UIViewController.class]) {
        AMWebHomeAttachToFeedController((UIViewController *)self);
    }
}

static void AMWebHomeInstallFeedHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class __unsafe_unretained *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    SEL selector = @selector(viewDidAppear:);
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (![NSStringFromClass(cls) containsString:@"FeedVC"] ||
            ![cls isSubclassOfClass:UIViewController.class] ||
            objc_getAssociatedObject((id)cls, AMWebHomeOriginalIMPKey)) continue;
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        IMP original = method_getImplementation(method);
        if (original == (IMP)AMWebHomeFeedViewDidAppear) continue;
        const char *types = method_getTypeEncoding(method);
        objc_setAssociatedObject((id)cls, AMWebHomeOriginalIMPKey,
            [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!class_addMethod(cls, selector, (IMP)AMWebHomeFeedViewDidAppear,
                            types)) {
            class_replaceMethod(cls, selector, (IMP)AMWebHomeFeedViewDidAppear,
                                types);
        }
    }
    free(classes);
}

static UIViewController *AMWebHomeFindController(
    UIViewController *root, NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!root || depth > 24) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)root];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    NSString *className = NSStringFromClass(root.class);
    if ([className containsString:@"FeedVC"]) return root;
    UIViewController *presented = root.presentedViewController;
    UIViewController *found = AMWebHomeFindController(presented, visited, depth + 1);
    if (found) return found;
    for (UIViewController *child in root.childViewControllers) {
        found = AMWebHomeFindController(child, visited, depth + 1);
        if (found) return found;
    }
    if ([root isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)root).viewControllers) {
            found = AMWebHomeFindController(child, visited, depth + 1);
            if (found) return found;
        }
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)root).viewControllers) {
            found = AMWebHomeFindController(child, visited, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static UIWindow *AMWebHomeKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

static BOOL AMWebHomeAttachToFeedController(UIViewController *feed) {
    if (!feed || !feed.isViewLoaded || !feed.view.window) return NO;
    AMWebHomeController *home =
        objc_getAssociatedObject(feed, AMWebHomeControllerKey);
    if (!home) {
        home = [AMWebHomeController new];
        [feed addChildViewController:home];
        home.view.translatesAutoresizingMaskIntoConstraints = NO;
        [feed.view addSubview:home.view];
        [NSLayoutConstraint activateConstraints:@[
            [home.view.topAnchor constraintEqualToAnchor:feed.view.topAnchor],
            [home.view.leadingAnchor constraintEqualToAnchor:feed.view.leadingAnchor],
            [home.view.trailingAnchor constraintEqualToAnchor:feed.view.trailingAnchor],
            [home.view.bottomAnchor constraintEqualToAnchor:feed.view.bottomAnchor],
        ]];
        [home didMoveToParentViewController:feed];
        objc_setAssociatedObject(feed, AMWebHomeControllerKey, home,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (home.view.superview != feed.view) {
        [feed.view addSubview:home.view];
    }
    home.view.hidden = NO;
    [feed.view bringSubviewToFront:home.view];
    return YES;
}

static BOOL AMWebHomeAttach(void) {
    UIWindow *window = AMWebHomeKeyWindow();
    if (!window || !window.rootViewController) return NO;
    UIViewController *feed = AMWebHomeFindController(
        window.rootViewController, [NSMutableSet set], 0);
    return AMWebHomeAttachToFeedController(feed);
}

static void AMWebHomeScheduleAttachAttempts(NSUInteger attempt) {
    if (AMWebHomeAttach()) return;
    if (attempt >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AMWebHomeScheduleAttachAttempts(attempt + 1);
    });
}

void AMWebHomeInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void (^attach)(void) = ^{
            AMWebHomeInstallFeedHooks();
            AMWebHomeScheduleAttachAttempts(0);
        };
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            attach();
        }];
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            attach();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), attach);
    });
}
