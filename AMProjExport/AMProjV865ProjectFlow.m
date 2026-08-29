#import "AMProjV865ProjectFlow.h"

#import <dispatch/dispatch.h>
#import <objc/runtime.h>

static NSString *const AMProjV865Version = @"6.2.58";
static NSString *const AMProjV865Build = @"865";
static NSString *const AMProjV865DirectoryName = @"AMProjV865ProjectHandoff";
static const void *AMProjV865BrokerKey = &AMProjV865BrokerKey;
static const unsigned long long AMProjV865MaximumDocumentBytes = 512ULL * 1024ULL * 1024ULL;

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
    NSURL *root = AMProjV865HandoffRoot();
    if (!root || ![manager createDirectoryAtURL:root withIntermediateDirectories:YES
                                      attributes:nil error:error]) return nil;
    NSURL *directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString
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
}

@interface AMProjV865DocumentBroker : NSObject <UIDocumentInteractionControllerDelegate>
@property(nonatomic, strong) UIDocumentInteractionController *controller;
@property(nonatomic, strong) NSURL *stagedURL;
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, strong) NSURL *cleanupDirectory;
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
    return view ? CGRectMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds), 1, 1)
                : CGRectZero;
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
    NSURL *directory = self.cleanupDirectory;
    if (!directory) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 24 * 60 * 60 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    });
}

@end

static BOOL AMProjV865PresentStagedDocument(NSURL *stagedURL,
                                            UIViewController *presenter) {
    if (!stagedURL || !presenter || !presenter.viewIfLoaded.window ||
        !AMProjV865ProjectFlowIsRuntimeSupported()) return NO;
    AMProjV865DocumentBroker *broker = [AMProjV865DocumentBroker new];
    broker.stagedURL = stagedURL;
    broker.cleanupDirectory = stagedURL.URLByDeletingLastPathComponent;
    broker.presenter = presenter;
    broker.controller = [UIDocumentInteractionController interactionControllerWithURL:stagedURL];
    NSString *extension = stagedURL.pathExtension.lowercaseString;
    broker.controller.UTI = [extension isEqualToString:@"xml"]
        ? @"public.xml" : @"com.alightcreative.motion.amproj";
    broker.controller.delegate = broker;
    objc_setAssociatedObject(presenter, AMProjV865BrokerKey, broker,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL presented = [broker.controller presentOpenInMenuFromRect:
        CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1)
                                                   inView:presenter.view animated:YES];
    if (!presented) {
        NSLog(@"[AMProjExport] 865 project handoff staged; no Open In target is available");
    } else {
        NSLog(@"[AMProjExport] 865 project handoff presented through native Open In");
    }
    return YES;
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

BOOL AMProjV865ProjectFlowPresentDocument(NSURL *fileURL, NSString *filename,
                                          UIViewController *presenter) {
    if (!AMProjV865ProjectFlowIsRuntimeSupported() || !fileURL.isFileURL) return NO;
    NSError *error = nil;
    NSURL *stagedURL = AMProjV865CopyDocument(fileURL, filename, &error);
    if (!stagedURL) {
        NSLog(@"[AMProjExport] 865 project handoff rejected: %@", error.localizedDescription);
        return NO;
    }
    // AMCloudSync dismisses its account controller immediately after the
    // import callback returns. Defer the UIKit handoff until that dismissal
    // has completed, then resolve the current foreground presenter on main.
    void (^presentWhenReady)(void) = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UIViewController *owner = AMProjV865TopController(presenter) ?:
                AMProjV865ForegroundPresenter();
            if (!owner) {
                NSLog(@"[AMProjExport] 865 project handoff staged without a visible presenter");
                return;
            }
            (void)AMProjV865PresentStagedDocument(stagedURL, owner);
        });
    };
    if ([NSThread isMainThread]) {
        presentWhenReady();
    } else {
        dispatch_async(dispatch_get_main_queue(), presentWhenReady);
    }
    return YES;
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
            NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-7 * 24 * 60 * 60];
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
