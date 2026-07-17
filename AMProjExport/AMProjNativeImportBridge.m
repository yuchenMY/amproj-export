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

@interface AMProjLocalStorageTask : NSObject
@property(nonatomic, strong) NSURL *sourceURL;
@property(nonatomic, strong) NSURL *destinationURL;
@property(nonatomic, strong) NSError *copyError;
@property(nonatomic, strong) id reference;
@property(nonatomic) BOOL terminalScheduled;
- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                   destinationURL:(NSURL *)destinationURL
                         reference:(id)reference;
- (id)observeStatus:(NSInteger)status handler:(void (^)(id snapshot))handler;
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

- (instancetype)initWithSourceURL:(NSURL *)sourceURL
                   destinationURL:(NSURL *)destinationURL
                         reference:(id)reference {
    self = [super init];
    if (!self) return nil;
    _sourceURL = sourceURL;
    _destinationURL = destinationURL;
    _reference = reference;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *error = nil;
    NSURL *directoryURL = [destinationURL URLByDeletingLastPathComponent];
    if (![manager createDirectoryAtURL:directoryURL
           withIntermediateDirectories:YES attributes:nil error:&error]) {
        _copyError = error;
        return self;
    }
    if ([manager fileExistsAtPath:destinationURL.path]) {
        if (![manager removeItemAtURL:destinationURL error:&error]) {
            _copyError = error;
            return self;
        }
    }
    if (![manager copyItemAtURL:sourceURL toURL:destinationURL error:&error]) {
        _copyError = error;
    }
    return self;
}

- (id)observeStatus:(NSInteger)status handler:(void (^)(id snapshot))handler {
    if (!handler) return nil;

    NSString *handle = NSUUID.UUID.UUIDString;
    BOOL scheduleSuccess = NO;
    BOOL scheduleFailure = NO;
    @synchronized (self) {
        if (!self.terminalScheduled) {
            scheduleSuccess = status == 4 && self.copyError == nil;
            scheduleFailure = status == 5 && self.copyError != nil;
            if (scheduleSuccess || scheduleFailure) self.terminalScheduled = YES;
        }
    }

    if (scheduleFailure) {
        void (^callback)(id) = [handler copy];
        AMProjLocalStorageSnapshot *snapshot = [AMProjLocalStorageSnapshot new];
        snapshot.error = self.copyError ?: AMProjNativeBridgeError(
            105, @"Unable to copy the complete .amproj package", nil);
        snapshot.task = self;
        snapshot.reference = self.reference;
        snapshot.progress = [NSProgress progressWithTotalUnitCount:1];
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(snapshot);
        });
    } else if (scheduleSuccess) {
        void (^callback)(id) = [handler copy];
        AMProjLocalStorageSnapshot *snapshot = [AMProjLocalStorageSnapshot new];
        snapshot.task = self;
        snapshot.reference = self.reference;
        snapshot.progress = [NSProgress progressWithTotalUnitCount:1];
        snapshot.progress.completedUnitCount = 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(snapshot);
        });
    }
    return handle;
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
    UIViewController *projects = AMProjLoadedProjectsController();
    UIViewController *projectOwner = AMProjUsablePresentationOwner(projects);
    if (projectOwner) return projectOwner;

    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (window.isKeyWindow && window.rootViewController) {
                UIViewController *owner = AMProjUsablePresentationOwner(
                    window.rootViewController);
                if (owner) return owner;
            }
        }
        for (UIWindow *window in windowScene.windows) {
            if (!window.hidden && window.alpha > 0 && window.rootViewController) {
                UIViewController *owner = AMProjUsablePresentationOwner(
                    window.rootViewController);
                if (owner) return owner;
            }
        }
    }
    return nil;
}

static UIViewController *AMProjFindProjectsController(UIViewController *controller,
                                                       NSUInteger depth,
                                                       NSMutableSet<NSValue *> *visited) {
    if (!controller || depth > 16) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if ([NSStringFromClass(controller.class) containsString:@"ProjectsVC"]) {
        return controller;
    }
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
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *found = AMProjFindProjectsController(
                window.rootViewController, 0, visited);
            if (found) return found;
        }
    }
    return nil;
}

static void AMProjRefreshProjectsController(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *projects = AMProjLoadedProjectsController();
        if (!projects) return;
        UITabBarController *tabs = projects.tabBarController;
        if (tabs) {
            UIViewController *branch = projects;
            while (branch.parentViewController &&
                   branch.parentViewController != tabs) {
                branch = branch.parentViewController;
            }
            if (branch.parentViewController == tabs &&
                [tabs.viewControllers containsObject:branch]) {
                tabs.selectedViewController = branch;
            }
        }
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
    (void)result;
    if (!AMProjFinishNativeBridge(YES, nil)) return;
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
    AMProjCallNativePackageImport(
        entry,
        swiftName.word0,
        swiftName.word1,
        reference,
        nil,
        (void *)&AMProjNativeImportCompletionThunk,
        NULL,
        owner);
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
