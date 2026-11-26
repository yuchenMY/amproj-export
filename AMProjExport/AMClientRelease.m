// 猫鹤 AM · 版本策略、更新入口和用户工程迁移备份。
#import "AMClientRelease.h"
#import "AMClientReleasePolicy.h"
#import "AMAppUpdate.h"
#import "AMProjZIPWriter.h"
#import <QuartzCore/QuartzCore.h>
#ifndef AMPROJ_RELEASE_CODE
#define AMPROJ_RELEASE_CODE 176
#endif
#ifndef AMPROJ_CLIENT_BUILD_ID
#define AMPROJ_CLIENT_BUILD_ID "unknown"
#endif
#define AMCLIENT_STRING_VALUE(x) #x
#define AMCLIENT_STRING(x) AMCLIENT_STRING_VALUE(x)
#if AMPROJ_BETA_DIAGNOSTICS
#define AMCLIENT_CHANNEL "beta"
#else
#define AMCLIENT_CHANNEL "stable"
#endif
__attribute__((used, visibility("default"))) const char AMProjClientReleaseIdentity[] =
    "AMCLIENT_RELEASE:" AMCLIENT_STRING(AMPROJ_RELEASE_CODE) ":" AMCLIENT_CHANNEL ":" AMPROJ_CLIENT_BUILD_ID;
static NSString *AMReleaseChannel(void) { return @AMCLIENT_CHANNEL; }
static NSURL *AMReleaseCacheURL(void) {
    NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[root URLByAppendingPathComponent:@"AMClientRelease" isDirectory:YES] URLByAppendingPathComponent:@"policy.plist"];
}
static UIViewController *AMReleaseTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *item in ((UIWindowScene *)scene).windows)
            if (item.isKeyWindow && item.windowLevel == UIWindowLevelNormal) { window = item; break; }
    }
    UIViewController *top = window.rootViewController;
    for (NSUInteger depth = 0; top && depth < 24; depth++) {
        UIViewController *next = top.presentedViewController;
        if (!next && [top isKindOfClass:UINavigationController.class]) next = ((UINavigationController *)top).visibleViewController;
        if (!next && [top isKindOfClass:UITabBarController.class]) next = ((UITabBarController *)top).selectedViewController;
        // Build 865 embeds its browsing tabs in MainVC rather than making them the root.
        NSString *name = NSStringFromClass(top.class);
        if (!next && ([name isEqual:@"MainVC"] || [name hasSuffix:@".MainVC"] ||
            [name isEqual:@"_TtC12AlightMotion6MainVC"])) {
            @try {
                id tab = [top valueForKey:@"embedTBC"];
                if ([tab isKindOfClass:UITabBarController.class]) next = tab;
                else if ([tab isKindOfClass:UIViewController.class]) {
                    id selected = ((UIViewController *)tab).presentedViewController ?: [tab valueForKey:@"selectedViewController"];
                    if ([selected isKindOfClass:UIViewController.class]) next = selected;
                }
            } @catch (__unused NSException *exception) { next = nil; }
        }
        // SwiftUI's NodeHosting root embeds the native navigation container as a child.
        if (!next) for (UIViewController *child in top.childViewControllers) {
            if (([child isKindOfClass:UINavigationController.class] || [child isKindOfClass:UITabBarController.class]) &&
                child.viewIfLoaded.window && !child.viewIfLoaded.hidden && child.viewIfLoaded.alpha > 0.01) {
                next = child; break;
            }
        }
        if (!next || next == top) break;
        top = next;
    }
    return top;
}
static BOOL AMReleaseVisibleModalInTree(UIViewController *controller, NSUInteger depth, NSUInteger *remaining) {
    if (!controller.viewIfLoaded.window || controller.viewIfLoaded.hidden || controller.viewIfLoaded.alpha <= 0.01) return NO;
    if (depth > 16 || !*remaining) return YES;
    (*remaining)--;
    if (AMClientReleaseProtectedPresenter(NSStringFromClass(controller.class)) || controller.presentedViewController) return YES;
    for (UIViewController *child in controller.childViewControllers)
        if (AMReleaseVisibleModalInTree(child, depth + 1, remaining)) return YES;
    return NO;
}
static BOOL AMReleaseVisibleBrowsingView(UIView *view, NSUInteger depth, NSUInteger *remaining, BOOL customOnly) {
    if (!view.window || view.hidden || view.alpha <= 0.01 || depth > 18 || !*remaining) return NO;
    (*remaining)--;
    BOOL homepage = !customOnly && AMClientReleaseBrowsingViewClass(NSStringFromClass(view.class));
    BOOL customHome = [NSStringFromClass(view.nextResponder.class) isEqual:@"AMHomeUIController"];
    if ((homepage || customHome) && view.bounds.size.width > 80 && view.bounds.size.height > 80) {
        BOOL exposed = YES;
        // Native 865 home views extend beneath the persistent bottom tab bar.
        for (NSNumber *fraction in @[@0.2,@0.45,@0.7]) {
            CGPoint local = CGPointMake(view.bounds.origin.x + view.bounds.size.width * 0.5,
                view.bounds.origin.y + view.bounds.size.height * fraction.doubleValue);
            UIView *hit = [view.window hitTest:[view convertPoint:local toView:view.window] withEvent:nil];
            if (!hit || !(hit == view || [hit isDescendantOfView:view])) { exposed = NO; break; }
        }
        if (exposed) return YES;
    }
    for (UIView *child in view.subviews)
        if (AMReleaseVisibleBrowsingView(child, depth + 1, remaining, customOnly)) return YES;
    return NO;
}
static BOOL AMReleaseControllerIsBrowsing(UIViewController *controller) {
    if (!controller.viewIfLoaded.window || controller.viewIfLoaded.hidden || controller.viewIfLoaded.alpha <= 0.01) return NO;
    NSUInteger remaining = 128;
    if (AMReleaseVisibleModalInTree(controller, 0, &remaining)) return NO;
    if (AMClientReleaseSafePresenter(NSStringFromClass(controller.class))) return YES;
    remaining = 256;
    if (AMReleaseVisibleBrowsingView(controller.viewIfLoaded, 0, &remaining, NO)) return YES;
    // The custom home is a sibling of the selected native tab in MainVC's content view.
    UIViewController *parent = controller.parentViewController;
    for (NSUInteger depth = 0; parent && depth < 12; depth++, parent = parent.parentViewController) {
        remaining = 128;
        if (AMReleaseVisibleModalInTree(parent, 0, &remaining)) return NO;
        remaining = 256;
        if (AMReleaseVisibleBrowsingView(parent.viewIfLoaded, 0, &remaining, YES)) return YES;
    }
    return NO;
}
// 只收集原生 UUID 工程 XML 和项目素材目录，不导出账户、偏好或令牌。
static BOOL AMReleaseCollectBackup(NSURL *library, NSMutableDictionary **scenesOut,
                                  NSMutableDictionary **resourcesOut, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableDictionary *scenes = [NSMutableDictionary dictionary], *resources = [NSMutableDictionary dictionary];
    NSArray *roots = [files contentsOfDirectoryAtURL:library includingPropertiesForKeys:nil options:0 error:error];
    if (!roots) return NO;
    for (NSURL *file in roots) {
        if (![file.pathExtension.lowercaseString isEqual:@"xml"] ||
            ![[NSUUID alloc] initWithUUIDString:file.lastPathComponent.stringByDeletingPathExtension]) continue;
        NSDictionary *attributes = [files attributesOfItemAtPath:file.path error:error];
        if (!attributes || ![attributes[NSFileType] isEqual:NSFileTypeRegular]) return NO;
        NSData *data = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:error];
        if (!data.length) return NO;
        scenes[file.lastPathComponent] = data;
    }
    if (!scenes.count) {
        if (error) *error = [NSError errorWithDomain:@"AMClientRelease" code:1 userInfo:@{NSLocalizedDescriptionKey:@"本机没有可导出的工程"}];
        return NO;
    }
    NSURL *directory = [library URLByAppendingPathComponent:@"project-dependencies" isDirectory:YES];
    NSNumber *link = nil; [directory getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
    if (link.boolValue) return NO;
    if ([files fileExistsAtPath:directory.path]) {
        NSArray *entries = [files contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:error];
        if (!entries) return NO;
        for (NSURL *file in entries) {
            NSDictionary *attributes = [files attributesOfItemAtPath:file.path error:error];
            if (!attributes || ![attributes[NSFileType] isEqual:NSFileTypeRegular]) return NO;
            resources[file.lastPathComponent] = file;
        }
    }
    *scenesOut = scenes; *resourcesOut = resources;
    return YES;
}
@interface AMReleaseSceneReferences : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableSet<NSString *> *names;
@property(nonatomic, copy) NSString *title;
@end
@implementation AMReleaseSceneReferences
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary<NSString *,NSString *> *)attributes {
    (void)parser; (void)namespaceURI; (void)qualifiedName;
    if ([name isEqual:@"scene"] && !self.title) self.title = attributes[@"title"] ?: @"工程";
    for (NSString *value in attributes.allValues) {
        NSString *reference = nil;
        if ([value.lowercaseString hasPrefix:@"am-internal:///"]) reference = [value substringFromIndex:15];
        else if ([value.lowercaseString hasPrefix:@"amproj:"]) reference = [value substringFromIndex:7];
        if (reference.length) [self.names addObject:reference];
    }
}
@end
static NSArray<NSURL *> *AMReleaseWriteBackup(NSURL *directory, NSDictionary *scenes,
                                             NSDictionary *resources, NSError **error) {
    NSMutableArray *outputs = [NSMutableArray array];
    for (NSString *name in [scenes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        AMReleaseSceneReferences *references = [AMReleaseSceneReferences new];
        references.names = [NSMutableSet set];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:scenes[name]];
        parser.shouldResolveExternalEntities = NO; parser.delegate = references;
        if (![parser parse]) { if (error) *error = parser.parserError; return nil; }
        NSMutableDictionary *included = [NSMutableDictionary dictionary];
        for (NSString *resource in references.names) {
            if (!resources[resource]) {
                if (error) *error = [NSError errorWithDomain:@"AMClientRelease" code:2 userInfo:@{
                    NSLocalizedDescriptionKey:@"工程有未找到的本地素材，备份未完成。请保留 Beta，先在工程中补全素材。"}];
                return nil;
            }
            included[resource] = resources[resource];
        }
        NSString *title = references.title ?: @"工程";
        title = [[title componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:\n\r"]] componentsJoinedByString:@"-"];
        if (title.length > 60) title = [title substringToIndex:60];
        NSString *filename = [NSString stringWithFormat:@"%@-%@.amproj",title,name.stringByDeletingPathExtension];
        NSURL *output = [directory URLByAppendingPathComponent:filename];
        if (!AMProjZIPWriteProjectArchiveFiles(output, @{name:scenes[name]}, included, nil, error)) return nil;
        [outputs addObject:output];
    }
    return outputs;
}
@class AMReleaseManager;
@interface AMReleaseController : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, weak) AMReleaseManager *manager;
@property(nonatomic, strong) UILabel *messageLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) UIButton *updateButton;
@property(nonatomic, strong) UIButton *backupButton;
@property(nonatomic) BOOL backupBusy;
@property(nonatomic, strong) NSURL *backupDirectory;
@property(nonatomic) NSUInteger backupCount;
- (void)updateContent;
@end
@interface AMReleaseManager : NSObject
@property(nonatomic, strong) NSDictionary *policy;
@property(nonatomic) NSTimeInterval policyReceivedAt;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic) BOOL checking;
@property(nonatomic) NSTimeInterval lastCheck;
@property(nonatomic, strong) AMReleaseController *gate;
@property(nonatomic) NSUInteger presentationRetries;
@property(nonatomic) BOOL presentationRetryScheduled;
@property(nonatomic) NSTimeInterval lastPresentationAttempt;
@property(nonatomic, copy) NSString *lastPresentationState;
+ (instancetype)shared;
- (void)check:(BOOL)force;
- (void)present;
- (void)accept:(NSDictionary *)policy;
- (BOOL)blocked;
- (void)recordPresentation:(NSString *)phase top:(UIViewController *)top;
@end
@implementation AMReleaseManager
+ (instancetype)shared {
    static AMReleaseManager *manager;
    static dispatch_once_t once; dispatch_once(&once, ^{
        manager = [self new];
        NSTimeInterval receivedAt = 0;
        manager.policy = AMClientReleaseLoadCache(AMReleaseCacheURL(), AMReleaseChannel(), &receivedAt);
        manager.policyReceivedAt = receivedAt;
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        manager.session = [NSURLSession sessionWithConfiguration:config];
    }); return manager;
}
- (BOOL)blocked {
    NSTimeInterval elapsed = MAX(0, NSDate.date.timeIntervalSince1970 - self.policyReceivedAt);
    return AMClientReleasePolicyBlocked(self.policy, AMPROJ_RELEASE_CODE, [self.policy[@"serverNow"] doubleValue] + elapsed);
}
- (void)accept:(NSDictionary *)policy {
    NSDictionary *valid = AMClientReleaseValidatedPolicy(policy, AMReleaseChannel());
    if (!valid || [valid[@"revision"] longLongValue] < [self.policy[@"revision"] longLongValue]) return;
    self.policy = valid; self.policyReceivedAt = NSDate.date.timeIntervalSince1970;
    AMClientReleaseSaveCache(AMReleaseCacheURL(), valid, self.policyReceivedAt);
    [self present];
}
- (void)check:(BOOL)force {
    self.presentationRetries = 0;
    [self present];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (self.checking || (!force && now - self.lastCheck < 60)) return;
    self.lastCheck = now; self.checking = YES;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://am.meowcr.cn/api/ios/client-release"]];
    AMClientReleaseAddHeaders(request);
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *envelope = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checking = NO;
            if (!error && status == 200 && [envelope isKindOfClass:NSDictionary.class] && [envelope[@"code"] isEqual:@0] &&
                AMClientReleaseValidatedPolicy(envelope[@"data"], AMReleaseChannel())) {
                [self accept:envelope[@"data"]]; self.gate.statusLabel.text = @"版本状态已更新";
            } else self.gate.statusLabel.text = @"暂时无法读取版本状态，请检查网络后重试";
        });
    }] resume];
}
- (void)present {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    BOOL blocked = [self blocked];
    if (self.gate.presentingViewController) {
        [self.gate updateContent];
        if (!blocked && !self.gate.backupBusy && !self.gate.presentedViewController) {
            AMReleaseController *gate = self.gate; self.gate = nil;
            [gate dismissViewControllerAnimated:NO completion:nil];
        }
        return;
    }
    if (!self.policy || ![self.policy[@"enabled"] boolValue]) { [self recordPresentation:@"inactive" top:nil]; return; }
    if (!blocked && [self.policy[@"latestRelease"] integerValue] <= AMPROJ_RELEASE_CODE) {
        [self recordPresentation:@"up_to_date" top:nil]; return;
    }
    UIViewController *top = AMReleaseTopController();
    BOOL browsing = AMReleaseControllerIsBrowsing(top);
    if (!browsing || !top.viewIfLoaded.window || top.presentedViewController || top.transitionCoordinator ||
        top.isBeingPresented || top.isBeingDismissed || [top isKindOfClass:UIAlertController.class]) {
        [self recordPresentation:browsing ? @"waiting_transition" : @"waiting_browsing_page" top:top];
        if (blocked && !self.presentationRetryScheduled && self.presentationRetries < 10) {
            self.presentationRetries++; self.presentationRetryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                self.presentationRetryScheduled = NO; [self present];
            });
        }
        return;
    }
    self.presentationRetries = 0;
    if (blocked) {
        self.gate = [AMReleaseController new]; self.gate.manager = self;
        self.gate.modalPresentationStyle = UIModalPresentationOverFullScreen; self.gate.modalInPresentation = YES;
        [self recordPresentation:@"presenting_dialog" top:top];
        [top presentViewController:self.gate animated:NO completion:^{ [self recordPresentation:@"dialog_visible" top:top]; }];
    } else if ([self.policy[@"latestRelease"] integerValue] > AMPROJ_RELEASE_CODE) {
        NSString *key = [NSString stringWithFormat:@"AMReleaseNotice-%@-%@-%@",AMReleaseChannel(),self.policy[@"latestRelease"],self.policy[@"revision"]];
        if (NSDate.date.timeIntervalSince1970 - [NSUserDefaults.standardUserDefaults doubleForKey:key] < 86400) return;
        [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970 forKey:key];
        UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"有新版本可更新" message:self.policy[@"message"] preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
        NSString *download = self.policy[@"downloadURL"];
        [notice addAction:[UIAlertAction actionWithTitle:@"前往更新" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [top dismissViewControllerAnimated:YES completion:^{
                AMAppUpdatePresent(top, [NSURL URLWithString:download], [self.policy[@"retired"] boolValue]);
            }];
        }]];
        [top presentViewController:notice animated:YES completion:nil];
    }
}
- (void)recordPresentation:(NSString *)phase top:(UIViewController *)top {
    NSString *name = top ? NSStringFromClass(top.class) : @"";
    NSString *key = [NSString stringWithFormat:@"%@/%@/%@",phase,name,self.policy[@"revision"]];
    if ([key isEqual:self.lastPresentationState]) return;
    self.lastPresentationState = key;
    NSURL *url = [AMReleaseCacheURL().URLByDeletingLastPathComponent URLByAppendingPathComponent:@"presentation.plist"];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"phase":phase,@"top":name,@"viewClass":top.viewIfLoaded ? NSStringFromClass(top.viewIfLoaded.class) : @"",
        @"revision":self.policy[@"revision"] ?: @0,
        @"release":@(AMPROJ_RELEASE_CODE),@"channel":AMReleaseChannel(),@"time":@(NSDate.date.timeIntervalSince1970)} writeToURL:url atomically:YES];
}
@end
@implementation AMReleaseController
- (UIButton *)button:(NSString *)title action:(SEL)selector primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:primary ? 16 : 14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.backgroundColor = primary ? [UIColor colorWithRed:0.125 green:0.133 blue:0.22 alpha:1] : UIColor.clearColor;
    [button setTitleColor:primary ? UIColor.whiteColor : [UIColor colorWithRed:0.36 green:0.38 blue:0.44 alpha:1] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:0.55 alpha:1] forState:UIControlStateDisabled];
    button.layer.cornerRadius = 14; [button.heightAnchor constraintGreaterThanOrEqualToConstant:primary ? 50 : 44].active = YES;
    button.contentEdgeInsets = UIEdgeInsetsMake(12, 10, 12, 10);
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside]; return button;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor colorWithRed:0.08 green:0.09 blue:0.14 alpha:0.32];
    UIView *card = [UIView new]; card.backgroundColor = UIColor.whiteColor;
    card.layer.cornerRadius = 26; card.clipsToBounds = YES; card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];
    UIColor *ink = [UIColor colorWithRed:0.125 green:0.133 blue:0.22 alpha:1];
    UIView *iconHost = [UIView new]; iconHost.backgroundColor = [UIColor colorWithRed:0.90 green:0.97 blue:0.95 alpha:1]; iconHost.layer.cornerRadius = 14;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.app" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightMedium]]];
    icon.tintColor = [UIColor colorWithRed:0.07 green:0.56 blue:0.51 alpha:1]; icon.translatesAutoresizingMaskIntoConstraints = NO;
    [iconHost addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[[iconHost.widthAnchor constraintEqualToConstant:48], [iconHost.heightAnchor constraintEqualToConstant:48], [icon.centerXAnchor constraintEqualToAnchor:iconHost.centerXAnchor], [icon.centerYAnchor constraintEqualToAnchor:iconHost.centerYAnchor]]];
    UILabel *title = [UILabel new]; title.text = @"请更新猫鹤 AM";
    title.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:20 weight:UIFontWeightBold]]; title.textColor = ink;
    title.numberOfLines = 0;
    self.versionLabel = [UILabel new]; self.versionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; self.versionLabel.textColor = UIColor.secondaryLabelColor; self.versionLabel.numberOfLines = 0;
    UIStackView *headings = [[UIStackView alloc] initWithArrangedSubviews:@[title,self.versionLabel]]; headings.axis = UILayoutConstraintAxisVertical; headings.spacing = 5;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[iconHost,headings]]; header.axis = UILayoutConstraintAxisHorizontal; header.alignment = UIStackViewAlignmentCenter; header.spacing = 14;
    self.messageLabel = [UILabel new]; self.messageLabel.numberOfLines = 0; self.messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.messageLabel.textColor = [UIColor colorWithRed:0.36 green:0.38 blue:0.44 alpha:1];
    self.hintLabel = [UILabel new]; self.hintLabel.numberOfLines = 0; self.hintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; self.hintLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel = [UILabel new]; self.statusLabel.numberOfLines = 0; self.statusLabel.textColor = UIColor.secondaryLabelColor; self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    for (UILabel *label in @[self.versionLabel,title,self.messageLabel,self.hintLabel,self.statusLabel]) {
        label.adjustsFontForContentSizeCategory = YES;
        [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    }
    self.updateButton = [self button:@"立即更新" action:@selector(update) primary:YES];
    self.backupButton = [self button:@"备份工程" action:@selector(backup) primary:NO]; self.backupButton.accessibilityLabel = @"导出本机工程备份";
    UIButton *retry = [self button:@"重新检查" action:@selector(retry) primary:NO]; retry.accessibilityLabel = @"重新检查版本";
    UIStackView *secondary = [[UIStackView alloc] initWithArrangedSubviews:@[self.backupButton,retry]]; secondary.axis = UILayoutConstraintAxisHorizontal; secondary.distribution = UIStackViewDistributionFillEqually; secondary.spacing = 8;
    UIView *line = [UIView new]; line.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1]; [line.heightAnchor constraintEqualToConstant:1].active = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header,self.messageLabel,self.hintLabel,self.updateButton,line,secondary,self.statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16; [stack setCustomSpacing:4 afterView:line]; [stack setCustomSpacing:4 afterView:secondary]; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:scroll]; [scroll addSubview:stack];
    NSLayoutConstraint *naturalHeight = [scroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:48];
    naturalHeight.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *preferredWidth = [card.widthAnchor constraintEqualToConstant:332];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor], preferredWidth,
        [card.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48],
        [card.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [card.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [scroll.topAnchor constraintEqualToAnchor:card.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor], naturalHeight,
        [scroll.contentLayoutGuide.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-24]]];
    [self updateContent];
}
- (void)updateContent {
    BOOL retired = [self.manager.policy[@"retired"] boolValue];
    NSString *message = self.manager.policy[@"message"];
    self.messageLabel.text = message.length ? message : @"当前版本已停止支持，请更新后继续使用。";
    self.hintLabel.text = retired ? @"请先备份工程，导入正式版并检查后再删除 Beta。" : @"请保留原应用，覆盖安装可保留本机工程。";
    NSInteger target = MAX([self.manager.policy[@"latestRelease"] integerValue], [self.manager.policy[@"minimumRelease"] integerValue]);
    self.versionLabel.text = target > AMPROJ_RELEASE_CODE ? [NSString stringWithFormat:@"r%d → r%ld · %@",AMPROJ_RELEASE_CODE,(long)target,[AMReleaseChannel() isEqual:@"beta"] ? @"Beta 测试版" : @"正式版"] : [NSString stringWithFormat:@"r%d · %@",AMPROJ_RELEASE_CODE,[AMReleaseChannel() isEqual:@"beta"] ? @"Beta 测试版" : @"正式版"];
    [self.updateButton setTitle:retired ? @"前往安装正式版" : @"立即更新" forState:UIControlStateNormal];
}
- (void)update { AMAppUpdatePresent(self, [NSURL URLWithString:self.manager.policy[@"downloadURL"]], [self.manager.policy[@"retired"] boolValue]); }
- (void)retry { self.statusLabel.text = @"正在检查版本…"; [self.manager check:YES]; }
- (void)backup {
    if (self.backupBusy) return;
    self.backupBusy = YES; self.backupButton.enabled = NO; self.updateButton.enabled = NO;
    self.statusLabel.text = @"正在生成本机工程和本地素材备份。外部链接素材不包含在内，请勿退出应用。";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil; NSMutableDictionary *scenes = nil, *resources = nil;
        NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
        BOOL ready = AMReleaseCollectBackup(library, &scenes, &resources, &error);
        NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"AMReleaseBackup-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSArray *outputs = nil;
        if (ready && [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:NO attributes:nil error:&error])
            outputs = AMReleaseWriteBackup(directory, scenes, resources, &error);
        ready = outputs.count == scenes.count && outputs.count > 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ready) {
                [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                self.backupBusy = NO; self.backupButton.enabled = YES; self.updateButton.enabled = YES;
                self.statusLabel.text = error.localizedDescription ?: @"备份未完成，请保留原应用和工程后重试"; return;
            }
            self.backupDirectory = directory;
            self.backupCount = outputs.count;
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:outputs asCopy:YES];
            picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
        });
    });
}
- (void)finishBackup:(BOOL)saved {
    if (self.backupDirectory) [NSFileManager.defaultManager removeItemAtURL:self.backupDirectory error:nil];
    self.backupDirectory = nil; self.backupBusy = NO; self.backupButton.enabled = YES; self.updateButton.enabled = YES;
    self.statusLabel.text = saved ? ([self.manager.policy[@"retired"] boolValue] ? @"工程已分别导出。请在正式版逐个导入并检查后，再删除 Beta。" : @"工程备份已导出，请保留原应用并覆盖安装更新。") : @"备份未全部确认保存，请保留原应用和工程。";
    [self.manager present];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls { (void)controller; [self finishBackup:urls.count == self.backupCount && urls.count > 0]; }
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; [self finishBackup:NO]; }
@end
void AMClientReleaseAddHeaders(NSMutableURLRequest *request) {
    [request setValue:@"ios" forHTTPHeaderField:@"X-AM-Platform"];
    [request setValue:[NSString stringWithFormat:@"%d",AMPROJ_RELEASE_CODE] forHTTPHeaderField:@"X-AM-Release-Code"];
    [request setValue:AMReleaseChannel() forHTTPHeaderField:@"X-AM-Release-Channel"];
    [request setValue:@AMPROJ_CLIENT_BUILD_ID forHTTPHeaderField:@"X-AM-Release-Build"];
}
NSDictionary *AMClientReleaseIdentity(void) {
    return @{@"release":@(AMPROJ_RELEASE_CODE),@"channel":AMReleaseChannel(),@"build":@AMPROJ_CLIENT_BUILD_ID};
}
void AMClientReleaseHandleResponse(NSURLResponse *response, NSData *data) {
    if (![response isKindOfClass:NSHTTPURLResponse.class] || ((NSHTTPURLResponse *)response).statusCode != 426 || !data.length) return;
    id envelope = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![envelope isKindOfClass:NSDictionary.class] || ![envelope[@"data"] isKindOfClass:NSDictionary.class]) return;
    id policy = envelope[@"data"][@"clientReleasePolicy"];
    dispatch_async(dispatch_get_main_queue(), ^{ [[AMReleaseManager shared] accept:policy]; });
}
void AMClientReleasePresentIfNeeded(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AMReleaseManager *manager = [AMReleaseManager shared];
        NSTimeInterval now = CACurrentMediaTime();
        if (now - manager.lastPresentationAttempt < 0.5) return;
        manager.lastPresentationAttempt = now; [manager present];
    });
}
void AMClientReleaseBrowsingControllerVisible(UIViewController *controller) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!controller.viewIfLoaded.window || controller.presentedViewController) return;
        AMClientReleasePresentIfNeeded();
    });
}
void AMClientReleaseInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t once; dispatch_once(&once, ^{
            AMReleaseManager *manager = [AMReleaseManager shared];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { [manager check:NO]; }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { AMClientReleasePresentIfNeeded(); }];
            [manager check:NO];
        });
    });
}
