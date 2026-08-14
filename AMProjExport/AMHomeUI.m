#import "AMHomeUI.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const AMHomeUIURLString =
    @"https://amhome.meowcr.cn/home?embed=1&platform=ios";
static NSString *const AMHomeUIAvatarCacheFilename = @"account-avatar.png";
static NSString *const AMHomeUIAvatarChangedNotification =
    @"AMCloudAvatarChangedNotification";
static NSString *const AMHomeUITokenChangedNotification =
    @"AMCloudTokenChangedNotification";
static NSString *const AMHomeUIShowAccountNotification =
    @"AMHomeUIShowAccountNotification";

static const void *AMHomeUIControllerKey = &AMHomeUIControllerKey;
static const void *AMHomeUIOriginalBarImageKey = &AMHomeUIOriginalBarImageKey;
static const void *AMHomeUIOriginalButtonImageKey =
    &AMHomeUIOriginalButtonImageKey;
static const void *AMHomeUIOriginalButtonConfigurationKey =
    &AMHomeUIOriginalButtonConfigurationKey;
static const void *AMHomeUIOriginalButtonPresentationKey =
    &AMHomeUIOriginalButtonPresentationKey;

@class AMHomeUIController;

static __weak UIViewController *AMHomeUIEmbeddedHost;
static AMHomeUIController *AMHomeUIEmbeddedController;
static BOOL AMHomeUIAttachLoopRunning;
static Class AMHomeUIHookedFeedClass;
static IMP AMHomeUIOriginalFeedViewDidAppear;

static BOOL AMHomeUIAttachToController(UIViewController *controller);
static void AMHomeUIRefreshAvatarEverywhere(void);
static void AMHomeUIApplyAvatarToButton(UIButton *button, UIImage *avatar);

typedef NS_ENUM(NSInteger, AMHomeUIControllerKind) {
    AMHomeUIControllerKindNone = 0,
    AMHomeUIControllerKindHome = 1,
    AMHomeUIControllerKindFeed = 2,
};

static BOOL AMHomeUIClassIsViewController(Class cls) {
    Class viewControllerClass = UIViewController.class;
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == viewControllerClass) return YES;
    }
    return NO;
}

static AMHomeUIControllerKind AMHomeUIKindForClass(Class cls) {
    if (!cls || !AMHomeUIClassIsViewController(cls)) {
        return AMHomeUIControllerKindNone;
    }
    NSString *name = NSStringFromClass(cls) ?: @"";
    if ([name isEqualToString:@"FeedVC"] ||
        [name isEqualToString:@"AlightMotion.FeedVC"] ||
        [name isEqualToString:@"_TtC12AlightMotion6FeedVC"]) {
        return AMHomeUIControllerKindFeed;
    }
    if ([name isEqualToString:@"HomeVC"] ||
        [name isEqualToString:@"AlightMotion.HomeVC"] ||
        [name isEqualToString:@"_TtC12AlightMotion6HomeVC"]) {
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
                if (window.hidden || window.alpha <= 0.01) {
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
        if (window.hidden || window.alpha <= 0.01) {
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
                if (!window.hidden && window.alpha > 0.01) {
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
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIView *errorView;
@property(nonatomic, strong) AMHomeUIMessageProxy *messageProxy;
- (void)updateAvatar;
@end

@implementation AMHomeUIController

- (void)loadView {
    self.view = [UIView new];
    self.view.backgroundColor =
        [UIColor colorWithRed:0.961 green:0.965 blue:0.973 alpha:1.0];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.messageProxy = [AMHomeUIMessageProxy new];
    self.messageProxy.target = self;
    [configuration.userContentController
        addScriptMessageHandler:self.messageProxy name:@"amnative"];
    NSString *embeddedStyleScript =
        @"(function(){var id='am-native-embedded-style';"
         "if(document.getElementById(id)){return;}"
         "var style=document.createElement('style');style.id=id;"
         "style.textContent='.home-header{display:none!important}' +"
         "'.home-shell{padding-top:16px!important}';"
         "var install=function(){var root=document.head||document.documentElement;"
         "if(!root){return false;}root.appendChild(style);"
         "document.documentElement.setAttribute('data-am-native-embedded','true');"
         "return true;};if(!install()){document.addEventListener('DOMContentLoaded',install,{once:true});}"
         "})();";
    [configuration.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:embeddedStyleScript
                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                           forMainFrameOnly:YES]];
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

    [self updateAvatar];
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
    AMHomeUISelectProjectsTab();
}

- (void)openAccountCenter {
    [NSNotificationCenter.defaultCenter
        postNotificationName:AMHomeUIShowAccountNotification object:nil];
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
        self.view.hidden = NO;
        [self loadHome];
    }
}

@end


static BOOL AMHomeUIStringLooksLikeAccount(NSString *value) {
    NSString *text = value.lowercaseString ?: @"";
    for (NSString *term in @[@"account", @"profile", @"person", @"user",
                             @"login", @"sign in", @"\u8d26\u6237",
                             @"\u767b\u5f55", @"\u767b\u5165",
                             @"\u6211\u7684", @"\u4e2a\u4eba"]) {
        if ([text containsString:term]) return YES;
    }
    return NO;
}

static id AMHomeUIAccountControlForController(UIViewController *controller) {
    SEL selector = NSSelectorFromString(@"accountButton");
    Method method = controller
        ? class_getInstanceMethod(controller.class, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char *returnType = method_copyReturnType(method);
    BOOL returnsObject = returnType && returnType[0] == '@';
    free(returnType);
    if (!returnsObject) return nil;
    IMP implementation = method_getImplementation(method);
    return implementation
        ? ((id (*)(id, SEL))implementation)(controller, selector) : nil;
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
    if ([item.customView isKindOfClass:UIButton.class]) {
        AMHomeUIApplyAvatarToButton((UIButton *)item.customView, avatar);
    }
}

static void AMHomeUIApplyAvatarToButton(UIButton *button, UIImage *avatar) {
    if (!button) return;
    NSDictionary<NSNumber *, id> *originals =
        objc_getAssociatedObject(button, AMHomeUIOriginalButtonImageKey);
    NSArray<NSNumber *> *states = @[
        @(UIControlStateNormal), @(UIControlStateHighlighted),
        @(UIControlStateSelected), @(UIControlStateDisabled),
        @(UIControlStateFocused),
    ];
    if (!originals) {
        NSMutableDictionary<NSNumber *, id> *captured = [NSMutableDictionary dictionary];
        for (NSNumber *stateValue in states) {
            UIImage *image = [button imageForState:stateValue.unsignedIntegerValue];
            captured[stateValue] = image ?: NSNull.null;
        }
        originals = captured;
        objc_setAssociatedObject(button, AMHomeUIOriginalButtonImageKey, originals,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSDictionary<NSString *, NSNumber *> *originalPresentation =
        objc_getAssociatedObject(button, AMHomeUIOriginalButtonPresentationKey);
    if (!originalPresentation) {
        originalPresentation = @{
            @"contentMode": @(button.imageView.contentMode),
            @"cornerRadius": @(button.imageView.layer.cornerRadius),
            @"clipsToBounds": @(button.imageView.clipsToBounds),
        };
        objc_setAssociatedObject(button, AMHomeUIOriginalButtonPresentationKey,
                                 originalPresentation,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (@available(iOS 15.0, *)) {
        id originalConfiguration = objc_getAssociatedObject(
            button, AMHomeUIOriginalButtonConfigurationKey);
        if (!originalConfiguration) {
            originalConfiguration = button.configuration
                ? [button.configuration copy] : NSNull.null;
            objc_setAssociatedObject(button,
                AMHomeUIOriginalButtonConfigurationKey, originalConfiguration,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (avatar && button.configuration) {
            UIButtonConfiguration *configuration = [button.configuration copy];
            configuration.image = avatar;
            button.configuration = configuration;
        } else if (!avatar && originalConfiguration != NSNull.null) {
            button.configuration = [originalConfiguration copy];
        }
    }
    for (NSNumber *stateValue in states) {
        id original = originals[stateValue];
        UIImage *image = avatar ?: (original == NSNull.null ? nil : original);
        [button setImage:image forState:stateValue.unsignedIntegerValue];
    }
    if (avatar) {
        button.imageView.contentMode = UIViewContentModeScaleAspectFill;
        button.imageView.layer.cornerRadius =
            MIN(button.bounds.size.width, button.bounds.size.height) * 0.5;
        button.imageView.clipsToBounds = YES;
    } else {
        button.imageView.contentMode =
            originalPresentation[@"contentMode"].integerValue;
        button.imageView.layer.cornerRadius =
            originalPresentation[@"cornerRadius"].doubleValue;
        button.imageView.clipsToBounds =
            originalPresentation[@"clipsToBounds"].boolValue;
    }
}

static void AMHomeUIFindNativeAccountButton(
    UIView *view, UIWindow *window, NSMutableArray<UIButton *> *matches,
    NSUInteger depth) {
    if (!view || !window || view.hidden || view.alpha <= 0.01 || depth > 24) {
        return;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        CGRect frame = [button convertRect:button.bounds toView:window];
        BOOL compactControl = frame.size.width >= 28.0 &&
            frame.size.width <= 76.0 && frame.size.height >= 28.0 &&
            frame.size.height <= 76.0;
        BOOL topRightGeometry = compactControl &&
            CGRectGetMidX(frame) > CGRectGetWidth(window.bounds) * 0.72 &&
            CGRectGetMinY(frame) < window.safeAreaInsets.top + 110.0;
        if (topRightGeometry) [matches addObject:button];
    }
    for (UIView *child in view.subviews) {
        AMHomeUIFindNativeAccountButton(child, window, matches, depth + 1);
    }
}

static void AMHomeUIApplyAvatarToNativeController(
    UIViewController *controller) {
    if (!controller) return;
    UIImage *avatar = AMHomeUILoadAvatar();
    NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIViewController *current = controller;
    for (NSUInteger depth = 0; current && depth < 16; depth++) {
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)current];
        if (AMHomeUIKindForClass(current.class) != AMHomeUIControllerKindNone &&
            ![visited containsObject:identity]) {
            [visited addObject:identity];
            [controllers addObject:current];
        }
        current = current.parentViewController;
    }
    UINavigationController *navigation = controller.navigationController;
    for (UIViewController *candidate in @[
        navigation.visibleViewController ?: controller,
        navigation.topViewController ?: controller,
    ]) {
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)candidate];
        if (AMHomeUIKindForClass(candidate.class) !=
                AMHomeUIControllerKindNone &&
            ![visited containsObject:identity]) {
            [visited addObject:identity];
            [controllers addObject:candidate];
        }
    }
    NSMutableArray<UIBarButtonItem *> *labeledBarItems = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *propertyBarItems = [NSMutableArray array];
    NSMutableArray<UIButton *> *propertyButtons = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedBarItems = [NSMutableSet set];
    NSMutableSet<NSValue *> *visitedPropertyControls = [NSMutableSet set];
    for (UIViewController *candidate in controllers) {
        id accountControl = AMHomeUIAccountControlForController(candidate);
        if (accountControl) {
            NSValue *identity = [NSValue valueWithPointer:
                (__bridge const void *)accountControl];
            if (![visitedPropertyControls containsObject:identity]) {
                [visitedPropertyControls addObject:identity];
                if ([accountControl isKindOfClass:UIButton.class])
                    [propertyButtons addObject:accountControl];
                else if ([accountControl isKindOfClass:UIBarButtonItem.class])
                    [propertyBarItems addObject:accountControl];
            }
        }
        NSArray<UIBarButtonItem *> *items =
            candidate.navigationItem.rightBarButtonItems ?: @[];
        for (UIBarButtonItem *item in items) {
            NSValue *identity =
                [NSValue valueWithPointer:(__bridge const void *)item];
            if ([visitedBarItems containsObject:identity]) continue;
            [visitedBarItems addObject:identity];
            NSString *label = [NSString stringWithFormat:@"%@ %@ %@",
                item.accessibilityLabel ?: @"",
                item.accessibilityIdentifier ?: @"",
                item.title ?: @""];
            if (AMHomeUIStringLooksLikeAccount(label))
                [labeledBarItems addObject:item];
        }
    }
    UIBarButtonItem *barTarget = propertyBarItems.count == 1
        ? propertyBarItems.firstObject
        : (propertyBarItems.count == 0 && labeledBarItems.count == 1
            ? labeledBarItems.firstObject : nil);
    AMHomeUIApplyAvatarToBarItem(barTarget, avatar);

    UIWindow *window = controller.viewIfLoaded.window ?: AMHomeUIKeyWindow();
    if (!window) return;
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedRoots = [NSMutableSet set];
    for (UIViewController *candidate in controllers) {
        UIView *view = candidate.viewIfLoaded;
        if (!view || view.window != window) continue;
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)view];
        if (![visitedRoots containsObject:identity]) {
            [visitedRoots addObject:identity];
            [roots addObject:view];
        }
    }
    UINavigationBar *navigationBar = navigation.navigationBar;
    if (navigationBar.window == window) {
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)navigationBar];
        if (![visitedRoots containsObject:identity]) {
            [visitedRoots addObject:identity];
            [roots addObject:navigationBar];
        }
    }
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (UIView *root in roots) {
        AMHomeUIFindNativeAccountButton(root, window, buttons, 0);
    }
    NSMutableArray<UIButton *> *labeledButtons = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedButtons = [NSMutableSet set];
    for (UIButton *button in buttons) {
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)button];
        if ([visitedButtons containsObject:identity]) continue;
        [visitedButtons addObject:identity];
        NSString *label = [NSString stringWithFormat:@"%@ %@ %@",
            button.accessibilityLabel ?: @"",
            button.accessibilityIdentifier ?: @"",
            [button titleForState:UIControlStateNormal] ?: @""];
        if (AMHomeUIStringLooksLikeAccount(label))
            [labeledButtons addObject:button];
    }
    UIButton *buttonTarget = propertyButtons.count == 1
        ? propertyButtons.firstObject
        : (propertyButtons.count == 0 && labeledButtons.count == 1
            ? labeledButtons.firstObject : nil);
    AMHomeUIApplyAvatarToButton(buttonTarget, avatar);
}

static void AMHomeUIViewDidAppear(id self, SEL selector, BOOL animated) {
    IMP original = AMHomeUIOriginalFeedViewDidAppear;
    if (original) ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
    if (![self isKindOfClass:UIViewController.class]) return;
    __weak UIViewController *controller = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *strongController = controller;
        if (!strongController) return;
        @try {
            AMHomeUIApplyAvatarToNativeController(strongController);
            AMHomeUIAttachToController(strongController);
        } @catch (NSException *exception) {
            NSLog(@"[AMHomeUI] viewDidAppear attach failed: %@ %@",
                  exception.name, exception.reason ?: @"");
        }
    });
}

static void AMHomeUIInstallControllerHooks(void) {
    if (AMHomeUIHookedFeedClass) return;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes || count == 0) {
        free(classes);
        return;
    }
    SEL selector = @selector(viewDidAppear:);
    for (unsigned int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (AMHomeUIKindForClass(cls) != AMHomeUIControllerKindFeed) continue;
        Method method = class_getInstanceMethod(cls, selector);
        if (!method || method_getNumberOfArguments(method) != 3) continue;
        IMP original = method_getImplementation(method);
        if (original == (IMP)AMHomeUIViewDidAppear) continue;
        AMHomeUIHookedFeedClass = cls;
        AMHomeUIOriginalFeedViewDidAppear = original;
        const char *types = method_getTypeEncoding(method);
        if (!class_addMethod(cls, selector, (IMP)AMHomeUIViewDidAppear, types)) {
            class_replaceMethod(cls, selector, (IMP)AMHomeUIViewDidAppear,
                                types);
        }
        break;
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
    if (kind > *bestKind && root.isViewLoaded) {
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

static void AMHomeUIAttachEmbeddedView(UIViewController *controller) {
    UIView *embeddedView = AMHomeUIEmbeddedController.view;
    if (!controller || !embeddedView || embeddedView.superview == controller.view)
        return;
    [embeddedView removeFromSuperview];
    embeddedView.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:embeddedView];
    [NSLayoutConstraint activateConstraints:@[
        [embeddedView.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [embeddedView.leadingAnchor
            constraintEqualToAnchor:controller.view.leadingAnchor],
        [embeddedView.trailingAnchor
            constraintEqualToAnchor:controller.view.trailingAnchor],
        [embeddedView.bottomAnchor
            constraintEqualToAnchor:controller.view.bottomAnchor],
    ]];
}

static BOOL AMHomeUIAttachToController(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) {
        return NO;
    }
    AMHomeUIControllerKind newKind = AMHomeUIKindForClass(controller.class);
    if (newKind != AMHomeUIControllerKindFeed) return NO;
    UIViewController *oldHost = AMHomeUIEmbeddedHost;
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
        AMHomeUIEmbeddedController = [AMHomeUIController new];
        AMHomeUIEmbeddedHost = controller;
        [controller addChildViewController:AMHomeUIEmbeddedController];
        AMHomeUIAttachEmbeddedView(controller);
        [AMHomeUIEmbeddedController didMoveToParentViewController:controller];
        objc_setAssociatedObject(controller, AMHomeUIControllerKey,
                                 AMHomeUIEmbeddedController,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else AMHomeUIAttachEmbeddedView(controller);
    AMHomeUIEmbeddedController.view.hidden = NO;
    [AMHomeUIEmbeddedController updateAvatar];
    [controller.view bringSubviewToFront:AMHomeUIEmbeddedController.view];
    AMHomeUIApplyAvatarToNativeController(controller);
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

static void AMHomeUIAttachAttempt(NSUInteger attempt) {
    @try {
        AMHomeUIInstallControllerHooks();
        if (AMHomeUIAttach()) {
            AMHomeUIAttachLoopRunning = NO;
            return;
        }
        if (attempt >= 60) {
            AMHomeUIAttachLoopRunning = NO;
            NSLog(@"[AMHomeUI] native HomeVC/FeedVC not found; web home disabled");
            return;
        }
    } @catch (NSException *exception) {
        AMHomeUIAttachLoopRunning = NO;
        NSLog(@"[AMHomeUI] attach attempt failed: %@ %@", exception.name,
              exception.reason ?: @"");
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
    UIViewController *avatarHost = AMHomeUIEmbeddedHost;
    if (!avatarHost) {
        UIWindow *window = AMHomeUIKeyWindow();
        UIViewController *root = window.rootViewController;
        UIViewController *best = nil;
        AMHomeUIControllerKind bestKind = AMHomeUIControllerKindNone;
        AMHomeUIFindBestController(root, [NSMutableSet set], 0, &best,
                                   &bestKind);
        avatarHost = best;
    }
    AMHomeUIApplyAvatarToNativeController(avatarHost);
    [AMHomeUIEmbeddedController updateAvatar];
}

static void AMHomeUIScheduleAvatarRefreshes(void) {
    for (NSNumber *delay in @[@0, @0.2, @0.8, @2.0]) {
        dispatch_after(dispatch_time(
                           DISPATCH_TIME_NOW,
                           (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AMHomeUIRefreshAvatarEverywhere();
        });
    }
}

static void AMHomeUIActivateSafely(void) {
    @try {
        AMHomeUIScheduleAttachAttempts();
        AMHomeUIRefreshAvatarEverywhere();
    } @catch (NSException *exception) {
        AMHomeUIAttachLoopRunning = NO;
        NSLog(@"[AMHomeUI] activation failed: %@ %@", exception.name,
              exception.reason ?: @"");
    }
}

static void AMHomeUIScheduleActivation(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AMHomeUIActivateSafely();
    });
}

void AMHomeUIInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            AMHomeUIScheduleActivation(0.35);
        }];
        for (NSNotificationName name in @[
            AMHomeUIAvatarChangedNotification,
            AMHomeUITokenChangedNotification,
        ]) {
            [NSNotificationCenter.defaultCenter
                addObserverForName:name object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *notification) {
                AMHomeUIScheduleAvatarRefreshes();
            }];
        }
        // 动态加载时应用通常已经激活，显式执行首次挂载。
        AMHomeUIScheduleActivation(0.35);
    });
}
