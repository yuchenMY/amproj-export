#import "AMHomeUI.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <CoreText/CoreText.h>
#import <os/log.h>
#import <string.h>

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
static const void *AMHomeUIAvatarOverlayKey = &AMHomeUIAvatarOverlayKey;
static void *AMHomeUITabSelectionContext = &AMHomeUITabSelectionContext;

@class AMHomeUIController;

static __weak UIViewController *AMHomeUIEmbeddedHost;
static __weak UIView *AMHomeUIEmbeddedHostView;
static AMHomeUIController *AMHomeUIEmbeddedController;
static NSArray<NSLayoutConstraint *> *AMHomeUIEmbeddedConstraints;
static BOOL AMHomeUIAttachLoopRunning;
static void AMHomeUIApplyBrandLogoEverywhere(void);
static BOOL AMHomeUIIsBuild865(void) {
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:
        @"CFBundleVersion"];
    return [build isEqualToString:@"865"];
}

static void AMHomeUIInstallSettingsDrawerTrim(void);

static BOOL AMHomeUIAttachToHost(UIViewController *controller, UIView *hostView);
static BOOL AMHomeUIEmbeddedConstraintsAreActive(void);
static UIView *AMHomeUIDirectChildContainingView(UIView *hostView,
                                                  UIView *descendant);
static void AMHomeUIRefreshEmbeddedLayerOrder(void);
static BOOL AMHomeUIEmbeddedLayerOrderNeedsRefresh(void);
static void AMHomeUIClearEmbeddedAttachment(void);
static id AMHomeUIMainTabControllerForController(UIViewController *controller);
static BOOL AMHomeUIViewIsVisible(UIView *view, UIWindow *window);
static BOOL AMHomeUIIsHomeTabSelected(UIViewController *controller,
                                      NSInteger *detectedHomeIndexInOut,
                                      NSInteger *selectedIndexOut,
                                      BOOL *indexKnownOut,
                                      BOOL *nativeHomeVisibleOut);
static void AMHomeUIRefreshAvatarEverywhere(void);
static void AMHomeUIApplyAvatarToButton(UIButton *button, UIImage *avatar);

typedef NS_ENUM(NSInteger, AMHomeUIControllerKind) {
    AMHomeUIControllerKindNone = 0,
    AMHomeUIControllerKindFeed = 1,
    AMHomeUIControllerKindHome = 2,
    AMHomeUIControllerKindMain = 3,
};

static AMHomeUIControllerKind AMHomeUIAttach(void);

static NSString *AMHomeUIEmbeddedPresentationScript(void) {
    return
        @"(function(){"
         "var apply=function(){var root=document.documentElement;"
         "if(root){root.setAttribute('data-am-native-embedded','true');}"
         "var headers=document.querySelectorAll('.home-header');"
         "for(var index=0;index<headers.length;index++){"
         "var header=headers[index];header.hidden=true;"
         "header.setAttribute('aria-hidden','true');}};"
         "var start=function(){apply();"
         "if(window.__amNativeEmbeddedObserver||!window.MutationObserver){return;}"
         "var root=document.documentElement;if(!root){return;}"
         "var observer=new MutationObserver(apply);"
         "observer.observe(root,{childList:true,subtree:true});"
         "window.__amNativeEmbeddedObserver=observer;};"
         "if(document.documentElement){start();}"
         "else{document.addEventListener('DOMContentLoaded',start,{once:true});}"
         "document.addEventListener('DOMContentLoaded',apply,{once:true});"
         "})();";
}

static BOOL AMHomeUIClassIsViewController(Class cls) {
    Class viewControllerClass = UIViewController.class;
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == viewControllerClass) return YES;
    }
    return NO;
}

static BOOL AMHomeUIClassIsMainController(Class cls) {
    NSString *name = cls ? NSStringFromClass(cls) : @"";
    return [name isEqualToString:@"MainVC"] ||
        [name hasSuffix:@".MainVC"] ||
        [name isEqualToString:@"_TtC12AlightMotion6MainVC"];
}

static AMHomeUIControllerKind AMHomeUIDirectKindForClass(Class cls) {
    if (!cls) return AMHomeUIControllerKindNone;
    if (AMHomeUIClassIsMainController(cls)) {
        return AMHomeUIControllerKindMain;
    }
    NSString *name = NSStringFromClass(cls) ?: @"";
    if ([name containsString:@"HomeVC"]) {
        return AMHomeUIControllerKindHome;
    }
    if ([name containsString:@"FeedVC"]) {
        return AMHomeUIControllerKindFeed;
    }
    return AMHomeUIControllerKindNone;
}

static AMHomeUIControllerKind AMHomeUIKindForClass(Class cls) {
    if (!cls || !AMHomeUIClassIsViewController(cls)) {
        return AMHomeUIControllerKindNone;
    }
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        AMHomeUIControllerKind kind = AMHomeUIDirectKindForClass(current);
        if (kind != AMHomeUIControllerKindNone) return kind;
        if (current == UIViewController.class) break;
    }
    return AMHomeUIControllerKindNone;
}

static BOOL AMHomeUIIsMainController(UIViewController *controller) {
    return controller && AMHomeUIClassIsMainController(controller.class);
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
    // Tab switches call this constantly; PNG-decoding the file each time
    // stutters the main thread. Cache by the file's fingerprint.
    static NSDate *cachedModDate = nil;
    static NSNumber *cachedSize = nil;
    static UIImage *cachedImage = nil;
    NSString *path = AMHomeUIAvatarCacheURL().path;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:path error:nil];
    NSDate *modDate = attrs[NSFileModificationDate];
    NSNumber *size = attrs[NSFileSize];
    if (cachedImage && [modDate isEqual:cachedModDate] &&
        [size isEqual:cachedSize]) {
        return cachedImage;
    }
    NSData *data = [NSData dataWithContentsOfURL:AMHomeUIAvatarCacheURL()];
    UIImage *image = data.length
        ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale]
        : nil;
    image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cachedModDate = modDate;
    cachedSize = size;
    cachedImage = image;
    return image;
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
@property(nonatomic, strong) NSObject *observedTabController;
@property(nonatomic) BOOL observingTabSelection;
@property(nonatomic) BOOL hasVisibilitySnapshot;
@property(nonatomic) BOOL lastHomeVisible;
@property(nonatomic) NSInteger lastSelectedIndex;
@property(nonatomic) BOOL lastSelectedIndexKnown;
@property(nonatomic) BOOL lastNativeHomeVisible;
@property(nonatomic, weak) NSObject *detectedHomeTabController;
@property(nonatomic) NSInteger detectedHomeTabIndex;
- (void)applyEmbeddedPresentation;
- (void)observeTabController:(NSObject *)tabController;
- (void)syncTabSelectionVisibility;
- (void)updateAvatar;
@end

@implementation AMHomeUIController

- (instancetype)init {
    self = [super init];
    if (self) self.detectedHomeTabIndex = NSNotFound;
    return self;
}

- (void)loadView {
    self.view = [UIView new];
    self.view.backgroundColor =
        [UIColor colorWithRed:0.961 green:0.965 blue:0.973 alpha:1.0];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.messageProxy = [AMHomeUIMessageProxy new];
    self.messageProxy.target = self;
    [configuration.userContentController
        addScriptMessageHandler:self.messageProxy name:@"amnative"];
    [configuration.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:AMHomeUIEmbeddedPresentationScript()
                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                           forMainFrameOnly:YES]];
    configuration.allowsInlineMediaPlayback = YES;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero
                                      configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.opaque = NO;
    if (@available(iOS 13.0, *)) {
        self.webView.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
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
    [self observeTabController:nil];
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

- (void)applyEmbeddedPresentation {
    [self.webView evaluateJavaScript:AMHomeUIEmbeddedPresentationScript()
                   completionHandler:nil];
}

- (void)observeTabController:(NSObject *)tabController {
    BOOL sameController = self.observedTabController == tabController;
    if (sameController &&
        (!tabController || self.observingTabSelection)) {
        [self syncTabSelectionVisibility];
        return;
    }
    if (!sameController && self.observingTabSelection &&
        self.observedTabController) {
        @try {
            [self.observedTabController removeObserver:self
                                            forKeyPath:@"selectedIndex"
                                               context:AMHomeUITabSelectionContext];
        } @catch (__unused NSException *exception) {
        }
    }
    if (!sameController) {
        self.observingTabSelection = NO;
        self.observedTabController = tabController;
        self.detectedHomeTabController = tabController;
        self.detectedHomeTabIndex = NSNotFound;
        self.hasVisibilitySnapshot = NO;
    }
    if (tabController && !self.observingTabSelection) {
        @try {
            [tabController addObserver:self
                            forKeyPath:@"selectedIndex"
                               options:NSKeyValueObservingOptionNew
                               context:AMHomeUITabSelectionContext];
            self.observingTabSelection = YES;
        } @catch (NSException *exception) {
            NSLog(@"[AMHomeUI] selectedIndex observation unavailable: %@ %@",
                  exception.name, exception.reason ?: @"");
        }
    }
    [self syncTabSelectionVisibility];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context == AMHomeUITabSelectionContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncTabSelectionVisibility];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath
                        ofObject:object
                          change:change
                         context:context];
}

- (void)syncTabSelectionVisibility {
    UIViewController *host = AMHomeUIEmbeddedHost;
    UIView *hostView = AMHomeUIEmbeddedHostView;
    UIView *embeddedView = self.viewIfLoaded;
    UIWindow *window = hostView.window ?: AMHomeUIKeyWindow();
    BOOL hasValidRegion = AMHomeUIIsMainController(host) && hostView &&
        embeddedView.superview == hostView &&
        AMHomeUIEmbeddedConstraintsAreActive() &&
        AMHomeUIViewIsVisible(hostView, window);
    NSInteger selectedIndex = NSNotFound;
    BOOL selectedIndexKnown = NO;
    BOOL nativeHomeVisible = NO;
    NSObject *tabController = AMHomeUIMainTabControllerForController(host);
    if (self.detectedHomeTabController != tabController) {
        self.detectedHomeTabController = tabController;
        self.detectedHomeTabIndex = NSNotFound;
    }
    NSInteger detectedHomeIndex = self.detectedHomeTabIndex;
    BOOL homeSelected = AMHomeUIIsHomeTabSelected(
        host, &detectedHomeIndex, &selectedIndex, &selectedIndexKnown,
        &nativeHomeVisible);
    self.detectedHomeTabIndex = detectedHomeIndex;
    BOOL shouldShow = hasValidRegion && homeSelected;
    BOOL wasHidden = embeddedView.hidden;
    embeddedView.hidden = !shouldShow;
    if (shouldShow &&
        (wasHidden || AMHomeUIEmbeddedLayerOrderNeedsRefresh())) {
        AMHomeUIRefreshEmbeddedLayerOrder();
    }
    if (!self.hasVisibilitySnapshot || self.lastHomeVisible != shouldShow ||
        self.lastSelectedIndex != selectedIndex ||
        self.lastSelectedIndexKnown != selectedIndexKnown ||
        self.lastNativeHomeVisible != nativeHomeVisible) {
        NSLog(@"[AMHomeUI] visibility=%@ region=%@ selectedIndex=%@ nativeHome=%@ learnedIndex=%@",
              shouldShow ? @"shown" : @"hidden",
              hasValidRegion ? @"valid" : @"invalid",
              selectedIndexKnown ? @(selectedIndex) : @"unknown",
              nativeHomeVisible ? @"yes" : @"no",
              self.detectedHomeTabIndex == NSNotFound
                  ? @"unknown" : @(self.detectedHomeTabIndex));
        self.hasVisibilitySnapshot = YES;
        self.lastHomeVisible = shouldShow;
        self.lastSelectedIndex = selectedIndex;
        self.lastSelectedIndexKnown = selectedIndexKnown;
        self.lastNativeHomeVisible = nativeHomeVisible;
    }
}

- (void)updateAvatar {
    // PNG-encoding the avatar and rebuilding the injection script on every
    // tab switch stalls the main thread; the script only changes when the
    // avatar file does.
    static NSString *cachedScript = nil;
    static NSString *cachedFingerprint = nil;
    NSString *avatarPath = AMHomeUIAvatarCacheURL().path;
    NSDictionary *avatarAttrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:avatarPath error:nil];
    NSString *fingerprint = [NSString stringWithFormat:@"%@|%@",
        avatarAttrs[NSFileModificationDate] ?: @"",
        avatarAttrs[NSFileSize] ?: @""];
    NSString *script = nil;
    if (cachedScript && [fingerprint isEqualToString:cachedFingerprint]) {
        script = cachedScript;
    } else {
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
    script = [NSString stringWithFormat:
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
    cachedFingerprint = fingerprint;
    cachedScript = script;
    }
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
    [self applyEmbeddedPresentation];
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
        [self loadHome];
        [self syncTabSelectionVisibility];
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

static id AMHomeUIObjectPropertyForController(UIViewController *controller,
                                               NSString *propertyName) {
    SEL selector = NSSelectorFromString(propertyName);
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

static id AMHomeUIObjectIvarValue(id object, NSString *nameFragment) {
    if (!object || nameFragment.length == 0) return nil;
    NSString *needle = nameFragment.lowercaseString;
    for (Class current = object_getClass(object); current;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(current, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = ivars[index];
            const char *name = ivar_getName(ivar);
            const char *type = ivar_getTypeEncoding(ivar);
            NSString *ivarName = name ? [NSString stringWithUTF8String:name] : @"";
            if (type && type[0] == '@' &&
                [ivarName.lowercaseString containsString:needle]) {
                id value = object_getIvar(object, ivar);
                free(ivars);
                return value;
            }
        }
        free(ivars);
    }
    return nil;
}

static UITabBarController *AMHomeUIFindEmbeddedTabController(
    UIViewController *controller, NSMutableSet<NSValue *> *visited,
    NSUInteger depth) {
    if (!controller || depth > 8) return nil;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if (depth > 0 && [controller isKindOfClass:UITabBarController.class]) {
        return (UITabBarController *)controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UITabBarController *match = AMHomeUIFindEmbeddedTabController(
            child, visited, depth + 1);
        if (match) return match;
    }
    return nil;
}

static id AMHomeUIMainTabControllerForController(UIViewController *controller) {
    if (!AMHomeUIIsMainController(controller)) return nil;
    id tabController = AMHomeUIObjectPropertyForController(controller, @"embedTBC");
    if (!tabController) {
        @try {
            tabController = [controller valueForKey:@"embedTBC"];
        } @catch (__unused NSException *exception) {
            tabController = nil;
        }
    }
    if (!tabController) {
        tabController = AMHomeUIObjectIvarValue(controller, @"embedTBC");
    }
    if ([tabController isKindOfClass:UIViewController.class]) {
        return tabController;
    }
    return AMHomeUIFindEmbeddedTabController(
        controller, [NSMutableSet set], 0) ?: tabController;
}

static NSInteger AMHomeUISelectedTabIndex(id tabController, BOOL *known) {
    if (known) *known = NO;
    if (!tabController) return NSNotFound;
    @try {
        id value = [tabController valueForKey:@"selectedIndex"];
        if ([value respondsToSelector:@selector(integerValue)]) {
            if (known) *known = YES;
            return [value integerValue];
        }
    } @catch (__unused NSException *exception) {
    }

    SEL selector = NSSelectorFromString(@"selectedIndex");
    Method method = class_getInstanceMethod([tabController class], selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NSNotFound;
    char *returnType = method_copyReturnType(method);
    BOOL returnsInteger = returnType && strchr("cislqCISLQB", returnType[0]);
    free(returnType);
    if (!returnsInteger) return NSNotFound;
    IMP implementation = method_getImplementation(method);
    if (!implementation) return NSNotFound;
    if (known) *known = YES;
    return ((NSInteger (*)(id, SEL))implementation)(tabController, selector);
}

static BOOL AMHomeUIControllerTreeContainsHome(
    UIViewController *controller, NSMutableSet<NSValue *> *visited,
    NSUInteger depth) {
    if (!controller || depth > 16) return NO;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return NO;
    [visited addObject:identity];
    AMHomeUIControllerKind kind = AMHomeUIKindForClass(controller.class);
    if (kind == AMHomeUIControllerKindHome ||
        kind == AMHomeUIControllerKindFeed) {
        return YES;
    }
    for (UIViewController *child in controller.childViewControllers) {
        if (AMHomeUIControllerTreeContainsHome(child, visited, depth + 1)) {
            return YES;
        }
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
             ((UINavigationController *)controller).viewControllers) {
            if (AMHomeUIControllerTreeContainsHome(child, visited, depth + 1)) {
                return YES;
            }
        }
    }
    return NO;
}

static UIViewController *AMHomeUISelectedBranchController(id tabController) {
    if (!tabController) return nil;
    id selectedController = nil;
    @try {
        selectedController = [tabController valueForKey:@"selectedViewController"];
    } @catch (__unused NSException *exception) {
        selectedController = nil;
    }
    if (![selectedController isKindOfClass:UIViewController.class]) {
        BOOL indexKnown = NO;
        NSInteger selectedIndex =
            AMHomeUISelectedTabIndex(tabController, &indexKnown);
        id controllers = nil;
        @try {
            controllers = [tabController valueForKey:@"viewControllers"];
        } @catch (__unused NSException *exception) {
            controllers = nil;
        }
        if (indexKnown && [controllers isKindOfClass:NSArray.class] &&
            selectedIndex >= 0 && selectedIndex < (NSInteger)[controllers count]) {
            id candidate = controllers[(NSUInteger)selectedIndex];
            if ([candidate isKindOfClass:UIViewController.class]) {
                selectedController = candidate;
            }
        }
    }
    if (![selectedController isKindOfClass:UIViewController.class] ||
        AMHomeUIKindForClass([selectedController class]) ==
            AMHomeUIControllerKindMain) {
        return nil;
    }
    return selectedController;
}

typedef NS_OPTIONS(NSUInteger, AMHomeUIMarkerMask) {
    AMHomeUIMarkerLatestProjects = 1u << 0,
    AMHomeUIMarkerViewAll = 1u << 1,
    AMHomeUIMarkerCreateProject = 1u << 2,
    AMHomeUIMarkerGettingStarted = 1u << 3,
    AMHomeUIMarkerTutorial = 1u << 4,
};

static AMHomeUIMarkerMask AMHomeUIMarkersForText(NSString *value) {
    NSString *text = value.lowercaseString ?: @"";
    AMHomeUIMarkerMask markers = 0;
    if ([text containsString:@"\u6700\u65b0\u9879\u76ee"] ||
        [text containsString:@"latest projects"]) {
        markers |= AMHomeUIMarkerLatestProjects;
    }
    if ([text containsString:@"\u67e5\u770b\u5168\u90e8"] ||
        [text containsString:@"view all"]) {
        markers |= AMHomeUIMarkerViewAll;
    }
    if ([text containsString:@"\u521b\u5efa\u65b0\u9879\u76ee"] ||
        [text containsString:@"create new project"]) {
        markers |= AMHomeUIMarkerCreateProject;
    }
    if ([text containsString:@"\u5f00\u59cb\u4f7f\u7528"] ||
        [text containsString:@"getting started"]) {
        markers |= AMHomeUIMarkerGettingStarted;
    }
    if ([text containsString:@"\u89c2\u770b\u6211\u4eec\u7684\u6559\u7a0b"] ||
        [text containsString:@"watch our tutorials"]) {
        markers |= AMHomeUIMarkerTutorial;
    }
    return markers;
}

static void AMHomeUICollectNativeHomeMarkers(
    UIView *view, UIWindow *window, AMHomeUIMarkerMask *markers,
    NSUInteger depth) {
    if (!view || !window || !markers || depth > 32 ||
        !AMHomeUIViewIsVisible(view, window)) {
        return;
    }
    NSString *text = view.accessibilityLabel;
    if ([view isKindOfClass:UILabel.class]) {
        text = ((UILabel *)view).text ?: text;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        text = button.currentTitle ?: button.titleLabel.text ?: text;
    }
    *markers |= AMHomeUIMarkersForText(text);
    for (UIView *subview in view.subviews) {
        AMHomeUICollectNativeHomeMarkers(
            subview, window, markers, depth + 1);
    }
}

static BOOL AMHomeUINativeHomeVisibleInView(UIView *view,
                                            UIView *excludedView) {
    if (!view || view.hidden || view.alpha <= 0.01 || !view.window) return NO;
    AMHomeUIMarkerMask markers = 0;
    for (UIView *subview in view.subviews) {
        if (subview == excludedView) continue;
        AMHomeUICollectNativeHomeMarkers(subview, view.window, &markers, 0);
    }
    NSUInteger count = 0;
    for (NSUInteger value = markers; value; value >>= 1) {
        count += value & 1u;
    }
    return count >= 2;
}

static BOOL AMHomeUINativeHomeVisible(UIViewController *controller) {
    return AMHomeUINativeHomeVisibleInView(controller.viewIfLoaded, nil);
}

static BOOL AMHomeUIIsHomeTabSelected(UIViewController *controller,
                                      NSInteger *detectedHomeIndexInOut,
                                      NSInteger *selectedIndexOut,
                                      BOOL *indexKnownOut,
                                      BOOL *nativeHomeVisibleOut) {
    BOOL known = NO;
    id tabController = AMHomeUIMainTabControllerForController(controller);
    NSInteger selectedIndex = AMHomeUISelectedTabIndex(tabController, &known);
    NSInteger detectedHomeIndex = detectedHomeIndexInOut
        ? *detectedHomeIndexInOut : NSNotFound;
    BOOL needsHomeDiscovery = detectedHomeIndex == NSNotFound;
    UIViewController *selectedBranch = needsHomeDiscovery
        ? AMHomeUISelectedBranchController(tabController) : nil;
    BOOL branchContainsHome = selectedBranch &&
        AMHomeUIControllerTreeContainsHome(
            selectedBranch, [NSMutableSet set], 0);
    BOOL nativeHomeVisible = selectedBranch &&
        AMHomeUINativeHomeVisible(selectedBranch);
    if (!nativeHomeVisible) {
        UIView *hostView = AMHomeUIEmbeddedHostView ?: controller.viewIfLoaded;
        nativeHomeVisible = AMHomeUINativeHomeVisibleInView(
            hostView, AMHomeUIEmbeddedController.viewIfLoaded);
    }
    if (selectedIndexOut) *selectedIndexOut = selectedIndex;
    if (indexKnownOut) *indexKnownOut = known;
    if (nativeHomeVisibleOut) *nativeHomeVisibleOut = nativeHomeVisible;

    if (needsHomeDiscovery && (branchContainsHome || nativeHomeVisible) && known) {
        detectedHomeIndex = selectedIndex;
        if (detectedHomeIndexInOut) {
            *detectedHomeIndexInOut = detectedHomeIndex;
        }
    }
    if (known && detectedHomeIndex != NSNotFound) {
        return selectedIndex == detectedHomeIndex;
    }
    if (branchContainsHome || nativeHomeVisible) return YES;
    return known && selectedIndex == 0;
}

static id AMHomeUIAccountControlForController(UIViewController *controller) {
    id control = AMHomeUIObjectPropertyForController(controller, @"accountButton");
    if (control) return control;
    for (NSString *key in @[@"accountButton", @"profileButton", @"userButton"]) {
        @try {
            control = [controller valueForKey:key];
        } @catch (__unused NSException *exception) {
            control = nil;
        }
        if (control) return control;
    }
    return nil;
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

    UIImageView *overlay = objc_getAssociatedObject(button,
                                                     AMHomeUIAvatarOverlayKey);
    if (avatar) {
        if (!overlay) {
            overlay = [UIImageView new];
            overlay.translatesAutoresizingMaskIntoConstraints = NO;
            overlay.userInteractionEnabled = NO;
            overlay.contentMode = UIViewContentModeScaleAspectFill;
            overlay.clipsToBounds = YES;
            overlay.accessibilityIdentifier = @"AMHomeUIAccountAvatar";
            objc_setAssociatedObject(button, AMHomeUIAvatarOverlayKey, overlay,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (overlay.superview != button) {
            [overlay removeFromSuperview];
            [button addSubview:overlay];
            [NSLayoutConstraint activateConstraints:@[
                [overlay.topAnchor constraintEqualToAnchor:button.topAnchor
                                                  constant:3.0],
                [overlay.leadingAnchor constraintEqualToAnchor:button.leadingAnchor
                                                      constant:3.0],
                [overlay.trailingAnchor constraintEqualToAnchor:button.trailingAnchor
                                                       constant:-3.0],
                [overlay.bottomAnchor constraintEqualToAnchor:button.bottomAnchor
                                                     constant:-3.0],
            ]];
        }
        overlay.image = avatar;
        overlay.hidden = NO;
        [button layoutIfNeeded];
        CGFloat diameter = MIN(CGRectGetWidth(overlay.bounds),
                               CGRectGetHeight(overlay.bounds));
        if (diameter <= 0.0) {
            diameter = MAX(0.0, MIN(CGRectGetWidth(button.bounds),
                                    CGRectGetHeight(button.bounds)) - 6.0);
        }
        overlay.layer.cornerRadius = diameter * 0.5;
        [button bringSubviewToFront:overlay];
    } else {
        overlay.image = nil;
        overlay.hidden = YES;
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

static void AMHomeUIAppendUniqueController(
    UIViewController *controller, NSMutableArray<UIViewController *> *controllers,
    NSMutableSet<NSValue *> *visited) {
    if (!controller) return;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    [controllers addObject:controller];
}

static UIViewController *AMHomeUIFindMainController(
    UIViewController *root, NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!root || depth > 24) return nil;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)root];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if (AMHomeUIIsMainController(root)) return root;
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *match =
            AMHomeUIFindMainController(child, visited, depth + 1);
        if (match) return match;
    }
    UIViewController *presented = AMHomeUIFindMainController(
        root.presentedViewController, visited, depth + 1);
    if (presented) return presented;
    if ([root isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
             ((UINavigationController *)root).viewControllers) {
            UIViewController *match =
                AMHomeUIFindMainController(child, visited, depth + 1);
            if (match) return match;
        }
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in
             ((UITabBarController *)root).viewControllers) {
            UIViewController *match =
                AMHomeUIFindMainController(child, visited, depth + 1);
            if (match) return match;
        }
    }
    return nil;
}

static void AMHomeUIApplyAvatarToNativeController(
    UIViewController *controller) {
    UIWindow *keyWindow = controller.viewIfLoaded.window ?: AMHomeUIKeyWindow();
    UIViewController *mainController = AMHomeUIFindMainController(
        keyWindow.rootViewController, [NSMutableSet set], 0);
    if (!controller) controller = mainController;
    if (!controller) return;
    UIImage *avatar = AMHomeUILoadAvatar();
    NSMutableArray<UIViewController *> *homeControllers = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedHomeControllers = [NSMutableSet set];
    NSMutableArray<UIViewController *> *accountOwners = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedAccountOwners = [NSMutableSet set];
    AMHomeUIAppendUniqueController(mainController, accountOwners,
                                   visitedAccountOwners);
    UIViewController *current = controller;
    for (NSUInteger depth = 0; current && depth < 16; depth++) {
        AMHomeUIAppendUniqueController(current, accountOwners,
                                       visitedAccountOwners);
        if (AMHomeUIKindForClass(current.class) != AMHomeUIControllerKindNone) {
            AMHomeUIAppendUniqueController(current, homeControllers,
                                           visitedHomeControllers);
        }
        current = current.parentViewController;
    }
    UINavigationController *navigation = controller.navigationController;
    for (UIViewController *candidate in @[
        navigation.visibleViewController ?: controller,
        navigation.topViewController ?: controller,
    ]) {
        AMHomeUIAppendUniqueController(candidate, accountOwners,
                                       visitedAccountOwners);
        if (AMHomeUIKindForClass(candidate.class) !=
                AMHomeUIControllerKindNone) {
            AMHomeUIAppendUniqueController(candidate, homeControllers,
                                           visitedHomeControllers);
        }
    }
    current = navigation;
    for (NSUInteger depth = 0; current && depth < 16; depth++) {
        AMHomeUIAppendUniqueController(current, accountOwners,
                                       visitedAccountOwners);
        current = current.parentViewController;
    }
    NSMutableArray<UIBarButtonItem *> *labeledBarItems = [NSMutableArray array];
    NSMutableArray<UIBarButtonItem *> *propertyBarItems = [NSMutableArray array];
    NSMutableArray<UIButton *> *propertyButtons = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedBarItems = [NSMutableSet set];
    NSMutableSet<NSValue *> *visitedPropertyControls = [NSMutableSet set];
    for (UIViewController *candidate in accountOwners) {
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
    }
    for (UIViewController *candidate in homeControllers) {
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
    for (UIBarButtonItem *item in propertyBarItems) {
        AMHomeUIApplyAvatarToBarItem(item, avatar);
    }
    if (propertyBarItems.count == 0 && labeledBarItems.count == 1) {
        AMHomeUIApplyAvatarToBarItem(labeledBarItems.firstObject, avatar);
    }

    UIWindow *window = controller.viewIfLoaded.window ?: keyWindow;
    if (!window) return;
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedRoots = [NSMutableSet set];
    UIView *mainView = mainController.viewIfLoaded;
    if (mainView && mainView.window == window) {
        [visitedRoots addObject:[NSValue valueWithPointer:
            (__bridge const void *)mainView]];
        [roots addObject:mainView];
    }
    for (UIViewController *candidate in homeControllers) {
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
    NSMutableArray<UIButton *> *uniqueButtons = [NSMutableArray array];
    NSMutableSet<NSValue *> *visitedButtons = [NSMutableSet set];
    for (UIButton *button in buttons) {
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)button];
        if ([visitedButtons containsObject:identity]) continue;
        [visitedButtons addObject:identity];
        [uniqueButtons addObject:button];
        NSString *label = [NSString stringWithFormat:@"%@ %@ %@",
            button.accessibilityLabel ?: @"",
            button.accessibilityIdentifier ?: @"",
            [button titleForState:UIControlStateNormal] ?: @""];
        if (AMHomeUIStringLooksLikeAccount(label))
            [labeledButtons addObject:button];
    }
    for (UIButton *button in propertyButtons) {
        AMHomeUIApplyAvatarToButton(button, avatar);
    }
    if (propertyButtons.count == 0 && labeledButtons.count == 1) {
        AMHomeUIApplyAvatarToButton(labeledButtons.firstObject, avatar);
    } else if (propertyButtons.count == 0 && labeledButtons.count == 0 &&
               uniqueButtons.count == 1) {
        AMHomeUIApplyAvatarToButton(uniqueButtons.firstObject, avatar);
    }
    NSLog(@"[AMHomeUI] avatar refresh cache=%@ property=%lu labeled=%lu unique=%lu",
          avatar ? @"yes" : @"no",
          (unsigned long)propertyButtons.count,
          (unsigned long)labeledButtons.count,
          (unsigned long)uniqueButtons.count);
}

static BOOL AMHomeUIViewIsVisible(UIView *view, UIWindow *window) {
    if (!view || !window || view.window != window || CGRectIsEmpty(view.bounds)) {
        return NO;
    }
    for (UIView *current = view; current; current = current.superview) {
        if (current.hidden || current.alpha <= 0.01) return NO;
        if (current == window) break;
    }
    CGRect frame = [view convertRect:view.bounds toView:window];
    return !CGRectIsNull(frame) && !CGRectIsInfinite(frame) &&
        CGRectGetWidth(frame) > 1.0 && CGRectGetHeight(frame) > 1.0 &&
        CGRectIntersectsRect(window.bounds, frame);
}

static UIView *AMHomeUIViewPropertyForController(
    UIViewController *controller, NSString *propertyName) {
    id value = AMHomeUIObjectPropertyForController(controller, propertyName);
    if (![value isKindOfClass:UIView.class]) {
        @try {
            value = [controller valueForKey:propertyName];
        } @catch (__unused NSException *exception) {
            value = nil;
        }
    }
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static UIView *AMHomeUIMainContentView(UIViewController *controller) {
    if (!AMHomeUIIsMainController(controller) || !controller.isViewLoaded) {
        return nil;
    }
    UIView *controllerView = controller.viewIfLoaded;
    UIView *mainView =
        AMHomeUIViewPropertyForController(controller, @"mainView");
    if (!mainView || (mainView != controllerView &&
                      ![mainView isDescendantOfView:controllerView])) {
        mainView = controllerView.subviews.count == 1
            ? controllerView.subviews.firstObject : controllerView;
    }

    id tabController = AMHomeUIMainTabControllerForController(controller);
    UIView *tabControllerView =
        [tabController isKindOfClass:UIViewController.class]
            ? ((UIViewController *)tabController).viewIfLoaded : nil;
    UIView *containerView =
        AMHomeUIDirectChildContainingView(mainView, tabControllerView);
    if (containerView) return containerView;

    UIView *topBar = AMHomeUIViewPropertyForController(controller, @"topBar");
    UIView *tabBarView =
        AMHomeUIViewPropertyForController(controller, @"tabBarView");
    CGRect topFrame = topBar
        ? [topBar convertRect:topBar.bounds toView:mainView] : CGRectZero;
    CGRect bottomFrame = tabBarView
        ? [tabBarView convertRect:tabBarView.bounds toView:mainView]
        : CGRectMake(0.0, CGRectGetHeight(mainView.bounds), 0.0, 0.0);
    CGFloat topEdge = topBar ? CGRectGetMaxY(topFrame) : 0.0;
    CGFloat bottomEdge = tabBarView
        ? CGRectGetMinY(bottomFrame) : CGRectGetHeight(mainView.bounds);
    UIView *bestContainer = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    CGFloat bestArea = 0.0;
    for (UIView *subview in mainView.subviews) {
        if (subview == topBar || subview == tabBarView || subview.hidden ||
            subview.alpha <= 0.01) {
            continue;
        }
        CGRect frame = [subview convertRect:subview.bounds toView:mainView];
        if (CGRectIsNull(frame) || CGRectIsInfinite(frame) ||
            CGRectGetWidth(frame) < CGRectGetWidth(mainView.bounds) * 0.7 ||
            CGRectGetMinY(frame) > topEdge + 4.0 ||
            CGRectGetMaxY(frame) < bottomEdge - 4.0) {
            continue;
        }
        CGFloat topDelta = CGRectGetMinY(frame) - topEdge;
        if (topDelta < 0.0) topDelta = -topDelta;
        CGFloat bottomDelta = CGRectGetMaxY(frame) - bottomEdge;
        if (bottomDelta < 0.0) bottomDelta = -bottomDelta;
        CGFloat distance = topDelta + bottomDelta;
        CGFloat area = CGRectGetWidth(frame) * CGRectGetHeight(frame);
        if (!bestContainer || distance < bestDistance - 0.5 ||
            (distance <= bestDistance + 0.5 && area > bestArea)) {
            bestContainer = subview;
            bestDistance = distance;
            bestArea = area;
        }
    }
    return bestContainer;
}

static UIView *AMHomeUIHostViewForController(UIViewController *controller,
                                              UIWindow *window) {
    if (!controller || !controller.isViewLoaded) return nil;
    AMHomeUIControllerKind kind = AMHomeUIKindForClass(controller.class);
    UIView *hostView = kind == AMHomeUIControllerKindMain
        ? AMHomeUIMainContentView(controller) : controller.viewIfLoaded;
    return AMHomeUIViewIsVisible(hostView, window) ? hostView : nil;
}

static void AMHomeUIFindBestHost(
    UIViewController *root, UIWindow *window,
    NSMutableSet<NSValue *> *visited, NSUInteger depth,
    UIViewController *__strong *bestController, UIView *__strong *bestHostView,
    AMHomeUIControllerKind *bestKind) {
    if (!root || depth > 24 || *bestKind == AMHomeUIControllerKindMain) return;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)root];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    AMHomeUIControllerKind kind = AMHomeUIKindForClass(root.class);
    UIView *hostView = AMHomeUIHostViewForController(root, window);
    if (hostView && kind > *bestKind) {
        *bestController = root;
        *bestHostView = hostView;
        *bestKind = kind;
    }
    for (UIViewController *child in root.childViewControllers) {
        AMHomeUIFindBestHost(child, window, visited, depth + 1, bestController,
                            bestHostView, bestKind);
    }
    AMHomeUIFindBestHost(root.presentedViewController, window, visited, depth + 1,
                        bestController, bestHostView, bestKind);
    if ([root isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in
             ((UINavigationController *)root).viewControllers) {
            AMHomeUIFindBestHost(child, window, visited, depth + 1,
                                bestController, bestHostView, bestKind);
        }
    }
    if ([root isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in
             ((UITabBarController *)root).viewControllers) {
            AMHomeUIFindBestHost(child, window, visited, depth + 1,
                                bestController, bestHostView, bestKind);
        }
    }
}

static void AMHomeUIFindBestHostInView(
    UIView *view, UIWindow *window, NSMutableSet<NSValue *> *visited,
    NSUInteger depth, UIViewController *__strong *bestController,
    UIView *__strong *bestHostView, AMHomeUIControllerKind *bestKind) {
    if (!view || depth > 64 || *bestKind == AMHomeUIControllerKindMain) return;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    UIResponder *responder = view;
    for (NSUInteger step = 0; responder && step < 32; step++) {
        responder = responder.nextResponder;
        if (![responder isKindOfClass:UIViewController.class]) continue;
        UIViewController *controller = (UIViewController *)responder;
        AMHomeUIControllerKind kind = AMHomeUIKindForClass(controller.class);
        UIView *hostView = AMHomeUIHostViewForController(controller, window);
        if (hostView && kind > *bestKind) {
            *bestController = controller;
            *bestHostView = hostView;
            *bestKind = kind;
        }
        if (*bestKind == AMHomeUIControllerKindMain) return;
    }

    for (UIView *subview in view.subviews) {
        AMHomeUIFindBestHostInView(subview, window, visited, depth + 1,
                                   bestController, bestHostView, bestKind);
        if (*bestKind == AMHomeUIControllerKindMain) return;
    }
}

static BOOL AMHomeUIEmbeddedConstraintsAreActive(void) {
    if (AMHomeUIEmbeddedConstraints.count != 4) return NO;
    for (NSLayoutConstraint *constraint in AMHomeUIEmbeddedConstraints) {
        if (!constraint.active) return NO;
    }
    return YES;
}

static UIView *AMHomeUIDirectChildContainingView(UIView *hostView,
                                                  UIView *descendant) {
    if (!hostView || !descendant || descendant == hostView) return nil;
    UIView *current = descendant;
    while (current.superview && current.superview != hostView) {
        current = current.superview;
    }
    return current.superview == hostView ? current : nil;
}

static UIView *AMHomeUINativeContentAnchorView(void) {
    UIView *hostView = AMHomeUIEmbeddedHostView;
    UIView *embeddedView = AMHomeUIEmbeddedController.viewIfLoaded;
    if (!hostView || !embeddedView || embeddedView.superview != hostView) {
        return nil;
    }

    id tabController =
        AMHomeUIMainTabControllerForController(AMHomeUIEmbeddedHost);
    UIViewController *selectedBranch =
        AMHomeUISelectedBranchController(tabController);
    UIView *selectedView = selectedBranch.viewIfLoaded;
    if (selectedView && selectedView != hostView &&
        [selectedView isDescendantOfView:hostView]) {
        UIView *anchor =
            AMHomeUIDirectChildContainingView(hostView, selectedView);
        if (anchor && anchor != embeddedView) return anchor;
    }

    UIView *anchor = nil;
    UIWindow *window = hostView.window;
    for (UIView *subview in hostView.subviews) {
        if (subview == embeddedView) continue;
        AMHomeUIMarkerMask markers = 0;
        AMHomeUICollectNativeHomeMarkers(subview, window, &markers, 0);
        if (markers) anchor = subview;
    }
    return anchor;
}

static void AMHomeUIRefreshEmbeddedLayerOrder(void) {
    UIView *hostView = AMHomeUIEmbeddedHostView;
    UIView *embeddedView = AMHomeUIEmbeddedController.viewIfLoaded;
    if (!hostView || embeddedView.superview != hostView) {
        return;
    }
    UIView *nativeContentAnchor = AMHomeUINativeContentAnchorView();
    if (nativeContentAnchor && nativeContentAnchor.superview == hostView) {
        [hostView insertSubview:embeddedView aboveSubview:nativeContentAnchor];
    }
}

static BOOL AMHomeUIEmbeddedLayerOrderNeedsRefresh(void) {
    UIView *hostView = AMHomeUIEmbeddedHostView;
    UIView *embeddedView = AMHomeUIEmbeddedController.viewIfLoaded;
    if (!hostView || embeddedView.superview != hostView) return NO;
    UIView *nativeContentAnchor = AMHomeUINativeContentAnchorView();
    if (!nativeContentAnchor || nativeContentAnchor.superview != hostView) {
        return NO;
    }
    NSUInteger embeddedIndex =
        [hostView.subviews indexOfObjectIdenticalTo:embeddedView];
    if (embeddedIndex == NSNotFound) return NO;
    NSUInteger nativeContentIndex =
        [hostView.subviews indexOfObjectIdenticalTo:nativeContentAnchor];
    return nativeContentIndex != NSNotFound &&
        embeddedIndex != nativeContentIndex + 1;
}

static void AMHomeUIClearEmbeddedAttachment(void) {
    UIViewController *oldHost = AMHomeUIEmbeddedHost;
    AMHomeUIController *controller = AMHomeUIEmbeddedController;
    [controller observeTabController:nil];
    if (AMHomeUIEmbeddedConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:AMHomeUIEmbeddedConstraints];
    }
    AMHomeUIEmbeddedConstraints = nil;
    if (controller) {
        BOOL hadParent = controller.parentViewController != nil;
        if (hadParent) [controller willMoveToParentViewController:nil];
        [controller.viewIfLoaded removeFromSuperview];
        if (hadParent) [controller removeFromParentViewController];
    }
    if (oldHost) {
        objc_setAssociatedObject(oldHost, AMHomeUIControllerKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    AMHomeUIEmbeddedHost = nil;
    AMHomeUIEmbeddedHostView = nil;
    AMHomeUIEmbeddedController = nil;
}

static BOOL AMHomeUIAttachEmbeddedView(UIView *hostView) {
    UIView *embeddedView = AMHomeUIEmbeddedController.view;
    if (!hostView || !embeddedView) return NO;
    BOOL needsLayout = embeddedView.superview != hostView ||
        !AMHomeUIEmbeddedConstraintsAreActive();
    if (!needsLayout) return NO;

    if (AMHomeUIEmbeddedConstraints.count) {
        [NSLayoutConstraint deactivateConstraints:AMHomeUIEmbeddedConstraints];
    }
    if (embeddedView.superview != hostView) {
        [embeddedView removeFromSuperview];
        embeddedView.translatesAutoresizingMaskIntoConstraints = NO;
        embeddedView.hidden = YES;
        [hostView addSubview:embeddedView];
    }
    embeddedView.clipsToBounds = YES;
    AMHomeUIEmbeddedConstraints = @[
        [embeddedView.topAnchor constraintEqualToAnchor:hostView.topAnchor],
        [embeddedView.leadingAnchor
            constraintEqualToAnchor:hostView.leadingAnchor],
        [embeddedView.trailingAnchor
            constraintEqualToAnchor:hostView.trailingAnchor],
        [embeddedView.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:AMHomeUIEmbeddedConstraints];
    AMHomeUIRefreshEmbeddedLayerOrder();
    return YES;
}

static BOOL AMHomeUIAttachToHost(UIViewController *controller, UIView *hostView) {
    if (!AMHomeUIIsMainController(controller) || !hostView) {
        AMHomeUIClearEmbeddedAttachment();
        return NO;
    }
    UIViewController *oldHost = AMHomeUIEmbeddedHost;
    UIView *oldHostView = AMHomeUIEmbeddedHostView;
    BOOL needsNewController = oldHost != controller ||
        !AMHomeUIEmbeddedController ||
        AMHomeUIEmbeddedController.parentViewController != controller;
    BOOL hostChanged = needsNewController || oldHostView != hostView;
    if (needsNewController) {
        AMHomeUIClearEmbeddedAttachment();
        AMHomeUIEmbeddedController = [AMHomeUIController new];
        AMHomeUIEmbeddedHost = controller;
        AMHomeUIEmbeddedHostView = hostView;
        [controller addChildViewController:AMHomeUIEmbeddedController];
        if (!AMHomeUIAttachEmbeddedView(hostView)) {
            AMHomeUIClearEmbeddedAttachment();
            return NO;
        }
        [AMHomeUIEmbeddedController didMoveToParentViewController:controller];
        objc_setAssociatedObject(controller, AMHomeUIControllerKey,
                                 AMHomeUIEmbeddedController,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        AMHomeUIEmbeddedHostView = hostView;
        hostChanged |= AMHomeUIAttachEmbeddedView(hostView);
    }
    [AMHomeUIEmbeddedController observeTabController:
        AMHomeUIMainTabControllerForController(controller)];
    [AMHomeUIEmbeddedController syncTabSelectionVisibility];
    if (hostChanged) {
        [AMHomeUIEmbeddedController updateAvatar];
        AMHomeUIApplyAvatarToNativeController(controller);
        NSLog(@"[AMHomeUI] embedded into %@.%@",
              NSStringFromClass(controller.class),
              AMHomeUIIsMainController(controller) ? @"containerView" : @"view");
    }
    return YES;
}

static AMHomeUIControllerKind AMHomeUIAttach(void) {
    UIWindow *window = AMHomeUIKeyWindow();
    if (!window.rootViewController) return AMHomeUIControllerKindNone;
    UIViewController *bestController = nil;
    UIView *bestHostView = nil;
    AMHomeUIControllerKind bestKind = AMHomeUIControllerKindNone;
    AMHomeUIFindBestHost(window.rootViewController, window, [NSMutableSet set],
                        0, &bestController, &bestHostView, &bestKind);
    if (bestKind != AMHomeUIControllerKindMain) {
        AMHomeUIFindBestHostInView(window, window, [NSMutableSet set], 0,
                                   &bestController, &bestHostView, &bestKind);
    }
    if (bestKind != AMHomeUIControllerKindMain) {
        AMHomeUIClearEmbeddedAttachment();
        return AMHomeUIControllerKindNone;
    }
    return AMHomeUIAttachToHost(bestController, bestHostView)
        ? bestKind : AMHomeUIControllerKindNone;
}

static void AMHomeUIAttachAttempt(NSUInteger attempt) {
    if (UIApplication.sharedApplication.applicationState !=
            UIApplicationStateActive) {
        AMHomeUIAttachLoopRunning = NO;
        return;
    }
    @try {
        AMHomeUIControllerKind attachedKind = AMHomeUIAttach();
        AMHomeUIApplyBrandLogoEverywhere();
        if (attempt == 60) {
            NSLog(@"[AMHomeUI] MainVC.containerView not ready; continuing low-frequency discovery");
        }
        NSTimeInterval retryDelay = attachedKind == AMHomeUIControllerKindMain
            ? 1.0 : (attempt < 60 ? 0.25 : 2.0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(retryDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AMHomeUIAttachAttempt(attempt + 1);
        });
    } @catch (NSException *exception) {
        AMHomeUIAttachLoopRunning = NO;
        NSLog(@"[AMHomeUI] attach attempt failed: %@ %@", exception.name,
              exception.reason ?: @"");
        return;
    }
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
        UIViewController *bestController = nil;
        UIView *bestHostView = nil;
        AMHomeUIControllerKind bestKind = AMHomeUIControllerKindNone;
        AMHomeUIFindBestHost(root, window, [NSMutableSet set], 0,
                            &bestController, &bestHostView, &bestKind);
        avatarHost = bestController ?: AMHomeUIFindMainController(
            root, [NSMutableSet set], 0);
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
        AMHomeUIInstallSettingsDrawerTrim();
        AMHomeUIScheduleAttachAttempts();
        AMHomeUIApplyBrandLogoEverywhere();
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

// MARK: - Brand logo (猫鹤AM)

// The native home header shows Alight Motion's wordmark from the asset
// catalog. Replace every image view that uses one of those assets with a
// locally rendered 猫鹤AM wordmark in the requested Miku-green / Tianyi-blue
// gradient, rendered at the original image's pixel size so the existing
// layout keeps its geometry.
static NSString * const AMHomeUIBrandText = @"猫鹤AM";

static void *AMHomeUIBrandReplacedKey = &AMHomeUIBrandReplacedKey;

// The wordmark has no public asset name at runtime, so candidates are found by
// shape: a wide, short image in the upper part of the screen, horizontally
// centered (the home header sits between the menu button and the avatar).
static BOOL AMHomeUIIsBrandLogoCandidate(UIImageView *imageView, UIWindow *window) {
    UIImage *image = imageView.image;
    if (!image || image.size.height < 12 || image.size.height > 60) return NO;
    if (image.size.width < image.size.height * 2.5) return NO;
    CGRect frameInWindow = [imageView convertRect:imageView.bounds toView:window];
    if (CGRectIsNull(frameInWindow) ||
        CGRectGetMaxY(frameInWindow) > 140) return NO;
    CGFloat centerX = CGRectGetMidX(frameInWindow);
    if (fabs(centerX - window.bounds.size.width / 2.0) >
        window.bounds.size.width * 0.2) return NO;
    return YES;
}

// The brand fonts ship inside the app bundle (Payload/AlightMotion.app) and
// are registered into the process scope on first use; UIFont is then created
// from each font's internal PostScript name, never from the file name.
static BOOL AMHomeUIBrandFontsRegistered = NO;
static NSString * const AMHomeUIBrandChineseFontName = @"luoliti";
static NSString * const AMHomeUIBrandLatinFontName = @"Cat";

static void AMHomeUIRegisterBrandFonts(void) {
    if (AMHomeUIBrandFontsRegistered) return;
    AMHomeUIBrandFontsRegistered = YES;
    for (NSString *resource in (@[ @"CatBrand-AM.otf", @"LoliCN.ttf" ])) {
        NSURL *fontURL = [NSBundle.mainBundle URLForResource:
            [resource stringByDeletingPathExtension]
            withExtension:resource.pathExtension];
        if (!fontURL) {
            NSLog(@"[AMHomeUI] brand font missing from bundle: %@", resource);
            continue;
        }
        CFErrorRef registrationError = NULL;
        BOOL registered = CTFontManagerRegisterFontsForURL(
            (__bridge CFURLRef)fontURL, kCTFontManagerScopeProcess,
            &registrationError);
        NSLog(@"[AMHomeUI] brand font %@ registered=%d", resource, registered);
    }
}

static UIImage *AMHomeUIBrandLogoImageForSize(CGSize size, CGFloat scale) {
    AMHomeUIRegisterBrandFonts();
    CGFloat pixelWidth = MAX(size.width * scale, 1.0);
    CGFloat pixelHeight = MAX(size.height * scale, 1.0);
    // The rendered wordmark is 15-20% smaller than the original asset's box.
    CGFloat textHeight = pixelHeight * 0.44;
    UIFont *chineseFont = [UIFont fontWithName:AMHomeUIBrandChineseFontName
                                          size:textHeight]
        ?: [UIFont fontWithName:@"PingFangSC-Semibold" size:textHeight]
        ?: [UIFont systemFontOfSize:textHeight weight:UIFontWeightSemibold];
    UIFont *latinFont = [UIFont fontWithName:AMHomeUIBrandLatinFontName
                                        size:textHeight * 1.02]
        ?: [UIFont systemFontOfSize:textHeight * 1.02 weight:UIFontWeightBold];
    UIColor *chineseColor = [UIColor colorWithRed:0x39 / 255.0
                                            green:0xC5 / 255.0
                                             blue:0xBB / 255.0 alpha:1.0];
    UIColor *latinColor = [UIColor colorWithRed:0x66 / 255.0
                                           green:0xCC / 255.0
                                            blue:0xFF / 255.0 alpha:1.0];
    NSDictionary *chineseAttributes = @{ NSFontAttributeName: chineseFont,
        NSForegroundColorAttributeName: chineseColor };
    NSDictionary *latinAttributes = @{ NSFontAttributeName: latinFont,
        NSForegroundColorAttributeName: latinColor };
    CGSize chineseSize = [@"猫鹤" sizeWithAttributes:chineseAttributes];
    CGSize latinSize = [@"AM" sizeWithAttributes:latinAttributes];
    CGFloat textWidth = chineseSize.width + latinSize.width * 0.92;
    if (textWidth <= 0 || textHeight <= 0) return nil;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.scale = 1.0;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(pixelWidth, pixelHeight)
                                              format:format];
    return [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *renderContext) {
            (void)renderContext;
            // Baseline-align both runs; the renderer context is top-left.
            CGFloat baseline = MAX(chineseFont.ascender, latinFont.ascender);
            [@"猫鹤" drawAtPoint:CGPointMake((pixelWidth - textWidth) / 2.0,
                                           baseline - chineseFont.ascender)
                withAttributes:chineseAttributes];
            [@"AM" drawAtPoint:CGPointMake((pixelWidth - textWidth) / 2.0 +
                                           chineseSize.width,
                                           baseline - latinFont.ascender)
                withAttributes:latinAttributes];
        }];
}

static void AMHomeUIApplyBrandLogoInView(UIView *view, NSMutableArray<UIImageView *> *pending) {
    if ([view isKindOfClass:UIImageView.class] &&
        ![objc_getAssociatedObject(view, AMHomeUIBrandReplacedKey) boolValue]) {
        [pending addObject:(UIImageView *)view];
    }
    for (UIView *subview in view.subviews) {
        AMHomeUIApplyBrandLogoInView(subview, pending);
    }
}

static void AMHomeUIApplyBrandLogoEverywhere(void) {
    UIWindow *window = AMHomeUIKeyWindow();
    if (!window) return;
    NSMutableArray<UIImageView *> *pending = [NSMutableArray array];
    AMHomeUIApplyBrandLogoInView(window, pending);
    for (UIImageView *imageView in pending) {
        if (!AMHomeUIIsBrandLogoCandidate(imageView, window)) continue;
        CGSize targetSize = imageView.image.size;
        if (targetSize.width <= 1 || targetSize.height <= 1) {
            targetSize = imageView.bounds.size;
        }
        CGFloat scale = imageView.image.scale > 0 ? imageView.image.scale
                                                  : UIScreen.mainScreen.scale;
        UIImage *brandLogo = AMHomeUIBrandLogoImageForSize(targetSize, scale);
        if (!brandLogo) continue;
        imageView.image = [brandLogo
            imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        imageView.tintColor = nil;
        objc_setAssociatedObject(imageView, AMHomeUIBrandReplacedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSLog(@"[AMHomeUI] replaced the header wordmark with 猫鹤AM");
    }
}

// MARK: - Settings drawer: hide every group below 关于

// r29 只匹配 UILabel.text 且日志被系统 redact 成 <private>，trim 落空后无从
// 判断。这一版：文本源覆盖 text/attributedText/按钮标题/accessibilityLabel，
// 目标串运行时取自 help_center/follow_us/open_source_libraries 键；日志一律
// %{public}@；三个下方卡片额外直接隐藏顶层祖先，找不到任何目标时对
// containerView 和 key window 做一次性全树 dump，下一轮日志必有真相。
static void *AMHomeUIDrawerTrimmedKey = &AMHomeUIDrawerTrimmedKey;

static UIView *AMHomeUIDrawerContainerView(UIViewController *controller) {
    if (!controller) return nil;
    id value = [controller valueForKey:@"containerView"];
    return [value isKindOfClass:UIView.class] ? value : nil;
}

static NSString *AMHomeUIDrawerTextOfView(UIView *view) {
    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        text = label.text;
        if (!text.length && label.attributedText.length) {
            text = label.attributedText.string;
        }
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        text = [button titleForState:UIControlStateNormal];
        if (!text.length && button.currentAttributedTitle.length) {
            text = button.currentAttributedTitle.string;
        }
    }
    if (!text.length) text = view.accessibilityLabel;
    return [text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static NSString *AMHomeUILocalizedOrLiteral(NSString *key, NSString *literal) {
    NSString *value = NSLocalizedString(key, @"");
    if (!value.length || [value isEqualToString:key]) return literal;
    return [value stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void AMHomeUIFindTextNodes(UIView *view, NSUInteger depth,
    NSArray<NSString *> *targets,
    NSMutableDictionary<NSString *, NSMutableArray<UIView *> *> *found) {
    if (!view || depth > 16) return;
    NSString *text = AMHomeUIDrawerTextOfView(view);
    if (text.length) {
        for (NSString *target in targets) {
            if ([text isEqualToString:target]) {
                [found[target] addObject:view];
                break;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        AMHomeUIFindTextNodes(subview, depth + 1, targets, found);
    }
}

// 沿节点的祖先链逐层向下裁剪：每一层都隐藏位于该节点之后的兄弟视图。
// 抽屉的行嵌在表格/堆栈等深层容器里，仅裁剪顶层容器的直接子视图会漏掉
// 全部行；逐层处理对任意嵌套结构都生效。
static void AMHomeUIDrawerTrimBelowNode(UIView *node, UIView *root,
                                        NSMutableArray<NSString *> *log) {
    UIView *current = node;
    while (current && current.superview && current != root) {
        UIView *parent = current.superview;
        CGFloat cutY = CGRectGetMinY(current.frame) + 2.0;
        for (UIView *sibling in [parent.subviews copy]) {
            if (sibling == current || sibling.hidden) continue;
            if (CGRectGetMinY(sibling.frame) >= cutY) {
                sibling.hidden = YES;
                [log addObject:[NSString stringWithFormat:@"below:%@ y=%.0f",
                    NSStringFromClass(sibling.class),
                    CGRectGetMinY(sibling.frame)]];
            }
        }
        if (parent == root) break;
        current = parent;
    }
}

// 直接隐藏包含该节点的顶层卡片（containerView 的直接子视图）。逐层裁剪
// 依赖 frame 顺序，这里不依赖——只要节点存在，整张卡片必然消失。
static void AMHomeUIHideTopLevelAncestor(UIView *node, UIView *root,
                                         NSMutableArray<NSString *> *log) {
    UIView *current = node;
    while (current && current.superview && current.superview != root) {
        current = current.superview;
    }
    if (current && current.superview == root && !current.hidden) {
        current.hidden = YES;
        [log addObject:[NSString stringWithFormat:@"topcard:%@ y=%.0f",
            NSStringFromClass(current.class),
            CGRectGetMinY(current.frame)]];
    }
}

static void AMHomeUIDumpViewTreeInto(UIView *view, NSUInteger depth,
                                     NSMutableString *dump,
                                     NSUInteger *visited) {
    if (!view || *visited >= 220) return;
    (*visited)++;
    [dump appendFormat:@"%@%@ %@ %@ text=%@\n",
        [@"" stringByPaddingToLength:MIN(depth, 14) * 2
                         withString:@" " startingAtIndex:0],
        NSStringFromClass(view.class),
        NSStringFromCGRect(view.frame),
        view.hidden ? @"HIDDEN" : @"shown",
        AMHomeUIDrawerTextOfView(view)];
    for (UIView *subview in view.subviews) {
        AMHomeUIDumpViewTreeInto(subview, depth + 1, dump, visited);
    }
}

// syslog 会把动态 NSLog 参数一律 redact 成 <private>，而新 clang 又禁止在
// NSLog 上用 %{public}@——所以诊断 dump 走 os_log，并把长输出按 ~16 节点
// 分块，避免超长行被 syslogd 截断。
static void AMHomeUIDumpViewTree(UIView *root, NSString *tag) {
    if (!root) return;
    NSMutableString *dump = [NSMutableString stringWithFormat:
        @"%@ root=%@ frame=%@\n", tag, NSStringFromClass(root.class),
        NSStringFromCGRect(root.frame)];
    NSUInteger visited = 0;
    AMHomeUIDumpViewTreeInto(root, 0, dump, &visited);
    NSRange remaining = NSMakeRange(0, dump.length);
    NSUInteger chunkIndex = 0;
    while (remaining.length) {
        NSUInteger scan = MIN(remaining.length, (NSUInteger)900);
        NSRange lineRange = [dump lineRangeForRange:
            NSMakeRange(remaining.location, scan)];
        NSUInteger take = NSMaxRange(lineRange) - remaining.location;
        if (take > remaining.length) take = remaining.length;
        os_log(OS_LOG_DEFAULT, "[AMHomeUI] drawer dump[%lu] %{public}@",
               (unsigned long)chunkIndex++,
               [dump substringWithRange:
                   NSMakeRange(remaining.location, take)]);
        remaining.location += take;
        remaining.length -= take;
    }
}

static void AMHomeUITrimDrawerNow(UIViewController *controller, NSString *source) {
    UIView *containerView = AMHomeUIDrawerContainerView(controller);
    if (!containerView) {
        os_log(OS_LOG_DEFAULT, "[AMHomeUI] drawer trim skipped (%{public}@): "
               "containerView not ready on %{public}@", source ?: @"",
               NSStringFromClass(controller.class) ?: @"");
        return;
    }
    NSString *aboutVal = AMHomeUILocalizedOrLiteral(@"about", @"关于");
    NSString *helpVal = AMHomeUILocalizedOrLiteral(@"help_center", @"获取支持");
    NSString *followVal = AMHomeUILocalizedOrLiteral(@"follow_us", @"关注我们");
    NSString *ossVal = AMHomeUILocalizedOrLiteral(@"open_source_libraries", @"开源库");
    NSArray<NSString *> *targets = @[aboutVal, helpVal, followVal, ossVal];
    NSMutableDictionary<NSString *, NSMutableArray<UIView *> *> *found =
        [NSMutableDictionary dictionary];
    for (NSString *target in targets) found[target] = [NSMutableArray array];
    AMHomeUIFindTextNodes(containerView, 0, targets, found);

    NSMutableArray<NSString *> *log = [NSMutableArray array];
    UIView *aboutNode = found[aboutVal].firstObject;
    if (aboutNode) AMHomeUIDrawerTrimBelowNode(aboutNode, containerView, log);
    for (NSString *key in @[helpVal, followVal, ossVal]) {
        for (UIView *node in found[key]) {
            AMHomeUIHideTopLevelAncestor(node, containerView, log);
            AMHomeUIDrawerTrimBelowNode(node, containerView, log);
        }
    }
    os_log(OS_LOG_DEFAULT, "[AMHomeUI] drawer trim pass (%{public}@): "
           "about=%d help=%lu follow=%lu oss=%lu hidden %{public}@",
           source ?: @"", aboutNode != nil,
           (unsigned long)found[helpVal].count,
           (unsigned long)found[followVal].count,
           (unsigned long)found[ossVal].count, log);
    if (!aboutNode && !found[helpVal].count && !found[followVal].count &&
        !found[ossVal].count) {
        static dispatch_once_t dumpToken;
        dispatch_once(&dumpToken, ^{
            AMHomeUIDumpViewTree(containerView, @"containerView");
            AMHomeUIDumpViewTree(AMHomeUIKeyWindow(), @"keyWindow");
        });
    }
}

static void AMHomeUIScheduleDrawerTrim(UIViewController *controller) {
    UIView *containerView = AMHomeUIDrawerContainerView(controller);
    if (!containerView) {
        // viewDidLoad can run long before the drawer is first opened, and
        // the container is built lazily. Retry on a ladder so the first
        // actual open is covered; each attempt reports why it bailed.
        for (NSNumber *delay in @[@0.45, @1.0, @2.0, @4.0, @6.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if ([objc_getAssociatedObject(controller,
                        AMHomeUIDrawerTrimmedKey) boolValue]) return;
                UIView *liveContainer =
                    AMHomeUIDrawerContainerView(controller);
                if (!liveContainer) return;
                objc_setAssociatedObject(controller,
                    AMHomeUIDrawerTrimmedKey, @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                for (NSNumber *pass in @[@0.1, @0.5, @1.2]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(pass.doubleValue * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                        AMHomeUITrimDrawerNow(controller,
                            [NSString stringWithFormat:@"retry+%.1fs",
                                pass.doubleValue]);
                    });
                }
            });
        }
        return;
    }
    if ([objc_getAssociatedObject(controller, AMHomeUIDrawerTrimmedKey) boolValue]) {
        return;
    }
    objc_setAssociatedObject(controller, AMHomeUIDrawerTrimmedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSNumber *delay in @[@0.45, @1.0, @1.8, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *liveContainer = AMHomeUIDrawerContainerView(controller);
            if (!liveContainer || !liveContainer.window) return;
            AMHomeUITrimDrawerNow(controller,
                [NSString stringWithFormat:@"load+%.1fs", delay.doubleValue]);
        });
    }
}

static void (*orig_SettingsContainerViewDidAppear)(id, SEL, BOOL) = NULL;

static void hooked_SettingsContainerViewDidAppear(id self, SEL _cmd,
                                                  BOOL animated) {
    if (orig_SettingsContainerViewDidAppear) {
        orig_SettingsContainerViewDidAppear(self, _cmd, animated);
    }
    // The drawer is on screen and laid out here: trim immediately, then a
    // short ladder catches late-arriving rows.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMHomeUITrimDrawerNow((UIViewController *)self, @"appear");
        });
        return;
    }
    AMHomeUITrimDrawerNow((UIViewController *)self, @"appear");
    for (NSNumber *delay in @[@0.25, @0.7, @1.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AMHomeUITrimDrawerNow((UIViewController *)self,
                [NSString stringWithFormat:@"appear+%.1fs",
                    delay.doubleValue]);
        });
    }
}

static void (*orig_SettingsContainerViewDidLoad)(id, SEL) = NULL;

static void hooked_SettingsContainerViewDidLoad(id self, SEL _cmd) {
    if (orig_SettingsContainerViewDidLoad) {
        orig_SettingsContainerViewDidLoad(self, _cmd);
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMHomeUIScheduleDrawerTrim((UIViewController *)self);
        });
        return;
    }
    AMHomeUIScheduleDrawerTrim((UIViewController *)self);
}

static void AMHomeUIInstallSettingsDrawerTrim(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!AMHomeUIIsBuild865()) return;
        Class containerClass = objc_getClass(
            "_TtC12AlightMotion19SettingsContainerVC");
        if (!containerClass) {
            containerClass = objc_getClass("AlightMotion.SettingsContainerVC");
        }
        if (!containerClass) return;
        Method method = class_getInstanceMethod(containerClass,
            NSSelectorFromString(@"viewDidLoad"));
        if (!method) return;
        orig_SettingsContainerViewDidLoad = (void (*)(id, SEL))method_setImplementation(
            method, (IMP)hooked_SettingsContainerViewDidLoad);
        Method appearMethod = class_getInstanceMethod(containerClass,
            NSSelectorFromString(@"viewDidAppear:"));
        if (appearMethod) {
            orig_SettingsContainerViewDidAppear =
                (void (*)(id, SEL, BOOL))method_setImplementation(
                    appearMethod, (IMP)hooked_SettingsContainerViewDidAppear);
        }
        NSLog(@"[AMHomeUI] settings drawer trim installed");
    });
}

void AMHomeUIInstall(void) {
    NSLog(@"[AMHomeUI] linked install requested");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        AMHomeUIInstallSettingsDrawerTrim();
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

// Home UI is a standalone image. Its constructor is the only activation
// entrypoint, so Cloud cannot install the observers a second time.
__attribute__((constructor))
static void AMHomeUIInitialize(void) {
    @autoreleasepool {
        AMHomeUIInstall();
    }
}
