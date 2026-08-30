#import "AMProjV865ProjectFlow.h"

#import <dispatch/dispatch.h>
#import <objc/runtime.h>

static NSString *const AMProjV865Version = @"6.2.58";
static NSString *const AMProjV865Build = @"865";
static NSString *const AMProjV865DirectoryName = @"AMProjV865ProjectHandoff";
static NSString *const AMProjV865BreadcrumbFilename = @"last-handoff.plist";
static const void *AMProjV865BrokerKey = &AMProjV865BrokerKey;
static const unsigned long long AMProjV865MaximumDocumentBytes = 512ULL * 1024ULL * 1024ULL;

@interface AMProjV865ProjectFlowRequest ()
@property(nonatomic, readwrite, getter=isCancelled) BOOL cancelled;
@end

@implementation AMProjV865ProjectFlowRequest

@synthesize cancelled = _cancelled;

- (BOOL)isCancelled {
    @synchronized (self) {
        return _cancelled;
    }
}

- (void)cancel {
    @synchronized (self) {
        _cancelled = YES;
    }
}

@end

static NSError *AMProjV865StageError(NSInteger code, NSString *message);
typedef void (^AMProjV865RouteCompletion)(
    AMProjV865ProjectHandoffStatus status, NSError * _Nullable error);

static dispatch_queue_t AMProjV865StagingQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.amproj.865.project-staging",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static CGRect AMProjV865CenterAnchorRect(CGRect bounds) {
    return CGRectMake(CGRectGetMidX(bounds) - 0.5,
                       CGRectGetMidY(bounds) - 0.5, 1.0, 1.0);
}

static NSObject *AMProjV865HandoffLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static AMProjV865ProjectHandoffStatus amproj_v865LastHandoffStatus =
    AMProjV865ProjectHandoffStatusFailed;

static NSObject *AMProjV865RequestRegistryLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, AMProjV865ProjectFlowRequest *>
*AMProjV865RequestRegistry(void) {
    static NSMutableDictionary<NSString *, AMProjV865ProjectFlowRequest *> *requests;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ requests = [NSMutableDictionary dictionary]; });
    return requests;
}

static NSString *AMProjV865RequestKey(NSURL *URL) {
    if (!URL.isFileURL || !URL.path.length) return nil;
    return URL.URLByStandardizingPath.path;
}

static void AMProjV865RegisterRequest(NSURL *URL,
                                      AMProjV865ProjectFlowRequest *request) {
    NSString *key = AMProjV865RequestKey(URL);
    if (!key.length || !request) return;
    @synchronized (AMProjV865RequestRegistryLock()) {
        AMProjV865RequestRegistry()[key] = request;
    }
}

static void AMProjV865UnregisterRequest(NSURL *URL,
                                        AMProjV865ProjectFlowRequest *request) {
    NSString *key = AMProjV865RequestKey(URL);
    if (!key.length) return;
    @synchronized (AMProjV865RequestRegistryLock()) {
        AMProjV865ProjectFlowRequest *current = AMProjV865RequestRegistry()[key];
        if (!request || current == request) {
            [AMProjV865RequestRegistry() removeObjectForKey:key];
        }
    }
}

void AMProjV865ProjectFlowCancelDocument(NSURL *fileURL) {
    NSString *key = AMProjV865RequestKey(fileURL);
    if (!key.length) return;
    AMProjV865ProjectFlowRequest *request = nil;
    @synchronized (AMProjV865RequestRegistryLock()) {
        request = AMProjV865RequestRegistry()[key];
        [AMProjV865RequestRegistry() removeObjectForKey:key];
    }
    [request cancel];
}

NSString *AMProjV865ProjectFlowHandoffStatusString(
    AMProjV865ProjectHandoffStatus status) {
    switch (status) {
        case AMProjV865ProjectHandoffStatusStaged:
            return @"staged";
        case AMProjV865ProjectHandoffStatusRouteAccepted:
            return @"route_accepted";
        case AMProjV865ProjectHandoffStatusFallbackPresented:
            return @"fallback_presented";
        case AMProjV865ProjectHandoffStatusUnverified:
            return @"unverified";
        case AMProjV865ProjectHandoffStatusFailed:
        default:
            return @"failed";
    }
}

AMProjV865ProjectHandoffStatus AMProjV865ProjectFlowLastHandoffStatus(void) {
    @synchronized (AMProjV865HandoffLock()) {
        return amproj_v865LastHandoffStatus;
    }
}

BOOL AMProjV865ProjectFlowIsRuntimeSupported(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
        ? info[@"CFBundleShortVersionString"] : nil;
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class]
        ? info[@"CFBundleVersion"] : nil;
    return [version isEqualToString:AMProjV865Version] &&
        [build isEqualToString:AMProjV865Build];
}

static NSString *AMProjV865SafeFilename(NSString *filename) {
    NSString *value = filename.length ? filename.lastPathComponent : @"project.amproj";
    if (!value.length || [value isEqualToString:@"."] || [value isEqualToString:@".."]) {
        value = @"project.amproj";
    }
    NSString *extension = value.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"amproj"] && ![extension isEqualToString:@"xml"]) {
        value = [value.stringByDeletingPathExtension stringByAppendingPathExtension:@"amproj"];
    }
    if (value.length > 160) {
        value = [value substringToIndex:160];
        extension = value.pathExtension.lowercaseString;
        if (![extension isEqualToString:@"amproj"] && ![extension isEqualToString:@"xml"]) {
            value = [value.stringByDeletingPathExtension stringByAppendingPathExtension:@"amproj"];
        }
    }
    return value;
}

static NSURL *AMProjV865HandoffRoot(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:
        NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:AMProjV865DirectoryName
                                      isDirectory:YES];
}

static void AMProjV865WriteHandoffBreadcrumb(
    AMProjV865ProjectHandoffStatus status, NSURL *stagedURL,
    NSString *filename, NSString *reason, NSDictionary *extra) {
    NSString *statusString = AMProjV865ProjectFlowHandoffStatusString(status);
    NSMutableDictionary *record = [@{
        @"status": statusString,
        @"verified": @NO,
        @"version": AMProjV865Version,
        @"build": AMProjV865Build,
        @"timestamp": NSDate.date,
        @"filename": filename.length ? filename : @"project.amproj"
    } mutableCopy];
    if (stagedURL.path.length) record[@"staged_path"] = stagedURL.path;
    if (reason.length) record[@"reason"] = reason;
    if (extra.count) [record addEntriesFromDictionary:extra];

    @synchronized (AMProjV865HandoffLock()) {
        amproj_v865LastHandoffStatus = status;
        NSURL *root = AMProjV865HandoffRoot();
        NSFileManager *manager = NSFileManager.defaultManager;
        if (!root || ![manager createDirectoryAtURL:root
                         withIntermediateDirectories:YES attributes:nil error:nil]) {
            NSLog(@"[AMProjExport] 865 handoff breadcrumb unavailable: %@", statusString);
            return;
        }
        NSError *serializationError = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
        if (!data) {
            NSLog(@"[AMProjExport] 865 handoff breadcrumb serialization failed: %@",
                  serializationError.localizedDescription ?: @"unknown error");
            return;
        }
        NSURL *breadcrumbURL = [root URLByAppendingPathComponent:
            AMProjV865BreadcrumbFilename isDirectory:NO];
        NSError *writeError = nil;
        if (![data writeToURL:breadcrumbURL options:NSDataWritingAtomic error:&writeError]) {
            NSLog(@"[AMProjExport] 865 handoff breadcrumb write failed: %@",
                  writeError.localizedDescription ?: @"unknown error");
        }
        NSURL *directory = stagedURL.URLByDeletingLastPathComponent;
        if (directory && [manager fileExistsAtPath:directory.path]) {
            NSURL *handoffURL = [directory URLByAppendingPathComponent:@"handoff.plist"];
            [data writeToURL:handoffURL options:NSDataWritingAtomic error:nil];
        }
    }
    NSLog(@"[AMProjExport] 865 handoff status=%@ filename=%@%@",
          statusString, record[@"filename"],
          reason.length ? [NSString stringWithFormat:@" reason=%@", reason] : @"");
}

static void AMProjV865ScheduleDirectoryCleanup(NSURL *directory) {
    if (!directory) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 24 * 60 * 60 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    });
}

static UIViewController *AMProjV865TopController(UIViewController *controller) {
    UIViewController *current = controller;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    while (current) {
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)current];
        if ([visited containsObject:identity]) break;
        [visited addObject:identity];
        UIViewController *next = current.presentedViewController;
        if (!next && [current isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)current).visibleViewController;
        }
        if (!next && [current isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)current).selectedViewController;
        }
        if (!next) next = current.childViewControllers.lastObject;
        if (!next) break;
        current = next;
    }
    return current;
}

static UIViewController *AMProjV865ForegroundPresenter(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in scene.windows.reverseObjectEnumerator) {
                if (!window.hidden && window.alpha > 0.0 && window.rootViewController) {
                    UIViewController *top = AMProjV865TopController(window.rootViewController);
                    if (top.viewIfLoaded.window) return top;
                }
            }
        }
    }
    for (UIWindow *window in application.windows.reverseObjectEnumerator) {
        if (!window.hidden && window.alpha > 0.0 && window.rootViewController) {
            UIViewController *top = AMProjV865TopController(window.rootViewController);
            if (top.viewIfLoaded.window) return top;
        }
    }
    return nil;
}

static NSURL *AMProjV865CopyDocument(NSURL *source, NSString *filename,
                                     NSError **error) {
    if (!source.isFileURL || ![NSFileManager.defaultManager isReadableFileAtPath:source.path]) {
        if (error) *error = [NSError errorWithDomain:@"com.amproj.865.project-flow"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"The downloaded project is not readable"}];
        return nil;
    }
    NSNumber *size = nil;
    if (![source getResourceValue:&size forKey:NSURLFileSizeKey error:error] ||
        ![size isKindOfClass:NSNumber.class] ||
        size.unsignedLongLongValue == 0 ||
        size.unsignedLongLongValue > AMProjV865MaximumDocumentBytes) {
        if (error && !*error) *error = [NSError errorWithDomain:@"com.amproj.865.project-flow"
                                                               code:2
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                               @"The project document size is invalid"}];
        return nil;
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directory = nil;
    @try {
        NSURL *root = AMProjV865HandoffRoot();
        if (!root || ![manager createDirectoryAtURL:root withIntermediateDirectories:YES
                                          attributes:nil error:error]) return nil;
        directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                                          isDirectory:YES];
        if (![manager createDirectoryAtURL:directory withIntermediateDirectories:NO
                                  attributes:nil error:error]) return nil;
        [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

        NSString *safeName = AMProjV865SafeFilename(filename ?: source.lastPathComponent);
        NSURL *temporary = [directory URLByAppendingPathComponent:@"document.partial"];
        NSURL *destination = [directory URLByAppendingPathComponent:safeName];
        BOOL copied = [manager copyItemAtURL:source toURL:temporary error:error];
        if (!copied || ![manager moveItemAtURL:temporary toURL:destination error:error]) {
            [manager removeItemAtURL:directory error:nil];
            return nil;
        }
        [destination setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        return destination;
    } @catch (NSException *exception) {
        if (directory) [manager removeItemAtURL:directory error:nil];
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"com.amproj.865.project-flow"
                                          code:4
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"The project handoff raised an exception while copying",
                                                 @"exception": exception.name ?: @"unknown",
                                                 @"reason": exception.reason ?: @"unknown"}];
        }
        return nil;
    }
}

@interface AMProjV865DocumentBroker : NSObject <UIDocumentInteractionControllerDelegate>
@property(nonatomic, strong) UIDocumentInteractionController *controller;
@property(nonatomic, strong) NSURL *stagedURL;
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) NSURL *cleanupDirectory;
@property(nonatomic, strong) AMProjV865ProjectFlowRequest *request;
@property(nonatomic) BOOL nativeRouteInFlight;
@property(nonatomic) BOOL fallbackPresented;
- (void)scheduleCleanup;
@end

@implementation AMProjV865DocumentBroker

- (UIViewController *)documentInteractionControllerViewControllerForPreview:
    (UIDocumentInteractionController *)controller {
    return self.presenter ?: AMProjV865ForegroundPresenter();
}

- (UIView *)documentInteractionControllerViewForPreview:
    (UIDocumentInteractionController *)controller {
    return [self documentInteractionControllerViewControllerForPreview:controller].view;
}

- (CGRect)documentInteractionControllerRectForPreview:
    (UIDocumentInteractionController *)controller {
    UIView *view = [self documentInteractionControllerViewForPreview:controller];
    return view ? AMProjV865CenterAnchorRect(view.bounds) : CGRectZero;
}

- (void)documentInteractionControllerDidDismissOpenInMenu:
    (UIDocumentInteractionController *)controller {
    [self scheduleCleanup];
}

- (void)documentInteractionControllerDidEndPreview:
    (UIDocumentInteractionController *)controller {
    [self scheduleCleanup];
}

- (void)scheduleCleanup {
    AMProjV865ScheduleDirectoryCleanup(self.cleanupDirectory);
}

@end

static UIViewController *AMProjV865PresenterForBroker(
    AMProjV865DocumentBroker *broker) {
    UIViewController *presenter = AMProjV865ForegroundPresenter();
    if (!presenter || !presenter.viewIfLoaded.window) return nil;
    broker.presenter = presenter;
    return presenter;
}

static BOOL AMProjV865PresentOpenInFallback(
    AMProjV865DocumentBroker *broker, UIViewController *presenter,
    AMProjV865RouteCompletion completion) {
    NSError *(^cancelError)(void) = ^{
        return AMProjV865StageError(6, @"The project handoff was cancelled");
    };
    if (!broker || broker.fallbackPresented || !presenter ||
        !presenter.viewIfLoaded.window || !broker.stagedURL ||
        broker.request.isCancelled) {
        if (broker && broker.stagedURL) {
            NSError *error = broker.request.isCancelled
                ? cancelError() : AMProjV865StageError(
                    7, @"No visible presenter is available for the project handoff");
            AMProjV865WriteHandoffBreadcrumb(
                AMProjV865ProjectHandoffStatusFailed, broker.stagedURL,
                broker.stagedURL.lastPathComponent,
                broker.request.isCancelled ? @"cancelled" : @"fallback_presenter_unavailable", nil);
            [broker scheduleCleanup];
            if (completion) completion(AMProjV865ProjectHandoffStatusFailed, error);
        }
        return NO;
    }
    broker.fallbackPresented = YES;
    if (!broker.controller) {
        broker.controller = [UIDocumentInteractionController
            interactionControllerWithURL:broker.stagedURL];
        NSString *extension = broker.stagedURL.pathExtension.lowercaseString;
        broker.controller.UTI = [extension isEqualToString:@"xml"]
            ? @"public.xml" : @"com.alightcreative.motion.amproj";
        broker.controller.delegate = broker;
    }
    BOOL presented = [broker.controller presentOpenInMenuFromRect:
        AMProjV865CenterAnchorRect(presenter.view.bounds)
                                                   inView:presenter.view animated:YES];
    if (!presented) {
        broker.fallbackPresented = NO;
        NSError *error = AMProjV865StageError(8, @"The system could not present the project handoff menu");
        AMProjV865WriteHandoffBreadcrumb(
            AMProjV865ProjectHandoffStatusFailed, broker.stagedURL,
            broker.stagedURL.lastPathComponent, @"open_in_unavailable", nil);
        [broker scheduleCleanup];
        NSLog(@"[AMProjExport] 865 project handoff staged; no Open In target is available");
        if (completion) completion(AMProjV865ProjectHandoffStatusFailed, error);
    } else {
        AMProjV865WriteHandoffBreadcrumb(
            AMProjV865ProjectHandoffStatusFallbackPresented, broker.stagedURL,
            broker.stagedURL.lastPathComponent, nil,
            @{ @"route": @"uidocument_interaction" });
        AMProjV865WriteHandoffBreadcrumb(
            AMProjV865ProjectHandoffStatusUnverified, broker.stagedURL,
            broker.stagedURL.lastPathComponent, @"open_in_requires_user_selection",
            @{ @"route_status": @"fallback_presented" });
        NSLog(@"[AMProjExport] 865 project handoff presented through native Open In fallback");
        if (completion) completion(AMProjV865ProjectHandoffStatusFallbackPresented, nil);
    }
    return presented;
}

static BOOL AMProjV865PresentStagedDocument(NSURL *stagedURL,
                                            UIViewController *presenter,
                                            AMProjV865ProjectFlowRequest *request,
                                            AMProjV865RouteCompletion completion) {
    if (!stagedURL || !presenter || !presenter.viewIfLoaded.window ||
        !AMProjV865ProjectFlowIsRuntimeSupported() || request.isCancelled) {
        if (stagedURL) {
            NSError *error = request.isCancelled
                ? AMProjV865StageError(6, @"The project handoff was cancelled")
                : AMProjV865StageError(7, @"No visible presenter is available for the project handoff");
            AMProjV865WriteHandoffBreadcrumb(
                AMProjV865ProjectHandoffStatusFailed, stagedURL,
                stagedURL.lastPathComponent,
                request.isCancelled ? @"cancelled" : @"no_visible_presenter", nil);
            AMProjV865ScheduleDirectoryCleanup(stagedURL.URLByDeletingLastPathComponent);
            if (completion) completion(AMProjV865ProjectHandoffStatusFailed, error);
        }
        return NO;
    }
    AMProjV865DocumentBroker *broker = [AMProjV865DocumentBroker new];
    broker.stagedURL = stagedURL;
    broker.cleanupDirectory = stagedURL.URLByDeletingLastPathComponent;
    broker.request = request;
    broker.presenter = presenter;
    objc_setAssociatedObject(presenter, AMProjV865BrokerKey, broker,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIApplication *application = UIApplication.sharedApplication;
    BOOL canUseNativeRoute = application.applicationState == UIApplicationStateActive &&
        [application respondsToSelector:
            @selector(openURL:options:completionHandler:)];
    if (canUseNativeRoute) {
        broker.nativeRouteInFlight = YES;
        NSLog(@"[AMProjExport] 865 project handoff opening through native document URL route: %@",
              stagedURL.lastPathComponent ?: @"project");
        [application openURL:stagedURL options:@{}
            completionHandler:^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                broker.nativeRouteInFlight = NO;
                if (broker.request.isCancelled) {
                    AMProjV865WriteHandoffBreadcrumb(
                        AMProjV865ProjectHandoffStatusFailed, broker.stagedURL,
                        broker.stagedURL.lastPathComponent, @"cancelled_after_route_start", nil);
                    [broker scheduleCleanup];
                    if (completion) completion(AMProjV865ProjectHandoffStatusFailed,
                        AMProjV865StageError(6, @"The project handoff was cancelled"));
                    return;
                }
                if (success) {
                    AMProjV865WriteHandoffBreadcrumb(
                        AMProjV865ProjectHandoffStatusRouteAccepted,
                        broker.stagedURL, broker.stagedURL.lastPathComponent, nil,
                        @{ @"route": @"application.openURL" });
                    AMProjV865WriteHandoffBreadcrumb(
                        AMProjV865ProjectHandoffStatusUnverified,
                        broker.stagedURL, broker.stagedURL.lastPathComponent,
                        @"openURL_acceptance_is_not_import_confirmation",
                        @{ @"route_status": @"route_accepted" });
                    NSLog(@"[AMProjExport] 865 native document URL route accepted: %@",
                          stagedURL.lastPathComponent ?: @"project");
                    [broker scheduleCleanup];
                    if (completion) completion(AMProjV865ProjectHandoffStatusRouteAccepted, nil);
                    return;
                }
                UIViewController *fallback = AMProjV865PresenterForBroker(broker);
                if (!fallback || !AMProjV865PresentOpenInFallback(broker, fallback, completion)) {
                    NSLog(@"[AMProjExport] 865 native document URL route declined and no fallback presenter is available");
                }
            });
        }];
        return YES;
    }
    return AMProjV865PresentOpenInFallback(broker, presenter, completion);
}

BOOL AMProjV865ProjectFlowIsProjectPackageController(UIViewController *controller) {
    if (!AMProjV865ProjectFlowIsRuntimeSupported() || !controller) return NO;
    UIViewController *candidate = controller;
    if ([candidate isKindOfClass:UINavigationController.class]) {
        candidate = ((UINavigationController *)candidate).visibleViewController;
    }
    NSString *name = NSStringFromClass(candidate.class);
    return [name isEqualToString:@"AlightMotion.ShareProjectPackageVC"] ||
        [name isEqualToString:@"_TtC12AlightMotion21ShareProjectPackageVC"];
}

static NSError *AMProjV865StageError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.amproj.865.project-flow"
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey:
                                        message ?: @"Project staging failed"}];
}

static void AMProjV865CompleteStage(
    AMProjV865ProjectFlowStageCompletion completion,
    AMProjV865ProjectHandoffStatus status, NSError *error) {
    if (!completion) return;
    void (^deliver)(void) = ^{
        @try {
            completion(status, error);
        } @catch (NSException *exception) {
            NSLog(@"[AMProjExport] 865 handoff completion exception: %@ (%@)",
                  exception.name ?: @"unknown", exception.reason ?: @"unknown");
        }
    };
    if ([NSThread isMainThread]) {
        deliver();
    } else {
        dispatch_async(dispatch_get_main_queue(), deliver);
    }
}

static void AMProjV865ScheduleStagedPresentation(
    NSURL *stagedURL, UIViewController *presenter,
    AMProjV865ProjectFlowRequest *request,
    AMProjV865RouteCompletion completion) {
    if (!stagedURL) {
        if (completion) completion(AMProjV865ProjectHandoffStatusFailed,
            AMProjV865StageError(1, @"The downloaded project is not a readable file URL"));
        return;
    }
    __weak UIViewController *weakPresenter = presenter;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            if (request.isCancelled) {
                AMProjV865WriteHandoffBreadcrumb(
                    AMProjV865ProjectHandoffStatusFailed, stagedURL,
                    stagedURL.lastPathComponent, @"cancelled_before_route", nil);
                AMProjV865ScheduleDirectoryCleanup(stagedURL.URLByDeletingLastPathComponent);
                if (completion) completion(AMProjV865ProjectHandoffStatusFailed,
                    AMProjV865StageError(6, @"The project handoff was cancelled"));
                return;
            }
            UIViewController *owner = AMProjV865ForegroundPresenter();
            UIViewController *candidate = weakPresenter;
            if (!owner && candidate.viewIfLoaded.window) {
                owner = AMProjV865TopController(candidate);
            }
            if (!owner) {
                AMProjV865WriteHandoffBreadcrumb(
                    AMProjV865ProjectHandoffStatusFailed, stagedURL,
                    stagedURL.lastPathComponent, @"no_visible_presenter_after_delay", nil);
                AMProjV865ScheduleDirectoryCleanup(stagedURL.URLByDeletingLastPathComponent);
                NSLog(@"[AMProjExport] 865 project handoff staged without a visible presenter");
                if (completion) completion(AMProjV865ProjectHandoffStatusFailed,
                    AMProjV865StageError(7, @"No visible presenter is available for the project handoff"));
                return;
            }
            (void)AMProjV865PresentStagedDocument(stagedURL, owner, request, completion);
        });
    });
}

AMProjV865ProjectFlowRequest *AMProjV865ProjectFlowStageDocumentAsync(
    NSURL *fileURL, NSString *filename, UIViewController *presenter,
    AMProjV865ProjectFlowStageCompletion completion) {
    AMProjV865ProjectFlowRequest *request = [AMProjV865ProjectFlowRequest new];
    BOOL runtimeSupported = AMProjV865ProjectFlowIsRuntimeSupported();
    if (!runtimeSupported || !fileURL.isFileURL) {
        [request cancel];
        NSError *error = AMProjV865StageError(
            1, @"The downloaded project is not a readable file URL");
        if (runtimeSupported) {
            AMProjV865WriteHandoffBreadcrumb(
                AMProjV865ProjectHandoffStatusFailed, nil, filename,
                error.localizedDescription, nil);
        }
        AMProjV865CompleteStage(completion,
            AMProjV865ProjectHandoffStatusFailed, error);
        return request;
    }
    NSURL *source = [fileURL copy];
    NSString *requestedFilename = [filename copy];
    AMProjV865RegisterRequest(source, request);
    __weak UIViewController *weakPresenter = presenter;
    NSObject *completionLock = [NSObject new];
    __block BOOL completionDelivered = NO;
    void (^completeOnce)(AMProjV865ProjectHandoffStatus, NSError *) =
        ^(AMProjV865ProjectHandoffStatus status, NSError *error) {
            AMProjV865UnregisterRequest(source, request);
            @synchronized (completionLock) {
                if (completionDelivered) return;
                completionDelivered = YES;
            }
            AMProjV865CompleteStage(completion, status, error);
        };
    dispatch_async(AMProjV865StagingQueue(), ^{
        NSURL *stagedURL = nil;
        @try {
            NSError *error = nil;
            stagedURL = AMProjV865CopyDocument(source, requestedFilename, &error);
            if (!stagedURL) {
                AMProjV865WriteHandoffBreadcrumb(
                    AMProjV865ProjectHandoffStatusFailed, nil, requestedFilename,
                    error.localizedDescription ?: @"document_staging_failed", nil);
                NSLog(@"[AMProjExport] 865 project handoff rejected: %@",
                      error.localizedDescription ?: @"unknown");
                completeOnce(AMProjV865ProjectHandoffStatusFailed, error);
                return;
            }
            if (request.isCancelled) {
                AMProjV865WriteHandoffBreadcrumb(
                    AMProjV865ProjectHandoffStatusFailed, stagedURL,
                    stagedURL.lastPathComponent, @"cancelled_after_staging", nil);
                AMProjV865ScheduleDirectoryCleanup(stagedURL.URLByDeletingLastPathComponent);
                completeOnce(AMProjV865ProjectHandoffStatusFailed,
                    AMProjV865StageError(6, @"The project handoff was cancelled"));
                return;
            }
            AMProjV865WriteHandoffBreadcrumb(
                AMProjV865ProjectHandoffStatusStaged, stagedURL,
                stagedURL.lastPathComponent, nil, @{ @"route": @"pending" });
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    AMProjV865ScheduleStagedPresentation(
                        stagedURL, weakPresenter, request,
                        ^(AMProjV865ProjectHandoffStatus status, NSError *routeError) {
                            completeOnce(status, routeError);
                        });
                } @catch (NSException *exception) {
                    NSError *error = AMProjV865StageError(
                        5, @"The project handoff raised an exception while routing");
                    @try {
                        AMProjV865WriteHandoffBreadcrumb(
                            AMProjV865ProjectHandoffStatusFailed, stagedURL,
                            requestedFilename, error.localizedDescription,
                            @{ @"phase": @"main_queue_route",
                               @"exception": exception.name ?: @"unknown",
                               @"reason": exception.reason ?: @"unknown" });
                    } @catch (__unused NSException *breadcrumbException) {
                        NSLog(@"[AMProjExport] 865 route failure breadcrumb raised an exception");
                    }
                    if (stagedURL) {
                        // Keep the staged source available for retry after a route exception.
                        AMProjV865ScheduleDirectoryCleanup(
                            stagedURL.URLByDeletingLastPathComponent);
                    }
                    NSLog(@"[AMProjExport] 865 project handoff route exception: %@ (%@)",
                          exception.name ?: @"unknown", exception.reason ?: @"unknown");
                    completeOnce(AMProjV865ProjectHandoffStatusFailed, error);
                }
            });
        } @catch (NSException *exception) {
            NSError *error = AMProjV865StageError(
                4, @"The project handoff raised an exception while staging");
            @try {
                AMProjV865WriteHandoffBreadcrumb(
                    AMProjV865ProjectHandoffStatusFailed, stagedURL,
                    requestedFilename, error.localizedDescription,
                    @{ @"exception": exception.name ?: @"unknown",
                       @"reason": exception.reason ?: @"unknown" });
            } @catch (__unused NSException *breadcrumbException) {
                NSLog(@"[AMProjExport] 865 handoff failure breadcrumb raised an exception");
            }
            if (stagedURL) {
                AMProjV865ScheduleDirectoryCleanup(
                    stagedURL.URLByDeletingLastPathComponent);
            }
            NSLog(@"[AMProjExport] 865 project handoff exception: %@ (%@)",
                  exception.name ?: @"unknown", exception.reason ?: @"unknown");
            completeOnce(AMProjV865ProjectHandoffStatusFailed, error);
        }
    });
    return request;
}

AMProjV865ProjectHandoffStatus AMProjV865ProjectFlowStageDocument(
    NSURL *fileURL, NSString *filename, UIViewController *presenter) {
    if ([NSThread isMainThread]) {
        NSError *error = AMProjV865StageError(
            3, @"Synchronous project staging is not allowed on the main thread");
        if (AMProjV865ProjectFlowIsRuntimeSupported()) {
            AMProjV865WriteHandoffBreadcrumb(
                AMProjV865ProjectHandoffStatusFailed, nil, filename,
                error.localizedDescription, @{ @"thread": @"main" });
        }
        NSLog(@"[AMProjExport] 865 project handoff rejected: %@",
              error.localizedDescription);
        return AMProjV865ProjectHandoffStatusFailed;
    }
    if (!AMProjV865ProjectFlowIsRuntimeSupported() || !fileURL.isFileURL) {
        if (AMProjV865ProjectFlowIsRuntimeSupported()) {
            AMProjV865WriteHandoffBreadcrumb(
                AMProjV865ProjectHandoffStatusFailed, nil, filename,
                @"input_is_not_a_readable_file_url", nil);
        }
        return AMProjV865ProjectHandoffStatusFailed;
    }
    NSError *error = nil;
    NSURL *stagedURL = AMProjV865CopyDocument(fileURL, filename, &error);
    if (!stagedURL) {
        AMProjV865WriteHandoffBreadcrumb(
            AMProjV865ProjectHandoffStatusFailed, nil, filename,
            error.localizedDescription ?: @"document_staging_failed", nil);
        NSLog(@"[AMProjExport] 865 project handoff rejected: %@",
              error.localizedDescription ?: @"unknown");
        return AMProjV865ProjectHandoffStatusFailed;
    }
    AMProjV865WriteHandoffBreadcrumb(
        AMProjV865ProjectHandoffStatusStaged, stagedURL,
        stagedURL.lastPathComponent, nil, @{ @"route": @"pending" });
    AMProjV865ScheduleStagedPresentation(stagedURL, presenter, nil, nil);
    return AMProjV865ProjectHandoffStatusStaged;
}

BOOL AMProjV865ProjectFlowPresentDocument(NSURL *fileURL, NSString *filename,
                                          UIViewController *presenter) {
    return AMProjV865ProjectFlowStageDocument(fileURL, filename, presenter) ==
        AMProjV865ProjectHandoffStatusStaged;
}

BOOL AMProjV865ProjectFlowQueueDownloadedProject(NSURL *fileURL, NSString *filename) {
    return AMProjV865ProjectFlowPresentDocument(fileURL, filename, nil);
}

void AMProjV865ProjectFlowInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!AMProjV865ProjectFlowIsRuntimeSupported()) {
            NSLog(@"[AMProjExport] 865 project flow: disabled for this bundle");
            return;
        }
        NSURL *root = AMProjV865HandoffRoot();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSFileManager *manager = NSFileManager.defaultManager;
            NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
                includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                   options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
            // A staged source remains available for at least one day. Clean
            // expired handoffs on a later launch if the scheduled cleanup did
            // not run because the app was terminated.
            NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-24 * 60 * 60];
            for (NSURL *entry in entries) {
                NSDate *modified = nil;
                [entry getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
                if (modified && [modified compare:cutoff] == NSOrderedAscending) {
                    [manager removeItemAtURL:entry error:nil];
                }
            }
        });
        NSLog(@"[AMProjExport] 865 project flow ready (native document handoff)");
    });
}
