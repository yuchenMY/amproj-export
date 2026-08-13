#import "AMHomeUI.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const AMHomeUIURLString = @"https://amhome.meowcr.cn/home";
static NSString *const AMHomeUIAvatarCacheFilename = @"account-avatar.png";
static NSString *const AMHomeUIAvatarChangedNotification =
    @"AMCloudAvatarChangedNotification";
static NSString *const AMHomeUITokenChangedNotification =
    @"AMCloudTokenChangedNotification";
static NSString *const AMHomeUIShowAccountNotification =
    @"AMHomeUIShowAccountNotification";

static const void *AMHomeUIControllerKey = &AMHomeUIControllerKey;
static const void *AMHomeUIOriginalIMPKey = &AMHomeUIOriginalIMPKey;
static const void *AMHomeUIOriginalBarImageKey = &AMHomeUIOriginalBarImageKey;
static const void *AMHomeUIOriginalButtonImageKey =
    &AMHomeUIOriginalButtonImageKey;

@class AMHomeUIController;

static __weak UIViewController *AMHomeUIEmbeddedHost;
static AMHomeUIController *AMHomeUIEmbeddedController;
static AMHomeUIController *AMHomeUIFallbackController;
static UIWindow *AMHomeUIFallbackWindow;
static BOOL AMHomeUIAttachLoopRunning;

static BOOL AMHomeUIAttachToController(UIViewController *controller);
static void AMHomeUIRefreshAvatarEverywhere(void);

typedef NS_ENUM(NSInteger, AMHomeUIControllerKind) {
    AMHomeUIControllerKindNone = 0,
    AMHomeUIControllerKindHome = 1,
    AMHomeUIControllerKindFeed = 2,
};

static AMHomeUIControllerKind AMHomeUIKindForClass(Class cls) {
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) {
        return AMHomeUIControllerKindNone;
    }
    NSString *name = NSStringFromClass(cls) ?: @"";
    NSString *leaf = name.pathExtension.length ? name.pathExtension : name;
    if ([leaf isEqualToString:@"FeedVC"] || [name hasSuffix:@".FeedVC"]) {
        return AMHomeUIControllerKindFeed;
    }
    if ([leaf isEqualToString:@"HomeVC"] || [name hasSuffix:@".HomeVC"]) {
        return AMHomeUIControllerKindHome;
    }
    return AMHomeUIControllerKindNone;
}

static BOOL AMHomeUIIsTrustedURL(NSURL *url) {
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"amhome.meowcr.cn"]) {
        return NO;
    }
    return url.port == nil || url.port.integerValue == 443;
}

static NSURL *AMHomeUIAvatarCacheURL(void) {
    NSURL *directory = [NSFileManager.defaultManager
        URLsForDirectory:NSCachesDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [directory URLByAppendingPathComponent:AMHomeUIAvatarCacheFilename
                                       isDirectory:NO];
}

static UIImage *AMHomeUILoadAvatar(void) {
    NSData *data = [NSData dataWithContentsOfURL:AMHomeUIAvatarCacheURL()];
    UIImage *image = data.length
        ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale]
        : nil;
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIWindow *AMHomeUIKeyWindow(void) {
    UIWindow *fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window == AMHomeUIFallbackWindow || window.hidden ||
                    window.alpha <= 0.01) {
                    continue;
                }
                if (window.isKeyWindow) return window;
                if (!fallback) fallback = window;
            }
        }
    }
    if (fallback) return fallback;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window == AMHomeUIFallbackWindow || window.hidden ||
            window.alpha <= 0.01) {
            continue;
        }
        if (window.isKeyWindow) return window;
        if (!fallback) fallback = window;
    }
    return fallback ?: UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

static void AMHomeUICollectTabControllers(
    UIViewController *controller, NSMutableSet<NSValue *> *visited,
    NSMutableArray<UITabBarController *> *tabs, NSUInteger depth) {
    if (!controller || depth > 24) return;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if ([controller isKindOfClass:UITabBarController.class]) {
        [tabs addObject:(UITabBarController *)controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        AMHomeUICollectTabControllers(child, visited, tabs, depth + 1);
    }
    AMHomeUICollectTabControllers(controller.presentedViewController, visited,
                                  tabs, depth + 1);
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
             ((UINavigationController *)controller).viewControllers) {
            AMHomeUICollectTabControllers(child, visited, tabs, depth + 1);
        }
    }
}

static NSInteger AMHomeUIProjectsBranchScore(UIViewController *branch) {
    NSString *title = branch.tabBarItem.title.lowercaseString ?: @"";
    NSString *className = NSStringFromClass(branch.class).lowercaseString ?: @"";
    NSInteger score = 0;
    if ([title containsString:@"\u9879\u76ee"] ||
        [title containsString:@"project"]) {
        score += 100;
    }
    if ([className containsString:@"projectsvc"] ||
        [className containsString:@"projectslistvc"] ||
        [className containsString:@"project"]) {
        score += 50;
    }
    return score;
}

static BOOL AMHomeUISelectProjectsTab(void) {
    NSMutableArray<UITabBarController *> *tabs = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window != AMHomeUIFallbackWindow && !window.hidden &&
                    window.alpha > 0.01) {
                    AMHomeUICollectTabControllers(window.rootViewController,
                                                  visited, tabs, 0);
                }
            }
        }
    } else {
        UIWindow *window = AMHomeUIKeyWindow();
        AMHomeUICollectTabControllers(window.rootViewController, visited, tabs,
                                      0);
    }

    UITabBarController *bestTabs = nil;
    UIViewController *bestBranch = nil;
    NSInteger bestScore = 0;
    for (UITabBarController *tabController in tabs) {
        for (UIViewController *branch in tabController.viewControllers) {
            NSInteger score = AMHomeUIProjectsBranchScore(branch);
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

@interface AMHomeUIPassthroughView : UIView
@end

@implementation AMHomeUIPassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

@interface AMHomeUIOverlayWindow : UIWindow
@end

@implementation AMHomeUIOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}

@end

@interface AMHomeUIMessageProxy : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation AMHomeUIMessageProxy

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController
               didReceiveScriptMessage:message];
}

@end

@interface AMHomeUIController : UIViewController
    <WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic) BOOL fallbackMode;
@property(nonatomic) BOOL webVisible;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIView *errorView;
@property(nonatomic, strong) UIButton *fallbackToggleButton;
@property(nonatomic, strong) AMHomeUIMessageProxy *messageProxy;
- (instancetype)initWithFallbackMode:(BOOL)fallbackMode;
- (void)updateAvatar;
@end

@implementation AMHomeUIController

- (instancetype)initWithFallbackMode:(BOOL)fallbackMode {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _fallbackMode = fallbackMode;
        _webVisible = YES;
    }
    return self;
}

- (void)loadView {
    self.view = self.fallbackMode ? [AMHomeUIPassthroughView new] : [UIView new];
    self.view.backgroundColor = self.fallbackMode
        ? UIColor.clearColor
        : [UIColor colorWithRed:0.961 green:0.965 blue:0.973 alpha:1.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.messageProxy = [AMHomeUIMessageProxy new];
    self.messageProxy.target = self;
    [configuration.userContentController
        addScriptMessageHandler:self.messageProxy name:@"amnative"];
    configuration.allowsInlineMediaPlayback = YES;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero
                                      configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    self.webView.backgroundColor = [UIColor colorWithRed:0.961
                                                   green:0.965
                                                    blue:0.973
                                                   alpha:1.0];
    self.webView.scrollView.backgroundColor = self.webView.backgroundColor;
    self.webView.allowsBackForwardNavigationGestures = YES;
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

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.color = self.refreshControl.tintColor;
    [self.view addSubview:self.activityIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor
            constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor
            constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    if (self.fallbackMode) {
        self.fallbackToggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.fallbackToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.fallbackToggleButton.tintColor = UIColor.whiteColor;
        self.fallbackToggleButton.backgroundColor =
            [UIColor colorWithWhite:0.0 alpha:0.62];
        self.fallbackToggleButton.layer.cornerRadius = 22.0;
        self.fallbackToggleButton.accessibilityLabel = @"\u5207\u6362\u4e3b\u9875\u548c\u7f16\u8f91\u5668";
        [self.fallbackToggleButton addTarget:self
                                      action:@selector(toggleFallbackMode)
                            forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.fallbackToggleButton];
        [NSLayoutConstraint activateConstraints:@[
            [self.fallbackToggleButton.widthAnchor constraintEqualToConstant:44.0],
            [self.fallbackToggleButton.heightAnchor constraintEqualToConstant:44.0],
            [self.fallbackToggleButton.trailingAnchor
                constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor
                               constant:-16.0],
            [self.fallbackToggleButton.bottomAnchor
                constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                               constant:-72.0],
        ]];
    }

    [self updateAvatar];
    [self updateFallbackVisibility];
    [self loadHome];
}

- (void)dealloc {
    [self.webView.configuration.userContentController
        removeScriptMessageHandlerForName:@"amnative"];
}

- (void)loadHome {
    [self hideError];
    [self.activityIndicator startAnimating];
    NSURL *url = [NSURL URLWithString:AMHomeUIURLString];
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
    BOOL selected = AMHomeUISelectProjectsTab();
    if (self.fallbackMode) {
        self.webVisible = NO;
        [self updateFallbackVisibility];
        return;
    }
    if (!selected) self.view.hidden = YES;
}

- (void)openAccountCenter {
    [NSNotificationCenter.defaultCenter
        postNotificationName:AMHomeUIShowAccountNotification object:nil];
}

- (void)toggleFallbackMode {
    self.webVisible = !self.webVisible;
    [self updateFallbackVisibility];
}

- (void)updateFallbackVisibility {
    if (!self.fallbackMode) return;
    BOOL visible = self.webVisible;
    self.webView.hidden = !visible;
    self.errorView.hidden = !visible;
    if (!visible) [self.activityIndicator stopAnimating];
    NSString *symbolName = visible ? @"slider.horizontal.3" : @"house.fill";
    UIImage *image = nil;
    if (@available(iOS 13.0, *)) image = [UIImage systemImageNamed:symbolName];
    [self.fallbackToggleButton setImage:image forState:UIControlStateNormal];
    [self.view bringSubviewToFront:self.fallbackToggleButton];
}

- (void)updateAvatar {
    UIImage *avatar = AMHomeUILoadAvatar();
    NSString *avatarDataURL = @"";
    if (avatar) {
        NSData *data = UIImagePNGRepresentation(avatar);
        if (data.length) {
            avatarDataURL = [@"data:image/png;base64,"
                stringByAppendingString:[data base64EncodedStringWithOptions:0]];
        }
    }
    NSData *JSONData = [NSJSONSerialization dataWithJSONObject:@[avatarDataURL]
                                                       options:0 error:nil];
    NSString *JSON = JSONData.length
        ? [[NSString alloc] initWithData:JSONData encoding:NSUTF8StringEncoding]
        : @"[\"\"]";
    NSString *script = [NSString stringWithFormat:
        @"(function(avatar){"
         "var state=window.__amHomeAccountButtonState;"
         "if(!state||typeof state!=='object'){state={avatar:'',observer:null,scheduled:false,force:false};"
         "window.__amHomeAccountButtonState=state;}"
         "state.avatar=avatar||'';"
         "state.observe=function(){var root=document.documentElement||document.body;"
         "if(root&&state.observer){state.observer.observe(root,{childList:true,subtree:true,"
         "attributes:true,attributeFilter:['id','class','disabled','aria-label','title','style']});}};"
         "state.apply=function(force){"
         "var current=document.getElementById('refreshButton');"
         "if(!current){return false;}"
         "var ready=current.__amHomeAccountButtonReady===true&&"
         "current.__amHomeAvatar===state.avatar;"
         "if(!force&&ready){return true;}"
         "if(state.observer){state.observer.disconnect();}"
         "try{var button=current;"
         "if(current.__amHomeAccountButtonReady!==true){"
         "button=current.cloneNode(false);current.replaceWith(button);}"
         "button.classList.remove('is-loading');button.disabled=false;"
         "button.setAttribute('data-am-account-button','true');"
         "button.setAttribute('aria-label','AutFengHub \\u8d26\\u6237');"
         "button.setAttribute('title','AutFengHub \\u8d26\\u6237');"
         "button.onclick=function(event){event.preventDefault();event.stopPropagation();"
         "var bridge=window.webkit&&window.webkit.messageHandlers&&"
         "window.webkit.messageHandlers.amnative;if(bridge){bridge.postMessage({action:'openAccount'});}};"
         "button.replaceChildren();"
         "if(state.avatar){var image=document.createElement('img');image.src=state.avatar;image.alt='';"
         "image.style.cssText='width:100%%;height:100%%;display:block;object-fit:cover;border-radius:50%%';"
         "button.appendChild(image);button.style.padding='0';button.style.overflow='hidden';}"
         "else{button.style.padding='';button.style.overflow='';button.innerHTML="
         "'<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M20 21a8 8 0 0 0-16 0M12 13a5 5 0 1 0 0-10 5 5 0 0 0 0 10\"/></svg>'; }"
         "button.__amHomeAccountButtonReady=true;button.__amHomeAvatar=state.avatar;"
         "}finally{state.observe();}return true;};"
         "state.schedule=function(force){state.force=state.force||!!force;"
         "if(state.scheduled){return;}state.scheduled=true;"
         "setTimeout(function(){var requested=state.force;state.force=false;"
         "state.scheduled=false;state.apply(requested);},0);};"
         "if(!state.observer){state.observer=new MutationObserver(function(records){"
         "var changed=false;var force=false;"
         "for(var index=0;index<records.length;index++){var record=records[index];"
         "var target=record.target;"
         "if(target&&target.nodeType===1&&target.id==='refreshButton'){changed=true;force=true;break;}"
         "for(var nodeIndex=0;nodeIndex<record.addedNodes.length;nodeIndex++){"
         "var node=record.addedNodes[nodeIndex];"
         "if(node.nodeType===1&&(node.id==='refreshButton'||"
         "(node.querySelector&&node.querySelector('#refreshButton')))){changed=true;break;}}"
         "if(changed){break;}}if(changed){state.schedule(force);}});}"
         "state.observe();return state.apply(false);})(%@[0]||'');",
        JSON];
    [self.webView evaluateJavaScript:script completionHandler:nil];
    if (self.fallbackToggleButton) {
        [self.view bringSubviewToFront:self.fallbackToggleButton];
    }
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
    errorView.backgroundColor = self.webView.backgroundColor;
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"\u4e3b\u9875\u52a0\u8f7d\u5931\u8d25\n\u8bf7\u68c0\u67e5\u7f51\u7edc\u540e\u91cd\u8bd5";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont systemFontOfSize:15.0];
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    retry.translatesAutoresizingMaskIntoConstraints = NO;
    retry.layer.cornerRadius = 8.0;
    retry.backgroundColor = self.refreshControl.tintColor;
    retry.titleLabel.font =
        [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [retry setTitle:@"\u91cd\u65b0\u52a0\u8f7d" forState:UIControlStateNormal];
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
    if (self.fallbackToggleButton) {
        [self.view bringSubviewToFront:self.fallbackToggleButton];
    }
}

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;
    (void)navigation;
    [self.activityIndicator stopAnimating];
    [self.refreshControl endRefreshing];
    [self hideError];
    [self updateAvatar];
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
                    decisionHandler:
                        (void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    NSURL *url = navigationAction.request.URL;
    if (AMHomeUIIsTrustedURL(url)) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (url) {
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"https"] ||
            [scheme isEqualToString:@"http"] ||
            [scheme isEqualToString:@"mailto"] ||
            [scheme isEqualToString:@"tel"]) {
            [UIApplication.sharedApplication openURL:url
                                             options:@{}
                                   completionHandler:nil];
        }
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    if (![message.name isEqualToString:@"amnative"] ||
        !message.frameInfo.isMainFrame ||
        ![message.frameInfo.securityOrigin.protocol.lowercaseString
            isEqualToString:@"https"] ||
        ![message.frameInfo.securityOrigin.host.lowercaseString
            isEqualToString:@"amhome.meowcr.cn"]) {
        return;
    }
    id rawAction = nil;
    if ([message.body isKindOfClass:NSDictionary.class]) {
        rawAction = ((NSDictionary *)message.body)[@"action"];
    } else if ([message.body isKindOfClass:NSString.class]) {
        rawAction = message.body;
    }
    if (![rawAction isKindOfClass:NSString.class]) return;
    NSString *action = rawAction;
    if ([action isEqualToString:@"openEditor"] ||
        [action isEqualToString:@"open-editor"] ||
        [action isEqualToString:@"projects"] ||
        [action isEqualToString:@"native"]) {
        [self openNativeEditor];
    } else if ([action isEqualToString:@"openAccount"] ||
               [action isEqualToString:@"account"] ||
               [action isEqualToString:@"profile"]) {
        [self openAccountCenter];
    } else if ([action isEqualToString:@"reload"]) {
        [self loadHome];
    } else if ([action isEqualToString:@"home"] ||
               [action isEqualToString:@"web"]) {
        self.webVisible = YES;
        self.view.hidden = NO;
        [self updateFallbackVisibility];
        [self loadHome];
    }
}

@end


static BOOL AMHomeUIStringLooksLikeAccount(NSString *value) {
    NSString *text = value.lowercaseString ?: @"";
    for (NSString *term in @[@"account", @"profile", @"person", @"user",
                             @"\u8d26\u6237", @"\u6211\u7684", @"\u4e2a\u4eba"]) {
        if ([text containsString:term]) return YES;
    }
    return NO;
}

static void AMHomeUIApplyAvatarToBarItem(UIBarButtonItem *item,
                                         UIImage *avatar) {
    if (!item) return;
    id original = objc_getAssociatedObject(item, AMHomeUIOriginalBarImageKey);
    if (!original) {
        original = item.image ?: NSNull.null;
        objc_setAssociatedObject(item, AMHomeUIOriginalBarImageKey, original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    item.image = avatar ?: (original == NSNull.null ? nil : original);
}

static void AMHomeUIApplyAvatarToButton(UIButton *button, UIImage *avatar) {
    if (!button) return;
    id original = objc_getAssociatedObject(button, AMHomeUIOriginalButtonImageKey);
    if (!original) {
        original = [button imageForState:UIControlStateNormal] ?: NSNull.null;
        objc_setAssociatedObject(button, AMHomeUIOriginalButtonImageKey, original,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIImage *image = avatar ?: (original == NSNull.null ? nil : original);
    [button setImage:image forState:UIControlStateNormal];
    if (avatar) {
        button.imageView.contentMode = UIViewContentModeScaleAspectFill;
        button.imageView.layer.cornerRadius =
            MIN(button.bounds.size.width, button.bounds.size.height) * 0.5;
        button.imageView.clipsToBounds = YES;
    } else {
        button.imageView.layer.cornerRadius = 0;
        button.imageView.clipsToBounds = NO;
    }
}

static void AMHomeUIFindNativeAccountButton(
    UIView *view, UIWindow *window, NSMutableArray<UIButton *> *matches,
    NSUInteger depth) {
    if (!view || !window || view.hidden || view.alpha <= 0.01 || depth > 16) {
        return;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        CGRect frame = [button convertRect:button.bounds toView:window];
        NSString *label = [NSString stringWithFormat:@"%@ %@ %@",
            button.accessibilityLabel ?: @"",
            button.accessibilityIdentifier ?: @"",
            [button titleForState:UIControlStateNormal] ?: @""];
        BOOL accountLabel = AMHomeUIStringLooksLikeAccount(label);
        BOOL topRightGeometry = frame.size.width >= 28.0 &&
            frame.size.width <= 76.0 && frame.size.height >= 28.0 &&
            frame.size.height <= 76.0 && CGRectGetMidX(frame) >
                CGRectGetWidth(window.bounds) * 0.72 &&
            CGRectGetMinY(frame) < window.safeAreaInsets.top + 110.0;
        if (accountLabel || topRightGeometry) [matches addObject:button];
    }
    for (UIView *child in view.subviews) {
        AMHomeUIFindNativeAccountButton(child, window, matches, depth + 1);
    }
}

static void AMHomeUIApplyAvatarToNativeController(
    UIViewController *controller) {
    if (!controller) return;
    UIImage *avatar = AMHomeUILoadAvatar();
    NSArray<UIBarButtonItem *> *items =
        controller.navigationItem.rightBarButtonItems ?: @[];
    for (UIBarButtonItem *item in items) {
        NSString *label = [NSString stringWithFormat:@"%@ %@",
            item.accessibilityLabel ?: @"",
            item.accessibilityIdentifier ?: @""];
        if (items.count == 1 || AMHomeUIStringLooksLikeAccount(label)) {
            AMHomeUIApplyAvatarToBarItem(item, avatar);
            if (items.count == 1) break;
        }
    }
    UIWindow *window = controller.viewIfLoaded.window;
    if (!window) return;
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    AMHomeUIFindNativeAccountButton(controller.viewIfLoaded, window, buttons, 0);
    UIButton *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UIButton *button in buttons) {
        CGRect frame = [button convertRect:button.bounds toView:window];
        NSString *label = [NSString stringWithFormat:@"%@ %@ %@",
            button.accessibilityLabel ?: @"",
            button.accessibilityIdentifier ?: @"",
            [button titleForState:UIControlStateNormal] ?: @""];
        NSInteger score = AMHomeUIStringLooksLikeAccount(label) ? 1000 : 0;
        score += (NSInteger)CGRectGetMinX(frame);
        score -= (NSInteger)(CGRectGetMinY(frame) * 2.0);
        if (score > bestScore) {
            bestScore = score;
            best = button;
        }
    }
    AMHomeUIApplyAvatarToButton(best, avatar);
}

static IMP AMHomeUIOriginalViewDidAppear(Class cls) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSValue *value =
            objc_getAssociatedObject((id)current, AMHomeUIOriginalIMPKey);
        if (value) return value.pointerValue;
    }
    return NULL;
}

static void AMHomeUIViewDidAppear(id self, SEL selector, BOOL animated) {
    IMP original = AMHomeUIOriginalViewDidAppear(object_getClass(self));
    if (original) ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
    if (![self isKindOfClass:UIViewController.class]) return;
    UIViewController *controller = (UIViewController *)self;
    AMHomeUIApplyAvatarToNativeController(controller);
    AMHomeUIAttachToController(controller);
}

static void AMHomeUIInstallControllerHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class __unsafe_unretained *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    SEL selector = @selector(viewDidAppear:);
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (AMHomeUIKindForClass(cls) == AMHomeUIControllerKindNone ||
            objc_getAssociatedObject((id)cls, AMHomeUIOriginalIMPKey)) {
            continue;
        }
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        IMP original = method_getImplementation(method);
        if (original == (IMP)AMHomeUIViewDidAppear) continue;
        objc_setAssociatedObject((id)cls, AMHomeUIOriginalIMPKey,
            [NSValue valueWithPointer:original],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        const char *types = method_getTypeEncoding(method);
        if (!class_addMethod(cls, selector, (IMP)AMHomeUIViewDidAppear, types)) {
            class_replaceMethod(cls, selector, (IMP)AMHomeUIViewDidAppear,
                                types);
        }
    }
    free(classes);
}

static void AMHomeUIFindBestController(
    UIViewController *root, NSMutableSet<NSValue *> *visited, NSUInteger depth,
    UIViewController *__strong *best, AMHomeUIControllerKind *bestKind) {
    if (!root || depth > 24) return;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)root];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    AMHomeUIControllerKind kind = AMHomeUIKindForClass(root.class);
    if (kind > *bestKind && root.isViewLoaded && root.view.window) {
        *best = root;
        *bestKind = kind;
    }
    for (UIViewController *child in root.childViewControllers) {
        AMHomeUIFindBestController(child, visited, depth + 1, best, bestKind);
    }
    AMHomeUIFindBestController(root.presentedViewController, visited, depth + 1,
                               best, bestKind);
    if ([root isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
             ((UINavigationController *)root).viewControllers) {
            AMHomeUIFindBestController(child, visited, depth + 1, best,
                                       bestKind);
        }
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in
             ((UITabBarController *)root).viewControllers) {
            AMHomeUIFindBestController(child, visited, depth + 1, best,
                                       bestKind);
        }
    }
}

static void AMHomeUIDismissFallback(void) {
    if (!AMHomeUIFallbackWindow) return;
    AMHomeUIFallbackWindow.hidden = YES;
    AMHomeUIFallbackWindow.rootViewController = nil;
    AMHomeUIFallbackController = nil;
    AMHomeUIFallbackWindow = nil;
}

static BOOL AMHomeUIAttachToController(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded || !controller.view.window) {
        return NO;
    }
    AMHomeUIControllerKind newKind = AMHomeUIKindForClass(controller.class);
    if (newKind == AMHomeUIControllerKindNone) return NO;
    UIViewController *oldHost = AMHomeUIEmbeddedHost;
    AMHomeUIControllerKind oldKind = AMHomeUIKindForClass(oldHost.class);
    if (oldHost && oldHost != controller && oldHost.viewIfLoaded.window &&
        oldKind >= newKind) {
        AMHomeUIApplyAvatarToNativeController(oldHost);
        return YES;
    }
    if (oldHost != controller) {
        if (AMHomeUIEmbeddedController.parentViewController) {
            [AMHomeUIEmbeddedController willMoveToParentViewController:nil];
            [AMHomeUIEmbeddedController.view removeFromSuperview];
            [AMHomeUIEmbeddedController removeFromParentViewController];
        }
        if (oldHost) {
            objc_setAssociatedObject(oldHost, AMHomeUIControllerKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        AMHomeUIEmbeddedController =
            [[AMHomeUIController alloc] initWithFallbackMode:NO];
        AMHomeUIEmbeddedHost = controller;
        [controller addChildViewController:AMHomeUIEmbeddedController];
        AMHomeUIEmbeddedController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [controller.view addSubview:AMHomeUIEmbeddedController.view];
        [NSLayoutConstraint activateConstraints:@[
            [AMHomeUIEmbeddedController.view.topAnchor
                constraintEqualToAnchor:controller.view.topAnchor],
            [AMHomeUIEmbeddedController.view.leadingAnchor
                constraintEqualToAnchor:controller.view.leadingAnchor],
            [AMHomeUIEmbeddedController.view.trailingAnchor
                constraintEqualToAnchor:controller.view.trailingAnchor],
            [AMHomeUIEmbeddedController.view.bottomAnchor
                constraintEqualToAnchor:controller.view.bottomAnchor],
        ]];
        [AMHomeUIEmbeddedController didMoveToParentViewController:controller];
        objc_setAssociatedObject(controller, AMHomeUIControllerKey,
                                 AMHomeUIEmbeddedController,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (AMHomeUIEmbeddedController.view.superview != controller.view) {
        [controller.view addSubview:AMHomeUIEmbeddedController.view];
    }
    AMHomeUIEmbeddedController.view.hidden = NO;
    [AMHomeUIEmbeddedController updateAvatar];
    [controller.view bringSubviewToFront:AMHomeUIEmbeddedController.view];
    AMHomeUIApplyAvatarToNativeController(controller);
    AMHomeUIDismissFallback();
    return YES;
}

static BOOL AMHomeUIAttach(void) {
    UIWindow *window = AMHomeUIKeyWindow();
    if (!window.rootViewController) return NO;
    UIViewController *best = nil;
    AMHomeUIControllerKind bestKind = AMHomeUIControllerKindNone;
    AMHomeUIFindBestController(window.rootViewController,
                               [NSMutableSet set], 0, &best, &bestKind);
    return AMHomeUIAttachToController(best);
}

static BOOL AMHomeUIShowFallback(void) {
    if (AMHomeUIFallbackWindow) return YES;
    UIWindow *appWindow = AMHomeUIKeyWindow();
    if (!appWindow || !appWindow.rootViewController) return NO;
    UIWindow *overlay = nil;
    if (@available(iOS 13.0, *)) {
        if (appWindow.windowScene) {
            overlay = [[AMHomeUIOverlayWindow alloc]
                initWithWindowScene:appWindow.windowScene];
        }
    }
    if (!overlay) {
        overlay = [[AMHomeUIOverlayWindow alloc] initWithFrame:appWindow.bounds];
    }
    overlay.frame = appWindow.bounds;
    overlay.windowLevel = UIWindowLevelNormal + 1.0;
    overlay.backgroundColor = UIColor.clearColor;
    AMHomeUIFallbackController =
        [[AMHomeUIController alloc] initWithFallbackMode:YES];
    overlay.rootViewController = AMHomeUIFallbackController;
    AMHomeUIFallbackWindow = overlay;
    [overlay makeKeyAndVisible];
    [appWindow makeKeyWindow];
    overlay.hidden = NO;
    return YES;
}

static void AMHomeUIAttachAttempt(NSUInteger attempt) {
    AMHomeUIInstallControllerHooks();
    if (AMHomeUIAttach()) {
        AMHomeUIAttachLoopRunning = NO;
        return;
    }
    if (attempt >= 60) {
        AMHomeUIShowFallback();
        AMHomeUIAttachLoopRunning = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AMHomeUIAttachAttempt(attempt + 1);
    });
}

static void AMHomeUIScheduleAttachAttempts(void) {
    if (AMHomeUIAttachLoopRunning) return;
    AMHomeUIAttachLoopRunning = YES;
    AMHomeUIAttachAttempt(0);
}

static void AMHomeUIRefreshAvatarEverywhere(void) {
    AMHomeUIApplyAvatarToNativeController(AMHomeUIEmbeddedHost);
    [AMHomeUIEmbeddedController updateAvatar];
    [AMHomeUIFallbackController updateAvatar];
}

void AMHomeUIInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void (^activate)(void) = ^{
            AMHomeUIInstallControllerHooks();
            AMHomeUIScheduleAttachAttempts();
            AMHomeUIRefreshAvatarEverywhere();
        };
        for (NSNotificationName name in @[
            UIApplicationDidFinishLaunchingNotification,
            UIApplicationDidBecomeActiveNotification,
        ]) {
            [NSNotificationCenter.defaultCenter
                addObserverForName:name object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                activate();
            }];
        }
        for (NSNotificationName name in @[
            AMHomeUIAvatarChangedNotification,
            AMHomeUITokenChangedNotification,
        ]) {
            [NSNotificationCenter.defaultCenter
                addObserverForName:name object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                AMHomeUIRefreshAvatarEverywhere();
            }];
        }
        dispatch_async(dispatch_get_main_queue(), activate);
    });
}

__attribute__((constructor))
static void AMHomeUIInitialize(void) {
    @autoreleasepool {
        AMHomeUIInstall();
    }
}
