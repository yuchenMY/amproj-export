#import "AMProjNativeImportBridge.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>
#import <string.h>

static NSString *const AMProjNativeBridgeErrorDomain =
    @"com.amproj.import.native-bridge";

static const uintptr_t AMProjMainPreferredBase = 0x100000000ULL;
static const uintptr_t AMProjNativeImportEntry = 0x100266ee8ULL;
static const uintptr_t AMProjNSStringToSwiftStringStub = 0x101fb678cULL;
static const uintptr_t AMProjSwiftBridgeReleaseStub = 0x101fbc1bcULL;

typedef struct {
    uintptr_t word0;
    uintptr_t word1;
} AMProjSwiftString;

typedef AMProjSwiftString (*AMProjNSStringToSwiftStringFn)(NSString *value);
typedef void (*AMProjSwiftBridgeReleaseFn)(uintptr_t value);

@interface AMProjLocalStorageSnapshot : NSObject
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) NSProgress *progress;
@property(nonatomic, strong) id task;
@property(nonatomic, strong) id reference;
@end

@implementation AMProjLocalStorageSnapshot
@end

// FIRStorageHandle is a signed 64-bit value in the Firebase Objective-C API.
// The Swift importer stores this result as an Int64 and may pass it back to
// removeObserverWithHandle:, so an Objective-C object/NSString handle is not
// ABI-compatible here.
typedef int64_t AMProjLocalStorageHandle;

@interface AMProjLocalStorageTask : NSObject
@property(nonatomic, strong) NSURL *sourceURL;
@property(nonatomic, strong) NSURL *destinationURL;
@property(nonatomic, strong) NSError *transferError;
@property(nonatomic, strong) id reference;
@property(nonatomic, strong) NSProgress *progress;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *observers;
@property(nonatomic) AMProjLocalStorageHandle nextHandle;
@property(nonatomic) BOOL transferFinished;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                   destinationURL:(NSURL *)destinationURL
                         reference:(id)reference;
- (AMProjLocalStorageHandle)observeStatus:(NSInteger)status
                                  handler:(void (^)(id snapshot))handler;
- (void)removeObserverWithHandle:(AMProjLocalStorageHandle)handle;
- (void)removeAllObserversForStatus:(NSInteger)status;
- (void)removeAllObservers;
@end

@interface AMProjLocalStorageReference : NSObject
@property(nonatomic, strong) NSURL *sourceURL;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL;
- (id)writeToFile:(NSURL *)destinationURL;
@end

static NSObject *AMProjNativeBridgeLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static AMProjNativePackageImportCompletion amproj_nativeBridgeCompletion = nil;
static NSUInteger amproj_nativeBridgeGeneration = 0;
static NSString *amproj_nativeBridgeFilename = nil;
static BOOL amproj_nativeBridgePoisoned = NO;

static NSError *AMProjNativeBridgeError(NSInteger code, NSString *message,
                                        NSDictionary *extra) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = message ?: @"Native project import failed";
    if (extra.count) [userInfo addEntriesFromDictionary:extra];
    return [NSError errorWithDomain:AMProjNativeBridgeErrorDomain
                               code:code
                           userInfo:userInfo];
}

static BOOL AMProjFinishNativeBridge(BOOL success, NSError *error) {
    AMProjNativePackageImportCompletion completion = nil;
    @synchronized (AMProjNativeBridgeLock()) {
        completion = amproj_nativeBridgeCompletion;
        if (!completion) return NO;
        amproj_nativeBridgeCompletion = nil;
        amproj_nativeBridgeFilename = nil;
        ++amproj_nativeBridgeGeneration;
    }
    completion(success, error);
    return YES;
}

BOOL AMProjNativePackageImportBridgeFinishFailure(NSError *error) {
    NSError *resolved = error ?: AMProjNativeBridgeError(
        106, @"Alight Motion rejected the local project package", nil);
    return AMProjFinishNativeBridge(NO, resolved);
}

@implementation AMProjLocalStorageTask

- (AMProjLocalStorageSnapshot *)snapshot {
    AMProjLocalStorageSnapshot *snapshot = [AMProjLocalStorageSnapshot new];
    snapshot.error = self.transferError;
    snapshot.task = self;
    snapshot.reference = self.reference;
    snapshot.progress = self.progress;
    return snapshot;
}

- (void)finishTransferWithError:(NSError *)error {
    NSArray<NSDictionary *> *callbacks = nil;
    @synchronized (self) {
        if (self.transferFinished) return;
        self.transferError = error;
        self.transferFinished = YES;
        self.progress.completedUnitCount = 1;
        NSInteger terminalStatus = error ? 5 : 4;
        NSMutableArray<NSDictionary *> *matching = [NSMutableArray array];
        for (NSNumber *handle in self.observers.allKeys) {
            NSDictionary *observer = self.observers[handle];
            if ([observer[@"status"] integerValue] == terminalStatus) {
                [matching addObject:observer];
            }
        }
        [self.observers removeAllObjects];
        callbacks = [matching copy];
    }
    NSLog(@"[AMProjExport] Native import storage finished success=%d callbacks=%lu",
          error == nil, (unsigned long)callbacks.count);
    void (^invokeCallbacks)(void) = ^{
        for (NSDictionary *observer in callbacks) {
            void (^handler)(id) = observer[@"handler"];
            if (handler) handler([self snapshot]);
        }
    };
    if ([NSThread isMainThread]) invokeCallbacks();
    else dispatch_async(dispatch_get_main_queue(), invokeCallbacks);
}

- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                   destinationURL:(NSURL *)destinationURL
                         reference:(id)reference {
    self = [super init];
    if (!self) return nil;
    _sourceURL = sourceURL;
    _destinationURL = destinationURL;
    _reference = reference;
    _progress = [NSProgress progressWithTotalUnitCount:1];
    _observers = [NSMutableDictionary dictionary];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSError *error = nil;
        NSURL *directoryURL = [destinationURL URLByDeletingLastPathComponent];
        if (![manager createDirectoryAtURL:directoryURL
               withIntermediateDirectories:YES attributes:nil error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishTransferWithError:error];
            });
            return;
        }
        if ([manager fileExistsAtPath:destinationURL.path] &&
            ![manager removeItemAtURL:destinationURL error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishTransferWithError:error];
            });
            return;
        }
        if (![manager copyItemAtURL:sourceURL toURL:destinationURL error:&error]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishTransferWithError:error];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishTransferWithError:nil];
        });
    });
    return self;
}

- (AMProjLocalStorageHandle)observeStatus:(NSInteger)status
                                  handler:(void (^)(id snapshot))handler {
    if (!handler) return 0;

    AMProjLocalStorageHandle handle = 0;
    BOOL notifyTerminal = NO;
    AMProjLocalStorageSnapshot *terminalSnapshot = nil;
    @synchronized (self) {
        handle = ++self.nextHandle;
        notifyTerminal = self.transferFinished &&
            ((status == 4 && self.transferError == nil) ||
             (status == 5 && self.transferError != nil));
        if (notifyTerminal) {
            terminalSnapshot = [self snapshot];
        } else {
            self.observers[@(handle)] = @{
                @"status": @(status),
                @"handler": [handler copy]
            };
        }
    }
    NSLog(@"[AMProjExport] Native import storage observer status=%ld terminal=%d",
          (long)status, notifyTerminal);
    if (notifyTerminal) {
        void (^callback)(id) = [handler copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(terminalSnapshot ?: [self snapshot]);
        });
    }
    return handle;
}

- (void)removeObserverWithHandle:(AMProjLocalStorageHandle)handle {
    if (!handle) return;
    @synchronized (self) {
        [self.observers removeObjectForKey:@(handle)];
    }
}

- (void)removeAllObserversForStatus:(NSInteger)status {
    @synchronized (self) {
        NSMutableArray<NSNumber *> *handles = [NSMutableArray array];
        for (NSNumber *handle in self.observers) {
            if ([self.observers[handle][@"status"] integerValue] == status) {
                [handles addObject:handle];
            }
        }
        [self.observers removeObjectsForKeys:handles];
    }
}

- (void)removeAllObservers {
    @synchronized (self) {
        [self.observers removeAllObjects];
    }
}

@end

@implementation AMProjLocalStorageReference

- (instancetype)initWithSourceURL:(NSURL *)sourceURL {
    self = [super init];
    if (self) _sourceURL = sourceURL;
    return self;
}

- (id)writeToFile:(NSURL *)destinationURL {
    return [[AMProjLocalStorageTask alloc] initWithSourceURL:self.sourceURL
                                             destinationURL:destinationURL
                                                   reference:self];
}

@end


static const struct mach_header_64 *AMProjMainHeader(void) {
    const struct mach_header *header = _dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64) return NULL;
    return (const struct mach_header_64 *)header;
}

static BOOL AMProjMainExecutableMatches(NSError **error) {
    static const uint8_t expectedUUID[16] = {
        0x4b, 0x22, 0xd4, 0x3f, 0x09, 0xfc, 0x3b, 0xde,
        0x85, 0x9b, 0x78, 0xa5, 0xd5, 0x73, 0xa5, 0x03,
    };
    static const uint8_t expectedPrologue[16] = {
        0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9,
        0xf8, 0x5f, 0x02, 0xa9, 0xf6, 0x57, 0x03, 0xa9,
    };

    const struct mach_header_64 *header = AMProjMainHeader();
    if (!header) {
        if (error) *error = AMProjNativeBridgeError(
            100, @"The Alight Motion executable header is unavailable", nil);
        return NO;
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *limit = cursor + header->sizeofcmds;
    BOOL uuidMatched = NO;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if (cursor + sizeof(struct load_command) > limit) break;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command) ||
            cursor + command->cmdsize > limit) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            uuidMatched = memcmp(uuid->uuid, expectedUUID, sizeof(expectedUUID)) == 0;
            break;
        }
        cursor += command->cmdsize;
    }
    if (!uuidMatched) {
        if (error) *error = AMProjNativeBridgeError(
            100, @"This native importer only supports the supplied clean AM_v1 build", nil);
        return NO;
    }

    uintptr_t runtimeBase = (uintptr_t)header;
    const void *entry = (const void *)(runtimeBase +
        (AMProjNativeImportEntry - AMProjMainPreferredBase));
    if (memcmp(entry, expectedPrologue, sizeof(expectedPrologue)) != 0) {
        if (error) *error = AMProjNativeBridgeError(
            100, @"The Alight Motion importer entry does not match the verified build", nil);
        return NO;
    }
    return YES;
}

static void *AMProjMainAddress(uintptr_t preferredAddress) {
    const struct mach_header_64 *header = AMProjMainHeader();
    if (!header || preferredAddress < AMProjMainPreferredBase) return NULL;
    return (void *)((uintptr_t)header +
                    (preferredAddress - AMProjMainPreferredBase));
}

static UIViewController *AMProjTopController(UIViewController *controller) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    while (controller) {
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) break;
        [visited addObject:identity];
        if (controller.presentedViewController &&
            !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
            continue;
        }
        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible =
                ((UINavigationController *)controller).visibleViewController;
            if (visible && visible != controller) {
                controller = visible;
                continue;
            }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *selected =
                ((UITabBarController *)controller).selectedViewController;
            if (selected && selected != controller) {
                controller = selected;
                continue;
            }
        }
        break;
    }
    return controller;
}

static UIViewController *AMProjLoadedProjectsController(void);
static void AMProjSelectProjectsTab(UIViewController *projects);

@interface AMProjProjectControllerCandidate : NSObject
@property(nonatomic, strong) UIViewController *controller;
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic) BOOL foregroundActive;
@property(nonatomic) BOOL keyWindow;
@property(nonatomic) BOOL visibleWindow;
@property(nonatomic) BOOL mounted;
@property(nonatomic) NSInteger classRank;
@property(nonatomic) NSUInteger depth;
@end

@implementation AMProjProjectControllerCandidate
@end

static NSArray<AMProjProjectControllerCandidate *> *AMProjProjectControllerCandidates(void);
static AMProjProjectControllerCandidate *AMProjBestProjectControllerCandidate(
    NSArray<AMProjProjectControllerCandidate *> *candidates, BOOL requireMounted);
static BOOL AMProjControllerIsMountedVisible(UIViewController *controller);
static BOOL AMProjControllerBlocksNativePresentation(UIViewController *controller);
static UIViewController *AMProjVisibleWindowPresentationOwner(void);

static UIViewController *AMProjUsablePresentationOwner(
    UIViewController *controller) {
    controller = AMProjTopController(controller);
    while (controller &&
           ([controller isKindOfClass:UIAlertController.class] ||
            controller.isBeingDismissed)) {
        UIViewController *presenter = controller.presentingViewController;
        if (!presenter || presenter == controller) return nil;
        controller = presenter;
    }
    if (!controller || !controller.viewIfLoaded.window) return nil;
    return controller;
}

static UIViewController *AMProjPresentationOwner(void) {
    // The project tab can still be loading when QQ/File Provider wakes AM.
    // Select the best known project controller first, then re-scan after UIKit
    // has applied the tab selection. Never fall back to an arbitrary root
    // controller: PackageImporter presents its own UI from this owner.
    NSArray<AMProjProjectControllerCandidate *> *initial =
        AMProjProjectControllerCandidates();
    AMProjProjectControllerCandidate *candidate =
        AMProjBestProjectControllerCandidate(initial, NO);
    if (!candidate) {
        NSLog(@"[AMProjExport] Native import project owner: no ProjectsVC/ProjectsListVC candidate");
        return AMProjVisibleWindowPresentationOwner();
    }
    NSLog(@"[AMProjExport] Native import project candidate class=%@ window=%@ active=%d key=%d visible=%d mounted=%d",
          NSStringFromClass(candidate.controller.class), candidate.window,
          candidate.foregroundActive, candidate.keyWindow,
          candidate.visibleWindow, candidate.mounted);
    UIViewController *projects = candidate.controller;
    AMProjSelectProjectsTab(projects);

    NSArray<AMProjProjectControllerCandidate *> *mountedCandidates =
        AMProjProjectControllerCandidates();
    AMProjProjectControllerCandidate *mounted =
        AMProjBestProjectControllerCandidate(mountedCandidates, YES);
    if (!mounted) {
        NSLog(@"[AMProjExport] Native import project owner: tab selected but no mounted visible candidate");
        return AMProjVisibleWindowPresentationOwner();
    }
    UIViewController *projectOwner =
        AMProjUsablePresentationOwner(mounted.controller);
    if (!projectOwner || !AMProjControllerIsMountedVisible(projectOwner)) {
        NSLog(@"[AMProjExport] Native import project owner: candidate %@ is not mounted after tab selection",
              NSStringFromClass(mounted.controller.class));
        return AMProjVisibleWindowPresentationOwner();
    }
    NSLog(@"[AMProjExport] Native import project owner selected class=%@ window=%@",
          NSStringFromClass(projectOwner.class), projectOwner.viewIfLoaded.window);
    return projectOwner;
}

static UIViewController *AMProjFindProjectsController(UIViewController *controller,
                                                       NSUInteger depth,
                                                       NSMutableSet<NSValue *> *visited);

static BOOL AMProjIsProjectsController(UIViewController *controller,
                                       NSInteger *classRank) {
    if (!controller) return NO;
    NSString *name = NSStringFromClass(controller.class);
    // Swift runtime names can be either "AlightMotion.ProjectsVC" or the
    // mangled Objective-C form "_TtC...ProjectsVC".
    if ([name hasSuffix:@"ProjectsVC"]) {
        if (classRank) *classRank = 2;
        return YES;
    }
    if ([name hasSuffix:@"ProjectsListVC"]) {
        if (classRank) *classRank = 1;
        return YES;
    }
    return NO;
}

static BOOL AMProjControllerIsMountedVisible(UIViewController *controller) {
    if (!controller) return NO;
    UIView *view = controller.viewIfLoaded;
    UIWindow *window = view.window;
    if (!view || !window || window.hidden || window.alpha <= 0.01) return NO;
    if (view.hidden || view.alpha <= 0.01) return NO;
    return YES;
}

static UIWindow *AMProjNearestAttachedWindow(UIViewController *controller,
                                             UIWindow *sourceWindow) {
    for (UIViewController *cursor = controller; cursor; cursor = cursor.parentViewController) {
        UIWindow *window = cursor.viewIfLoaded.window;
        if (window) return window;
    }
    return sourceWindow;
}

static void AMProjCollectProjectsControllers(
    UIViewController *controller,
    NSUInteger depth,
    NSMutableSet<NSValue *> *visited,
    NSMutableArray<NSDictionary *> *matches,
    UIWindow *sourceWindow) {
    if (!controller || depth > 24) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    NSInteger classRank = 0;
    if (AMProjIsProjectsController(controller, &classRank)) {
        [matches addObject:@{
            @"controller": controller,
            @"window": sourceWindow ?: [NSNull null],
            @"class_rank": @(classRank),
            @"depth": @(depth)
        }];
    }

    AMProjCollectProjectsControllers(controller.presentedViewController,
                                     depth + 1, visited, matches, sourceWindow);
    for (UIViewController *child in controller.childViewControllers) {
        AMProjCollectProjectsControllers(child, depth + 1, visited, matches,
                                         sourceWindow);
    }
    // A few Swift containers do not expose their managed children through
    // childViewControllers until their view is loaded. Include these explicit
    // edges without forcing a view load.
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
            AMProjCollectProjectsControllers(child, depth + 1, visited, matches,
                                             sourceWindow);
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)controller).viewControllers) {
            AMProjCollectProjectsControllers(child, depth + 1, visited, matches,
                                             sourceWindow);
        }
    }
}

static BOOL AMProjSceneIsForegroundActive(UIWindow *window) {
    return window.windowScene.activationState == UISceneActivationStateForegroundActive;
}

static NSArray<AMProjProjectControllerCandidate *> *AMProjProjectControllerCandidates(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableSet<NSValue *> *windowIDs = [NSMutableSet set];
    void (^appendWindow)(UIWindow *) = ^(UIWindow *window) {
        if (!window) return;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([windowIDs containsObject:identity]) return;
        [windowIDs addObject:identity];
        // Hidden/system windows must never become a presentation owner.
        if (window.hidden || window.alpha <= 0.01) return;
        [windows addObject:window];
    };

    NSArray<UIScene *> *scenes = application.connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) appendWindow(window);
    }
    // UIApplication.windows is still populated by older/partially migrated
    // scenes (notably during a cold document URL launch), so use it as a
    // de-duplicated fallback.
    for (UIWindow *window in application.windows) appendWindow(window);

    NSMutableArray<AMProjProjectControllerCandidate *> *candidates = [NSMutableArray array];
    for (UIWindow *window in windows) {
        BOOL foregroundActive = AMProjSceneIsForegroundActive(window);
        NSLog(@"[AMProjExport] Native import window=%@ active=%d key=%d visible=%d root=%@",
              window, foregroundActive, window.isKeyWindow,
              !window.hidden && window.alpha > 0.01,
              NSStringFromClass(window.rootViewController.class));
        NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        AMProjCollectProjectsControllers(window.rootViewController, 0, visited,
                                         matches, window);
        for (NSDictionary *match in matches) {
            UIViewController *controller = match[@"controller"];
            UIWindow *attached = AMProjNearestAttachedWindow(controller, window);
            BOOL attachedVisible = attached && !attached.hidden && attached.alpha > 0.01;
            AMProjProjectControllerCandidate *candidate = [AMProjProjectControllerCandidate new];
            candidate.controller = controller;
            candidate.window = attached ?: window;
            candidate.foregroundActive = foregroundActive;
            candidate.keyWindow = window.isKeyWindow || attached.isKeyWindow;
            candidate.visibleWindow = attachedVisible;
            candidate.mounted = attachedVisible && AMProjControllerIsMountedVisible(controller);
            candidate.classRank = [match[@"class_rank"] integerValue];
            candidate.depth = [match[@"depth"] unsignedIntegerValue];
            [candidates addObject:candidate];
            NSLog(@"[AMProjExport] Native import candidate class=%@ window=%@ active=%d key=%d visible=%d mounted=%d",
                  NSStringFromClass(controller.class), candidate.window,
                  candidate.foregroundActive, candidate.keyWindow,
                  candidate.visibleWindow, candidate.mounted);
        }
    }
    return candidates;
}

static BOOL AMProjProjectCandidateIsBetter(AMProjProjectControllerCandidate *left,
                                           AMProjProjectControllerCandidate *right) {
    if (!right) return YES;
    if (left.foregroundActive != right.foregroundActive)
        return left.foregroundActive;
    if (left.keyWindow != right.keyWindow)
        return left.keyWindow;
    if (left.visibleWindow != right.visibleWindow)
        return left.visibleWindow;
    if (left.mounted != right.mounted)
        return left.mounted;
    if (left.classRank != right.classRank)
        return left.classRank > right.classRank;
    return left.depth < right.depth;
}

static AMProjProjectControllerCandidate *AMProjBestProjectControllerCandidate(
    NSArray<AMProjProjectControllerCandidate *> *candidates, BOOL requireMounted) {
    AMProjProjectControllerCandidate *best = nil;
    for (AMProjProjectControllerCandidate *candidate in candidates) {
        if (!candidate.visibleWindow) continue;
        if (requireMounted && !candidate.mounted) continue;
        if (AMProjProjectCandidateIsBetter(candidate, best)) best = candidate;
    }
    return best;
}

static BOOL AMProjControllerBlocksNativePresentation(UIViewController *controller) {
    if (!controller) return YES;
    if ([controller isKindOfClass:UIAlertController.class] ||
        [controller isKindOfClass:UIActivityViewController.class]) return YES;
    NSString *name = NSStringFromClass(controller.class);
    return [name containsString:@"PortalActivityViewController"] ||
           [name containsString:@"ShareProjectPackage"] ||
           [name containsString:@"ProjectsImportAlert"];
}

static UIViewController *AMProjVisibleWindowPresentationOwner(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) return nil;

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    void (^appendWindow)(UIWindow *) = ^(UIWindow *window) {
        if (!window || window.hidden || window.alpha <= 0.01 ||
            !window.rootViewController) return;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([seen containsObject:identity]) return;
        [seen addObject:identity];
        [windows addObject:window];
    };
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) appendWindow(window);
    }
    for (UIWindow *window in application.windows) appendWindow(window);
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *left, UIWindow *right) {
        BOOL leftActive = left.windowScene.activationState == UISceneActivationStateForegroundActive;
        BOOL rightActive = right.windowScene.activationState == UISceneActivationStateForegroundActive;
        if (leftActive != rightActive) return leftActive ? NSOrderedAscending : NSOrderedDescending;
        if (left.isKeyWindow != right.isKeyWindow) {
            return left.isKeyWindow ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    for (UIWindow *window in windows) {
        UIViewController *root = window.rootViewController;
        UIViewController *cursor = root;
        BOOL blocked = NO;
        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        while (cursor) {
            NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)cursor];
            if ([visited containsObject:identity]) { blocked = YES; break; }
            [visited addObject:identity];
            if (AMProjControllerBlocksNativePresentation(cursor) ||
                cursor.isBeingDismissed || cursor.isBeingPresented) {
                blocked = YES;
                break;
            }
            UIViewController *presented = cursor.presentedViewController;
            if (!presented || presented.isBeingDismissed) break;
            cursor = presented;
        }
        if (blocked) continue;
        UIViewController *owner = AMProjUsablePresentationOwner(root);
        if (!owner || AMProjControllerBlocksNativePresentation(owner) ||
            owner.isBeingDismissed || owner.isBeingPresented) continue;
        UIView *view = owner.viewIfLoaded;
        if (!view || view.window != window || view.hidden || view.alpha <= 0.01) continue;
        NSLog(@"[AMProjExport] Native import visible fallback owner=%@ window=%@",
              NSStringFromClass(owner.class), window);
        return owner;
    }
    return nil;
}

static UIViewController *AMProjFindProjectsController(UIViewController *controller,
                                                       NSUInteger depth,
                                                       NSMutableSet<NSValue *> *visited) {
    if (!controller || depth > 24) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if (AMProjIsProjectsController(controller, NULL)) return controller;
    UIViewController *found = AMProjFindProjectsController(
        controller.presentedViewController, depth + 1, visited);
    if (found) return found;
    for (UIViewController *child in controller.childViewControllers) {
        found = AMProjFindProjectsController(child, depth + 1, visited);
        if (found) return found;
    }
    return nil;
}

static UIViewController *AMProjLoadedProjectsController(void) {
    AMProjProjectControllerCandidate *candidate =
        AMProjBestProjectControllerCandidate(AMProjProjectControllerCandidates(), NO);
    return candidate.controller;
}

static void AMProjSelectProjectsTab(UIViewController *projects) {
    if (!projects) return;
    UITabBarController *tabs = projects.tabBarController;
    if (!tabs) return;

    UIViewController *branch = projects;
    while (branch.parentViewController && branch.parentViewController != tabs) {
        branch = branch.parentViewController;
    }
    if (branch.parentViewController == tabs &&
        [tabs.viewControllers containsObject:branch] &&
        tabs.selectedViewController != branch) {
        tabs.selectedViewController = branch;
        [tabs.viewIfLoaded setNeedsLayout];
    }
}

static void AMProjRefreshProjectsController(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *projects = AMProjLoadedProjectsController();
        if (!projects) return;
        AMProjSelectProjectsTab(projects);
        SEL selector = NSSelectorFromString(@"pCollectionView");
        UICollectionView *collection = nil;
        if ([projects respondsToSelector:selector]) {
            collection = ((id (*)(id, SEL))(void *)objc_msgSend)(projects, selector);
        }
        [collection reloadData];
        [collection setNeedsLayout];
    });
}

static void AMProjNativeImportCompletionThunk(void *result) {
    NSLog(@"[AMProjExport] Native import completion enter result=%p", result);
    if (!AMProjFinishNativeBridge(YES, nil)) return;
    NSLog(@"[AMProjExport] Native import completion accepted");
    AMProjRefreshProjectsController();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        AMProjRefreshProjectsController();
    });
}

static BOOL AMProjStartNativePackageImport(
    NSURL *packageURL,
    NSString *originalName,
    AMProjNativePackageImportCompletion completion,
    NSError **error) {
    NSNumber *isRegular = nil;
    NSError *resourceError = nil;
    if (!packageURL.isFileURL ||
        ![packageURL getResourceValue:&isRegular
                               forKey:NSURLIsRegularFileKey
                                error:&resourceError] ||
        !isRegular.boolValue) {
        if (error) *error = resourceError ?: AMProjNativeBridgeError(
            104, @"The complete .amproj package is no longer readable", nil);
        return NO;
    }

    NSError *compatibilityError = nil;
    if (!AMProjMainExecutableMatches(&compatibilityError)) {
        if (error) *error = compatibilityError;
        return NO;
    }

    UIViewController *owner = AMProjPresentationOwner();
    if (!owner) {
        if (error) *error = AMProjNativeBridgeError(
            103, @"The Alight Motion project screen is not ready",
            @{ @"AMProjRetryable": @YES });
        return NO;
    }

    NSUInteger generation = 0;
    @synchronized (AMProjNativeBridgeLock()) {
        if (amproj_nativeBridgePoisoned) {
            if (error) *error = AMProjNativeBridgeError(
                108,
                @"A previous native import timed out. Fully close and reopen Alight Motion before importing another project",
                nil);
            return NO;
        }
        if (amproj_nativeBridgeCompletion) {
            if (error) *error = AMProjNativeBridgeError(
                102, @"Another project package is still importing", nil);
            return NO;
        }
        amproj_nativeBridgeCompletion = [completion copy];
        amproj_nativeBridgeFilename = [originalName copy] ?: packageURL.lastPathComponent;
        generation = ++amproj_nativeBridgeGeneration;
    }

    NSString *projectName = originalName.stringByDeletingPathExtension;
    if (!projectName.length) projectName = packageURL.lastPathComponent.stringByDeletingPathExtension;
    if (!projectName.length) projectName = @"Imported Project";

    AMProjNSStringToSwiftStringFn bridge =
        (AMProjNSStringToSwiftStringFn)dlsym(
            RTLD_DEFAULT,
            "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
    AMProjSwiftBridgeReleaseFn releaseBridge =
        (AMProjSwiftBridgeReleaseFn)dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease");
    if (!bridge) {
        bridge = (AMProjNSStringToSwiftStringFn)AMProjMainAddress(
            AMProjNSStringToSwiftStringStub);
    }
    if (!releaseBridge) {
        releaseBridge = (AMProjSwiftBridgeReleaseFn)AMProjMainAddress(
            AMProjSwiftBridgeReleaseStub);
    }
    void *entry = AMProjMainAddress(AMProjNativeImportEntry);
    if (!bridge || !releaseBridge || !entry) {
        NSError *runtimeError = AMProjNativeBridgeError(
            101, @"The Swift project importer runtime is unavailable", nil);
        AMProjFinishNativeBridge(NO, runtimeError);
        if (error) *error = runtimeError;
        return NO;
    }

    AMProjSwiftString swiftName = bridge(projectName);
    AMProjLocalStorageReference *reference =
        [[AMProjLocalStorageReference alloc] initWithSourceURL:packageURL];
    NSLog(@"[AMProjExport] Native import entry begin owner=%@ package=%@",
          NSStringFromClass(owner.class), packageURL.lastPathComponent);
    @try {
        // The verified Swift entry uses the arm64 Swift closure convention:
        // x2 is the weak UIViewController owner, while the hidden x20
        // context is the storage reference whose writeToFile: method starts
        // the local copy.  AMProjCallNativePackageImport maps its last
        // argument to x20; reversing these two objects makes the importer
        // silently stop after package validation (or report "screen not
        // ready") because it tries to use the storage proxy as a VC.
        AMProjCallNativePackageImport(
            entry,
            swiftName.word0,
            swiftName.word1,
            owner,
            nil,
            (void *)&AMProjNativeImportCompletionThunk,
            NULL,
            reference);
    } @catch (NSException *exception) {
        NSError *runtimeError = AMProjNativeBridgeError(
            109, exception.reason ?: @"The native project importer raised an exception", nil);
        AMProjFinishNativeBridge(NO, runtimeError);
        releaseBridge(swiftName.word1);
        if (error) *error = runtimeError;
        return NO;
    }
    NSLog(@"[AMProjExport] Native import entry returned");
    releaseBridge(swiftName.word1);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        BOOL stillActive = NO;
        @synchronized (AMProjNativeBridgeLock()) {
            stillActive = amproj_nativeBridgeCompletion != nil &&
                          generation == amproj_nativeBridgeGeneration;
            if (stillActive) amproj_nativeBridgePoisoned = YES;
        }
        if (!stillActive) return;
        AMProjNativePackageImportBridgeFinishFailure(AMProjNativeBridgeError(
            107,
            @"Alight Motion did not finish importing the project within 5 minutes. Fully close and reopen the app before retrying",
            nil));
    });
    return YES;
}

void AMProjInstallNativePackageImportBridge(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSError *compatibilityError = nil;
        BOOL compatible = AMProjMainExecutableMatches(&compatibilityError);
        NSLog(@"[AMProjExport] Native PackageImporter bridge: %@%@",
              compatible ? @"ready" : @"incompatible",
              compatibilityError.localizedDescription.length
                  ? [@" - " stringByAppendingString:compatibilityError.localizedDescription]
                  : @"");
        AMProjRegisterNativePackageImportStarter(
            ^BOOL(NSURL *packageURL, NSString *originalName,
                  AMProjNativePackageImportCompletion completion,
                  NSError **error) {
            return AMProjStartNativePackageImport(
                packageURL, originalName, completion, error);
        });
    });
}
