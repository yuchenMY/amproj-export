/**
 * AMProjExport.m — 劫持"项目包导出", 将 PNG 替换为 .amproj
 *
 * 策略:
 *   原版 AM iOS 的"项目包导出"生成一张 PNG 图片.
 *   我们 hook UIActivityViewController, 检测到项目包导出时,
 *   拦截图片 items, 替换为 .amproj ZIP 文件.
 *
 * 安全:
 *   - 只在检测到项目包导出时才介入
 *   - 所有其他导出(视频/GIF/Webp/XML)完全不受影响
 *   - 每个 ObjC 调用均有 respondsToSelector + @try/@catch
 *
 * 编译:
 *   clang -dynamiclib -arch arm64 -o AMProjExport.dylib AMProjExport.m \
 *       -framework Foundation -framework UIKit \
 *       -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *       -miphoneos-version-min=14.0 -fobjc-arc
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <StoreKit/StoreKit.h>
#import <Photos/Photos.h>
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <zlib.h>
#import <stdatomic.h>
#import <string.h>
#import <strings.h>
#import <math.h>
#import <float.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "AMProjArchiveWriter.h"
#import "AMProjImportArchive.h"
#import "AMProjNativeImportBridge.h"
#import "AMProjV865ProjectFlow.h"

#if AMPROJ_CLOUD_SYNC
#import "AMCloudSync.h"
#endif

static NSString *const kAMProjPluginVersion = @"44";
// Bumped every defense round; the constructor banner and the chain export
// file both carry it so the installed build can be identified on device
// without guessing.
static NSString *const kAMProjGateDefenseRound = @"r24-storekit-empty-response";
// Master switch for every crack-funnel interception (window hooks, gate
// cycles, funnel sweep, intro autoclose, sweep ladder). The window-level
// rounds were verified to suppress the funnel visually, but their synthetic
// control activations race the crack module's own license state machine and
// were observed dropping the member entitlement (watermark and members-only
// effects returned). Disabled here so the crack flow runs exactly as the
// known-good ae4292f base; flip to YES to restore the defense.
// The crack module is a hollow stub in this package: there is no funnel to
// defend against, and every interception here is pure false-positive risk
// (the r22 black screen was this defense hiding the app's own window).
// Keep the machinery compiled but switched off.
static BOOL amproj_gateDefenseActive = NO;
// The accessibility-based activations (funnel sweep continue taps, intro
// close activation) raced the crack module's license state machine and were
// observed dropping the member entitlement. They stay disarmed even while
// the visual defense is on.
static BOOL amproj_funnelSweepEnabled = NO;
static BOOL amproj_introAutocloseEnabled = YES;
// r14 evidence: activating the paywall's continue control dropped the
// member entitlement, but the user's own manual X-close never did. Only
// the X-close path is therefore automated; the continue activation stays
// banned in the funnel sweep.
static NSString *const kAMProjCloudStabilityContract =
    @"[AMProjExport] v44-stable:semantic-option-7,no-native-activity-fallback";
static const ptrdiff_t AMProjShareVCSelectedExportOptionOffset = 0x120;
#if AMPROJ_CLOUD_SYNC
static const uint8_t AMProjShareCloudUploadOption = 6;
#endif

extern BOOL AMProjV44ReleaseNativeActivityFallbackEnabled(void);
extern BOOL AMProjV44IsDirectProjectPackageOption(uint8_t selectedExportOption);

#if AMPROJ_DEBUG || AMPROJ_TELEMETRY
#import "AMDebugTransport.h"
#endif

#if AMPROJ_DEBUG
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/arm/thread_status.h>
#endif

// Forward declarations
@class AMProjNativeXMLPickerProxy;
typedef NS_ENUM(NSInteger, AMProjIncomingURLResult) {
    AMProjIncomingURLNotRecognized = 0,
    AMProjIncomingURLAccepted,
    AMProjIncomingURLFailed,
};
static UIViewController* amproj_shareVCRecursive(
    UIViewController *controller, NSUInteger depth,
    NSMutableSet<NSValue *> *visited, uint8_t *selectedExportOption);
static UIViewController* amproj_topViewController(UIViewController *controller);
static void amproj_noteIncomingGrantLoss(NSString *name, BOOL isXML);
static void amproj_clearIncomingGrantLoss(NSString *name);
static BOOL AMProjClassIsFromCrackDylib(Class cls);
static BOOL AMProjPresentationChainHasCrackController(UIViewController *controller);
static BOOL AMProjViewHierarchyHasCrackClass(UIView *view, NSUInteger depth);
static NSString* amproj_currentProjectTitle(UIViewController *shareController);
static void amproj_scheduleIPAFireWelcomeSuppression(NSString *source);

typedef NS_ENUM(NSInteger, AMProjImportKind) {
    AMProjImportKindPackage = 0,
    AMProjImportKindXMLTemplate,
};

static NSData* amproj_buildXML(id sceneInfo);
static NSData* amproj_buildXMLInternal(id sceneInfo, NSMutableSet<NSValue*> *visited,
                                       NSUInteger depth, BOOL includeDeclaration);
static NSString* amproj_serializeLayer(id layer, NSMutableSet<NSValue*> *visited, NSUInteger depth);
static NSString* amproj_tagForType(NSString *type);
static UIWindow* amproj_keyWindow(void);
static NSURL* amproj_directExportRoot(void);
static void amproj_exportPresentedChainDiagnostics(
    NSArray<NSString *> *classes);
// Startup paywall fallback window; the initializing definition lives with
// the startup paywall machinery, but the gate-bypass helpers above reference
// it earlier.
static CFAbsoluteTime amproj_paywallStartupFallbackUntil;
static BOOL amproj_URLIsInDocumentsInbox(NSURL *URL);
static NSString* amproj_normalizedFilePath(NSURL *URL);
static AMProjIncomingURLResult amproj_handleIncomingProjectURL(
    NSURL *URL, NSString *source, NSDictionary *options);
static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult(
    NSURL *URL, NSString *source, NSDictionary *options, BOOL *prepared);
static void amproj_releaseImportTransactionForURL(NSURL *URL, NSString *name);
static void amproj_clearImportSuppression(NSURL *URL, NSString *name);
static AMProjIncomingURLResult amproj_handleIncomingProjectURLSafely(
    NSURL *URL, NSString *source, NSDictionary *options, BOOL *prepared);
#if AMPROJ_CLOUD_SYNC
static void amproj_importCloudPackage(NSURL *URL, NSString *filename,
                                      NSURL *cleanupURL,
                                      AMCloudImportCompletion completion);
#endif
static void amproj_presentImportError(NSString *message);
static void amproj_presentImportErrorOfferingPicker(NSString *message,
                                                     BOOL offerPicker);
static void amproj_presentImportErrorOfferingPickerWithTitle(
    NSString *message, NSString *title, BOOL offerPicker);
static void amproj_presentXMLImportError(NSString *message,
                                         BOOL offerPicker);
static void amproj_presentImportErrorForKind(NSString *message,
                                              AMProjImportKind kind,
                                              BOOL offerPicker);
static void amproj_presentImportDocumentPicker(void);
static dispatch_queue_t amproj_importInboxQueue(void);
static void amproj_scanLocalImportInboxes(NSString *source, NSString *requestID);
static void amproj_installImportHook(void);
static void amproj_installPublic865ImportHooks(void);
static void amproj_installPublic865SceneHooksForClass(Class cls);
static void amproj_recordPublic865LaunchNativeRoute(
    NSDictionary *launchOptions, NSString *source, BOOL forwarded);
static void amproj_installNativeProjectPickerHook(void);
static Class amproj_declaredAppDelegateClass(void);
static void amproj_installApplicationDelegateHook(void);
static void amproj_installShareExportHook(void);
static void amproj_installNavigationExportHook(void);
static void amproj_installPresentationHook(void);
static id<UIDocumentPickerDelegate> amproj_restoreNativeXMLPickerDelegate(
    AMProjNativeXMLPickerProxy *proxy,
    UIDocumentPickerViewController *picker);
static NSString* amproj_importedFontFilename(NSString *reference);
static NSDictionary* amproj_captureImportPersistenceSnapshot(void);
static void amproj_storeImportProjectTitle(NSString *transactionID,
                                           NSString *projectTitle);
static void amproj_captureActivatedPersistenceBaseline(
    NSString *transactionID, NSUInteger generation, NSUInteger probeEpoch,
    void (^completion)(BOOL captured));
static void amproj_scheduleImportPersistenceProbe(
    NSString *transactionID, NSString *reason, void (^completion)(BOOL verified));
static void amproj_captureXMLPersistenceBaseline(
    NSString *transactionID, NSUInteger generation,
    void (^completion)(BOOL captured));
static void amproj_probeXMLPersistence(
    NSString *transactionID, NSUInteger generation,
    void (^completion)(BOOL verified));
static NSArray *amproj_accessibilityChildren(UIView *view);

static AMProjImportKind amproj_importKindForURL(NSURL *URL,
                                                NSDictionary *options);

static void amproj_debugEvent(NSString *name, NSDictionary *fields) {
#if AMPROJ_DEBUG || AMPROJ_TELEMETRY
    [[AMDebugTransport shared] emitEvent:name fields:fields ?: @{}];
#else
    (void)name;
    (void)fields;
#endif
}

// Keep the two user-visible entry points diagnosable even when the telemetry
// backend is not configured.  These messages are intentionally limited to
// class names, selectors, and file extensions; they never log project bytes.
static void amproj_logCriticalEvent(NSString *name, NSDictionary *fields) {
    NSLog(@"[AMProjExport] %@ %@", name ?: @"event", fields ?: @{});
    amproj_debugEvent(name, fields);
}

// The native import/export hooks below were reverse-engineered against the
// 6.2.55 (862) private ABI.  6.2.58 (865) must use AM's own document and
// activity paths until a matching ABI has been verified.  Keep this check
// exact so a missing or unexpected bundle version never opts into the 865
// safety path accidentally, and leave the 862 behavior unchanged.
static BOOL amproj_runtimeIsBuild865(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *shortVersion = [info[@"CFBundleShortVersionString"]
        isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : nil;
    NSString *buildVersion = [info[@"CFBundleVersion"]
        isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : nil;
    return [shortVersion isEqualToString:@"6.2.58"] &&
        [buildVersion isEqualToString:@"865"];
}

static BOOL amproj_runtimeIsLegacy862(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *shortVersion = [info[@"CFBundleShortVersionString"]
        isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : nil;
    NSString *buildVersion = [info[@"CFBundleVersion"]
        isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : nil;
    return [shortVersion isEqualToString:@"6.2.55"] &&
        [buildVersion isEqualToString:@"862"];
}

static BOOL amproj_runtimeUsesLegacyImportHooks(void) {
    // The legacy lane is allowed only for the exact ABI that was verified in
    // the 6.2.55 package. Unknown or missing bundle metadata fails closed.
    return amproj_runtimeIsLegacy862() &&
        AMProjNativePackageImportBridgeIsRuntimeSupported();
}

static BOOL amproj_runtimeUsesPublic865ImportHooks(void) {
    // Build 865 owns a separate public-API lane. This gate must never imply
    // that the verified 862 PackageImporter ABI is available.
    return amproj_runtimeIsBuild865();
}

// The local import engine (validation, XML wrap, staging, transaction UI and
// breadcrumb evidence) is build independent.  It was historically gated to the
// verified 862 ABI because that was the only build whose native importer could
// finish a transaction.  6.2.58 (865) now runs the same engine so every
// XML/.amproj entry lands in the plugin's own chain instead of Alight Motion's
// online import page.  The final native dispatch step still refuses to run on
// 865 and reports the engine state honestly instead of forwarding or faking.
static BOOL amproj_runtimeUsesLocalImportEngine(void) {
    return amproj_runtimeUsesLegacyImportHooks() || amproj_runtimeIsBuild865();
}

static void amproj_log865LegacyPathDisabled(NSString *component) {
    static NSObject *lock;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        static NSMutableSet<NSString *> *logged;
        static dispatch_once_t setOnce;
        dispatch_once(&setOnce, ^{ logged = [NSMutableSet set]; });
        NSString *name = component.length ? component : @"legacy_import_export";
        if ([logged containsObject:name]) return;
        [logged addObject:name];
        amproj_logCriticalEvent(@"runtime.865_legacy_path_disabled", @{
            @"component": name,
            @"short_version": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
            @"bundle_version": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @""
        });
    }
}

// AmEnhancer keeps its media-demo state in these standalone preferences.  Keep
// them false after all injected images have loaded so the media picker uses the
// user's Photos albums instead of the bundled Sample Media collection.
static void amproj_restorePhotoAlbumMode(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in @[
        @"demo_mode_enabled", @"DemoMode", @"user_demo_mode"
    ]) {
        [defaults setBool:NO forKey:key];
    }
    NSLog(@"[AMProjExport] Restored normal Photos album mode");
}

static void amproj_flushDebugEvents(void) {
#if AMPROJ_DEBUG || AMPROJ_TELEMETRY
    [[AMDebugTransport shared] flush];
#endif
}

static NSString* amproj_stageFilePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"AMProjExport.laststage"];
}

static NSURL *amproj_importBreadcrumbURL(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:
        NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!support) return nil;
    NSURL *directory = [support URLByAppendingPathComponent:@"AMProjImports"
                                                  isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil]) {
        return nil;
    }
    return [directory URLByAppendingPathComponent:@"last-import.plist"];
}

static NSObject *amproj_importBreadcrumbLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDictionary *amproj_readImportBreadcrumbAtURL(NSURL *URL) {
    if (!URL) return nil;
    NSData *data = [NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                           options:NSPropertyListImmutable
                                                            format:nil error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static void amproj_writeImportBreadcrumb(NSString *transactionID,
                                         NSString *fingerprint,
                                         NSString *phase,
                                         NSString *source,
                                         NSString *ownerClass,
                                         NSNumber *nativeStatus,
                                         NSString *errorText) {
    NSURL *URL = amproj_importBreadcrumbURL();
    if (!URL) return;
    @synchronized (amproj_importBreadcrumbLock()) {
        NSDictionary *previous = amproj_readImportBreadcrumbAtURL(URL);
        NSString *previousID = [previous[@"transaction_id"] isKindOfClass:NSString.class]
            ? previous[@"transaction_id"] : @"";
        BOOL sameTransaction = transactionID.length && [previousID isEqualToString:transactionID];
        NSMutableDictionary *record = sameTransaction
            ? [previous mutableCopy] : [NSMutableDictionary dictionary];
        record[@"transaction_id"] = transactionID ?: @"";
        record[@"phase"] = phase ?: @"";
        record[@"updated_at"] = @([NSDate.date timeIntervalSince1970]);
        if (fingerprint.length || !sameTransaction) record[@"fingerprint"] = fingerprint ?: @"";
        if (source.length || !sameTransaction) record[@"source"] = source ?: @"";
        if (ownerClass.length || !sameTransaction) record[@"owner_class"] = ownerClass ?: @"";
        if (nativeStatus) record[@"native_status"] = nativeStatus;
        if (errorText.length) record[@"error"] = errorText;
        if ([phase isEqualToString:@"completed"]) [record removeObjectForKey:@"error"];

        NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0 error:nil];
        if (data.length) [data writeToURL:URL options:NSDataWritingAtomic error:nil];
    }
}

static NSDictionary *amproj_readImportBreadcrumb(void) {
    NSURL *URL = amproj_importBreadcrumbURL();
    if (!URL) return nil;
    @synchronized (amproj_importBreadcrumbLock()) {
        return amproj_readImportBreadcrumbAtURL(URL);
    }
}

static NSString *amproj_nativeBreadcrumbDisplayStage(NSDictionary *breadcrumb) {
    NSString *phase = [breadcrumb[@"phase"] isKindOfClass:NSString.class]
        ? breadcrumb[@"phase"] : @"";
    NSString *event = [breadcrumb[@"last_native_event"] isKindOfClass:NSString.class]
        ? breadcrumb[@"last_native_event"] : @"";
    NSNumber *status = [breadcrumb[@"native_status"] isKindOfClass:NSNumber.class]
        ? breadcrumb[@"native_status"] : nil;
    if ([event isEqualToString:@"storage_observer_registered"] && status) {
        return [NSString stringWithFormat:@"storage_observer_%@_registered", status];
    }
    return event.length ? event : phase;
}

static void amproj_writeNativeEventBreadcrumb(NSString *transactionID,
                                               NSString *event,
                                               NSDictionary *fields) {
    if (!transactionID.length ||
        (!([event hasPrefix:@"native_"] || [event hasPrefix:@"storage_"]))) return;
    NSURL *URL = amproj_importBreadcrumbURL();
    if (!URL) return;
    @synchronized (amproj_importBreadcrumbLock()) {
        NSDictionary *previous = amproj_readImportBreadcrumbAtURL(URL);
        NSString *previousID = [previous[@"transaction_id"] isKindOfClass:NSString.class]
            ? previous[@"transaction_id"] : @"";
        if (previousID.length && ![previousID isEqualToString:transactionID]) return;

        NSMutableDictionary *record = [previous mutableCopy] ?: [NSMutableDictionary dictionary];
        record[@"transaction_id"] = transactionID;
        if (![record[@"phase"] isKindOfClass:NSString.class]) record[@"phase"] = @"native_active";
        record[@"last_native_event"] = event ?: @"";
        record[@"updated_at"] = @([NSDate.date timeIntervalSince1970]);

        NSNumber *status = [fields[@"status"] isKindOfClass:NSNumber.class]
            ? fields[@"status"] : nil;
        if (status) record[@"native_status"] = status;
        NSString *ownerClass = [fields[@"owner_class"] isKindOfClass:NSString.class]
            ? fields[@"owner_class"] : nil;
        if (ownerClass.length) record[@"owner_class"] = ownerClass;
        NSString *errorText = [fields[@"error"] isKindOfClass:NSString.class]
            ? fields[@"error"] : nil;
        if (errorText.length) record[@"error"] = errorText;

        NSMutableDictionary *nativeFields = [NSMutableDictionary dictionary];
        for (NSString *key in @[
            @"generation", @"status", @"handle", @"handle_class", @"terminal",
            @"success", @"returned", @"exception", @"error_domain", @"error_code",
            @"error", @"filename", @"owner_class", @"source_path", @"destination_path"
        ]) {
            id value = fields[key];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
                nativeFields[key] = value;
            }
        }
        record[@"native_fields"] = nativeFields;

        NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
                                                                    format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0 error:nil];
        if (data.length) [data writeToURL:URL options:NSDataWritingAtomic error:nil];
    }
}

static void amproj_setPersistentStage(NSString *stage) {
    NSString *path = amproj_stageFilePath();
    if (!path.length) return;
    if (!stage.length) {
        unlink(path.fileSystemRepresentation);
        return;
    }
    NSData *data = [stage dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > 96) return;
    int descriptor = open(path.fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (descriptor < 0) return;
    (void)write(descriptor, data.bytes, data.length);
    close(descriptor);
}

static NSString *amproj_sha256ForFileURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL) return nil;
    int descriptor = open(URL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[256 * 1024];
    BOOL success = YES;
    while (YES) {
        ssize_t amount = read(descriptor, buffer, sizeof(buffer));
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0) { success = NO; break; }
        if (amount == 0) break;
        CC_SHA256_Update(&context, buffer, (CC_LONG)amount);
    }
    close(descriptor);
    if (!success) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    static const char digits[] = "0123456789abcdef";
    char hex[CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        hex[index * 2] = digits[digest[index] >> 4];
        hex[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    return [[NSString alloc] initWithBytes:hex length:sizeof(hex)
                                  encoding:NSASCIIStringEncoding];
}

static NSString* amproj_exportMode(void) {
#if AMPROJ_DEBUG
    return [[AMDebugTransport shared] currentMode] ?: @"observe";
#else
    return @"full";
#endif
}

#if AMPROJ_DEBUG
static atomic_uint amproj_getterTraceCount = 0;
static const unsigned int kAMProjGetterTraceLimit = 256;
#endif

// ═══════════════════════════════════════════
// MARK: - ZIP Creator
// ═══════════════════════════════════════════

static NSData* amproj_deflate(NSData *input) {
    if (!input || input.length > UINT_MAX) return nil;

    z_stream stream = {0};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                     -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return nil;
    }

    uLong bound = compressBound((uLong)input.length);
    if (bound > UINT_MAX) {
        deflateEnd(&stream);
        return nil;
    }
    NSMutableData *output = [NSMutableData dataWithLength:(NSUInteger)bound];
    stream.next_in = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out = output.mutableBytes;
    stream.avail_out = (uInt)output.length;

    int result = deflate(&stream, Z_FINISH);
    if (result != Z_STREAM_END) {
        deflateEnd(&stream);
        return nil;
    }

    [output setLength:(NSUInteger)stream.total_out];
    deflateEnd(&stream);
    return output;
}

static NSData* amproj_createZIP(NSData *xml, NSDictionary<NSString*,NSData*> *resources) {
    NSMutableData *z = [NSMutableData data];
    NSMutableArray *cd = [NSMutableArray array];

    void (^w32)(uint32_t) = ^(uint32_t v){
        uint8_t b[4]={v,v>>8,v>>16,v>>24}; [z appendBytes:b length:4];
    };
    void (^w16)(uint16_t) = ^(uint16_t v){
        uint8_t b[2]={v,v>>8}; [z appendBytes:b length:2];
    };

    NSMutableArray *files = [NSMutableArray arrayWithObject:@{@"n":@"scene.xml",@"d":xml}];
    for (NSString *k in resources)
        [files addObject:@{@"n":k,@"d":resources[k]}];

    for (NSDictionary *f in files) {
        NSString *n = f[@"n"]; NSData *d = f[@"d"];
        NSData *nameData = [n dataUsingEncoding:NSUTF8StringEncoding];
        NSData *compressed = amproj_deflate(d);
        if (!compressed || nameData.length > UINT16_MAX || d.length > UINT32_MAX ||
            compressed.length > UINT32_MAX || z.length > UINT32_MAX) return nil;

        uLong crcValue = crc32(0L, Z_NULL, 0);
        crcValue = crc32(crcValue, d.bytes, (uInt)d.length);
        uint32_t crc = (uint32_t)crcValue;
        uint32_t cs = (uint32_t)compressed.length;
        uint32_t us = (uint32_t)d.length;
        uint32_t lo = (uint32_t)z.length;
        [z appendBytes:"PK\3\4" length:4];
        w16(20);w16(0);w16(8);w16(0);w16(0);
        w32(crc);w32(cs);w32(us);
        w16((uint16_t)nameData.length);w16(0);
        [z appendData:nameData];
        [z appendData:compressed];
        [cd addObject:@{@"n":n,@"nd":nameData,@"o":@(lo),@"crc":@(crc),@"cs":@(cs),@"us":@(us)}];
    }

    uint32_t cds = (uint32_t)z.length;
    for (NSDictionary *e in cd) {
        NSString *n = e[@"n"];
        NSData *nameData = e[@"nd"];
        uint32_t lo=[e[@"o"] unsignedIntValue], crc=[e[@"crc"] unsignedIntValue];
        uint32_t cs=[e[@"cs"] unsignedIntValue], us=[e[@"us"] unsignedIntValue];
        [z appendBytes:"PK\1\2" length:4];
        w16(20);w16(20);w16(0);w16(8);w16(0);w16(0);
        w32(crc);w32(cs);w32(us);
        w16((uint16_t)nameData.length);w16(0);w16(0);
        w16(0);w16(0);w32(0);w32(lo);
        [z appendData:nameData];
        (void)n;
    }
    uint32_t cdz = (uint32_t)z.length - cds;
    [z appendBytes:"PK\5\6" length:4];
    w16(0);w16(0);
    w16((uint16_t)cd.count);w16((uint16_t)cd.count);
    w32(cdz);w32(cds);w16(0);
    return z;
}

// ═══════════════════════════════════════════
// MARK: - Scene XML Serializer
// ═══════════════════════════════════════════

static id am_get(id obj, NSString *key) {
    if (!obj || !key) return nil;
#if AMPROJ_DEBUG
    BOOL traceGetter = atomic_fetch_add(&amproj_getterTraceCount, 1) < kAMProjGetterTraceLimit;
    if (traceGetter) {
        amproj_debugEvent(@"getter.begin", @{
            @"class": NSStringFromClass([obj class]) ?: @"",
            @"key": key
        });
    }
#endif

    @try {
        id value = [obj valueForKey:key];
#if AMPROJ_DEBUG
        if (traceGetter) {
            amproj_debugEvent(@"getter.end", @{
                @"class": NSStringFromClass([obj class]) ?: @"",
                @"key": key,
                @"path": @"kvc",
                @"found": @(value != nil)
            });
        }
#endif
        if (value) return value;
    } @catch (NSException *exception) {
#if AMPROJ_DEBUG
        if (traceGetter) {
            amproj_debugEvent(@"getter.kvc_error", @{
                @"class": NSStringFromClass([obj class]) ?: @"",
                @"key": key,
                @"error": exception.reason ?: @""
            });
        }
#endif
    }

    for (Class cls = [obj class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            if (!name) continue;
            NSString *ivarName = [NSString stringWithUTF8String:name];
            if (![ivarName isEqualToString:key] &&
                ![ivarName isEqualToString:[@"_" stringByAppendingString:key]]) continue;

            const char *type = ivar_getTypeEncoding(ivar);
            ptrdiff_t offset = ivar_getOffset(ivar);
            const uint8_t *address = (const uint8_t *)(__bridge const void *)obj + offset;
            id value = nil;

            if (type && (type[0] == '@' || type[0] == '#')) {
                value = object_getIvar(obj, ivar);
            } else if (type) {
#define AMPROJ_BOX_IVAR(code, ctype) \
                case code: { ctype raw = 0; memcpy(&raw, address, sizeof(raw)); value = @(raw); break; }
                switch (type[0]) {
                    AMPROJ_BOX_IVAR('c', char)
                    AMPROJ_BOX_IVAR('C', unsigned char)
                    AMPROJ_BOX_IVAR('s', short)
                    AMPROJ_BOX_IVAR('S', unsigned short)
                    AMPROJ_BOX_IVAR('i', int)
                    AMPROJ_BOX_IVAR('I', unsigned int)
                    AMPROJ_BOX_IVAR('l', long)
                    AMPROJ_BOX_IVAR('L', unsigned long)
                    AMPROJ_BOX_IVAR('q', long long)
                    AMPROJ_BOX_IVAR('Q', unsigned long long)
                    AMPROJ_BOX_IVAR('f', float)
                    AMPROJ_BOX_IVAR('d', double)
                    AMPROJ_BOX_IVAR('B', BOOL)
                    default: break;
                }
#undef AMPROJ_BOX_IVAR
            }

            free(ivars);
#if AMPROJ_DEBUG
            if (traceGetter) {
                amproj_debugEvent(@"getter.end", @{
                    @"class": NSStringFromClass([obj class]) ?: @"",
                    @"key": key,
                    @"path": @"ivar",
                    @"type": type ? [NSString stringWithUTF8String:type] : @"",
                    @"found": @(value != nil)
                });
            }
#endif
            return value;
        }
        free(ivars);
    }

#if AMPROJ_DEBUG
    if (traceGetter) {
        amproj_debugEvent(@"getter.end", @{
            @"class": NSStringFromClass([obj class]) ?: @"",
            @"key": key,
            @"path": @"missing",
            @"found": @NO
        });
    }
#endif
    return nil;
}

static NSString* am_str(id obj, NSString *key) {
    id v = am_get(obj, key);
    return [v isKindOfClass:[NSString class]] ? v :
           [v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil;
}

static NSInteger am_int(id obj, NSString *key) {
    id v = am_get(obj, key);
    return [v respondsToSelector:@selector(integerValue)] ? [(NSNumber*)v integerValue] : 0;
}

static CGFloat am_flt(id obj, NSString *key) {
    id v = am_get(obj, key);
    return [v respondsToSelector:@selector(doubleValue)] ? [(NSNumber*)v doubleValue] : 0.0;
}

static NSArray* am_arr(id obj, NSString *key) {
    id v = am_get(obj, key);
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

// ─── 场景对象递归查找 ───

static id am_findSceneRecursive(id obj, NSUInteger depth, NSMutableSet<NSValue*> *visited) {
    if (!obj || depth > 6) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    NSString *cn = NSStringFromClass([obj class]).lowercaseString;
    if ([cn containsString:@"scene"] && ![cn containsString:@"kit"] &&
        ![cn containsString:@"window"] && ![cn containsString:@"controller"] &&
        (am_get(obj, @"layers") || am_get(obj, @"width")))
        return obj;

    unsigned int pc;
    objc_property_t *props = class_copyPropertyList([obj class], &pc);
    for (unsigned int i = 0; i < pc; i++) {
        NSString *n = [NSString stringWithUTF8String:property_getName(props[i])];
        if ([n.lowercaseString containsString:@"scene"] ||
            [n.lowercaseString containsString:@"project"] ||
            [n.lowercaseString containsString:@"holder"] ||
            [n.lowercaseString isEqualToString:@"root"]) {
            id value = am_get(obj, n);
            id found = am_findSceneRecursive(value, depth + 1, visited);
            if (found) { free(props); return found; }
        }
    }
    free(props);

    unsigned int ic;
    Ivar *ivars = class_copyIvarList([obj class], &ic);
    for (unsigned int i = 0; i < ic; i++) {
        NSString *ivn = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
        NSString *lower = ivn.lowercaseString;
        if ([lower containsString:@"scene"] || [lower containsString:@"project"] ||
            [lower containsString:@"holder"] || [lower isEqualToString:@"_root"]) {
            NSString *key = [ivn hasPrefix:@"_"] ? [ivn substringFromIndex:1] : ivn;
            id value = am_get(obj, key);
            id found = am_findSceneRecursive(value, depth + 1, visited);
            if (found) { free(ivars); return found; }
        }
    }
    free(ivars);
    return nil;
}

static id am_findScene(id obj) {
    NSMutableSet<NSValue*> *visited = [NSMutableSet set];
    return am_findSceneRecursive(obj, 0, visited);
}

static NSString* amproj_escapeXML(NSString *value, BOOL attribute) {
    if (!value) return @"";
    NSMutableString *escaped = [value mutableCopy];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    if (attribute) {
        [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
        [escaped replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, escaped.length)];
    }
    return escaped;
}

// ─── XML 构建 ───

static NSData* amproj_buildXMLInternal(id sceneInfo, NSMutableSet<NSValue*> *visited,
                                       NSUInteger depth, BOOL includeDeclaration) {
    if (!sceneInfo || depth > 12) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)sceneInfo];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    @try {
        NSMutableString *x = [NSMutableString string];
        if (includeDeclaration) {
            [x appendString:@"<?xml version='1.0' encoding='UTF-8' ?>\n"];
        }

        NSString *title = amproj_escapeXML(am_str(sceneInfo, @"title") ?: @"Exported Project", YES);
        NSInteger w = am_int(sceneInfo, @"width") ?: 1280;
        NSInteger h = am_int(sceneInfo, @"height") ?: 720;
        NSInteger fps = am_int(sceneInfo, @"fps") ?: 60;
        NSInteger tt = am_int(sceneInfo, @"totalTime") ?: 5000;
        NSString *bg = amproj_escapeXML(am_str(sceneInfo, @"bgcolor") ?: @"#ff000000", YES);

        [x appendFormat:@"<scene title=\"%@\" width=\"%ld\" height=\"%ld\" "
                          "exportWidth=\"%ld\" exportHeight=\"%ld\" "
                          "fps=\"%ld\" totalTime=\"%ld\" bgcolor=\"%@\">\n",
                          title, (long)w, (long)h, (long)w, (long)h, (long)fps, (long)tt, bg];

        // 序列化 media
        NSArray *media = am_arr(sceneInfo, @"media");
        if (media) {
            for (id m in media) {
                [x appendFormat:@"<media uri=\"%@\" filename=\"%@\" type=\"%@\" />\n",
                    amproj_escapeXML(am_str(m, @"uri") ?: @"", YES),
                    amproj_escapeXML(am_str(m, @"filename") ?: @"", YES),
                    amproj_escapeXML(am_str(m, @"mediaType") ?: @"", YES)];
            }
        }

        // 序列化 layers
        NSArray *layers = am_arr(sceneInfo, @"layers");
        if (layers) {
            NSUInteger index = 0;
            for (id layer in layers) {
#if AMPROJ_DEBUG
                amproj_debugEvent(@"layer.begin", @{@"index": @(index), @"class": NSStringFromClass([layer class]) ?: @""});
#endif
                NSString *layerXML = amproj_serializeLayer(layer, visited, depth + 1);
                if (layerXML) [x appendString:layerXML];
#if AMPROJ_DEBUG
                amproj_debugEvent(@"layer.end", @{@"index": @(index), @"bytes": @(layerXML.length)});
#endif
                index++;
            }
        }

        [x appendString:@"</scene>\n"];
        NSData *result = [x dataUsingEncoding:NSUTF8StringEncoding];
        [visited removeObject:identity];
        return result;
    } @catch (NSException *e) {
        [visited removeObject:identity];
        NSLog(@"[AMProjExport] XML build error: %@", e);
        return nil;
    }
}

static NSData* amproj_buildXML(id sceneInfo) {
    return amproj_buildXMLInternal(sceneInfo, [NSMutableSet set], 0, YES);
}

static NSString* amproj_serializeLayer(id layer, NSMutableSet<NSValue*> *visited, NSUInteger depth) {
    if (!layer || depth > 12) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)layer];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    @try {
        NSString *type = am_str(layer, @"layerType") ?:
                          am_str(layer, @"type") ?: @"shape";
        NSInteger lid = am_int(layer, @"id");
        NSString *label = amproj_escapeXML(am_str(layer, @"label") ?: @"", YES);
        NSInteger st = am_int(layer, @"startTime");
        NSInteger et = am_int(layer, @"endTime");
        NSInteger parent = am_int(layer, @"parent");
        BOOL hidden = [am_get(layer, @"hidden") boolValue];

        NSString *tag = amproj_tagForType(type);
        NSMutableString *l = [NSMutableString string];
        [l appendFormat:@"<%@ id=\"%ld\" label=\"%@\" startTime=\"%ld\" endTime=\"%ld\"",
                         tag, (long)lid, label, (long)st, (long)et];
        if (parent) [l appendFormat:@" parent=\"%ld\"", (long)parent];
        if (hidden) [l appendString:@" hidden=\"true\""];

        NSString *fillType = am_str(layer, @"fillType");
        if (fillType) [l appendFormat:@" fillType=\"%@\"", amproj_escapeXML(fillType, YES)];
        NSString *blending = am_str(layer, @"blending");
        if (blending) [l appendFormat:@" blending=\"%@\"", amproj_escapeXML(blending, YES)];

        // shape specific
        NSString *shapeType = am_str(layer, @"shapeType") ?: am_str(layer, @"s");
        if (shapeType) [l appendFormat:@" s=\"%@\"", amproj_escapeXML(shapeType, YES)];
        CGFloat speed = am_flt(layer, @"speed");
        if (speed > 0 && speed != 1.0) [l appendFormat:@" speed=\"%g\"", speed];

        // text specific
        NSString *font = am_str(layer, @"font");
        if (font) [l appendFormat:@" font=\"%@\"", amproj_escapeXML(font, YES)];
        CGFloat fontSize = am_flt(layer, @"size");
        if (fontSize > 0) [l appendFormat:@" size=\"%g\"", fontSize];
        NSString *align = am_str(layer, @"align");
        if (align) [l appendFormat:@" align=\"%@\"", amproj_escapeXML(align, YES)];
        CGFloat wrap = am_flt(layer, @"wrapWidth");
        if (wrap > 0) [l appendFormat:@" wrapWidth=\"%g\"", wrap];

        [l appendString:@">\n"];

        // transform
        id xf = am_get(layer, @"transform");
        if (xf) {
            [l appendString:@"<transform>\n"];
            NSString *loc = am_str(xf, @"locationValue") ?: am_str(xf, @"location");
            if (loc) [l appendFormat:@"<location value=\"%@\" />\n", amproj_escapeXML(loc, YES)];
            NSString *piv = am_str(xf, @"pivotValue") ?: am_str(xf, @"pivot");
            if (piv) [l appendFormat:@"<pivot value=\"%@\" />\n", amproj_escapeXML(piv, YES)];
            CGFloat rot = am_flt(xf, @"rotation") ?: am_flt(xf, @"rotationValue");
            [l appendFormat:@"<rotation value=\"%g\" />\n", rot];
            NSString *scl = am_str(xf, @"scaleValue") ?: am_str(xf, @"scale");
            [l appendFormat:@"<scale value=\"%@\" />\n", amproj_escapeXML(scl ?: @"1.0,1.0", YES)];
            CGFloat op = am_flt(xf, @"opacity") ?: am_flt(xf, @"opacityValue") ?: 1.0;
            [l appendFormat:@"<opacity value=\"%g\" />\n", op];
            [l appendString:@"</transform>\n"];
        }

        // fillColor
        NSString *fc = am_str(layer, @"fillColor");
        if (fc) [l appendFormat:@"<fillColor value=\"%@\" />\n", amproj_escapeXML(fc, YES)];

        // content (text)
        NSString *content = am_str(layer, @"content");
        if (content) [l appendFormat:@"<content>%@</content>\n", amproj_escapeXML(content, NO)];

        // effects
        NSArray *effects = am_arr(layer, @"effects");
        if (effects) {
            for (id eff in effects) {
                NSString *eid = am_str(eff, @"id") ?: am_str(eff, @"effectId") ?: @"";
                BOOL local = [am_get(eff, @"locallyApplied") boolValue];
                [l appendFormat:@"<effect id=\"%@\"%@>\n", amproj_escapeXML(eid, YES), local ? @" locallyApplied=\"true\"" : @""];
                NSArray *props = am_arr(eff, @"properties");
                for (id p in props) {
                    [l appendFormat:@"<property name=\"%@\" type=\"%@\" value=\"%@\" />\n",
                        amproj_escapeXML(am_str(p, @"name") ?: @"", YES),
                        amproj_escapeXML(am_str(p, @"type") ?: am_str(p,@"propType") ?: @"float", YES),
                        amproj_escapeXML(am_str(p, @"value") ?: @"", YES)];
                }
                [l appendString:@"</effect>\n"];
            }
        }

        // path
        NSString *pathD = am_str(layer, @"pathData") ?: am_str(layer, @"d");
        if (pathD) [l appendFormat:@"<path d=\"%@\" />\n", amproj_escapeXML(pathD, YES)];

        // gradient
        id grad = am_get(layer, @"gradient");
        if (grad) {
            [l appendFormat:@"<gradient type=\"%@\" startColor=\"%@\" endColor=\"%@\" />\n",
                amproj_escapeXML(am_str(grad, @"gradientType") ?: @"linear", YES),
                amproj_escapeXML(am_str(grad, @"startColor") ?: @"#ff000000", YES),
                amproj_escapeXML(am_str(grad, @"endColor") ?: @"#ffffffff", YES)];
        }

        // stroke
        id stroke = am_get(layer, @"stroke") ?: am_get(layer, @"pathStroke");
        if (stroke) {
            [l appendFormat:@"<path-stroke direction=\"%@\">",
                amproj_escapeXML(am_str(stroke, @"direction") ?: @"center", YES)];
            NSString *sc = am_str(stroke, @"colorValue") ?: am_str(stroke, @"color");
            if (sc) [l appendFormat:@"<color value=\"%@\" />", amproj_escapeXML(sc, YES)];
            [l appendString:@"</path-stroke>\n"];
        }

        // nested scene
        if ([tag isEqualToString:@"embedScene"]) {
            id nested = am_get(layer, @"scene");
            if (nested) {
                NSData *nx = amproj_buildXMLInternal(nested, visited, depth + 1, NO);
                if (nx) [l appendString:[[NSString alloc] initWithData:nx encoding:NSUTF8StringEncoding]];
            }
        }

        [l appendFormat:@"</%@>\n", tag];
        [visited removeObject:identity];
        return l;
    } @catch (NSException *e) {
        [visited removeObject:identity];
        NSLog(@"[AMProjExport] Layer serialize error: %@", e);
        return nil;
    }
}

static NSString* amproj_tagForType(NSString *type) {
    static NSDictionary *map;
    if (!map) map = @{
        @"shape":@"shape", @"text":@"text", @"image":@"image",
        @"video":@"video", @"audio":@"audio", @"camera":@"camera",
        @"nullobj":@"nullobj", @"null":@"nullobj",
        @"embedScene":@"embedScene", @"group":@"embedScene",
        @"bookmark":@"bookmark"
    };
    return map[type] ?: @"shape";
}

static NSData* amproj_placeholderXML(void) {
    return [@"<?xml version='1.0' encoding='UTF-8' ?>\n"
            @"<scene title=\"Exported Project\" width=\"1280\" height=\"720\" "
            @"exportWidth=\"1280\" exportHeight=\"720\" "
            @"fps=\"60\" totalTime=\"5000\" bgcolor=\"#ff000000\">\n"
            @"</scene>\n" dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *const AMProjDirectErrorDomain = @"com.amproj.export.direct";
static NSString *const AMProjUTI = @"com.alightcreative.motion.amproj";

@interface AMProjXMLProbe : NSObject <NSXMLParserDelegate>
@property(nonatomic) BOOL validRoot;
@property(nonatomic) BOOL sawRootElement;
@property(nonatomic) NSUInteger depth;
@property(nonatomic) NSUInteger rootDepth;
@property(nonatomic) NSUInteger layerCount;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *resourceReferences;
@property(nonatomic, strong) NSError *parseError;
@end

@implementation AMProjXMLProbe

- (instancetype)init {
    self = [super init];
    if (self) _resourceReferences = [NSMutableOrderedSet orderedSet];
    return self;
}

- (void)parser:(NSXMLParser *)parser
 didStartElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qualifiedName
      attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    (void)parser;
    (void)namespaceURI;
    (void)qualifiedName;
    if (!self.sawRootElement) {
        self.sawRootElement = YES;
        self.validRoot = [elementName isEqualToString:@"scene"];
        self.rootDepth = self.depth;
        if (self.validRoot) {
            self.title = attributes[@"title"] ?: @"";
            self.width = [attributes[@"width"] integerValue];
            self.height = [attributes[@"height"] integerValue];
        }
    } else if (self.depth == self.rootDepth + 1) {
        static NSSet<NSString *> *layerElements;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            layerElements = [NSSet setWithArray:@[
                @"shape", @"text", @"image", @"video", @"audio", @"camera",
                @"nullobj", @"embedScene", @"bookmark"
            ]];
        });
        if ([layerElements containsObject:elementName]) self.layerCount++;
    }

    static NSSet<NSString *> *resourceKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resourceKeys = [NSSet setWithArray:@[
            @"uri", @"source", @"src", @"fillImage", @"fillVideo", @"font", @"file"
        ]];
    });
    [attributes enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        if (![resourceKeys containsObject:key] || !value.length) return;
        NSString *extension = value.pathExtension.lowercaseString;
        static NSSet<NSString *> *resourceExtensions;
        static dispatch_once_t extensionsOnce;
        dispatch_once(&extensionsOnce, ^{
            resourceExtensions = [NSSet setWithArray:@[
                @"png", @"jpg", @"jpeg", @"webp", @"gif", @"heic",
                @"mp4", @"mov", @"m4v", @"mp3", @"m4a", @"wav", @"aac",
                @"ttf", @"otf"
            ]];
        });
        NSString *scheme = [NSURLComponents componentsWithString:value].scheme.lowercaseString;
        if ([value hasPrefix:@"file://"] || [value hasPrefix:@"/"] ||
            [value hasPrefix:@"amproj:"] || [scheme hasPrefix:@"phasset-"] ||
            amproj_importedFontFilename(value).length ||
            [resourceExtensions containsObject:extension]) {
            [self.resourceReferences addObject:value];
        }
    }];
    self.depth++;
}

- (void)parser:(NSXMLParser *)parser
   didEndElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qualifiedName {
    (void)parser;
    (void)elementName;
    (void)namespaceURI;
    (void)qualifiedName;
    if (self.depth) self.depth--;
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    (void)parser;
    self.parseError = parseError;
}

@end

static NSError* amproj_directError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AMProjDirectErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown export error"}];
}

static AMProjXMLProbe* amproj_probeXML(NSData *xmlData) {
    if (!xmlData.length) return nil;
    AMProjXMLProbe *probe = [AMProjXMLProbe new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xmlData];
    parser.delegate = probe;
    BOOL parsed = [parser parse];
    return parsed && probe.validRoot && !probe.parseError ? probe : nil;
}

static BOOL amproj_dataStartsWithBytes(const uint8_t *bytes, NSUInteger length,
                                       const uint8_t *signature,
                                       NSUInteger signatureLength) {
    return bytes && signature && length >= signatureLength &&
        memcmp(bytes, signature, signatureLength) == 0;
}

// Encryption output is intentionally classified only when it is clearly a
// binary, high-entropy payload. Text encodings (including base64/hex), other
// XML documents, and known archive/media formats must continue through the
// normal invalid-XML path so that this guard cannot mislabel user files.
static BOOL amproj_isLikelyEncryptedXML(NSData *data,
                                        NSDictionary **signalOut) {
    if (signalOut) *signalOut = nil;
    if (![data isKindOfClass:NSData.class] || data.length < 32) return NO;

    const uint8_t *bytes = data.bytes;
    const NSUInteger length = data.length;
    static const uint8_t zipLocal[] = {0x50, 0x4b, 0x03, 0x04};
    static const uint8_t zipEmpty[] = {0x50, 0x4b, 0x05, 0x06};
    static const uint8_t zipSpanned[] = {0x50, 0x4b, 0x07, 0x08};
    static const uint8_t gzip[] = {0x1f, 0x8b};
    static const uint8_t sevenZip[] = {0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c};
    static const uint8_t rar[] = {0x52, 0x61, 0x72, 0x21};
    static const uint8_t xz[] = {0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00};
    static const uint8_t bplist[] = {0x62, 0x70, 0x6c, 0x69, 0x73, 0x74};
    static const uint8_t png[] = {0x89, 0x50, 0x4e, 0x47};
    static const uint8_t jpeg[] = {0xff, 0xd8, 0xff};
    static const uint8_t gif[] = {0x47, 0x49, 0x46, 0x38};
    static const uint8_t pdf[] = {0x25, 0x50, 0x44, 0x46};
    if (amproj_dataStartsWithBytes(bytes, length, zipLocal, sizeof(zipLocal)) ||
        amproj_dataStartsWithBytes(bytes, length, zipEmpty, sizeof(zipEmpty)) ||
        amproj_dataStartsWithBytes(bytes, length, zipSpanned, sizeof(zipSpanned)) ||
        amproj_dataStartsWithBytes(bytes, length, gzip, sizeof(gzip)) ||
        amproj_dataStartsWithBytes(bytes, length, sevenZip, sizeof(sevenZip)) ||
        amproj_dataStartsWithBytes(bytes, length, rar, sizeof(rar)) ||
        amproj_dataStartsWithBytes(bytes, length, xz, sizeof(xz)) ||
        amproj_dataStartsWithBytes(bytes, length, bplist, sizeof(bplist)) ||
        amproj_dataStartsWithBytes(bytes, length, png, sizeof(png)) ||
        amproj_dataStartsWithBytes(bytes, length, jpeg, sizeof(jpeg)) ||
        amproj_dataStartsWithBytes(bytes, length, gif, sizeof(gif)) ||
        amproj_dataStartsWithBytes(bytes, length, pdf, sizeof(pdf))) {
        return NO;
    }

    // A BOM identifies a text encoding. The alternating-NUL check also keeps
    // BOM-less UTF-16/UTF-32 XML out of the binary classifier.
    if ((length >= 2 && ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
                         (bytes[0] == 0xfe && bytes[1] == 0xff))) ||
        (length >= 4 && ((bytes[0] == 0x00 && bytes[1] == 0x00 &&
                          bytes[2] == 0xfe && bytes[3] == 0xff) ||
                         (bytes[0] == 0xff && bytes[1] == 0xfe &&
                          bytes[2] == 0x00 && bytes[3] == 0x00)))) {
        return NO;
    }

    NSString *utf8 = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
    NSString *trimmed = [utf8 stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        unichar first = [trimmed characterAtIndex:0];
        // XML, JSON, and HTML (including truncated documents) are text input,
        // even when their syntax is invalid and amproj_probeXML rejects them.
        if (first == '<' || first == '{' || first == '[') return NO;

        BOOL onlyBase64 = YES;
        BOOL onlyHex = YES;
        NSUInteger significant = 0;
        for (NSUInteger index = 0; index < trimmed.length; index++) {
            unichar character = [trimmed characterAtIndex:index];
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet]
                    characterIsMember:character]) continue;
            significant++;
            BOOL base64 = (character >= 'A' && character <= 'Z') ||
                (character >= 'a' && character <= 'z') ||
                (character >= '0' && character <= '9') ||
                character == '+' || character == '/' || character == '=';
            BOOL hex = (character >= '0' && character <= '9') ||
                (character >= 'a' && character <= 'f') ||
                (character >= 'A' && character <= 'F');
            if (!base64) onlyBase64 = NO;
            if (!hex) onlyHex = NO;
        }
        if (significant >= 32 && (onlyBase64 || (onlyHex && (significant % 2) == 0))) {
            return NO;
        }
    }

    const NSUInteger sampleLength = MIN(length, (NSUInteger)65536);
    NSUInteger counts[256] = {0};
    NSUInteger nonText = 0;
    NSUInteger nulCount = 0;
    for (NSUInteger index = 0; index < sampleLength; index++) {
        uint8_t value = bytes[index];
        counts[value]++;
        if (value == 0) nulCount++;
        BOOL printable = (value == '\t' || value == '\n' || value == '\r' ||
                          (value >= 0x20 && value <= 0x7e));
        if (!printable) nonText++;
    }

    // Repeated and UTF-16-like payloads are not ciphertext.
    if (nulCount > sampleLength / 4) return NO;
    NSUInteger unique = 0;
    for (NSUInteger index = 0; index < 256; index++) {
        if (counts[index]) unique++;
    }
    if (unique <= 2) return NO;

    double entropy = 0.0;
    for (NSUInteger index = 0; index < 256; index++) {
        if (!counts[index]) continue;
        double probability = (double)counts[index] / (double)sampleLength;
        entropy -= probability * log2(probability);
    }
    double nonTextRatio = (double)nonText / (double)sampleLength;
    if (entropy < 5.5 || nonTextRatio < 0.20) return NO;

    if (signalOut) {
        *signalOut = @{
            @"category": @"binary_high_entropy",
            @"sample_bytes": @(sampleLength),
            @"unique_bytes": @(unique),
            @"entropy": @(entropy),
            @"nontext_ratio": @(nonTextRatio),
            @"nul_bytes": @(nulCount)
        };
    }
    return YES;
}

static NSString* amproj_normalizedProjectTitle(NSString *title) {
    NSString *value = [title ?: @"" stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *suffixes = [NSCharacterSet characterSetWithCharactersInString:@"-–—"];
    while (value.length && [suffixes characterIsMember:[value characterAtIndex:value.length - 1]]) {
        value = [[value substringToIndex:value.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return value;
}

static BOOL amproj_shouldTraverseObject(id object) {
    if (!object || object == NSNull.null) return NO;
    if ([object isKindOfClass:NSString.class] || [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSData.class] || [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSValue.class] || [object isKindOfClass:UIImage.class] ||
        [object isKindOfClass:UIColor.class]) return NO;
    return YES;
}

static id amproj_findObjectByClassRecursive(id object, NSString *classFragment,
                                             NSUInteger depth,
                                             NSMutableSet<NSValue *> *visited) {
    if (!amproj_shouldTraverseObject(object) || depth > 7 || visited.count > 1024) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if ([NSStringFromClass([object class]) containsString:classFragment]) return object;

    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class]) {
        NSArray *objects = [object isKindOfClass:NSArray.class] ? object : [(NSSet *)object allObjects];
        for (id value in objects) {
            id found = amproj_findObjectByClassRecursive(value, classFragment, depth + 1, visited);
            if (found) return found;
        }
        return nil;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)object allValues]) {
            id found = amproj_findObjectByClassRecursive(value, classFragment, depth + 1, visited);
            if (found) return found;
        }
        return nil;
    }

    for (Class cls = [object class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@') continue;
            id value = object_getIvar(object, ivars[index]);
            id found = amproj_findObjectByClassRecursive(value, classFragment, depth + 1, visited);
            if (found) {
                free(ivars);
                return found;
            }
        }
        free(ivars);
    }
    return nil;
}

static id amproj_findObjectByClass(NSArray *roots, NSString *classFragment) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (id root in roots) {
        id found = amproj_findObjectByClassRecursive(root, classFragment, 0, visited);
        if (found) return found;
    }
    return nil;
}

static void amproj_addPathCandidate(id value, NSMutableOrderedSet<NSURL *> *candidates) {
    NSURL *URL = nil;
    if ([value isKindOfClass:NSURL.class]) {
        URL = value;
    } else if ([value isKindOfClass:NSString.class] && [value length]) {
        NSString *string = value;
        URL = [string hasPrefix:@"file://"] ? [NSURL URLWithString:string] :
            ([string hasPrefix:@"/"] ? [NSURL fileURLWithPath:string] : nil);
    }
    if (URL.isFileURL) {
        NSURL *standard = URL.URLByStandardizingPath;
        NSString *home = [[NSURL fileURLWithPath:NSHomeDirectory()] URLByStandardizingPath].path;
        if ([standard.path hasPrefix:home]) [candidates addObject:standard];
    }
}

static void amproj_collectPathCandidatesRecursive(id object, NSUInteger depth,
                                                   NSMutableSet<NSValue *> *visited,
                                                   NSMutableOrderedSet<NSURL *> *candidates) {
    if (!object || depth > 6 || visited.count > 1024 || candidates.count > 512) return;
    amproj_addPathCandidate(object, candidates);
    if (!amproj_shouldTraverseObject(object)) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)object];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    if ([object isKindOfClass:NSArray.class] || [object isKindOfClass:NSSet.class]) {
        NSArray *objects = [object isKindOfClass:NSArray.class] ? object : [(NSSet *)object allObjects];
        for (id value in objects) {
            amproj_collectPathCandidatesRecursive(value, depth + 1, visited, candidates);
        }
        return;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id value in [(NSDictionary *)object allValues]) {
            amproj_collectPathCandidatesRecursive(value, depth + 1, visited, candidates);
        }
        return;
    }

    for (Class cls = [object class]; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (!type || type[0] != '@') continue;
            NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[index]) ?: ""];
            NSString *lower = name.lowercaseString;
            id value = object_getIvar(object, ivars[index]);
            if ([lower containsString:@"url"] || [lower containsString:@"path"] ||
                [lower containsString:@"file"] || [lower containsString:@"project"] ||
                [lower containsString:@"holder"] || [lower containsString:@"scene"] ||
                [lower containsString:@"model"]) {
                amproj_collectPathCandidatesRecursive(value, depth + 1, visited, candidates);
            }
        }
        free(ivars);
    }
}

static NSArray<NSURL *>* amproj_collectPathCandidates(NSArray *roots) {
    NSMutableOrderedSet<NSURL *> *candidates = [NSMutableOrderedSet orderedSet];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSNumber *directory in @[@(NSApplicationSupportDirectory),
                                   @(NSDocumentDirectory), @(NSLibraryDirectory)]) {
        NSURL *URL = [manager URLsForDirectory:directory.unsignedIntegerValue
                                      inDomains:NSUserDomainMask].firstObject;
        if (URL) [candidates addObject:URL];
    }
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (id root in roots) {
        amproj_collectPathCandidatesRecursive(root, 0, visited, candidates);
    }
    return candidates.array;
}

static NSArray<NSURL *>* amproj_expandXMLCandidates(NSArray<NSURL *> *roots) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableOrderedSet<NSURL *> *results = [NSMutableOrderedSet orderedSet];
    NSUInteger inspected = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
    for (NSURL *root in roots) {
        if (inspected >= 10000 || [deadline timeIntervalSinceNow] <= 0) break;
        NSNumber *directory = nil;
        [root getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (!directory.boolValue) {
            if ([root.pathExtension.lowercaseString isEqualToString:@"xml"] &&
                [manager fileExistsAtPath:root.path]) [results addObject:root];
            continue;
        }
        NSArray<NSURL *> *topLevel = [manager contentsOfDirectoryAtURL:root
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLContentModificationDateKey]
                               options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *URL in topLevel) {
            inspected++;
            if (inspected >= 10000 || results.count >= 2048 ||
                [deadline timeIntervalSinceNow] <= 0) break;
            if ([URL.pathExtension.lowercaseString isEqualToString:@"xml"]) [results addObject:URL];
        }
        NSDirectoryEnumerator<NSURL *> *enumerator = [manager enumeratorAtURL:root
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsDirectoryKey,
                                         NSURLFileSizeKey, NSURLContentModificationDateKey]
                               options:(NSDirectoryEnumerationSkipsHiddenFiles |
                                        NSDirectoryEnumerationSkipsPackageDescendants)
                          errorHandler:^BOOL(NSURL *URL, NSError *error) {
            (void)URL;
            (void)error;
            return YES;
        }];
        for (NSURL *URL in enumerator) {
            inspected++;
            if (inspected >= 10000 || results.count >= 2048 ||
                [deadline timeIntervalSinceNow] <= 0) break;
            NSNumber *isDirectory = nil;
            [URL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if (isDirectory.boolValue &&
                [URL.lastPathComponent caseInsensitiveCompare:@"Caches"] == NSOrderedSame) {
                [enumerator skipDescendants];
                continue;
            }
            if ([URL.pathExtension.lowercaseString isEqualToString:@"xml"]) [results addObject:URL];
        }
    }
    return results.array;
}

static NSDictionary* amproj_selectNativeXML(NSArray<NSURL *> *roots, NSDictionary *expected) {
    NSDictionary *best = nil;
    NSInteger bestScore = NSIntegerMin;
    NSTimeInterval bestModified = -DBL_MAX;
    BOOL ambiguous = NO;
    NSUInteger validCount = 0;
    NSUInteger eligibleCount = 0;
    NSArray<NSURL *> *candidates = amproj_expandXMLCandidates(roots);
    for (NSURL *URL in candidates) {
        NSNumber *size = nil;
        NSDate *modified = nil;
        [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [URL getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (!size || size.unsignedLongLongValue < 64 || size.unsignedLongLongValue > 64 * 1024 * 1024) continue;
        NSData *data = [NSData dataWithContentsOfURL:URL options:NSDataReadingMappedIfSafe error:nil];
        AMProjXMLProbe *probe = amproj_probeXML(data);
        if (!probe || probe.width <= 0 || probe.height <= 0) continue;
        validCount++;

        NSInteger expectedWidth = [expected[@"width"] integerValue];
        NSInteger expectedHeight = [expected[@"height"] integerValue];
        NSUInteger expectedLayers = [expected[@"layers"] unsignedIntegerValue];
        BOOL layersKnown = [expected[@"layers_known"] boolValue];
        if (expectedWidth > 0 && expectedWidth != probe.width) continue;
        if (expectedHeight > 0 && expectedHeight != probe.height) continue;
        if (layersKnown && probe.layerCount != expectedLayers) continue;

        NSString *expectedTitle = expected[@"title"];
        NSString *normalizedExpectedTitle = amproj_normalizedProjectTitle(expectedTitle);
        NSString *normalizedProbeTitle = amproj_normalizedProjectTitle(probe.title);
        BOOL titleMatches = normalizedExpectedTitle.length &&
            [normalizedProbeTitle isEqualToString:normalizedExpectedTitle];
        NSDate *saveStarted = expected[@"save_started"];
        BOOL modifiedForSave = modified && saveStarted &&
            [modified timeIntervalSinceDate:saveStarted] > -5.0;
        if (!titleMatches && !modifiedForSave) continue;
        eligibleCount++;

        NSInteger score = 1;
        if (titleMatches) score += 16;
        if (expectedWidth > 0 && expectedWidth == probe.width) score += 4;
        if (expectedHeight > 0 && expectedHeight == probe.height) score += 4;
        if (layersKnown && expectedLayers == probe.layerCount) score += 8;
        if (modifiedForSave) score += 32;
        NSTimeInterval modifiedTime = modified ? modified.timeIntervalSince1970 : -DBL_MAX;
        if (!best || score > bestScore ||
            (score == bestScore && modifiedTime > bestModified + 1.0)) {
            bestScore = score;
            bestModified = modifiedTime;
            ambiguous = NO;
            best = @{@"data": data, @"url": URL, @"probe": probe,
                      @"modified": modified ?: NSDate.distantPast, @"score": @(score)};
        } else if (score == bestScore && fabs(modifiedTime - bestModified) <= 1.0) {
            ambiguous = YES;
        }
    }
    amproj_debugEvent(@"direct.native_xml_candidates", @{
        @"scanned": @(candidates.count),
        @"valid": @(validCount),
        @"eligible": @(eligibleCount),
        @"ambiguous": @(ambiguous)
    });
    return ambiguous ? nil : best;
}

static NSString* amproj_safeFilename(NSString *value, NSString *fallback) {
    NSString *name = value.stringByDeletingPathExtension;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|\r\n\t"];
    NSArray<NSString *> *parts = [name componentsSeparatedByCharactersInSet:invalid];
    name = [parts componentsJoinedByString:@"_"];
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) name = fallback ?: @"AlightMotion_Project";
    if (name.length > 80) name = [name substringToIndex:80];
    return name;
}

static NSString* amproj_photoAssetIdentifier(NSString *reference) {
    NSURLComponents *components = [NSURLComponents componentsWithString:reference];
    NSString *scheme = components.scheme.lowercaseString;
    if (![scheme hasPrefix:@"phasset-"]) return nil;
    NSMutableString *identifier = [NSMutableString string];
    if (components.host.length) [identifier appendString:components.host];
    NSString *path = components.path ?: @"";
    if (components.host.length && path.length) {
        [identifier appendString:path];
    } else if (path.length) {
        [identifier appendString:[path hasPrefix:@"//"] ? [path substringFromIndex:2] : path];
    }
    while ([identifier hasPrefix:@"/"]) [identifier deleteCharactersInRange:NSMakeRange(0, 1)];
    return identifier.stringByRemovingPercentEncoding ?: identifier;
}

static PHAssetResource* amproj_photoAssetResource(PHAsset *asset, NSString *scheme) {
    NSArray<PHAssetResource *> *resources = [PHAssetResource assetResourcesForAsset:asset];
    for (PHAssetResource *resource in resources) {
        if ([scheme isEqualToString:@"phasset-image"] &&
            (resource.type == PHAssetResourceTypePhoto ||
             resource.type == PHAssetResourceTypeFullSizePhoto)) return resource;
        if ([scheme isEqualToString:@"phasset-video"] &&
            (resource.type == PHAssetResourceTypeVideo ||
             resource.type == PHAssetResourceTypeFullSizeVideo)) return resource;
        if ([scheme isEqualToString:@"phasset-audio"] &&
            resource.type == PHAssetResourceTypeAudio) return resource;
    }
    return resources.firstObject;
}

static NSURL* amproj_exportPhotoAsset(NSString *reference) {
    NSString *identifier = amproj_photoAssetIdentifier(reference);
    NSString *scheme = [NSURLComponents componentsWithString:reference].scheme.lowercaseString;
    if (!identifier.length) return nil;
    PHAsset *asset = [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil].firstObject;
    if (!asset) {
        amproj_debugEvent(@"direct.phasset", @{
            @"scheme": scheme ?: @"",
            @"found": @NO,
            @"reason": @"asset_not_found"
        });
        return nil;
    }
    PHAssetResource *resource = amproj_photoAssetResource(asset, scheme);
    if (!resource) return nil;
    NSURL *directory = [[amproj_directExportRoot()
        URLByAppendingPathComponent:@"Resolved" isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                withIntermediateDirectories:YES attributes:nil
                                                     error:&directoryError]) return nil;
    NSString *filename = resource.originalFilename.lastPathComponent;
    if (!filename.length) filename = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"bin"];
    NSURL *outputURL = [directory URLByAppendingPathComponent:filename];
    PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new];
    options.networkAccessAllowed = YES;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *writeError = nil;
    [[PHAssetResourceManager defaultManager] writeDataForAssetResource:resource
        toFile:outputURL options:options completionHandler:^(NSError *error) {
            writeError = error;
            dispatch_semaphore_signal(semaphore);
        }];
    long waitResult = dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:outputURL.path];
    amproj_debugEvent(@"direct.phasset", @{
        @"scheme": scheme ?: @"",
        @"found": @(exists && waitResult == 0 && !writeError),
        @"filename": filename,
        @"error": writeError.localizedDescription ?: (waitResult ? @"timeout" : @"")
    });
    return exists && waitResult == 0 && !writeError ? outputURL : nil;
}

static BOOL amproj_pathIsWithinDirectory(NSString *path, NSString *directory) {
    if (!path.length || !directory.length) return NO;
    if ([path isEqualToString:directory]) return YES;
    NSString *prefix = [directory hasSuffix:@"/"] ? directory :
        [directory stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static NSURL* amproj_canonicalSandboxURL(NSURL *URL, BOOL requireRegularFile) {
    if (!URL.isFileURL || !URL.path.length) return nil;
    NSString *home = NSHomeDirectory().stringByStandardizingPath.stringByResolvingSymlinksInPath;
    NSString *path = URL.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (!amproj_pathIsWithinDirectory(path, home)) return nil;
    struct stat information = {0};
    if (stat(path.fileSystemRepresentation, &information) != 0) return nil;
    if (requireRegularFile ? !S_ISREG(information.st_mode) : !S_ISDIR(information.st_mode)) return nil;
    return [NSURL fileURLWithPath:path isDirectory:!requireRegularFile];
}

static NSString* amproj_fileIdentity(NSURL *URL) {
    struct stat information = {0};
    if (stat(URL.path.fileSystemRepresentation, &information) != 0) return nil;
    return [NSString stringWithFormat:@"%llu:%llu",
        (unsigned long long)information.st_dev, (unsigned long long)information.st_ino];
}

static NSString* amproj_SHA1ForFileURL(NSURL *URL) {
    int descriptor = open(URL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return nil;
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    uint8_t buffer[64 * 1024];
    BOOL success = YES;
    while (YES) {
        ssize_t amount = read(descriptor, buffer, sizeof(buffer));
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0) {
            success = NO;
            break;
        }
        if (amount == 0) break;
        CC_SHA1_Update(&context, buffer, (CC_LONG)amount);
    }
    close(descriptor);
    if (!success) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    static const char digits[] = "0123456789ABCDEF";
    char hex[CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) {
        hex[index * 2] = digits[digest[index] >> 4];
        hex[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    return [[NSString alloc] initWithBytes:hex length:sizeof(hex)
                                  encoding:NSASCIIStringEncoding];
}

static NSString* amproj_expectedInternalSHA1(NSString *filename) {
    NSString *stem = filename.stringByDeletingPathExtension;
    if (stem.length != CC_SHA1_DIGEST_LENGTH * 2) return nil;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefABCDEF"];
    if ([stem rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) return nil;
    return stem.uppercaseString;
}

static NSURL* amproj_internalResourceCacheRoot(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    if (!caches) return nil;
    return [[caches URLByAppendingPathComponent:@"AMProjExport" isDirectory:YES]
        URLByAppendingPathComponent:@"InternalResources" isDirectory:YES];
}

static NSObject* amproj_internalResourceCacheLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static void amproj_purgeInternalResourceCache(void) {
    @synchronized (amproj_internalResourceCacheLock()) {
        NSURL *directory = amproj_internalResourceCacheRoot();
        if (!directory) return;
        NSFileManager *manager = NSFileManager.defaultManager;
        NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:directory
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey,
                                         NSURLContentModificationDateKey]
                               options:0 error:nil];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-(7 * 24 * 60 * 60)];
        NSMutableArray<NSDictionary *> *survivors = [NSMutableArray array];
        unsigned long long totalBytes = 0;
        for (NSURL *URL in entries) {
            NSNumber *regular = nil;
            NSNumber *size = nil;
            NSDate *modified = nil;
            [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [URL getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
            BOOL partial = [URL.lastPathComponent hasSuffix:@".partial"];
            if (!regular.boolValue || partial || !modified ||
                [modified compare:cutoff] == NSOrderedAscending) {
                if (regular.boolValue) [manager removeItemAtURL:URL error:nil];
                continue;
            }
            unsigned long long bytes = size.unsignedLongLongValue;
            totalBytes += bytes;
            [survivors addObject:@{@"url": URL, @"modified": modified, @"bytes": @(bytes)}];
        }
        const unsigned long long maximumBytes = 2ULL * 1024ULL * 1024ULL * 1024ULL;
        if (totalBytes <= maximumBytes) return;
        [survivors sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                           NSDictionary *right) {
            return [left[@"modified"] compare:right[@"modified"]];
        }];
        for (NSDictionary *entry in survivors) {
            if (totalBytes <= maximumBytes) break;
            NSURL *URL = entry[@"url"];
            unsigned long long bytes = [entry[@"bytes"] unsignedLongLongValue];
            if ([manager removeItemAtURL:URL error:nil]) {
                totalBytes = bytes > totalBytes ? 0 : totalBytes - bytes;
            }
        }
    }
}

static NSURL* amproj_cacheInternalResource(NSURL *source, NSString *filename,
                                           NSString *verifiedSHA1) {
    if (!source.isFileURL || !filename.length || !verifiedSHA1.length) return source;
    @synchronized (amproj_internalResourceCacheLock()) {
        NSURL *directory = amproj_internalResourceCacheRoot();
        if (!directory) return source;
        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                    withIntermediateDirectories:YES attributes:nil
                                                         error:&directoryError]) return source;
        NSURL *destination = [directory URLByAppendingPathComponent:filename isDirectory:NO];
        NSString *destinationSHA1 = amproj_SHA1ForFileURL(destination);
        if ([destinationSHA1 isEqualToString:verifiedSHA1]) {
            [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date}
                                           ofItemAtPath:destination.path error:nil];
            return destination;
        }

        NSURL *temporary = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@".%@.%@.partial", filename, NSUUID.UUID.UUIDString]
                                                   isDirectory:NO];
        NSFileManager *manager = NSFileManager.defaultManager;
        NSError *copyError = nil;
        if (![manager copyItemAtURL:source toURL:temporary error:&copyError]) return source;
        NSString *temporarySHA1 = amproj_SHA1ForFileURL(temporary);
        if (![temporarySHA1 isEqualToString:verifiedSHA1]) {
            [manager removeItemAtURL:temporary error:nil];
            return source;
        }
        [manager removeItemAtURL:destination error:nil];
        NSError *moveError = nil;
        if (![manager moveItemAtURL:temporary toURL:destination error:&moveError]) {
            [manager removeItemAtURL:temporary error:nil];
            return source;
        }
        amproj_debugEvent(@"direct.am_internal_cache", @{
            @"filename": filename, @"cached": @YES
        });
        return destination;
    }
}

static NSString* amproj_internalResourceFilename(NSString *reference) {
    NSURLComponents *components = [NSURLComponents componentsWithString:reference];
    if (![components.scheme.lowercaseString isEqualToString:@"am-internal"] ||
        components.host.length || components.user.length || components.password.length ||
        components.port || components.query != nil || components.fragment != nil) return nil;
    NSString *path = components.percentEncodedPath.stringByRemovingPercentEncoding;
    while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
    if (!path.length || path.length > 255 || [path isEqualToString:@"."] ||
        [path isEqualToString:@".."] || [path containsString:@"/"] ||
        [path containsString:@"\\"] || !path.pathExtension.length ||
        [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        ![path.lastPathComponent isEqualToString:path]) return nil;
    return path;
}

static BOOL amproj_isSafeFlatResourceFilename(NSString *filename) {
    if (!filename.length || filename.length > 255 ||
        [filename isEqualToString:@"."] || [filename isEqualToString:@".."] ||
        [filename containsString:@"/"] || [filename containsString:@"\\"] ||
        [filename rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location !=
            NSNotFound ||
        ![filename.lastPathComponent isEqualToString:filename]) return NO;
    return YES;
}

// AM stores user-imported fonts as a relative URI such as
// `imported?name=Example.ttf`. It is not a filesystem path: the query value is
// the flat filename that must be resolved from AM's local font storage.
static NSString* amproj_importedFontFilename(NSString *reference) {
    if (!reference.length) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:reference];
    if (!components || components.scheme.length || components.host.length ||
        components.user.length || components.password.length || components.port ||
        components.fragment != nil) return nil;
    NSString *path = components.percentEncodedPath.stringByRemovingPercentEncoding;
    while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
    if (![path isEqualToString:@"imported"] || components.queryItems.count != 1) {
        return nil;
    }
    NSURLQueryItem *item = components.queryItems.firstObject;
    if (![item.name isEqualToString:@"name"] || !item.value.length) return nil;
    NSString *filename = item.value.stringByRemovingPercentEncoding ?: item.value;
    NSString *extension = filename.pathExtension.lowercaseString;
    if (!amproj_isSafeFlatResourceFilename(filename) ||
        !([extension isEqualToString:@"ttf"] || [extension isEqualToString:@"otf"])) {
        return nil;
    }
    return filename.precomposedStringWithCanonicalMapping;
}

static NSString* amproj_scannableResourceFilename(NSString *reference) {
    return amproj_internalResourceFilename(reference) ?:
        amproj_importedFontFilename(reference);
}

static NSString* amproj_resourceLookupEventName(NSString *reference) {
    return amproj_importedFontFilename(reference).length
        ? @"direct.font_resource" : @"direct.am_internal";
}

static NSDictionary<NSString *, NSURL *>* amproj_resolveInternalResources(
        NSArray<NSString *> *references, NSURL *XMLURL,
        NSDictionary<NSString *, NSString *> **failureReasons) {
    NSMutableDictionary<NSString *, NSString *> *failures = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *filenameByReference =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSURL *> *> *matchesByName =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSURL *> *> *fallbackByExtension =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *expectedByExtension =
        [NSMutableDictionary dictionary];
    for (NSString *reference in references) {
        NSString *filename = amproj_scannableResourceFilename(reference);
        if (!filename.length) {
            amproj_debugEvent(amproj_resourceLookupEventName(reference), @{
                @"filename": @"", @"found": @NO, @"match_count": @0,
                @"search_count": @0, @"truncated": @NO, @"search_complete": @YES,
                @"reason": @"invalid_reference"
            });
            failures[reference] = @"Internal resource URI is invalid";
            continue;
        }
        filenameByReference[reference] = filename;
        NSString *key = filename.lowercaseString;
        if (!matchesByName[key]) matchesByName[key] = [NSMutableDictionary dictionary];
        NSString *expectedSHA1 = amproj_expectedInternalSHA1(filename);
        NSString *extension = filename.pathExtension.lowercaseString;
        if (expectedSHA1 && extension.length) {
            if (!fallbackByExtension[extension]) {
                fallbackByExtension[extension] = [NSMutableDictionary dictionary];
                expectedByExtension[extension] = [NSMutableSet set];
            }
            [expectedByExtension[extension] addObject:expectedSHA1];
        }
    }
    if (!matchesByName.count) {
        if (failureReasons) *failureReasons = failures;
        return @{};
    }

    amproj_purgeInternalResourceCache();
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableOrderedSet<NSURL *> *roots = [NSMutableOrderedSet orderedSet];
    NSURL *XMLDirectory = XMLURL.URLByDeletingLastPathComponent;
    if (XMLDirectory) {
        [roots addObject:XMLDirectory];
        for (NSString *subdirectory in @[@"Media", @"Assets", @"Resources"]) {
            [roots addObject:[XMLDirectory URLByAppendingPathComponent:subdirectory isDirectory:YES]];
        }
    }
    for (NSNumber *directory in @[@(NSApplicationSupportDirectory),
                                   @(NSDocumentDirectory), @(NSLibraryDirectory)]) {
        NSURL *URL = [manager URLsForDirectory:directory.unsignedIntegerValue
                                      inDomains:NSUserDomainMask].firstObject;
        if (URL) [roots addObject:URL];
    }

    NSMutableSet<NSString *> *visitedPaths = [NSMutableSet set];
    const NSUInteger searchLimit = 50000;
    __block NSUInteger searchCount = 0;
    __block NSUInteger fallbackCandidateCount = 0;
    __block BOOL fallbackCandidatesTruncated = NO;
    BOOL truncated = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    void (^considerURL)(NSURL *) = ^(NSURL *URL) {
        if (!URL.path.length || [visitedPaths containsObject:URL.path]) return;
        [visitedPaths addObject:URL.path];
        searchCount++;
        NSMutableDictionary<NSString *, NSURL *> *matches =
            matchesByName[URL.lastPathComponent.lowercaseString];
        NSMutableDictionary<NSString *, NSURL *> *fallbacks =
            fallbackByExtension[URL.pathExtension.lowercaseString];
        if (!matches && !fallbacks) return;
        NSURL *match = amproj_canonicalSandboxURL(URL, YES);
        NSString *identity = match ? amproj_fileIdentity(match) : nil;
        if (identity) matches[identity] = match;
        if (identity && fallbacks && !fallbacks[identity]) {
            if (fallbackCandidateCount < 4096) {
                fallbacks[identity] = match;
                fallbackCandidateCount++;
            } else {
                fallbackCandidatesTruncated = YES;
            }
        }
    };

    for (NSURL *candidateRoot in roots) {
        if (searchCount >= searchLimit || [deadline timeIntervalSinceNow] <= 0) {
            truncated = YES;
            break;
        }
        NSURL *root = amproj_canonicalSandboxURL(candidateRoot, NO);
        NSString *rootPath = root.path;
        if (!rootPath.length || [visitedPaths containsObject:rootPath]) continue;
        [visitedPaths addObject:rootPath];
        for (NSString *filename in [NSSet setWithArray:filenameByReference.allValues]) {
            if (searchCount >= searchLimit || [deadline timeIntervalSinceNow] <= 0) {
                truncated = YES;
                break;
            }
            considerURL([root URLByAppendingPathComponent:filename isDirectory:NO]);
        }
        if (truncated) break;

        NSNumber *isDirectory = nil;
        [root getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue) continue;
        NSDirectoryEnumerator<NSURL *> *enumerator = [manager enumeratorAtURL:root
            includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey,
                                         NSURLIsSymbolicLinkKey]
                               options:0
                          errorHandler:^BOOL(NSURL *URL, NSError *error) {
            (void)URL;
            (void)error;
            return YES;
        }];
        for (NSURL *URL in enumerator) {
            if (searchCount >= searchLimit || [deadline timeIntervalSinceNow] <= 0) {
                truncated = YES;
                break;
            }
            NSNumber *symbolicLink = nil;
            [URL getResourceValue:&symbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (symbolicLink.boolValue) {
                [enumerator skipDescendants];
                continue;
            }
            NSString *path = URL.path.stringByStandardizingPath;
            if ([visitedPaths containsObject:path]) {
                NSNumber *directory = nil;
                [URL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
                if (directory.boolValue) [enumerator skipDescendants];
                continue;
            }
            considerURL(URL);
        }
        if (truncated) break;
    }

    NSMutableDictionary<NSString *, NSString *> *digestByIdentity = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSURL *> *matchByExpectedSHA1 = [NSMutableDictionary dictionary];
    __block NSUInteger contentHashFiles = 0;
    __block unsigned long long contentHashBytes = 0;

    for (NSString *filename in [NSSet setWithArray:filenameByReference.allValues]) {
        NSString *expectedSHA1 = amproj_expectedInternalSHA1(filename);
        if (!expectedSHA1) continue;
        NSDictionary<NSString *, NSURL *> *matches = matchesByName[filename.lowercaseString];
        [matches enumerateKeysAndObjectsUsingBlock:
            ^(NSString *identity, NSURL *URL, BOOL *stop) {
            if (matchByExpectedSHA1[expectedSHA1]) {
                *stop = YES;
                return;
            }
            NSString *digest = digestByIdentity[identity];
            if (!digest) {
                digest = amproj_SHA1ForFileURL(URL);
                if (digest) {
                    digestByIdentity[identity] = digest;
                    contentHashFiles++;
                    NSNumber *size = nil;
                    [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                    contentHashBytes += size.unsignedLongLongValue;
                }
            }
            if ([digest isEqualToString:expectedSHA1]) {
                matchByExpectedSHA1[expectedSHA1] = URL;
                *stop = YES;
            }
        }];
    }

    BOOL contentScanTruncated = fallbackCandidatesTruncated;
    const unsigned long long contentScanByteLimit = 1024ULL * 1024ULL * 1024ULL;
    NSDate *contentDeadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    for (NSString *extension in fallbackByExtension) {
        NSSet<NSString *> *expectedHashes = expectedByExtension[extension];
        BOOL needsMatch = NO;
        for (NSString *expectedSHA1 in expectedHashes) {
            if (!matchByExpectedSHA1[expectedSHA1]) {
                needsMatch = YES;
                break;
            }
        }
        if (!needsMatch) continue;

        NSDictionary<NSString *, NSURL *> *candidates = fallbackByExtension[extension];
        for (NSString *identity in candidates) {
            if ([contentDeadline timeIntervalSinceNow] <= 0) {
                contentScanTruncated = YES;
                break;
            }
            NSURL *URL = candidates[identity];
            NSString *digest = digestByIdentity[identity];
            if (!digest) {
                NSNumber *size = nil;
                [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                unsigned long long bytes = size.unsignedLongLongValue;
                if (bytes > contentScanByteLimit - MIN(contentHashBytes, contentScanByteLimit)) {
                    contentScanTruncated = YES;
                    continue;
                }
                digest = amproj_SHA1ForFileURL(URL);
                if (!digest) continue;
                digestByIdentity[identity] = digest;
                contentHashFiles++;
                contentHashBytes += bytes;
            }
            if ([expectedHashes containsObject:digest] && !matchByExpectedSHA1[digest]) {
                matchByExpectedSHA1[digest] = URL;
            }
            BOOL allMatched = YES;
            for (NSString *expectedSHA1 in expectedHashes) {
                if (!matchByExpectedSHA1[expectedSHA1]) {
                    allMatched = NO;
                    break;
                }
            }
            if (allMatched) break;
        }
    }

    NSMutableDictionary<NSString *, NSURL *> *resolved = [NSMutableDictionary dictionary];
    [filenameByReference enumerateKeysAndObjectsUsingBlock:
        ^(NSString *reference, NSString *filename, BOOL *stop) {
        (void)stop;
        NSDictionary<NSString *, NSURL *> *matches = matchesByName[filename.lowercaseString];
        NSURL *selected = nil;
        NSString *reason = truncated ? @"search_limit" : @"not_found";
        __block NSUInteger hashedCount = 0;
        NSUInteger contentMatchCount = 0;
        NSString *expectedSHA1 = amproj_expectedInternalSHA1(filename);
        if (expectedSHA1 && matchByExpectedSHA1[expectedSHA1]) {
            selected = matchByExpectedSHA1[expectedSHA1];
            contentMatchCount = 1;
            reason = [matches.allValues containsObject:selected] ?
                @"content_hash_match" : @"content_scan_match";
            selected = amproj_cacheInternalResource(selected, filename, expectedSHA1);
        } else if (!expectedSHA1 && !truncated && matches.count == 1) {
            selected = matches.allValues.firstObject;
            reason = @"unique_match";
        } else if (!expectedSHA1 && !truncated && matches.count > 1) {
            NSMutableDictionary<NSString *, NSURL *> *firstByDigest = [NSMutableDictionary dictionary];
            [matches enumerateKeysAndObjectsUsingBlock:
                ^(NSString *identity, NSURL *URL, BOOL *innerStop) {
                (void)innerStop;
                NSString *digest = digestByIdentity[identity] ?: amproj_SHA1ForFileURL(URL);
                if (!digest) return;
                digestByIdentity[identity] = digest;
                hashedCount++;
                if (!firstByDigest[digest]) firstByDigest[digest] = URL;
            }];
            if (hashedCount == matches.count && firstByDigest.count == 1) {
                selected = firstByDigest.allValues.firstObject;
                reason = @"duplicate_identical";
            } else {
                reason = @"ambiguous_content";
            }
        }
        BOOL found = selected != nil;
        amproj_debugEvent(amproj_resourceLookupEventName(reference), @{
            @"filename": filename,
            @"found": @(found),
            @"match_count": @(matches.count),
            @"search_count": @(searchCount),
            @"truncated": @(truncated),
            @"search_complete": @(!truncated),
            @"hashed_count": @(hashedCount),
            @"content_match_count": @(contentMatchCount),
            @"content_hash_files": @(contentHashFiles),
            @"content_hash_bytes": @(contentHashBytes),
            @"fallback_candidates": @(fallbackCandidateCount),
            @"content_scan_truncated": @(contentScanTruncated),
            @"expected_sha1": expectedSHA1 ?: @"",
            @"reason": reason
        });
        if (found) {
            resolved[reference] = selected;
        } else if (truncated || contentScanTruncated) {
            failures[reference] = [NSString stringWithFormat:
                @"Internal resource scan reached its safety limit (%lu files, %llu hashed bytes)",
                (unsigned long)searchCount, contentHashBytes];
        } else if (!matches.count) {
            failures[reference] = [NSString stringWithFormat:
                @"Internal resource was not found after scanning %lu files",
                (unsigned long)searchCount];
        } else {
            failures[reference] = [NSString stringWithFormat:
                @"Found %lu different files for the same internal resource",
                (unsigned long)matches.count];
        }
    }];
    if (failureReasons) *failureReasons = failures;
    return resolved;
}

static NSURL* amproj_resolveResourceReference(NSString *reference, NSURL *XMLURL,
                                               NSDictionary<NSString *, NSURL *> *internalResources) {
    if (!reference.length) return nil;
    NSString *scheme = [NSURLComponents componentsWithString:reference].scheme.lowercaseString;
    if ([scheme hasPrefix:@"phasset-"]) return amproj_exportPhotoAsset(reference);
    if ([scheme isEqualToString:@"am-internal"] ||
        amproj_importedFontFilename(reference).length) {
        return internalResources[reference];
    }
    NSURL *URL = nil;
    if ([reference hasPrefix:@"file://"]) URL = [NSURL URLWithString:reference];
    else if ([reference hasPrefix:@"/"]) URL = [NSURL fileURLWithPath:reference];
    else if ([reference hasPrefix:@"amproj:"]) {
        NSString *relative = [reference substringFromIndex:@"amproj:".length];
        URL = [XMLURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:relative];
    } else if (![NSURL URLWithString:reference].scheme.length && reference.pathExtension.length) {
        URL = [XMLURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:reference];
    }
    return URL.isFileURL ? URL.URLByStandardizingPath : nil;
}

static NSDictionary* amproj_collectResourcesAndRewriteXML(NSData *xmlData, NSURL *XMLURL,
                                                            NSError **error) {
    AMProjXMLProbe *probe = amproj_probeXML(xmlData);
    if (!probe) {
        if (error) *error = amproj_directError(20, @"Project XML is invalid");
        return nil;
    }
    NSString *XML = [[NSString alloc] initWithData:xmlData encoding:NSUTF8StringEncoding];
    if (!XML) {
        if (error) *error = amproj_directError(21, @"Project XML is not UTF-8");
        return nil;
    }

    NSMutableDictionary<NSString *, NSURL *> *resources = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *sourceNames = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *sourceDigests = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *digestNames = [NSMutableDictionary dictionary];
    NSMutableString *rewritten = [XML mutableCopy];
    NSUInteger sequence = 0;
    NSMutableArray<NSString *> *internalReferences = [NSMutableArray array];
    for (NSString *reference in probe.resourceReferences) {
        NSString *scheme = [NSURLComponents componentsWithString:reference].scheme.lowercaseString;
        if ([scheme isEqualToString:@"am-internal"] ||
            amproj_importedFontFilename(reference).length) {
            [internalReferences addObject:reference];
        }
    }
    NSDictionary<NSString *, NSString *> *internalFailures = nil;
    NSDictionary<NSString *, NSURL *> *internalResources =
        amproj_resolveInternalResources(internalReferences, XMLURL, &internalFailures);
    for (NSString *reference in probe.resourceReferences) {
        NSURL *source = amproj_resolveResourceReference(reference, XMLURL, internalResources);
        if (!source) {
            NSString *failure = internalFailures[reference];
            if (error) *error = amproj_directError(22, failure.length ?
                [NSString stringWithFormat:@"%@\n%@", failure, reference] :
                [NSString stringWithFormat:@"Unable to resolve required resource: %@", reference]);
            return nil;
        }
        NSNumber *regular = nil;
        [source getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) {
            if (error) *error = amproj_directError(22,
                [NSString stringWithFormat:@"Required resource is missing: %@", source.lastPathComponent ?: reference]);
            return nil;
        }
        NSString *sourceKey = source.path;
        NSString *archiveName = sourceNames[sourceKey];
        if (!archiveName) {
            NSString *digest = sourceDigests[sourceKey] ?: amproj_SHA1ForFileURL(source);
            if (!digest.length) {
                if (error) *error = amproj_directError(23,
                    [NSString stringWithFormat:@"Unable to hash required resource: %@",
                     source.lastPathComponent ?: reference]);
                return nil;
            }
            sourceDigests[sourceKey] = digest;
            archiveName = digestNames[digest];
            if (!archiveName) {
                NSString *base = amproj_safeFilename(source.lastPathComponent, @"resource");
                NSString *extension = source.pathExtension.lowercaseString;
                if (extension.length) base = [base stringByAppendingPathExtension:extension];
                archiveName = base;
                while (resources[archiveName]) {
                    sequence++;
                    NSString *stem = archiveName.stringByDeletingPathExtension;
                    archiveName = [NSString stringWithFormat:@"%@_%lu", stem,
                                   (unsigned long)sequence];
                    if (extension.length) archiveName = [archiveName
                        stringByAppendingPathExtension:extension];
                }
                resources[archiveName] = source;
                digestNames[digest] = archiveName;
            }
            sourceNames[sourceKey] = archiveName;
        }
        NSString *escapedOriginal = amproj_escapeXML(reference, YES);
        NSString *escapedReplacement = amproj_escapeXML(
            [@"amproj:" stringByAppendingString:archiveName], YES);
        [rewritten replaceOccurrencesOfString:escapedOriginal withString:escapedReplacement
                                      options:0 range:NSMakeRange(0, rewritten.length)];
    }
    NSData *rewrittenData = [rewritten dataUsingEncoding:NSUTF8StringEncoding];
    return @{@"xml": rewrittenData ?: xmlData, @"resources": resources, @"probe": probe};
}

// ═══════════════════════════════════════════
// MARK: - 核心: 劫持 UIActivityViewController
// ═══════════════════════════════════════════

static id (*orig_initWithItems)(id, SEL, NSArray *, NSArray *) = NULL;
static void (*orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;
static void (*orig_shareNCOnTapExport)(id, SEL, id) = NULL;
static void (*orig_navigationPush)(id, SEL, UIViewController *, BOOL) = NULL;

// Build 865 moved the share-screen export selection out of ObjC ivars, so the
// 862 option-reading hook cannot tell which export option is selected. What
// can be observed safely is the tap itself: ShareNC still exposes an ObjC
// `onTapExport:`. Recording its timestamp lets the presentation hook tell a
// login gate that Alight Motion raised for the just-tapped package export
// apart from unrelated sign-in prompts.
static CFAbsoluteTime amproj_865ShareExportTapAt = 0;
static void (*orig_shareNCTap865)(id, SEL, id) = NULL;

static void hooked_shareNCTap865(id self, SEL _cmd, id sender) {
    amproj_865ShareExportTapAt = CFAbsoluteTimeGetCurrent();
    if (orig_shareNCTap865) orig_shareNCTap865(self, _cmd, sender);
}

static void amproj_install865ShareTapHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!amproj_runtimeIsBuild865()) return;
        Class shareClass = objc_getClass("_TtC12AlightMotion7ShareNC");
        if (!shareClass) shareClass = objc_getClass("AlightMotion.ShareNC");
        if (!shareClass) return;
        Method method = class_getInstanceMethod(shareClass,
            NSSelectorFromString(@"onTapExport:"));
        if (!method) return;
        orig_shareNCTap865 = (void (*)(id, SEL, id))method_setImplementation(
            method, (IMP)hooked_shareNCTap865);
        amproj_logCriticalEvent(@"direct.865_share_tap_hook", @{
            @"installed": @YES,
            @"class": NSStringFromClass(shareClass) ?: @""
        });
    });
}

@interface AMProjActivityItemSource : NSObject <UIActivityItemSource>
@property(nonatomic, strong) NSURL *fileURL;
@end

@implementation AMProjActivityItemSource
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController {
    (void)activityViewController;
    return self.fileURL;
}
- (id)activityViewController:(UIActivityViewController *)activityViewController
          itemForActivityType:(UIActivityType)activityType {
    (void)activityViewController;
    (void)activityType;
    return self.fileURL;
}
- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
 dataTypeIdentifierForActivityType:(UIActivityType)activityType {
    (void)activityViewController;
    (void)activityType;
    return AMProjUTI;
}
- (NSString *)activityViewController:(UIActivityViewController *)activityViewController
              subjectForActivityType:(UIActivityType)activityType {
    (void)activityViewController;
    (void)activityType;
    return self.fileURL.lastPathComponent ?: @"AlightMotion_Project.amproj";
}
@end

@interface AMProjDirectRequest : NSObject
@property(nonatomic, strong) UIViewController *presenter;
@property(nonatomic, strong) UIViewController *originalController;
@property(nonatomic) BOOL animated;
@property(nonatomic, copy) void (^originalCompletion)(void);
@property(nonatomic, strong) UIAlertController *progressAlert;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic, strong) NSURL *outputURL;
@property(nonatomic, copy) NSString *projectTitle;
@property(nonatomic) BOOL uploadToCloud;
@end

@implementation AMProjDirectRequest
@end

static AMProjDirectRequest *amproj_directRequest = nil;
static BOOL amproj_constructingDirectShare = NO;
#if AMPROJ_CLOUD_SYNC
static uint64_t amproj_directAuthorizationGeneration = 0;
static BOOL amproj_directAuthorizationPending = NO;
#endif

#if AMPROJ_DEBUG
typedef NS_ENUM(int, AMProjDebugPhase) {
    AMProjDebugPhaseIdle = 0,
    AMProjDebugPhasePackageUI,
    AMProjDebugPhaseActivityInit,
    AMProjDebugPhaseSceneFind,
    AMProjDebugPhaseXML,
    AMProjDebugPhaseZIP,
    AMProjDebugPhaseFileWrite,
    AMProjDebugPhaseOriginalInit,
    AMProjDebugPhasePresent,
    AMProjDebugPhaseComplete,
};

static atomic_bool amproj_packageFlowActive = false;
static atomic_bool amproj_mainStallReported = false;
static _Atomic(float) amproj_lastProgress = 0.0f;
static atomic_int amproj_currentPhase = AMProjDebugPhaseIdle;
static atomic_uint_fast64_t amproj_flowGeneration = 0;
static atomic_uint_fast64_t amproj_progressGeneration = 0;
static atomic_uint_fast64_t amproj_lastMainHeartbeatMs = 0;
static NSString *amproj_currentTransaction = nil;
static BOOL amproj_captureCurrentTransaction = NO;
static mach_port_t amproj_mainThread = MACH_PORT_NULL;
static dispatch_source_t amproj_heartbeatTimer = nil;
static const float amproj_stallProgressThreshold = 0.95f;
static const uint64_t amproj_progressStallMilliseconds = 5000;

static uint64_t amproj_uptimeMilliseconds(void) {
    return (uint64_t)([NSProcessInfo processInfo].systemUptime * 1000.0);
}

static NSString* amproj_phaseName(AMProjDebugPhase phase) {
    switch (phase) {
        case AMProjDebugPhasePackageUI: return @"package_ui";
        case AMProjDebugPhaseActivityInit: return @"activity_init";
        case AMProjDebugPhaseSceneFind: return @"scene_find";
        case AMProjDebugPhaseXML: return @"xml";
        case AMProjDebugPhaseZIP: return @"zip";
        case AMProjDebugPhaseFileWrite: return @"file_write";
        case AMProjDebugPhaseOriginalInit: return @"original_activity_init";
        case AMProjDebugPhasePresent: return @"present";
        case AMProjDebugPhaseComplete: return @"complete";
        default: return @"idle";
    }
}

static void amproj_setPhase(AMProjDebugPhase phase, NSDictionary *fields) {
    atomic_store(&amproj_currentPhase, phase);
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    payload[@"phase"] = amproj_phaseName(phase);
    amproj_debugEvent(@"export.phase", payload);
}

static NSDictionary* amproj_mainThreadSnapshot(void) {
    if (amproj_mainThread == MACH_PORT_NULL) return @{@"available": @NO};

    kern_return_t suspended = thread_suspend(amproj_mainThread);
    if (suspended != KERN_SUCCESS) return @{@"available": @NO, @"suspend_error": @(suspended)};

    arm_thread_state64_t state = {0};
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(amproj_mainThread, ARM_THREAD_STATE64,
                                             (thread_state_t)&state, &count);
    uintptr_t pc = 0, lr = 0, fp = 0, sp = 0;
    if (result == KERN_SUCCESS) {
        pc = (uintptr_t)arm_thread_state64_get_pc(state);
        lr = (uintptr_t)arm_thread_state64_get_lr(state);
        fp = (uintptr_t)arm_thread_state64_get_fp(state);
        sp = (uintptr_t)arm_thread_state64_get_sp(state);
    }
    thread_resume(amproj_mainThread);

    if (result != KERN_SUCCESS) return @{@"available": @NO, @"state_error": @(result)};

    Dl_info info = {0};
    NSString *image = @"";
    uintptr_t imageOffset = 0;
    if (dladdr((const void *)pc, &info) && info.dli_fname && info.dli_fbase) {
        image = [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] ?: @"";
        imageOffset = pc - (uintptr_t)info.dli_fbase;
    }
    return @{
        @"available": @YES,
        @"pc": [NSString stringWithFormat:@"0x%llx", (unsigned long long)pc],
        @"lr": [NSString stringWithFormat:@"0x%llx", (unsigned long long)lr],
        @"fp": [NSString stringWithFormat:@"0x%llx", (unsigned long long)fp],
        @"sp": [NSString stringWithFormat:@"0x%llx", (unsigned long long)sp],
        @"image": image,
        @"image_offset": [NSString stringWithFormat:@"0x%llx", (unsigned long long)imageOffset]
    };
}

static void amproj_beginPackageFlow(NSString *source) {
    bool wasActive = atomic_exchange(&amproj_packageFlowActive, true);
    if (wasActive) return;

    atomic_store(&amproj_lastProgress, 0.0f);
    atomic_fetch_add(&amproj_progressGeneration, 1);
    atomic_store(&amproj_getterTraceCount, 0);
    atomic_fetch_add(&amproj_flowGeneration, 1);
    amproj_currentTransaction = [[AMDebugTransport shared]
        beginExportTransaction:@"project_package"
                        fields:@{@"source": source ?: @"unknown", @"mode": amproj_exportMode()}];
    amproj_captureCurrentTransaction = amproj_currentTransaction &&
        [[AMDebugTransport shared] captureArtifactsForTransaction:amproj_currentTransaction];
    amproj_setPhase(AMProjDebugPhasePackageUI, @{@"source": source ?: @"unknown"});
}

static void amproj_endPackageFlow(NSString *result) {
    if (!atomic_exchange(&amproj_packageFlowActive, false)) return;
    atomic_fetch_add(&amproj_flowGeneration, 1);
    atomic_fetch_add(&amproj_progressGeneration, 1);
    amproj_setPhase(AMProjDebugPhaseComplete, @{@"result": result ?: @"finished"});
    if (amproj_currentTransaction) {
        [[AMDebugTransport shared] endExportTransaction:amproj_currentTransaction
                                                fields:@{@"result": result ?: @"finished"}];
    }
    amproj_currentTransaction = nil;
    amproj_captureCurrentTransaction = NO;
}

static void amproj_scheduleProgressWatchdog(uint64_t progressGeneration) {
    uint64_t flowGeneration = atomic_load(&amproj_flowGeneration);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 amproj_progressStallMilliseconds * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL stalled = atomic_load(&amproj_packageFlowActive) &&
                       atomic_load(&amproj_flowGeneration) == flowGeneration &&
                       atomic_load(&amproj_progressGeneration) == progressGeneration &&
                       atomic_load(&amproj_lastProgress) >= amproj_stallProgressThreshold;
        if (stalled) {
            AMProjDebugPhase phase = (AMProjDebugPhase)atomic_load(&amproj_currentPhase);
            amproj_debugEvent(@"export.stall", @{
                @"progress": @(atomic_load(&amproj_lastProgress)),
                @"stalled_ms": @(amproj_progressStallMilliseconds),
                @"phase": amproj_phaseName(phase),
                @"main_thread": amproj_mainThreadSnapshot()
            });
        }
    });
}

static void amproj_startHeartbeat(void) {
    if (amproj_heartbeatTimer) return;
    atomic_store(&amproj_lastMainHeartbeatMs, amproj_uptimeMilliseconds());
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    amproj_heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(amproj_heartbeatTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(amproj_heartbeatTimer, ^{
        uint64_t now = amproj_uptimeMilliseconds();
        uint64_t last = atomic_load(&amproj_lastMainHeartbeatMs);
        if (atomic_load(&amproj_packageFlowActive) && now > last + 3000 &&
            !atomic_exchange(&amproj_mainStallReported, true)) {
            amproj_debugEvent(@"main_thread.stall", @{
                @"delay_ms": @(now - last),
                @"phase": amproj_phaseName((AMProjDebugPhase)atomic_load(&amproj_currentPhase)),
                @"snapshot": amproj_mainThreadSnapshot()
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            atomic_store(&amproj_lastMainHeartbeatMs, amproj_uptimeMilliseconds());
            atomic_store(&amproj_mainStallReported, false);
        });
    });
    dispatch_resume(amproj_heartbeatTimer);
}
#else
static BOOL amproj_packageFlowActive = NO;
static void amproj_setPhase(int phase, NSDictionary *fields) { (void)phase; (void)fields; }
#define AMProjDebugPhaseActivityInit 0
#define AMProjDebugPhaseSceneFind 0
#define AMProjDebugPhaseXML 0
#define AMProjDebugPhaseZIP 0
#define AMProjDebugPhaseFileWrite 0
#define AMProjDebugPhaseOriginalInit 0
#define AMProjDebugPhasePresent 0
#endif

static NSURL* amproj_directExportRoot(void) {
    return [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"AMProjDirectExports" isDirectory:YES];
}

static void amproj_purgeOldDirectExports(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *root = amproj_directExportRoot();
        NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                               error:nil];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-24.0 * 60.0 * 60.0];
        for (NSURL *entry in entries) {
            NSDate *modified = nil;
            [entry getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
            if (modified && [modified compare:cutoff] == NSOrderedAscending) {
                [manager removeItemAtURL:entry error:nil];
            }
        }
    });
}

static void amproj_finishDirectFlow(NSString *result) {
#if AMPROJ_DEBUG
    amproj_endPackageFlow(result);
#else
    amproj_packageFlowActive = NO;
#endif
}

static void amproj_beginDirectFlow(void) {
#if AMPROJ_DEBUG
    amproj_beginPackageFlow(@"direct_package_intercept");
#else
    amproj_packageFlowActive = YES;
#endif
}

static NSDictionary* amproj_expectedSceneMetadata(id scene, NSDate *saveStarted) {
    NSArray *layers = am_arr(scene, @"layers");
    return @{
        @"title": am_str(scene, @"title") ?: @"",
        @"width": @(am_int(scene, @"width")),
        @"height": @(am_int(scene, @"height")),
        @"layers": @(layers.count),
        @"layers_known": @(layers != nil),
        @"save_started": saveStarted ?: NSDate.date
    };
}

static BOOL amproj_validateXMLAgainstScene(NSData *xmlData, NSDictionary *expected,
                                           AMProjXMLProbe **probeOut, NSError **error) {
    AMProjXMLProbe *probe = amproj_probeXML(xmlData);
    if (!probe) {
        if (error) *error = amproj_directError(30, @"Generated XML is invalid");
        return NO;
    }
    NSInteger width = [expected[@"width"] integerValue];
    NSInteger height = [expected[@"height"] integerValue];
    NSUInteger layers = [expected[@"layers"] unsignedIntegerValue];
    BOOL layersKnown = [expected[@"layers_known"] boolValue];
    if (width <= 0 || height <= 0 ||
        width != probe.width || height != probe.height ||
        (layersKnown && probe.layerCount != layers)) {
        if (error) *error = amproj_directError(31,
            [NSString stringWithFormat:@"XML validation failed (expected %lu layers, found %lu)",
             (unsigned long)layers, (unsigned long)probe.layerCount]);
        return NO;
    }
    if (probeOut) *probeOut = probe;
    return YES;
}

static NSURL* amproj_createOutputURL(NSString *title, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directory = [amproj_directExportRoot()
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES
                            attributes:nil error:error]) return nil;
    NSString *filename = [amproj_safeFilename(title, @"AlightMotion_Project")
        stringByAppendingPathExtension:@"amproj"];
    return [directory URLByAppendingPathComponent:filename];
}

static void amproj_finishDirectFailure(AMProjDirectRequest *request, NSError *error);

#if AMPROJ_CLOUD_SYNC
static UIViewController *amproj_visibleCloudUploadPresenter(
    UIViewController *preferred) {
    UIViewController *candidate = amproj_topViewController(preferred);
    if (candidate.viewIfLoaded.window) return candidate;
    candidate = amproj_topViewController(amproj_keyWindow().rootViewController);
    return candidate.viewIfLoaded.window ? candidate : nil;
}

static void amproj_beginDirectCloudUpload(AMProjDirectRequest *request,
                                          NSURL *fileURL) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (amproj_directRequest != request) return;
        request.outputURL = fileURL;
        UIViewController *presenter =
            amproj_visibleCloudUploadPresenter(request.presenter);
        if (!presenter) {
            amproj_finishDirectFailure(
                request,
                amproj_directError(40, @"Export presenter is no longer available"));
            return;
        }

        NSString *title = request.projectTitle.length
            ? request.projectTitle
            : fileURL.lastPathComponent.stringByDeletingPathExtension;
        void (^beginUpload)(void) = ^{
            if (amproj_directRequest != request) return;
            request.originalCompletion = nil;
            amproj_directRequest = nil;
            amproj_setPersistentStage(nil);
            amproj_finishDirectFlow(@"cloud_upload_ready");
            amproj_logCriticalEvent(@"direct.cloud_upload_ready", @{
                @"filename": fileURL.lastPathComponent ?: @"",
                @"title": title ?: @""
            });
            AMCloudSyncBeginUploadFile(fileURL, title ?: @"", presenter);
        };
        if (request.progressAlert.presentingViewController) {
            [request.progressAlert dismissViewControllerAnimated:NO
                                                       completion:beginUpload];
        } else {
            beginUpload();
        }
    });
}
#endif

static void amproj_presentDirectShare(AMProjDirectRequest *request, NSURL *fileURL) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (amproj_directRequest != request) return;
        amproj_setPersistentStage(@"activity_init");
        request.outputURL = fileURL;
        UIViewController *presenter = request.presenter;
        void (^presentShare)(void) = ^{
            if (!presenter) {
                amproj_finishDirectFailure(request, amproj_directError(40, @"Export presenter is no longer available"));
                return;
            }
            AMProjActivityItemSource *item = [AMProjActivityItemSource new];
            item.fileURL = fileURL;
            UIActivityViewController *activity = nil;
            @try {
                amproj_constructingDirectShare = YES;
#if AMPROJ_CLOUD_SYNC
                NSArray<UIActivity *> *cloudActivities =
                    AMCloudSyncUploadActivities(fileURL, request.projectTitle, presenter);
#else
                NSArray<UIActivity *> *cloudActivities = nil;
#endif
                activity = [[UIActivityViewController alloc]
                    initWithActivityItems:@[item] applicationActivities:cloudActivities];
            } @catch (NSException *exception) {
                amproj_finishDirectFailure(request,
                    amproj_directError(43, exception.reason ?: @"Unable to create share sheet"));
                return;
            } @finally {
                amproj_constructingDirectShare = NO;
            }
            activity.modalPresentationStyle = UIModalPresentationAutomatic;
            UIPopoverPresentationController *popover = activity.popoverPresentationController;
            if (popover) {
                popover.sourceView = presenter.view;
                popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                                CGRectGetMidY(presenter.view.bounds), 1, 1);
                popover.permittedArrowDirections = 0;
            }
            __weak AMProjDirectRequest *weakRequest = request;
            activity.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                                                     NSArray *returnedItems, NSError *shareError) {
                (void)returnedItems;
                AMProjDirectRequest *strongRequest = weakRequest;
                amproj_debugEvent(@"direct.share_complete", @{
                    @"completed": @(completed),
                    @"activity": activityType ?: @"",
                    @"error": shareError.localizedDescription ?: @""
                });
                if (amproj_directRequest == strongRequest) amproj_directRequest = nil;
                amproj_setPersistentStage(nil);
                amproj_finishDirectFlow(completed ? @"shared" : @"share_cancelled");
            };
            @try {
                amproj_setPersistentStage(@"activity_present");
                orig_presentVC(presenter, @selector(presentViewController:animated:completion:),
                               activity, YES, ^{
                    request.originalCompletion = nil;
                    amproj_setPersistentStage(nil);
                    amproj_debugEvent(@"direct.share_presented", @{
                        @"filename": fileURL.lastPathComponent ?: @"",
                        @"uti": AMProjUTI
                    });
                });
            } @catch (NSException *exception) {
                amproj_finishDirectFailure(request,
                    amproj_directError(41, exception.reason ?: @"Unable to present share sheet"));
            }
        };
        if (request.progressAlert.presentingViewController) {
            [request.progressAlert dismissViewControllerAnimated:NO completion:presentShare];
        } else {
            presentShare();
        }
    });
}

static void amproj_writeDirectArchive(AMProjDirectRequest *request, NSData *xmlData,
                                      NSURL *XMLURL, NSDictionary *expected,
                                      NSString *xmlSource) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSError *error = nil;
            AMProjXMLProbe *validated = nil;
            amproj_setPersistentStage(@"xml_validate");
            if (!amproj_validateXMLAgainstScene(xmlData, expected, &validated, &error)) {
                amproj_finishDirectFailure(request, error ?: amproj_directError(30, @"Project XML validation failed"));
                return;
            }
            amproj_setPersistentStage(@"resource_rewrite");
            NSDictionary *prepared = amproj_collectResourcesAndRewriteXML(xmlData, XMLURL, &error);
            if (!prepared) {
                amproj_finishDirectFailure(request, error ?: amproj_directError(22, @"Unable to collect project resources"));
                return;
            }
            NSData *rewrittenXML = prepared[@"xml"];
            NSDictionary<NSString *, NSURL *> *resources = prepared[@"resources"];
            if (!amproj_validateXMLAgainstScene(rewrittenXML, expected, NULL, &error)) {
                amproj_finishDirectFailure(request, error ?: amproj_directError(31, @"Rewritten XML validation failed"));
                return;
            }
            NSString *title = [expected[@"title"] length] ? expected[@"title"] : validated.title;
            NSURL *outputURL = amproj_createOutputURL(title, &error);
            NSDictionary<NSString *, NSNumber *> *zipMetrics = nil;
            amproj_setPersistentStage(@"zip_write");
            if (!outputURL || !AMProjZIPWriteProjectArchive(
                    outputURL, rewrittenXML, resources, &zipMetrics, &error)) {
                amproj_finishDirectFailure(request, error ?: amproj_directError(42, @"Unable to write .amproj archive"));
                return;
            }
            NSNumber *fileSize = nil;
            [outputURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            amproj_logCriticalEvent(@"direct.archive_ready", @{
                @"xml_source": xmlSource ?: @"unknown",
                @"xml_bytes": @(rewrittenXML.length),
                @"resource_count": @(resources.count),
                @"archive_bytes": fileSize ?: @0,
                @"crc_verified": zipMetrics[@"crc_verified"] ?: @NO,
                @"manifest_verified": zipMetrics[@"manifest_verified"] ?: @NO,
                @"entry_count": zipMetrics[@"entry_count"] ?: @0,
                @"filename": outputURL.lastPathComponent ?: @""
            });
#if AMPROJ_DEBUG
            if (amproj_currentTransaction && amproj_captureCurrentTransaction) {
                [[AMDebugTransport shared] uploadArtifactData:rewrittenXML name:@"scene.xml"
                                                     mimeType:@"application/xml"
                                                  transaction:amproj_currentTransaction];
                if (fileSize.unsignedLongLongValue <= 32ULL * 1024ULL * 1024ULL) {
                    NSData *archiveData = [NSData dataWithContentsOfURL:outputURL
                                                                options:NSDataReadingMappedIfSafe error:nil];
                    if (archiveData) {
                        [[AMDebugTransport shared] uploadArtifactData:archiveData
                                                                 name:outputURL.lastPathComponent
                                                             mimeType:@"application/x-amproj"
                                                          transaction:amproj_currentTransaction];
                    }
                }
            }
#endif
#if AMPROJ_CLOUD_SYNC
            if (request.uploadToCloud) {
                amproj_beginDirectCloudUpload(request, outputURL);
                return;
            }
#endif
            amproj_presentDirectShare(request, outputURL);
        } @catch (NSException *exception) {
            NSString *reason = exception.reason.length ? exception.reason : @"Unexpected export exception";
            amproj_logCriticalEvent(@"direct.archive_exception", @{
                @"name": exception.name ?: @"NSException",
                @"reason": reason
            });
            amproj_finishDirectFailure(request, amproj_directError(44, reason));
        }
    });
}

static void amproj_buildDirectPackage(AMProjDirectRequest *request) {
    if (amproj_directRequest != request) return;
    @try {
        amproj_setPersistentStage(@"build_enter");
        if ([request.mode isEqualToString:@"placeholder"]) {
            NSDate *now = NSDate.date;
            amproj_writeDirectArchive(request, amproj_placeholderXML(), nil,
                @{@"title": @"AMProj_Placeholder", @"width": @1280, @"height": @720,
                  @"layers": @0, @"layers_known": @YES, @"save_started": now}, @"placeholder");
            return;
        }
        NSDate *saveStarted = NSDate.date;
        NSDictionary *expected = @{
            @"title": request.projectTitle ?: @"",
            @"width": @0,
            @"height": @0,
            @"layers": @0,
            @"layers_known": @NO,
            @"save_started": saveStarted
        };
        amproj_setPersistentStage(@"path_scan");
        NSArray<NSURL *> *paths = amproj_collectPathCandidates(@[]);
        amproj_logCriticalEvent(@"direct.scene_native_only", @{
            @"holder": @"not_accessed",
            @"scene": @"not_accessed",
            @"title": expected[@"title"],
            @"layers": expected[@"layers"],
            @"path_candidates": @(paths.count)
        });

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @try {
                amproj_setPersistentStage(@"native_xml_scan");
                NSDictionary *native = amproj_selectNativeXML(paths, expected);
                if (native) {
                    amproj_setPersistentStage(@"native_xml_found");
                    AMProjXMLProbe *probe = native[@"probe"];
                    NSDictionary *validatedExpected = @{
                        @"title": probe.title ?: request.projectTitle ?: @"",
                        @"width": @(probe.width),
                        @"height": @(probe.height),
                        @"layers": @(probe.layerCount),
                        @"layers_known": @YES,
                        @"save_started": saveStarted
                    };
                    amproj_logCriticalEvent(@"direct.native_xml", @{
                        @"found": @YES,
                        @"path": [native[@"url"] lastPathComponent] ?: @"",
                        @"score": native[@"score"] ?: @0
                    });
                    amproj_writeDirectArchive(request, native[@"data"], native[@"url"], validatedExpected, @"native");
                    return;
                }
                amproj_logCriticalEvent(@"direct.native_xml", @{@"found": @NO});
                amproj_finishDirectFailure(request,
                    amproj_directError(51, @"Unable to locate Alight Motion's saved project XML; no incomplete fallback package was created"));
            } @catch (NSException *exception) {
                NSString *reason = exception.reason.length ? exception.reason : @"Unexpected project scan exception";
                amproj_logCriticalEvent(@"direct.scan_exception", @{
                    @"name": exception.name ?: @"NSException",
                    @"reason": reason
                });
                amproj_finishDirectFailure(request, amproj_directError(52, reason));
            }
        });
    } @catch (NSException *exception) {
        NSString *reason = exception.reason.length ? exception.reason : @"Unexpected export setup exception";
        amproj_logCriticalEvent(@"direct.setup_exception", @{
            @"name": exception.name ?: @"NSException",
            @"reason": reason
        });
        amproj_finishDirectFailure(request, amproj_directError(53, reason));
    }
}

static void amproj_startAuthorizedDirectExport(UIViewController *presenter,
                                               UIViewController *originalController,
                                               BOOL animated, void (^completion)(void),
                                               NSString *projectTitle,
                                               BOOL uploadToCloud) {
    if (amproj_directRequest) {
        if (completion) completion();
        return;
    }
    AMProjDirectRequest *request = [AMProjDirectRequest new];
    request.presenter = presenter;
    request.originalController = originalController;
    request.animated = animated;
    request.originalCompletion = completion;
    request.projectTitle = projectTitle;
    request.uploadToCloud = uploadToCloud;
    request.mode = amproj_exportMode();
    // Do not present a second UIKit modal from ShareNC.onTapExport.  On 6.2.55
    // the action is still inside SwiftUI/UIKit's transition, and presenting a
    // progress alert synchronously here can terminate the process before the
    // export work even starts.  The request remains tracked; the share sheet
    // is presented only after the archive is complete.
    request.progressAlert = nil;
    amproj_directRequest = request;
    amproj_setPersistentStage(@"progress_present");
    amproj_beginDirectFlow();
    amproj_logCriticalEvent(@"direct.intercept", @{
        @"presenter": NSStringFromClass([presenter class]) ?: @"",
        @"controller": NSStringFromClass([originalController class]) ?: @"",
        @"holder": @"not_accessed",
        @"source": @"share_export_button",
        @"destination": uploadToCloud ? @"autfeng_hub" : @"share_sheet",
        @"mode": request.mode ?: @""
    });
    if (!presenter || !orig_presentVC) {
        amproj_finishDirectFailure(request,
            amproj_directError(54, @"Export presenter is unavailable"));
        return;
    }
    // Let the originating control finish its event/transition before any
    // export-side UIKit work. The actual archive build is off-main-thread.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (amproj_directRequest == request) amproj_buildDirectPackage(request);
    });
}

static void amproj_startDirectExportWithDestination(
    UIViewController *presenter, UIViewController *originalController,
    BOOL animated, void (^completion)(void), NSString *projectTitle,
    BOOL uploadToCloud) {
    if (amproj_directRequest) {
        if (completion) completion();
        return;
    }
#if AMPROJ_CLOUD_SYNC
    uint64_t authorizationGeneration = ++amproj_directAuthorizationGeneration;
    amproj_directAuthorizationPending = YES;
    AMCloudAuthorizeFeature(@"export", presenter,
        ^(BOOL allowed, __unused NSError *error) {
            if (authorizationGeneration != amproj_directAuthorizationGeneration ||
                !amproj_directAuthorizationPending) {
                amproj_logCriticalEvent(@"direct.authorization_stale", @{
                    @"generation": @(authorizationGeneration),
                    @"destination": uploadToCloud ? @"autfeng_hub" : @"share_sheet"
                });
                return;
            }
            amproj_directAuthorizationPending = NO;
            if (allowed) {
                if (!presenter.viewIfLoaded.window) {
                    amproj_logCriticalEvent(@"direct.authorization_presenter_detached", @{
                        @"generation": @(authorizationGeneration),
                        @"destination": uploadToCloud ? @"autfeng_hub" : @"share_sheet"
                    });
                    return;
                }
                // Keep the destination check on the native export controller.
                // If an unverified caller reaches this legacy path on 865, it
                // fails closed instead of taking ownership of the native action.
                if (uploadToCloud) {
                    uint8_t selectedExportOption = UINT8_MAX;
                    UIViewController *shareVC = amproj_shareVCRecursive(
                        presenter, 0, [NSMutableSet set], &selectedExportOption);
                    if (!shareVC ||
                        selectedExportOption != AMProjShareCloudUploadOption) {
                        amproj_logCriticalEvent(@"direct.authorization_selection_changed", @{
                            @"generation": @(authorizationGeneration),
                            @"selected_export_option": shareVC
                                ? @(selectedExportOption) : @(-1)
                        });
                        return;
                    }
                }
                amproj_startAuthorizedDirectExport(
                    presenter, originalController, animated, completion, projectTitle,
                    uploadToCloud);
            }
        });
#else
    amproj_startAuthorizedDirectExport(
        presenter, originalController, animated, completion, projectTitle,
        uploadToCloud);
#endif
}

static void amproj_startDirectExport(UIViewController *presenter,
                                     UIViewController *originalController,
                                     BOOL animated, void (^completion)(void),
                                     NSString *projectTitle) {
    amproj_startDirectExportWithDestination(
        presenter, originalController, animated, completion, projectTitle, NO);
}

#if AMPROJ_CLOUD_SYNC
static void amproj_startCloudUpload(UIViewController *presenter,
                                    NSString *projectTitle) {
    amproj_startDirectExportWithDestination(
        presenter, nil, YES, nil, projectTitle, YES);
}
#endif

static void amproj_finishDirectFailure(AMProjDirectRequest *request, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (amproj_directRequest != request) return;
        amproj_setPersistentStage(nil);
        amproj_debugEvent(@"direct.failed", @{
            @"code": @(error.code),
            @"error": error.localizedDescription ?: @"Unknown export error"
        });
        UIViewController *presenter = request.presenter;
        UIViewController *originalController = request.originalController;
        BOOL animated = request.animated;
        void (^originalCompletion)(void) = request.originalCompletion;
        NSString *projectTitle = request.projectTitle;
        BOOL uploadToCloud = request.uploadToCloud;
        void (^showFailure)(void) = ^{
            amproj_directRequest = nil;
            amproj_finishDirectFlow(@"failed");
            if (!presenter) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法生成 .amproj"
                message:error.localizedDescription ?: @"项目数据验证失败。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    if (uploadToCloud) {
#if AMPROJ_CLOUD_SYNC
                        amproj_startCloudUpload(presenter, projectTitle);
#endif
                    } else {
                        amproj_startDirectExport(
                            presenter, originalController, animated,
                            originalCompletion, projectTitle);
                    }
                }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            orig_presentVC(presenter, @selector(presentViewController:animated:completion:), alert, YES, nil);
        };
        if (request.progressAlert.presentingViewController) {
            [request.progressAlert dismissViewControllerAnimated:NO completion:showFailure];
        } else {
            showFailure();
        }
    });
}

// MARK: - Local .amproj import bridge

typedef BOOL (*AMProjApplicationOpenURLIMP)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
typedef BOOL (*AMProjApplicationWillFinishIMP)(id, SEL, UIApplication *, NSDictionary *);
typedef BOOL (*AMProjApplicationDidFinishIMP)(id, SEL, UIApplication *, NSDictionary *);
typedef BOOL (*AMProjApplicationContinueActivityIMP)(id, SEL, UIApplication *,
                                                      NSUserActivity *, id);
typedef BOOL (*AMProjApplicationHandleOpenURLIMP)(id, SEL, UIApplication *, NSURL *);
typedef BOOL (*AMProjApplicationLegacyOpenURLIMP)(id, SEL, UIApplication *, NSURL *,
                                                  NSString *, id);
typedef void (*AMProjApplicationSetDelegateIMP)(UIApplication *, SEL,
                                                 id<UIApplicationDelegate>);
typedef UISceneConfiguration *(*AMProjApplicationConfigurationForConnectingIMP)(
    id, SEL, UIApplication *, UISceneSession *, UISceneConnectionOptions *);
typedef void (*AMProjSceneWillConnectIMP)(id, SEL, UIScene *, UISceneSession *,
                                          UISceneConnectionOptions *);
typedef void (*AMProjSceneOpenURLContextsIMP)(id, SEL, UIScene *, NSSet *);
typedef id (*AMProjDocumentPickerModernInitIMP)(
    id, SEL, NSArray<UTType *> *, BOOL);
typedef id (*AMProjDocumentPickerLegacyInitIMP)(
    id, SEL, NSArray<NSString *> *, UIDocumentPickerMode);

@interface AMProjImportPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

@interface AMProjNativeXMLPickerProxy : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong) id<UIDocumentPickerDelegate> originalDelegate;
@end

typedef struct {
    __unsafe_unretained Class cls;
    IMP original;
    IMP base;
} AMProjTrackedHook;

static AMProjTrackedHook amproj_openURLHooks[12] = {0};
static AMProjTrackedHook amproj_willFinishHooks[12] = {0};
static AMProjTrackedHook amproj_didFinishHooks[12] = {0};
static AMProjTrackedHook amproj_continueActivityHooks[12] = {0};
static AMProjTrackedHook amproj_handleOpenURLHooks[12] = {0};
static AMProjTrackedHook amproj_legacyOpenURLHooks[12] = {0};
static AMProjTrackedHook amproj_configurationHooks[12] = {0};
static AMProjTrackedHook amproj_sceneWillConnectHooks[12] = {0};
static AMProjTrackedHook amproj_sceneOpenURLHooks[12] = {0};
static AMProjTrackedHook amproj_nativeXMLDelegateStartHooks[8] = {0};
static AMProjTrackedHook amproj_nativeXMLDelegateEndHooks[8] = {0};
static AMProjApplicationSetDelegateIMP orig_applicationSetDelegate = NULL;
static __weak UIApplication *amproj_public865Application = nil;
static __weak id<UIApplicationDelegate> amproj_public865RuntimeDelegate = nil;
static AMProjDocumentPickerModernInitIMP orig_documentPickerModernInit = NULL;
static AMProjDocumentPickerLegacyInitIMP orig_documentPickerLegacyInit = NULL;
static IMP amproj_nativeAppDelegateOpenURLIMP = NULL;
static BOOL (*orig_nativeXMLParserParse)(NSXMLParser *, SEL) = NULL;
static char amproj_nativeXMLParserAttemptKey;
static char amproj_nativeXMLParserLastElementKey;
static char amproj_nativeXMLParserElementStackKey;
static char amproj_nativeXMLParserSemanticErrorKey;
static char amproj_nativeXMLParserErrorCountKey;
static char amproj_nativeXMLPickerProxyKey;
static NSURL *amproj_pendingImportURL = nil;
static NSString *amproj_pendingImportName = nil;
static NSString *amproj_pendingImportTransactionID = nil;
static NSMutableArray<NSDictionary *> *amproj_pendingImportQueue = nil;
static NSMutableArray<NSDictionary *> *amproj_deferredLaunchImportCandidates = nil;
static BOOL amproj_importDispatchCoolingDown = NO;
static BOOL amproj_nativeImportAlertActive = NO;
static BOOL amproj_waitingForNativeImportAlert = NO;
static BOOL amproj_nativeBridgeRestartNoticeShown = NO;
static BOOL amproj_nativeImportObservationActive = NO;
static NSUInteger amproj_nativeImportObservationGeneration = 0;
static NSString *amproj_nativeImportObservationName = nil;
static NSString *amproj_nativeImportAttemptID = nil;
static NSString *amproj_nativeImportObservationPhase = nil;
static CFAbsoluteTime amproj_nativeImportObservationStartedAt = 0;
static NSDictionary *amproj_nativeParserSnapshot = nil;
static NSUInteger amproj_nativeImportRecognitionGeneration = 0;
static NSString *amproj_nativeImportRecognitionName = nil;
static NSUInteger amproj_pendingImportGeneration = 0;
static CFAbsoluteTime amproj_pendingImportDeadline = 0;
static NSUInteger amproj_activeNativeImportGeneration = 0;
#if AMPROJ_CLOUD_SYNC
static BOOL amproj_importAuthorizationPending = NO;
static NSUInteger amproj_importAuthorizationGeneration = 0;
#endif
static NSString *amproj_activeNativeImportTransactionID = nil;
static BOOL amproj_importVerificationActive = NO;
static NSUInteger amproj_importVerificationGeneration = 0;
static NSString *amproj_importVerificationName = nil;
static NSString *amproj_importVerificationTransactionID = nil;
static NSUInteger amproj_importVerificationAttempt = 0;
static NSInteger amproj_importProjectRowBaselineCount = -1;
static BOOL amproj_xmlTemplateImportActive = NO;
static NSUInteger amproj_xmlTemplateImportGeneration = 0;
static NSString *amproj_xmlTemplateImportTransactionID = nil;
static NSMutableArray<NSDictionary *> *amproj_xmlTemplatePendingQueue = nil;
static __weak UIViewController *amproj_xmlTemplateResultAlert = nil;
static UIDocumentPickerViewController *amproj_xmlTemplateRetiredPicker = nil;
static BOOL amproj_xmlTemplateResultAlertWaitScheduled = NO;
static CFAbsoluteTime amproj_xmlTemplateResultQuarantineUntil = 0;
typedef NS_ENUM(NSInteger, AMProjImportTransactionState) {
    AMProjImportTransactionCaptured = 0,
    AMProjImportTransactionCopying,
    AMProjImportTransactionValidating,
    AMProjImportTransactionQueued,
    AMProjImportTransactionWaitingForProjects,
    AMProjImportTransactionNativeActive,
    AMProjImportTransactionTemplateDetected,
    AMProjImportTransactionCreatingProject,
    AMProjImportTransactionProjectVerified,
    AMProjImportTransactionCleaningTemplate,
    AMProjImportTransactionCompleted,
    AMProjImportTransactionFailed,
};

typedef NS_ENUM(NSInteger, AMProjTemplateProbeCapability) {
    AMProjTemplateProbeCapabilityUnknown = 0,
    AMProjTemplateProbeCapabilityUIKitReady,
    AMProjTemplateProbeCapabilitySwiftUIUnavailable,
};

@interface AMProjImportTransaction : NSObject
@property(nonatomic, copy) NSString *transactionID;
@property(nonatomic, copy) NSString *provisionalKey;
@property(nonatomic, copy) NSString *fingerprint;
@property(nonatomic, copy) NSString *duplicateOfFingerprint;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *source;
@property(nonatomic, strong) NSURL *archiveURL;
@property(nonatomic, strong) NSURL *incomingURL;
@property(nonatomic, strong) NSURL *incomingCleanupURL;
@property(nonatomic, strong) NSURL *stagedDirectoryURL;
@property(nonatomic, copy) NSString *projectTitle;
@property(nonatomic, copy) NSDictionary *persistenceBaseline;
@property(nonatomic, copy) NSString *nativeTemporaryPath;
@property(nonatomic) AMProjImportKind kind;
@property(nonatomic) BOOL deleteIncomingSourceOnCompletion;
@property(nonatomic) BOOL packageIntegrityVerified;
@property(nonatomic) BOOL persistenceVerified;
@property(nonatomic) BOOL nativeTerminalStatus4Observed;
@property(nonatomic) BOOL nativeTerminalStatus4Returned;
@property(nonatomic) BOOL nativeCompletionSucceeded;
@property(nonatomic) BOOL nativeTemporaryConsumed;
@property(nonatomic) BOOL xmlImportedAnywayWarningObserved;
@property(nonatomic) BOOL persistenceBaselineCaptureStarted;
@property(nonatomic) BOOL persistenceBaselineCaptured;
@property(nonatomic) NSUInteger persistenceBaselineGeneration;
// Monotonically changes whenever the persistence baseline is invalidated.
// Async probes must match this epoch before they can mark a transaction
// verified; a retry must never inherit a probe from the previous attempt.
@property(nonatomic) NSUInteger persistenceProbeEpoch;
@property(nonatomic) BOOL projectTabReselected;
@property(nonatomic) BOOL projectTitleBaselineCaptured;
@property(nonatomic) BOOL projectTitlePresentAtBaseline;
@property(nonatomic) BOOL directProjectVerified;
@property(nonatomic) BOOL templateAbsenceVerified;
@property(nonatomic) BOOL templateAbsenceStable;
@property(nonatomic) BOOL templateAbsenceFinalCheckPending;
@property(nonatomic) NSUInteger templateAbsenceExactCycles;
@property(nonatomic) NSUInteger templateAddedStableCycles;
@property(nonatomic) NSInteger directProjectRowCount;
@property(nonatomic) BOOL templateBaselineCaptured;
@property(nonatomic) AMProjTemplateProbeCapability templateProbeCapability;
@property(nonatomic) NSUInteger templateProbeStableCycles;
@property(nonatomic, weak) UIViewController *templateProbeController;
@property(nonatomic) NSInteger templateBaselineMatchCount;
@property(nonatomic) NSInteger templateBaselineRowCount;
@property(nonatomic) NSInteger templateBaselineViewTitleCount;
@property(nonatomic) BOOL templateBaselineListReady;
@property(nonatomic, copy) NSArray<NSString *> *templateBaselineCandidateKeys;
@property(nonatomic) BOOL templatePromotionStarted;
@property(nonatomic) BOOL templateSelectionSent;
@property(nonatomic) BOOL templateCreationActionSent;
@property(nonatomic) BOOL templateProjectVerified;
@property(nonatomic, copy) NSDictionary *templatePromotionPersistenceBaseline;
@property(nonatomic) BOOL templatePromotionBaselineCaptureStarted;
@property(nonatomic) BOOL templatePersistenceProbeStarted;
@property(nonatomic) BOOL templatePersistenceVerified;
@property(nonatomic) NSUInteger templatePersistenceProbeAttempts;
@property(nonatomic) BOOL templateCleanupStarted;
@property(nonatomic) BOOL templateCleanupVerified;
@property(nonatomic) NSUInteger templateCleanupAbsenceCycles;
@property(nonatomic) BOOL templateOverflowActionSent;
@property(nonatomic) BOOL templateDeleteActionSent;
@property(nonatomic) BOOL templateDeleteConfirmationSent;
@property(nonatomic) NSUInteger templateDeleteActionCount;
@property(nonatomic) BOOL xmlTemplateDispatchStarted;
@property(nonatomic) BOOL xmlTemplatePickerLaunchStarted;
@property(nonatomic) CFAbsoluteTime xmlTemplatePickerLaunchStartedAt;
@property(nonatomic, strong) NSMutableSet<NSValue *> *xmlTemplateUploadAttemptedIdentities;
@property(nonatomic) NSUInteger xmlTemplateUploadActivationCount;
@property(nonatomic) BOOL xmlTemplatePickerDelegateInvoked;
@property(nonatomic) BOOL xmlTemplatePickerDismissRequested;
@property(nonatomic) BOOL xmlTemplatePickerDismissVerified;
@property(nonatomic) BOOL xmlTemplatePersistenceProbeInFlight;
@property(nonatomic) NSUInteger xmlTemplateDispatchGeneration;
@property(nonatomic, copy) NSSet<NSValue *> *xmlTemplatePickerBaseline;
@property(nonatomic, strong) UIDocumentPickerViewController *xmlTemplateNativePicker;
@property(nonatomic, strong) id xmlTemplateNativePickerDelegate;
@property(nonatomic, weak) UIViewController *xmlTemplateOwner;
@property(nonatomic, weak) UIViewController *xmlTemplatePickerPresenter;
@property(nonatomic) CFAbsoluteTime xmlTemplateDispatchStartedAt;
@property(nonatomic, strong) NSIndexPath *templateSelectedIndexPath;
@property(nonatomic, weak) UIView *templateSelectedList;
@property(nonatomic, weak) UIView *templateTargetCell;
@property(nonatomic, weak) UIViewController *templateMenuOwner;
@property(nonatomic, weak) UIViewController *templateActionOwner;
@property(nonatomic, weak) UIViewController *templateConfirmationOwner;
@property(nonatomic, strong) UIViewController *templateCardActivationBaselineTop;
@property(nonatomic, strong) UIViewController *templateCardActivationBaselinePresented;
@property(nonatomic, strong) UIViewController *templateDeleteActivationBaselineTop;
@property(nonatomic, strong) UIViewController *templateDeleteActivationBaselinePresented;
@property(nonatomic, copy) NSString *templateSelectedFingerprint;
@property(nonatomic, copy) NSString *templateSelectedStableKey;
@property(nonatomic) NSInteger projectTitleMatchBaselineCount;
@property(nonatomic) AMProjImportTransactionState state;
@property(nonatomic) CFAbsoluteTime updatedAt;
@end

@implementation AMProjImportTransaction
@end

static void amproj_invalidatePersistenceBaseline(
    AMProjImportTransaction *transaction) {
    if (!transaction) return;
    transaction.persistenceBaseline = nil;
    transaction.persistenceVerified = NO;
    transaction.persistenceBaselineCaptureStarted = NO;
    transaction.persistenceBaselineCaptured = NO;
    transaction.persistenceBaselineGeneration = 0;
    transaction.persistenceProbeEpoch += 1;
    if (transaction.persistenceProbeEpoch == 0) {
        transaction.persistenceProbeEpoch = 1;
    }
}

static void amproj_invalidateTemplateProbe(
    AMProjImportTransaction *transaction) {
    if (!transaction) return;
    transaction.templateBaselineCaptured = NO;
    transaction.templateProbeCapability = AMProjTemplateProbeCapabilityUnknown;
    transaction.templateProbeStableCycles = 0;
    transaction.templateProbeController = nil;
    transaction.templateBaselineMatchCount = 0;
    transaction.templateBaselineRowCount = -1;
    transaction.templateBaselineViewTitleCount = 0;
    transaction.templateBaselineListReady = NO;
    transaction.templateBaselineCandidateKeys = nil;
    transaction.templateAbsenceVerified = NO;
    transaction.templateAbsenceStable = NO;
    transaction.templateAbsenceFinalCheckPending = NO;
    transaction.templateAbsenceExactCycles = 0;
    transaction.templateAddedStableCycles = 0;
    transaction.directProjectVerified = NO;
    transaction.directProjectRowCount = -1;
    transaction.templatePromotionStarted = NO;
    transaction.templateSelectionSent = NO;
    transaction.templateCreationActionSent = NO;
    transaction.templateProjectVerified = NO;
    transaction.templatePromotionPersistenceBaseline = nil;
    transaction.templatePromotionBaselineCaptureStarted = NO;
    transaction.templatePersistenceProbeStarted = NO;
    transaction.templatePersistenceVerified = NO;
    transaction.templatePersistenceProbeAttempts = 0;
    transaction.templateCleanupStarted = NO;
    transaction.templateCleanupVerified = NO;
    transaction.templateCleanupAbsenceCycles = 0;
    transaction.templateOverflowActionSent = NO;
    transaction.templateDeleteActionSent = NO;
    transaction.templateDeleteConfirmationSent = NO;
    transaction.templateDeleteActionCount = 0;
    transaction.templateSelectedIndexPath = nil;
    transaction.templateSelectedList = nil;
    transaction.templateTargetCell = nil;
    transaction.templateMenuOwner = nil;
    transaction.templateActionOwner = nil;
    transaction.templateConfirmationOwner = nil;
    transaction.templateCardActivationBaselineTop = nil;
    transaction.templateCardActivationBaselinePresented = nil;
    transaction.templateDeleteActivationBaselineTop = nil;
    transaction.templateDeleteActivationBaselinePresented = nil;
    transaction.templateSelectedFingerprint = nil;
    transaction.templateSelectedStableKey = nil;
    transaction.projectTitlePresentAtBaseline = NO;
    transaction.projectTitleMatchBaselineCount = -1;
}

static NSMutableDictionary<NSString *, AMProjImportTransaction *> *amproj_importTransactions = nil;
static NSMutableDictionary<NSString *, NSString *> *amproj_importKeyOwners = nil;
static NSMutableDictionary<NSString *, NSNumber *> *amproj_importTombstones = nil;
// Provisional keys for copies that arrived while another transaction owns the
// same SHA-256. They remain suppressed until the owner succeeds or fails.
static NSMutableDictionary<NSString *, NSString *> *amproj_importDuplicateOwners = nil;
static BOOL amproj_importScanScheduled = NO;
static NSString *amproj_pendingScanSource = nil;
static NSString *amproj_pendingScanRequestID = nil;
static NSInteger amproj_importVisibleStageRank = 0;
static NSString *amproj_visibleStatusTransactionID = nil;
static __weak UILabel *amproj_importStatusBanner = nil;
static AMProjImportPickerDelegate *amproj_importPickerDelegate = nil;
static NSUInteger amproj_importStatusGeneration = 0;
static NSString *amproj_latestImportErrorMessage = nil;
static NSString *amproj_latestImportErrorTitle = nil;
static NSUInteger amproj_importErrorGeneration = 0;
static BOOL amproj_latestImportErrorOffersPicker = YES;
static NSURL *amproj_retryImportURL = nil;
static NSString *amproj_retryImportName = nil;
static __thread NSUInteger amproj_openURLForwardDepth = 0;
static __thread NSUInteger amproj_handleOpenURLForwardDepth = 0;
static __thread NSUInteger amproj_activityForwardDepth = 0;
static __thread NSUInteger amproj_willFinishForwardDepth = 0;
static __thread NSUInteger amproj_didFinishForwardDepth = 0;
static __thread NSUInteger amproj_legacyOpenURLForwardDepth = 0;
static __thread NSUInteger amproj_configurationForwardDepth = 0;
static __thread NSUInteger amproj_sceneWillConnectForwardDepth = 0;
static __thread NSUInteger amproj_sceneOpenURLForwardDepth = 0;

static void amproj_tryDispatchPendingImport(NSUInteger generation);
static void amproj_activateNextPendingImport(void);
static void amproj_resumeQueuedImports(NSString *source);
static void amproj_queuePreparedImport(NSURL *URL, NSString *originalName,
                                       NSString *transactionID);
static void amproj_retryDeferredLaunchImportCandidates(void);
static BOOL amproj_write865ProjectStoreImport(NSURL *preparedArchiveURL,
                                              NSString *originalName,
                                              NSString *transactionID,
                                              NSString * _Nullable * _Nullable titleOut);
static void amproj_installNativeXMLDelegateHook(Class cls);
static NSString* amproj_compactNativeDiagnostic(NSString *text,
                                                 NSUInteger maximumLength);
static NSString* amproj_visibleNativeParserSummary(NSDictionary *snapshot);
static AMProjImportTransaction *amproj_importTransactionForID(
    NSString *transactionID);
static void amproj_releaseImportTransaction(NSString *transactionID,
                                             BOOL success);
static void amproj_showImportStatusForTransaction(NSString *text, BOOL error,
                                                   NSString *transactionID);
static void amproj_failImportedProjectVerification(
    NSString *transactionID, NSString *name, NSUInteger attempt,
    NSString *reason) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    NSString *failureReason = reason.length ? reason :
        @"原生导入回调已完成，但底部“项目”中没有找到新项目";
    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = transaction.archiveURL;
    amproj_retryImportName = [transaction.name copy] ?: [name copy];
    amproj_writeImportBreadcrumb(
        transactionID, transaction.fingerprint, @"failed",
        transaction.source, nil, @4, failureReason);
    amproj_releaseImportTransaction(transactionID, NO);
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = nil;
    amproj_debugEvent(@"import.project_row_missing", @{
        @"transaction_id": transactionID ?: @"",
        @"filename": name ?: @"project.amproj",
        @"attempts": @(attempt + 1),
        @"cache_path": transaction.archiveURL.path ?: @"",
        @"error": failureReason
    });
    NSString *visible = [NSString stringWithFormat:
        @"AMProj · 导入未完成：%@。缓存包已保留，可重试。",
        failureReason];
    amproj_showImportStatusForTransaction(visible, YES, transactionID);
    amproj_presentImportErrorOfferingPicker(visible, NO);
    amproj_resumeQueuedImports(@"project_row_missing");
}

static void amproj_verifyImportedProjectRow(NSUInteger generation,
                                            NSString *name,
                                            NSString *transactionID,
                                            NSUInteger attempt);
static void amproj_verifyNativeXMLTemplateImport(NSUInteger generation,
                                                  NSString *name,
                                                  NSString *transactionID,
                                                  NSUInteger attempt);
static void amproj_captureActivatedPackageBaselines(NSURL *URL,
                                                     NSString *name,
                                                     NSString *transactionID);
static void amproj_beginXMLTemplateImport(NSURL *URL,
                                          NSString *name,
                                          NSString *transactionID,
                                          NSUInteger attempt);
static void amproj_beginTemplatePromotion(NSString *transactionID,
                                           NSUInteger generation,
                                           NSString *name,
                                           NSUInteger attempt);
static void amproj_beginSwiftUITemplatePromotion(NSString *transactionID,
                                                  NSUInteger generation,
                                                  NSString *name,
                                                  NSUInteger attempt);
static void amproj_cleanupPromotedTemplate(NSString *transactionID,
                                            NSUInteger generation,
                                            NSString *name,
                                            NSUInteger attempt);
static void amproj_cleanupSwiftUIPromotedTemplate(NSString *transactionID,
                                                   NSUInteger generation,
                                                   NSString *name,
                                                   NSUInteger attempt);
static void amproj_enqueueXMLTemplateImport(NSURL *URL,
                                             NSString *name,
                                             NSString *transactionID);
static void amproj_pumpXMLTemplateImports(void);
static void amproj_resumeAfterXMLResultAlert(NSUInteger attempt);

static NSObject* amproj_importDedupeLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static void amproj_importTransactionStoreLocked(void) {
    if (!amproj_importTransactions) {
        amproj_importTransactions = [NSMutableDictionary dictionary];
        amproj_importKeyOwners = [NSMutableDictionary dictionary];
        amproj_importTombstones = [NSMutableDictionary dictionary];
        amproj_importDuplicateOwners = [NSMutableDictionary dictionary];
    }
}

static NSString *amproj_importProvisionalKey(NSURL *URL, NSString *name) {
    NSString *path = amproj_normalizedFilePath(URL) ?: URL.absoluteString ?: @"";
    NSNumber *size = nil;
    if (![URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil] ||
        ![size isKindOfClass:NSNumber.class]) size = @0;
    NSString *base = name.length ? name.lowercaseString : URL.lastPathComponent.lowercaseString;
    return [NSString stringWithFormat:@"%@|%@|%@", path, base ?: @"", size];
}

static AMProjImportTransaction *amproj_importTransactionForID(NSString *transactionID) {
    if (!transactionID.length) return nil;
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        return amproj_importTransactions[transactionID];
    }
}

static BOOL amproj_importHasLiveTransaction(void) {
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        for (AMProjImportTransaction *transaction in amproj_importTransactions.allValues) {
            if (transaction.state != AMProjImportTransactionCompleted &&
                transaction.state != AMProjImportTransactionFailed) return YES;
        }
    }
    return NO;
}

static BOOL amproj_hasDeferredLaunchImportCandidates(void) {
    @synchronized (amproj_importDedupeLock()) {
        return amproj_deferredLaunchImportCandidates.count > 0;
    }
}

static BOOL amproj_claimImportTransaction(NSURL *URL, NSString *name,
                                           NSString *source, NSString **transactionID,
                                           BOOL *duplicate) {
    if (transactionID) *transactionID = nil;
    if (duplicate) *duplicate = NO;
    NSString *key = amproj_importProvisionalKey(URL, name);
    if (!key.length) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        NSArray<NSString *> *expired = [amproj_importTombstones.allKeys
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSString *candidate, NSDictionary *_) {
            return now - amproj_importTombstones[candidate].doubleValue > 6.0;
        }]];
        [amproj_importTombstones removeObjectsForKeys:expired];
        NSString *ownerID = amproj_importKeyOwners[key];
        AMProjImportTransaction *existing = ownerID
            ? amproj_importTransactions[ownerID] : nil;
        NSString *duplicateFingerprint = amproj_importDuplicateOwners[key];
        if (duplicateFingerprint.length) {
            NSString *fingerprintOwner = amproj_importKeyOwners[
                [@"fingerprint:" stringByAppendingString:duplicateFingerprint]];
            if (fingerprintOwner.length &&
                amproj_importTransactions[fingerprintOwner]) {
                if (duplicate) *duplicate = YES;
                return NO;
            }
            [amproj_importDuplicateOwners removeObjectForKey:key];
        }
        if (existing && now - existing.updatedAt > 900.0 &&
            existing.state != AMProjImportTransactionNativeActive &&
            existing.state != AMProjImportTransactionCompleted) {
            NSArray<NSString *> *staleKeys = [amproj_importKeyOwners.allKeys
                filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                    ^BOOL(NSString *candidate, NSDictionary *_) {
                return [amproj_importKeyOwners[candidate]
                    isEqualToString:existing.transactionID];
            }]];
            [amproj_importKeyOwners removeObjectsForKeys:staleKeys];
            [amproj_importTransactions removeObjectForKey:existing.transactionID];
            existing = nil;
            ownerID = nil;
        }
        if (ownerID && !existing && ![ownerID isEqualToString:@"tombstone"]) {
            [amproj_importKeyOwners removeObjectForKey:key];
            ownerID = nil;
        }
        if (!ownerID && amproj_importTombstones[[@"provisional:" stringByAppendingString:key]]) {
            ownerID = @"tombstone";
        }
        if (ownerID && !existing) {
            if (duplicate) *duplicate = YES;
            return NO;
        }
        if (existing && existing.state != AMProjImportTransactionFailed) {
            existing.updatedAt = now;
            if (duplicate) *duplicate = YES;
            if (transactionID) *transactionID = existing.transactionID;
            return NO;
        }
        AMProjImportTransaction *transaction = [AMProjImportTransaction new];
        transaction.transactionID = NSUUID.UUID.UUIDString.lowercaseString;
        transaction.provisionalKey = key;
        transaction.name = name.length ? [name copy] : (URL.lastPathComponent ?: @"project.amproj");
        transaction.source = source ?: @"unknown";
        transaction.state = AMProjImportTransactionCaptured;
        transaction.updatedAt = now;
        amproj_importTransactions[transaction.transactionID] = transaction;
        amproj_importKeyOwners[key] = transaction.transactionID;
        amproj_clearIncomingGrantLoss(transaction.name);
        if (transactionID) *transactionID = transaction.transactionID;
        return YES;
    }
}

static BOOL amproj_claimImportFingerprint(NSString *transactionID, NSURL *archiveURL,
                                          NSString *fingerprint, BOOL *duplicate) {
    if (duplicate) *duplicate = NO;
    if (!transactionID.length || !fingerprint.length) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        AMProjImportTransaction *transaction = amproj_importTransactions[transactionID];
        if (!transaction) return NO;
        NSString *fingerprintKey = [@"fingerprint:" stringByAppendingString:fingerprint];
        NSString *ownerID = amproj_importKeyOwners[fingerprintKey];
        if (!ownerID && amproj_importTombstones[fingerprint]) {
            ownerID = @"tombstone";
        }
        if (ownerID && ![ownerID isEqualToString:@"tombstone"] &&
            !amproj_importTransactions[ownerID]) {
            [amproj_importKeyOwners removeObjectForKey:fingerprintKey];
            ownerID = nil;
        }
        if ([ownerID isEqualToString:@"tombstone"]) {
            // A previous successful transaction already absorbed this content.
            // Let the caller discard this duplicate source immediately; do not
            // create a waiter with no live owner that could release it later.
            if (duplicate) *duplicate = YES;
            return NO;
        }
        if (ownerID && ![ownerID isEqualToString:transactionID]) {
            // Keep this transaction as a waiter. Its source must remain intact
            // until the owner transaction succeeds; otherwise a failed owner
            // would destroy the only retryable copy received from the provider.
            transaction.fingerprint = [fingerprint copy];
            transaction.duplicateOfFingerprint = [fingerprint copy];
            transaction.archiveURL = archiveURL;
            transaction.stagedDirectoryURL = archiveURL.URLByDeletingLastPathComponent;
            transaction.state = AMProjImportTransactionValidating;
            transaction.updatedAt = now;
            amproj_importDuplicateOwners[transaction.provisionalKey] = fingerprint;
            if (duplicate) *duplicate = YES;
            return NO;
        }
        transaction.fingerprint = [fingerprint copy];
        transaction.archiveURL = archiveURL;
        transaction.stagedDirectoryURL = archiveURL.URLByDeletingLastPathComponent;
        transaction.state = AMProjImportTransactionValidating;
        transaction.updatedAt = now;
        amproj_importKeyOwners[fingerprintKey] = transactionID;
        return YES;
    }
}

static void amproj_releaseImportTransaction(NSString *transactionID, BOOL success) {
    if (!transactionID.length) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSDictionary *> *dependentCleanup = [NSMutableArray array];
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        AMProjImportTransaction *transaction = amproj_importTransactions[transactionID];
        if (!transaction) return;
        transaction.state = success ? AMProjImportTransactionCompleted
                                    : AMProjImportTransactionFailed;
        transaction.updatedAt = now;
        if (success) {
            amproj_clearIncomingGrantLoss(transaction.name);
        }
        if (success) {
            if (transaction.fingerprint.length) {
                amproj_importTombstones[transaction.fingerprint] = @(now);
            }
            if (transaction.provisionalKey.length) {
                amproj_importTombstones[[@"provisional:" stringByAppendingString:
                                          transaction.provisionalKey]] = @(now);
            }
        } else if (transaction.provisionalKey.length) {
            // Absorb late lifecycle/provider callbacks after a failure. An
            // explicit retry clears this short-lived tombstone first.
            amproj_importTombstones[[@"provisional:" stringByAppendingString:
                                      transaction.provisionalKey]] = @(now);
        }
        // A waiter also carries the content fingerprint, but it must never
        // release the other waiters owned by the real transaction.
        NSString *ownerFingerprint = transaction.duplicateOfFingerprint.length
            ? nil : transaction.fingerprint;
        NSArray<AMProjImportTransaction *> *dependents = ownerFingerprint.length
            ? [amproj_importTransactions.allValues filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(AMProjImportTransaction *candidate,
                                                       NSDictionary *_) {
                return [candidate.duplicateOfFingerprint isEqualToString:ownerFingerprint];
            }]] : @[];
        for (AMProjImportTransaction *dependent in dependents) {
            if (dependent.provisionalKey.length) {
                if (success) {
                    amproj_importTombstones[[@"provisional:" stringByAppendingString:
                                              dependent.provisionalKey]] = @(now);
                }
                [amproj_importKeyOwners removeObjectForKey:dependent.provisionalKey];
                [amproj_importDuplicateOwners removeObjectForKey:dependent.provisionalKey];
            }
            if (dependent.stagedDirectoryURL) {
                [dependentCleanup addObject:@{
                    @"staged": dependent.stagedDirectoryURL,
                    @"success": @(success)
                }];
            }
            if (success) {
                if (dependent.incomingCleanupURL) {
                    [dependentCleanup addObject:@{
                        @"incoming": dependent.incomingCleanupURL,
                        @"success": @YES
                    }];
                } else if (dependent.deleteIncomingSourceOnCompletion &&
                           dependent.incomingURL) {
                    [dependentCleanup addObject:@{
                        @"incoming": dependent.incomingURL,
                        @"success": @YES
                    }];
                }
            }
            [amproj_importTransactions removeObjectForKey:dependent.transactionID];
        }
        if (transaction.duplicateOfFingerprint.length && transaction.provisionalKey.length) {
            [amproj_importDuplicateOwners removeObjectForKey:transaction.provisionalKey];
        }
        NSArray<NSString *> *keys = [amproj_importKeyOwners.allKeys
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(NSString *key, NSDictionary *_) {
            return [amproj_importKeyOwners[key] isEqualToString:transactionID];
        }]];
        [amproj_importKeyOwners removeObjectsForKeys:keys];
        [amproj_importTransactions removeObjectForKey:transactionID];
    }
    for (NSDictionary *cleanup in dependentCleanup) {
        // A failed owner leaves each dependent's staged copy available for an
        // explicit retry. Only an owner success has established that the
        // identical content was persisted and made those copies disposable.
        if (![cleanup[@"success"] boolValue]) continue;
        NSURL *URL = cleanup[@"staged"] ?: cleanup[@"incoming"];
        if (URL) [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
    }
}

static void amproj_releaseImportTransactionForURL(NSURL *URL, NSString *name) {
    NSString *key = amproj_importProvisionalKey(URL, name);
    NSString *transactionID = nil;
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        transactionID = [amproj_importKeyOwners[key] copy];
        if (!transactionID.length) {
            NSString *path = amproj_normalizedFilePath(URL);
            for (AMProjImportTransaction *candidate in amproj_importTransactions.allValues) {
                if ([amproj_normalizedFilePath(candidate.incomingURL)
                     isEqualToString:path]) {
                    transactionID = [candidate.transactionID copy];
                    break;
                }
            }
        }
    }
    if (transactionID.length) amproj_releaseImportTransaction(transactionID, NO);
}

static void amproj_clearImportSuppression(NSURL *URL, NSString *name) {
    NSString *key = amproj_importProvisionalKey(URL, name);
    if (!key.length) return;
    @synchronized (amproj_importDedupeLock()) {
        amproj_importTransactionStoreLocked();
        [amproj_importTombstones removeObjectForKey:
            [@"provisional:" stringByAppendingString:key]];
        [amproj_importDuplicateOwners removeObjectForKey:key];
    }
}

static void amproj_markImportTransactionState(NSString *transactionID,
                                               AMProjImportTransactionState state) {
    if (!transactionID.length) return;
    NSString *snapshotID = nil;
    NSString *snapshotFingerprint = nil;
    NSString *snapshotSource = nil;
    @synchronized (amproj_importDedupeLock()) {
        AMProjImportTransaction *transaction = amproj_importTransactions[transactionID];
        if (!transaction) return;
        transaction.state = state;
        transaction.updatedAt = CFAbsoluteTimeGetCurrent();
        snapshotID = [transaction.transactionID copy];
        snapshotFingerprint = [transaction.fingerprint copy];
        snapshotSource = [transaction.source copy];
    }
    NSArray<NSString *> *phases = @[
        @"captured", @"copying", @"validating", @"queued",
        @"waiting_for_projects", @"native_active", @"template_detected",
        @"creating_project", @"project_verified", @"cleaning_template",
        @"completed", @"failed"
    ];
    NSString *phase = state >= 0 && state < phases.count ? phases[state] : @"unknown";
    amproj_writeImportBreadcrumb(snapshotID, snapshotFingerprint, phase,
                                 snapshotSource, nil, nil, nil);
}

static NSObject* amproj_nativeParserLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static void amproj_beginNativeImportObservation(NSString *name) {
    amproj_nativeImportObservationActive = YES;
    ++amproj_nativeImportObservationGeneration;
    amproj_nativeImportObservationName = [name copy] ?: @"project.amproj";
    amproj_nativeImportObservationStartedAt = CFAbsoluteTimeGetCurrent();
    @synchronized (amproj_nativeParserLock()) {
        amproj_nativeImportAttemptID = NSUUID.UUID.UUIDString.lowercaseString;
        amproj_nativeImportObservationPhase = @"recognition";
        amproj_nativeParserSnapshot = nil;
    }
}

static void amproj_endNativeImportObservation(void) {
    amproj_nativeImportObservationActive = NO;
    ++amproj_nativeImportObservationGeneration;
    amproj_nativeImportObservationName = nil;
    amproj_nativeImportObservationStartedAt = 0;
    @synchronized (amproj_nativeParserLock()) {
        amproj_nativeImportAttemptID = nil;
        amproj_nativeImportObservationPhase = nil;
    }
}

static NSString* amproj_currentNativeImportAttemptID(void) {
    @synchronized (amproj_nativeParserLock()) {
        return [amproj_nativeImportAttemptID copy];
    }
}

static NSString* amproj_currentNativeImportObservationPhase(void) {
    @synchronized (amproj_nativeParserLock()) {
        return [amproj_nativeImportObservationPhase copy];
    }
}

static void amproj_setNativeImportObservationPhase(NSString *phase) {
    @synchronized (amproj_nativeParserLock()) {
        if (amproj_nativeImportAttemptID.length) {
            amproj_nativeImportObservationPhase = [phase copy];
        }
    }
}

static NSDictionary* amproj_currentNativeParserSnapshot(void) {
    @synchronized (amproj_nativeParserLock()) {
        return [amproj_nativeParserSnapshot copy];
    }
}

static void amproj_storeNativeParserSnapshot(NSString *attemptID,
                                              NSDictionary *snapshot) {
    if (!attemptID.length || !snapshot.count) return;
    @synchronized (amproj_nativeParserLock()) {
        if ([attemptID isEqualToString:amproj_nativeImportAttemptID]) {
            BOOL incomingFailure = [snapshot[@"semantic_error_count"] unsignedIntegerValue] > 0 ||
                (snapshot[@"result"] && ![snapshot[@"result"] boolValue]);
            BOOL existingFailure =
                [amproj_nativeParserSnapshot[@"semantic_error_count"] unsignedIntegerValue] > 0 ||
                (amproj_nativeParserSnapshot[@"result"] &&
                 ![amproj_nativeParserSnapshot[@"result"] boolValue]);
            BOOL incomingCommit = [snapshot[@"import_phase"] isEqual:@"commit"];
            BOOL existingCommit =
                [amproj_nativeParserSnapshot[@"import_phase"] isEqual:@"commit"];
            if (!amproj_nativeParserSnapshot ||
                (incomingFailure && !existingFailure) ||
                (incomingCommit && !existingCommit)) {
                amproj_nativeParserSnapshot = [snapshot copy];
            }
        }
    }
}

static NSDictionary* amproj_nativeImportObservationFields(void) {
    NSTimeInterval elapsed = amproj_nativeImportObservationStartedAt > 0
        ? MAX(0, (CFAbsoluteTimeGetCurrent() -
                  amproj_nativeImportObservationStartedAt) * 1000.0)
        : 0;
    return @{
        @"attempt_id": amproj_currentNativeImportAttemptID() ?: @"",
        @"phase": amproj_currentNativeImportObservationPhase() ?: @"",
        @"filename": amproj_nativeImportObservationName ?: @"project.amproj",
        @"elapsed_ms": @(elapsed)
    };
}

static IMP amproj_originalHookForReceiver(AMProjTrackedHook *hooks, NSUInteger count,
                                         id receiver) {
    Class receiverClass = object_getClass(receiver);
    for (Class cls = receiverClass; cls; cls = class_getSuperclass(cls)) {
        for (NSUInteger index = 0; index < count; index++) {
            if (hooks[index].cls == cls && hooks[index].original) {
                return hooks[index].original;
            }
        }
    }
    return NULL;
}

static IMP amproj_originalHookForClass(AMProjTrackedHook *hooks, NSUInteger count,
                                      Class targetClass) {
    if (!targetClass) return NULL;
    for (NSUInteger index = 0; index < count; index++) {
        if (hooks[index].cls == targetClass && hooks[index].original) {
            return hooks[index].base ? hooks[index].base : hooks[index].original;
        }
    }
    return NULL;
}

static IMP amproj_originalHookForReceiverSkippingExact(AMProjTrackedHook *hooks,
                                                       NSUInteger count, id receiver) {
    Class receiverClass = object_getClass(receiver);
    for (NSUInteger index = 0; index < count; index++) {
        if (hooks[index].cls == receiverClass && hooks[index].base &&
            hooks[index].original != hooks[index].base) {
            return hooks[index].base;
        }
    }
    for (Class cls = class_getSuperclass(receiverClass); cls; cls = class_getSuperclass(cls)) {
        for (NSUInteger index = 0; index < count; index++) {
            if (hooks[index].cls == cls && hooks[index].original) {
                return hooks[index].base ? hooks[index].base : hooks[index].original;
            }
        }
    }
    return NULL;
}

static BOOL amproj_storeOriginalHook(AMProjTrackedHook *hooks, NSUInteger count,
                                     Class cls, IMP original) {
    if (!cls || !original) return NO;
    for (NSUInteger index = 0; index < count; index++) {
        if (hooks[index].cls == cls) {
            if (!hooks[index].base) {
                hooks[index].base = hooks[index].original
                    ? hooks[index].original : original;
            }
            hooks[index].original = original;
            return YES;
        }
    }
    for (NSUInteger index = 0; index < count; index++) {
        if (!hooks[index].cls) {
            hooks[index].cls = cls;
            hooks[index].original = original;
            hooks[index].base = original;
            return YES;
        }
    }
    return NO;
}

static UIWindow* amproj_importForegroundWindow(void) {
    UIWindow *window = amproj_keyWindow();
    if (window) return window;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (!candidate.hidden && candidate.alpha > 0.0 &&
            candidate.windowLevel == UIWindowLevelNormal) {
            return candidate;
        }
    }
    return nil;
}

static NSInteger amproj_statusStageRank(NSString *text) {
    if ([text containsString:@"1/4"]) return 1;
    if ([text containsString:@"1/3"]) return 1;
    if ([text containsString:@"2/4"]) return 2;
    if ([text containsString:@"2/3"]) return 2;
    if ([text containsString:@"3/4"]) return 3;
    if ([text containsString:@"4/4"]) return 4;
    return 0;
}

static void amproj_showImportStatusAttempt(NSString *text, BOOL error,
                                           NSUInteger generation, NSUInteger attempt) {
    if (generation != amproj_importStatusGeneration) return;
    UIWindow *window = amproj_importForegroundWindow();
    if (!window) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_showImportStatusAttempt(text, error, generation, attempt + 1);
            });
        }
        return;
    }

    UILabel *banner = [amproj_importStatusBanner isKindOfClass:UILabel.class]
        ? amproj_importStatusBanner : nil;
    if (!banner || banner.superview != window) {
        [banner removeFromSuperview];
        banner = [[UILabel alloc] initWithFrame:CGRectZero];
        banner.userInteractionEnabled = NO;
        banner.textAlignment = NSTextAlignmentCenter;
        banner.textColor = UIColor.whiteColor;
        banner.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        banner.numberOfLines = 2;
        banner.layer.cornerRadius = 10.0;
        banner.layer.masksToBounds = YES;
        banner.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:banner];
        amproj_importStatusBanner = banner;
    }
    CGFloat top = MAX(window.safeAreaInsets.top, 8.0) + 44.0;
    banner.frame = CGRectMake(12.0, top, MAX(window.bounds.size.width - 24.0, 120.0), 42.0);
    banner.text = text;
    banner.backgroundColor = error
        ? [UIColor colorWithRed:0.68 green:0.10 blue:0.10 alpha:0.96]
        : [UIColor colorWithRed:0.07 green:0.34 blue:0.66 alpha:0.96];
    banner.alpha = 1.0;
    [window bringSubviewToFront:banner];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (generation != amproj_importStatusGeneration ||
            banner != amproj_importStatusBanner) return;
        [UIView animateWithDuration:0.2 animations:^{ banner.alpha = 0.0; }
                         completion:^(__unused BOOL finished) { [banner removeFromSuperview]; }];
    });
}

static void amproj_showImportStatusForTransaction(NSString *text, BOOL error,
                                                  NSString *transactionID) {
    NSString *snapshot = [text copy] ?: [NSString stringWithFormat:
        @"AMProj v%@ import", kAMProjPluginVersion];
    NSString *transactionSnapshot = [transactionID copy];
    NSInteger rank = amproj_statusStageRank(snapshot);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (transactionSnapshot.length &&
            amproj_visibleStatusTransactionID.length &&
            ![transactionSnapshot isEqualToString:amproj_visibleStatusTransactionID]) {
            AMProjImportTransaction *visibleTransaction =
                amproj_importTransactionForID(amproj_visibleStatusTransactionID);
            if (visibleTransaction) {
                amproj_debugEvent(@"import.status_suppressed", @{
                    @"transaction_id": transactionSnapshot,
                    @"visible_transaction_id": amproj_visibleStatusTransactionID,
                    @"reason": @"stale_transaction",
                    @"text": snapshot
                });
                return;
            }
            amproj_visibleStatusTransactionID = transactionSnapshot;
            amproj_importVisibleStageRank = 0;
        }
        if (transactionSnapshot.length && !amproj_visibleStatusTransactionID.length) {
            amproj_visibleStatusTransactionID = transactionSnapshot;
        }
        if (!error && rank > 0 && amproj_importVisibleStageRank > rank) {
            amproj_debugEvent(@"import.status_suppressed", @{
                @"requested_rank": @(rank),
                @"visible_rank": @(amproj_importVisibleStageRank),
                @"text": snapshot
            });
            return;
        }
        if (rank > amproj_importVisibleStageRank) {
            amproj_importVisibleStageRank = rank;
        }
        NSUInteger generation = ++amproj_importStatusGeneration;
        amproj_debugEvent(@"import.status", @{
            @"transaction_id": amproj_visibleStatusTransactionID ?: @"",
            @"text": snapshot,
            @"error": @(error),
            @"stage": @(rank)
        });
        amproj_showImportStatusAttempt(snapshot, error, generation, 0);
    });
}

static void amproj_showImportStatus(NSString *text, BOOL error) {
    amproj_showImportStatusForTransaction(text, error, nil);
}

static NSURL* amproj_importCacheRoot(void) {
    NSURL *support = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"AMProjImports" isDirectory:YES];
}

static void amproj_purgeOldImports(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *root = amproj_importCacheRoot();
        NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                               error:nil];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-7.0 * 24.0 * 60.0 * 60.0];
        for (NSURL *entry in entries) {
            NSDate *modified = nil;
            [entry getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
            if (modified && [modified compare:cutoff] == NSOrderedAscending) {
                [manager removeItemAtURL:entry error:nil];
            }
        }
    });
}

typedef NS_ENUM(NSInteger, AMProjImportFileError) {
    AMProjImportFileErrorOpenSource = 20,
    AMProjImportFileErrorReadSource = 21,
    AMProjImportFileErrorWriteCache = 22,
    AMProjImportFileErrorFinalizeCache = 23,
    AMProjImportFileErrorInvalidZIP = 30,
    AMProjImportFileErrorUnsupportedZIP = 31,
};

static NSString* amproj_copyDiagnosticSummary(NSError *error);

// QQ/File Provider grants frequently expire between the launch-options
// delivery and the actual copy (errno 1 / NSCocoaErrorDomain 257). QQ then
// re-delivers the very same document through the openURL callback with a
// fresh grant, so the first failed copy must stay silent and simply wait
// for that redelivery. Only if no redelivery (or successful import)
// arrives in time does a single concise alert appear.
static NSObject *amproj_pendingRedeliveryLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, NSNumber *> *amproj_pendingRedeliveryDeadlines(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static NSString *amproj_pendingRedeliveryKey(NSString *name) {
    return (name.length ? name : @"project").lowercaseString ?: @"";
}

static void amproj_noteIncomingGrantLoss(NSString *name, BOOL isXML) {
    if (!name.length) return;
    NSString *key = amproj_pendingRedeliveryKey(name);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 10.0;
    BOOL scheduleCheck = NO;
    @synchronized (amproj_pendingRedeliveryLock()) {
        scheduleCheck = amproj_pendingRedeliveryDeadlines()[key] == nil;
        amproj_pendingRedeliveryDeadlines()[key] = @(deadline);
    }
    amproj_logCriticalEvent(@"import.grant_loss_awaiting_redelivery", @{
        @"filename": name ?: @"",
        @"kind": isXML ? @"xml" : @"amproj"
    });
    if (!scheduleCheck) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL stillPending = NO;
        @synchronized (amproj_pendingRedeliveryLock()) {
            NSNumber *stored = amproj_pendingRedeliveryDeadlines()[key];
            stillPending = stored != nil &&
                stored.doubleValue <= CFAbsoluteTimeGetCurrent();
            if (stillPending) [amproj_pendingRedeliveryDeadlines() removeObjectForKey:key];
        }
        if (!stillPending) return;
        amproj_showImportStatus([NSString stringWithFormat:
            @"AMProj · 未能读取《%@》，请回到 QQ 重新用其他应用打开一次",
            name], YES);
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:isXML ? @"无法导入 XML" : @"无法导入 .amproj"
            message:[NSString stringWithFormat:
                @"QQ 提供的《%@》已过期，无法读取。请回到 QQ 重新选择“用其他应用打开”。",
                name]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
            style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter = amproj_topViewController(
            amproj_keyWindow().rootViewController);
        if (presenter && !presenter.presentedViewController &&
            presenter.viewIfLoaded.window) {
            orig_presentVC(presenter,
                @selector(presentViewController:animated:completion:),
                alert, YES, nil);
        }
    });
}

static void amproj_clearIncomingGrantLoss(NSString *name) {
    if (!name.length) return;
    @synchronized (amproj_pendingRedeliveryLock()) {
        [amproj_pendingRedeliveryDeadlines()
            removeObjectForKey:amproj_pendingRedeliveryKey(name)];
    }
}

static NSString* amproj_visibleImportFileError(NSError *error) {
    NSString *message = nil;
    switch (error.code) {
        case AMProjImportFileErrorOpenSource:
            message = @"\u65e0\u6cd5\u6253\u5f00 QQ/\u6587\u4ef6 App \u63d0\u4f9b\u7684\u6587\u4ef6";
            break;
        case AMProjImportFileErrorReadSource:
            message = @"\u8bfb\u53d6 QQ \u6587\u4ef6\u65f6\u4e2d\u65ad";
            break;
        case AMProjImportFileErrorWriteCache:
            message = @"\u5199\u5165 AM \u5bfc\u5165\u7f13\u5b58\u5931\u8d25";
            break;
        case AMProjImportFileErrorFinalizeCache:
            message = @"\u5bfc\u5165\u7f13\u5b58\u5b8c\u6210\u5931\u8d25";
            break;
        case AMProjImportFileErrorInvalidZIP:
            if ([error.localizedDescription.lowercaseString containsString:@"manifest.txt"]) {
                message = [error.localizedDescription.lowercaseString containsString:@"no manifest"]
                    ? @"\u9879\u76ee\u5305\u7f3a\u5c11 manifest.txt"
                    : @"\u9879\u76ee\u5305\u5fc5\u987b\u6070\u597d\u5305\u542b\u4e00\u4e2a manifest.txt";
            } else if ([error.localizedDescription.lowercaseString containsString:@"scene xml"]) {
                message = [error.localizedDescription.lowercaseString containsString:@"no scene"]
                    ? @"\u9879\u76ee\u5305\u7f3a\u5c11\u573a\u666f XML"
                    : @"\u9879\u76ee\u5305\u5fc5\u987b\u6070\u597d\u5305\u542b\u4e00\u4e2a\u573a\u666f XML";
            } else {
                message = @"ZIP \u7ed3\u6784\u65e0\u6548\u6216\u5df2\u635f\u574f";
            }
            break;
        case AMProjImportFileErrorUnsupportedZIP:
            message = @"\u6682\u4e0d\u652f\u6301 ZIP64 \u6216\u5206\u5377 ZIP";
            break;
        default:
            message = @"\u9879\u76ee\u5305\u8bfb\u53d6\u5931\u8d25";
            break;
    }
    // User-facing text never carries NSError details, errno values or
    // internal diagnostics; those stay in the debug event stream only.
    return [NSString stringWithFormat:@"AMProj \u00b7 %@", message];
}

static NSError* amproj_importFileError(AMProjImportFileError code,
                                       NSString *description, int posixError,
                                       NSError *underlyingError) {
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:
        (description.length ? description : @"Project package file error")
                                                                    forKey:NSLocalizedDescriptionKey];
    if (posixError) details[@"posix_errno"] = @(posixError);
    if (underlyingError) details[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"com.amproj.import.file" code:code userInfo:details];
}

static NSNumber* amproj_posixNumberFromError(NSError *error) {
    if (!error) return nil;
    NSNumber *recorded = error.userInfo[@"posix_errno"];
    if ([recorded isKindOfClass:NSNumber.class] && recorded.intValue) return recorded;
    if ([error.domain isEqualToString:NSPOSIXErrorDomain] && error.code) {
        return @(error.code);
    }
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:NSError.class] && underlying != error) {
        return amproj_posixNumberFromError(underlying);
    }
    return nil;
}

static NSDictionary* amproj_copyAttemptDiagnostic(NSString *method, NSError *error) {
    NSError *reported = error;
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([error.domain isEqualToString:@"com.amproj.import.file"] &&
        [underlying isKindOfClass:NSError.class]) {
        reported = underlying;
    }
    NSMutableDictionary *diagnostic = [@{
        @"method": method ?: @"unknown",
        @"domain": reported.domain ?: error.domain ?: @"unknown",
        @"code": @(reported ? reported.code : 0),
        @"error": reported.localizedDescription ?: error.localizedDescription ?: @"Unknown error"
    } mutableCopy];
    NSNumber *posix = amproj_posixNumberFromError(error);
    if (posix) diagnostic[@"posix_errno"] = posix;
    return diagnostic;
}

static NSError* amproj_aggregateCopyError(NSArray<NSDictionary *> *attempts,
                                          NSError *lastError) {
    AMProjImportFileError code = AMProjImportFileErrorOpenSource;
    if ([lastError.domain isEqualToString:@"com.amproj.import.file"] &&
        lastError.code >= AMProjImportFileErrorOpenSource &&
        lastError.code <= AMProjImportFileErrorFinalizeCache) {
        code = (AMProjImportFileError)lastError.code;
    }
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:
        @"All supported File Provider read methods failed"
                                                                    forKey:NSLocalizedDescriptionKey];
    if (attempts.count) details[@"copy_attempts"] = attempts;
    NSNumber *posix = amproj_posixNumberFromError(lastError);
    if (posix) details[@"posix_errno"] = posix;
    if (lastError) details[NSUnderlyingErrorKey] = lastError;
    return [NSError errorWithDomain:@"com.amproj.import.file" code:code userInfo:details];
}

static NSString* amproj_copyDiagnosticSummary(NSError *error) {
    NSArray *attempts = error.userInfo[@"copy_attempts"];
    if (![attempts isKindOfClass:NSArray.class] || !attempts.count) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *attempt in attempts) {
        if (![attempt isKindOfClass:NSDictionary.class]) continue;
        NSString *method = attempt[@"method"] ?: @"?";
        NSString *domain = attempt[@"domain"] ?: @"?";
        NSNumber *code = attempt[@"code"] ?: @0;
        NSNumber *posix = attempt[@"posix_errno"];
        NSString *part = [NSString stringWithFormat:@"%@=%@/%@", method, domain, code];
        if (posix.intValue) {
            part = [part stringByAppendingFormat:@" errno=%@", posix];
        }
        [parts addObject:part];
    }
    return [parts componentsJoinedByString:@"; "];
}

static BOOL amproj_readExactlyAt(int descriptor, void *buffer, size_t length,
                                 off_t fileOffset, NSError **error) {
    uint8_t *cursor = buffer;
    size_t remaining = length;
    while (remaining) {
        ssize_t count = pread(descriptor, cursor, remaining, fileOffset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            int savedErrno = count < 0 ? errno : EIO;
            if (error) {
                *error = amproj_importFileError(
                    AMProjImportFileErrorReadSource,
                    @"Unable to read the copied project package", savedErrno, nil);
            }
            return NO;
        }
        cursor += (size_t)count;
        fileOffset += count;
        remaining -= (size_t)count;
    }
    return YES;
}

static uint16_t amproj_zipUInt16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t amproj_zipUInt32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static BOOL amproj_zipNameHasXMLSuffix(const uint8_t *bytes, size_t length) {
    if (!bytes || length < 4 || bytes[length - 4] != '.') return NO;
    return bytes[length - 3] == 'x' &&
           bytes[length - 2] == 'm' &&
           bytes[length - 1] == 'l';
}

static BOOL amproj_zipNameIsManifest(const uint8_t *bytes, size_t length) {
    static const char name[] = "manifest.txt";
    if (!bytes || length != sizeof(name) - 1) return NO;
    for (size_t index = 0; index < length; index++) {
        if (bytes[index] != (uint8_t)name[index]) return NO;
    }
    return YES;
}

// Validate the ZIP32 structure without loading project media into memory. The old
// implementation searched only the last 2 MiB for ".xml", which rejected valid
// archives when the central directory was larger than that heuristic window.
static BOOL amproj_validateIncomingArchive(NSURL *URL, NSDictionary **metrics,
                                           NSError **error) {
    if (metrics) *metrics = nil;
    int descriptor = open(URL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) {
        if (error) {
            *error = amproj_importFileError(
                AMProjImportFileErrorOpenSource,
                @"Unable to open the copied project package", errno, nil);
        }
        return NO;
    }

    BOOL valid = NO;
    struct stat information = {0};
    uint8_t *tail = NULL;
    uint8_t *name = NULL;
    NSError *validationError = nil;
    uint16_t entryCount = 0;
    NSUInteger XMLCount = 0;
    NSUInteger manifestCount = 0;

    if (fstat(descriptor, &information) != 0) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorReadSource,
            @"Unable to inspect the copied project package", errno, nil);
        goto cleanup;
    }
    if (!S_ISREG(information.st_mode) || information.st_size < 22) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorInvalidZIP,
            @"The copied project package is empty or is not a regular ZIP file",
            0, nil);
        goto cleanup;
    }

    // EOCD is at most 65,535 bytes of comment plus its 22-byte fixed record.
    size_t tailLength = (size_t)MIN((off_t)(22 + UINT16_MAX), information.st_size);
    tail = malloc(tailLength);
    if (!tail) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorReadSource,
            @"Unable to allocate the ZIP validation buffer", ENOMEM, nil);
        goto cleanup;
    }
    off_t tailOffset = information.st_size - (off_t)tailLength;
    if (!amproj_readExactlyAt(descriptor, tail, tailLength, tailOffset,
                              &validationError)) goto cleanup;

    size_t endIndex = SIZE_MAX;
    for (size_t index = tailLength - 22;; index--) {
        if (tail[index] == 'P' && tail[index + 1] == 'K' &&
            tail[index + 2] == 5 && tail[index + 3] == 6) {
            uint16_t commentLength = amproj_zipUInt16(tail + index + 20);
            if (index + 22 + commentLength == tailLength) {
                endIndex = index;
                break;
            }
        }
        if (index == 0) break;
    }
    if (endIndex == SIZE_MAX) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorInvalidZIP,
            @"The project package has no valid ZIP end record", 0, nil);
        goto cleanup;
    }

    uint16_t diskNumber = amproj_zipUInt16(tail + endIndex + 4);
    uint16_t centralDisk = amproj_zipUInt16(tail + endIndex + 6);
    uint16_t entriesOnDisk = amproj_zipUInt16(tail + endIndex + 8);
    entryCount = amproj_zipUInt16(tail + endIndex + 10);
    uint32_t centralSize = amproj_zipUInt32(tail + endIndex + 12);
    uint32_t centralOffset = amproj_zipUInt32(tail + endIndex + 16);
    off_t endRecordOffset = tailOffset + (off_t)endIndex;
    uint64_t centralEnd = (uint64_t)centralOffset + (uint64_t)centralSize;
    if (diskNumber || centralDisk || entriesOnDisk != entryCount || !entryCount ||
        entryCount == UINT16_MAX || centralSize == UINT32_MAX ||
        centralOffset == UINT32_MAX || centralEnd > (uint64_t)endRecordOffset) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorUnsupportedZIP,
            @"The project package uses an unsupported split or ZIP64 layout", 0, nil);
        goto cleanup;
    }

    uint64_t cursor = centralOffset;
    uint64_t directoryEnd = centralEnd;
    for (uint32_t entryIndex = 0; entryIndex < entryCount; entryIndex++) {
        uint8_t header[46] = {0};
        if (cursor > directoryEnd || directoryEnd - cursor < sizeof(header) ||
            !amproj_readExactlyAt(descriptor, header, sizeof(header), (off_t)cursor,
                                  &validationError)) goto cleanup;
        if (amproj_zipUInt32(header) != 0x02014b50) {
            validationError = amproj_importFileError(
                AMProjImportFileErrorInvalidZIP,
                @"The project package has a damaged ZIP central directory", 0, nil);
            goto cleanup;
        }
        uint16_t nameLength = amproj_zipUInt16(header + 28);
        uint16_t extraLength = amproj_zipUInt16(header + 30);
        uint16_t commentLength = amproj_zipUInt16(header + 32);
        uint64_t recordLength = sizeof(header) + (uint64_t)nameLength +
                                extraLength + commentLength;
        if (!nameLength || recordLength > directoryEnd - cursor) {
            validationError = amproj_importFileError(
                AMProjImportFileErrorInvalidZIP,
                @"The project package contains a damaged ZIP entry", 0, nil);
            goto cleanup;
        }
        name = malloc(nameLength);
        if (!name) {
            validationError = amproj_importFileError(
                AMProjImportFileErrorReadSource,
                @"Unable to allocate the ZIP entry buffer", ENOMEM, nil);
            goto cleanup;
        }
        if (!amproj_readExactlyAt(descriptor, name, nameLength,
                                  (off_t)(cursor + sizeof(header)),
                                  &validationError)) goto cleanup;
        if (amproj_zipNameHasXMLSuffix(name, nameLength)) XMLCount++;
        if (amproj_zipNameIsManifest(name, nameLength)) manifestCount++;
        free(name);
        name = NULL;
        cursor += recordLength;
    }
    if (cursor != directoryEnd) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorInvalidZIP,
            @"The project package central directory length is inconsistent", 0, nil);
        goto cleanup;
    }
    if (metrics) {
        *metrics = @{
            @"bytes": @((unsigned long long)information.st_size),
            @"entries": @(entryCount),
            @"xml_count": @(XMLCount),
            @"manifest": @(manifestCount == 1),
            @"manifest_count": @(manifestCount),
            @"manifest_missing": @(manifestCount == 0),
        };
    }
    if (XMLCount == 0) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorInvalidZIP,
            @"The project package ZIP contains no scene XML",
            0, nil);
        goto cleanup;
    }
    if (manifestCount > 1) {
        validationError = amproj_importFileError(
            AMProjImportFileErrorInvalidZIP,
            @"The project package ZIP may contain at most one manifest.txt",
            0, nil);
        goto cleanup;
    }
    valid = YES;

cleanup:
    if (name) free(name);
    if (tail) free(tail);
    close(descriptor);
    if (!valid && error) *error = validationError ?: amproj_importFileError(
        AMProjImportFileErrorInvalidZIP, @"The project package ZIP is invalid", 0, nil);
    return valid;
}

static NSString* amproj_importCacheFilename(NSString *originalName) {
    NSString *base = [[originalName lastPathComponent] stringByDeletingPathExtension];
    NSMutableCharacterSet *invalid = [NSMutableCharacterSet controlCharacterSet];
    [invalid formUnionWithCharacterSet:NSCharacterSet.illegalCharacterSet];
    [invalid addCharactersInString:@"/:\\"];
    base = [[base componentsSeparatedByCharactersInSet:invalid]
        componentsJoinedByString:@"_"];
    base = [base stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@". \t\r\n"]];
    if (!base.length) base = @"project";
    if (base.length > 80) {
        NSRange range = [base rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 80)];
        base = [base substringWithRange:range];
    }
    NSString *extension = originalName.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"xml"] &&
        ![extension isEqualToString:@"amproj"]) {
        extension = @"amproj";
    }
    return [base stringByAppendingPathExtension:extension];
}

static BOOL amproj_finalizeIncomingPartial(NSFileManager *manager, NSURL *partialURL,
                                           NSURL *destinationURL, uint64_t *copiedBytes,
                                           NSError **error) {
    NSNumber *fileSize = nil;
    NSError *sizeError = nil;
    if (![partialURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:&sizeError] ||
        ![fileSize isKindOfClass:NSNumber.class]) {
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to inspect the copied project package", 0, sizeError);
        return NO;
    }
    NSError *moveError = nil;
    if (![manager moveItemAtURL:partialURL toURL:destinationURL error:&moveError]) {
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorFinalizeCache,
            @"Unable to finalize the local project package cache", 0, moveError);
        return NO;
    }
    if (copiedBytes) *copiedBytes = fileSize.unsignedLongLongValue;
    return YES;
}

static BOOL amproj_foundationCopyIncomingFile(NSURL *sourceURL, NSURL *destinationURL,
                                               uint64_t *copiedBytes, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directoryURL = destinationURL.URLByDeletingLastPathComponent;
    NSURL *partialURL = [directoryURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.partial",
            destinationURL.lastPathComponent ?: @"project.amproj", NSUUID.UUID.UUIDString]];
    NSError *copyError = nil;
    if (![manager copyItemAtURL:sourceURL toURL:partialURL error:&copyError]) {
        [manager removeItemAtURL:partialURL error:nil];
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorOpenSource,
            @"NSFileManager could not copy the coordinated project package", 0, copyError);
        return NO;
    }
    BOOL success = amproj_finalizeIncomingPartial(
        manager, partialURL, destinationURL, copiedBytes, error);
    if (!success) [manager removeItemAtURL:partialURL error:nil];
    return success;
}

static BOOL amproj_fileHandleCopyIncomingFile(NSURL *sourceURL, NSURL *destinationURL,
                                               uint64_t *copiedBytes, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directoryURL = destinationURL.URLByDeletingLastPathComponent;
    NSURL *partialURL = [directoryURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.partial",
            destinationURL.lastPathComponent ?: @"project.amproj", NSUUID.UUID.UUIDString]];
    NSError *copyError = nil;
    NSError *openError = nil;
    NSError *flushError = nil;
    NSError *closeError = nil;
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:sourceURL error:&openError];
    NSFileHandle *output = nil;
    uint64_t total = 0;
    BOOL success = NO;

    if (!input) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorOpenSource,
            @"NSFileHandle could not open the coordinated project package", 0, openError);
        goto cleanup;
    }
    errno = 0;
    if (![manager createFileAtPath:partialURL.path contents:nil attributes:nil]) {
        int savedErrno = errno ?: EIO;
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to create the local project package cache", savedErrno, nil);
        goto cleanup;
    }
    output = [NSFileHandle fileHandleForWritingToURL:partialURL error:&openError];
    if (!output) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"NSFileHandle could not open the local project package cache", 0, openError);
        goto cleanup;
    }

    for (;;) {
        NSError *readError = nil;
        NSData *chunk = [input readDataUpToLength:256 * 1024 error:&readError];
        if (!chunk) {
            copyError = amproj_importFileError(
                AMProjImportFileErrorReadSource,
                @"NSFileHandle stopped while reading the File Provider document", 0, readError);
            goto cleanup;
        }
        if (!chunk.length) break;
        NSError *writeError = nil;
        if (![output writeData:chunk error:&writeError]) {
            copyError = amproj_importFileError(
                AMProjImportFileErrorWriteCache,
                @"NSFileHandle could not write the local project package cache", 0, writeError);
            goto cleanup;
        }
        total += chunk.length;
    }

    if (![output synchronizeAndReturnError:&flushError]) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to flush the local project package cache", 0, flushError);
        goto cleanup;
    }
    if (![output closeAndReturnError:&closeError]) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to close the local project package cache", 0, closeError);
        goto cleanup;
    }
    output = nil;
    (void)[input closeAndReturnError:nil];
    input = nil;
    success = amproj_finalizeIncomingPartial(
        manager, partialURL, destinationURL, copiedBytes, &copyError);
    if (success && copiedBytes && *copiedBytes != total) {
        success = NO;
        copyError = amproj_importFileError(
            AMProjImportFileErrorReadSource,
            @"NSFileHandle returned an incomplete project package", EIO, nil);
        [manager removeItemAtURL:destinationURL error:nil];
    }

cleanup:
    if (output) (void)[output closeAndReturnError:nil];
    if (input) (void)[input closeAndReturnError:nil];
    if (!success) [manager removeItemAtURL:partialURL error:nil];
    if (!success && error) *error = copyError ?: amproj_importFileError(
        AMProjImportFileErrorReadSource,
        @"NSFileHandle could not copy the project package", 0, nil);
    return success;
}

static BOOL amproj_mappedDataCopyIncomingFile(NSURL *sourceURL, NSURL *destinationURL,
                                               uint64_t *copiedBytes, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directoryURL = destinationURL.URLByDeletingLastPathComponent;
    NSURL *partialURL = [directoryURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.partial",
            destinationURL.lastPathComponent ?: @"project.amproj", NSUUID.UUID.UUIDString]];
    NSNumber *sourceSize = nil;
    NSError *sizeError = nil;
    if (![sourceURL getResourceValue:&sourceSize forKey:NSURLFileSizeKey error:&sizeError] ||
        ![sourceSize isKindOfClass:NSNumber.class]) {
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorOpenSource,
            @"The File Provider did not report a safe mapped-data size", 0, sizeError);
        return NO;
    }
    if (sourceSize.unsignedLongLongValue > 512ULL * 1024ULL * 1024ULL) {
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorOpenSource,
            @"The project package is too large for the mapped-data fallback", EFBIG, nil);
        return NO;
    }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:sourceURL
                                        options:NSDataReadingMappedIfSafe
                                          error:&readError];
    if (!data) {
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorOpenSource,
            @"NSData could not map the coordinated project package", 0, readError);
        return NO;
    }
    NSError *writeError = nil;
    if (![data writeToURL:partialURL options:NSDataWritingAtomic error:&writeError]) {
        [manager removeItemAtURL:partialURL error:nil];
        if (error) *error = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"NSData could not write the local project package cache", 0, writeError);
        return NO;
    }
    BOOL success = amproj_finalizeIncomingPartial(
        manager, partialURL, destinationURL, copiedBytes, error);
    if (!success) [manager removeItemAtURL:partialURL error:nil];
    return success;
}

// Last-resort path for ordinary local files. Some document-provider URLs reject
// POSIX open() even while their NSFileCoordinator accessor is active.
static BOOL amproj_posixCopyIncomingFile(NSURL *sourceURL, NSURL *destinationURL,
                                         uint64_t *copiedBytes, NSError **error) {
    if (copiedBytes) *copiedBytes = 0;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directoryURL = destinationURL.URLByDeletingLastPathComponent;
    NSString *partialName = [NSString stringWithFormat:@".%@.%@.partial",
        destinationURL.lastPathComponent ?: @"project.amproj", NSUUID.UUID.UUIDString];
    NSURL *partialURL = [directoryURL URLByAppendingPathComponent:partialName];
    int input = -1;
    int output = -1;
    uint8_t *buffer = NULL;
    BOOL success = NO;
    NSError *copyError = nil;
    NSError *moveError = nil;
    uint64_t total = 0;

    input = open(sourceURL.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (input < 0) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorOpenSource,
            @"Unable to open the security-scoped project package", errno, nil);
        goto cleanup;
    }
    output = open(partialURL.fileSystemRepresentation,
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (output < 0) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to create the local project package cache", errno, nil);
        goto cleanup;
    }
    buffer = malloc(256 * 1024);
    if (!buffer) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to allocate the project package copy buffer", ENOMEM, nil);
        goto cleanup;
    }

    for (;;) {
        ssize_t count = read(input, buffer, 256 * 1024);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            copyError = amproj_importFileError(
                AMProjImportFileErrorReadSource,
                @"The File Provider stopped while reading the project package", errno, nil);
            goto cleanup;
        }
        if (count == 0) break;
        size_t written = 0;
        while (written < (size_t)count) {
            ssize_t amount = write(output, buffer + written, (size_t)count - written);
            if (amount < 0 && errno == EINTR) continue;
            if (amount <= 0) {
                int savedErrno = amount < 0 ? errno : EIO;
                copyError = amproj_importFileError(
                    AMProjImportFileErrorWriteCache,
                    @"Unable to write the local project package cache", savedErrno, nil);
                goto cleanup;
            }
            written += (size_t)amount;
            total += (uint64_t)amount;
        }
    }
    if (fsync(output) != 0) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to flush the local project package cache", errno, nil);
        goto cleanup;
    }
    if (close(output) != 0) {
        output = -1;
        copyError = amproj_importFileError(
            AMProjImportFileErrorWriteCache,
            @"Unable to close the local project package cache", errno, nil);
        goto cleanup;
    }
    output = -1;
    if (![manager moveItemAtURL:partialURL toURL:destinationURL error:&moveError]) {
        copyError = amproj_importFileError(
            AMProjImportFileErrorFinalizeCache,
            @"Unable to finalize the local project package cache", 0, moveError);
        goto cleanup;
    }
    success = YES;
    if (copiedBytes) *copiedBytes = total;

cleanup:
    if (buffer) free(buffer);
    if (output >= 0) close(output);
    if (input >= 0) close(input);
    if (!success) [manager removeItemAtURL:partialURL error:nil];
    if (!success && error) *error = copyError ?: amproj_importFileError(
        AMProjImportFileErrorReadSource, @"Unable to copy the project package", 0, nil);
    return success;
}

static NSError* amproj_importCopyException(NSException *exception) {
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:
        @"A File Provider read method raised an exception"
                                                                    forKey:NSLocalizedDescriptionKey];
    if (exception.name.length) details[@"exception_name"] = exception.name;
    if (exception.reason.length) details[@"exception_reason"] = exception.reason;
    return [NSError errorWithDomain:@"com.amproj.import.file"
                               code:AMProjImportFileErrorOpenSource
                           userInfo:details];
}

static void amproj_removeIncomingPartials(NSURL *destinationURL) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *directoryURL = destinationURL.URLByDeletingLastPathComponent;
    NSString *prefix = [NSString stringWithFormat:@".%@.",
        destinationURL.lastPathComponent ?: @"project.amproj"];
    NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:directoryURL
                                      includingPropertiesForKeys:nil
                                                         options:0
                                                           error:nil];
    for (NSURL *entry in entries) {
        NSString *name = entry.lastPathComponent ?: @"";
        if ([name hasPrefix:prefix] && [name hasSuffix:@".partial"]) {
            [manager removeItemAtURL:entry error:nil];
        }
    }
}

// Run every read strategy synchronously while NSFileCoordinator and the security
// scope are still active. Foundation paths are first because iOS File Provider
// URLs may be valid documents without being directly openable POSIX paths.
static BOOL amproj_streamCopyIncomingFile(NSURL *sourceURL, NSURL *destinationURL,
                                          uint64_t *copiedBytes, NSString **copyMethod,
                                          NSError **error) {
    if (copiedBytes) *copiedBytes = 0;
    if (copyMethod) *copyMethod = nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];
    NSError *attemptError = nil;

    @try {
        if (amproj_foundationCopyIncomingFile(
                sourceURL, destinationURL, copiedBytes, &attemptError)) {
            if (copyMethod) *copyMethod = @"copy_item";
            return YES;
        }
    } @catch (NSException *exception) {
        attemptError = amproj_importCopyException(exception);
    }
    [attempts addObject:amproj_copyAttemptDiagnostic(@"copy_item", attemptError)];
    [manager removeItemAtURL:destinationURL error:nil];
    amproj_removeIncomingPartials(destinationURL);

    attemptError = nil;
    @try {
        if (amproj_fileHandleCopyIncomingFile(
                sourceURL, destinationURL, copiedBytes, &attemptError)) {
            if (copyMethod) *copyMethod = @"file_handle";
            return YES;
        }
    } @catch (NSException *exception) {
        attemptError = amproj_importCopyException(exception);
    }
    [attempts addObject:amproj_copyAttemptDiagnostic(@"file_handle", attemptError)];
    [manager removeItemAtURL:destinationURL error:nil];
    amproj_removeIncomingPartials(destinationURL);

    attemptError = nil;
    @try {
        if (amproj_mappedDataCopyIncomingFile(
                sourceURL, destinationURL, copiedBytes, &attemptError)) {
            if (copyMethod) *copyMethod = @"mapped_data";
            return YES;
        }
    } @catch (NSException *exception) {
        attemptError = amproj_importCopyException(exception);
    }
    [attempts addObject:amproj_copyAttemptDiagnostic(@"mapped_data", attemptError)];
    [manager removeItemAtURL:destinationURL error:nil];
    amproj_removeIncomingPartials(destinationURL);

    attemptError = nil;
    @try {
        if (amproj_posixCopyIncomingFile(
                sourceURL, destinationURL, copiedBytes, &attemptError)) {
            if (copyMethod) *copyMethod = @"posix";
            return YES;
        }
    } @catch (NSException *exception) {
        attemptError = amproj_importCopyException(exception);
    }
    [attempts addObject:amproj_copyAttemptDiagnostic(@"posix", attemptError)];
    [manager removeItemAtURL:destinationURL error:nil];
    amproj_removeIncomingPartials(destinationURL);

    if (error) *error = amproj_aggregateCopyError(attempts, attemptError);
    return NO;
}

static AMProjImportKind amproj_importKindForURL(NSURL *URL,
                                                NSDictionary *options) {
    NSString *extension = URL.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"xml"]) return AMProjImportKindXMLTemplate;
    for (id value in options.allValues) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *identifier = [(NSString *)value lowercaseString];
        if ([identifier isEqualToString:@"public.xml"] ||
            [identifier containsString:@".xml"] ||
            [identifier hasSuffix:@"/xml"]) {
            return AMProjImportKindXMLTemplate;
        }
    }
    return AMProjImportKindPackage;
}

static BOOL amproj_isIncomingProjectURL(NSURL *URL, NSDictionary *options) {
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL) return NO;
    NSString *extension = URL.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"amproj"] ||
        [extension isEqualToString:@"zip"] ||
        [extension isEqualToString:@"xml"]) {
        return YES;
    }
    for (id value in options.allValues) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *identifier = [(NSString *)value lowercaseString];
        if ([identifier containsString:@"amproj"] ||
            [identifier isEqualToString:@"public.zip-archive"] ||
            [identifier isEqualToString:@"public.xml"] ||
            [identifier containsString:@".xml"] ||
            [identifier hasSuffix:@"/xml"]) {
            return YES;
        }
    }

    // Never consume unrelated media/document URLs. QQ/Files preserves the
    // suffix in copy-in mode; providers that omit it must supply the UTI.
    return NO;
}

static UIViewController* amproj_topViewController(UIViewController *controller) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    while (controller) {
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) break;
        [visited addObject:identity];

        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)controller).visibleViewController;
        }
        if (!next && [controller isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)controller).selectedViewController;
        }
        if (!next && controller.childViewControllers.count) {
            // IPAFire may attach its welcome controller through a custom
            // containment controller rather than navigation/tab presentation.
            next = controller.childViewControllers.lastObject;
        }
        if (!next) break;
        controller = next;
    }
    return controller;
}

@implementation AMProjImportPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    (void)controller;
    if (URLs.count != 1 || ![URLs.firstObject isKindOfClass:NSURL.class]) {
        amproj_presentImportError(@"请选择一个 .amproj 项目包或 XML 项目文件。");
        return;
    }
    NSURL *selectedURL = [URLs.firstObject copy];
    BOOL heldSecurityScope = [selectedURL startAccessingSecurityScopedResource];
    BOOL XML = [selectedURL.pathExtension.lowercaseString isEqualToString:@"xml"];
    amproj_showImportStatus(
        XML ? @"AMProj · 1/3 已选择 XML 文件"
            : @"AMProj · 1/4 已选择 .amproj 文件", NO);
    dispatch_async(amproj_importInboxQueue(), ^{
        BOOL prepared = NO;
        AMProjIncomingURLResult result = amproj_handleIncomingProjectURLSafely(
            selectedURL, @"document_picker_copy",
            @{
                @"AMProjBackgroundWorker": @YES,
                @"AMProjExplicitRetry": @YES,
                @"AMProjAlreadyScoped": @(heldSecurityScope)
            }, &prepared);
        if (heldSecurityScope) [selectedURL stopAccessingSecurityScopedResource];
        amproj_debugEvent(@"import.picker_result", @{
            @"result": @(result),
            @"prepared": @(prepared),
            @"filename": selectedURL.lastPathComponent ?: @""
        });
        if (result == AMProjIncomingURLNotRecognized) {
            amproj_presentImportError(
                @"选择的文件不是可识别的 .amproj 项目包或 XML 项目文件。");
        }
    });
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentAtURL:(NSURL *)URL {
    [self documentPicker:controller didPickDocumentsAtURLs:URL ? @[URL] : @[]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    amproj_debugEvent(@"import.picker_cancelled", @{});
}

@end

static NSArray<UTType *> *amproj_expandNativeProjectContentTypes(
    NSArray<UTType *> *contentTypes) {
    BOOL includesXML = NO;
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id value in contentTypes) {
        if (![value isKindOfClass:UTType.class]) continue;
        NSString *identifier = ((UTType *)value).identifier.lowercaseString;
        if (identifier.length) [identifiers addObject:identifier];
        if ([identifier isEqualToString:@"public.xml"]) includesXML = YES;
    }
    if (!includesXML) return contentTypes;

    NSMutableArray<UTType *> *expanded =
        [contentTypes mutableCopy] ?: [NSMutableArray array];
    UTType *projectType = [UTType typeWithIdentifier:AMProjUTI];
    NSString *projectIdentifier = projectType.identifier.lowercaseString;
    if (projectType && projectIdentifier.length &&
        ![identifiers containsObject:projectIdentifier]) {
        [expanded addObject:projectType];
    }
    return expanded;
}

static NSArray<NSString *> *amproj_expandNativeProjectDocumentTypes(
    NSArray<NSString *> *documentTypes) {
    BOOL includesXML = NO;
    NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
    for (id value in documentTypes) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *identifier = [(NSString *)value lowercaseString];
        if (identifier.length) [identifiers addObject:identifier];
        if ([identifier isEqualToString:@"public.xml"]) includesXML = YES;
    }
    if (!includesXML || [identifiers containsObject:AMProjUTI.lowercaseString]) {
        return documentTypes;
    }
    NSMutableArray<NSString *> *expanded =
        [documentTypes mutableCopy] ?: [NSMutableArray array];
    [expanded addObject:AMProjUTI];
    return expanded;
}

static id hooked_documentPickerModernInit(
    id self, SEL _cmd, NSArray<UTType *> *contentTypes, BOOL asCopy) {
    NSArray<UTType *> *expanded =
        amproj_expandNativeProjectContentTypes(contentTypes);
    return orig_documentPickerModernInit
        ? orig_documentPickerModernInit(self, _cmd, expanded, asCopy) : nil;
}

static id hooked_documentPickerLegacyInit(
    id self, SEL _cmd, NSArray<NSString *> *documentTypes,
    UIDocumentPickerMode mode) {
    NSArray<NSString *> *expanded =
        amproj_expandNativeProjectDocumentTypes(documentTypes);
    return orig_documentPickerLegacyInit
        ? orig_documentPickerLegacyInit(self, _cmd, expanded, mode) : nil;
}

static NSURL *amproj_singleNativePickerProjectURL(
    NSArray<NSURL *> *URLs, AMProjImportKind *kindOut) {
    if (URLs.count != 1 || ![URLs.firstObject isKindOfClass:NSURL.class]) {
        return nil;
    }
    NSURL *URL = URLs.firstObject;
    if (!URL.isFileURL) return nil;
    NSString *extension = URL.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"xml"]) {
        if (kindOut) *kindOut = AMProjImportKindXMLTemplate;
        return URL;
    }
    if ([extension isEqualToString:@"amproj"]) {
        if (kindOut) *kindOut = AMProjImportKindPackage;
        return URL;
    }
    return nil;
}

static BOOL amproj_routeNativeProjectPicker(
    UIDocumentPickerViewController *picker, NSArray<NSURL *> *URLs,
    NSString *selectorName) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        // Non-engine builds keep the picker delegate owned by Alight Motion.
        // Returning NO lets the validation proxy forward the callback once.
        amproj_log865LegacyPathDisabled(@"native_picker_route");
        return NO;
    }
    AMProjImportKind kind = AMProjImportKindPackage;
    NSURL *selectedURL =
        [amproj_singleNativePickerProjectURL(URLs, &kind) copy];
    if (!selectedURL) return NO;

    BOOL XML = kind == AMProjImportKindXMLTemplate;
    NSString *originalName = selectedURL.lastPathComponent.length
        ? selectedURL.lastPathComponent
        : (XML ? @"project.xml" : @"project.amproj");
    BOOL heldSecurityScope = [selectedURL startAccessingSecurityScopedResource];
    if (XML) {
        amproj_showImportStatus(@"AMProj · 1/3 已从上传 XML 选择文件", NO);
    } else {
        amproj_showImportStatus(
            @"AMProj · 1/4 已从上传项目选择 .amproj", NO);
    }
    amproj_logCriticalEvent(
        XML ? @"import.native_xml_picker_intercepted"
            : @"import.native_package_picker_intercepted", @{
        @"picker": NSStringFromClass(picker.class) ?: @"",
        @"delegate_selector": selectorName ?: @"",
        @"filename": originalName,
        @"security_scope": @(heldSecurityScope),
        @"route": XML ? @"xml_minimal_package_offline"
                       : @"amproj_verified_package_offline"
    });

    dispatch_async(amproj_importInboxQueue(), ^{
        @autoreleasepool {
            BOOL prepared = NO;
            AMProjIncomingURLResult result =
                amproj_handleIncomingProjectURLSafely(
                    selectedURL,
                    XML ? @"native_xml_picker_local"
                        : @"native_package_picker_local", @{
                        @"AMProjBackgroundWorker": @YES,
                        @"AMProjDirectStage": @YES,
                        @"AMProjExplicitRetry": @YES,
                        @"AMProjAlreadyScoped": @(heldSecurityScope),
                        @"AMProjOriginalFilename": originalName,
                        @"AMProjDeclaredType": XML ? @"public.xml" : AMProjUTI
                    }, &prepared);
            if (heldSecurityScope) {
                [selectedURL stopAccessingSecurityScopedResource];
            }
            amproj_debugEvent(
                XML ? @"import.native_xml_picker_result"
                    : @"import.native_package_picker_result", @{
                @"result": @(result),
                @"prepared": @(prepared),
                @"filename": originalName,
                @"online_delegate_called": @NO
            });
            if (result == AMProjIncomingURLNotRecognized && !XML) {
                amproj_presentImportErrorForKind(
                    @"选择的文件不是可识别的 .amproj 项目包。",
                    kind, YES);
                return;
            }
            if (result == AMProjIncomingURLNotRecognized) {
                amproj_presentXMLImportError(
                    @"选择的文件不是可识别的 Alight Motion XML 项目。", YES);
            }
        }
    });
    return YES;
}

static id<UIDocumentPickerDelegate> amproj_restoreNativeXMLPickerDelegate(
    AMProjNativeXMLPickerProxy *proxy,
    UIDocumentPickerViewController *picker) {
    id<UIDocumentPickerDelegate> original = proxy.originalDelegate;
    proxy.originalDelegate = nil;
    if (picker.delegate == proxy) picker.delegate = original;
    objc_setAssociatedObject(picker, &amproj_nativeXMLPickerProxyKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return original;
}

static void amproj_finishOriginalPickerAsCancelled(
    id<UIDocumentPickerDelegate> original,
    UIDocumentPickerViewController *picker) {
    SEL selector = @selector(documentPickerWasCancelled:);
    if ([original respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))(void *)objc_msgSend)(
            original, selector, picker);
    }
}

@implementation AMProjNativeXMLPickerProxy

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    if (amproj_routeNativeProjectPicker(
            controller, URLs,
            NSStringFromSelector(@selector(documentPicker:didPickDocumentsAtURLs:)))) {
        id<UIDocumentPickerDelegate> original =
            amproj_restoreNativeXMLPickerDelegate(self, controller);
        amproj_finishOriginalPickerAsCancelled(original, controller);
        return;
    }
    id<UIDocumentPickerDelegate> original =
        amproj_restoreNativeXMLPickerDelegate(self, controller);
    SEL multipleSelector = @selector(documentPicker:didPickDocumentsAtURLs:);
    SEL singleSelector = @selector(documentPicker:didPickDocumentAtURL:);
    if ([original respondsToSelector:multipleSelector]) {
        ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
            original, multipleSelector, controller, URLs);
    } else if (URLs.count == 1 && [original respondsToSelector:singleSelector]) {
        ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
            original, singleSelector, controller, URLs.firstObject);
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentAtURL:(NSURL *)URL {
    NSArray<NSURL *> *URLs = URL ? @[URL] : @[];
    if (amproj_routeNativeProjectPicker(
            controller, URLs,
            NSStringFromSelector(@selector(documentPicker:didPickDocumentAtURL:)))) {
        id<UIDocumentPickerDelegate> original =
            amproj_restoreNativeXMLPickerDelegate(self, controller);
        amproj_finishOriginalPickerAsCancelled(original, controller);
        return;
    }
    id<UIDocumentPickerDelegate> original =
        amproj_restoreNativeXMLPickerDelegate(self, controller);
    SEL singleSelector = @selector(documentPicker:didPickDocumentAtURL:);
    SEL multipleSelector = @selector(documentPicker:didPickDocumentsAtURLs:);
    if ([original respondsToSelector:singleSelector]) {
        ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
            original, singleSelector, controller, URL);
    } else if ([original respondsToSelector:multipleSelector]) {
        ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
            original, multipleSelector, controller, URLs);
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    id<UIDocumentPickerDelegate> original =
        amproj_restoreNativeXMLPickerDelegate(self, controller);
    amproj_finishOriginalPickerAsCancelled(original, controller);
}

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] ||
        [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    id target = self.originalDelegate;
    return [target respondsToSelector:selector]
        ? target : [super forwardingTargetForSelector:selector];
}

@end

static void amproj_attachNativeXMLPickerProxy(UIViewController *controller) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        // Builds without the local engine own the complete document
        // picker/delegate lifecycle.
        amproj_log865LegacyPathDisabled(@"native_xml_picker_proxy");
        return;
    }
    if (![controller isKindOfClass:UIDocumentPickerViewController.class]) return;
    UIDocumentPickerViewController *picker =
        (UIDocumentPickerViewController *)controller;
    id<UIDocumentPickerDelegate> delegate = picker.delegate;
    if (!delegate ||
        [delegate isKindOfClass:AMProjImportPickerDelegate.class] ||
        [delegate isKindOfClass:AMProjNativeXMLPickerProxy.class]) {
        return;
    }

    AMProjNativeXMLPickerProxy *proxy = [AMProjNativeXMLPickerProxy new];
    proxy.originalDelegate = delegate;
    objc_setAssociatedObject(picker, &amproj_nativeXMLPickerProxyKey, proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    picker.delegate = proxy;
    amproj_debugEvent(@"import.native_xml_picker_proxy_attached", @{
        @"picker": NSStringFromClass(picker.class) ?: @"",
        @"delegate": NSStringFromClass([delegate class]) ?: @""
    });
}

static void amproj_presentImportDocumentPickerAttempt(NSUInteger attempt) {
    UIViewController *presenter = amproj_topViewController(
        amproj_keyWindow().rootViewController);
    if ([presenter isKindOfClass:UIDocumentPickerViewController.class]) return;
    if (!presenter || [presenter isKindOfClass:UIAlertController.class] ||
        !presenter.view.window || presenter.presentedViewController) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_presentImportDocumentPickerAttempt(attempt + 1);
            });
        }
        return;
    }

    UTType *projectType = [UTType typeWithIdentifier:@"com.alightcreative.motion.amproj"];
    UTType *archiveType = [UTType typeWithIdentifier:@"public.zip-archive"];
    UTType *XMLType = [UTType typeWithIdentifier:@"public.xml"];
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (projectType) [types addObject:projectType];
    if (archiveType) [types addObject:archiveType];
    if (XMLType) [types addObject:XMLType];
    if (!types.count) [types addObject:UTTypeData];

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                    asCopy:YES];
    if (!amproj_importPickerDelegate) {
        amproj_importPickerDelegate = [AMProjImportPickerDelegate new];
    }
    picker.delegate = amproj_importPickerDelegate;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    UIPopoverPresentationController *popover = picker.popoverPresentationController;
    if (popover) {
        popover.sourceView = presenter.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                        CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
    }
    amproj_debugEvent(@"import.picker_presented", @{@"copy_mode": @YES});
    [presenter presentViewController:picker animated:YES completion:nil];
}

static void amproj_presentImportDocumentPicker(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        amproj_presentImportDocumentPickerAttempt(0);
    });
}

static void amproj_presentImportErrorAttempt(NSString *message,
                                             NSUInteger generation,
                                             NSUInteger attempt) {
    if (generation != amproj_importErrorGeneration ||
        ![message isEqualToString:amproj_latestImportErrorMessage]) return;
    UIViewController *presenter = amproj_topViewController(
        amproj_keyWindow().rootViewController);
    if (!presenter || [presenter isKindOfClass:UIAlertController.class] ||
        !presenter.view.window || presenter.presentedViewController) {
        if (attempt < 300) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_presentImportErrorAttempt(message, generation, attempt + 1);
            });
        }
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:amproj_latestImportErrorTitle.length
            ? amproj_latestImportErrorTitle : @"无法导入 .amproj"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    NSURL *retryURL = [amproj_retryImportURL copy];
    NSString *retryName = [amproj_retryImportName copy];
    if (retryURL.isFileURL &&
        [NSFileManager.defaultManager isReadableFileAtPath:retryURL.path]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"重试"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            dispatch_async(amproj_importInboxQueue(), ^{
                BOOL staged = NO;
                amproj_handleIncomingProjectURLSafely(
                    retryURL, @"explicit_retry", @{
                        @"AMProjDirectStage": @YES,
                        @"AMProjBackgroundWorker": @YES,
                        @"AMProjExplicitRetry": @YES,
                        @"AMProjPreserveSource": @YES,
                        @"AMProjOriginalFilename": retryName ?: retryURL.lastPathComponent
                    }, &staged);
            });
        }]];
    }
    if (amproj_latestImportErrorOffersPicker) {
        BOOL XMLFailure =
            [amproj_latestImportErrorTitle containsString:@"XML"];
        [alert addAction:[UIAlertAction actionWithTitle:
            XMLFailure ? @"选择 XML 文件" : @"选择项目包"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_presentImportDocumentPicker();
            });
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

static void amproj_presentImportErrorOfferingPicker(NSString *message,
                                                     BOOL offerPicker) {
    amproj_presentImportErrorOfferingPickerWithTitle(
        message, @"无法导入 .amproj", offerPicker);
}

static void amproj_presentImportErrorOfferingPickerWithTitle(
    NSString *message, NSString *title, BOOL offerPicker) {
    NSString *snapshot = message.length ? [message copy] :
        @"请返回 QQ 或文件 App 后重新打开项目包。";
    NSString *titleSnapshot = title.length ? [title copy] : @"无法导入文件";
    dispatch_async(dispatch_get_main_queue(), ^{
        amproj_latestImportErrorMessage = snapshot;
        amproj_latestImportErrorTitle = titleSnapshot;
        amproj_latestImportErrorOffersPicker = offerPicker;
        NSUInteger generation = ++amproj_importErrorGeneration;
        amproj_presentImportErrorAttempt(snapshot, generation, 0);
    });
}

static void amproj_presentImportError(NSString *message) {
    amproj_presentImportErrorOfferingPicker(message, YES);
}

static void amproj_presentXMLImportError(NSString *message, BOOL offerPicker) {
    amproj_presentImportErrorOfferingPickerWithTitle(
        message, @"无法导入 XML", offerPicker);
}

static void amproj_presentImportErrorForKind(NSString *message,
                                             AMProjImportKind kind,
                                             BOOL offerPicker) {
    if (kind == AMProjImportKindXMLTemplate) {
        amproj_presentXMLImportError(message, offerPicker);
    } else {
        amproj_presentImportErrorOfferingPicker(message, offerPicker);
    }
}

// A failed native transaction may still have an old Swift completion closure
// in flight. Keep the staged package and stop scheduling retries in this
// process; reopening AM resets the bridge while preserving the cache.
static BOOL amproj_pauseForNativeBridgeRestart(NSString *transactionID,
                                               NSString *name) {
    if (!AMProjNativePackageImportBridgeRequiresRestart()) return NO;
    if (amproj_nativeBridgeRestartNoticeShown) return YES;
    amproj_nativeBridgeRestartNoticeShown = YES;
    NSString *message =
        @"AMProj \u539f\u751f\u5bfc\u5165\u5931\u8d25\uff0c\u8bf7\u5b8c\u5168\u5173\u95ed\u5e76\u91cd\u65b0\u6253\u5f00 Alight Motion \u540e\u518d\u91cd\u8bd5\u3002\u5df2\u4fdd\u7559\u5bfc\u5165\u7f13\u5b58\u5305\u3002";
    amproj_debugEvent(@"import.local_bridge_requires_restart", @{
        @"transaction_id": transactionID ?: @"",
        @"filename": name ?: @"project.amproj",
        @"reason": @"native_bridge_poisoned",
        @"native_bridge_busy_or_poisoned": @YES
    });
    amproj_showImportStatusForTransaction(message, YES, transactionID);
    amproj_presentImportErrorOfferingPicker(message, NO);
    return YES;
}

static void amproj_prepareCopiedXML(NSURL *XMLURL, NSURL *directoryURL,
                                    NSString *originalName, NSString *source,
                                    BOOL silentErrors, NSString *transactionID) {
    NSURL *URLSnapshot = [XMLURL copy];
    NSURL *directorySnapshot = [directoryURL copy];
    NSString *nameSnapshot = [originalName copy] ?: @"project.xml";
    NSString *sourceSnapshot = [source copy] ?: @"unknown";
    dispatch_async(amproj_importInboxQueue(), ^{
        @autoreleasepool {
            NSNumber *size = nil;
            [URLSnapshot getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            const unsigned long long maximumXMLBytes = 32ULL * 1024ULL * 1024ULL;
            NSError *readError = nil;
            NSData *data = size.unsignedLongLongValue > 0 &&
                    size.unsignedLongLongValue <= maximumXMLBytes
                ? [NSData dataWithContentsOfURL:URLSnapshot
                                         options:NSDataReadingMappedIfSafe
                                           error:&readError]
                : nil;
            // Probe the original bytes first. NSXMLParser handles the XML
            // declaration/BOM itself, so forcing UTF-8 here would reject
            // otherwise valid UTF-16/UTF-32 project documents.
            AMProjXMLProbe *probe = nil;
            NSString *probeException = nil;
            @try {
                probe = data.length ? amproj_probeXML(data) : nil;
            } @catch (NSException *exception) {
                // Encrypted/binary payloads must never turn parser diagnostics
                // into an uncaught exception on the serial import worker.
                probeException = exception.name ?: @"NSException";
            }
            BOOL valid = probe != nil;
            NSDictionary *encryptionSignal = nil;
            BOOL likelyEncrypted = !valid &&
                amproj_isLikelyEncryptedXML(data, &encryptionSignal);
            NSString *UTF8 = data.length
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                : nil;
            amproj_debugEvent(@"import.xml_validate", @{
                @"success": @(valid),
                @"transaction_id": transactionID ?: @"",
                @"source": sourceSnapshot,
                @"filename": nameSnapshot,
                @"bytes": size ?: @0,
                @"utf8": @(UTF8 != nil),
                @"root_scene": @(probe.validRoot),
                @"title": probe.title ?: @"",
                @"layers": @(probe.layerCount),
                @"likely_encrypted": @(likelyEncrypted),
                @"probe_exception": probeException ?: @"",
                @"error": readError.localizedDescription ?: @""
            });
            if (likelyEncrypted) {
                AMProjImportTransaction *failed =
                    amproj_importTransactionForID(transactionID);
                NSString *fingerprint = [failed.fingerprint copy];
                NSString *message = @"加密 XML 无法导入";

                // Keep this branch before ZIP creation, queueing, or any
                // native/private bridge callback. Only bounded metadata is
                // recorded; XML bytes and content previews never leave RAM.
                amproj_debugEvent(@"import.xml_encrypted_rejected", @{
                    @"transaction_id": transactionID ?: @"",
                    @"source": sourceSnapshot,
                    @"filename": nameSnapshot,
                    @"bytes": size ?: @0,
                    @"category": encryptionSignal[@"category"] ?: @"binary_high_entropy",
                    @"signal": encryptionSignal ?: @{}
                });
                amproj_releaseImportTransaction(transactionID, NO);
                [NSFileManager.defaultManager removeItemAtURL:directorySnapshot error:nil];
                amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                             sourceSnapshot, nil, nil, message);
                if (!silentErrors) {
                    amproj_showImportStatusForTransaction(message, YES, transactionID);
                    amproj_presentImportErrorOfferingPickerWithTitle(
                        message, @"XML 导入失败", NO);
                }
                return;
            }
            if (!valid) {
                AMProjImportTransaction *failed =
                    amproj_importTransactionForID(transactionID);
                NSString *fingerprint = [failed.fingerprint copy];
                amproj_releaseImportTransaction(transactionID, NO);
                [NSFileManager.defaultManager removeItemAtURL:directorySnapshot error:nil];
                NSString *message = @"XML 文件不是有效的 Alight Motion <scene> 项目";
                amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                             sourceSnapshot, nil, nil, message);
                if (!silentErrors) {
                    amproj_showImportStatusForTransaction(
                        [NSString stringWithFormat:@"AMProj · XML 校验失败：%@", message],
                        YES, transactionID);
                    amproj_presentXMLImportError(message, YES);
                }
                return;
            }
            NSURL *localPackageURL = [directorySnapshot
                URLByAppendingPathComponent:
                    [[@"xml-template-" stringByAppendingString:
                        NSUUID.UUID.UUIDString.lowercaseString]
                        stringByAppendingPathExtension:@"amproj"]];
            NSDictionary<NSString *, NSNumber *> *zipMetrics = nil;
            NSError *zipError = nil;
            BOOL packaged = AMProjZIPWriteProjectArchive(
                localPackageURL, data, @{}, &zipMetrics, &zipError);
            packaged = packaged &&
                [zipMetrics[@"crc_verified"] boolValue] &&
                [zipMetrics[@"manifest_verified"] boolValue] &&
                [zipMetrics[@"xml_count"] unsignedIntegerValue] == 1 &&
                [zipMetrics[@"manifest_count"] unsignedIntegerValue] == 1 &&
                [zipMetrics[@"entry_count"] unsignedIntegerValue] == 2;
            amproj_debugEvent(@"import.xml_local_package_created", @{
                @"success": @(packaged),
                @"transaction_id": transactionID ?: @"",
                @"source": sourceSnapshot,
                @"filename": nameSnapshot,
                @"package_filename": localPackageURL.lastPathComponent ?: @"",
                @"xml_bytes": @(data.length),
                @"metrics": zipMetrics ?: @{},
                @"error_domain": zipError.domain ?: @"",
                @"error_code": @(zipError.code),
                @"error": zipError.localizedDescription ?: @""
            });
            if (!packaged) {
                AMProjImportTransaction *failed =
                    amproj_importTransactionForID(transactionID);
                amproj_retryImportURL = failed.archiveURL ?: URLSnapshot;
                amproj_retryImportName = [nameSnapshot copy];
                NSString *fingerprint = [failed.fingerprint copy];
                NSString *message = zipError.localizedDescription.length
                    ? zipError.localizedDescription
                    : @"无法创建本地 XML 模板导入包";
                amproj_releaseImportTransaction(transactionID, NO);
                amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                             sourceSnapshot, nil, nil, message);
                if (!silentErrors) {
                    NSString *visible = [NSString stringWithFormat:
                        @"AMProj · XML 本地导入准备失败：%@", message];
                    amproj_showImportStatusForTransaction(
                        visible, YES, transactionID);
                    amproj_presentXMLImportError(visible, YES);
                }
                return;
            }

            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionID);
            transaction.projectTitle = probe.title.length
                ? probe.title : nameSnapshot.stringByDeletingPathExtension;
            transaction.packageIntegrityVerified = YES;
            amproj_debugEvent(@"import.route_selected", @{
                @"transaction_id": transactionID ?: @"",
                @"kind": @"xml_template",
                @"route": @"xml_minimal_package_offline"
            });
            amproj_debugEvent(@"import.xml_template_started", @{
                @"transaction_id": transactionID ?: @"",
                @"title": transaction.projectTitle ?: @"",
                @"filename": nameSnapshot,
                @"route": @"xml_minimal_package_offline"
            });
            amproj_showImportStatusForTransaction(
                @"AMProj · 2/3 XML 校验通过，正在本地导入模板",
                NO, transactionID);
            // Keep the XML bytes unchanged. In particular, do not call
            // AMProjNormalizeProjectArchive: adding type="project" would route
            // this document to Projects instead of Your Templates.
            amproj_queuePreparedImport(
                localPackageURL, nameSnapshot, transactionID);
        }
    });
}

static void amproj_prepareCopiedArchive(NSURL *archiveURL, NSURL *directoryURL,
                                        NSString *originalName, NSString *source,
                                        BOOL silentErrors, NSString *transactionID) {
    NSURL *archiveSnapshot = [archiveURL copy];
    NSURL *directorySnapshot = [directoryURL copy];
    NSString *nameSnapshot = [originalName copy] ?: @"project.amproj";
    NSString *sourceSnapshot = [source copy] ?: @"unknown";
    dispatch_async(amproj_importInboxQueue(), ^{
        @autoreleasepool {
            @try {
            amproj_showImportStatusForTransaction(
                @"AMProj \u00b7 2/4 \u5df2\u590d\u5236\uff0c\u6b63\u5728\u5b8c\u6574\u6821\u9a8c\u9879\u76ee\u5305",
                NO, transactionID);

            NSDictionary *validationMetrics = nil;
            NSError *validationError = nil;
            BOOL valid = amproj_validateIncomingArchive(
                archiveSnapshot, &validationMetrics, &validationError);
            amproj_debugEvent(@"import.validate", @{
                @"success": @(valid),
                @"source": sourceSnapshot,
                @"entries": validationMetrics[@"entries"] ?: @0,
                @"xml_count": validationMetrics[@"xml_count"] ?: @0,
                @"manifest_count": validationMetrics[@"manifest_count"] ?: @0,
                @"resource_count": validationMetrics[@"resource_count"] ?: @0,
                @"manifest_entry_count": validationMetrics[@"manifest_entry_count"] ?: @0,
                @"manifest_verified_resource_count":
                    validationMetrics[@"manifest_verified_resource_count"] ?: @0,
                @"manifest_verified": validationMetrics[@"manifest_verified"] ?: @NO,
                @"bytes": validationMetrics[@"bytes"] ?: @0,
                @"error": validationError.localizedDescription ?: @""
            });
            amproj_debugEvent(@"import.archive_prepare", @{
                @"success": @(valid),
                @"source": sourceSnapshot,
                @"filename": nameSnapshot,
                @"route": @"native_package_zip",
                @"metrics": validationMetrics ?: @{},
                @"error_domain": validationError.domain ?: @"",
                @"error_code": @(validationError.code),
                @"error": validationError.localizedDescription ?: @""
            });
            if (!valid) {
                amproj_releaseImportTransaction(transactionID, NO);
                [NSFileManager.defaultManager removeItemAtURL:directorySnapshot error:nil];
                if (!silentErrors) {
                    NSError *reported = validationError ?: amproj_importFileError(
                        AMProjImportFileErrorInvalidZIP,
                        @"The project package ZIP is invalid", 0, nil);
                    NSString *visible = amproj_visibleImportFileError(reported);
                    amproj_showImportStatusForTransaction(visible, YES, transactionID);
                    amproj_presentImportError(visible);
                }
                return;
            }

            NSUInteger inputManifestCount =
                [validationMetrics[@"manifest_count"] unsignedIntegerValue];
            NSUInteger inputXMLCount =
                [validationMetrics[@"xml_count"] unsignedIntegerValue];
            NSURL *preparedURL = nil;
            NSDictionary *preparationMetrics = nil;
            NSError *preparationError = nil;
            NSString *route = nil;

            if (inputManifestCount == 1) {
                // Android accepts media identities from manifest.txt alone,
                // while this iOS build resolves packaged media through the
                // matching <media sig="SHA1"> value. PackageImporter also
                // classifies a scene without type="project" as a preset and
                // stores it under Templates. Preserve the source only when
                // both the media identities and root scene kinds are ready.
                NSURL *unusedNativeXML = nil;
                BOOL prepared = AMProjPrepareNativeImport(
                    archiveSnapshot, directorySnapshot, &unusedNativeXML,
                    &preparationMetrics, &preparationError);
                NSString *extractionPath = [preparationMetrics[@"extraction_directory"]
                    isKindOfClass:NSString.class]
                    ? preparationMetrics[@"extraction_directory"] : nil;
                if (extractionPath.length) {
                    [NSFileManager.defaultManager removeItemAtURL:
                        [NSURL fileURLWithPath:extractionPath isDirectory:YES] error:nil];
                }
                if (prepared) {
                    NSUInteger signatureRewrites =
                        [preparationMetrics[@"rewritten_media_signature_count"]
                            unsignedIntegerValue];
                    NSUInteger projectSceneRewrites =
                        [preparationMetrics[@"rewritten_project_scene_count"]
                            unsignedIntegerValue];
                    if (signatureRewrites == 0 && projectSceneRewrites == 0) {
                        preparedURL = archiveSnapshot;
                        route = @"validated_original_package";
                    } else {
                        NSURL *normalizedURL = [directorySnapshot
                            URLByAppendingPathComponent:
                                [[@"ios-project-ready-" stringByAppendingString:
                                    NSUUID.UUID.UUIDString.lowercaseString]
                                    stringByAppendingPathExtension:@"amproj"]];
                        BOOL normalized = AMProjNormalizeProjectArchive(
                            archiveSnapshot, directorySnapshot, normalizedURL,
                            &preparationMetrics, &preparationError);
                        if (normalized && normalizedURL.isFileURL) {
                            preparedURL = normalizedURL;
                            route = @"ios_project_archive_normalized";
                        }
                    }
                }
            } else if (inputXMLCount == 1) {
                // Legacy packages need both a manifest and the iOS media SHA-1
                // attributes. Rebuild the complete package with every resource.
                NSURL *normalizedURL = [directorySnapshot URLByAppendingPathComponent:
                    [[@"ios-normalized-" stringByAppendingString:
                        NSUUID.UUID.UUIDString.lowercaseString]
                        stringByAppendingPathExtension:@"amproj"]];
                BOOL normalized = AMProjNormalizeProjectArchive(
                    archiveSnapshot, directorySnapshot, normalizedURL,
                    &preparationMetrics, &preparationError);
                if (normalized && normalizedURL.isFileURL) {
                    preparedURL = normalizedURL;
                    route = @"legacy_ios_media_normalized";
                }
            } else {
                preparationError = [NSError errorWithDomain:
                    @"com.amproj.import.archive" code:32 userInfo:@{
                        NSLocalizedDescriptionKey:
                            @"A multi-project package must contain manifest.txt",
                        @"xml_count": @(inputXMLCount)
                    }];
            }

            BOOL prepared = preparedURL.isFileURL;
            amproj_debugEvent(@"import.prepare_complete_package", @{
                @"success": @(prepared),
                @"source": sourceSnapshot,
                @"filename": nameSnapshot,
                @"route": route ?: @"none",
                @"input_xml_count": @(inputXMLCount),
                @"input_manifest_count": @(inputManifestCount),
                @"entry_count": preparationMetrics[@"entry_count"] ?: @0,
                @"resource_count": preparationMetrics[@"resource_count"] ?: @0,
                @"reference_count": preparationMetrics[@"reference_count"] ?: @0,
                @"media_signature_count":
                    preparationMetrics[@"media_signature_count"] ?: @0,
                @"rewritten_media_signature_count":
                    preparationMetrics[@"rewritten_media_signature_count"] ?: @0,
                @"missing_media_signature_count":
                    preparationMetrics[@"missing_media_signature_count"] ?: @0,
                @"project_scene_count":
                    preparationMetrics[@"project_scene_count"] ?: @0,
                @"rewritten_project_scene_count":
                    preparationMetrics[@"rewritten_project_scene_count"] ?: @0,
                @"missing_reference_count": preparationMetrics[@"missing_reference_count"] ?: @0,
                @"missing_reference_names": preparationMetrics[@"missing_reference_names"] ?: @[],
                @"zip": preparationMetrics[@"zip"] ?: @{},
                @"error_domain": preparationError.domain ?: @"",
                @"error_code": @(preparationError.code),
                @"error": preparationError.localizedDescription ?: @""
            });
            if (!prepared) {
                amproj_releaseImportTransaction(transactionID, NO);
                [NSFileManager.defaultManager removeItemAtURL:directorySnapshot error:nil];
                if (!silentErrors) {
                    NSString *detail = preparationError.localizedDescription.length
                        ? preparationError.localizedDescription
                        : @"\u9879\u76ee\u5305\u5b8c\u6574\u6027\u6821\u9a8c\u6216\u89c4\u8303\u5316\u5931\u8d25";
                    NSString *visible = [NSString stringWithFormat:
                        @"AMProj \u00b7 \u9879\u76ee\u5305\u65e0\u6cd5\u6821\u9a8c\uff1a%@", detail];
                    amproj_showImportStatusForTransaction(visible, YES, transactionID);
                    amproj_presentImportError(visible);
                }
                return;
            }

            NSUInteger missingReferences =
                [preparationMetrics[@"missing_reference_count"] unsignedIntegerValue];
            if (missingReferences) {
                NSString *missingMessage = [NSString stringWithFormat:
                    @"项目包缺少 %lu 个 XML 引用的资源，已停止导入：%@",
                    (unsigned long)missingReferences,
                    [preparationMetrics[@"missing_reference_names"] componentsJoinedByString:@", "] ?: @"未知资源"];
                amproj_debugEvent(@"import.missing_resources", @{
                    @"source": sourceSnapshot,
                    @"filename": nameSnapshot,
                    @"missing_reference_count": @(missingReferences),
                    @"missing_reference_names":
                        preparationMetrics[@"missing_reference_names"] ?: @[],
                    @"action": @"reject_incomplete_package"
                });
                AMProjImportTransaction *failedTransaction =
                    amproj_importTransactionForID(transactionID);
                amproj_retryImportURL = failedTransaction.archiveURL ?: archiveSnapshot;
                amproj_retryImportName = [nameSnapshot copy];
                NSString *fingerprint = [failedTransaction.fingerprint copy];
                amproj_releaseImportTransaction(transactionID, NO);
                amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                             sourceSnapshot, nil, nil, missingMessage);
                if (!silentErrors) {
                    amproj_showImportStatusForTransaction(
                        missingMessage, YES, transactionID);
                    amproj_presentImportError(missingMessage);
                }
                // Keep the staged directory for an explicit retry; it is
                // removed by the normal seven-day cache purge.
                return;
            }
            NSUInteger missingMediaSignatures =
                [preparationMetrics[@"missing_media_signature_count"] unsignedIntegerValue];
            if (missingMediaSignatures) {
                NSString *missingMediaMessage = [NSString stringWithFormat:
                    @"\u9879\u76ee\u5305\u4e2d\u6709 %lu \u4e2a\u5a92\u4f53\u6ca1\u6709\u5bf9\u5e94\u7684 manifest SHA-1\uff0c\u5df2\u505c\u6b62\u5bfc\u5165",
                    (unsigned long)missingMediaSignatures];
                amproj_debugEvent(@"import.missing_media_signatures", @{
                    @"source": sourceSnapshot,
                    @"filename": nameSnapshot,
                    @"missing_media_signature_count": @(missingMediaSignatures),
                    @"action": @"reject_incomplete_package"
                });
                AMProjImportTransaction *failedTransaction =
                    amproj_importTransactionForID(transactionID);
                amproj_retryImportURL = failedTransaction.archiveURL ?: archiveSnapshot;
                amproj_retryImportName = [nameSnapshot copy];
                NSString *fingerprint = [failedTransaction.fingerprint copy];
                amproj_releaseImportTransaction(transactionID, NO);
                amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                             sourceSnapshot, nil, nil,
                                             missingMediaMessage);
                if (!silentErrors) {
                    amproj_showImportStatusForTransaction(
                        missingMediaMessage, YES, transactionID);
                    amproj_presentImportError(missingMediaMessage);
                }
                return;
            }
            NSString *projectTitle = [preparationMetrics[@"scene_title"]
                isKindOfClass:NSString.class] ? preparationMetrics[@"scene_title"] : nil;
            AMProjImportTransaction *preparedTransaction =
                amproj_importTransactionForID(transactionID);
            if (preparedTransaction) preparedTransaction.packageIntegrityVerified = YES;
            amproj_storeImportProjectTitle(transactionID, projectTitle);
            amproj_showImportStatusForTransaction(
                @"AMProj \u00b7 2/4 \u9879\u76ee\u5305\u5b8c\u6574\u6821\u9a8c\u901a\u8fc7\uff0c\u6b63\u5728\u542f\u52a8\u672c\u5730\u5bfc\u5165",
                NO, transactionID);
            // Preparation is intentionally UI-free. The package enters the
            // shared import lane first; only the activated Projects owner may
            // capture its project/persistence baselines and call PackageImporter.
            amproj_queuePreparedImport(preparedURL, nameSnapshot, transactionID);
            } @catch (NSException *exception) {
                AMProjImportTransaction *failedTransaction =
                    amproj_importTransactionForID(transactionID);
                amproj_retryImportURL = failedTransaction.archiveURL ?: archiveSnapshot;
                amproj_retryImportName = [nameSnapshot copy];
                NSString *reason = exception.reason ?: @"Project package preparation raised an exception";
                NSString *fingerprint = [failedTransaction.fingerprint copy];
                amproj_releaseImportTransaction(transactionID, NO);
                amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                             sourceSnapshot, nil, nil, reason);
                amproj_debugEvent(@"import.prepare_exception", @{
                    @"transaction_id": transactionID ?: @"",
                    @"source": sourceSnapshot,
                    @"filename": nameSnapshot,
                    @"exception": exception.name ?: @"",
                    @"reason": reason
                });
                if (!silentErrors) {
                    NSString *visible = [NSString stringWithFormat:
                        @"AMProj · 项目包处理异常：%@", reason];
                    amproj_showImportStatusForTransaction(visible, YES, transactionID);
                    amproj_presentImportError(visible);
                }
            }
        }
    });
}

static void amproj_activateNextPendingImport(void) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"pending_import_activation");
        return;
    }
    if (!amproj_pendingImportQueue.count) return;
    if (AMProjNativePackageImportBridgeRequiresRestart()) {
        amproj_pauseForNativeBridgeRestart(nil, nil);
        return;
    }
    if (AMProjNativePackageImportBridgeIsBusy()) {
        amproj_debugEvent(@"import.queue_blocked", @{
            @"reason": @"native_bridge_busy_or_poisoned",
            @"queue_depth": @(amproj_pendingImportQueue.count)
        });
        return;
    }
    if (amproj_xmlTemplateImportActive || amproj_importVerificationActive ||
        amproj_pendingImportURL || amproj_importDispatchCoolingDown ||
        amproj_nativeImportAlertActive) {
        amproj_debugEvent(@"import.queue_blocked", @{
            @"pending": @(amproj_pendingImportURL != nil),
            @"cooldown": @(amproj_importDispatchCoolingDown),
            @"xml_template_active": @(amproj_xmlTemplateImportActive),
            @"native_alert": @(amproj_nativeImportAlertActive),
            @"queue_depth": @(amproj_pendingImportQueue.count)
        });
        return;
    }
    NSDictionary *entry = amproj_pendingImportQueue.firstObject;
    [amproj_pendingImportQueue removeObjectAtIndex:0];
    NSURL *URL = [entry[@"url"] isKindOfClass:NSURL.class] ? entry[@"url"] : nil;
    if (!URL) {
        amproj_activateNextPendingImport();
        return;
    }
    NSString *name = [entry[@"name"] isKindOfClass:NSString.class]
        ? entry[@"name"] : @"project.amproj";
    NSString *transactionID = [entry[@"transaction_id"] isKindOfClass:NSString.class]
        ? entry[@"transaction_id"] : @"";
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (transactionID.length &&
        (!transaction || transaction.state != AMProjImportTransactionQueued)) {
        amproj_debugEvent(@"import.stale_queue_suppressed", @{
            @"transaction_id": transactionID,
            @"filename": name,
            @"reason": transaction ? @"state_changed" : @"transaction_released"
        });
        amproj_activateNextPendingImport();
        return;
    }
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = [transactionID copy];
    amproj_pendingImportURL = URL;
    amproj_pendingImportName = name.length ? name : @"project.amproj";
    amproj_pendingImportTransactionID = [transactionID copy];
    amproj_activeNativeImportTransactionID = nil;
    // A transaction may be re-queued after a retry. Never carry a persistence
    // snapshot across lane ownership: the active lane owner captures a fresh
    // baseline only after its Projects UI is mounted and ready.
    amproj_invalidatePersistenceBaseline(transaction);
    amproj_invalidateTemplateProbe(transaction);
    // The native deadline starts only after the Projects UI and persistence
    // baselines are captured. Waiting for a delayed Projects controller must
    // not consume it.
    amproj_pendingImportDeadline = 0;
    NSUInteger generation = ++amproj_pendingImportGeneration;
    amproj_debugEvent(@"import.activated", @{
        @"filename": amproj_pendingImportName,
        @"transaction_id": transactionID,
        @"queued_after_current": @(amproj_pendingImportQueue.count),
        @"wait_seconds": @90
    });
    amproj_markImportTransactionState(
        transactionID, AMProjImportTransactionWaitingForProjects);
    amproj_showImportStatusForTransaction(
        transaction.kind == AMProjImportKindXMLTemplate
            ? @"AMProj \u00b7 2/3 \u6b63\u5728\u51c6\u5907\u672c\u5730 XML \u6a21\u677f\u5bfc\u5165"
            : @"AMProj \u00b7 2/4 \u6b63\u5728\u5bfc\u5165\u5230\u5e95\u90e8\u201c\u9879\u76ee\u201d",
        NO, transactionID);
    amproj_captureActivatedPackageBaselines(
        amproj_pendingImportURL, amproj_pendingImportName, transactionID);
}

static AMProjNativePackageImportStarter amproj_nativePackageImportStarter = nil;

// The PackageImporter ABI adapter registers here. A successful completion means
// the package, XML and bundled resources have been persisted as a real project.
void AMProjRegisterNativePackageImportStarter(AMProjNativePackageImportStarter starter) {
    amproj_nativePackageImportStarter = [starter copy];
    amproj_debugEvent(@"import.local_bridge", @{
        @"available": @(amproj_nativePackageImportStarter != nil)
    });
}

static BOOL amproj_textMatchesImportedTitle(NSString *text, NSString *title) {
    if (!text.length || !title.length) return NO;
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    if ([text rangeOfString:title options:options].location != NSNotFound) return YES;
    NSString *normalizedText = [text stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSString *normalizedTitle = [title stringByReplacingOccurrencesOfString:@" " withString:@""];
    return normalizedTitle.length > 1 &&
        [normalizedText rangeOfString:normalizedTitle options:options].location != NSNotFound;
}

static BOOL amproj_viewTreeContainsImportedTitle(UIView *view, NSString *title,
                                                 NSMutableSet<NSValue *> *visited,
                                                 NSUInteger depth) {
    if (!view || depth > 20) return NO;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return NO;
    [visited addObject:identity];
    NSArray<NSString *> *texts = @[
        [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text ?: @"" : @"",
        [view isKindOfClass:UITextView.class] ? ((UITextView *)view).text ?: @"" : @"",
        view.accessibilityLabel ?: @"",
        [view.accessibilityValue isKindOfClass:NSString.class] ? view.accessibilityValue : @""
    ];
    for (NSString *text in texts) {
        if (amproj_textMatchesImportedTitle(text, title)) return YES;
    }
    for (UIView *child in view.subviews) {
        if (amproj_viewTreeContainsImportedTitle(child, title, visited, depth + 1)) return YES;
    }
    return NO;
}

static NSArray<UIViewController *> *amproj_visibleProjectsControllers(void) {
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    __block void (^walk)(UIViewController *);
    __block __weak void (^weakWalk)(UIViewController *);
    walk = ^(UIViewController *controller) {
        if (!controller) return;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) return;
        [visited addObject:identity];
        NSString *className = NSStringFromClass(controller.class);
        if (([className hasSuffix:@"ProjectsVC"] ||
             [className hasSuffix:@"ProjectsListVC"]) &&
            controller.viewIfLoaded.window && !controller.viewIfLoaded.hidden &&
            controller.viewIfLoaded.alpha > 0.01) {
            [result addObject:controller];
        }
        void (^recurse)(UIViewController *) = weakWalk;
        for (UIViewController *child in controller.childViewControllers) recurse(child);
        recurse(controller.presentedViewController);
        if ([controller isKindOfClass:UINavigationController.class]) {
            for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
                recurse(child);
            }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            for (UIViewController *child in ((UITabBarController *)controller).viewControllers) {
                recurse(child);
            }
        }
    };
    weakWalk = walk;
    NSMutableSet<NSValue *> *windowIDs = [NSMutableSet set];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    void (^appendWindow)(UIWindow *) = ^(UIWindow *window) {
        if (!window || window.hidden || window.alpha <= 0.01 ||
            window.windowScene.activationState != UISceneActivationStateForegroundActive) return;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([windowIDs containsObject:identity]) return;
        [windowIDs addObject:identity];
        [windows addObject:window];
    };
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) appendWindow(window);
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) appendWindow(window);
    for (UIWindow *window in windows) {
        walk(window.rootViewController);
    }
    weakWalk = nil;
    walk = nil;
    return result;
}

static NSArray<UIWindow *> *amproj_foregroundApplicationWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    void (^append)(UIWindow *) = ^(UIWindow *window) {
        if (!window || window.hidden || window.alpha <= 0.01) return;
        if (window.windowScene &&
            window.windowScene.activationState != UISceneActivationStateForegroundActive) {
            return;
        }
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([visited containsObject:identity]) return;
        [visited addObject:identity];
        [windows addObject:window];
    };
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) append(window);
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) append(window);
    return windows;
}

static BOOL amproj_controllerTreeContainsToken(UIViewController *controller,
                                                NSString *token,
                                                NSMutableSet<NSValue *> *visited,
                                                NSUInteger depth) {
    if (!controller || !token.length || depth > 24) return NO;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return NO;
    [visited addObject:identity];
    if ([NSStringFromClass(controller.class).lowercaseString
            containsString:token.lowercaseString]) return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if (amproj_controllerTreeContainsToken(child, token, visited, depth + 1)) return YES;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
            if (amproj_controllerTreeContainsToken(child, token, visited, depth + 1)) return YES;
        }
    }
    return NO;
}

static void amproj_collectTabControllers(UIViewController *controller,
                                         NSMutableSet<NSValue *> *visited,
                                         NSMutableArray<UITabBarController *> *tabs,
                                         NSUInteger depth) {
    if (!controller || depth > 24) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if ([controller isKindOfClass:UITabBarController.class]) {
        [tabs addObject:(UITabBarController *)controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        amproj_collectTabControllers(child, visited, tabs, depth + 1);
    }
    amproj_collectTabControllers(controller.presentedViewController,
                                 visited, tabs, depth + 1);
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
            amproj_collectTabControllers(child, visited, tabs, depth + 1);
        }
    }
}

static BOOL amproj_selectMainTab(BOOL templates, NSString *transactionID) {
    NSMutableArray<UITabBarController *> *tabs = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIWindow *window in amproj_foregroundApplicationWindows()) {
        amproj_collectTabControllers(window.rootViewController, visited, tabs, 0);
    }
    NSString *token = templates ? @"template" : @"projects";
    UIViewController *bestBranch = nil;
    UITabBarController *bestTabs = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UITabBarController *tabController in tabs) {
        for (UIViewController *branch in tabController.viewControllers) {
            NSString *title = branch.tabBarItem.title.lowercaseString ?: @"";
            NSInteger score = 0;
            if (templates) {
                if ([title containsString:@"\u6a21\u677f"] ||
                    [title containsString:@"template"]) score += 100;
            } else {
                if ([title isEqualToString:@"\u9879\u76ee"] ||
                    [title containsString:@"project"]) score += 100;
            }
            if (amproj_controllerTreeContainsToken(
                    branch, token, [NSMutableSet set], 0)) score += 50;
            if (score > bestScore) {
                bestScore = score;
                bestBranch = branch;
                bestTabs = tabController;
            }
        }
    }
    BOOL selected = bestTabs && bestBranch && bestScore > 0;
    BOOL changed = selected && bestTabs.selectedViewController != bestBranch;
    if (changed) bestTabs.selectedViewController = bestBranch;
    if (selected) {
        [bestBranch.viewIfLoaded setNeedsLayout];
        [bestTabs.viewIfLoaded setNeedsLayout];
    }
    amproj_debugEvent(templates ? @"import.templates_tab_selected"
                                : @"import.projects_tab_selected", @{
        @"transaction_id": transactionID ?: @"",
        @"selected": @(selected),
        @"changed": @(changed),
        @"branch": NSStringFromClass(bestBranch.class) ?: @"",
        @"score": @(bestScore == NSIntegerMin ? 0 : bestScore)
    });
    return changed;
}

static NSArray<UIViewController *> *amproj_visibleTemplatesControllers(void) {
    NSMutableArray<UIViewController *> *result = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    __block void (^walk)(UIViewController *);
    walk = ^(UIViewController *controller) {
        if (!controller) return;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) return;
        [visited addObject:identity];
        NSString *className = NSStringFromClass(controller.class);
        NSString *lowerClassName = className.lowercaseString ?: @"";
        if ([lowerClassName containsString:@"templateslistvc"] &&
            controller.viewIfLoaded.window && !controller.viewIfLoaded.hidden &&
            controller.viewIfLoaded.alpha > 0.01) {
            [result addObject:controller];
        }
        for (UIViewController *child in controller.childViewControllers) walk(child);
        walk(controller.presentedViewController);
        if ([controller isKindOfClass:UINavigationController.class]) {
            for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
                walk(child);
            }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            for (UIViewController *child in ((UITabBarController *)controller).viewControllers) {
                walk(child);
            }
        }
    };
    for (UIWindow *window in amproj_foregroundApplicationWindows()) {
        walk(window.rootViewController);
    }
    walk = nil;
    return result;
}

static void amproj_collectVisibleProjectLists(UIView *view,
                                              NSMutableSet<NSValue *> *visited,
                                              NSMutableArray<UIView *> *lists,
                                              NSUInteger depth) {
    if (!view || depth > 32 || view.hidden || view.alpha <= 0.01) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if (view.window && ([view isKindOfClass:UICollectionView.class] ||
                        [view isKindOfClass:UITableView.class])) {
        [lists addObject:view];
    }
    for (UIView *child in view.subviews) {
        amproj_collectVisibleProjectLists(child, visited, lists, depth + 1);
    }
}

static NSArray<UIView *> *amproj_visibleTemplateLists(void) {
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIViewController *controller in amproj_visibleTemplatesControllers()) {
        amproj_collectVisibleProjectLists(controller.viewIfLoaded, visited, lists, 0);
    }
    return lists;
}

static NSString *amproj_templateComparableText(NSString *text) {
    NSString *value = [text ?: @"" lowercaseString];
    NSMutableCharacterSet *ignored = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [ignored formUnionWithCharacterSet:NSCharacterSet.punctuationCharacterSet];
    [ignored formUnionWithCharacterSet:NSCharacterSet.symbolCharacterSet];
    return [[value componentsSeparatedByCharactersInSet:ignored]
        componentsJoinedByString:@""];
}

static void amproj_collectViewTexts(UIView *view,
                                    NSMutableArray<NSString *> *texts,
                                    NSMutableSet<NSValue *> *visited,
                                    NSUInteger depth) {
    if (!view || depth > 20 || texts.count >= 64) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    void (^append)(NSString *) = ^(NSString *text) {
        NSString *trimmed = [text ?: @"" stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length && texts.count < 64) [texts addObject:trimmed];
    };
    if ([view isKindOfClass:UILabel.class]) append(((UILabel *)view).text);
    if ([view isKindOfClass:UITextView.class]) append(((UITextView *)view).text);
    if ([view isKindOfClass:UIButton.class]) {
        append([((UIButton *)view) titleForState:UIControlStateNormal]);
    }
    append(view.accessibilityLabel);
    if ([view.accessibilityValue isKindOfClass:NSString.class]) {
        append((NSString *)view.accessibilityValue);
    }
    for (UIView *child in view.subviews) {
        amproj_collectViewTexts(child, texts, visited, depth + 1);
    }
    for (id element in amproj_accessibilityChildren(view)) {
        if ([element respondsToSelector:@selector(accessibilityLabel)]) {
            append([element accessibilityLabel]);
        }
        if ([element respondsToSelector:@selector(accessibilityValue)]) {
            id value = [element accessibilityValue];
            if ([value isKindOfClass:NSString.class]) append(value);
        }
    }
}

static BOOL amproj_objectHasExactTemplateTitle(id object,
                                                NSString *expected) {
    if (!object || !expected.length) return NO;
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    @try {
        if ([object respondsToSelector:@selector(accessibilityLabel)]) {
            id value = [object accessibilityLabel];
            if ([value isKindOfClass:NSString.class]) [values addObject:value];
        }
        if ([object respondsToSelector:@selector(accessibilityValue)]) {
            id value = [object accessibilityValue];
            if ([value isKindOfClass:NSString.class]) [values addObject:value];
        }
        if ([object isKindOfClass:UILabel.class]) {
            NSString *value = ((UILabel *)object).text;
            if (value.length) [values addObject:value];
        }
        if ([object isKindOfClass:UITextView.class]) {
            NSString *value = ((UITextView *)object).text;
            if (value.length) [values addObject:value];
        }
        if ([object isKindOfClass:UIButton.class]) {
            NSString *value = [((UIButton *)object)
                titleForState:UIControlStateNormal];
            if (value.length) [values addObject:value];
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    for (NSString *value in values) {
        if ([amproj_templateComparableText(value) isEqualToString:expected]) {
            return YES;
        }
    }
    return NO;
}

static void amproj_collectExactTemplateTitleObjects(
    UIView *view, NSString *expected, NSMutableSet<NSValue *> *visited,
    NSMutableArray *matches, NSUInteger depth) {
    if (!view || depth > 32 || view.hidden || view.alpha <= 0.01) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if (amproj_objectHasExactTemplateTitle(view, expected)) {
        [matches addObject:view];
    }
    for (UIView *child in view.subviews) {
        amproj_collectExactTemplateTitleObjects(
            child, expected, visited, matches, depth + 1);
    }
    for (id element in amproj_accessibilityChildren(view)) {
        NSValue *elementIdentity = [NSValue valueWithPointer:
            (__bridge const void *)element];
        if ([visited containsObject:elementIdentity]) continue;
        if ([element isKindOfClass:UIView.class]) {
            amproj_collectExactTemplateTitleObjects(
                element, expected, visited, matches, depth + 1);
            continue;
        }
        [visited addObject:elementIdentity];
        if (amproj_objectHasExactTemplateTitle(element, expected)) {
            [matches addObject:element];
        }
    }
}

static NSArray *amproj_visibleTemplateExactTitleObjects(NSString *title) {
    NSString *expected = amproj_templateComparableText(title);
    if (!expected.length) return @[];
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIViewController *controller in amproj_visibleTemplatesControllers()) {
        amproj_collectExactTemplateTitleObjects(
            controller.viewIfLoaded, expected, visited, matches, 0);
    }
    return [matches copy];
}

static NSInteger amproj_visibleTemplateViewTitleCount(NSString *title) {
    return (NSInteger)amproj_visibleTemplateExactTitleObjects(title).count;
}

static id amproj_uniqueActivatableTemplateTitleObject(NSString *title) {
    NSMutableArray *activatable = [NSMutableArray array];
    for (id object in amproj_visibleTemplateExactTitleObjects(title)) {
        BOOL canActivate = [object isKindOfClass:UIControl.class] ||
            [object respondsToSelector:@selector(accessibilityActivate)];
        if (!canActivate) continue;
        if ([object isKindOfClass:UIView.class]) {
            UIView *view = (UIView *)object;
            if (!view.window || view.hidden || view.alpha <= 0.01 ||
                !view.userInteractionEnabled) continue;
        }
        [activatable addObject:object];
    }
    return activatable.count == 1 ? activatable.firstObject : nil;
}

static NSString *amproj_templateCellStableKey(UIView *list, UIView *cell,
                                               NSArray<NSString *> *texts) {
    if (!list || !cell) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *listClass = NSStringFromClass(list.class);
    NSString *cellClass = NSStringFromClass(cell.class);
    if (listClass.length) [parts addObject:listClass];
    if (cellClass.length) [parts addObject:cellClass];
    if (cell.accessibilityIdentifier.length) {
        [parts addObject:[NSString stringWithFormat:@"aid=%@", cell.accessibilityIdentifier]];
    }
    if (cell.restorationIdentifier.length) {
        [parts addObject:[NSString stringWithFormat:@"rid=%@", cell.restorationIdentifier]];
    }
    if ([cell respondsToSelector:@selector(reuseIdentifier)]) {
        @try {
            NSString *reuse = ((NSString *(*)(id, SEL))(void *)objc_msgSend)(
                cell, @selector(reuseIdentifier));
            if ([reuse isKindOfClass:NSString.class] && reuse.length) {
                [parts addObject:[NSString stringWithFormat:@"reuse=%@", reuse]];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    NSMutableArray<NSString *> *normalizedTexts = [NSMutableArray array];
    for (NSString *text in texts) {
        NSString *normalized = amproj_templateComparableText(text);
        if (normalized.length && ![normalizedTexts containsObject:normalized]) {
            [normalizedTexts addObject:normalized];
        }
    }
    [normalizedTexts sortUsingSelector:@selector(compare:)];
    if (normalizedTexts.count) {
        [parts addObject:[NSString stringWithFormat:@"text=%@",
                          [normalizedTexts componentsJoinedByString:@"|"]]];
    }
    // A semantic key is intentionally required. Pointer/index-path identity is
    // only a diagnostic aid: both are unstable when the collection reloads.
    return parts.count >= 3 ? [parts componentsJoinedByString:@";"] : nil;
}

static UIView *amproj_templateCellAtIndexPath(UIView *list, NSIndexPath *indexPath) {
    if (!list || !indexPath) return nil;
    @try {
        if ([list isKindOfClass:UICollectionView.class]) {
            UICollectionView *collection = (UICollectionView *)list;
            UICollectionViewCell *cell = [collection cellForItemAtIndexPath:indexPath];
            if (cell) return cell;
            [collection scrollToItemAtIndexPath:indexPath
                               atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                       animated:NO];
            [collection layoutIfNeeded];
            return [collection cellForItemAtIndexPath:indexPath];
        } else if ([list isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)list;
            UITableViewCell *cell = [table cellForRowAtIndexPath:indexPath];
            if (cell) return cell;
            [table scrollToRowAtIndexPath:indexPath
                         atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
            [table layoutIfNeeded];
            return [table cellForRowAtIndexPath:indexPath];
        }
    } @catch (NSException *exception) {
        amproj_debugEvent(@"import.template_cell_probe_exception", @{
            @"list_class": NSStringFromClass(list.class) ?: @"",
            @"reason": exception.reason ?: @""
        });
    }
    return nil;
}

static NSDictionary *amproj_templateCandidate(UIView *list, UIView *cell,
                                               NSIndexPath *indexPath,
                                               NSString *title) {
    if (!list || !cell || !indexPath) return nil;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    amproj_collectViewTexts(cell, texts, [NSMutableSet set], 0);
    NSString *expected = amproj_templateComparableText(title);
    BOOL exact = !expected.length;
    BOOL fuzzy = !expected.length;
    if (expected.length) {
        for (NSString *text in texts) {
            NSString *candidate = amproj_templateComparableText(text);
            if ([candidate isEqualToString:expected]) exact = YES;
            if (amproj_textMatchesImportedTitle(text, title)) fuzzy = YES;
        }
    }
    if (expected.length && !exact && !fuzzy) return nil;
    NSString *joined = [texts componentsJoinedByString:@"|"];
    if (joined.length > 512) joined = [joined substringToIndex:512];
    NSString *stableKey = amproj_templateCellStableKey(list, cell, texts);
    NSString *fingerprint = [NSString stringWithFormat:@"%@|%ld:%ld|%@",
        NSStringFromClass(cell.class) ?: @"", (long)indexPath.section,
        (long)indexPath.item, joined ?: @""];
    return @{
        @"list": list,
        @"cell": cell,
        @"index_path": indexPath,
        @"exact": @(exact),
        @"fingerprint": fingerprint,
        @"stable_key": stableKey ?: @"",
        @"identity_safe": @(stableKey.length > 0),
        @"list_class": NSStringFromClass(list.class) ?: @"",
        @"cell_class": NSStringFromClass(cell.class) ?: @"",
        @"delegate_class": NSStringFromClass(
            [list isKindOfClass:UICollectionView.class]
                ? ((UICollectionView *)list).delegate.class
                : ((UITableView *)list).delegate.class) ?: @""
    };
}

static NSArray<NSDictionary *> *amproj_visibleTemplateCandidates(NSString *title) {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSUInteger inspected = 0;
    for (UIView *list in amproj_visibleTemplateLists()) {
        if (inspected >= 512) break;
        CGPoint originalOffset = [list isKindOfClass:UIScrollView.class]
            ? ((UIScrollView *)list).contentOffset : CGPointZero;
        @try {
            if ([list isKindOfClass:UICollectionView.class]) {
                UICollectionView *collection = (UICollectionView *)list;
                NSInteger sections = MIN(collection.numberOfSections, 64);
                for (NSInteger section = 0; section < sections && inspected < 512; section++) {
                    NSInteger items = MIN([collection numberOfItemsInSection:section], 512);
                    for (NSInteger item = 0; item < items && inspected < 512; item++) {
                        inspected++;
                        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:item
                                                                    inSection:section];
                        UIView *cell = amproj_templateCellAtIndexPath(list, indexPath);
                        NSDictionary *candidate = amproj_templateCandidate(
                            list, cell, indexPath, title);
                        if (candidate) [candidates addObject:candidate];
                    }
                }
            } else if ([list isKindOfClass:UITableView.class]) {
                UITableView *table = (UITableView *)list;
                NSInteger sections = MIN(table.numberOfSections, 64);
                for (NSInteger section = 0; section < sections && inspected < 512; section++) {
                    NSInteger rows = MIN([table numberOfRowsInSection:section], 512);
                    for (NSInteger row = 0; row < rows && inspected < 512; row++) {
                        inspected++;
                        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row
                                                                    inSection:section];
                        UIView *cell = amproj_templateCellAtIndexPath(list, indexPath);
                        NSDictionary *candidate = amproj_templateCandidate(
                            list, cell, indexPath, title);
                        if (candidate) [candidates addObject:candidate];
                    }
                }
            }
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.template_candidate_exception", @{
                @"list_class": NSStringFromClass(list.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        } @finally {
            if ([list isKindOfClass:UIScrollView.class]) {
                [(UIScrollView *)list setContentOffset:originalOffset animated:NO];
                [list layoutIfNeeded];
            }
        }
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                         NSDictionary *right) {
        BOOL leftExact = [left[@"exact"] boolValue];
        BOOL rightExact = [right[@"exact"] boolValue];
        if (leftExact != rightExact) return leftExact ? NSOrderedAscending : NSOrderedDescending;
        NSIndexPath *leftPath = left[@"index_path"];
        NSIndexPath *rightPath = right[@"index_path"];
        if (leftPath.section != rightPath.section) {
            return leftPath.section < rightPath.section ? NSOrderedAscending : NSOrderedDescending;
        }
        if (leftPath.item == rightPath.item) return NSOrderedSame;
        return leftPath.item < rightPath.item ? NSOrderedAscending : NSOrderedDescending;
    }];
    return candidates;
}

static NSInteger amproj_visibleTemplateRowCount(void) {
    NSInteger total = -1;
    for (UIView *list in amproj_visibleTemplateLists()) {
        @try {
            NSInteger count = 0;
            if ([list isKindOfClass:UICollectionView.class]) {
                UICollectionView *collection = (UICollectionView *)list;
                for (NSInteger section = 0; section < collection.numberOfSections && section < 128;
                     section++) {
                    count += [collection numberOfItemsInSection:section];
                }
            } else if ([list isKindOfClass:UITableView.class]) {
                UITableView *table = (UITableView *)list;
                for (NSInteger section = 0; section < table.numberOfSections && section < 128;
                     section++) {
                    count += [table numberOfRowsInSection:section];
                }
            }
            if (total < 0) total = 0;
            total += count;
        } @catch (__unused NSException *exception) {
        }
    }
    return total;
}

static void amproj_refreshVisibleTemplateRows(void) {
    for (UIView *list in amproj_visibleTemplateLists()) {
        @try {
            if ([list isKindOfClass:UICollectionView.class]) {
                [[(UICollectionView *)list collectionViewLayout] invalidateLayout];
            }
            [list setNeedsLayout];
            [list layoutIfNeeded];
        } @catch (__unused NSException *exception) {
        }
    }
}

static NSDictionary *amproj_templateCandidateDebugFields(NSDictionary *candidate) {
    NSIndexPath *indexPath = candidate[@"index_path"];
    return @{
        @"list_class": candidate[@"list_class"] ?: @"",
        @"cell_class": candidate[@"cell_class"] ?: @"",
        @"delegate_class": candidate[@"delegate_class"] ?: @"",
        @"section": @(indexPath.section),
        @"item": @(indexPath.item),
        @"exact": candidate[@"exact"] ?: @NO,
        @"stable_key": candidate[@"stable_key"] ?: @"",
        @"identity_safe": candidate[@"identity_safe"] ?: @NO,
        @"fingerprint": candidate[@"fingerprint"] ?: @""
    };
}

static NSArray<UIView *> *amproj_visibleProjectLists(void) {
    NSMutableArray<UIView *> *lists = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        amproj_collectVisibleProjectLists(controller.viewIfLoaded, visited, lists, 0);
    }
    return lists;
}

static void amproj_refreshVisibleProjectsRows(void) {
    NSArray<UIView *> *lists = amproj_visibleProjectLists();
    for (UIView *list in lists) {
        @try {
            if ([list isKindOfClass:UICollectionView.class]) {
                [[(UICollectionView *)list collectionViewLayout] invalidateLayout];
            }
            [list setNeedsLayout];
            [list layoutIfNeeded];
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_refresh_exception", @{
                @"list_class": NSStringFromClass(list.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        [controller.viewIfLoaded setNeedsLayout];
        [controller.viewIfLoaded layoutIfNeeded];
    }
    amproj_debugEvent(@"project_ui_refreshed", @{
        @"list_count": @(lists.count)
    });
}

static NSInteger amproj_visibleProjectsRowCount(void) {
    NSInteger total = -1;
    for (UIView *list in amproj_visibleProjectLists()) {
        @try {
            NSInteger count = 0;
            NSInteger sections = 0;
            if ([list isKindOfClass:UICollectionView.class]) {
                UICollectionView *collection = (UICollectionView *)list;
                sections = collection.numberOfSections;
                for (NSInteger section = 0; section < sections && section < 128; section++) {
                    count += [collection numberOfItemsInSection:section];
                }
            } else if ([list isKindOfClass:UITableView.class]) {
                UITableView *table = (UITableView *)list;
                sections = table.numberOfSections;
                for (NSInteger section = 0; section < sections && section < 128; section++) {
                    count += [table numberOfRowsInSection:section];
                }
            } else {
                continue;
            }
            if (total < 0) total = 0;
            total += count;
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_count_exception", @{
                @"list_class": NSStringFromClass(list.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
    return total;
}

static NSInteger amproj_projectTitleMatchCount(NSString *title) {
    if (!title.length) return 0;
    NSInteger total = 0;
    BOOL foundList = NO;
    NSUInteger inspected = 0;
    for (UIView *list in amproj_visibleProjectLists()) {
        if (inspected >= 512) break;
        foundList = YES;
        CGPoint originalOffset = [list isKindOfClass:UIScrollView.class]
            ? ((UIScrollView *)list).contentOffset : CGPointZero;
        @try {
            NSInteger sections = 0;
            if ([list isKindOfClass:UICollectionView.class]) {
                UICollectionView *collection = (UICollectionView *)list;
                sections = MIN(collection.numberOfSections, 64);
                for (NSInteger section = 0; section < sections && inspected < 512; section++) {
                    NSInteger items = MIN([collection numberOfItemsInSection:section], 512);
                    for (NSInteger item = 0; item < items && inspected < 512; item++) {
                        inspected++;
                        NSIndexPath *path = [NSIndexPath indexPathForItem:item inSection:section];
                        UIView *cell = amproj_templateCellAtIndexPath(list, path);
                        NSMutableArray<NSString *> *texts = [NSMutableArray array];
                        amproj_collectViewTexts(cell, texts, [NSMutableSet set], 0);
                        BOOL match = NO;
                        for (NSString *text in texts) {
                            if (amproj_textMatchesImportedTitle(text, title)) {
                                match = YES;
                                break;
                            }
                        }
                        if (match) total++;
                    }
                }
            } else if ([list isKindOfClass:UITableView.class]) {
                UITableView *table = (UITableView *)list;
                sections = MIN(table.numberOfSections, 64);
                for (NSInteger section = 0; section < sections && inspected < 512; section++) {
                    NSInteger rows = MIN([table numberOfRowsInSection:section], 512);
                    for (NSInteger row = 0; row < rows && inspected < 512; row++) {
                        inspected++;
                        NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
                        UIView *cell = amproj_templateCellAtIndexPath(list, path);
                        NSMutableArray<NSString *> *texts = [NSMutableArray array];
                        amproj_collectViewTexts(cell, texts, [NSMutableSet set], 0);
                        BOOL match = NO;
                        for (NSString *text in texts) {
                            if (amproj_textMatchesImportedTitle(text, title)) {
                                match = YES;
                                break;
                            }
                        }
                        if (match) total++;
                    }
                }
            }
        } @catch (__unused NSException *exception) {
        } @finally {
            if ([list isKindOfClass:UIScrollView.class]) {
                [(UIScrollView *)list setContentOffset:originalOffset animated:NO];
                [list layoutIfNeeded];
            }
        }
    }
    if (!foundList) return -1;
    return total;
}

static NSString *amproj_transactionExpectedTitle(AMProjImportTransaction *transaction,
                                                  NSString *fallbackName) {
    NSString *title = transaction.projectTitle.length
        ? transaction.projectTitle : fallbackName.stringByDeletingPathExtension;
    return title.length ? title : @"project";
}

static void amproj_captureTemplateBaseline(AMProjImportTransaction *transaction,
                                           NSString *fallbackName) {
    if (!transaction || (transaction.templateBaselineCaptured &&
                         transaction.templateBaselineListReady)) return;
    NSString *title = amproj_transactionExpectedTitle(transaction, fallbackName);
    amproj_refreshVisibleTemplateRows();
    NSArray<NSDictionary *> *candidates = amproj_visibleTemplateCandidates(title);
    NSMutableArray<NSString *> *baselineKeys = [NSMutableArray array];
    BOOL identitySafe = YES;
    for (NSDictionary *candidate in candidates) {
        NSString *key = candidate[@"stable_key"];
        if (![key isKindOfClass:NSString.class] || !key.length) {
            identitySafe = NO;
            continue;
        }
        [baselineKeys addObject:key];
    }
    transaction.templateBaselineListReady =
        amproj_visibleTemplateLists().count > 0 &&
        amproj_visibleTemplateRowCount() >= 0;
    transaction.templateBaselineCandidateKeys = [baselineKeys copy];
    transaction.templateBaselineCaptured = YES;
    transaction.templateBaselineMatchCount = candidates.count;
    transaction.templateBaselineRowCount = amproj_visibleTemplateRowCount();
    transaction.templateBaselineViewTitleCount =
        amproj_visibleTemplateViewTitleCount(title);
    amproj_debugEvent(@"import.template_baseline", @{
        @"transaction_id": transaction.transactionID ?: @"",
        @"title": title,
        @"match_count": @(transaction.templateBaselineMatchCount),
        @"row_count": @(transaction.templateBaselineRowCount),
        @"view_title_count": @(transaction.templateBaselineViewTitleCount),
        @"list_ready": @(transaction.templateBaselineListReady),
        @"identity_safe": @(identitySafe),
        @"candidate_keys": baselineKeys,
        @"controller_count": @(amproj_visibleTemplatesControllers().count)
    });
}

static BOOL amproj_prepareVisibleTemplateProbe(
    AMProjImportTransaction *transaction, NSString *fallbackName,
    UIViewController *preferredController) {
    if (!transaction) return NO;
    NSArray<UIViewController *> *controllers =
        amproj_visibleTemplatesControllers();
    UIViewController *controller = nil;
    if (preferredController && [controllers containsObject:preferredController]) {
        controller = preferredController;
    } else {
        controller = controllers.firstObject;
    }
    if (!controller || !controller.viewIfLoaded.window) return NO;

    if (transaction.templateProbeController != controller) {
        transaction.templateProbeController = controller;
        transaction.templateProbeStableCycles = 0;
        if (transaction.templateProbeCapability !=
            AMProjTemplateProbeCapabilityUIKitReady) {
            transaction.templateProbeCapability =
                AMProjTemplateProbeCapabilityUnknown;
        }
    }

    NSInteger rowCount = amproj_visibleTemplateRowCount();
    BOOL UIKitReady = amproj_visibleTemplateLists().count > 0 && rowCount >= 0;
    if (UIKitReady) {
        transaction.templateProbeCapability =
            AMProjTemplateProbeCapabilityUIKitReady;
        transaction.templateProbeStableCycles = 0;
        amproj_captureTemplateBaseline(transaction, fallbackName);
        amproj_debugEvent(@"import.template_probe_capability", @{
            @"transaction_id": transaction.transactionID ?: @"",
            @"capability": @"uikit_ready",
            @"controller": NSStringFromClass(controller.class) ?: @"",
            @"row_count": @(rowCount)
        });
        BOOL capturedReady = transaction.templateBaselineCaptured &&
            transaction.templateBaselineListReady;
        if (!capturedReady) {
            transaction.templateProbeCapability =
                AMProjTemplateProbeCapabilityUnknown;
            transaction.templateBaselineCaptured = NO;
        }
        return capturedReady;
    }

    if (transaction.templateProbeCapability ==
        AMProjTemplateProbeCapabilityUIKitReady) {
        return NO;
    }
    if (transaction.templateProbeCapability ==
        AMProjTemplateProbeCapabilitySwiftUIUnavailable) {
        return transaction.templateBaselineCaptured;
    }

    transaction.templateProbeStableCycles += 1;
    amproj_debugEvent(@"import.template_probe_capability", @{
        @"transaction_id": transaction.transactionID ?: @"",
        @"capability": @"unknown",
        @"controller": NSStringFromClass(controller.class) ?: @"",
        @"stable_cycles": @(transaction.templateProbeStableCycles),
        @"list_count": @(amproj_visibleTemplateLists().count),
        @"row_count": @(rowCount)
    });
    if (transaction.templateProbeStableCycles < 12) return NO;

    transaction.templateProbeCapability =
        AMProjTemplateProbeCapabilitySwiftUIUnavailable;
    amproj_captureTemplateBaseline(transaction, fallbackName);
    amproj_debugEvent(@"import.template_probe_capability", @{
        @"transaction_id": transaction.transactionID ?: @"",
        @"capability": @"swiftui_unavailable",
        @"controller": NSStringFromClass(controller.class) ?: @"",
        @"stable_cycles": @(transaction.templateProbeStableCycles)
    });
    return transaction.templateBaselineCaptured;
}

static NSDictionary *amproj_newTemplateCandidateForTransaction(
    AMProjImportTransaction *transaction, NSString *title) {
    if (!transaction || !transaction.templateBaselineCaptured ||
        !transaction.templateBaselineListReady ||
        transaction.templateBaselineMatchCount < 0 ||
        transaction.templateBaselineRowCount < 0) return nil;
    NSArray<NSDictionary *> *candidates = amproj_visibleTemplateCandidates(title);
    if (candidates.count != (NSUInteger)(transaction.templateBaselineMatchCount + 1)) {
        return nil;
    }
    NSCountedSet *counts = [NSCountedSet set];
    for (NSDictionary *candidate in candidates) {
        NSString *key = candidate[@"stable_key"];
        if (![key isKindOfClass:NSString.class] || !key.length) return nil;
        [counts addObject:key];
    }
    NSMutableArray<NSDictionary *> *added = [NSMutableArray array];
    NSArray<NSString *> *baselineKeys = transaction.templateBaselineCandidateKeys ?: @[];
    for (NSDictionary *candidate in candidates) {
        NSString *key = candidate[@"stable_key"];
        if ([candidate[@"exact"] boolValue] &&
            ![baselineKeys containsObject:key] &&
            [counts countForObject:key] == 1) {
            [added addObject:candidate];
        }
    }
    return added.count == 1 ? added.firstObject : nil;
}

static BOOL amproj_templateBaselineStillExact(
    AMProjImportTransaction *transaction, NSString *title) {
    if (!transaction || !transaction.templateBaselineListReady ||
        transaction.templateBaselineRowCount < 0 ||
        transaction.templateBaselineMatchCount < 0) return NO;
    NSInteger rowCount = amproj_visibleTemplateRowCount();
    NSArray<NSDictionary *> *candidates = amproj_visibleTemplateCandidates(title);
    if (rowCount != transaction.templateBaselineRowCount ||
        candidates.count != (NSUInteger)transaction.templateBaselineMatchCount) {
        return NO;
    }
    NSCountedSet *baseline = [[NSCountedSet alloc] initWithArray:
        transaction.templateBaselineCandidateKeys ?: @[]];
    NSCountedSet *current = [[NSCountedSet alloc] init];
    for (NSDictionary *candidate in candidates) {
        NSString *key = candidate[@"stable_key"];
        if (![key isKindOfClass:NSString.class] || !key.length) return NO;
        [current addObject:key];
    }
    if (baseline.count != current.count) return NO;
    for (NSString *key in baseline) {
        if ([baseline countForObject:key] != [current countForObject:key]) return NO;
    }
    return YES;
}

static BOOL amproj_invokeTemplateCandidate(NSDictionary *candidate,
                                           AMProjImportTransaction *transaction) {
    UIView *list = candidate[@"list"];
    UIView *cell = candidate[@"cell"];
    NSIndexPath *indexPath = candidate[@"index_path"];
    NSString *stableKey = candidate[@"stable_key"];
    if (!list || !indexPath || !transaction || transaction.templateSelectionSent ||
        ![stableKey isKindOfClass:NSString.class] || !stableKey.length) return NO;
    SEL selector = NULL;
    id delegate = nil;
    @try {
        if ([list isKindOfClass:UICollectionView.class]) {
            UICollectionView *collection = (UICollectionView *)list;
            delegate = collection.delegate;
            selector = @selector(collectionView:didSelectItemAtIndexPath:);
            [collection scrollToItemAtIndexPath:indexPath
                               atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                       animated:NO];
            [collection selectItemAtIndexPath:indexPath animated:NO
                               scrollPosition:UICollectionViewScrollPositionNone];
            UIView *visibleCell = amproj_templateCellAtIndexPath(list, indexPath);
            if (visibleCell) cell = visibleCell;
        } else if ([list isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)list;
            delegate = table.delegate;
            selector = @selector(tableView:didSelectRowAtIndexPath:);
            [table scrollToRowAtIndexPath:indexPath
                         atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
            [table selectRowAtIndexPath:indexPath animated:NO
                         scrollPosition:UITableViewScrollPositionNone];
            UIView *visibleCell = amproj_templateCellAtIndexPath(list, indexPath);
            if (visibleCell) cell = visibleCell;
        }
        if (!selector || !delegate || ![delegate respondsToSelector:selector]) return NO;
        transaction.templateSelectionSent = YES;
        transaction.templateSelectedIndexPath = indexPath;
        transaction.templateSelectedList = list;
        transaction.templateSelectedFingerprint = candidate[@"fingerprint"];
        transaction.templateSelectedStableKey = stableKey;
        transaction.templateTargetCell = cell;
        amproj_markImportTransactionState(
            transaction.transactionID, AMProjImportTransactionCreatingProject);
        NSMutableDictionary *fields =
            [amproj_templateCandidateDebugFields(candidate) mutableCopy];
        if (!fields) fields = [NSMutableDictionary dictionary];
        fields[@"transaction_id"] = transaction.transactionID ?: @"";
        amproj_debugEvent(@"import.template_selected", fields);
        ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
            delegate, selector, list, indexPath);
        amproj_debugEvent(@"import.template_selection_returned", @{
            @"transaction_id": transaction.transactionID ?: @"",
            @"delegate_class": NSStringFromClass([delegate class]) ?: @""
        });
        return YES;
    } @catch (NSException *exception) {
        amproj_debugEvent(@"import.template_selection_exception", @{
            @"transaction_id": transaction.transactionID ?: @"",
            @"reason": exception.reason ?: @""
        });
        return NO;
    }
}

static NSString *amproj_controlVisibleText(UIControl *control) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([control isKindOfClass:UIButton.class]) {
        NSString *title = [((UIButton *)control) titleForState:UIControlStateNormal];
        if (title.length) [parts addObject:title];
    }
    if (control.accessibilityLabel.length) [parts addObject:control.accessibilityLabel];
    if ([control.accessibilityValue isKindOfClass:NSString.class] &&
        [control.accessibilityValue length]) {
        [parts addObject:control.accessibilityValue];
    }
    return [parts componentsJoinedByString:@" "];
}

static BOOL amproj_controlActionsContainTerms(UIControl *control,
                                              NSArray<NSString *> *terms) {
    if (!control || !terms.count) return NO;
    @try {
        for (id target in control.allTargets) {
            for (NSString *action in [control actionsForTarget:target
                                               forControlEvent:UIControlEventAllEvents]) {
                NSString *lower = action.lowercaseString ?: @"";
                for (NSString *term in terms) {
                    if (term.length && [lower containsString:term.lowercaseString]) return YES;
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return NO;
}

static BOOL amproj_activateControl(UIControl *control) {
    if (!control || !control.enabled || !control.userInteractionEnabled ||
        control.hidden || control.alpha <= 0.01 || !control.window) return NO;
    @try {
        UIControlEvents events = control.allControlEvents;
        if (events & UIControlEventTouchUpInside) {
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if (events & UIControlEventPrimaryActionTriggered) {
            [control sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
            return YES;
        }
        return [control accessibilityActivate];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSString *amproj_viewVisibleText(id object) {
    if (!object) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([object isKindOfClass:UIControl.class]) {
        NSString *controlText =
            amproj_controlVisibleText((UIControl *)object);
        if (controlText.length) [parts addObject:controlText];
    } else {
        NSString *label = [object respondsToSelector:@selector(accessibilityLabel)]
            ? [object accessibilityLabel] : nil;
        if (label.length) {
            [parts addObject:label];
        }
        id value = [object respondsToSelector:@selector(accessibilityValue)]
            ? [object accessibilityValue] : nil;
        if ([value isKindOfClass:NSString.class] && [value length]) {
            [parts addObject:(NSString *)value];
        }
    }
    NSString *identifier =
        [object respondsToSelector:@selector(accessibilityIdentifier)]
            ? [object accessibilityIdentifier] : nil;
    if (identifier.length) {
        [parts addObject:identifier];
    }
    return [parts componentsJoinedByString:@" "];
}

static id amproj_findActivatableViewWithTerms(
    UIView *view, NSArray<NSString *> *terms,
    NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!view || depth > 32 || view.hidden || view.alpha <= 0.01) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    NSString *text = amproj_viewVisibleText(view).lowercaseString;
    for (NSString *term in terms) {
        if (term.length && [text containsString:term.lowercaseString]) {
            if (([view isKindOfClass:UIControl.class] || view.isAccessibilityElement) &&
                view.userInteractionEnabled) {
                return view;
            }
        }
    }
    for (UIView *child in view.subviews) {
        id found = amproj_findActivatableViewWithTerms(
            child, terms, visited, depth + 1);
        if (found) return found;
    }
    for (id element in amproj_accessibilityChildren(view)) {
        NSString *elementText = amproj_viewVisibleText(element).lowercaseString;
        for (NSString *term in terms) {
            if (term.length &&
                [elementText containsString:term.lowercaseString] &&
                [element respondsToSelector:@selector(accessibilityActivate)]) {
                return element;
            }
        }
    }
    return nil;
}

static BOOL amproj_activateView(id object) {
    if (!object) return NO;
    if ([object isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)object;
        if (view.hidden || view.alpha <= 0.01 || !view.window ||
            !view.userInteractionEnabled) return NO;
    }
    if ([object isKindOfClass:UIControl.class] &&
        amproj_activateControl((UIControl *)object)) return YES;
    @try {
        return ((BOOL (*)(id, SEL))(void *)objc_msgSend)(
            object, @selector(accessibilityActivate));
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static UIControl *amproj_findControlWithTerms(UIView *view,
                                             NSArray<NSString *> *terms,
                                             NSMutableSet<NSValue *> *visited,
                                             NSUInteger depth) {
    if (!view || depth > 24 || view.hidden || view.alpha <= 0.01) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        NSString *text = amproj_controlVisibleText(control).lowercaseString;
        for (NSString *term in terms) {
            if (term.length && [text containsString:term.lowercaseString]) return control;
        }
        if (amproj_controlActionsContainTerms(control, terms)) return control;
    }
    for (UIView *child in view.subviews) {
        UIControl *found = amproj_findControlWithTerms(child, terms, visited, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UIViewController *amproj_templateScopedActionOwner(
    AMProjImportTransaction *transaction) {
    UIViewController *base = transaction.templateMenuOwner;
    UIWindow *window = base.viewIfLoaded.window;
    if (!base || !window) return nil;
    UIViewController *container = base.navigationController ?: base;
    UIViewController *top = amproj_topViewController(container);
    if (!top || top.viewIfLoaded.window != window) return nil;
    BOOL sameNavigation = top == base ||
        (base.navigationController &&
         top.navigationController == base.navigationController);
    BOOL directPresentation = top.presentingViewController == base ||
        base.presentedViewController == top ||
        top.presentingViewController == base.navigationController ||
        base.navigationController.presentedViewController == top;
    return (sameNavigation || directPresentation) ? top : nil;
}

static UIViewController *amproj_presentedControllerFromOwnerHierarchy(
    UIViewController *owner) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIViewController *cursor = owner;
    while (cursor) {
        NSValue *identity = [NSValue valueWithPointer:
            (__bridge const void *)cursor];
        if ([visited containsObject:identity]) return nil;
        [visited addObject:identity];
        if (cursor.presentedViewController) {
            return cursor.presentedViewController;
        }
        cursor = cursor.parentViewController;
    }
    return nil;
}

static BOOL amproj_controllerContainsExactTemplateTitle(
    UIViewController *controller, NSString *title) {
    UIView *view = controller.viewIfLoaded;
    NSString *expected = amproj_templateComparableText(title);
    if (!view || !view.window || !expected.length) return NO;
    NSMutableArray *matches = [NSMutableArray array];
    amproj_collectExactTemplateTitleObjects(
        view, expected, [NSMutableSet set], matches, 0);
    return matches.count > 0;
}

static UIViewController *amproj_boundSwiftUITemplateActionOwner(
    AMProjImportTransaction *transaction) {
    UIViewController *base = transaction.templateMenuOwner;
    UIWindow *window = base.viewIfLoaded.window;
    UIViewController *baselineTop =
        transaction.templateCardActivationBaselineTop;
    if (!base || !window || !baselineTop ||
        !transaction.templateCleanupStarted) return nil;

    UIViewController *presented =
        amproj_presentedControllerFromOwnerHierarchy(base);
    UIViewController *container = base.navigationController ?: base;
    UIViewController *top = presented
        ? amproj_topViewController(presented)
        : amproj_topViewController(container);
    if (!top || top == base || top == baselineTop ||
        top == transaction.templateCardActivationBaselinePresented ||
        top.viewIfLoaded.window != window) return nil;

    BOOL newPresentation = presented &&
        presented != transaction.templateCardActivationBaselinePresented;
    BOOL newNavigationTop = base.navigationController &&
        top.navigationController == base.navigationController &&
        top != baselineTop;
    if (!newPresentation && !newNavigationTop) return nil;

    NSString *title = amproj_transactionExpectedTitle(
        transaction, transaction.name);
    return amproj_controllerContainsExactTemplateTitle(top, title) ? top : nil;
}

static UIViewController *amproj_boundSwiftUIConfirmationOwner(
    AMProjImportTransaction *transaction) {
    UIViewController *actionOwner = transaction.templateActionOwner;
    UIWindow *window = actionOwner.viewIfLoaded.window;
    UIViewController *baselineTop =
        transaction.templateDeleteActivationBaselineTop;
    if (!actionOwner || !window || !baselineTop ||
        !transaction.templateDeleteActionSent) return nil;

    UIViewController *presented =
        amproj_presentedControllerFromOwnerHierarchy(actionOwner);
    if (!presented ||
        presented == transaction.templateDeleteActivationBaselinePresented) {
        return nil;
    }
    UIViewController *owner = amproj_topViewController(presented);
    if (!owner || owner == actionOwner || owner == baselineTop ||
        owner == transaction.templateDeleteActivationBaselinePresented ||
        owner.viewIfLoaded.window != window) return nil;

    NSString *title = amproj_transactionExpectedTitle(
        transaction, transaction.name);
    return amproj_controllerContainsExactTemplateTitle(owner, title) ? owner : nil;
}

static BOOL amproj_activateTemplateCreationAction(AMProjImportTransaction *transaction) {
    if (transaction.templateCreationActionSent) return YES;
    NSArray<NSString *> *terms = @[
        @"\u4f7f\u7528\u6a21\u677f", @"\u521b\u5efa\u9879\u76ee", @"\u6253\u5f00\u6a21\u677f",
        @"use template", @"create project", @"open template", @"add to projects"
    ];
    UIViewController *top =
        amproj_templateScopedActionOwner(transaction);
    id control = top ? amproj_findActivatableViewWithTerms(
        top.viewIfLoaded, terms, [NSMutableSet set], 0) : nil;
    if (control && amproj_activateView(control)) {
        transaction.templateActionOwner = top;
        transaction.templateCreationActionSent = YES;
        amproj_debugEvent(@"import.template_creation_action", @{
            @"controller": NSStringFromClass(top.class) ?: @"",
            @"control": NSStringFromClass([control class]) ?: @"",
            @"text": amproj_viewVisibleText(control) ?: @""
        });
        return YES;
    }
    return NO;
}

static UIControl *amproj_findTemplateOverflowControl(UIView *cell) {
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    __block void (^walk)(UIView *, NSUInteger);
    walk = ^(UIView *view, NSUInteger depth) {
        if (!view || depth > 20 || view.hidden || view.alpha <= 0.01) return;
        if ([view isKindOfClass:UIControl.class]) [controls addObject:(UIControl *)view];
        for (UIView *child in view.subviews) walk(child, depth + 1);
    };
    walk(cell, 0);
    walk = nil;
    for (UIControl *control in controls) {
        NSString *text = amproj_controlVisibleText(control).lowercaseString;
        NSString *identifier = control.accessibilityIdentifier.lowercaseString ?: @"";
        NSString *hint = control.accessibilityHint.lowercaseString ?: @"";
        BOOL actionMatches = amproj_controlActionsContainTerms(
            control, @[@"more", @"option", @"menu", @"overflow"]);
        if ([text containsString:@"more"] || [text containsString:@"option"] ||
            [text containsString:@"\u66f4\u591a"] || [text containsString:@"\u83dc\u5355"] ||
            [text containsString:@"..."] || [text containsString:@"\u2026"] ||
            [identifier containsString:@"more"] || [identifier containsString:@"menu"] ||
            [identifier containsString:@"overflow"] || [hint containsString:@"more"] ||
            [hint containsString:@"menu"] || actionMatches) {
            return control;
        }
    }
    return nil;
}

static UIControl *amproj_findDeleteControlInController(UIViewController *owner) {
    NSArray<NSString *> *terms = @[@"\u5220\u9664", @"delete", @"remove"];
    UIViewController *top = amproj_topViewController(owner);
    return top ? amproj_findControlWithTerms(
        top.viewIfLoaded, terms, [NSMutableSet set], 0) : nil;
}

static void amproj_unwindTemplatePresentation(void) {
    NSMutableArray<UITabBarController *> *tabs = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIWindow *window in amproj_foregroundApplicationWindows()) {
        amproj_collectTabControllers(window.rootViewController, visited, tabs, 0);
    }
    for (UITabBarController *tabController in tabs) {
        UIViewController *presented = tabController.presentedViewController;
        NSString *presentedClass = NSStringFromClass(presented.class).lowercaseString ?: @"";
        if (presented && ([presentedClass containsString:@"template"] ||
                          [presentedClass containsString:@"project"] ||
                          [presentedClass containsString:@"editor"] ||
                          [presentedClass containsString:@"create"])) {
            [tabController dismissViewControllerAnimated:NO completion:nil];
        }
        UINavigationController *navigation = [tabController.selectedViewController
            isKindOfClass:UINavigationController.class]
            ? (UINavigationController *)tabController.selectedViewController : nil;
        if (navigation.viewControllers.count > 1) {
            [navigation popToRootViewControllerAnimated:NO];
        }
    }
}

static void amproj_failActivatedPackageBaseline(NSString *transactionID,
                                                 NSString *name,
                                                 NSString *message) {
    if (![amproj_pendingImportTransactionID isEqualToString:transactionID]) return;
    AMProjImportTransaction *failed = amproj_importTransactionForID(transactionID);
    AMProjImportKind failedKind = failed.kind;
    amproj_retryImportURL = failed.archiveURL;
    amproj_retryImportName = [failed.name copy] ?: [name copy];
    amproj_writeImportBreadcrumb(transactionID, failed.fingerprint, @"failed",
                                 failed.source, nil, nil, message);
    amproj_pendingImportURL = nil;
    amproj_pendingImportName = nil;
    amproj_pendingImportTransactionID = nil;
    amproj_pendingImportDeadline = 0;
    amproj_importDispatchCoolingDown = NO;
    ++amproj_pendingImportGeneration;
    amproj_releaseImportTransaction(transactionID, NO);
    amproj_showImportStatusForTransaction(
        [NSString stringWithFormat:@"AMProj · %@", message], YES, transactionID);
    amproj_presentImportErrorForKind(
        [NSString stringWithFormat:@"%@，缓存文件已保留，可重试。", message],
        failedKind, NO);
    amproj_resumeQueuedImports(@"native_baseline_failed");
}

static void amproj_captureActivatedPackageBaselinesAttempt(
    NSURL *URL, NSString *name, NSString *transactionID, NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        BOOL ownsLane = [amproj_pendingImportTransactionID
            isEqualToString:transactionID] &&
            [amproj_pendingImportURL isEqual:URL];
        if (!ownsLane || !transaction ||
            (transaction.kind != AMProjImportKindPackage &&
             transaction.kind != AMProjImportKindXMLTemplate) ||
            transaction.state != AMProjImportTransactionWaitingForProjects) return;

        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            if (attempt < 240) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_captureActivatedPackageBaselinesAttempt(
                        URL, name, transactionID, attempt + 1);
                });
            } else {
                amproj_failActivatedPackageBaseline(
                    transactionID, name, @"等待 Alight Motion 前台页面超时");
            }
            return;
        }

        BOOL changedToProjects = amproj_selectMainTab(NO, transactionID);
        if (changedToProjects || !amproj_visibleProjectsControllers().count) {
            if (attempt < 240) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_captureActivatedPackageBaselinesAttempt(
                        URL, name, transactionID, attempt + 1);
                });
            } else {
                amproj_failActivatedPackageBaseline(
                    transactionID, name,
                    @"项目列表未就绪，无法安全记录创建项目前基线");
            }
            return;
        }

        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        NSInteger projectRows = amproj_visibleProjectsRowCount();
        NSInteger titleMatches = amproj_projectTitleMatchCount(title);
        if (projectRows < 0 || titleMatches < 0) {
            if (attempt < 240) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_captureActivatedPackageBaselinesAttempt(
                        URL, name, transactionID, attempt + 1);
                });
            } else {
                amproj_failActivatedPackageBaseline(
                    transactionID, name,
                    @"项目列表数据源未就绪，无法安全记录创建项目前基线");
            }
            return;
        }
        amproj_importProjectRowBaselineCount = projectRows;
        transaction.projectTitleMatchBaselineCount = titleMatches;
        transaction.projectTitlePresentAtBaseline = titleMatches > 0;
        transaction.projectTitleBaselineCaptured = YES;
        amproj_debugEvent(@"import.project_title_baseline", @{
            @"transaction_id": transactionID ?: @"",
            @"title": title ?: @"",
            @"present": @(transaction.projectTitlePresentAtBaseline),
            @"match_count": @(titleMatches),
            @"row_count": @(projectRows),
            @"ready": @YES,
            @"owner": @"activated_package"
        });
        NSUInteger generation = amproj_pendingImportGeneration;
        BOOL persistenceBaselineReady =
            transaction.persistenceBaselineCaptured &&
            transaction.persistenceBaselineGeneration == generation;
        if (!persistenceBaselineReady) {
            if (!transaction.persistenceBaselineCaptureStarted) {
                transaction.persistenceBaselineCaptureStarted = YES;
                amproj_captureActivatedPersistenceBaseline(
                    transactionID, generation,
                    transaction.persistenceProbeEpoch, ^(BOOL captured) {
                    AMProjImportTransaction *current =
                        amproj_importTransactionForID(transactionID);
                    BOOL stillOwnsLane = current &&
                        generation == amproj_pendingImportGeneration &&
                        [amproj_pendingImportTransactionID
                            isEqualToString:transactionID];
                    if (current) current.persistenceBaselineCaptureStarted = NO;
                    if (!stillOwnsLane) return;
                    if (!captured && attempt < 240) {
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          500 * NSEC_PER_MSEC),
                            dispatch_get_main_queue(), ^{
                            amproj_captureActivatedPackageBaselinesAttempt(
                                URL, name, transactionID, attempt + 1);
                        });
                        return;
                    }
                    if (!captured) {
                        amproj_failActivatedPackageBaseline(
                            transactionID, name,
                            @"无法记录当前导入事务的持久化基线");
                        return;
                    }
                    amproj_captureActivatedPackageBaselinesAttempt(
                        URL, name, transactionID, attempt);
                });
            }
            return;
        }
        amproj_tryDispatchPendingImport(amproj_pendingImportGeneration);
    });
}

static void amproj_captureActivatedPackageBaselines(NSURL *URL,
                                                     NSString *name,
                                                     NSString *transactionID) {
    amproj_captureActivatedPackageBaselinesAttempt(URL, name, transactionID, 0);
}

static void amproj_enqueueXMLTemplateImport(NSURL *URL,
                                             NSString *name,
                                             NSString *transactionID) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"xml_template_queue");
        return;
    }
    if (!URL || !transactionID.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_xmlTemplatePendingQueue) {
            amproj_xmlTemplatePendingQueue = [NSMutableArray array];
        }
        if ([amproj_xmlTemplateImportTransactionID isEqualToString:transactionID]) return;
        for (NSDictionary *entry in amproj_xmlTemplatePendingQueue) {
            if ([entry[@"transaction_id"] isEqualToString:transactionID]) return;
        }
        [amproj_xmlTemplatePendingQueue addObject:@{
            @"url": URL,
            @"name": name ?: URL.lastPathComponent ?: @"project.xml",
            @"transaction_id": transactionID
        }];
        amproj_debugEvent(@"import.xml_template_queued", @{
            @"transaction_id": transactionID,
            @"depth": @(amproj_xmlTemplatePendingQueue.count)
        });
        amproj_resumeQueuedImports(@"xml_enqueued");
    });
}

static void amproj_pumpXMLTemplateImports(void) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"xml_template_pump");
        return;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_pumpXMLTemplateImports();
        });
        return;
    }
    if (CFAbsoluteTimeGetCurrent() <
        amproj_xmlTemplateResultQuarantineUntil) {
        amproj_resumeAfterXMLResultAlert(0);
        return;
    }
    if (amproj_xmlTemplateImportActive || amproj_pendingImportURL ||
        amproj_importVerificationActive ||
        amproj_nativeImportObservationActive || amproj_nativeImportAlertActive ||
        amproj_waitingForNativeImportAlert || !amproj_xmlTemplatePendingQueue.count) {
        return;
    }
    NSDictionary *entry = amproj_xmlTemplatePendingQueue.firstObject;
    [amproj_xmlTemplatePendingQueue removeObjectAtIndex:0];
    NSString *transactionID = entry[@"transaction_id"];
    if (!amproj_importTransactionForID(transactionID)) {
        amproj_pumpXMLTemplateImports();
        return;
    }
    amproj_xmlTemplateImportActive = YES;
    amproj_xmlTemplateImportTransactionID = [transactionID copy];
    ++amproj_xmlTemplateImportGeneration;
    amproj_beginXMLTemplateImport(entry[@"url"], entry[@"name"],
                                  transactionID, 0);
}

static void amproj_resumeAfterXMLResultAlert(NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (attempt == 0) {
            if (amproj_xmlTemplateResultAlertWaitScheduled) return;
            amproj_xmlTemplateResultAlertWaitScheduled = YES;
        }
        UIViewController *alert = amproj_xmlTemplateResultAlert;
        BOOL visible = alert && alert.viewIfLoaded.window &&
            alert.presentingViewController;
        if (visible) {
            if (attempt > 0 && attempt % 480 == 0) {
                amproj_debugEvent(@"import.xml_result_alert_still_visible", @{
                    @"wait_seconds": @(attempt / 4)
                });
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_resumeAfterXMLResultAlert(attempt + 1);
            });
            return;
        }
        UIDocumentPickerViewController *retiredPicker =
            amproj_xmlTemplateRetiredPicker;
        BOOL pickerVisible = retiredPicker &&
            (retiredPicker.viewIfLoaded.window ||
             retiredPicker.presentingViewController);
        if (pickerVisible) {
            [retiredPicker dismissViewControllerAnimated:NO completion:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_resumeAfterXMLResultAlert(attempt + 1);
            });
            return;
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now < amproj_xmlTemplateResultQuarantineUntil) {
            NSTimeInterval remaining =
                amproj_xmlTemplateResultQuarantineUntil - now;
            dispatch_after(dispatch_time(
                               DISPATCH_TIME_NOW,
                               (int64_t)(MIN(remaining, 0.25) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                amproj_resumeAfterXMLResultAlert(attempt + 1);
            });
            return;
        }
        amproj_xmlTemplateResultAlert = nil;
        amproj_xmlTemplateRetiredPicker = nil;
        amproj_xmlTemplateResultAlertWaitScheduled = NO;
        amproj_resumeQueuedImports(@"xml_result_alert_dismissed");
    });
}

static void amproj_finishXMLTemplateImportInternal(NSString *transactionID,
                                                    BOOL success,
                                                    NSString *message,
                                                    BOOL presentError) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    BOOL requestedSuccess = success;
    success = success && transaction.nativeCompletionSucceeded &&
        transaction.persistenceVerified;
    if (requestedSuccess && !success && !message.length) {
        message = @"XML import did not satisfy the native result and Projects persistence gates";
    }
    NSURL *incomingURL = transaction.incomingURL;
    NSURL *incomingCleanupURL = transaction.incomingCleanupURL;
    NSURL *stagedDirectoryURL = transaction.stagedDirectoryURL;
    BOOL deleteIncoming = transaction.deleteIncomingSourceOnCompletion;
    NSString *fingerprint = [transaction.fingerprint copy];
    NSString *source = [transaction.source copy];
    NSString *title = amproj_transactionExpectedTitle(transaction, transaction.name);
    UIDocumentPickerViewController *nativePicker =
        transaction.xmlTemplateNativePicker;
    if (nativePicker) {
        amproj_xmlTemplateRetiredPicker = nativePicker;
        if (nativePicker.viewIfLoaded.window ||
            nativePicker.presentingViewController) {
            [nativePicker dismissViewControllerAnimated:NO completion:nil];
        }
    }
    if ([amproj_xmlTemplateImportTransactionID isEqualToString:transactionID]) {
        amproj_xmlTemplateImportActive = NO;
        amproj_xmlTemplateImportTransactionID = nil;
        ++amproj_xmlTemplateImportGeneration;
    }
    amproj_xmlTemplateResultQuarantineUntil =
        CFAbsoluteTimeGetCurrent() + 2.0;
    if (success) {
        if (deleteIncoming && incomingURL) {
            [NSFileManager.defaultManager removeItemAtURL:incomingURL error:nil];
        }
        if (incomingCleanupURL) {
            [NSFileManager.defaultManager removeItemAtURL:incomingCleanupURL error:nil];
        }
        if (stagedDirectoryURL) {
            [NSFileManager.defaultManager removeItemAtURL:stagedDirectoryURL error:nil];
        }
        amproj_writeImportBreadcrumb(transactionID, fingerprint, @"completed",
                                     source, nil, @3, nil);
        amproj_debugEvent(@"import.xml_template_verified", @{
            @"transaction_id": transactionID ?: @"",
            @"title": title ?: @""
        });
        amproj_releaseImportTransaction(transactionID, YES);
        amproj_showImportStatusForTransaction(
            @"AMProj · 3/3 XML 已导入“您的模板”", NO, transactionID);
    } else {
        amproj_retryImportURL = transaction.archiveURL;
        amproj_retryImportName = [transaction.name copy];
        NSString *errorText = message.length ? message :
            @"XML import did not produce a verified Projects persistence result";
        amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                     source, nil, nil, errorText);
        amproj_releaseImportTransaction(transactionID, NO);
        NSString *visible = [NSString stringWithFormat:
            @"AMProj · XML 导入未完成：%@", errorText];
        amproj_showImportStatusForTransaction(visible, YES, transactionID);
        if (presentError) amproj_presentXMLImportError(visible, YES);
    }
    amproj_resumeAfterXMLResultAlert(0);
}

static void amproj_finishXMLTemplateImportAfterPicker(
    NSString *transactionID, BOOL success, NSString *message,
    BOOL presentError, NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        UIDocumentPickerViewController *picker =
            transaction.xmlTemplateNativePicker;
        BOOL pickerVisible = picker &&
            (picker.viewIfLoaded.window || picker.presentingViewController);
        if (pickerVisible && attempt < 40) {
            transaction.xmlTemplatePickerDismissRequested = YES;
            [picker dismissViewControllerAnimated:NO completion:nil];
            if (attempt >= 20 && picker.presentingViewController) {
                [picker.presentingViewController
                    dismissViewControllerAnimated:NO completion:nil];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_finishXMLTemplateImportAfterPicker(
                    transactionID, success, message,
                    presentError, attempt + 1);
            });
            return;
        }
        BOOL pickerClosed = !pickerVisible;
        if (transaction) {
            transaction.xmlTemplatePickerDismissVerified = pickerClosed;
        }
        BOOL finalSuccess = success && pickerClosed;
        NSString *finalMessage = message;
        if (!pickerClosed) {
            finalMessage =
                @"AM 的原生 XML 文件选择器未能关闭，已保留 XML 缓存";
        }
        amproj_finishXMLTemplateImportInternal(
            transactionID, finalSuccess, finalMessage, presentError);
    });
}

static void amproj_finishXMLTemplateImport(NSString *transactionID,
                                            BOOL success,
                                            NSString *message) {
    amproj_finishXMLTemplateImportAfterPicker(
        transactionID, success, message, YES, 0);
}

static void amproj_verifyXMLTemplateImport(NSUInteger generation,
                                           NSString *transactionID,
                                           NSString *name,
                                           NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_xmlTemplateImportActive ||
            generation != amproj_xmlTemplateImportGeneration ||
            ![amproj_xmlTemplateImportTransactionID isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || transaction.kind != AMProjImportKindXMLTemplate) {
            amproj_finishXMLTemplateImport(
                transactionID, NO, @"XML 导入事务已经失效");
            return;
        }
        BOOL changedToProjects = amproj_selectMainTab(NO, transactionID);
        BOOL projectsVisible = amproj_visibleProjectsControllers().count > 0;
        BOOL verified = transaction.nativeCompletionSucceeded &&
            transaction.persistenceVerified;
        amproj_debugEvent(verified ? @"import.xml_project_persistence_verified"
                                   : @"import.xml_project_persistence_probe", @{
            @"transaction_id": transactionID ?: @"",
            @"attempt": @(attempt),
            @"projects_visible": @(projectsVisible),
            @"tab_changed": @(changedToProjects),
            @"native_completion_succeeded":
                @(transaction.nativeCompletionSucceeded),
            @"persistence_verified": @(transaction.persistenceVerified),
            @"verified": @(verified),
            @"host": @"projects"
        });
        if (verified) {
            amproj_finishXMLTemplateImport(transactionID, YES, nil);
            return;
        }
        if (!transaction.xmlTemplatePersistenceProbeInFlight &&
            transaction.persistenceBaselineCaptured &&
            transaction.persistenceBaselineGeneration == generation &&
            transaction.xmlTemplateDispatchStarted) {
            transaction.xmlTemplatePersistenceProbeInFlight = YES;
            amproj_probeXMLPersistence(transactionID, generation, nil);
        }
        if (attempt >= 60) {
            NSString *reason = transaction.nativeCompletionSucceeded
                ? @"XML import completed, but no Projects persistence change was verified; cached file retained"
                : @"The Projects XML import callback did not report success; cached file retained";
            amproj_finishXMLTemplateImport(
                transactionID, NO, reason);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_verifyXMLTemplateImport(
                generation, transactionID, name, attempt + 1);
        });
    });
}

static NSArray<UIDocumentPickerViewController *> *
amproj_visibleXMLDocumentPickers(void) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    NSMutableArray<UIDocumentPickerViewController *> *result =
        [NSMutableArray array];
    __block void (^walk)(UIViewController *);
    walk = ^(UIViewController *controller) {
        if (!controller) return;
        NSValue *identity =
            [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) return;
        [visited addObject:identity];
        if ([controller isKindOfClass:UIDocumentPickerViewController.class] &&
            controller.viewIfLoaded.window) {
            [result addObject:(UIDocumentPickerViewController *)controller];
        }
        walk(controller.presentedViewController);
        for (UIViewController *child in controller.childViewControllers) {
            walk(child);
        }
        if ([controller isKindOfClass:UINavigationController.class]) {
            for (UIViewController *child in
                 ((UINavigationController *)controller).viewControllers) {
                walk(child);
            }
        }
    };
    for (UIWindow *window in amproj_foregroundApplicationWindows()) {
        walk(window.rootViewController);
    }
    walk = nil;
    return [result copy];
}

static NSSet<NSValue *> *amproj_visibleXMLDocumentPickerIdentities(void) {
    NSMutableSet<NSValue *> *identities = [NSMutableSet set];
    for (UIDocumentPickerViewController *picker in
         amproj_visibleXMLDocumentPickers()) {
        [identities addObject:[NSValue valueWithPointer:
            (__bridge const void *)picker]];
    }
    return [identities copy];
}

static UIDocumentPickerViewController *amproj_newXMLDocumentPicker(
    AMProjImportTransaction *transaction) {
    if (!transaction || !transaction.xmlTemplatePickerLaunchStarted) return nil;
    UIWindow *ownerWindow = transaction.xmlTemplateOwner.viewIfLoaded.window;
    for (UIDocumentPickerViewController *picker in
         amproj_visibleXMLDocumentPickers()) {
        NSValue *identity = [NSValue valueWithPointer:
            (__bridge const void *)picker];
        if ([transaction.xmlTemplatePickerBaseline containsObject:identity]) continue;
        if (!ownerWindow || picker.viewIfLoaded.window != ownerWindow) continue;
        return picker;
    }
    return nil;
}

static NSString *amproj_xmlUploadComparableText(NSString *text) {
    return amproj_templateComparableText(text ?: @"");
}

static NSString *amproj_xmlUploadObjectText(id object) {
    if (!object) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    @try {
        if ([object isKindOfClass:UILabel.class]) {
            if (((UILabel *)object).text.length) [parts addObject:((UILabel *)object).text];
        }
        if ([object isKindOfClass:UITextView.class]) {
            if (((UITextView *)object).text.length) [parts addObject:((UITextView *)object).text];
        }
        if ([object isKindOfClass:UITextField.class]) {
            if (((UITextField *)object).text.length) [parts addObject:((UITextField *)object).text];
            if (((UITextField *)object).placeholder.length) [parts addObject:((UITextField *)object).placeholder];
        }
        if ([object isKindOfClass:UIButton.class]) {
            NSString *title = [((UIButton *)object) titleForState:UIControlStateNormal];
            if (title.length) [parts addObject:title];
        }
        if ([object respondsToSelector:@selector(accessibilityLabel)] &&
            [object accessibilityLabel].length) {
            [parts addObject:[object accessibilityLabel]];
        }
        if ([object respondsToSelector:@selector(accessibilityValue)] &&
            [[object accessibilityValue] isKindOfClass:NSString.class] &&
            [[object accessibilityValue] length]) {
            [parts addObject:[object accessibilityValue]];
        }
        if ([object respondsToSelector:@selector(accessibilityHint)] &&
            [[object accessibilityHint] isKindOfClass:NSString.class] &&
            [[object accessibilityHint] length]) {
            [parts addObject:[object accessibilityHint]];
        }
        if ([object isKindOfClass:UIView.class]) {
            NSMutableArray<NSString *> *descendantText = [NSMutableArray array];
            amproj_collectViewTexts((UIView *)object, descendantText,
                                    [NSMutableSet set], 0);
            [parts addObjectsFromArray:descendantText];
        }
    } @catch (__unused NSException *exception) {
        return [parts componentsJoinedByString:@" "];
    }
    return [parts componentsJoinedByString:@" "];
}

static UIAccessibilityTraits amproj_xmlUploadObjectTraits(id object) {
    if (!object || ![object respondsToSelector:@selector(accessibilityTraits)]) return 0;
    @try {
        return [object accessibilityTraits];
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

static NSString *amproj_xmlUploadObjectIdentifier(id object) {
    if (!object || ![object respondsToSelector:@selector(accessibilityIdentifier)]) return @"";
    @try {
        id identifier = [object accessibilityIdentifier];
        return [identifier isKindOfClass:NSString.class] ? identifier : @"";
    } @catch (__unused NSException *exception) {
        return @"";
    }
}

static NSInteger amproj_xmlUploadCandidateScore(id object) {
    if (!object) return 0;
    UIAccessibilityTraits traits = amproj_xmlUploadObjectTraits(object);
    BOOL isControl = [object isKindOfClass:UIControl.class];
    BOOL isButton = (traits & UIAccessibilityTraitButton) != 0;
    BOOL canActivate = [object respondsToSelector:@selector(accessibilityActivate)] || isControl;
    if (!canActivate || (!isControl && !isButton)) return 0;

    NSString *identifier = amproj_xmlUploadObjectIdentifier(object).lowercaseString;
    if ([identifier isEqualToString:@"xml_importer.entry_point.button"]) return 1000;
    if ([identifier containsString:@"xml_importer"] &&
        [identifier containsString:@"entry_point"] &&
        [identifier containsString:@"button"]) return 950;

    NSString *text = amproj_xmlUploadObjectText(object);
    NSString *comparable = amproj_xmlUploadComparableText(text);
    NSSet<NSString *> *exact = [NSSet setWithObjects:
        @"上传", @"upload", @"上传xml", @"uploadxml",
        @"导入xml", @"importxml", nil];
    if ([exact containsObject:comparable]) return 850;
    if ([comparable containsString:@"upload"] &&
        [comparable containsString:@"xml"]) return 700;
    if ([comparable containsString:@"导入"] &&
        [comparable containsString:@"xml"]) return 650;
    if (isControl && amproj_controlActionsContainTerms(
            (UIControl *)object, @[@"upload", @"xml", @"import"])) return 500;
    return 0;
}

static NSDictionary *amproj_xmlUploadCandidateDebug(id object, NSInteger score) {
    NSString *identifier = amproj_xmlUploadObjectIdentifier(object);
    UIAccessibilityTraits traits = amproj_xmlUploadObjectTraits(object);
    CGRect frame = CGRectZero;
    @try {
        if ([object isKindOfClass:UIView.class]) frame = [object frame];
        else if ([object respondsToSelector:@selector(accessibilityFrame)]) {
            frame = [object accessibilityFrame];
        }
    } @catch (__unused NSException *exception) {
    }
    return @{
        @"class": NSStringFromClass([object class]) ?: @"",
        @"text": amproj_xmlUploadObjectText(object) ?: @"",
        @"identifier": identifier ?: @"",
        @"traits": @(traits),
        @"score": @(score),
        @"frame": NSStringFromCGRect(frame)
    };
}

static void amproj_collectXMLUploadCandidates(
    UIView *view, NSMutableArray<NSDictionary *> *candidates,
    NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!view || !candidates || depth > 32 || view.hidden || view.alpha <= 0.01) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    NSInteger score = amproj_xmlUploadCandidateScore(view);
    if (score > 0) {
        [candidates addObject:@{
            @"object": view,
            @"score": @(score),
            @"debug": amproj_xmlUploadCandidateDebug(view, score)
        }];
    }
    for (UIView *child in view.subviews) {
        amproj_collectXMLUploadCandidates(child, candidates, visited, depth + 1);
    }
    for (id element in amproj_accessibilityChildren(view)) {
        if ([element isKindOfClass:UIView.class]) {
            amproj_collectXMLUploadCandidates((UIView *)element, candidates, visited, depth + 1);
            continue;
        }
        NSValue *elementIdentity = [NSValue valueWithPointer:(__bridge const void *)element];
        if ([visited containsObject:elementIdentity]) continue;
        [visited addObject:elementIdentity];
        NSInteger elementScore = amproj_xmlUploadCandidateScore(element);
        if (elementScore > 0) {
            [candidates addObject:@{
                @"object": element,
                @"score": @(elementScore),
                @"debug": amproj_xmlUploadCandidateDebug(element, elementScore)
            }];
        }
    }
}

static id amproj_activateXMLUploadView(
    UIViewController *owner,
    NSSet<NSValue *> *excludedIdentities,
    NSArray<NSDictionary *> **candidateDebug) {
    if (!owner.viewIfLoaded.window) return nil;
    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    if (owner.viewIfLoaded) [roots addObject:owner.viewIfLoaded];
    UINavigationController *navigation = owner.navigationController;
    if (navigation.navigationBar) [roots addObject:navigation.navigationBar];
    if (navigation.viewIfLoaded) [roots addObject:navigation.viewIfLoaded];
    UIWindow *window = owner.viewIfLoaded.window;
    if (window) [roots addObject:window];

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIView *root in roots) {
        amproj_collectXMLUploadCandidates(root, candidates, visited, 0);
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                        NSDictionary *right) {
        NSInteger lhs = [left[@"score"] integerValue];
        NSInteger rhs = [right[@"score"] integerValue];
        return lhs == rhs ? NSOrderedSame : (lhs > rhs ? NSOrderedAscending : NSOrderedDescending);
    }];
    if (candidateDebug) {
        NSMutableArray *debug = [NSMutableArray arrayWithCapacity:candidates.count];
        for (NSDictionary *candidate in candidates) {
            id object = candidate[@"object"];
            NSValue *identity = [NSValue valueWithPointer:
                (__bridge const void *)object];
            NSMutableDictionary *entry =
                [candidate[@"debug"] mutableCopy];
            entry[@"previously_attempted"] =
                @([excludedIdentities containsObject:identity]);
            [debug addObject:entry];
        }
        *candidateDebug = [debug copy];
    }
    for (NSDictionary *candidate in candidates) {
        id object = candidate[@"object"];
        NSValue *identity = [NSValue valueWithPointer:
            (__bridge const void *)object];
        if ([excludedIdentities containsObject:identity]) continue;
        if (amproj_activateView(object)) return object;
    }
    return nil;
}

static void amproj_waitForXMLPickerDismissal(
    NSUInteger generation, NSString *transactionID, NSString *name,
    NSUInteger dispatchGeneration, NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_xmlTemplateImportActive ||
            generation != amproj_xmlTemplateImportGeneration ||
            ![amproj_xmlTemplateImportTransactionID
                isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction ||
            transaction.xmlTemplateDispatchGeneration != dispatchGeneration ||
            !transaction.xmlTemplateNativePicker) return;
        UIDocumentPickerViewController *picker =
            transaction.xmlTemplateNativePicker;
        BOOL visible = picker.viewIfLoaded.window ||
            picker.presentingViewController;
        if (visible) {
            if (!transaction.xmlTemplatePickerDismissRequested ||
                (attempt > 0 && attempt % 8 == 0)) {
                transaction.xmlTemplatePickerDismissRequested = YES;
                [picker dismissViewControllerAnimated:NO completion:nil];
                amproj_debugEvent(@"import.xml_native_picker_dismiss_requested", @{
                    @"transaction_id": transactionID ?: @"",
                    @"dispatch_generation": @(dispatchGeneration)
                });
            }
            if (attempt >= 20 && picker.presentingViewController) {
                [picker.presentingViewController
                    dismissViewControllerAnimated:NO completion:nil];
            }
            if (attempt >= 40) {
                amproj_finishXMLTemplateImport(
                    transactionID, NO,
                    @"AM 的原生 XML 文件选择器无法关闭，已停止后续导入");
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_waitForXMLPickerDismissal(
                    generation, transactionID, name,
                    dispatchGeneration, attempt + 1);
            });
            return;
        }
        transaction.xmlTemplatePickerDismissVerified = YES;
        amproj_debugEvent(@"import.xml_native_picker_dismissed", @{
            @"transaction_id": transactionID ?: @"",
            @"dispatch_generation": @(dispatchGeneration),
            @"attempt": @(attempt)
        });
        amproj_verifyXMLTemplateImport(
            generation, transactionID, name, 0);
    });
}

static void amproj_beginXMLTemplateImport(NSURL *URL,
                                          NSString *name,
                                          NSString *transactionID,
                                          NSUInteger attempt) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"xml_template_begin");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || transaction.kind != AMProjImportKindXMLTemplate) return;
        if (!amproj_xmlTemplateImportActive) {
            // Direct callers are kept safe for older lifecycle paths; normal
            // delivery goes through amproj_pumpXMLTemplateImports, which owns
            // the single active transaction and serializes later XML files.
            amproj_xmlTemplateImportActive = YES;
            amproj_xmlTemplateImportTransactionID = [transactionID copy];
            ++amproj_xmlTemplateImportGeneration;
        } else if (![amproj_xmlTemplateImportTransactionID isEqualToString:transactionID]) {
            amproj_enqueueXMLTemplateImport(URL, name, transactionID);
            return;
        }
        NSUInteger generation = amproj_xmlTemplateImportGeneration;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            if (attempt < 240) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginXMLTemplateImport(URL, name, transactionID, attempt + 1);
                });
            } else {
                amproj_finishXMLTemplateImport(
                    transactionID, NO,
                    @"Waiting for the foreground Projects page timed out");
            }
            return;
        }
        BOOL changed = amproj_selectMainTab(NO, transactionID);
        SEL multipleSelector =
            @selector(documentPicker:didPickDocumentsAtURLs:);
        SEL singleSelector = @selector(documentPicker:didPickDocumentAtURL:);
        UIViewController *owner = nil;
        for (UIViewController *controller in amproj_visibleProjectsControllers()) {
            if ([controller respondsToSelector:multipleSelector] ||
                [controller respondsToSelector:singleSelector]) {
                owner = controller;
                break;
            }
        }
        if (changed || !owner) {
            if (attempt < 240) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginXMLTemplateImport(URL, name, transactionID, attempt + 1);
                });
            } else {
                amproj_finishXMLTemplateImport(
                    transactionID, NO,
                    @"The Projects XML import entry point did not become ready");
            }
            return;
        }
        if (!transaction.persistenceBaselineCaptured ||
            transaction.persistenceBaselineGeneration != generation) {
            if (!transaction.persistenceBaselineCaptureStarted) {
                transaction.persistenceBaselineCaptureStarted = YES;
                amproj_captureXMLPersistenceBaseline(
                    transactionID, generation, ^(BOOL captured) {
                    if (!captured) {
                        amproj_finishXMLTemplateImport(
                            transactionID, NO,
                            @"Unable to capture the Projects persistence baseline before XML import; cached file retained");
                        return;
                    }
                    amproj_beginXMLTemplateImport(
                        URL, name, transactionID, attempt);
                });
            }
            return;
        }
        if (transaction.xmlTemplateDispatchStarted) return;

        BOOL supportsMultiple = [owner respondsToSelector:multipleSelector];
        BOOL supportsSingle = [owner respondsToSelector:singleSelector];
        UIDocumentPickerViewController *nativePicker = nil;
        @try {
            if (@available(iOS 14.0, *)) {
                UTType *xmlType = [UTType typeWithIdentifier:@"public.xml"];
                nativePicker = [[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:xmlType ? @[xmlType] : @[UTTypeData]
                    asCopy:YES];
            } else {
                nativePicker = [[UIDocumentPickerViewController alloc]
                    initWithDocumentTypes:@[@"public.xml"]
                    inMode:UIDocumentPickerModeImport];
            }
        } @catch (NSException *exception) {
            amproj_finishXMLTemplateImport(
                transactionID, NO,
                exception.reason ?: @"无法创建 XML 导入桥接对象");
            return;
        }
        if (!nativePicker || (!supportsMultiple && !supportsSingle)) {
            amproj_finishXMLTemplateImport(
                transactionID, NO,
                @"The Projects XML native import callback is unavailable; cached file retained");
            return;
        }
        nativePicker.delegate = (id<UIDocumentPickerDelegate>)owner;
        transaction.xmlTemplateNativePicker = nativePicker;
        transaction.xmlTemplateNativePickerDelegate = owner;
        transaction.xmlTemplateOwner = owner;
        transaction.xmlTemplatePickerPresenter = owner;
        transaction.xmlTemplatePickerLaunchStarted = YES;
        transaction.xmlTemplatePickerLaunchStartedAt = CFAbsoluteTimeGetCurrent();
        transaction.xmlTemplatePickerDismissVerified = YES;
        transaction.xmlTemplateDispatchStartedAt = CFAbsoluteTimeGetCurrent();
        NSUInteger dispatchGeneration =
            ++transaction.xmlTemplateDispatchGeneration;
        transaction.xmlTemplatePickerDelegateInvoked = YES;
        transaction.xmlTemplateDispatchStarted = YES;
        amproj_markImportTransactionState(
            transactionID, AMProjImportTransactionCreatingProject);
        @try {
            if (supportsMultiple) {
                ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
                    owner, multipleSelector, nativePicker, @[URL]);
            } else {
                ((void (*)(id, SEL, id, id))(void *)objc_msgSend)(
                    owner, singleSelector, nativePicker, URL);
            }
        } @catch (NSException *exception) {
            transaction.xmlTemplatePickerDelegateInvoked = NO;
            transaction.xmlTemplateDispatchStarted = NO;
            transaction.xmlTemplateNativePicker = nil;
            transaction.xmlTemplateNativePickerDelegate = nil;
            transaction.xmlTemplatePickerPresenter = nil;
            transaction.xmlTemplateDispatchStartedAt = 0;
            amproj_finishXMLTemplateImport(
                transactionID, NO,
                exception.reason ?: @"The Projects XML native import callback raised an exception");
            return;
        }
        amproj_debugEvent(@"import.xml_template_dispatch", @{
            @"transaction_id": transactionID ?: @"",
            @"controller": NSStringFromClass(owner.class) ?: @"",
            @"picker": NSStringFromClass(nativePicker.class) ?: @"",
            @"delegate": NSStringFromClass(owner.class) ?: @"",
            @"selector": supportsMultiple
                ? NSStringFromSelector(multipleSelector)
                : NSStringFromSelector(singleSelector),
            @"dispatch_generation": @(dispatchGeneration),
            @"filename": URL.lastPathComponent ?: @"",
            @"route": @"projects_direct_delegate"
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_verifyXMLTemplateImport(
                generation, transactionID, name, 0);
        });
    });
}

static BOOL amproj_persistencePathIsPluginOwned(NSString *relativePath) {
    NSString *path = relativePath.lowercaseString;
    return [path hasPrefix:@"library/application support/amprojimports/"] ||
        [path isEqualToString:@"library/application support/amprojimports"] ||
        [path hasPrefix:@"library/caches/amprojexport/"] ||
        [path isEqualToString:@"library/caches/amprojexport"] ||
        [path hasPrefix:@"library/caches/amprojimports/"] ||
        [path isEqualToString:@"library/caches/amprojimports"] ||
        [path containsString:@"/amprojdebug/"] ||
        [path containsString:@"/amdebug/"];
}

static BOOL amproj_persistencePathIsNativeTemporary(NSString *relativePath) {
    return [relativePath.lowercaseString containsString:@"temp_pkgimport"];
}

static BOOL amproj_persistencePathIsDatabase(NSString *relativePath) {
    NSString *path = relativePath.lowercaseString;
    NSString *extension = path.pathExtension;
    return [@[@"db", @"sqlite", @"sqlite3", @"realm"] containsObject:extension] ||
        [path hasSuffix:@"-wal"] || [path hasSuffix:@"-shm"] ||
        [path containsString:@"/databases/"];
}

static BOOL amproj_persistencePathIsStable(NSString *relativePath) {
    NSString *path = relativePath.lowercaseString;
    if (amproj_persistencePathIsPluginOwned(relativePath) ||
        amproj_persistencePathIsNativeTemporary(relativePath)) return NO;
    // Cache churn from thumbnails/networking is not evidence that a project
    // was committed. Documents and non-cache Library storage are stable.
    return ![path hasPrefix:@"library/caches/"] &&
        ![path isEqualToString:@"library/caches"];
}

static NSDictionary* amproj_captureImportPersistenceSnapshot(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSDictionary *> *files = [NSMutableDictionary dictionary];
    NSString *home = NSHomeDirectory();
    if (!home.length) return @{ @"files": @{}, @"scanned": @0, @"truncated": @NO };
    NSArray<NSDictionary *> *roots = @[
        @{ @"name": @"Documents", @"url":
            [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Documents"]
                       isDirectory:YES] },
        @{ @"name": @"Library", @"url":
            [NSURL fileURLWithPath:[home stringByAppendingPathComponent:@"Library"]
                       isDirectory:YES] }
    ];
    const NSUInteger fileLimit = 75000;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4.0];
    NSUInteger scanned = 0;
    BOOL truncated = NO;
    NSArray<NSURLResourceKey> *keys = @[
        NSURLIsDirectoryKey, NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey,
        NSURLFileSizeKey, NSURLContentModificationDateKey
    ];
    for (NSDictionary *rootInfo in roots) {
        NSURL *root = [rootInfo[@"url"] isKindOfClass:NSURL.class]
            ? rootInfo[@"url"] : nil;
        if (!root.path.length) continue;
        NSString *rootPath = root.path.stringByStandardizingPath;
        NSString *rootName = rootInfo[@"name"];
        NSDirectoryEnumerator<NSURL *> *enumerator = [manager enumeratorAtURL:root
            includingPropertiesForKeys:keys options:0
                          errorHandler:^BOOL(NSURL *URL, NSError *error) {
            (void)URL;
            (void)error;
            return YES;
        }];
        for (NSURL *URL in enumerator) {
            if (scanned >= fileLimit || [deadline timeIntervalSinceNow] <= 0) {
                truncated = YES;
                break;
            }
            scanned++;
            NSString *path = URL.path.stringByStandardizingPath;
            if (![path hasPrefix:[rootPath stringByAppendingString:@"/"]]) continue;
            NSString *suffix = [path substringFromIndex:rootPath.length + 1];
            NSString *relative = [rootName stringByAppendingPathComponent:suffix];
            NSNumber *symbolic = nil;
            NSNumber *directory = nil;
            NSNumber *regular = nil;
            [URL getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
            [URL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
            if (symbolic.boolValue || amproj_persistencePathIsPluginOwned(relative)) {
                if (directory.boolValue) [enumerator skipDescendants];
                continue;
            }
            if (directory.boolValue) continue;
            [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (!regular.boolValue) continue;
            NSNumber *size = nil;
            NSDate *modified = nil;
            [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [URL getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
            files[relative] = @{
                @"size": size ?: @0,
                @"mtime_ms": @((long long)llround(
                    (modified ? modified.timeIntervalSince1970 : 0) * 1000.0))
            };
        }
        if (truncated) break;
    }
    return @{
        @"files": files,
        @"scanned": @(scanned),
        @"truncated": @(truncated)
    };
}

static void amproj_storeImportProjectTitle(NSString *transactionID,
                                            NSString *projectTitle) {
    @synchronized (amproj_importDedupeLock()) {
        AMProjImportTransaction *transaction = amproj_importTransactions[transactionID];
        if (!transaction) return;
        if (projectTitle.length) transaction.projectTitle = [projectTitle copy];
    }
    amproj_debugEvent(@"import.project_title_prepared", @{
        @"transaction_id": transactionID ?: @"",
        @"project_title": projectTitle ?: @""
    });
}

static void amproj_captureActivatedPersistenceBaseline(
    NSString *transactionID, NSUInteger generation, NSUInteger probeEpoch,
    void (^completion)(BOOL captured)) {
    NSString *transactionSnapshot = [transactionID copy];
    void (^completionSnapshot)(BOOL) = [completion copy];
    dispatch_async(amproj_importInboxQueue(), ^{
        NSDictionary *snapshot = amproj_captureImportPersistenceSnapshot();
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionSnapshot);
            BOOL ownsLane = transaction &&
                generation == amproj_pendingImportGeneration &&
                transaction.persistenceProbeEpoch == probeEpoch &&
                [amproj_pendingImportTransactionID isEqualToString:transactionSnapshot] &&
                transaction.state == AMProjImportTransactionWaitingForProjects;
            BOOL UIReady = UIApplication.sharedApplication.applicationState ==
                    UIApplicationStateActive &&
                amproj_visibleProjectsControllers().count > 0 &&
                transaction.projectTitleBaselineCaptured;
            BOOL captured = ownsLane && UIReady &&
                [snapshot[@"files"] isKindOfClass:NSDictionary.class];
            if (captured) {
                transaction.persistenceBaseline = snapshot;
                transaction.persistenceVerified = NO;
                transaction.persistenceBaselineCaptured = YES;
                transaction.persistenceBaselineGeneration = generation;
            }
            amproj_debugEvent(@"persistence_baseline", @{
                @"transaction_id": transactionSnapshot ?: @"",
                @"generation": @(generation),
                @"probe_epoch": @(probeEpoch),
                @"lane_owned": @(ownsLane),
                @"ui_owner_ready": @(UIReady),
                @"captured": @(captured),
                @"file_count": @([snapshot[@"files"] count]),
                @"scanned": snapshot[@"scanned"] ?: @0,
                @"truncated": snapshot[@"truncated"] ?: @NO,
                @"project_title": transaction.projectTitle ?: @""
            });
            if (completionSnapshot) completionSnapshot(captured);
        });
    });
}

static NSString* amproj_relativeSandboxPath(NSString *path) {
    NSString *home = NSHomeDirectory().stringByStandardizingPath;
    NSString *standard = path.stringByStandardizingPath;
    if ([standard hasPrefix:[home stringByAppendingString:@"/"]]) {
        return [standard substringFromIndex:home.length + 1];
    }
    return standard.lastPathComponent ?: @"";
}

static void amproj_appendCappedPath(NSMutableArray<NSString *> *paths,
                                    NSString *path) {
    if (path.length && paths.count < 32) [paths addObject:path];
}

static NSDictionary* amproj_importPersistenceDelta(NSDictionary *baseline,
                                                    NSDictionary *current,
                                                    NSString *nativeTemporaryPath) {
    BOOL baselineAvailable = [baseline[@"files"] isKindOfClass:NSDictionary.class];
    NSDictionary *before = [baseline[@"files"] isKindOfClass:NSDictionary.class]
        ? baseline[@"files"] : @{};
    NSDictionary *after = [current[@"files"] isKindOfClass:NSDictionary.class]
        ? current[@"files"] : @{};
    NSMutableArray<NSString *> *sceneXML = [NSMutableArray array];
    NSMutableArray<NSString *> *databases = [NSMutableArray array];
    NSMutableArray<NSString *> *applicationSupport = [NSMutableArray array];
    __block NSUInteger changedCount = 0;
    __block NSUInteger stableChangedCount = 0;
    [after enumerateKeysAndObjectsUsingBlock:
        ^(NSString *path, NSDictionary *metadata, BOOL *stop) {
        (void)stop;
        NSDictionary *old = [before[path] isKindOfClass:NSDictionary.class]
            ? before[path] : nil;
        if (old && [old isEqual:metadata]) return;
        changedCount++;
        if (!amproj_persistencePathIsStable(path)) return;
        stableChangedCount++;
        NSString *lower = path.lowercaseString;
        if ([lower.pathExtension isEqualToString:@"xml"]) {
            amproj_appendCappedPath(sceneXML, path);
        }
        if (amproj_persistencePathIsDatabase(path)) {
            amproj_appendCappedPath(databases, path);
        }
        if ([lower hasPrefix:@"library/application support/"] ||
            [lower hasPrefix:@"documents/"]) {
            amproj_appendCappedPath(applicationSupport, path);
        }
    }];
    BOOL hasTemporaryPath = nativeTemporaryPath.length > 0;
    BOOL temporaryExists = hasTemporaryPath &&
        [NSFileManager.defaultManager fileExistsAtPath:nativeTemporaryPath];
    BOOL temporaryConsumed = hasTemporaryPath && !temporaryExists;
    BOOL verified = baselineAvailable && (sceneXML.count > 0 || databases.count > 0 ||
        (temporaryConsumed && applicationSupport.count > 0));
    return @{
        @"changed_count": @(changedCount),
        @"stable_changed_count": @(stableChangedCount),
        @"scene_xml_paths": sceneXML,
        @"database_paths": databases,
        @"application_support_paths": applicationSupport,
        @"native_temp_path": amproj_relativeSandboxPath(nativeTemporaryPath ?: @""),
        @"native_temp_consumed": @(temporaryConsumed),
        @"baseline_available": @(baselineAvailable),
        @"persistence_verified": @(verified),
        @"snapshot_truncated": @([baseline[@"truncated"] boolValue] ||
                                  [current[@"truncated"] boolValue])
    };
}

static void amproj_captureXMLPersistenceBaseline(
    NSString *transactionID, NSUInteger generation,
    void (^completion)(BOOL captured)) {
    NSString *transactionSnapshot = [transactionID copy];
    void (^completionSnapshot)(BOOL) = [completion copy];
    dispatch_async(amproj_importInboxQueue(), ^{
        NSDictionary *snapshot = amproj_captureImportPersistenceSnapshot();
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionSnapshot);
            BOOL ownsXMLLane = transaction &&
                transaction.kind == AMProjImportKindXMLTemplate &&
                amproj_xmlTemplateImportActive &&
                generation == amproj_xmlTemplateImportGeneration &&
                [amproj_xmlTemplateImportTransactionID
                    isEqualToString:transactionSnapshot] &&
                !transaction.xmlTemplateDispatchStarted;
            BOOL captured = ownsXMLLane &&
                [snapshot[@"files"] isKindOfClass:NSDictionary.class] &&
                ![snapshot[@"truncated"] boolValue];
            if (transaction) transaction.persistenceBaselineCaptureStarted = NO;
            if (captured) {
                transaction.persistenceBaseline = snapshot;
                transaction.persistenceVerified = NO;
                transaction.persistenceBaselineCaptured = YES;
                transaction.persistenceBaselineGeneration = generation;
            }
            amproj_debugEvent(@"import.xml_persistence_baseline", @{
                @"transaction_id": transactionSnapshot ?: @"",
                @"generation": @(generation),
                @"lane_owned": @(ownsXMLLane),
                @"captured": @(captured),
                @"file_count": @([snapshot[@"files"] count]),
                @"scanned": snapshot[@"scanned"] ?: @0,
                @"truncated": snapshot[@"truncated"] ?: @NO
            });
            if (completionSnapshot) completionSnapshot(captured);
        });
    });
}

static void amproj_probeXMLPersistence(
    NSString *transactionID, NSUInteger generation,
    void (^completion)(BOOL verified)) {
    NSString *transactionSnapshot = [transactionID copy];
    void (^completionSnapshot)(BOOL) = [completion copy];
    __block NSDictionary *baseline = nil;
    dispatch_async(amproj_importInboxQueue(), ^{
        @synchronized (amproj_importDedupeLock()) {
            AMProjImportTransaction *transaction =
                amproj_importTransactions[transactionSnapshot];
            baseline = [transaction.persistenceBaseline copy];
        }
        NSDictionary *current = amproj_captureImportPersistenceSnapshot();
        NSDictionary *delta = amproj_importPersistenceDelta(
            baseline ?: @{}, current, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionSnapshot);
            BOOL accepted = transaction &&
                transaction.kind == AMProjImportKindXMLTemplate &&
                amproj_xmlTemplateImportActive &&
                generation == amproj_xmlTemplateImportGeneration &&
                transaction.persistenceBaselineCaptured &&
                transaction.persistenceBaselineGeneration == generation &&
                transaction.xmlTemplateDispatchStarted &&
                [amproj_xmlTemplateImportTransactionID
                    isEqualToString:transactionSnapshot];
            BOOL verified = accepted &&
                [delta[@"persistence_verified"] boolValue] &&
                ![delta[@"snapshot_truncated"] boolValue];
            if (transaction) {
                transaction.xmlTemplatePersistenceProbeInFlight = NO;
                if (verified) transaction.persistenceVerified = YES;
            }
            NSMutableDictionary *fields = [delta mutableCopy];
            fields[@"transaction_id"] = transactionSnapshot ?: @"";
            fields[@"generation"] = @(generation);
            fields[@"accepted"] = @(accepted);
            fields[@"verified"] = @(verified);
            amproj_debugEvent(@"import.xml_persistence_probe", fields);
            if (completionSnapshot) completionSnapshot(verified);
        });
    });
}

static void amproj_scheduleImportPersistenceProbe(
    NSString *transactionID, NSString *reason, void (^completion)(BOOL verified)) {
    if (!transactionID.length) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    NSString *transactionSnapshot = [transactionID copy];
    NSString *reasonSnapshot = [reason copy] ?: @"unspecified";
    void (^completionSnapshot)(BOOL) = [completion copy];
    dispatch_async(amproj_importInboxQueue(), ^{
        NSDictionary *baseline = nil;
        NSString *nativeTemporaryPath = nil;
        __block NSUInteger probeEpoch = 0;
        __block NSUInteger baselineGeneration = 0;
        __block BOOL probeEligible = NO;
        @synchronized (amproj_importDedupeLock()) {
            AMProjImportTransaction *transaction =
                amproj_importTransactions[transactionSnapshot];
            baseline = [transaction.persistenceBaseline copy];
            nativeTemporaryPath = [transaction.nativeTemporaryPath copy];
            probeEpoch = transaction.persistenceProbeEpoch;
            baselineGeneration = transaction.persistenceBaselineGeneration;
            probeEligible = transaction &&
                transaction.state == AMProjImportTransactionNativeActive &&
                transaction.persistenceBaselineCaptured &&
                baselineGeneration > 0 && baseline.count > 0;
        }
        NSDictionary *current = amproj_captureImportPersistenceSnapshot();
        NSDictionary *delta = amproj_importPersistenceDelta(
            baseline ?: @{}, current, nativeTemporaryPath);
        BOOL verified = probeEligible &&
            [delta[@"persistence_verified"] boolValue] &&
            ![delta[@"snapshot_truncated"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionSnapshot);
            BOOL accepted = transaction &&
                transaction.state == AMProjImportTransactionNativeActive &&
                transaction.persistenceProbeEpoch == probeEpoch &&
                transaction.persistenceBaselineCaptured &&
                transaction.persistenceBaselineGeneration == baselineGeneration;
            BOOL acceptedVerified = accepted && verified;
            if (accepted) {
                transaction.nativeTemporaryConsumed |=
                    [delta[@"native_temp_consumed"] boolValue];
            }
            if (acceptedVerified) transaction.persistenceVerified = YES;
            NSMutableDictionary *fields = [delta mutableCopy];
            fields[@"transaction_id"] = transactionSnapshot;
            fields[@"reason"] = reasonSnapshot;
            fields[@"probe_epoch"] = @(probeEpoch);
            fields[@"baseline_generation"] = @(baselineGeneration);
            fields[@"eligible"] = @(probeEligible);
            fields[@"accepted"] = @(accepted);
            fields[@"accepted_verified"] = @(acceptedVerified);
            amproj_debugEvent(@"persistence_delta", fields);
            if (nativeTemporaryPath.length) {
                amproj_debugEvent(@"native_temp_consumed", @{
                    @"transaction_id": transactionSnapshot,
                    @"reason": reasonSnapshot,
                    @"path": delta[@"native_temp_path"] ?: @"",
                    @"consumed": delta[@"native_temp_consumed"] ?: @NO
                });
            }
            if (acceptedVerified) {
                amproj_debugEvent(@"persistence_verified", fields);
            } else if (!accepted) {
                amproj_debugEvent(@"persistence_probe_stale", fields);
            }
            if (completionSnapshot) completionSnapshot(acceptedVerified);
        });
    });
}

static void amproj_captureTemplatePromotionPersistenceBaseline(
    NSString *transactionID, void (^completion)(BOOL captured)) {
    NSString *transactionSnapshot = [transactionID copy];
    void (^completionSnapshot)(BOOL) = [completion copy];
    dispatch_async(amproj_importInboxQueue(), ^{
        NSDictionary *snapshot = amproj_captureImportPersistenceSnapshot();
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionSnapshot);
            BOOL captured = transaction &&
                [snapshot[@"files"] isKindOfClass:NSDictionary.class];
            if (captured) {
                transaction.templatePromotionPersistenceBaseline = snapshot;
            }
            amproj_debugEvent(@"import.template_persistence_baseline", @{
                @"transaction_id": transactionSnapshot ?: @"",
                @"captured": @(captured),
                @"file_count": @([snapshot[@"files"] count]),
                @"truncated": snapshot[@"truncated"] ?: @NO
            });
            if (completionSnapshot) completionSnapshot(captured);
        });
    });
}

static void amproj_scheduleTemplatePromotionPersistenceProbe(
    NSString *transactionID, void (^completion)(BOOL verified)) {
    NSString *transactionSnapshot = [transactionID copy];
    void (^completionSnapshot)(BOOL) = [completion copy];
    dispatch_async(amproj_importInboxQueue(), ^{
        NSDictionary *baseline = nil;
        @synchronized (amproj_importDedupeLock()) {
            AMProjImportTransaction *transaction =
                amproj_importTransactions[transactionSnapshot];
            baseline = [transaction.templatePromotionPersistenceBaseline copy];
        }
        NSDictionary *current = amproj_captureImportPersistenceSnapshot();
        NSDictionary *delta = amproj_importPersistenceDelta(
            baseline ?: @{}, current, nil);
        BOOL verified = [delta[@"persistence_verified"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionSnapshot);
            if (transaction && verified) {
                transaction.templatePersistenceVerified = YES;
            }
            NSMutableDictionary *fields = [delta mutableCopy];
            fields[@"transaction_id"] = transactionSnapshot ?: @"";
            amproj_debugEvent(@"import.template_persistence_delta", fields);
            if (completionSnapshot) completionSnapshot(verified);
        });
    });
}

static BOOL amproj_projectRowVerifiedForName(NSString *name) {
    NSString *title = [name.pathExtension caseInsensitiveCompare:@"amproj"] == NSOrderedSame
        ? name.stringByDeletingPathExtension : name;
    if (!title.length) return NO;
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        @try {
            NSMutableSet<NSValue *> *visited = [NSMutableSet set];
            if (amproj_viewTreeContainsImportedTitle(controller.viewIfLoaded, title, visited, 0)) {
                return YES;
            }
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_probe_exception", @{
                @"controller": NSStringFromClass(controller.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
    for (UIView *list in amproj_visibleProjectLists()) {
        @try {
            id dataSource = nil;
            if ([list isKindOfClass:UICollectionView.class]) {
                dataSource = ((UICollectionView *)list).dataSource;
            } else if ([list isKindOfClass:UITableView.class]) {
                dataSource = ((UITableView *)list).dataSource;
            }
            if (amproj_textMatchesImportedTitle([dataSource description], title)) return YES;
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_probe_exception", @{
                @"list_class": NSStringFromClass(list.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
    return NO;
}

static BOOL amproj_reselectProjectsTabOnce(NSString *transactionID) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (!transaction || transaction.projectTabReselected) return NO;
    transaction.projectTabReselected = YES;
    BOOL selected = NO;
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        UITabBarController *tabs = controller.tabBarController;
        if (!tabs) continue;
        UIViewController *branch = controller;
        while (branch.parentViewController && branch.parentViewController != tabs) {
            branch = branch.parentViewController;
        }
        if (branch.parentViewController != tabs ||
            ![tabs.viewControllers containsObject:branch]) continue;
        tabs.selectedViewController = branch;
        [branch.viewIfLoaded setNeedsLayout];
        [tabs.viewIfLoaded setNeedsLayout];
        selected = YES;
        break;
    }
    amproj_debugEvent(@"import.projects_tab_reselected", @{
        @"transaction_id": transactionID ?: @"",
        @"selected": @(selected)
    });
    return selected;
}

static BOOL amproj_completePackageWithUnresolvedDestination(
    NSString *transactionID, NSString *name, NSString *evidence) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (!transaction || transaction.kind != AMProjImportKindPackage ||
        transaction.directProjectVerified || !transaction.persistenceVerified ||
        !transaction.packageIntegrityVerified ||
        !transaction.nativeTerminalStatus4Returned ||
        !transaction.nativeCompletionSucceeded ||
        !transaction.nativeTemporaryConsumed) return NO;

    NSString *title = amproj_transactionExpectedTitle(transaction, name);
    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = nil;
    amproj_retryImportName = nil;
    if (transaction.deleteIncomingSourceOnCompletion && transaction.incomingURL) {
        [NSFileManager.defaultManager removeItemAtURL:transaction.incomingURL error:nil];
    }
    if (transaction.incomingCleanupURL) {
        [NSFileManager.defaultManager removeItemAtURL:transaction.incomingCleanupURL error:nil];
    }
    amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                 @"completed", transaction.source,
                                 nil, @4, nil);
    amproj_debugEvent(@"import.package_destination_unresolved", @{
        @"transaction_id": transactionID ?: @"",
        @"title": title ?: @"",
        @"persistence_verified": @YES,
        @"package_integrity_verified": @YES,
        @"native_status_4_returned": @YES,
        @"native_completion_succeeded": @YES,
        @"native_temporary_consumed": @YES,
        @"evidence": evidence ?: @"native_terminal_persistence",
        @"route": @"native_terminal_destination_unknown"
    });
    amproj_releaseImportTransaction(transactionID, YES);
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = nil;
    amproj_showImportStatusForTransaction(
        @"AMProj \u00b7 4/4 \u9879\u76ee\u5305\u5df2\u5b8c\u6210\u5bfc\u5165\uff0c\u8bf7\u5728\u9879\u76ee\u6216\u201c\u60a8\u7684\u6a21\u677f\u201d\u4e2d\u67e5\u770b",
        NO, transactionID);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_resumeQueuedImports(@"package_destination_unresolved");
    });
    return YES;
}

static BOOL amproj_completePackageAsTemplate(NSString *transactionID,
                                             NSString *name,
                                             NSString *evidence) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (!transaction || transaction.kind != AMProjImportKindPackage ||
        !transaction.persistenceVerified) return NO;

    NSString *title = amproj_transactionExpectedTitle(transaction, name);
    BOOL UIKitTemplateAdded = NO;
    BOOL SwiftUITemplateAdded = NO;
    if (transaction.templateProbeCapability ==
            AMProjTemplateProbeCapabilityUIKitReady &&
        transaction.templateBaselineListReady) {
        UIKitTemplateAdded =
            amproj_newTemplateCandidateForTransaction(transaction, title) != nil;
    } else if (transaction.templateProbeCapability ==
                   AMProjTemplateProbeCapabilitySwiftUIUnavailable) {
        SwiftUITemplateAdded =
            transaction.templateAddedStableCycles >= 3 &&
            amproj_visibleTemplateViewTitleCount(title) >
                transaction.templateBaselineViewTitleCount;
    }
    if (!UIKitTemplateAdded && !SwiftUITemplateAdded) return NO;

    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = nil;
    amproj_retryImportName = nil;
    if (transaction.deleteIncomingSourceOnCompletion && transaction.incomingURL) {
        [NSFileManager.defaultManager removeItemAtURL:transaction.incomingURL error:nil];
    }
    if (transaction.incomingCleanupURL) {
        [NSFileManager.defaultManager removeItemAtURL:transaction.incomingCleanupURL error:nil];
    }
    amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                 @"completed", transaction.source,
                                 nil, @4, nil);
    amproj_debugEvent(@"import.package_template_verified", @{
        @"transaction_id": transactionID ?: @"",
        @"title": title ?: @"",
        @"persistence_verified": @YES,
        @"package_integrity_verified": @(transaction.packageIntegrityVerified),
        @"native_status_4_returned":
            @(transaction.nativeTerminalStatus4Returned),
        @"native_completion_succeeded":
            @(transaction.nativeCompletionSucceeded),
        @"native_temporary_consumed":
            @(transaction.nativeTemporaryConsumed),
        @"ui_template_verified": @(UIKitTemplateAdded || SwiftUITemplateAdded),
        @"evidence": evidence ?: (UIKitTemplateAdded
            ? @"uikit_template_identity_delta" :
              @"swiftui_title_delta"),
        @"route": @"template_final"
    });
    amproj_releaseImportTransaction(transactionID, YES);
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = nil;
    amproj_selectMainTab(YES, transactionID);
    amproj_showImportStatusForTransaction(
        @"AMProj · 4/4 完整项目包已导入“您的模板”",
        NO, transactionID);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_resumeQueuedImports(@"package_template_verified");
    });
    return YES;
}

static BOOL amproj_completePackageTransaction(NSString *transactionID,
                                               NSString *name,
                                               NSInteger rowCount,
                                               BOOL promoted) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (!transaction) return NO;
    BOOL directProjectReady = !promoted &&
        transaction.directProjectVerified &&
        transaction.packageIntegrityVerified &&
        transaction.nativeTerminalStatus4Returned &&
        transaction.nativeCompletionSucceeded &&
        transaction.nativeTemporaryConsumed;
    BOOL routeGateSatisfied = transaction.kind != AMProjImportKindPackage ||
        directProjectReady ||
        (promoted && transaction.templatePersistenceVerified &&
         transaction.templateCleanupVerified);
    if (!transaction.persistenceVerified || !routeGateSatisfied) {
        amproj_debugEvent(@"import.completion_gate_blocked", @{
            @"transaction_id": transactionID ?: @"",
            @"promoted": @(promoted),
            @"persistence_verified": @(transaction.persistenceVerified),
            @"template_persistence_verified": @(transaction.templatePersistenceVerified),
            @"template_cleanup_verified": @(transaction.templateCleanupVerified),
            @"direct_project_verified": @(transaction.directProjectVerified),
            @"native_status_4_returned":
                @(transaction.nativeTerminalStatus4Returned),
            @"native_completion_succeeded":
                @(transaction.nativeCompletionSucceeded),
            @"native_temporary_consumed":
                @(transaction.nativeTemporaryConsumed)
        });
        return NO;
    }
    NSInteger baseline = amproj_importProjectRowBaselineCount;
    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = nil;
    amproj_retryImportName = nil;
    if (transaction.deleteIncomingSourceOnCompletion && transaction.incomingURL) {
        [NSFileManager.defaultManager removeItemAtURL:transaction.incomingURL error:nil];
    }
    if (transaction.incomingCleanupURL) {
        [NSFileManager.defaultManager removeItemAtURL:transaction.incomingCleanupURL error:nil];
    }
    amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                 @"completed", transaction.source,
                                 nil, @4, nil);
    amproj_debugEvent(promoted ? @"import.project_row_verified_after_template"
                               : @"import.project_row_verified", @{
        @"transaction_id": transactionID ?: @"",
        @"title": name ?: @"",
        @"row_count": @(rowCount),
        @"baseline_row_count": @(baseline),
        @"persistence_verified": @(transaction.persistenceVerified),
        @"template_cleanup_verified": @(transaction.templateCleanupVerified)
    });
    amproj_releaseImportTransaction(transactionID, YES);
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = nil;
    amproj_selectMainTab(NO, transactionID);
    amproj_showImportStatusForTransaction(
        promoted ? @"AMProj · 4/4 项目已生成，临时模板已清理"
                 : @"AMProj · 4/4 项目已生成并出现在底部“项目”",
        NO, transactionID);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_resumeQueuedImports(@"project_row_verified");
    });
    return YES;
}

// AM 6.2.55 has a new SwiftUI template surface. The old v40-era flow below
// attempted to press "use template" and then delete the temporary template
// through accessibility. It is intentionally excluded from every stable
// dylib: successful imports now finish as native templates, and all project
// and template deletion remains exclusively owned by AM.
#if 0
static void amproj_failTemplatePromotion(NSString *transactionID,
                                         NSString *name,
                                         NSString *reason) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    NSString *message = reason.length ? reason : @"没有找到本次新增的模板";
    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = transaction.archiveURL;
    amproj_retryImportName = [transaction.name copy] ?: [name copy];
    amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                 @"failed", transaction.source,
                                 nil, @4, message);
    amproj_debugEvent(@"import.template_promotion_failed", @{
        @"transaction_id": transactionID ?: @"",
        @"title": name ?: @"",
        @"error": message
    });
    amproj_releaseImportTransaction(transactionID, NO);
    NSString *visible = [NSString stringWithFormat:
        @"AMProj · 无法从临时模板创建项目：%@", message];
    amproj_showImportStatusForTransaction(visible, YES, transactionID);
    amproj_presentImportErrorOfferingPicker(visible, NO);
    amproj_resumeQueuedImports(@"template_promotion_failed");
}

static void amproj_finishTemplateCleanupFailure(NSString *transactionID,
                                                NSString *name,
                                                NSString *reason) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    NSString *message = reason.length ? reason : @"无法安全删除本次临时模板";
    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                 @"failed", transaction.source,
                                 nil, @4, message);
    amproj_debugEvent(@"import.template_cleanup_failed", @{
        @"transaction_id": transactionID ?: @"",
        @"title": name ?: @"",
        @"error": message,
        @"project_preserved": @YES
    });
    // The project already exists. Tombstone the content fingerprint so an
    // explicit retry cannot create a duplicate project; retain the cached
    // package and the template for manual cleanup.
    amproj_releaseImportTransaction(transactionID, YES);
    amproj_selectMainTab(NO, transactionID);
    NSString *visible = [NSString stringWithFormat:
        @"AMProj · 项目已创建，但临时模板清理失败：%@", message];
    amproj_showImportStatusForTransaction(visible, YES, transactionID);
    amproj_presentImportErrorOfferingPicker(visible, NO);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_resumeQueuedImports(@"template_cleanup_failed");
    });
}

static void amproj_pollPromotedProject(NSString *transactionID,
                                      NSUInteger generation,
                                      NSString *name,
                                      NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration ||
            ![amproj_importVerificationTransactionID isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || !transaction.templateSelectionSent) return;
        // Keep the official template detail/action sheet alive until AM has
        // acknowledged the action. A fixed two-second dismiss used to abort
        // this flow before the Swift controller created the project.
        amproj_activateTemplateCreationAction(transaction);
        if (attempt >= 8 && !transaction.templatePersistenceVerified &&
            !transaction.templatePersistenceProbeStarted &&
            transaction.templatePersistenceProbeAttempts < 3) {
            transaction.templatePersistenceProbeStarted = YES;
            transaction.templatePersistenceProbeAttempts += 1;
            amproj_scheduleTemplatePromotionPersistenceProbe(
                transactionID, ^(BOOL persistenceVerified) {
                AMProjImportTransaction *current =
                    amproj_importTransactionForID(transactionID);
                if (!current || !amproj_importVerificationActive ||
                    generation != amproj_importVerificationGeneration ||
                    ![amproj_importVerificationTransactionID isEqualToString:transactionID]) {
                    return;
                }
                current.templatePersistenceProbeStarted = NO;
                current.templatePersistenceVerified = persistenceVerified;
                amproj_debugEvent(@"import.template_project_persistence", @{
                    @"transaction_id": transactionID ?: @"",
                    @"attempt": @(current.templatePersistenceProbeAttempts),
                    @"verified": @(persistenceVerified)
                });
                amproj_pollPromotedProject(
                    transactionID, generation, name, attempt);
            });
            return;
        }
        if (transaction.templatePersistenceVerified && attempt >= 8) {
            amproj_unwindTemplatePresentation();
            amproj_selectMainTab(NO, transactionID);
        } else if (transaction.templateCreationActionSent && attempt >= 8) {
            amproj_selectMainTab(NO, transactionID);
        }
        amproj_refreshVisibleProjectsRows();
        NSInteger rowCount = amproj_visibleProjectsRowCount();
        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        BOOL rowAdded = amproj_importProjectRowBaselineCount >= 0 &&
            rowCount > amproj_importProjectRowBaselineCount;
        BOOL titleFound = amproj_projectRowVerifiedForName(title);
        NSInteger titleMatchCount = amproj_projectTitleMatchCount(title);
        BOOL titleAdded = titleMatchCount >= 0 &&
            transaction.projectTitleMatchBaselineCount >= 0 &&
            titleMatchCount > transaction.projectTitleMatchBaselineCount;
        BOOL projectEvidence = titleAdded ||
            (rowAdded && titleFound && transaction.projectTitleMatchBaselineCount == 0);
        BOOL verified = transaction.persistenceVerified &&
            transaction.templatePersistenceVerified && projectEvidence;
        amproj_debugEvent(verified ? @"import.project_row_verified_after_template"
                                   : @"import.template_project_probe", @{
            @"transaction_id": transactionID ?: @"",
            @"attempt": @(attempt),
            @"row_count": @(rowCount),
            @"baseline_row_count": @(amproj_importProjectRowBaselineCount),
            @"title_found": @(titleFound),
            @"title_match_count": @(titleMatchCount),
            @"title_match_baseline": @(transaction.projectTitleMatchBaselineCount),
            @"persistence_verified": @(transaction.persistenceVerified),
            @"template_persistence_verified": @(transaction.templatePersistenceVerified),
            @"verified": @(verified)
        });
        if (verified) {
            transaction.templateProjectVerified = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionProjectVerified);
            amproj_debugEvent(@"import.project_created_from_template", @{
                @"transaction_id": transactionID ?: @"",
                @"title": title,
                @"row_count": @(rowCount)
            });
            amproj_showImportStatusForTransaction(
                @"AMProj · 项目已生成，正在清理临时模板",
                NO, transactionID);
            if (transaction.templateProbeCapability ==
                    AMProjTemplateProbeCapabilitySwiftUIUnavailable) {
                amproj_cleanupSwiftUIPromotedTemplate(
                    transactionID, generation, title, 0);
            } else {
                amproj_cleanupPromotedTemplate(
                    transactionID, generation, title, 0);
            }
            return;
        }
        if (attempt >= 60) {
            amproj_failTemplatePromotion(
                transactionID, name,
                @"已触发 AM 的模板打开流程，但底部“项目”中没有出现新项目");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_pollPromotedProject(
                transactionID, generation, name, attempt + 1);
        });
    });
}

static void amproj_beginTemplatePromotion(NSString *transactionID,
                                           NSUInteger generation,
                                           NSString *name,
                                           NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration ||
            ![amproj_importVerificationTransactionID isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || transaction.kind != AMProjImportKindPackage) return;
        if (!transaction.templatePromotionStarted) {
            transaction.templatePromotionStarted = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionTemplateDetected);
            amproj_debugEvent(@"import.template_fallback_started", @{
                @"transaction_id": transactionID ?: @"",
                @"title": amproj_transactionExpectedTitle(transaction, name)
            });
            amproj_showImportStatusForTransaction(
                @"AMProj · 已保存完整包，正在从临时模板创建项目",
                NO, transactionID);
        }
        if (transaction.templateSelectionSent) return;
        BOOL changed = amproj_selectMainTab(YES, transactionID);
        if (changed || !amproj_visibleTemplatesControllers().count) {
            if (attempt < 80) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginTemplatePromotion(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_failTemplatePromotion(
                    transactionID, name, @"等待模板页就绪超时");
            }
            return;
        }
        if (!transaction.templateBaselineListReady) {
            amproj_failTemplatePromotion(
                transactionID, name, @"模板列表基线不可用，已停止以防误选");
            return;
        }
        amproj_refreshVisibleTemplateRows();
        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        NSArray<NSDictionary *> *candidates = amproj_visibleTemplateCandidates(title);
        NSMutableArray *debugCandidates = [NSMutableArray array];
        for (NSDictionary *candidate in candidates) {
            [debugCandidates addObject:amproj_templateCandidateDebugFields(candidate)];
        }
        amproj_debugEvent(@"import.template_candidates", @{
            @"transaction_id": transactionID ?: @"",
            @"title": title,
            @"attempt": @(attempt),
            @"baseline_match_count": @(transaction.templateBaselineMatchCount),
            @"match_count": @(candidates.count),
            @"candidates": debugCandidates
        });
        NSDictionary *newCandidate = amproj_newTemplateCandidateForTransaction(
            transaction, title);
        if (!newCandidate) {
            if (attempt < 80) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginTemplatePromotion(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_failTemplatePromotion(
                    transactionID, name,
                    candidates.count ? @"同名模板无法唯一确认，已停止以防误选"
                                     : @"原生导入完成，但没有找到新增模板");
            }
            return;
        }
        if (!transaction.templatePromotionPersistenceBaseline) {
            if (!transaction.templatePromotionBaselineCaptureStarted) {
                transaction.templatePromotionBaselineCaptureStarted = YES;
                amproj_captureTemplatePromotionPersistenceBaseline(
                    transactionID, ^(BOOL captured) {
                    AMProjImportTransaction *current =
                        amproj_importTransactionForID(transactionID);
                    if (!current) return;
                    current.templatePromotionBaselineCaptureStarted = NO;
                    if (!captured) {
                        amproj_failTemplatePromotion(
                            transactionID, name,
                            @"无法记录从模板创建项目前的持久化基线");
                        return;
                    }
                    amproj_beginTemplatePromotion(
                        transactionID, generation, name, attempt);
                });
            }
            return;
        }
        transaction.templateMenuOwner =
            amproj_visibleTemplatesControllers().firstObject;
        if (!transaction.templateMenuOwner ||
            !amproj_invokeTemplateCandidate(newCandidate, transaction)) {
            amproj_failTemplatePromotion(
                transactionID, name, @"模板列表的标准选择回调不可用");
            return;
        }
        amproj_showImportStatusForTransaction(
            @"AMProj · 3/4 正在创建底部“项目”",
            NO, transactionID);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_pollPromotedProject(transactionID, generation, name, 0);
        });
    });
}

static void amproj_beginSwiftUITemplatePromotion(NSString *transactionID,
                                                  NSUInteger generation,
                                                  NSString *name,
                                                  NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration ||
            ![amproj_importVerificationTransactionID
                isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || transaction.kind != AMProjImportKindPackage ||
            transaction.templateProbeCapability !=
                AMProjTemplateProbeCapabilitySwiftUIUnavailable) return;
        if (!transaction.templatePromotionStarted) {
            transaction.templatePromotionStarted = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionTemplateDetected);
            amproj_debugEvent(@"import.template_fallback_started", @{
                @"transaction_id": transactionID ?: @"",
                @"title": amproj_transactionExpectedTitle(transaction, name),
                @"route": @"swiftui_accessibility"
            });
            amproj_showImportStatusForTransaction(
                @"AMProj · 检测到临时模板，正在创建底部“项目”",
                NO, transactionID);
        }
        if (transaction.templateSelectionSent) return;
        BOOL changed = amproj_selectMainTab(YES, transactionID);
        if (changed || !amproj_visibleTemplatesControllers().count) {
            if (attempt < 80) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginSwiftUITemplatePromotion(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_failTemplatePromotion(
                    transactionID, name, @"等待 SwiftUI 模板页就绪超时");
            }
            return;
        }
        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        NSInteger currentCount =
            amproj_visibleTemplateViewTitleCount(title);
        NSInteger baselineCount = transaction.templateBaselineViewTitleCount;
        amproj_debugEvent(@"import.template_candidates", @{
            @"transaction_id": transactionID ?: @"",
            @"title": title ?: @"",
            @"attempt": @(attempt),
            @"baseline_match_count": @(baselineCount),
            @"match_count": @(currentCount),
            @"route": @"swiftui_accessibility"
        });
        if (currentCount <= baselineCount) {
            if (attempt < 80) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginSwiftUITemplatePromotion(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_failTemplatePromotion(
                    transactionID, name,
                    @"原生导入完成，但未找到本次新增的临时模板");
            }
            return;
        }
        if (baselineCount != 0 || currentCount != 1) {
            amproj_failTemplatePromotion(
                transactionID, name,
                @"存在同名模板，无法安全确定本次新增项，已停止以防误选");
            return;
        }
        if (!transaction.templatePromotionPersistenceBaseline) {
            if (!transaction.templatePromotionBaselineCaptureStarted) {
                transaction.templatePromotionBaselineCaptureStarted = YES;
                amproj_captureTemplatePromotionPersistenceBaseline(
                    transactionID, ^(BOOL captured) {
                    AMProjImportTransaction *current =
                        amproj_importTransactionForID(transactionID);
                    if (!current) return;
                    current.templatePromotionBaselineCaptureStarted = NO;
                    if (!captured) {
                        amproj_failTemplatePromotion(
                            transactionID, name,
                            @"无法记录从模板创建项目前的持久化基线");
                        return;
                    }
                    amproj_beginSwiftUITemplatePromotion(
                        transactionID, generation, name, attempt);
                });
            }
            return;
        }
        id target = amproj_uniqueActivatableTemplateTitleObject(title);
        UIViewController *templateOwner =
            amproj_visibleTemplatesControllers().firstObject;
        if (!target || !templateOwner || !amproj_activateView(target)) {
            if (attempt < 80) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_beginSwiftUITemplatePromotion(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_failTemplatePromotion(
                    transactionID, name,
                    @"SwiftUI 模板卡片无法通过官方界面打开");
            }
            return;
        }
        transaction.templateMenuOwner = templateOwner;
        transaction.templateSelectionSent = YES;
        transaction.templateSelectedStableKey =
            [NSString stringWithFormat:@"%@|%@",
                NSStringFromClass([target class]) ?: @"",
                amproj_viewVisibleText(target) ?: @""];
        amproj_markImportTransactionState(
            transactionID, AMProjImportTransactionCreatingProject);
        amproj_debugEvent(@"import.template_selected", @{
            @"transaction_id": transactionID ?: @"",
            @"title": title ?: @"",
            @"route": @"swiftui_accessibility",
            @"target": NSStringFromClass([target class]) ?: @""
        });
        amproj_showImportStatusForTransaction(
            @"AMProj · 3/4 正在创建底部“项目”",
            NO, transactionID);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_pollPromotedProject(
                transactionID, generation, name, 0);
        });
    });
}

static id amproj_findSwiftUIAction(AMProjImportTransaction *transaction,
                                   NSArray<NSString *> *terms,
                                   BOOL confirmationOnly) {
    if (!transaction || !terms.count) return nil;
    UIViewController *owner = nil;
    if (confirmationOnly) {
        owner = amproj_boundSwiftUIConfirmationOwner(transaction);
        NSString *className = NSStringFromClass(owner.class).lowercaseString ?: @"";
        BOOL confirmationController =
            [owner isKindOfClass:UIAlertController.class] ||
            [className containsString:@"alert"] ||
            [className containsString:@"confirm"] ||
            [className containsString:@"action"];
        if (!owner || !confirmationController) return nil;
        transaction.templateConfirmationOwner = owner;
    } else {
        owner = amproj_boundSwiftUITemplateActionOwner(transaction);
        if (!owner) return nil;
        transaction.templateActionOwner = owner;
    }
    return amproj_findActivatableViewWithTerms(
        owner.viewIfLoaded, terms, [NSMutableSet set], 0);
}

static void amproj_cleanupSwiftUIPromotedTemplate(NSString *transactionID,
                                                   NSUInteger generation,
                                                   NSString *name,
                                                   NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration ||
            ![amproj_importVerificationTransactionID
                isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || !transaction.templateProjectVerified) return;
        BOOL changed = amproj_selectMainTab(YES, transactionID);
        if (changed || !amproj_visibleTemplatesControllers().count) {
            if (attempt < 100) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_cleanupSwiftUIPromotedTemplate(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_finishTemplateCleanupFailure(
                    transactionID, name, @"等待 SwiftUI 模板页返回超时");
            }
            return;
        }
        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        NSInteger baselineCount = transaction.templateBaselineViewTitleCount;
        NSInteger currentCount =
            amproj_visibleTemplateViewTitleCount(title);
        if (currentCount == baselineCount) {
            BOOL deletionWasTriggered =
                transaction.templateCleanupStarted &&
                transaction.templateDeleteActionSent;
            if (deletionWasTriggered) {
                transaction.templateCleanupAbsenceCycles += 1;
            } else {
                transaction.templateCleanupAbsenceCycles = 0;
            }
            amproj_debugEvent(@"import.template_cleanup_absence_probe", @{
                @"transaction_id": transactionID ?: @"",
                @"title": title ?: @"",
                @"route": @"swiftui_accessibility",
                @"deletion_triggered": @(deletionWasTriggered),
                @"absence_cycles":
                    @(transaction.templateCleanupAbsenceCycles)
            });
            if (transaction.templateCleanupAbsenceCycles < 6) {
                if (attempt < 100) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_cleanupSwiftUIPromotedTemplate(
                            transactionID, generation, name, attempt + 1);
                    });
                } else {
                    amproj_finishTemplateCleanupFailure(
                        transactionID, name,
                        deletionWasTriggered
                            ? @"临时模板删除结果未能稳定确认"
                            : @"SwiftUI 模板页标题尚未完成加载");
                }
                return;
            }
            transaction.templateCleanupVerified = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionCompleted);
            amproj_debugEvent(@"import.template_cleanup_verified", @{
                @"transaction_id": transactionID ?: @"",
                @"title": title ?: @"",
                @"route": @"swiftui_accessibility",
                @"remaining_match_count": @(currentCount)
            });
            amproj_unwindTemplatePresentation();
            amproj_selectMainTab(NO, transactionID);
            NSInteger projectRows = amproj_visibleProjectsRowCount();
            if (!amproj_completePackageTransaction(
                    transactionID, title, projectRows, YES)) {
                if (attempt < 100) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_cleanupSwiftUIPromotedTemplate(
                            transactionID, generation, name, attempt + 1);
                    });
                } else {
                    amproj_finishTemplateCleanupFailure(
                        transactionID, name,
                        @"项目已生成，但最终完整性门禁未通过");
                }
            }
            return;
        }
        transaction.templateCleanupAbsenceCycles = 0;
        if (baselineCount != 0 || currentCount != 1) {
            amproj_finishTemplateCleanupFailure(
                transactionID, name,
                @"临时模板身份发生歧义，已停止以防误删用户模板");
            return;
        }
        if (!transaction.templateCleanupStarted) {
            id target = amproj_uniqueActivatableTemplateTitleObject(title);
            UIViewController *templateOwner =
                amproj_visibleTemplatesControllers().firstObject;
            UIViewController *container =
                templateOwner.navigationController ?: templateOwner;
            UIViewController *baselineTop = templateOwner
                ? amproj_topViewController(container) : nil;
            UIViewController *baselinePresented = templateOwner
                ? amproj_presentedControllerFromOwnerHierarchy(templateOwner) : nil;
            if (target && templateOwner && baselineTop) {
                transaction.templateMenuOwner = templateOwner;
                transaction.templateActionOwner = nil;
                transaction.templateConfirmationOwner = nil;
                transaction.templateCardActivationBaselineTop = baselineTop;
                transaction.templateCardActivationBaselinePresented =
                    baselinePresented;
                transaction.templateDeleteActivationBaselineTop = nil;
                transaction.templateDeleteActivationBaselinePresented = nil;
            }
            if (target && templateOwner && baselineTop &&
                amproj_activateView(target)) {
                transaction.templateCleanupStarted = YES;
                amproj_markImportTransactionState(
                    transactionID, AMProjImportTransactionCleaningTemplate);
                amproj_debugEvent(@"import.template_cleanup_started", @{
                    @"transaction_id": transactionID ?: @"",
                    @"title": title ?: @"",
                    @"route": @"swiftui_accessibility"
                });
            } else {
                transaction.templateMenuOwner = nil;
                transaction.templateActionOwner = nil;
                transaction.templateConfirmationOwner = nil;
                transaction.templateCardActivationBaselineTop = nil;
                transaction.templateCardActivationBaselinePresented = nil;
            }
        } else if (!transaction.templateDeleteActionSent) {
            id deleteAction = amproj_findSwiftUIAction(
                transaction,
                @[@"删除模板", @"delete template", @"删除", @"delete"],
                NO);
            UIViewController *deleteOwner = transaction.templateActionOwner;
            UIViewController *deleteBaselineTop = deleteOwner
                ? amproj_topViewController(deleteOwner) : nil;
            UIViewController *deleteBaselinePresented = deleteOwner
                ? amproj_presentedControllerFromOwnerHierarchy(deleteOwner) : nil;
            if (deleteAction && deleteOwner && deleteBaselineTop) {
                transaction.templateDeleteActivationBaselineTop =
                    deleteBaselineTop;
                transaction.templateDeleteActivationBaselinePresented =
                    deleteBaselinePresented;
            }
            if (deleteAction && deleteOwner && deleteBaselineTop &&
                amproj_activateView(deleteAction)) {
                transaction.templateDeleteActionSent = YES;
                transaction.templateDeleteActionCount = 1;
                amproj_debugEvent(@"import.template_delete_action", @{
                    @"transaction_id": transactionID ?: @"",
                    @"route": @"swiftui_accessibility",
                    @"target": NSStringFromClass([deleteAction class]) ?: @""
                });
            } else {
                transaction.templateDeleteActivationBaselineTop = nil;
                transaction.templateDeleteActivationBaselinePresented = nil;
            }
            if (!transaction.templateDeleteActionSent &&
                !transaction.templateOverflowActionSent) {
                id moreAction = amproj_findSwiftUIAction(
                    transaction,
                    @[@"更多", @"菜单", @"more", @"options", @"overflow"],
                    NO);
                if (moreAction && amproj_activateView(moreAction)) {
                    transaction.templateOverflowActionSent = YES;
                }
            }
        } else if (!transaction.templateDeleteConfirmationSent) {
            id confirmation = amproj_findSwiftUIAction(
                transaction,
                @[@"确认删除", @"delete", @"删除", @"confirm"],
                YES);
            if (confirmation && amproj_activateView(confirmation)) {
                transaction.templateDeleteConfirmationSent = YES;
                transaction.templateDeleteActionCount = 2;
                amproj_debugEvent(@"import.template_delete_confirm", @{
                    @"transaction_id": transactionID ?: @"",
                    @"route": @"swiftui_accessibility",
                    @"target": NSStringFromClass([confirmation class]) ?: @""
                });
            }
        }
        if (attempt >= 100) {
            amproj_finishTemplateCleanupFailure(
                transactionID, name,
                @"AM 没有确认删除 SwiftUI 临时模板");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_cleanupSwiftUIPromotedTemplate(
                transactionID, generation, name, attempt + 1);
        });
    });
}

static void amproj_cleanupPromotedTemplate(NSString *transactionID,
                                            NSUInteger generation,
                                            NSString *name,
                                            NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration ||
            ![amproj_importVerificationTransactionID isEqualToString:transactionID]) return;
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || !transaction.templateProjectVerified) return;
        amproj_unwindTemplatePresentation();
        BOOL changed = amproj_selectMainTab(YES, transactionID);
        if (changed || !amproj_visibleTemplatesControllers().count) {
            if (attempt < 60) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_cleanupPromotedTemplate(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_finishTemplateCleanupFailure(
                    transactionID, name, @"等待模板页返回超时");
            }
            return;
        }
        amproj_refreshVisibleTemplateRows();
        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        NSArray<NSDictionary *> *candidates = amproj_visibleTemplateCandidates(title);
        NSInteger baseline = transaction.templateBaselineMatchCount;
        NSInteger rowCount = amproj_visibleTemplateRowCount();
        BOOL listReady = transaction.templateBaselineListReady &&
            amproj_visibleTemplateLists().count > 0 && rowCount >= 0;
        NSMutableArray<NSDictionary *> *selectedMatches = [NSMutableArray array];
        for (NSDictionary *candidate in candidates) {
            if ([candidate[@"stable_key"] isEqualToString:
                    transaction.templateSelectedStableKey]) {
                [selectedMatches addObject:candidate];
            }
        }
        if (selectedMatches.count > 1) {
            amproj_finishTemplateCleanupFailure(
                transactionID, name,
                @"临时模板身份不再唯一，已停止清理以保护原有同名模板");
            return;
        }
        BOOL selectedStillPresent = selectedMatches.count == 1;
        BOOL targetGone = transaction.templateSelectedStableKey.length &&
            !selectedStillPresent;
        BOOL rowCountRestored = transaction.templateBaselineRowCount >= 0 &&
            rowCount == transaction.templateBaselineRowCount;
        if (listReady && baseline >= 0 && targetGone && rowCountRestored) {
            transaction.templateCleanupVerified = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionCleaningTemplate);
            amproj_debugEvent(@"import.template_cleanup_verified", @{
                @"transaction_id": transactionID ?: @"",
                @"title": title,
                @"remaining_match_count": @(candidates.count),
                @"baseline_match_count": @(baseline),
                @"row_count": @(rowCount),
                @"baseline_row_count": @(transaction.templateBaselineRowCount),
                @"target_gone": @(targetGone)
            });
            amproj_unwindTemplatePresentation();
            amproj_selectMainTab(NO, transactionID);
            NSInteger projectRowCount = amproj_visibleProjectsRowCount();
            if (!amproj_projectRowVerifiedForName(title) &&
                !(amproj_importProjectRowBaselineCount >= 0 &&
                  projectRowCount > amproj_importProjectRowBaselineCount)) {
                if (attempt < 80) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_cleanupPromotedTemplate(
                            transactionID, generation, name, attempt + 1);
                    });
                    return;
                }
                amproj_finishTemplateCleanupFailure(
                    transactionID, name, @"临时模板已清理，但无法再次确认项目条目");
                return;
            }
            if (!amproj_completePackageTransaction(
                    transactionID, title, projectRowCount, YES)) {
                if (attempt < 80) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_cleanupPromotedTemplate(
                            transactionID, generation, name, attempt + 1);
                    });
                } else {
                    amproj_finishTemplateCleanupFailure(
                        transactionID, name,
                        @"项目已生成，但最终完整性门禁未通过");
                }
            }
            return;
        }
        NSDictionary *target = selectedMatches.firstObject;
        if (!target) {
            if (attempt < 40) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_cleanupPromotedTemplate(
                        transactionID, generation, name, attempt + 1);
                });
            } else {
                amproj_finishTemplateCleanupFailure(
                    transactionID, name,
                    @"无法唯一定位本次新增模板，已停止以防误删旧模板");
            }
            return;
        }
        if (!transaction.templateCleanupStarted) {
            UIView *targetCell = target[@"cell"];
            UIView *targetList = target[@"list"];
            NSIndexPath *targetPath = target[@"index_path"];
            @try {
                if ([targetList isKindOfClass:UICollectionView.class]) {
                    [(UICollectionView *)targetList scrollToItemAtIndexPath:targetPath
                        atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                animated:NO];
                } else if ([targetList isKindOfClass:UITableView.class]) {
                    [(UITableView *)targetList scrollToRowAtIndexPath:targetPath
                        atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                }
                UIView *visibleCell = amproj_templateCellAtIndexPath(targetList, targetPath);
                if (visibleCell) targetCell = visibleCell;
            } @catch (__unused NSException *exception) {
            }
            transaction.templateTargetCell = targetCell;
            UIViewController *menuOwner = nil;
            for (UIViewController *controller in amproj_visibleTemplatesControllers()) {
                if (controller.viewIfLoaded.window) {
                    menuOwner = controller;
                    break;
                }
            }
            transaction.templateMenuOwner = menuOwner;
            UIControl *overflow = amproj_findTemplateOverflowControl(targetCell);
            if (!overflow || !amproj_activateControl(overflow)) {
                if (attempt < 40) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_cleanupPromotedTemplate(
                            transactionID, generation, name, attempt + 1);
                    });
                } else {
                    amproj_finishTemplateCleanupFailure(
                        transactionID, name, @"模板卡片的更多菜单不可用");
                }
                return;
            }
            transaction.templateCleanupStarted = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionCleaningTemplate);
            amproj_debugEvent(@"import.template_cleanup_started", @{
                @"transaction_id": transactionID ?: @"",
                @"title": title,
                @"candidate": amproj_templateCandidateDebugFields(target),
                @"menu_owner": NSStringFromClass(menuOwner.class) ?: @""
            });
        } else if (!transaction.templateDeleteActionSent) {
            UIControl *deleteControl = amproj_findDeleteControlInController(
                transaction.templateMenuOwner);
            if (deleteControl && amproj_activateControl(deleteControl)) {
                transaction.templateDeleteActionSent = YES;
                transaction.templateDeleteActionCount = 1;
                amproj_debugEvent(@"import.template_delete_action", @{
                    @"transaction_id": transactionID ?: @"",
                    @"count": @(transaction.templateDeleteActionCount),
                    @"control": NSStringFromClass(deleteControl.class) ?: @"",
                    @"text": amproj_controlVisibleText(deleteControl) ?: @""
                });
            }
        } else if (!transaction.templateDeleteConfirmationSent) {
            UIViewController *top = amproj_topViewController(transaction.templateMenuOwner);
            NSString *topClass = NSStringFromClass(top.class).lowercaseString ?: @"";
            if ([topClass containsString:@"alert"] || [topClass containsString:@"action"] ||
                [topClass containsString:@"confirm"]) {
                UIControl *confirm = amproj_findDeleteControlInController(
                    transaction.templateMenuOwner);
                if (confirm && amproj_activateControl(confirm)) {
                    transaction.templateDeleteConfirmationSent = YES;
                    transaction.templateDeleteActionCount = 2;
                    amproj_debugEvent(@"import.template_delete_confirm", @{
                        @"transaction_id": transactionID ?: @"",
                        @"control": NSStringFromClass(confirm.class) ?: @"",
                        @"text": amproj_controlVisibleText(confirm) ?: @""
                    });
                }
            }
        }
        if (attempt >= 80) {
            amproj_finishTemplateCleanupFailure(
                transactionID, name, @"AM 没有确认删除临时模板");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_cleanupPromotedTemplate(
                transactionID, generation, name, attempt + 1);
        });
    });
}
#endif

static BOOL amproj_completeNativeXMLTemplateImport(
    NSString *transactionID, NSString *name, NSString *evidence,
    BOOL persistenceConfirmed) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    BOOL nativeWarningConfirmed =
        transaction.xmlImportedAnywayWarningObserved;
    if (!transaction || transaction.kind != AMProjImportKindXMLTemplate ||
        !transaction.packageIntegrityVerified ||
        !transaction.nativeTerminalStatus4Returned ||
        !transaction.nativeCompletionSucceeded ||
        !transaction.nativeTemporaryConsumed ||
        (!persistenceConfirmed && !nativeWarningConfirmed)) {
        return NO;
    }

    NSURL *incomingURL = transaction.incomingURL;
    NSURL *incomingCleanupURL = transaction.incomingCleanupURL;
    NSURL *stagedDirectoryURL = transaction.stagedDirectoryURL;
    BOOL deleteIncoming = transaction.deleteIncomingSourceOnCompletion;
    NSString *fingerprint = [transaction.fingerprint copy];
    NSString *source = [transaction.source copy];
    NSString *title = amproj_transactionExpectedTitle(transaction, name);

    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = nil;
    amproj_retryImportName = nil;
    amproj_markImportTransactionState(
        transactionID, AMProjImportTransactionCompleted);
    if (deleteIncoming && incomingURL) {
        [NSFileManager.defaultManager removeItemAtURL:incomingURL error:nil];
    }
    if (incomingCleanupURL) {
        [NSFileManager.defaultManager removeItemAtURL:incomingCleanupURL error:nil];
    }
    if (stagedDirectoryURL) {
        [NSFileManager.defaultManager removeItemAtURL:stagedDirectoryURL error:nil];
    }
    amproj_writeImportBreadcrumb(transactionID, fingerprint, @"completed",
                                 source, nil, @4, nil);
    amproj_debugEvent(@"import.xml_template_verified", @{
        @"transaction_id": transactionID ?: @"",
        @"title": title ?: @"",
        @"route": @"xml_minimal_package_offline",
        @"evidence": evidence ?: @"native_terminal_persistence",
        @"package_integrity_verified": @YES,
        @"native_status_4_returned": @YES,
        @"native_completion_succeeded": @YES,
        @"native_temporary_consumed": @YES,
        @"persistence_verified": @(persistenceConfirmed),
        @"native_imported_anyway_warning": @(nativeWarningConfirmed),
        @"persistence_delta_used": @YES,
        @"ui_template_verified": @NO,
        @"host": @"projects"
    });
    amproj_releaseImportTransaction(transactionID, YES);
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = nil;
    amproj_selectMainTab(NO, transactionID);
    amproj_showImportStatusForTransaction(
        @"AMProj · 3/3 XML 已离线导入“您的模板”",
        NO, transactionID);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_resumeQueuedImports(@"xml_native_template_verified");
    });
    return YES;
}

static void amproj_failNativeXMLTemplateImport(
    NSString *transactionID, NSString *name, NSString *reason) {
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (!transaction) {
        amproj_importVerificationActive = NO;
        amproj_importVerificationName = nil;
        amproj_importVerificationTransactionID = nil;
        amproj_importProjectRowBaselineCount = -1;
        amproj_importVisibleStageRank = 0;
        amproj_visibleStatusTransactionID = nil;
        amproj_debugEvent(@"import.xml_template_verification_stale", @{
            @"transaction_id": transactionID ?: @"",
            @"title": name ?: @"",
            @"error": reason ?: @"XML import transaction is unavailable"
        });
        amproj_resumeQueuedImports(@"xml_native_template_stale");
        return;
    }
    NSString *message = reason.length ? reason :
        @"本地 PackageImporter 已返回，但没有确认 XML 模板已落库";
    NSString *fingerprint = [transaction.fingerprint copy];
    NSString *source = [transaction.source copy];
    NSURL *retryURL = transaction.archiveURL;
    NSString *retryName = [transaction.name copy] ?: [name copy];

    amproj_importVerificationActive = NO;
    amproj_importVerificationName = nil;
    amproj_importVerificationTransactionID = nil;
    amproj_importProjectRowBaselineCount = -1;
    amproj_retryImportURL = retryURL;
    amproj_retryImportName = retryName;
    amproj_writeImportBreadcrumb(transactionID, fingerprint, @"failed",
                                 source, nil, @4, message);
    amproj_debugEvent(@"import.xml_template_verification_failed", @{
        @"transaction_id": transactionID ?: @"",
        @"title": name ?: @"",
        @"error": message,
        @"package_integrity_verified":
            @(transaction.packageIntegrityVerified),
        @"native_status_4_returned":
            @(transaction.nativeTerminalStatus4Returned),
        @"native_completion_succeeded":
            @(transaction.nativeCompletionSucceeded),
        @"persistence_delta_used": @NO
    });
    amproj_releaseImportTransaction(transactionID, NO);
    amproj_importVisibleStageRank = 0;
    amproj_visibleStatusTransactionID = nil;
    NSString *visible = [NSString stringWithFormat:
        @"AMProj · XML 本地导入未完成：%@", message];
    amproj_showImportStatusForTransaction(visible, YES, transactionID);
    amproj_presentXMLImportError(visible, YES);
    amproj_resumeQueuedImports(@"xml_native_template_failed");
}

static void amproj_verifyNativeXMLTemplateImport(
    NSUInteger generation, NSString *name, NSString *transactionID,
    NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration ||
            ![amproj_importVerificationTransactionID
                isEqualToString:transactionID]) {
            return;
        }
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction) {
            amproj_failNativeXMLTemplateImport(
                transactionID, name, @"XML 本地导入事务已经被释放");
            return;
        }
        if (transaction.kind != AMProjImportKindXMLTemplate ||
            transaction.state != AMProjImportTransactionNativeActive) {
            amproj_failNativeXMLTemplateImport(
                transactionID, name, @"XML 本地导入事务已经失效");
            return;
        }

        BOOL changedToProjects = amproj_selectMainTab(NO, transactionID);
        BOOL projectsVisible = amproj_visibleProjectsControllers().count > 0;
        NSString *title = amproj_transactionExpectedTitle(transaction, name);
        BOOL nativeTerminalReady =
            transaction.packageIntegrityVerified &&
            transaction.nativeTerminalStatus4Returned &&
            transaction.nativeCompletionSucceeded;
        BOOL persistenceReady = transaction.persistenceVerified;
        BOOL temporaryConsumed = transaction.nativeTemporaryConsumed;
        BOOL importedAnywayConfirmed =
            transaction.xmlImportedAnywayWarningObserved;
        BOOL importConfirmed = temporaryConsumed &&
            (persistenceReady || importedAnywayConfirmed);
        amproj_debugEvent(importConfirmed && nativeTerminalReady
            ? @"import.xml_local_template_ready"
            : @"import.xml_local_template_probe", @{
            @"transaction_id": transactionID ?: @"",
            @"title": title ?: @"",
            @"attempt": @(attempt),
            @"projects_visible": @(projectsVisible),
            @"tab_changed": @(changedToProjects),
            @"package_integrity_verified":
                @(transaction.packageIntegrityVerified),
            @"native_status_4_returned":
                @(transaction.nativeTerminalStatus4Returned),
            @"native_completion_succeeded":
                @(transaction.nativeCompletionSucceeded),
            @"native_temporary_consumed": @(temporaryConsumed),
            @"persistence_verified": @(persistenceReady),
            @"native_imported_anyway_warning": @(importedAnywayConfirmed),
            @"persistence_delta_used": @YES,
            @"host": @"projects"
        });
        if (importConfirmed && nativeTerminalReady) {
            NSString *evidence = persistenceReady
                ? @"native_terminal_persistence"
                : @"native_imported_anyway_warning";
            if (amproj_completeNativeXMLTemplateImport(
                    transactionID, name, evidence, persistenceReady)) return;
        }
        if (attempt == 0 || attempt == 2 || attempt == 6 || attempt == 14) {
            amproj_scheduleImportPersistenceProbe(
                transactionID, @"xml_native_completion", nil);
        }
        if (attempt >= 30) {
            NSString *reason = nil;
            if (!transaction.nativeTerminalStatus4Returned) {
                reason = @"本地导入没有返回 storage status 4";
            } else if (!transaction.nativeCompletionSucceeded) {
                reason = @"本地 PackageImporter 没有返回成功 completion";
            } else if (!transaction.nativeTemporaryConsumed) {
                reason = @"本地 PackageImporter 没有消费临时项目包";
            } else {
                reason = @"本地导入已完成，但项目持久化目录没有确认变化";
            }
            amproj_failNativeXMLTemplateImport(transactionID, name, reason);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_verifyNativeXMLTemplateImport(
                generation, name, transactionID, attempt + 1);
        });
    });
}

static void amproj_verifyImportedProjectRow(NSUInteger generation,
                                            NSString *name,
                                            NSString *transactionID,
                                            NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_importVerificationActive ||
            generation != amproj_importVerificationGeneration) return;
        amproj_refreshVisibleProjectsRows();
        NSInteger rowCount = amproj_visibleProjectsRowCount();
        AMProjImportTransaction *probeTransaction =
            amproj_importTransactionForID(transactionID);
        if (!probeTransaction ||
            probeTransaction.state != AMProjImportTransactionNativeActive) {
            amproj_importVerificationActive = NO;
            amproj_importVerificationName = nil;
            amproj_importVerificationTransactionID = nil;
            amproj_importProjectRowBaselineCount = -1;
            amproj_debugEvent(@"import.project_row_probe_stale", @{
                @"transaction_id": transactionID ?: @"",
                @"transaction_present": @(probeTransaction != nil)
            });
            amproj_resumeQueuedImports(@"project_probe_stale");
            return;
        }
        BOOL rowAdded = amproj_importProjectRowBaselineCount >= 0 &&
            rowCount > amproj_importProjectRowBaselineCount;
        BOOL titleFound = amproj_projectRowVerifiedForName(name);
        NSString *expectedTitle = amproj_transactionExpectedTitle(probeTransaction, name);
        NSInteger titleMatchCount = amproj_projectTitleMatchCount(expectedTitle);
        BOOL titleAdded = titleMatchCount >= 0 &&
            probeTransaction.projectTitleMatchBaselineCount >= 0 &&
            titleMatchCount > probeTransaction.projectTitleMatchBaselineCount;
        BOOL verified = probeTransaction.persistenceVerified &&
            (titleAdded || (rowAdded && titleFound &&
                            probeTransaction.projectTitleMatchBaselineCount == 0));
        amproj_debugEvent(verified ? @"import.project_row_verified"
                                   : @"import.project_row_probe", @{
            @"transaction_id": transactionID ?: @"",
            @"filename": name ?: @"project.amproj",
            @"attempt": @(attempt),
            @"row_count": @(rowCount),
            @"baseline_row_count": @(amproj_importProjectRowBaselineCount),
            @"title_found": @(titleFound),
            @"title_match_count": @(titleMatchCount),
            @"title_match_baseline": @(probeTransaction.projectTitleMatchBaselineCount),
            @"title_present_at_baseline":
                @(probeTransaction.projectTitlePresentAtBaseline),
            @"persistence_verified": @(probeTransaction.persistenceVerified),
            @"verified": @(verified)
        });
        if (verified) {
            probeTransaction.directProjectVerified = YES;
            probeTransaction.directProjectRowCount = rowCount;
            if (amproj_completePackageTransaction(
                    transactionID, name, rowCount, NO)) return;
        }
        if (probeTransaction.kind == AMProjImportKindPackage &&
            !probeTransaction.directProjectVerified && attempt >= 3 &&
            amproj_completePackageWithUnresolvedDestination(
                transactionID, name,
                @"native_terminal_persistence_after_ui_grace")) {
            return;
        }
        if (probeTransaction.kind == AMProjImportKindPackage) {
            if (attempt == 0 || attempt == 2 || attempt == 6 || attempt == 14) {
                amproj_scheduleImportPersistenceProbe(
                    transactionID, @"project_verification", nil);
            }
            if (!amproj_visibleProjectsControllers().count) {
                amproj_selectMainTab(NO, transactionID);
            }
            if (attempt < 30) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_verifyImportedProjectRow(
                        generation, name, transactionID, attempt + 1);
                });
                return;
            }
            if (amproj_completePackageWithUnresolvedDestination(
                    transactionID, name,
                    @"native_terminal_persistence_at_project_timeout")) {
                return;
            }
            amproj_failImportedProjectVerification(
                transactionID, name, attempt,
                @"原生导入已完成，但没有确认项目落库或持久化变化");
            return;
        }
        if (probeTransaction.kind == AMProjImportKindPackage &&
            probeTransaction.persistenceVerified &&
            probeTransaction.templateProbeCapability ==
                AMProjTemplateProbeCapabilitySwiftUIUnavailable) {
            BOOL templatesVisible =
                amproj_visibleTemplatesControllers().count > 0;
            if (!templatesVisible) {
                BOOL changedToTemplates =
                    amproj_selectMainTab(YES, transactionID);
                if (changedToTemplates ||
                    !amproj_visibleTemplatesControllers().count) {
                    if (attempt >= 30) {
                        amproj_failImportedProjectVerification(
                            transactionID, name, attempt,
                            @"SwiftUI 模板页持续不可见，无法确认临时模板状态");
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_verifyImportedProjectRow(
                            generation, name, transactionID, attempt + 1);
                    });
                    return;
                }
            }
            NSInteger templateTitleCount =
                amproj_visibleTemplateViewTitleCount(expectedTitle);
            NSInteger templateTitleBaseline =
                probeTransaction.templateBaselineViewTitleCount;
            if (templateTitleCount > templateTitleBaseline) {
                probeTransaction.templateAbsenceVerified = NO;
                probeTransaction.templateAbsenceStable = NO;
                probeTransaction.templateAbsenceExactCycles = 0;
                probeTransaction.templateAddedStableCycles += 1;
                amproj_debugEvent(@"import.swiftui_temporary_template_detected", @{
                    @"transaction_id": transactionID ?: @"",
                    @"title": expectedTitle ?: @"",
                    @"baseline_match_count": @(templateTitleBaseline),
                    @"match_count": @(templateTitleCount),
                    @"stable_cycles":
                        @(probeTransaction.templateAddedStableCycles)
                });
                if (probeTransaction.templateAddedStableCycles < 3) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_verifyImportedProjectRow(
                            generation, name, transactionID, attempt + 1);
                    });
                    return;
                }
                if (!amproj_completePackageAsTemplate(
                        transactionID, name, @"swiftui_title_delta")) {
                    amproj_failImportedProjectVerification(
                        transactionID, name, attempt,
                        @"检测到新增模板，但无法确认完整项目包已经持久化");
                }
                return;
            }
            probeTransaction.templateAddedStableCycles = 0;
            BOOL exactAbsence =
                templateTitleCount == templateTitleBaseline;
            BOOL projectVerifiedForTransaction =
                verified || probeTransaction.directProjectVerified;
            if (exactAbsence && projectVerifiedForTransaction) {
                probeTransaction.templateAbsenceExactCycles += 1;
            } else {
                probeTransaction.templateAbsenceExactCycles = 0;
                probeTransaction.templateAbsenceStable = NO;
                probeTransaction.templateAbsenceVerified = NO;
            }
            amproj_debugEvent(@"import.template_absence_probe", @{
                @"transaction_id": transactionID ?: @"",
                @"title": expectedTitle ?: @"",
                @"attempt": @(attempt),
                @"exact": @(exactAbsence),
                @"project_verified": @(projectVerifiedForTransaction),
                @"exact_cycles":
                    @(probeTransaction.templateAbsenceExactCycles),
                @"route": @"swiftui_accessibility"
            });
            if (projectVerifiedForTransaction && attempt >= 8 &&
                probeTransaction.templateAbsenceExactCycles >= 6) {
                probeTransaction.templateAbsenceStable = YES;
                probeTransaction.templateAbsenceVerified = YES;
                if (amproj_completePackageTransaction(
                        transactionID, name,
                        probeTransaction.directProjectRowCount, NO)) return;
            }
        }
        if (probeTransaction.kind == AMProjImportKindPackage &&
            probeTransaction.persistenceVerified && attempt >= 2 &&
            probeTransaction.templateProbeCapability ==
                AMProjTemplateProbeCapabilityUIKitReady &&
            probeTransaction.templateBaselineListReady) {
            if (probeTransaction.templateAbsenceStable &&
                !probeTransaction.templateAbsenceFinalCheckPending) {
                if (!amproj_visibleProjectsControllers().count) {
                    if (attempt >= 30) {
                        amproj_failImportedProjectVerification(
                            transactionID, name, attempt,
                            @"项目页持续不可见，无法完成项目行复核");
                        return;
                    }
                    amproj_selectMainTab(NO, transactionID);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_verifyImportedProjectRow(
                            generation, name, transactionID, attempt + 1);
                    });
                    return;
                }
                if (verified) {
                    probeTransaction.templateAbsenceFinalCheckPending = YES;
                    amproj_selectMainTab(YES, transactionID);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        amproj_verifyImportedProjectRow(
                            generation, name, transactionID, attempt + 1);
                    });
                    return;
                }
            } else {
                BOOL templatesVisible =
                    amproj_visibleTemplatesControllers().count > 0;
                if (!templatesVisible) {
                    BOOL changedToTemplates =
                        amproj_selectMainTab(YES, transactionID);
                    if (changedToTemplates ||
                        !amproj_visibleTemplatesControllers().count) {
                        if (attempt >= 30) {
                            amproj_failImportedProjectVerification(
                                transactionID, name, attempt,
                                @"模板页持续不可见，无法确认是否产生临时模板");
                            return;
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     300 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            amproj_verifyImportedProjectRow(
                                generation, name, transactionID, attempt + 1);
                        });
                        return;
                    }
                }
                NSDictionary *newTemplate =
                    amproj_newTemplateCandidateForTransaction(
                        probeTransaction, expectedTitle);
                if (newTemplate) {
                    probeTransaction.templateAbsenceExactCycles = 0;
                    probeTransaction.templateAbsenceStable = NO;
                    probeTransaction.templateAbsenceFinalCheckPending = NO;
                    probeTransaction.templateAbsenceVerified = NO;
                    if (!amproj_completePackageAsTemplate(
                            transactionID, name, @"uikit_template_identity_delta")) {
                        amproj_failImportedProjectVerification(
                            transactionID, name, attempt,
                            @"检测到新增模板，但无法确认完整项目包已经持久化");
                    }
                    return;
                }
                BOOL templateBaselineExact =
                    amproj_templateBaselineStillExact(
                        probeTransaction, expectedTitle);
                if (probeTransaction.templateAbsenceFinalCheckPending) {
                    if (templateBaselineExact &&
                        probeTransaction.templateAbsenceStable &&
                        probeTransaction.templateAbsenceExactCycles >= 6 &&
                        probeTransaction.directProjectVerified) {
                        probeTransaction.templateAbsenceVerified = YES;
                        amproj_debugEvent(
                            @"import.direct_project_without_template", @{
                            @"transaction_id": transactionID ?: @"",
                            @"title": expectedTitle ?: @"",
                            @"attempt": @(attempt),
                            @"exact_cycles":
                                @(probeTransaction.templateAbsenceExactCycles),
                            @"template_baseline_exact": @YES,
                            @"final_check": @YES
                        });
                        if (amproj_completePackageTransaction(
                                transactionID, name,
                                probeTransaction.directProjectRowCount,
                                NO)) return;
                    }
                    probeTransaction.templateAbsenceFinalCheckPending = NO;
                    probeTransaction.templateAbsenceStable = NO;
                    probeTransaction.templateAbsenceVerified = NO;
                    probeTransaction.templateAbsenceExactCycles = 0;
                } else {
                    if (templateBaselineExact) {
                        probeTransaction.templateAbsenceExactCycles += 1;
                    } else {
                        probeTransaction.templateAbsenceExactCycles = 0;
                        probeTransaction.templateAbsenceStable = NO;
                        probeTransaction.templateAbsenceVerified = NO;
                    }
                    amproj_debugEvent(@"import.template_absence_probe", @{
                        @"transaction_id": transactionID ?: @"",
                        @"title": expectedTitle ?: @"",
                        @"attempt": @(attempt),
                        @"exact": @(templateBaselineExact),
                        @"exact_cycles":
                            @(probeTransaction.templateAbsenceExactCycles)
                    });
                    if (probeTransaction.directProjectVerified &&
                        attempt >= 12 &&
                        probeTransaction.templateAbsenceExactCycles >= 6) {
                        probeTransaction.templateAbsenceStable = YES;
                        amproj_selectMainTab(NO, transactionID);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     300 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            amproj_verifyImportedProjectRow(
                                generation, name, transactionID, attempt + 1);
                        });
                        return;
                    }
                }
            }
        } else if (verified && probeTransaction.kind != AMProjImportKindPackage) {
            if (amproj_completePackageTransaction(
                    transactionID, name, rowCount, NO)) return;
        }
        BOOL mayReselectProjects = probeTransaction.kind != AMProjImportKindPackage ||
            probeTransaction.templateAbsenceVerified;
        if (probeTransaction.persistenceVerified && mayReselectProjects &&
            attempt >= 2 && !probeTransaction.projectTabReselected) {
            amproj_reselectProjectsTabOnce(transactionID);
        }
        if (attempt == 8 || attempt == 20) {
            amproj_scheduleImportPersistenceProbe(
                transactionID,
                attempt == 8 ? @"verification_retry_8" : @"verification_retry_20",
                nil);
        }
        if (attempt < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_verifyImportedProjectRow(generation, name, transactionID,
                                                attempt + 1);
            });
            return;
        }
        if (probeTransaction.kind == AMProjImportKindPackage &&
            amproj_completePackageWithUnresolvedDestination(
                transactionID, name,
                @"native_terminal_persistence_at_probe_timeout")) {
            return;
        }
        amproj_failImportedProjectVerification(
            transactionID, name, attempt,
            @"原生导入回调已完成，但底部“项目”中没有找到新项目");
    });
}

static void amproj_finishNativePackageImport(NSUInteger generation,
                                              NSString *name,
                                              BOOL success,
                                              NSError *error,
                                              NSString *transactionID) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != amproj_activeNativeImportGeneration) return;
        AMProjImportTransaction *activeTransaction =
            amproj_importTransactionForID(transactionID);
        // Tear down the local bridge state before validating the transaction.
        // A callback can arrive after an error path already released the
        // transaction; leaving the generation/observation armed would block
        // every later package indefinitely.
        NSDictionary *observation = amproj_nativeImportObservationFields();
        amproj_activeNativeImportGeneration = 0;
        amproj_activeNativeImportTransactionID = nil;
        amproj_pendingImportTransactionID = nil;
        amproj_waitingForNativeImportAlert = NO;
        amproj_nativeImportRecognitionName = nil;
        ++amproj_nativeImportRecognitionGeneration;
        amproj_endNativeImportObservation();
        amproj_importDispatchCoolingDown = NO;
        if (!activeTransaction ||
            activeTransaction.state != AMProjImportTransactionNativeActive) {
            if (activeTransaction) {
                amproj_releaseImportTransaction(transactionID, NO);
            }
            amproj_debugEvent(@"import.late_native_completion_ignored", @{
                @"transaction_id": transactionID ?: @"",
                @"generation": @(generation),
                @"success": @(success),
                @"transaction_present": @(activeTransaction != nil)
            });
            amproj_importProjectRowBaselineCount = -1;
            amproj_resumeQueuedImports(@"late_native_completion");
            return;
        }
        amproj_debugEvent(@"import.local_bridge_finished", @{
            @"success": @(success),
            @"filename": name ?: @"project.amproj",
            @"transaction_id": transactionID ?: @"",
            @"kind": activeTransaction.kind == AMProjImportKindXMLTemplate
                ? @"xml_template" : @"amproj_package",
            @"attempt_id": observation[@"attempt_id"] ?: @"",
            @"error_domain": error.domain ?: @"",
            @"error_code": @(error.code),
            @"error": error.localizedDescription ?: @""
        });
        if (success) {
            activeTransaction.nativeCompletionSucceeded = YES;
            // PackageImporter completion only means its callback fired. Keep
            // the transaction claimed while a background metadata snapshot
            // verifies that AM consumed the temp package and touched durable
            // project storage. UI verification starts only after that probe.
            NSString *verificationName = activeTransaction.projectTitle.length
                ? [activeTransaction.projectTitle copy]
                : [name copy];
            amproj_importVerificationActive = YES;
            NSUInteger verificationGeneration = ++amproj_importVerificationGeneration;
            amproj_importVerificationName = verificationName ?: @"project.amproj";
            amproj_importVerificationTransactionID = [transactionID copy];
            amproj_importVerificationAttempt = 0;
            if (activeTransaction.kind == AMProjImportKindXMLTemplate) {
                amproj_writeImportBreadcrumb(
                    transactionID, activeTransaction.fingerprint,
                    @"verifying_xml_template", activeTransaction.source,
                    nil, @4, nil);
                amproj_showImportStatusForTransaction(
                    @"AMProj · 2/3 本地导入完成，正在确认持久化结果",
                    NO, transactionID);
                amproj_verifyNativeXMLTemplateImport(
                    verificationGeneration,
                    verificationName ?: @"project.xml",
                    transactionID, 0);
                return;
            }
            amproj_writeImportBreadcrumb(transactionID,
                                         amproj_importTransactionForID(transactionID).fingerprint,
                                         @"verifying_persistence", nil, nil, @4, nil);
            amproj_showImportStatusForTransaction(
                @"AMProj · 原生回调完成，正在确认项目或完整模板已经落库",
                NO, transactionID);
            amproj_scheduleImportPersistenceProbe(
                transactionID, @"native_completion", ^(BOOL persistenceVerified) {
                AMProjImportTransaction *transaction =
                    amproj_importTransactionForID(transactionID);
                if (!transaction ||
                    transaction.state != AMProjImportTransactionNativeActive ||
                    !amproj_importVerificationActive ||
                    verificationGeneration != amproj_importVerificationGeneration ||
                    ![amproj_importVerificationTransactionID
                        isEqualToString:transactionID]) {
                    if (verificationGeneration == amproj_importVerificationGeneration &&
                        [amproj_importVerificationTransactionID
                            isEqualToString:transactionID]) {
                        amproj_importVerificationActive = NO;
                        amproj_importVerificationName = nil;
                        amproj_importVerificationTransactionID = nil;
                        amproj_importProjectRowBaselineCount = -1;
                        amproj_resumeQueuedImports(@"verification_cancelled");
                    }
                    return;
                }
                transaction.persistenceVerified |= persistenceVerified;
                amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                             @"verifying_project_row", nil, nil, @4, nil);
                amproj_verifyImportedProjectRow(verificationGeneration,
                                                verificationName ?: @"project.amproj",
                                                transactionID, 0);
            });
        } else {
            AMProjImportTransaction *failedTransaction =
                amproj_importTransactionForID(transactionID);
            AMProjImportKind failedKind = failedTransaction.kind;
            amproj_retryImportURL = failedTransaction.archiveURL;
            amproj_retryImportName = [name copy];
            amproj_releaseImportTransaction(transactionID, NO);
            amproj_writeImportBreadcrumb(transactionID,
                                         failedTransaction.fingerprint,
                                         @"failed", failedTransaction.source, nil, @5,
                                         error.localizedDescription);
            NSString *detail = error.localizedDescription.length
                ? error.localizedDescription
                : (failedKind == AMProjImportKindXMLTemplate
                    ? @"AM 本地 XML 模板导入失败"
                    : @"AM \u672c\u5730\u9879\u76ee\u5305\u5bfc\u5165\u5931\u8d25");
            NSString *visible = [NSString stringWithFormat:
                failedKind == AMProjImportKindXMLTemplate
                    ? @"AMProj · 无法本地导入 XML：%@"
                    : @"AMProj \u00b7 \u65e0\u6cd5\u5bfc\u5165\u9879\u76ee\u5305\uff1a%@",
                detail];
            amproj_showImportStatusForTransaction(visible, YES, transactionID);
            if (![error.userInfo[@"AMProjNativeAlertPresented"] boolValue]) {
                amproj_presentImportErrorForKind(visible, failedKind, NO);
            }
            amproj_importProjectRowBaselineCount = -1;
        }
        if (!success) {
            // Keep the failed Inbox source and staged cache for an explicit
            // retry, but do not scan it again immediately in a failure loop.
            amproj_resumeQueuedImports(@"native_import_failed");
        }
    });
}

#if AMPROJ_CLOUD_SYNC
static void amproj_finishImportAuthorizationDenied(NSUInteger generation,
                                                    NSString *transactionID,
                                                    NSString *name,
                                                    NSError *error) {
    if (generation != amproj_pendingImportGeneration ||
        ![transactionID isEqualToString:amproj_pendingImportTransactionID ?: @""]) {
        return;
    }
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    NSURL *retryURL = transaction.archiveURL ?: amproj_pendingImportURL;
    NSString *reason = error.localizedDescription.length
        ? error.localizedDescription : @"iOS 导入权限未开通";
    amproj_retryImportURL = retryURL;
    amproj_retryImportName = name;
    amproj_pendingImportURL = nil;
    amproj_pendingImportName = nil;
    amproj_pendingImportTransactionID = nil;
    amproj_pendingImportDeadline = 0;
    amproj_importProjectRowBaselineCount = -1;
    amproj_writeImportBreadcrumb(
        transactionID, transaction.fingerprint, @"authorization_denied",
        transaction.source, nil, nil, reason);
    amproj_releaseImportTransaction(transactionID, NO);
    amproj_debugEvent(@"import.authorization", @{
        @"allowed": @NO,
        @"transaction_id": transactionID,
        @"error": reason
    });
    amproj_showImportStatusForTransaction(
        [NSString stringWithFormat:@"AMProj · 导入未开始：%@", reason],
        YES, transactionID);
    amproj_resumeQueuedImports(@"authorization_denied");
}
#endif

#pragma mark - Build 865 direct project-store import

// Alight Motion 865 keeps every project as `<UUID>.xml` directly inside the
// app's Library directory, with media stored as
// `Library/project-dependencies/<UPPERCASE_SHA1>.<EXT>`. Scene XMLs reference
// those files through `am-internal:///<UPPERCASE_SHA1>.<EXT>` — confirmed by
// a native project the app itself wrote (r34 device log, 2026-09-04); the
// loader resolves the container path itself, so the scheme survives
// reinstall-induced container UUID changes. Verified on device (2026-08-31):
// writing a valid scene XML below Library made the running app index and list
// it on the next launch. The writer below turns an already validated package
// into such a project with no private ABI involvement.
static NSURL *amproj_v865StoreLibraryURL(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory
                                                inDomains:NSUserDomainMask].firstObject;
}

// app 会把"它不认识的项目"引用的依赖文件当孤儿清掉（r36 实测：导入时
// verified=1 全部在位，打开项目时只剩原生文件）。依赖文件一律双写：
// project-dependencies 给加载器用，amproj-deps-backup 留底；每次激活对账
// 补回被清掉的文件。
static NSURL *amproj_v865DependencyBackupURL(void) {
    return [amproj_v865StoreLibraryURL()
        URLByAppendingPathComponent:@"amproj-deps-backup" isDirectory:YES];
}

static void amproj_restoreDependencies(void) {
    static BOOL running = NO;
    if (running) return;
    running = YES;
    @try {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *library = amproj_v865StoreLibraryURL();
        NSURL *dependencies = [library
            URLByAppendingPathComponent:@"project-dependencies"
                          isDirectory:YES];
        NSURL *backup = amproj_v865DependencyBackupURL();
        NSArray<NSURL *> *xmls = [manager contentsOfDirectoryAtURL:library
            includingPropertiesForKeys:nil options:0 error:nil];
        NSMutableSet<NSString *> *needed = [NSMutableSet set];
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:
                @"am-internal:///([A-Fa-f0-9]{40}\\.[A-Za-z0-9]+)\""
                                 options:0 error:nil];
        for (NSURL *url in xmls) {
            if (![url.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
            NSString *text = [NSString stringWithContentsOfURL:url
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
            if (!text.length) continue;
            for (NSTextCheckingResult *match in [regex matchesInString:text
                options:0 range:NSMakeRange(0, text.length)]) {
                [needed addObject:[text substringWithRange:[match rangeAtIndex:1]]
                    .uppercaseString];
            }
        }
        if (!needed.count) return;
        [manager createDirectoryAtURL:dependencies
          withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createDirectoryAtURL:backup
          withIntermediateDirectories:YES attributes:nil error:nil];
        NSUInteger restored = 0, missingBackup = 0;
        NSMutableSet<NSString *> *backupNames = [NSMutableSet set];
        for (NSURL *url in [manager contentsOfDirectoryAtURL:backup
            includingPropertiesForKeys:nil options:0 error:nil]) {
            [backupNames addObject:url.lastPathComponent.uppercaseString];
        }
        for (NSString *name in needed) {
            if ([manager fileExistsAtPath:[dependencies
                    URLByAppendingPathComponent:name].path]) continue;
            NSURL *source = [backup URLByAppendingPathComponent:name];
            if (![manager fileExistsAtPath:source.path]) {
                missingBackup++;
                continue;
            }
            NSURL *temporary = [dependencies URLByAppendingPathComponent:
                [NSString stringWithFormat:@".%@.%@.restore", name,
                 NSUUID.UUID.UUIDString]];
            [manager removeItemAtURL:temporary error:nil];
            if ([manager copyItemAtURL:source toURL:temporary error:nil] &&
                [manager moveItemAtURL:temporary
                    toURL:[dependencies URLByAppendingPathComponent:name]
                    error:nil]) {
                restored++;
            } else {
                [manager removeItemAtURL:temporary error:nil];
            }
        }
        os_log(OS_LOG_DEFAULT, "[AMProjExport] dependency restore needed=%lu "
               "restored=%lu missing_backup=%lu",
               (unsigned long)needed.count, (unsigned long)restored,
               (unsigned long)missingBackup);
    } @catch (NSException *exception) {
        os_log(OS_LOG_DEFAULT, "[AMProjExport] dependency restore exception: "
               "%{public}@", exception.reason ?: @"");
    } @finally {
        running = NO;
    }
}

// NSTimer 的 target 会被强持有，用单例代理避免把大上下文挂在定时器上。
@interface AMProjRestoreTimerProxy : NSObject
+ (instancetype)sharedProxy;
- (void)restore;
@end

@implementation AMProjRestoreTimerProxy
+ (instancetype)sharedProxy {
    static AMProjRestoreTimerProxy *proxy = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ proxy = [AMProjRestoreTimerProxy new]; });
    return proxy;
}
- (void)restore {
    amproj_restoreDependencies();
}
@end

static NSString *amproj_v865StoreSHA1ForFile(NSURL *fileURL) {
    int fd = open(fileURL.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    uint8_t buffer[65536];
    BOOL ok = YES;
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = NO; break; }
        if (count == 0) break;
        CC_SHA1_Update(&context, buffer, (CC_LONG)count);
    }
    close(fd);
    if (!ok) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    static const char digits[] = "0123456789ABCDEF";
    char output[CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) {
        output[index * 2] = digits[digest[index] >> 4];
        output[index * 2 + 1] = digits[digest[index] & 0x0f];
    }
    return [[NSString alloc] initWithBytes:output length:sizeof(output)
                                  encoding:NSASCIIStringEncoding];
}

// 旧版包的根级 manifest.txt 每行一条 "SHA1:文件名"，是引用键到实际资源
// 文件名的权威映射——引用键不带扩展名时必须靠它定位文件。
static NSDictionary<NSString *, NSString *> *AMProjLegacyManifestResourceMap(
    NSURL *extractionDirectory) {
    if (!extractionDirectory) return @{};
    NSData *data = [NSData dataWithContentsOfURL:
        [extractionDirectory URLByAppendingPathComponent:@"manifest.txt"]];
    if (!data.length) return @{};
    NSString *text = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data
                                 encoding:NSUTF16LittleEndianStringEncoding];
    if (!text.length) return @{};
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]]) {
        NSRange split = [line rangeOfString:@":"];
        if (split.location == NSNotFound || split.location == 0) continue;
        NSString *key = [line substringToIndex:split.location];
        NSString *name = [line substringFromIndex:NSMaxRange(split)];
        NSCharacterSet *trim = [NSCharacterSet whitespaceCharacterSet];
        key = [key stringByTrimmingCharactersInSet:trim];
        name = [name stringByTrimmingCharactersInSet:trim];
        if (key.length && name.length && !map[key]) map[key] = name;
    }
    return map;
}

// Rewrites one scene document into the on-device project store format and
// copies every packaged resource into project-dependencies under its SHA-1.
// Returns the store XML bytes; referenced dependency names are appended to
// `dependenciesOut` as dictionaries {name, sha1, size}.
static NSData *amproj_v865StoreRewriteSceneXML(
    NSURL *nativeXMLURL, NSURL *extractionDirectory, BOOL asTemplate,
    NSMutableArray<NSDictionary<NSString *, id> *> *dependenciesOut,
    NSMutableArray<NSString *> *fontsOut, NSString **titleOut,
    NSError **error) {
    NSError *readError = nil;
    NSMutableString *xml = [NSMutableString stringWithContentsOfURL:nativeXMLURL
                                                           encoding:NSUTF8StringEncoding
                                                              error:&readError];
    if (!xml) {
        if (error) *error = [NSError errorWithDomain:@"com.amproj.865.store"
                                                code:1
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"无法读取解包后的场景 XML",
                                                NSUnderlyingErrorKey: readError ?: [NSError new]}];
        return nil;
    }

    NSRegularExpression *uriRegex = [NSRegularExpression
        regularExpressionWithPattern:@"uri=\\\"([^\\\"]*)\\\""
                             options:0 error:nil];
    NSMutableArray<NSTextCheckingResult *> *uriMatches = [[uriRegex
        matchesInString:xml options:0 range:NSMakeRange(0, xml.length)] mutableCopy];
    NSMutableDictionary<NSString *, NSString *> *storeNamesByResource = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, NSString *> *manifestResources =
        AMProjLegacyManifestResourceMap(extractionDirectory);
    NSUInteger amprojRefCount = 0, amprojManifestHits = 0, amprojBaseHits = 0,
        amprojExactHits = 0, amprojMisses = 0;
    NSString *amprojFirstMiss = nil;
    for (NSUInteger index = uriMatches.count; index-- > 0;) {
        NSTextCheckingResult *match = uriMatches[index];
        NSString *reference = [xml substringWithRange:[match rangeAtIndex:1]];
        NSString *value = [reference stringByReplacingOccurrencesOfString:@"&amp;"
                                                               withString:@"&"];
        value = [value stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
        value = [value stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
        value = [value stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];

        if ([value containsString:@"imported?name="]) {
            // Font reference: keep the URI, but make sure the font file exists
            // in the app's dlfonts directory when the package provides it.
            NSRange nameRange = [value rangeOfString:@"imported?name="];
            NSString *fontName = [value substringFromIndex:
                NSMaxRange(nameRange)];
            fontName = [fontName stringByRemovingPercentEncoding] ?: fontName;
            if (fontName.length && ![fontName containsString:@"/"] &&
                ![fontName containsString:@".."]) {
                NSURL *packaged = nil;
                NSURL *extraction = extractionDirectory;
                if (extraction) {
                    NSArray<NSURL *> *candidates = [NSFileManager.defaultManager
                        contentsOfDirectoryAtURL:extraction
                        includingPropertiesForKeys:nil
                                           options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                             error:nil];
                    for (NSURL *candidate in candidates) {
                        if ([candidate.lastPathComponent
                                caseInsensitiveCompare:fontName] == NSOrderedSame) {
                            packaged = candidate;
                            break;
                        }
                    }
                }
                if (packaged) {
                    NSURL *fontsDirectory = [amproj_v865StoreLibraryURL()
                        URLByAppendingPathComponent:@"dlfonts" isDirectory:YES];
                    [[NSFileManager defaultManager] createDirectoryAtURL:fontsDirectory
                                             withIntermediateDirectories:YES
                                                              attributes:nil error:nil];
                    NSURL *destination = [fontsDirectory
                        URLByAppendingPathComponent:fontName];
                    if (![NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
                        [NSFileManager.defaultManager copyItemAtURL:packaged
                                                              toURL:destination error:nil];
                        [fontsOut addObject:fontName];
                    }
                }
            }
            continue;
        }

        // Legacy packages reference media as amproj:SHA1.ext (the file is
        // one of the package's root-level resources, already extracted).
        if ([value hasPrefix:@"amproj:"]) {
            amprojRefCount++;
            NSString *reference = [value substringFromIndex:7];
            if (!reference.length || [reference containsString:@"/"] ||
                [reference containsString:@".."]) {
                continue;
            }
            NSURL *packaged = nil;
            NSURL *extraction = extractionDirectory;
            if (extraction) {
                // 旧版导出器用不带扩展名的 SHA-1 键引用媒体，而解包资源保留
                // 原始文件名（SHA1.png）。先查 manifest.txt 的键到文件名映射，
                // 再退回"去扩展名同基名"比较，最后才是完整文件名精确匹配。
                NSString *manifestName = manifestResources[reference];
                if (manifestName.length) {
                    NSURL *candidate = [extraction
                        URLByAppendingPathComponent:manifestName];
                    if ([NSFileManager.defaultManager
                            fileExistsAtPath:candidate.path]) {
                        packaged = candidate;
                        amprojManifestHits++;
                    }
                }
                if (!packaged) {
                    NSString *referenceBase = reference.pathExtension.length
                        ? [reference stringByDeletingPathExtension] : reference;
                    NSArray<NSURL *> *candidates = [NSFileManager.defaultManager
                        contentsOfDirectoryAtURL:extraction
                        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                           options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
                                             error:nil];
                    for (NSURL *candidate in candidates) {
                        NSString *name = candidate.lastPathComponent;
                        if ([name caseInsensitiveCompare:reference] == NSOrderedSame) {
                            packaged = candidate;
                            amprojExactHits++;
                            break;
                        }
                        NSString *base = name.pathExtension.length
                            ? [name stringByDeletingPathExtension] : name;
                        if ([base caseInsensitiveCompare:referenceBase] == NSOrderedSame) {
                            packaged = candidate;
                            amprojBaseHits++;
                            break;
                        }
                    }
                }
            }
            if (!packaged) {
                NSURL *extractionCatalog = [extraction
                    URLByAppendingPathComponent:@"BuiltinEffects"
                                    isDirectory:YES];
                if (extractionCatalog) {
                    NSURL *candidate = [extractionCatalog
                        URLByAppendingPathComponent:reference];
                    if ([NSFileManager.defaultManager
                            fileExistsAtPath:candidate.path]) {
                        packaged = candidate;
                    }
                }
            }
            if (!packaged) {
                amprojMisses++;
                if (!amprojFirstMiss) amprojFirstMiss = [reference copy];
                // The package did not provide this resource; keep the
                // reference untouched rather than pointing at nothing.
                continue;
            }
            NSString *storeName = storeNamesByResource[reference];
            if (!storeName) {
                NSString *sha1 = amproj_v865StoreSHA1ForFile(packaged);
                if (sha1.length != CC_SHA1_DIGEST_LENGTH * 2) continue;
                NSString *extension = packaged.pathExtension.uppercaseString;
                storeName = extension.length
                    ? [NSString stringWithFormat:@"%@.%@", sha1, extension] : sha1;
                storeNamesByResource[reference] = storeName;
                NSNumber *fileSize = nil;
                [packaged getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
                [dependenciesOut addObject:@{
                    @"source": [packaged copy] ?: [NSNull null],
                    @"name": storeName,
                    @"sha1": sha1,
                    @"size": fileSize ?: @0
                }];
            }
            // r34 实证：app 原生项目写的引用就是 am-internal:///SHA1.EXT，
            // 依赖文件就放 Library/project-dependencies（加载器自行换算容器
            // 路径，重装换容器也不受影响）。file:// 绝对路径反而因重装换
            // 容器而全部失效，弃用。
            NSString *storeURI = [NSString stringWithFormat:
                @"am-internal:///%@", storeName];
            [xml replaceCharactersInRange:[match rangeAtIndex:1] withString:storeURI];
            continue;
        }
        NSURL *fileURL = nil;
        if ([value hasPrefix:@"file://"]) {
            fileURL = [NSURL URLWithString:value];
        } else if ([value hasPrefix:@"/"]) {
            fileURL = [NSURL fileURLWithPath:value];
        }
        NSString *resourceName = fileURL.lastPathComponent;
        if (!fileURL || !resourceName.length ||
            ![NSFileManager.defaultManager fileExistsAtPath:fileURL.path]) {
            // Leave non-package references (am-internal:///, http, ...) intact.
            continue;
        }
        NSString *storeName = storeNamesByResource[resourceName];
        if (!storeName) {
            NSString *sha1 = amproj_v865StoreSHA1ForFile(fileURL);
            if (sha1.length != CC_SHA1_DIGEST_LENGTH * 2) continue;
            NSString *extension = resourceName.pathExtension.uppercaseString;
            storeName = extension.length
                ? [NSString stringWithFormat:@"%@.%@", sha1, extension] : sha1;
            storeNamesByResource[resourceName] = storeName;
            NSNumber *fileSize = nil;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
            [dependenciesOut addObject:@{
                @"source": [fileURL copy] ?: [NSNull null],
                @"name": storeName,
                @"sha1": sha1,
                @"size": fileSize ?: @0
            }];
        }
        NSString *storeURI = [NSString stringWithFormat:
            @"am-internal:///%@", storeName];
        [xml replaceCharactersInRange:[match rangeAtIndex:1] withString:storeURI];
    }

    // 全局扫尾：老包的图层不经 uri= 引用媒体——形状图层是
    // fillImage="amproj:SHA1.ext"，别的属性也可能携带。上面只覆盖了
    // uri="…"，这里把全文档残留的 amproj:<sha1> token（大小写不敏感）
    // 统一替换成 am-internal:///<storeName>。
    if (storeNamesByResource.count) {
        NSMutableDictionary<NSString *, NSString *> *resolvedByFoldedReference =
            [NSMutableDictionary dictionary];
        for (NSString *reference in storeNamesByResource) {
            resolvedByFoldedReference[reference.lowercaseString] =
                storeNamesByResource[reference];
        }
        NSRegularExpression *sweepRegex = [NSRegularExpression
            regularExpressionWithPattern:
                @"amproj:([A-Fa-f0-9]{40}(?:\\.[A-Za-z0-9]+)?)"
                                 options:0 error:nil];
        NSMutableArray<NSTextCheckingResult *> *sweepMatches = [[sweepRegex
            matchesInString:xml options:0 range:NSMakeRange(0, xml.length)]
            mutableCopy];
        NSUInteger sweepReplaced = 0, sweepUnresolved = 0;
        NSString *sweepFirstMiss = nil;
        for (NSUInteger index = sweepMatches.count; index-- > 0;) {
            NSTextCheckingResult *match = sweepMatches[index];
            NSString *reference =
                [xml substringWithRange:[match rangeAtIndex:1]];
            NSString *storeName =
                resolvedByFoldedReference[reference.lowercaseString];
            if (!storeName) {
                sweepUnresolved++;
                if (!sweepFirstMiss) sweepFirstMiss = [reference copy];
                continue;
            }
            [xml replaceCharactersInRange:[match range]
              withString:[NSString stringWithFormat:
                  @"am-internal:///%@", storeName]];
            sweepReplaced++;
        }
        os_log(OS_LOG_DEFAULT, "[AMProjExport] attribute sweep replaced=%lu "
               "unresolved=%lu first=%{public}@",
               (unsigned long)sweepReplaced, (unsigned long)sweepUnresolved,
               sweepFirstMiss ?: @"-");
    }

    // 标量在 os_log 里默认公开，不会被 syslog redact——导入诊断的关键通道。
    os_log(OS_LOG_DEFAULT, "[AMProjExport] import refs total=%lu amproj=%lu "
           "manifest_hit=%lu basename_hit=%lu exact_hit=%lu miss=%lu "
           "first_miss=%{public}@ manifest_lines=%lu",
           (unsigned long)uriMatches.count, (unsigned long)amprojRefCount,
           (unsigned long)amprojManifestHits, (unsigned long)amprojBaseHits,
           (unsigned long)amprojExactHits, (unsigned long)amprojMisses,
           amprojFirstMiss ?: @"-",
           (unsigned long)manifestResources.count);

    // The project store does not use PackageImporter media signatures.
    NSRegularExpression *sigRegex = [NSRegularExpression
        regularExpressionWithPattern:@"\\+sig=\"[^\"]*\""
                             options:0 error:nil];
    [sigRegex replaceMatchesInString:xml options:0
                               range:NSMakeRange(0, xml.length)
                          withTemplate:@""];

    // r35 实锤：app 原生项目的 media 标签没有 sig 属性（<media uri=… type=…
    // size=… infoUpdated=… width=… height=/>）。解包阶段从 manifest 注入的
    // sig="…" 会让加载器拒绝渲染（图层在、图空白）。这里把 media 标签上的
    // sig 一并剥掉，并把 infoUpdated 刷成当前时间对齐原生格式。
    NSRegularExpression *mediaSigRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(<media\\b[^>]*?)\\s+sig=\"[^\"]*\""
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    [mediaSigRegex replaceMatchesInString:xml options:0
                                   range:NSMakeRange(0, xml.length)
                              withTemplate:@"$1"];
    NSRegularExpression *infoUpdatedRegex = [NSRegularExpression
        regularExpressionWithPattern:@"infoUpdated=\"\\d+\""
                             options:0 error:nil];
    NSString *nowTimestamp = [NSString stringWithFormat:@"%lld",
        (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)];
    [infoUpdatedRegex replaceMatchesInString:xml options:0
                                      range:NSMakeRange(0, xml.length)
                                 withTemplate:
        [NSString stringWithFormat:@"infoUpdated=\"%@\"", nowTimestamp]];

    // Classification markers mirror the files Alight Motion itself keeps on
    // device: projects carry neither `type` nor `templateLink`; imported
    // templates carry a (possibly stale) templateLink and no `type`.
    NSRegularExpression *templateLinkRegex = [NSRegularExpression
        regularExpressionWithPattern:@"\\+templateLink=\"[^\"]*\""
                             options:0 error:nil];
    [templateLinkRegex replaceMatchesInString:xml options:0
                                        range:NSMakeRange(0, xml.length)
                                   withTemplate:@""];
    NSRegularExpression *typeRegex = [NSRegularExpression
        regularExpressionWithPattern:@"\\+type=\"[^\"]*\""
                             options:0 error:nil];
    [typeRegex replaceMatchesInString:xml options:0
                                range:NSMakeRange(0, xml.length)
                           withTemplate:@""];
    if (asTemplate) {
        NSRange sceneInsert = [xml rangeOfString:@"<scene"];
        if (sceneInsert.location != NSNotFound) {
            [xml insertString:[NSString stringWithFormat:
                @" templateLink=\"file:///amproj-import/%@/project.amproj\"",
                NSUUID.UUID.UUIDString]
                      atIndex:sceneInsert.location + 6];
        }
    }

    NSRange sceneRange = [xml rangeOfString:@"<scene"];
    if (sceneRange.location == NSNotFound) {
        if (error) *error = [NSError errorWithDomain:@"com.amproj.865.store"
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"\u573a\u666f XML \u7f3a\u5c11\u6839\u8282\u70b9"}];
        return nil;
    }
    NSString *nowMilliseconds = [NSString stringWithFormat:@"%lld",
        (long long)(NSDate.date.timeIntervalSince1970 * 1000.0)];
    NSRange rootTagRange = [xml rangeOfString:@">"
                                      options:0
                                        range:NSMakeRange(sceneRange.location,
                                                          xml.length - sceneRange.location)];
    NSRange modifiedRange = [xml rangeOfString:@"modifiedTime=\""
                                       options:0
                                         range:NSMakeRange(sceneRange.location,
                                                           rootTagRange.location - sceneRange.location)];
    if (modifiedRange.location != NSNotFound) {
        NSUInteger valueStart = NSMaxRange(modifiedRange);
        NSRange valueEnd = [xml rangeOfString:@"\""
                                      options:0
                                        range:NSMakeRange(valueStart,
                                                          rootTagRange.location - valueStart)];
        if (valueEnd.location != NSNotFound) {
            [xml replaceCharactersInRange:NSMakeRange(valueStart,
                                                      valueEnd.location - valueStart)
                               withString:nowMilliseconds];
        }
    } else {
        [xml insertString:[NSString stringWithFormat:@" modifiedTime=\"%@\"",
                           nowMilliseconds]
                  atIndex:sceneRange.location + 6];
        rootTagRange = [xml rangeOfString:@">"
                                  options:0
                                    range:NSMakeRange(sceneRange.location,
                                                      xml.length - sceneRange.location)];
    }

    if (titleOut) {
        NSRange titleRange = [xml rangeOfString:@"title=\""
                                        options:0
                                          range:NSMakeRange(sceneRange.location,
                                                            rootTagRange.location - sceneRange.location)];
        if (titleRange.location != NSNotFound) {
            NSUInteger start = NSMaxRange(titleRange);
            NSRange end = [xml rangeOfString:@"\""
                                     options:0
                                       range:NSMakeRange(start,
                                                         rootTagRange.location - start)];
            if (end.location != NSNotFound) {
                NSString *title = [xml substringWithRange:NSMakeRange(start,
                                                                      end.location - start)];
                title = [title stringByReplacingOccurrencesOfString:@"&amp;"
                                                         withString:@"&"];
                *titleOut = title;
            }
        }
    }
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

// The Projects/"Your Templates" lists render from a persisted scene-summary
// cache that Alight Motion rebuilds only on launch. Appending our entry here
// makes a freshly written project visible as soon as the user switches tabs.
static void amproj_v865StoreUpdateSummaryCache(NSString *storeUUID,
                                               NSString *title,
                                               BOOL asTemplate,
                                               NSData *storeXML) {
    if (!storeUUID.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *raw = [defaults stringForKey:@"cached_scene_summary_raw"];
    NSMutableDictionary *document = nil;
    if (raw.length) {
        NSData *rawData = [raw dataUsingEncoding:NSUTF8StringEncoding];
        if (rawData) {
            NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:rawData
                                                                   options:0 error:nil];
            if ([parsed isKindOfClass:NSDictionary.class]) {
                document = [parsed mutableCopy];
            }
        }
    }
    if (!document) document = [NSMutableDictionary dictionary];
    NSMutableArray *scenes = [document[@"scenes"] isKindOfClass:NSArray.class]
        ? [NSMutableArray arrayWithArray:document[@"scenes"]]
        : [NSMutableArray array];
    for (NSDictionary *scene in scenes) {
        if ([scene[@"i"] isKindOfClass:NSString.class] &&
            [scene[@"i"] isEqualToString:storeUUID]) {
            return; // already indexed
        }
    }
    NSURL *storeURL = [amproj_v865StoreLibraryURL()
        URLByAppendingPathComponent:[storeUUID stringByAppendingPathExtension:@"xml"]];
    NSString *xml = [NSString stringWithContentsOfURL:storeURL
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
    NSInteger sceneWidth = 0;
    NSInteger sceneHeight = 0;
    NSInteger sceneTotalTime = 0;
    if (xml.length) {
        for (NSString *attribute in (@[ @"width", @"height", @"totalTime" ])) {
            NSRange attributeRange = [xml rangeOfString:
                [NSString stringWithFormat:@"%@=\"", attribute]];
            if (attributeRange.location == NSNotFound ||
                attributeRange.location > 500) continue;
            NSUInteger valueStart = NSMaxRange(attributeRange);
            NSRange valueEnd = [xml rangeOfString:@"\""
                                          options:0
                                            range:NSMakeRange(valueStart,
                                                MIN(xml.length - valueStart, 64))];
            if (valueEnd.location == NSNotFound) continue;
            NSInteger value = [xml substringWithRange:
                NSMakeRange(valueStart, valueEnd.location - valueStart)].integerValue;
            if ([attribute isEqualToString:@"width"]) sceneWidth = value;
            else if ([attribute isEqualToString:@"height"]) sceneHeight = value;
            else sceneTotalTime = value;
        }
    }
    [scenes addObject:@{ // mirrors the entries Alight Motion itself writes
        @"tht": @{@"native": @(-1)},
        @"": @NO,
        @"tt": @{@"native": @(sceneTotalTime)},
        @"isTemplate": @(asTemplate),
        @"w": @(sceneWidth),
        @"st": @"scene",
        @"ta": @0,
        @"h": @(sceneHeight),
        @"x": @(storeXML.length),
        @"i": storeUUID,
        @"tv": @0,
        @"t": title.length ? title : @""
    }];
    NSData *updated = [NSJSONSerialization dataWithJSONObject:@{@"scenes": scenes}
                                                      options:0 error:nil];
    if (!updated) return;
    NSString *updatedRaw = [[NSString alloc] initWithData:updated
                                                 encoding:NSUTF8StringEncoding];
    if (updatedRaw.length) [defaults setObject:updatedRaw
                                        forKey:@"cached_scene_summary_raw"];
}

// 采样 Library 下 store XML 的媒体 uri 并 public 输出——am-internal 已被
// 证明不被主程序识别，app 自己保存的项目会揭示原生引用格式。
static void amproj_logStoreMediaSamples(NSString *tag) {
    NSURL *library = amproj_v865StoreLibraryURL();
    NSArray<NSURL *> *files = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:library
        includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                           options:0 error:nil];
    NSMutableArray<NSURL *> *xmls = [NSMutableArray array];
    for (NSURL *url in files) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
        [xmls addObject:url];
    }
    if (!xmls.count) return;
    [xmls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"uri=\\\"([^\\\"]*)\\\""
                             options:0 error:nil];
    NSUInteger shown = MIN(xmls.count, (NSUInteger)6);
    for (NSURL *url in [xmls subarrayWithRange:NSMakeRange(0, shown)]) {
        NSString *text = [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        if (!text.length) continue;
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSMutableArray<NSString *> *samples = [NSMutableArray array];
        for (NSTextCheckingResult *match in [regex matchesInString:text
            options:0 range:NSMakeRange(0, text.length)]) {
            if (samples.count >= 8) break;
            NSString *value = [text substringWithRange:[match rangeAtIndex:1]];
            if (value.length > 90) {
                value = [[value substringToIndex:90]
                    stringByAppendingString:@"…"];
            }
            if ([seen containsObject:value]) continue;
            [seen addObject:value];
            [samples addObject:value];
        }
        if (samples.count) {
            os_log(OS_LOG_DEFAULT,
                   "[AMProjExport] store sample (%{public}@) %{public}@: %{public}@",
                   tag, url.lastPathComponent,
                   [samples componentsJoinedByString:@" | "]);
        }
    }
}

// 在整个沙盒里定位依赖文件的实际落盘位置。820224D5…PNG 是 app 自己导入
// 照片时生成的原生依赖文件，它所在的目录就是 am-internal 加载器的搜索目录；
// CB0EF728…MOV 是我们 r31 写入的副本，用于对照。
static void amproj_locateDependencySamples(void) {
    NSArray<NSString *> *targets = @[
        @"820224D52494A5F881AB29A4C198DE2CAC875AB6.PNG",
        @"CB0EF728DB857F1D53F79FE2B707E2F067DADDD3.MOV",
    ];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDirectoryEnumerator<NSString *> *enumerator =
        [manager enumeratorAtPath:NSHomeDirectory()];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    NSUInteger visited = 0;
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSString *nativeDir = nil;
    NSString *oursDir = nil;
    NSString *relative = nil;
    while ((relative = [enumerator nextObject]) != nil) {
        if (++visited > 120000 || [deadline timeIntervalSinceNow] <= 0) break;
        NSString *name = relative.lastPathComponent;
        if ([name caseInsensitiveCompare:targets[0]] == NSOrderedSame) {
            nativeDir = [[NSHomeDirectory()
                stringByAppendingPathComponent:relative]
                stringByDeletingLastPathComponent];
            [hits addObject:[NSHomeDirectory()
                stringByAppendingPathComponent:relative]];
        } else if ([name caseInsensitiveCompare:targets[1]] == NSOrderedSame) {
            oursDir = [[NSHomeDirectory()
                stringByAppendingPathComponent:relative]
                stringByDeletingLastPathComponent];
            [hits addObject:[NSHomeDirectory()
                stringByAppendingPathComponent:relative]];
        }
    }
    os_log(OS_LOG_DEFAULT, "[AMProjExport] dep locate visited=%lu "
           "native_dir=%{public}@ ours_dir=%{public}@",
           (unsigned long)visited, nativeDir ?: @"NOT_FOUND",
           oursDir ?: @"NOT_FOUND");
    if (nativeDir) {
        NSArray<NSString *> *entries = [manager contentsOfDirectoryAtPath:nativeDir
                                                                    error:nil];
        NSUInteger shown = MIN(entries.count, (NSUInteger)12);
        os_log(OS_LOG_DEFAULT, "[AMProjExport] native dep dir listing %{public}@",
               [entries subarrayWithRange:NSMakeRange(0, shown)]);
    }
    os_log(OS_LOG_DEFAULT, "[AMProjExport] dep hits %{public}@",
           hits.count ? [hits componentsJoinedByString:@" | "] : @"NONE");
}

// 采样 Library 下 store XML 的完整 <media …> 标签并 public 输出——原生项目
// 与我们导入项目的标签对照能揭示加载失败缺的字段（sig/type 等）。
static void amproj_logMediaTagSamples(void) {
    NSURL *library = amproj_v865StoreLibraryURL();
    NSArray<NSURL *> *files = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:library
        includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                           options:0 error:nil];
    NSMutableArray<NSURL *> *xmls = [NSMutableArray array];
    for (NSURL *url in files) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"xml"]) continue;
        [xmls addObject:url];
    }
    [xmls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da = nil, *db = nil;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"<media\\b[^>]*>"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSUInteger shown = MIN(xmls.count, (NSUInteger)6);
    for (NSURL *url in [xmls subarrayWithRange:NSMakeRange(0, shown)]) {
        NSString *text = [NSString stringWithContentsOfURL:url
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        if (!text.length) continue;
        NSMutableArray<NSString *> *tags = [NSMutableArray array];
        for (NSTextCheckingResult *match in [regex matchesInString:text
            options:0 range:NSMakeRange(0, text.length)]) {
            if (tags.count >= 2) break;
            NSString *tag = [text substringWithRange:match.range];
            if (tag.length > 320) {
                tag = [[tag substringToIndex:320] stringByAppendingString:@"…"];
            }
            [tags addObject:tag];
        }
        if (tags.count) {
            os_log(OS_LOG_DEFAULT, "[AMProjExport] media tag (%{public}@): %{public}@",
                   url.lastPathComponent,
                   [tags componentsJoinedByString:@" || "]);
        }
    }
}

static BOOL amproj_write865ProjectStoreImport(NSURL *preparedArchiveURL,
                                              NSString *originalName,
                                              NSString *transactionID,
                                              NSString * _Nullable * _Nullable titleOut) {
    NSFileManager *manager = NSFileManager.defaultManager;
    // XML presets land in "Your Templates" (matching Alight Motion's own
    // upload semantics); full packages become regular projects.
    BOOL asTemplate = [originalName.pathExtension.lowercaseString
        isEqualToString:@"xml"];
    NSURL *workDirectory = [[[NSURL fileURLWithPath:NSTemporaryDirectory()
                                         isDirectory:YES]
        URLByAppendingPathComponent:@"amproj_store_865" isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *nativeXMLURL = nil;
    NSDictionary *metrics = nil;
    NSError *prepareError = nil;
    BOOL prepared = AMProjPrepareNativeImport(preparedArchiveURL, workDirectory,
                                              &nativeXMLURL, &metrics, &prepareError);
    if (!prepared || !nativeXMLURL) {
        amproj_logCriticalEvent(@"import.865_store_prepare_failed", @{
            @"filename": originalName ?: @"",
            @"transaction_id": transactionID ?: @"",
            @"error": prepareError.localizedDescription ?: @"unknown"
        });
        [manager removeItemAtURL:workDirectory error:nil];
        return NO;
    }

    NSURL *extractionDirectory = nil;
    NSString *extractionPath = [metrics[@"extraction_directory"]
        isKindOfClass:NSString.class] ? metrics[@"extraction_directory"] : nil;
    if (extractionPath.length) {
        extractionDirectory = [NSURL fileURLWithPath:extractionPath isDirectory:YES];
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *dependencies = [NSMutableArray array];
    NSMutableArray<NSString *> *fonts = [NSMutableArray array];
    NSString *title = nil;
    NSError *rewriteError = nil;
    NSData *storeXML = amproj_v865StoreRewriteSceneXML(
        nativeXMLURL, extractionDirectory, asTemplate,
        dependencies, fonts, &title, &rewriteError);
    if (!storeXML) {
        amproj_logCriticalEvent(@"import.865_store_rewrite_failed", @{
            @"filename": originalName ?: @"",
            @"transaction_id": transactionID ?: @"",
            @"error": rewriteError.localizedDescription ?: @"unknown"
        });
        [manager removeItemAtURL:workDirectory error:nil];
        return NO;
    }

    NSURL *dependenciesDirectory = [amproj_v865StoreLibraryURL()
        URLByAppendingPathComponent:@"project-dependencies" isDirectory:YES];
    [manager createDirectoryAtURL:dependenciesDirectory
          withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger copiedMedia = 0;
    for (NSDictionary<NSString *, id> *dependency in dependencies) {        NSURL *source = [dependency[@"source"] isKindOfClass:NSURL.class]
            ? dependency[@"source"] : nil;
        NSString *storeName = [dependency[@"name"] isKindOfClass:NSString.class]
            ? dependency[@"name"] : nil;
        NSNumber *expectedSize = [dependency[@"size"] isKindOfClass:NSNumber.class]
            ? dependency[@"size"] : @0;
        if (!source || !storeName.length) continue;
        NSURL *destination = [dependenciesDirectory
            URLByAppendingPathComponent:storeName];
        NSDictionary *existing = [manager attributesOfItemAtPath:destination.path
                                                           error:nil];
        if (existing && [existing[NSFileSize] isEqualToNumber:expectedSize]) continue;
        NSURL *temporary = [dependenciesDirectory
            URLByAppendingPathComponent:[NSString stringWithFormat:@".%@.%@.partial",
                                         storeName, NSUUID.UUID.UUIDString]];
        [manager removeItemAtURL:temporary error:nil];
        NSError *copyError = nil;
        if ([manager copyItemAtURL:source toURL:temporary error:&copyError] ||
            (copyError && copyError.code == NSFileWriteFileExistsError)) {
            if (![manager moveItemAtURL:temporary toURL:destination error:nil]) {
                [manager removeItemAtURL:temporary error:nil];
            } else {
                copiedMedia++;
            }
        } else {
            [manager removeItemAtURL:temporary error:nil];
        }
    }

    // 双写留底：app 的孤儿清理会删掉它不认识的项目引用的依赖文件（r36 实
    // 测），备份一份供每次激活时对账恢复。
    NSURL *backupDirectory = amproj_v865DependencyBackupURL();
    [manager createDirectoryAtURL:backupDirectory
          withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger backedUp = 0;
    for (NSDictionary<NSString *, id> *dependency in dependencies) {
        NSString *storeName = [dependency[@"name"] isKindOfClass:NSString.class]
            ? dependency[@"name"] : nil;
        if (!storeName.length) continue;
        NSURL *live = [dependenciesDirectory
            URLByAppendingPathComponent:storeName];
        NSURL *backupCopy = [backupDirectory
            URLByAppendingPathComponent:storeName];
        if (![manager fileExistsAtPath:live.path]) continue;
        if ([manager fileExistsAtPath:backupCopy.path]) continue;
        if ([manager copyItemAtURL:live toURL:backupCopy error:nil]) {
            backedUp++;
        }
    }
    os_log(OS_LOG_DEFAULT, "[AMProjExport] import deps backup written=%lu",
           (unsigned long)backedUp);

    NSString *storeUUID = NSUUID.UUID.UUIDString.uppercaseString;
    NSURL *storeURL = [amproj_v865StoreLibraryURL()
        URLByAppendingPathComponent:[storeUUID stringByAppendingPathExtension:@"xml"]];
    NSError *writeError = nil;
    if (![storeXML writeToURL:storeURL options:NSDataWritingAtomic
                        error:&writeError]) {
        amproj_logCriticalEvent(@"import.865_store_write_failed", @{
            @"filename": originalName ?: @"",
            @"transaction_id": transactionID ?: @"",
            @"error": writeError.localizedDescription ?: @"unknown"
        });
        [manager removeItemAtURL:workDirectory error:nil];
        return NO;
    }

    // Independent completion evidence: re-read the stored document and confirm
    // every rewritten reference resolves to an existing dependency file.
    NSError *verifyError = nil;
    NSString *verifyXML = [NSString stringWithContentsOfURL:storeURL
                                                   encoding:NSUTF8StringEncoding
                                                      error:&verifyError];
    NSUInteger referenceCount = 0;
    NSUInteger missingWrittenDependencies = 0;
    NSMutableSet<NSString *> *writtenNames = [NSMutableSet set];
    for (NSDictionary<NSString *, id> *dependency in dependencies) {
        NSString *dependencyName = [dependency[@"name"] isKindOfClass:NSString.class]
            ? dependency[@"name"] : nil;
        if (dependencyName.length) [writtenNames addObject:dependencyName];
    }
    if (verifyXML) {
        NSRegularExpression *verifyRegex = [NSRegularExpression
            regularExpressionWithPattern:@"am-internal:///([^\"]*)\""
                                 options:0 error:nil];
        for (NSTextCheckingResult *match in [verifyRegex
                matchesInString:verifyXML options:0
                          range:NSMakeRange(0, verifyXML.length)]) {
            referenceCount++;
            NSString *reference = [verifyXML substringWithRange:[match rangeAtIndex:1]];
            if (![writtenNames containsObject:reference]) continue;
            if (![manager fileExistsAtPath:[dependenciesDirectory
                URLByAppendingPathComponent:reference].path]) {
                missingWrittenDependencies++;
            }
        }
    }
    BOOL rootScenePresent = [verifyXML rangeOfString:@"<scene"].location != NSNotFound;
    BOOL verified = rootScenePresent && verifyXML.length > 0 &&
        missingWrittenDependencies == 0;
    if (verified) {
        amproj_v865StoreUpdateSummaryCache(storeUUID, title, asTemplate, storeXML);
        if (titleOut) *titleOut = title.length ? [title copy] : nil;
    }
    [manager removeItemAtURL:workDirectory error:nil];
    os_log(OS_LOG_DEFAULT, "[AMProjExport] import store done deps=%lu "
           "copied=%lu refs=%lu missing=%lu verified=%d",
           (unsigned long)dependencies.count, (unsigned long)copiedMedia,
           (unsigned long)referenceCount,
           (unsigned long)missingWrittenDependencies, verified);
    amproj_logStoreMediaSamples(@"post-import");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        amproj_logStoreMediaSamples(@"rescan45");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(150.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        amproj_logStoreMediaSamples(@"rescan150");
    });
    amproj_logCriticalEvent(@"import.865_store_write_completed", @{
        @"filename": originalName ?: @"",
        @"transaction_id": transactionID ?: @"",
        @"store_uuid": storeUUID,
        @"title": title ?: @"",
        @"media_count": @(dependencies.count),
        @"media_copied": @(copiedMedia),
        @"fonts_installed": @(fonts.count),
        @"references": @(referenceCount),
        @"missing_dependencies": @(missingWrittenDependencies),
        @"verified": @(verified),
        @"import_completed": @YES,
        @"route": @"865_project_store"
    });
    return verified;
}

static void amproj_tryDispatchPendingImport(NSUInteger generation) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"pending_import_dispatch");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != amproj_pendingImportGeneration || !amproj_pendingImportURL) return;

        if (amproj_runtimeIsBuild865() && !amproj_nativePackageImportStarter) {
            // Build 865's native importer is an async Swift closure chain whose
            // context captures Alight Motion's own cloud-download objects. It
            // cannot be invoked from the plugin, and the previous handoff loop
            // never imported anything. Fail the transaction here, on evidence:
            // the file is validated and retained, and no success is claimed.
            NSString *name = amproj_pendingImportName ?: @"project.amproj";
            AMProjImportTransaction *unreachable =
                amproj_importTransactionForID(amproj_pendingImportTransactionID);
            BOOL XML = [name.pathExtension.lowercaseString isEqualToString:@"xml"] ||
                (unreachable && unreachable.kind == AMProjImportKindXMLTemplate);
            amproj_retryImportURL = unreachable.archiveURL;
            amproj_retryImportName = [name copy];
            amproj_writeImportBreadcrumb(amproj_pendingImportTransactionID,
                                         unreachable.fingerprint,
                                         @"failed", unreachable.source,
                                         nil, nil,
                                         @"Build 865 native importer is unreachable from the plugin; package validated and retained");
            amproj_releaseImportTransaction(amproj_pendingImportTransactionID, NO);
            amproj_pendingImportURL = nil;
            amproj_pendingImportName = nil;
            amproj_pendingImportTransactionID = nil;
            amproj_activeNativeImportGeneration = 0;
            amproj_activeNativeImportTransactionID = nil;
            amproj_pendingImportDeadline = 0;
            amproj_importDispatchCoolingDown = NO;
            amproj_importProjectRowBaselineCount = -1;
            amproj_debugEvent(@"import.865_native_importer_unreachable", @{
                @"filename": name,
                @"kind": XML ? @"xml_template" : @"amproj_package",
                @"validated_and_retained": @YES,
                @"import_completed": @NO
            });
            amproj_showImportStatusForTransaction(
                XML ? @"AMProj · XML 已校验，但 865 原生导入引擎尚未接通"
                    : @"AMProj · 项目包已校验，但 865 原生导入引擎尚未接通",
                YES, amproj_pendingImportTransactionID);
            amproj_presentImportErrorOfferingPicker(
                XML
                    ? @"XML 已通过完整校验并保留在本机缓存。6.2.58 的原生导入入口无法从插件调用（其导入闭包依赖 AM 内部云下载对象），因此本次没有写入项目，也不会伪装成功。可点击“重试”或“选择 XML 文件”。"
                    : @"项目包已通过完整校验并保留在本机缓存。6.2.58 的原生导入入口无法从插件调用（其导入闭包依赖 AM 内部云下载对象），因此本次没有写入项目，也不会伪装成功。可点击“重试”或“选择项目包”。",
                YES);
            amproj_resumeQueuedImports(@"native_importer_unreachable");
            return;
        }

        if (AMProjNativePackageImportBridgeRequiresRestart()) {
            amproj_pauseForNativeBridgeRestart(
                amproj_pendingImportTransactionID,
                amproj_pendingImportName);
            return;
        }

        UIApplication *application = UIApplication.sharedApplication;
        if (application.applicationState != UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_tryDispatchPendingImport(generation);
            });
            return;
        }
        if (amproj_nativeImportAlertActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_tryDispatchPendingImport(generation);
            });
            return;
        }
        if (AMProjNativePackageImportBridgeIsBusy()) {
            amproj_debugEvent(@"import.local_bridge_busy", @{
                @"transaction_id": amproj_pendingImportTransactionID ?: @"",
                @"generation": @(generation)
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_tryDispatchPendingImport(generation);
            });
            return;
        }
        AMProjImportTransaction *laneOwner =
            amproj_importTransactionForID(amproj_pendingImportTransactionID);
        BOOL ownsPendingLane = laneOwner &&
            laneOwner.state == AMProjImportTransactionWaitingForProjects &&
            [laneOwner.transactionID isEqualToString:amproj_pendingImportTransactionID];
        BOOL projectUIOwnerReady =
            amproj_visibleProjectsControllers().count > 0;
        BOOL persistenceBaselineReady = ownsPendingLane &&
            laneOwner.persistenceBaselineCaptured &&
            laneOwner.persistenceBaselineGeneration == generation;
        if (!ownsPendingLane || !laneOwner.projectTitleBaselineCaptured ||
            !persistenceBaselineReady || !projectUIOwnerReady) {
            if (laneOwner) {
                if (!projectUIOwnerReady) {
                    amproj_invalidatePersistenceBaseline(laneOwner);
                }
                amproj_captureActivatedPackageBaselines(
                    amproj_pendingImportURL, amproj_pendingImportName,
                    amproj_pendingImportTransactionID);
            }
            return;
        }
        if (amproj_pendingImportDeadline <= 0) {
            amproj_pendingImportDeadline = CFAbsoluteTimeGetCurrent() + 90.0;
        }
        AMProjNativePackageImportStarter starter = amproj_nativePackageImportStarter;
        NSString *transactionID = amproj_pendingImportTransactionID ?: @"";
        if (starter) {
            NSURL *URL = amproj_pendingImportURL;
            NSString *name = amproj_pendingImportName ?: @"project.amproj";
            CFAbsoluteTime deadline = amproj_pendingImportDeadline;
            void (^startAuthorized)(void) = ^{
            if (generation != amproj_pendingImportGeneration ||
                ![transactionID isEqualToString:amproj_pendingImportTransactionID ?: @""] ||
                !amproj_pendingImportURL) {
                return;
            }
            amproj_importDispatchCoolingDown = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionNativeActive);
            if (amproj_importProjectRowBaselineCount < 0) {
                amproj_importProjectRowBaselineCount = amproj_visibleProjectsRowCount();
            }
            AMProjImportTransaction *dispatchTransaction =
                amproj_importTransactionForID(transactionID);
            if (dispatchTransaction &&
                !dispatchTransaction.projectTitleBaselineCaptured) {
                NSString *expectedTitle = dispatchTransaction.projectTitle.length
                    ? dispatchTransaction.projectTitle : name;
                dispatchTransaction.projectTitlePresentAtBaseline =
                    amproj_projectRowVerifiedForName(expectedTitle);
                dispatchTransaction.projectTitleMatchBaselineCount =
                    amproj_projectTitleMatchCount(expectedTitle);
                BOOL baselineReady = amproj_importProjectRowBaselineCount >= 0 &&
                    dispatchTransaction.projectTitleMatchBaselineCount >= 0;
                dispatchTransaction.projectTitleBaselineCaptured = baselineReady;
                amproj_debugEvent(@"import.project_title_baseline", @{
                    @"transaction_id": transactionID,
                    @"title": expectedTitle ?: @"",
                    @"present": @(dispatchTransaction.projectTitlePresentAtBaseline),
                    @"match_count": @(dispatchTransaction.projectTitleMatchBaselineCount),
                    @"row_count": @(amproj_importProjectRowBaselineCount),
                    @"ready": @(baselineReady)
                });
            }
            if (dispatchTransaction) {
                dispatchTransaction.nativeTerminalStatus4Observed = NO;
                dispatchTransaction.nativeTerminalStatus4Returned = NO;
                dispatchTransaction.nativeCompletionSucceeded = NO;
                dispatchTransaction.nativeTemporaryConsumed = NO;
            }
            amproj_beginNativeImportObservation(name);
            amproj_nativeImportRecognitionName = name;
            amproj_activeNativeImportGeneration = generation;
            amproj_activeNativeImportTransactionID = [transactionID copy];
            amproj_debugEvent(@"import.local_bridge_start", @{
                @"filename": name,
                @"transaction_id": transactionID,
                @"attempt_id": amproj_currentNativeImportAttemptID() ?: @"",
                @"package_filename": URL.lastPathComponent ?: @""
            });

            __block atomic_bool completionCalled = false;
            NSError *startError = nil;
            BOOL started = NO;
            @try {
                started = starter(URL, name, ^(BOOL success, NSError *error) {
                    bool expected = false;
                    if (!atomic_compare_exchange_strong(&completionCalled, &expected, true)) return;
                    amproj_finishNativePackageImport(generation, name, success, error,
                                                     transactionID);
                }, &startError);
            } @catch (NSException *exception) {
                startError = [NSError errorWithDomain:@"com.amproj.import.bridge"
                                                  code:42
                                              userInfo:@{NSLocalizedDescriptionKey:
                    exception.reason ?: @"The local project importer raised an exception"}];
            }

            BOOL retryable = !started && !atomic_load(&completionCalled) &&
                [startError.userInfo[@"AMProjRetryable"] boolValue] &&
                CFAbsoluteTimeGetCurrent() < deadline;
            if (retryable) {
                amproj_activeNativeImportGeneration = 0;
                amproj_activeNativeImportTransactionID = nil;
                amproj_nativeImportRecognitionName = nil;
                ++amproj_nativeImportRecognitionGeneration;
                amproj_endNativeImportObservation();
                amproj_importDispatchCoolingDown = NO;
                amproj_markImportTransactionState(
                    transactionID, AMProjImportTransactionWaitingForProjects);
                // A retry is a new native start attempt. Invalidate both UI
                // and persistence baselines so no mutations from the failed
                // attempt (or another lifecycle callback) can satisfy this
                // transaction's eventual persistence delta.
                amproj_invalidatePersistenceBaseline(dispatchTransaction);
                amproj_invalidateTemplateProbe(dispatchTransaction);
                dispatchTransaction.projectTitleBaselineCaptured = NO;
                amproj_importProjectRowBaselineCount = -1;
                NSUInteger retryGeneration = ++amproj_pendingImportGeneration;
                amproj_debugEvent(@"import.local_bridge_retry", @{
                    @"filename": name,
                    @"error": startError.localizedDescription ?: @"",
                    @"previous_generation": @(generation),
                    @"retry_generation": @(retryGeneration),
                    @"remaining_ms": @(MAX(0, (deadline -
                        CFAbsoluteTimeGetCurrent()) * 1000.0))
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_captureActivatedPackageBaselines(
                        URL, name, transactionID);
                });
                return;
            }

            amproj_pendingImportURL = nil;
            amproj_pendingImportName = nil;
            amproj_pendingImportTransactionID = nil;
            amproj_pendingImportDeadline = 0;
            if (!started && !atomic_load(&completionCalled)) {
                atomic_store(&completionCalled, true);
                amproj_finishNativePackageImport(generation, name, NO, startError,
                                                 transactionID);
            } else if (started &&
                       generation == amproj_activeNativeImportGeneration) {
                amproj_showImportStatusForTransaction(
                    dispatchTransaction.kind == AMProjImportKindXMLTemplate
                        ? @"AMProj · 2/3 正在离线解包 XML 模板"
                        : @"AMProj \u00b7 3/4 AM \u6b63\u5728\u89e3\u5305\u5e76\u5199\u5165\u9879\u76ee\u6216\u6a21\u677f",
                    NO, transactionID);
                amproj_debugEvent(@"import.local_bridge_started", @{
                    @"success": @YES,
                    @"filename": name
                });
            }
            };
#if AMPROJ_CLOUD_SYNC
            if (amproj_importAuthorizationPending &&
                amproj_importAuthorizationGeneration == generation) {
                return;
            }
            amproj_importAuthorizationPending = YES;
            amproj_importAuthorizationGeneration = generation;
            NSString *authorizationTransactionID = [transactionID copy];
            NSString *authorizationName = [name copy];
            AMCloudAuthorizeFeature(@"import", nil, ^(BOOL allowed, NSError *error) {
                if (amproj_importAuthorizationGeneration == generation) {
                    amproj_importAuthorizationPending = NO;
                    amproj_importAuthorizationGeneration = 0;
                }
                if (generation != amproj_pendingImportGeneration ||
                    ![authorizationTransactionID
                        isEqualToString:amproj_pendingImportTransactionID ?: @""]) {
                    return;
                }
                if (!allowed) {
                    amproj_finishImportAuthorizationDenied(
                        generation, authorizationTransactionID,
                        authorizationName, error);
                    return;
                }

                AMProjImportTransaction *currentOwner =
                    amproj_importTransactionForID(authorizationTransactionID);
                BOOL stillReady = currentOwner &&
                    currentOwner.state == AMProjImportTransactionWaitingForProjects &&
                    currentOwner.projectTitleBaselineCaptured &&
                    currentOwner.persistenceBaselineCaptured &&
                    currentOwner.persistenceBaselineGeneration == generation &&
                    amproj_visibleProjectsControllers().count > 0 &&
                    UIApplication.sharedApplication.applicationState ==
                        UIApplicationStateActive &&
                    !amproj_nativeImportAlertActive &&
                    !AMProjNativePackageImportBridgeRequiresRestart() &&
                    !AMProjNativePackageImportBridgeIsBusy() &&
                    amproj_nativePackageImportStarter == starter;
                if (!stillReady) {
                    amproj_tryDispatchPendingImport(generation);
                    return;
                }
                amproj_debugEvent(@"import.authorization", @{
                    @"allowed": @YES,
                    @"transaction_id": authorizationTransactionID
                });
                startAuthorized();
            });
#else
            startAuthorized();
#endif
            return;
        }

        if (CFAbsoluteTimeGetCurrent() >= amproj_pendingImportDeadline) {
            NSString *name = amproj_pendingImportName ?: @"project.amproj";
            amproj_pendingImportURL = nil;
            amproj_pendingImportName = nil;
            amproj_pendingImportTransactionID = nil;
            amproj_activeNativeImportGeneration = 0;
            amproj_activeNativeImportTransactionID = nil;
            amproj_pendingImportDeadline = 0;
            amproj_importDispatchCoolingDown = NO;
            amproj_importProjectRowBaselineCount = -1;
            AMProjImportTransaction *timedOutTransaction =
                amproj_importTransactionForID(transactionID);
            amproj_retryImportURL = timedOutTransaction.archiveURL;
            amproj_retryImportName = [name copy];
            amproj_writeImportBreadcrumb(transactionID,
                                         timedOutTransaction.fingerprint,
                                         @"failed", timedOutTransaction.source,
                                         nil, nil,
                                         @"Native project importer was not ready before the deadline");
            amproj_releaseImportTransaction(transactionID, NO);
            amproj_debugEvent(@"import.local_bridge_timeout", @{
                @"filename": name,
                @"bridge_available": @NO
            });
            amproj_showImportStatusForTransaction(
                @"AMProj \u00b7 AM \u672c\u5730\u9879\u76ee\u5bfc\u5165\u5668\u5c1a\u672a\u5c31\u7eea",
                YES, transactionID);
            amproj_presentImportErrorOfferingPicker(
                @"\u9879\u76ee\u5305\u5df2\u590d\u5236\u5e76\u6821\u9a8c\u901a\u8fc7\uff0c\u4f46 Alight Motion \u672c\u5730\u9879\u76ee\u5bfc\u5165\u5668\u672a\u80fd\u5c31\u7eea\u3002\u672c\u6b21\u6ca1\u6709\u56de\u9000\u5230\u4efb\u4f55\u4e0a\u4f20\u5165\u53e3\u3002",
                YES);
            amproj_resumeQueuedImports(@"native_import_timeout");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_tryDispatchPendingImport(generation);
        });
    });
}

static void amproj_queuePreparedImport(NSURL *URL, NSString *originalName,
                                       NSString *transactionID) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"prepared_import_queue");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!URL) return;
        if (amproj_runtimeIsBuild865() && !amproj_nativePackageImportStarter) {
            // Build 865: the validated package becomes a real project through
            // the on-device project store (Library/<UUID>.xml +
            // project-dependencies/<SHA1>). No PackageImporter lane, no
            // handoff, no fake success — the store write is the import.
            AMProjImportTransaction *storeTransaction =
                amproj_importTransactionForID(transactionID);
            if (transactionID.length && !storeTransaction) {
                amproj_debugEvent(@"import.stale_queue_suppressed", @{
                    @"transaction_id": transactionID,
                    @"reason": @"state_changed"
                });
                return;
            }
            if (storeTransaction) {
                amproj_markImportTransactionState(
                    transactionID, AMProjImportTransactionCreatingProject);
            }
            NSString *storeName = [originalName copy] ?: @"project.amproj";
            NSString *storeTransactionID = [transactionID copy];
            NSURL *storeURL = [URL copy];
            BOOL storeIsTemplate = [storeName.pathExtension.lowercaseString
                isEqualToString:@"xml"];
            NSString *storeDestination = storeIsTemplate ? @"您的模板" : @"项目";
            amproj_showImportStatusForTransaction(
                @"AMProj · 3/4 正在写入 Alight Motion 项目库", NO, transactionID);
            void (^presentStoreResult)(BOOL written, NSString *projectTitle) =
                ^(BOOL written, NSString *projectTitle) {
                AMProjImportTransaction *finished =
                    amproj_importTransactionForID(storeTransactionID);
                NSString *shownTitle = projectTitle.length ? projectTitle
                    : storeName.stringByDeletingPathExtension;
                if (written) {
                    amproj_writeImportBreadcrumb(storeTransactionID,
                                                 finished.fingerprint,
                                                 @"completed",
                                                 @"865_project_store",
                                                 nil, nil, nil);
                    amproj_showImportStatusForTransaction(
                        [NSString stringWithFormat:
                            @"AMProj · 导入完成：《%@》已加入%@，切换过去即可看到",
                            shownTitle, storeDestination],
                        NO, storeTransactionID);
                    amproj_releaseImportTransaction(storeTransactionID, YES);
                } else {
                    amproj_retryImportURL = finished.archiveURL ?: storeURL;
                    amproj_retryImportName = [storeName copy];
                    amproj_writeImportBreadcrumb(storeTransactionID,
                                                 finished.fingerprint,
                                                 @"failed",
                                                 @"865_project_store",
                                                 nil, nil,
                                                 @"写入 Alight Motion 项目库失败，缓存包已保留");
                    amproj_showImportStatusForTransaction(
                        storeIsTemplate
                            ? @"AMProj · XML 写入失败，缓存文件已保留"
                            : @"AMProj · 项目包写入失败，缓存包已保留",
                        YES, storeTransactionID);
                    amproj_presentImportErrorOfferingPickerWithTitle(
                        storeIsTemplate
                            ? @"XML 校验通过，但写入 Alight Motion 项目库时失败，缓存文件已保留。可点击“重试”。"
                            : @"项目包校验通过，但写入 Alight Motion 项目库时失败，缓存包已保留。可点击“重试”。",
                        storeIsTemplate ? @"无法导入 XML" : @"无法导入 .amproj",
                        YES);
                    amproj_releaseImportTransaction(storeTransactionID, NO);
                }
                amproj_resumeQueuedImports(@"865_store_done");
            };
            void (^storeDenied)(NSError *) = ^(NSError *error) {
                NSString *reason = error.localizedDescription.length
                    ? error.localizedDescription : @"iOS 导入权限未开通";
                amproj_retryImportURL = storeTransaction.archiveURL ?: storeURL;
                amproj_retryImportName = [storeName copy];
                amproj_writeImportBreadcrumb(storeTransactionID,
                                             storeTransaction.fingerprint,
                                             @"authorization_denied",
                                             storeTransaction.source,
                                             nil, nil, reason);
                amproj_releaseImportTransaction(storeTransactionID, NO);
                amproj_debugEvent(@"import.authorization", @{
                    @"allowed": @NO,
                    @"transaction_id": storeTransactionID,
                    @"error": reason
                });
                amproj_showImportStatusForTransaction(
                    [NSString stringWithFormat:@"AMProj · 导入未开始：%@", reason],
                    YES, storeTransactionID);
                amproj_resumeQueuedImports(@"865_store_denied");
            };
#if AMPROJ_CLOUD_SYNC
            AMCloudAuthorizeFeature(@"import", nil, ^(BOOL allowed, NSError *error) {
                if (!allowed) {
                    storeDenied(error);
                    return;
                }
                dispatch_async(amproj_importInboxQueue(), ^{
                    NSString *projectTitle = nil;
                    BOOL written = amproj_write865ProjectStoreImport(
                        storeURL, storeName, storeTransactionID, &projectTitle);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        presentStoreResult(written, projectTitle);
                    });
                });
            });
#else
            dispatch_async(amproj_importInboxQueue(), ^{
                NSString *projectTitle = nil;
                BOOL written = amproj_write865ProjectStoreImport(
                    storeURL, storeName, storeTransactionID, &projectTitle);
                dispatch_async(dispatch_get_main_queue(), ^{
                    presentStoreResult(written, projectTitle);
                });
            });
#endif
            return;
        }
        if (!amproj_pendingImportQueue) {
            amproj_pendingImportQueue = [NSMutableArray array];
        }
        if (amproj_importDispatchCoolingDown && !amproj_nativeImportObservationActive &&
            !amproj_waitingForNativeImportAlert &&
            !amproj_nativeImportAlertActive && !amproj_pendingImportURL) {
            amproj_importDispatchCoolingDown = NO;
            amproj_debugEvent(@"import.cooldown_finished", @{
                @"source": @"explicit_new_package"
            });
        }
        NSString *name = originalName.length ? originalName : @"project.amproj";
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (transactionID.length && !transaction) {
            amproj_debugEvent(@"import.stale_queue_suppressed", @{
                @"transaction_id": transactionID,
                @"filename": name
            });
            return;
        }
        for (NSDictionary *queued in amproj_pendingImportQueue) {
            if (transactionID.length &&
                [queued[@"transaction_id"] isEqualToString:transactionID]) {
                amproj_debugEvent(@"import.duplicate_suppressed", @{
                    @"transaction_id": transactionID,
                    @"reason": @"queue_entry"
                });
                return;
            }
        }
        if (transactionID.length &&
            [amproj_pendingImportTransactionID isEqualToString:transactionID]) {
            amproj_debugEvent(@"import.duplicate_suppressed", @{
                @"transaction_id": transactionID,
                @"reason": @"active_entry"
            });
            return;
        }
        if (transactionID.length &&
            ([amproj_activeNativeImportTransactionID isEqualToString:transactionID] ||
             [amproj_importVerificationTransactionID isEqualToString:transactionID])) {
            amproj_debugEvent(@"import.duplicate_suppressed", @{
                @"transaction_id": transactionID,
                @"reason": [amproj_activeNativeImportTransactionID
                    isEqualToString:transactionID] ? @"native_active" : @"row_verification"
            });
            return;
        }
        if (transaction) {
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionQueued);
        }
        [amproj_pendingImportQueue addObject:@{
            @"url": URL,
            @"name": name,
            @"transaction_id": transactionID ?: @""
        }];
        amproj_debugEvent(@"import.queued", @{
            @"filename": name,
            @"transaction_id": transactionID ?: @"",
            @"queue_depth": @(amproj_pendingImportQueue.count +
                               (amproj_pendingImportURL ? 1 : 0))
        });
        amproj_resumeQueuedImports(@"package_enqueued");
    });
}

static void amproj_resumeQueuedImports(NSString *source) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"queued_import_resume");
        return;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_resumeQueuedImports(source);
        });
        return;
    }
    if (CFAbsoluteTimeGetCurrent() <
        amproj_xmlTemplateResultQuarantineUntil) {
        amproj_resumeAfterXMLResultAlert(0);
        return;
    }
    UIViewController *XMLResultAlert = amproj_xmlTemplateResultAlert;
    if (XMLResultAlert && XMLResultAlert.viewIfLoaded.window &&
        XMLResultAlert.presentingViewController) {
        amproj_resumeAfterXMLResultAlert(0);
        return;
    }
    if (amproj_xmlTemplateImportActive || amproj_importVerificationActive ||
        amproj_nativeImportObservationActive || amproj_nativeImportAlertActive ||
        amproj_waitingForNativeImportAlert) {
        return;
    }
    if (amproj_pendingImportURL) {
        AMProjImportTransaction *owner =
            amproj_importTransactionForID(amproj_pendingImportTransactionID);
        if (owner &&
            (!owner.projectTitleBaselineCaptured ||
             !owner.persistenceBaselineCaptured ||
             owner.persistenceBaselineGeneration !=
                 amproj_pendingImportGeneration)) {
            amproj_captureActivatedPackageBaselines(
                amproj_pendingImportURL, amproj_pendingImportName,
                amproj_pendingImportTransactionID);
            return;
        }
        if (AMProjNativePackageImportBridgeRequiresRestart()) {
            amproj_pauseForNativeBridgeRestart(
                amproj_pendingImportTransactionID,
                amproj_pendingImportName);
            return;
        }
        if (AMProjNativePackageImportBridgeIsBusy()) {
            amproj_debugEvent(@"import.resume_blocked", @{
                @"source": source ?: @"",
                @"reason": @"native_bridge_busy_or_poisoned"
            });
            return;
        }
        amproj_tryDispatchPendingImport(amproj_pendingImportGeneration);
        return;
    }
    if (amproj_importDispatchCoolingDown) {
        amproj_importDispatchCoolingDown = NO;
        amproj_debugEvent(@"import.cooldown_finished", @{
            @"source": source ?: @""
        });
    }
    BOOL bridgeAvailable = !AMProjNativePackageImportBridgeRequiresRestart() &&
        !AMProjNativePackageImportBridgeIsBusy();
    if (amproj_pendingImportQueue.count && bridgeAvailable) {
        amproj_activateNextPendingImport();
        if (amproj_pendingImportURL) return;
    }
    if (amproj_xmlTemplatePendingQueue.count) {
        amproj_pumpXMLTemplateImports();
        if (amproj_xmlTemplateImportActive) return;
    }
    if (amproj_pendingImportQueue.count) {
        if (AMProjNativePackageImportBridgeRequiresRestart()) {
            amproj_pauseForNativeBridgeRestart(nil, nil);
        } else {
            amproj_debugEvent(@"import.resume_blocked", @{
                @"source": source ?: @"",
                @"reason": @"native_bridge_busy_or_poisoned"
            });
        }
        return;
    }
    if (amproj_hasDeferredLaunchImportCandidates()) {
        amproj_retryDeferredLaunchImportCandidates();
    } else {
        amproj_scanLocalImportInboxes(source.length ? source : @"resume", nil);
    }
}

static BOOL amproj_isImportCommandURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || URL.isFileURL) return NO;
    NSString *scheme = URL.scheme.lowercaseString;
    NSString *host = URL.host.lowercaseString;
    return [scheme isEqualToString:@"alightmotion"] &&
        [host isEqualToString:@"amproj-import"];
}

static BOOL amproj_handleImportCommandURL(NSURL *URL, NSString *source) {
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"import_command_url");
        return NO;
    }
    if (!amproj_isImportCommandURL(URL)) return NO;

    NSString *requestID = nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL
                                              resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"request"] && item.value.length) {
            requestID = item.value;
            break;
        }
    }
    amproj_debugEvent(@"import.share_command", @{
        @"source": source ?: @"",
        @"request_id": requestID ?: @""
    });
    amproj_scanLocalImportInboxes(@"share_command", requestID);
    return YES;
}

static NSString* amproj_normalizedFilePath(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL) return nil;
    NSString *path = URL.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    path = path.stringByStandardizingPath;
    if ([path isEqualToString:@"/private/var"]) return @"/var";
    if ([path hasPrefix:@"/private/var/"]) {
        path = [path substringFromIndex:@"/private".length];
    }
    return path;
}

static BOOL amproj_URLIsInDocumentsInbox(NSURL *URL) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
    NSURL *inbox = [documents URLByAppendingPathComponent:@"Inbox" isDirectory:YES];
    NSString *inboxPath = amproj_normalizedFilePath(inbox);
    NSString *candidatePath = amproj_normalizedFilePath(URL);
    if (!inboxPath.length || !candidatePath.length) return NO;
    NSString *prefix = [inboxPath stringByAppendingString:@"/"];
    return [candidatePath hasPrefix:prefix];
}

static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult(
    NSURL *URL, NSString *source, NSDictionary *options, BOOL *prepared) {
    if (prepared) *prepared = NO;
    if (!amproj_runtimeUsesLocalImportEngine()) {
        // No non-engine build may stage a provider URL into the 862 queue or
        // invoke the private PackageImporter continuation.
        amproj_log865LegacyPathDisabled(@"incoming_project_url");
        return AMProjIncomingURLNotRecognized;
    }
    if (amproj_handleImportCommandURL(URL, source)) return AMProjIncomingURLAccepted;
    if (!amproj_isIncomingProjectURL(URL, options)) return AMProjIncomingURLNotRecognized;
    BOOL directStage = [options[@"AMProjDirectStage"] boolValue];
    BOOL preserveSource = [options[@"AMProjPreserveSource"] boolValue];
    BOOL silentErrors = [options[@"AMProjSilentErrors"] boolValue];
    if ([options[@"AMProjExplicitRetry"] boolValue]) {
        amproj_clearImportSuppression(URL,
            [options[@"AMProjOriginalFilename"] isKindOfClass:NSString.class]
                ? options[@"AMProjOriginalFilename"] : URL.lastPathComponent);
    }
    if (amproj_URLIsInDocumentsInbox(URL) &&
        ![options[@"AMProjInboxWorker"] boolValue] && !directStage) {
        amproj_debugEvent(@"import.inbox_scheduled", @{
            @"source": source ?: @"",
            @"filename": URL.lastPathComponent ?: @"",
            @"staging_sync": @NO
        });
        amproj_scanLocalImportInboxes(source.length ? source : @"documents_inbox", nil);
        return AMProjIncomingURLAccepted;
    }

    BOOL stagingSync = ![options[@"AMProjBackgroundWorker"] boolValue];
    NSString *requestedName = [options[@"AMProjOriginalFilename"]
        isKindOfClass:NSString.class] ? options[@"AMProjOriginalFilename"] : nil;
    NSString *originalName = requestedName.length ? requestedName :
        (URL.lastPathComponent ?: @"project.amproj");
    NSString *transactionID = nil;
    BOOL duplicate = NO;
    if (!amproj_claimImportTransaction(URL, originalName, source, &transactionID,
                                       &duplicate)) {
        amproj_debugEvent(@"import.duplicate_suppressed", @{
            @"source": source ?: @"",
            @"filename": originalName ?: @"",
            @"transaction_id": transactionID ?: @"",
            @"reason": duplicate ? @"provisional_key" : @"claim_failed"
        });
        // A duplicate callback must not be treated as a completed import. The
        // owner transaction will consume the Inbox source after its own claim.
        return duplicate ? AMProjIncomingURLAccepted : AMProjIncomingURLFailed;
    }
    amproj_markImportTransactionState(transactionID, AMProjImportTransactionCopying);
    AMProjImportTransaction *claimedTransaction =
        amproj_importTransactionForID(transactionID);
    AMProjImportKind importKind = amproj_importKindForURL(URL, options);
    if (importKind == AMProjImportKindXMLTemplate &&
        ![originalName.pathExtension.lowercaseString isEqualToString:@"xml"]) {
        originalName = [originalName stringByAppendingPathExtension:@"xml"];
    }
    @synchronized (amproj_importDedupeLock()) {
        claimedTransaction.kind = importKind;
        claimedTransaction.incomingURL = URL;
        claimedTransaction.incomingCleanupURL =
            [options[@"AMProjIncomingCleanupURL"] isKindOfClass:NSURL.class]
                ? options[@"AMProjIncomingCleanupURL"] : nil;
        claimedTransaction.deleteIncomingSourceOnCompletion =
            (amproj_URLIsInDocumentsInbox(URL) && !preserveSource) ||
            claimedTransaction.incomingCleanupURL != nil;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!amproj_pendingImportURL && !amproj_importVerificationActive &&
            amproj_activeNativeImportGeneration == 0) {
            AMProjImportTransaction *visibleTransaction =
                amproj_importTransactionForID(amproj_visibleStatusTransactionID);
            if (!visibleTransaction ||
                [amproj_visibleStatusTransactionID isEqualToString:transactionID]) {
                amproj_importVisibleStageRank = 0;
                amproj_visibleStatusTransactionID = [transactionID copy];
            }
        }
    });
    amproj_debugEvent(@"import.transaction_captured", @{
        @"transaction_id": transactionID ?: @"",
        @"source": source ?: @"",
        @"filename": originalName ?: @"",
        @"kind": importKind == AMProjImportKindXMLTemplate ? @"xml_template" : @"amproj_package"
    });
    amproj_debugEvent(@"import.url_received", @{
        @"source": source ?: @"",
        @"filename": originalName,
        @"file_url": @YES,
        @"extension": URL.pathExtension ?: @"",
        @"kind": importKind == AMProjImportKindXMLTemplate ? @"xml_template" : @"amproj_package"
    });
    // Provider-owned URLs are staged synchronously while their grant is valid.
    // Documents/Inbox and asCopy picker URLs reach this code on our serial worker.
    NSFileManager *manager = NSFileManager.defaultManager;
    CFAbsoluteTime stagingStarted = CFAbsoluteTimeGetCurrent();
    BOOL requestedOpenInPlace = [options[UIApplicationOpenURLOptionsOpenInPlaceKey] boolValue];
    BOOL readableBeforeScope = [manager isReadableFileAtPath:URL.path];
    BOOL alreadyScoped = [options[@"AMProjAlreadyScoped"] boolValue];
    BOOL scoped = alreadyScoped || [URL startAccessingSecurityScopedResource];
    BOOL shouldStopScope = scoped && !alreadyScoped;
    BOOL readableAfterScope = [manager isReadableFileAtPath:URL.path];
    @autoreleasepool {
        NSError *error = nil;
        NSURL *root = amproj_importCacheRoot();
        NSURL *directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                                                 isDirectory:YES];
        if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                attributes:nil error:&error]) {
            amproj_releaseImportTransaction(transactionID, NO);
            if (shouldStopScope) [URL stopAccessingSecurityScopedResource];
            amproj_debugEvent(@"import.copy", @{
                @"success": @NO,
                @"scoped": @(scoped),
                @"open_in_place": @(requestedOpenInPlace),
                @"staging_sync": @(stagingSync),
                @"readable_before_scope": @(readableBeforeScope),
                @"readable_after_scope": @(readableAfterScope),
                @"error": error.localizedDescription ?: @"Unable to create import cache"
            });
            if (!silentErrors) {
                amproj_showImportStatusForTransaction(
                    @"AMProj \u00b7 \u521b\u5efa\u5bfc\u5165\u7f13\u5b58\u5931\u8d25",
                    YES, transactionID);
                amproj_presentImportErrorForKind(
                    @"无法创建导入缓存，请检查设备剩余空间后重试。",
                    importKind, YES);
            }
            return AMProjIncomingURLFailed;
        }
        [root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

        NSURL *destination = [directory URLByAppendingPathComponent:
            amproj_importCacheFilename(originalName)];
        __block NSError *copyError = nil;
        __block BOOL copied = NO;
        __block BOOL accessorCalled = NO;
        __block BOOL coordinatedReadable = NO;
        __block uint64_t copiedBytes = 0;
        __block NSString *copyMethod = nil;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError = nil;
        @try {
            [coordinator coordinateReadingItemAtURL:URL
                                            options:NSFileCoordinatorReadingWithoutChanges
                                              error:&coordinationError
                                          byAccessor:^(NSURL *coordinatedURL) {
                accessorCalled = YES;
                coordinatedReadable = [manager isReadableFileAtPath:coordinatedURL.path];
                copied = amproj_streamCopyIncomingFile(
                    coordinatedURL, destination, &copiedBytes, &copyMethod, &copyError);
            }];
        } @catch (NSException *exception) {
            copyError = amproj_importCopyException(exception);
        } @finally {
            if (shouldStopScope) [URL stopAccessingSecurityScopedResource];
        }
        if (!copied && !copyError) {
            copyError = amproj_importFileError(
                AMProjImportFileErrorOpenSource,
                accessorCalled ? @"Unable to read the coordinated project package" :
                                 @"The File Provider did not supply the project package",
                0, coordinationError);
        }
        if (!copied) {
            amproj_releaseImportTransaction(transactionID, NO);
            [manager removeItemAtURL:directory error:nil];
            amproj_debugEvent(@"import.copy", @{
                @"success": @NO,
                @"phase": @"callback_copy",
                @"source": source ?: @"",
                @"scoped": @(scoped),
                @"open_in_place": @(requestedOpenInPlace),
                @"staging_sync": @(stagingSync),
                @"readable_before_scope": @(readableBeforeScope),
                @"readable_after_scope": @(readableAfterScope),
                @"coordinated_readable": @(coordinatedReadable),
                @"accessor_called": @(accessorCalled),
                @"duration_ms": @((CFAbsoluteTimeGetCurrent() - stagingStarted) * 1000.0),
                @"error_domain": copyError.domain ?: @"",
                @"error_code": @(copyError.code),
                @"error": copyError.localizedDescription ?: @"Unable to copy project package",
                @"underlying": [copyError.userInfo[NSUnderlyingErrorKey] localizedDescription] ?: @"",
                @"attempts": copyError.userInfo[@"copy_attempts"] ?: @[],
                @"posix_errno": copyError.userInfo[@"posix_errno"] ?: @0
            });
            BOOL providerGrantLost = readableAfterScope == NO &&
                ([copyError.domain isEqualToString:NSCocoaErrorDomain] &&
                 (copyError.code == 257 || copyError.code == 513 ||
                  copyError.code == 260 || copyError.code == 256));
            if (providerGrantLost) {
                // QQ re-delivers the same document through openURL with a
                // fresh grant; stay silent here and let that delivery import.
                amproj_noteIncomingGrantLoss(originalName,
                    importKind == AMProjImportKindXMLTemplate);
                return AMProjIncomingURLFailed;
            }
            if (!silentErrors) {
                amproj_showImportStatusForTransaction(
                    amproj_visibleImportFileError(copyError), YES, transactionID);
            }
            NSString *documentName = importKind == AMProjImportKindXMLTemplate
                ? @"XML 文件" : @"项目包";
            NSString *message = [NSString stringWithFormat:
                @"无法读取 QQ 或文件 App 提供的%@，请返回后重新打开一次。",
                documentName];
            if (!silentErrors) {
                amproj_presentImportErrorForKind(message, importKind, YES);
            }
            return AMProjIncomingURLFailed;
        }

        amproj_debugEvent(@"import.copy", @{
            @"success": @YES,
            @"phase": @"callback_copy",
            @"source": source ?: @"",
            @"scoped": @(scoped),
            @"open_in_place": @(requestedOpenInPlace),
            @"staging_sync": @(stagingSync),
            @"readable_before_scope": @(readableBeforeScope),
            @"readable_after_scope": @(readableAfterScope),
            @"coordinated_readable": @(coordinatedReadable),
            @"accessor_called": @(accessorCalled),
            @"duration_ms": @((CFAbsoluteTimeGetCurrent() - stagingStarted) * 1000.0),
            @"bytes": @(copiedBytes),
            @"method": copyMethod ?: @"unknown",
            @"bridge_filename": destination.lastPathComponent ?: @""
        });

        NSNumber *stagedSize = nil;
        [destination getResourceValue:&stagedSize forKey:NSURLFileSizeKey error:nil];
        NSString *sha256 = amproj_sha256ForFileURL(destination);
        NSString *fingerprint = sha256.length && stagedSize
            ? [NSString stringWithFormat:@"%@|%@", sha256, stagedSize.stringValue] : nil;
        BOOL duplicateContent = NO;
        if (!amproj_claimImportFingerprint(transactionID, destination, fingerprint,
                                            &duplicateContent)) {
            AMProjImportTransaction *duplicateTransaction =
                amproj_importTransactionForID(transactionID);
            amproj_debugEvent(duplicateContent ? @"import.duplicate_content"
                                                : @"import.fingerprint_failed", @{
                @"transaction_id": transactionID ?: @"",
                @"fingerprint": fingerprint ?: @"",
                @"source": source ?: @"",
                @"filename": originalName ?: @"",
                @"duplicate": @(duplicateContent)
            });
            BOOL waitingForOwner = duplicateContent &&
                duplicateTransaction.duplicateOfFingerprint.length > 0;
            if (!waitingForOwner) {
                [manager removeItemAtURL:directory error:nil];
            }
            if (duplicateContent && !waitingForOwner) {
                if (duplicateTransaction.incomingCleanupURL) {
                    [manager removeItemAtURL:duplicateTransaction.incomingCleanupURL
                                        error:nil];
                } else if (amproj_URLIsInDocumentsInbox(URL) && !preserveSource) {
                    [manager removeItemAtURL:URL error:nil];
                }
            }
            if (waitingForOwner) {
                amproj_writeImportBreadcrumb(
                    transactionID, duplicateTransaction.fingerprint,
                    @"duplicate_waiting", duplicateTransaction.source, nil, nil,
                    @"An identical package is already being imported");
                amproj_debugEvent(@"import.duplicate_suppressed", @{
                    @"transaction_id": transactionID ?: @"",
                    @"fingerprint": fingerprint ?: @"",
                    @"owner_fingerprint": duplicateTransaction.duplicateOfFingerprint ?: @"",
                    @"source": source ?: @"",
                    @"kept_for_owner_result": @YES
                });
            } else {
                amproj_releaseImportTransaction(transactionID, NO);
            }
            if (!duplicateContent && !silentErrors) {
                NSString *message = importKind == AMProjImportKindXMLTemplate
                    ? @"XML 文件无法计算 SHA-256 指纹，已停止导入。"
                    : @"项目包无法计算 SHA-256 指纹，已停止导入。";
                amproj_showImportStatusForTransaction(message, YES, transactionID);
                amproj_presentImportErrorForKind(message, importKind, YES);
            }
            // A duplicate-content callback was consumed but did not start a
            // second transaction. Keep scanning other Inbox entries.
            if (prepared) *prepared = NO;
            return duplicateContent ? AMProjIncomingURLAccepted : AMProjIncomingURLFailed;
        }
        amproj_debugEvent(@"import.fingerprint_claimed", @{
            @"transaction_id": transactionID ?: @"",
            @"fingerprint": fingerprint ?: @"",
            @"bytes": stagedSize ?: @0
        });
        amproj_markImportTransactionState(transactionID, AMProjImportTransactionValidating);
        amproj_debugEvent(@"import.route_selected", @{
            @"transaction_id": transactionID ?: @"",
            @"kind": importKind == AMProjImportKindXMLTemplate
                ? @"xml_template" : @"amproj_package"
        });
        if (importKind == AMProjImportKindXMLTemplate) {
            amproj_showImportStatusForTransaction(
                @"AMProj · 1/3 已收到 XML 文件", NO, transactionID);
            amproj_prepareCopiedXML(
                destination, directory, originalName, source, silentErrors, transactionID);
            if (prepared) *prepared = YES;
            return AMProjIncomingURLAccepted;
        }
        amproj_showImportStatusForTransaction(
            @"AMProj \u00b7 1/4 \u5df2\u6536\u5230 .amproj \u6587件",
            NO, transactionID);
        amproj_showImportStatusForTransaction(
            @"AMProj \u00b7 2/4 \u5df2\u590d\u5236\u9879\u76ee\u5305",
            NO, transactionID);
        amproj_prepareCopiedArchive(
            destination, directory, originalName, source, silentErrors, transactionID);
        if (prepared) *prepared = YES;
    }
    return AMProjIncomingURLAccepted;
}

static AMProjIncomingURLResult amproj_handleIncomingProjectURL(
    NSURL *URL, NSString *source, NSDictionary *options) {
    return amproj_handleIncomingProjectURLWithResult(URL, source, options, NULL);
}

// Every asynchronous delivery path enters through this wrapper. A malformed
// provider URL or an Objective-C exception must release only its own claim and
// must never terminate the serial inbox worker with a live transaction behind.
static AMProjIncomingURLResult amproj_handleIncomingProjectURLSafely(
    NSURL *URL, NSString *source, NSDictionary *options, BOOL *prepared) {
    if (prepared) *prepared = NO;
    @try {
        return amproj_handleIncomingProjectURLWithResult(URL, source, options, prepared);
    } @catch (NSException *exception) {
        AMProjImportKind importKind = amproj_importKindForURL(URL, options);
        NSString *name = [options[@"AMProjOriginalFilename"] isKindOfClass:NSString.class]
            ? options[@"AMProjOriginalFilename"] : URL.lastPathComponent;
        amproj_releaseImportTransactionForURL(URL, name);
        NSString *reason = exception.reason ?: @"The project package import raised an exception";
        amproj_debugEvent(@"import.exception", @{
            @"source": source ?: @"",
            @"filename": name ?: @"",
            @"exception": exception.name ?: @"",
            @"reason": reason
        });
        amproj_writeImportBreadcrumb(nil, nil, @"failed", source,
                                     nil, nil, reason);
        if (![options[@"AMProjSilentErrors"] boolValue]) {
            NSString *message = importKind == AMProjImportKindXMLTemplate
                ? @"处理 XML 文件时发生异常，缓存文件已保留；请点击重试或使用“选择 XML 文件”。"
                : @"处理项目包时发生异常，缓存包已保留；请点击重试或使用“选择项目包”。";
            amproj_presentImportErrorForKind(message, importKind, YES);
        }
        return AMProjIncomingURLFailed;
    }
}

#if AMPROJ_CLOUD_SYNC
static void amproj_importCloudPackage(NSURL *URL, NSString *filename,
                                      NSURL *cleanupURL,
                                      AMCloudImportCompletion completion) {
    if (!URL.isFileURL) {
        if (completion) completion(NO, [NSError errorWithDomain:@"com.amproj.cloud-import"
            code:1 userInfo:@{NSLocalizedDescriptionKey: @"下载项目不是本地文件"}]);
        return;
    }
    if (amproj_runtimeIsBuild865()) {
        // Build 865 feeds the downloaded package straight into the local
        // import engine. The previous openURL handoff bounced the file back
        // through LaunchServices without ever importing it.
        NSDictionary *options = @{
            @"AMProjOriginalFilename": filename.length ? filename : @"project.amproj",
            @"AMProjPreserveSource": @YES,
            @"AMProjIncomingCleanupURL": cleanupURL ?: URL
        };
        BOOL prepared = NO;
        AMProjIncomingURLResult result = amproj_handleIncomingProjectURLSafely(
            URL, @"cloud_download_865", options, &prepared);
        BOOL accepted = result == AMProjIncomingURLAccepted;
        amproj_debugEvent(@"cloud.import_865_engine", @{
            @"accepted": @(accepted),
            @"prepared": @(prepared),
            @"filename": filename ?: @"",
            @"import_completed": @NO,
            @"engine": @"local_transaction"
        });
        if (completion) {
            completion(accepted,
                       accepted ? nil :
                       [NSError errorWithDomain:@"com.amproj.cloud-import"
                                           code:3
                                       userInfo:@{NSLocalizedDescriptionKey:
                                           @"云工程未能进入本地导入队列"}]);
        }
        return;
    }
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"cloud_project_import");
        if (completion) completion(NO, [NSError errorWithDomain:@"com.amproj.cloud-import"
            code:2 userInfo:@{NSLocalizedDescriptionKey: @"当前包体不支持旧版导入链路"}]);
        return;
    }
    BOOL prepared = NO;
    NSDictionary *options = @{
        @"AMProjOriginalFilename": filename.length ? filename : @"project.amproj",
        @"AMProjPreserveSource": @YES,
        @"AMProjIncomingCleanupURL": cleanupURL ?: URL
    };
    AMProjIncomingURLResult result = amproj_handleIncomingProjectURLSafely(
        URL, @"cloud_download", options, &prepared);
    amproj_debugEvent(@"cloud.import_queued", @{
        @"accepted": @(result == AMProjIncomingURLAccepted),
        @"prepared": @(prepared),
        @"filename": filename ?: @""
    });
    if (completion) completion(result == AMProjIncomingURLAccepted,
                               result == AMProjIncomingURLAccepted ? nil :
                               [NSError errorWithDomain:@"com.amproj.cloud-import"
                                   code:3 userInfo:@{NSLocalizedDescriptionKey:
                                       @"项目包未能进入导入队列"}]);
}
#endif

static dispatch_queue_t amproj_importInboxQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.amproj.import.inbox", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString* amproj_shareAppGroupIdentifier(void) {
    id value = [NSBundle.mainBundle objectForInfoDictionaryKey:
        @"AMProjShareAppGroupIdentifier"];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

static BOOL amproj_importEntryIsOlderThan(NSURL *URL, NSTimeInterval age) {
    NSDate *modified = nil;
    if (![URL getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil] ||
        ![modified isKindOfClass:NSDate.class]) return NO;
    return -modified.timeIntervalSinceNow > age;
}

static BOOL amproj_scanDocumentsInboxNow(NSString *source) {
    if (amproj_importHasLiveTransaction()) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *documents = [manager URLsForDirectory:NSDocumentDirectory
                                        inDomains:NSUserDomainMask].firstObject;
    NSURL *inbox = [documents URLByAppendingPathComponent:@"Inbox" isDirectory:YES];
    NSArray<NSURL *> *files = [manager contentsOfDirectoryAtURL:inbox
                                    includingPropertiesForKeys:@[NSURLIsRegularFileKey,
                                                                 NSURLContentModificationDateKey]
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:nil];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        NSDate *leftDate = nil;
        NSDate *rightDate = nil;
        [left getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
        [right getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
        return [rightDate ?: [NSDate distantPast] compare:leftDate ?: [NSDate distantPast]];
    }];
    for (NSURL *file in files) {
        if (amproj_importHasLiveTransaction()) return NO;
        NSNumber *regular = nil;
        [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        NSString *extension = file.pathExtension.lowercaseString;
        if (!regular.boolValue ||
            (![extension isEqualToString:@"amproj"] &&
             ![extension isEqualToString:@"xml"])) continue;

        BOOL prepared = NO;
        AMProjIncomingURLResult result = amproj_handleIncomingProjectURLSafely(
            file, source.length ? source : @"documents_inbox",
            @{
                @"AMProjInboxWorker": @YES,
                @"AMProjBackgroundWorker": @YES
            }, &prepared);
        if (prepared) {
            amproj_debugEvent(@"import.inbox_consumed", @{
                @"kind": @"documents",
                @"filename": file.lastPathComponent ?: @"",
                @"result": @(result)
            });
            return YES;
        }
        if (result == AMProjIncomingURLFailed) {
            amproj_debugEvent(@"import.inbox_failed", @{
                @"filename": file.lastPathComponent ?: @""
            });
            // Keep scanning later candidates; the failed source is suppressed
            // briefly by its transaction tombstone and can be retried explicitly.
            continue;
        }
    }
    return NO;
}

static NSDictionary* amproj_shareRequestDescriptor(NSURL *descriptorURL) {
    NSNumber *size = nil;
    if (![descriptorURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil] ||
        size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > 64 * 1024) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:descriptorURL
                                         options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 64 * 1024) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:nil error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL amproj_scanShareInboxNow(NSString *source, NSString *requestedID) {
    NSString *groupID = amproj_shareAppGroupIdentifier();
    if (!groupID.length) return NO;
    if (amproj_importHasLiveTransaction()) return NO;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *container = [manager containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!container) {
        amproj_debugEvent(@"import.share_inbox", @{
            @"success": @NO,
            @"app_group": groupID,
            @"error": @"container_unavailable"
        });
        if (requestedID.length) {
            amproj_presentImportError(
                @"Share Extension 的 App Group 容器不可用。请改用“用其他应用打开 → Alight Motion”，或点击“选择项目包”。");
        }
        return NO;
    }

    NSURL *root = [container URLByAppendingPathComponent:@"AMProjShareInbox"
                                             isDirectory:YES];
    NSArray<NSURL *> *requests = [manager contentsOfDirectoryAtURL:root
                                       includingPropertiesForKeys:@[
                                           NSURLIsDirectoryKey,
                                           NSURLContentModificationDateKey
                                       ]
                                                          options:NSDirectoryEnumerationSkipsHiddenFiles
                                                            error:nil];
    requests = [requests sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *left, NSURL *right) {
        NSDate *leftDate = nil;
        NSDate *rightDate = nil;
        [left getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
        [right getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
        return [rightDate ?: [NSDate distantPast]
            compare:leftDate ?: [NSDate distantPast]];
    }];
    BOOL matchedRequestedID = !requestedID.length;
    for (NSURL *requestDirectory in requests) {
        if (amproj_importHasLiveTransaction()) return NO;
        NSNumber *isDirectory = nil;
        [requestDirectory getResourceValue:&isDirectory
                                    forKey:NSURLIsDirectoryKey error:nil];
        if (!isDirectory.boolValue) continue;
        NSString *directoryID = requestDirectory.lastPathComponent;
        if (amproj_importEntryIsOlderThan(requestDirectory, 24.0 * 60.0 * 60.0)) {
            [manager removeItemAtURL:requestDirectory error:nil];
            continue;
        }
        if (requestedID.length && ![directoryID isEqualToString:requestedID]) continue;
        matchedRequestedID = YES;

        NSURL *descriptorURL = [requestDirectory URLByAppendingPathComponent:@"request.plist"];
        NSURL *payloadURL = [requestDirectory URLByAppendingPathComponent:@"payload.amproj"];
        NSDictionary *descriptor = amproj_shareRequestDescriptor(descriptorURL);
        NSNumber *protocolVersion = [descriptor[@"protocol_version"]
            isKindOfClass:NSNumber.class] ? descriptor[@"protocol_version"] : nil;
        NSString *descriptorID = [descriptor[@"request_id"]
            isKindOfClass:NSString.class] ? descriptor[@"request_id"] : nil;
        NSString *originalName = [descriptor[@"original_name"]
            isKindOfClass:NSString.class] ? descriptor[@"original_name"] : nil;
        id createdAt = descriptor[@"created_at"];
        NSNumber *declaredSize = [descriptor[@"size"]
            isKindOfClass:NSNumber.class] ? descriptor[@"size"] : nil;
        NSNumber *actualSize = nil;
        BOOL hasPayloadSize = [payloadURL getResourceValue:&actualSize
                                                    forKey:NSURLFileSizeKey error:nil];
        const unsigned long long maximumSize = 512ULL * 1024ULL * 1024ULL;
        NSString *originalExtension = originalName.pathExtension.lowercaseString;
        BOOL supportedShareExtensionName =
            [originalExtension isEqualToString:@"amproj"] ||
            [originalExtension isEqualToString:@"xml"];
        BOOL descriptorValid = protocolVersion.integerValue == 1 &&
            descriptorID.length && [descriptorID isEqualToString:directoryID] &&
            originalName.length &&
            supportedShareExtensionName &&
            ([createdAt isKindOfClass:NSDate.class] ||
             [createdAt isKindOfClass:NSNumber.class]) &&
            declaredSize.unsignedLongLongValue > 0 &&
            declaredSize.unsignedLongLongValue <= maximumSize &&
            hasPayloadSize &&
            actualSize.unsignedLongLongValue == declaredSize.unsignedLongLongValue;
        if (!descriptorValid) {
            amproj_debugEvent(@"import.share_request", @{
                @"success": @NO,
                @"request_id": directoryID ?: @"",
                @"error": @"invalid_descriptor_or_payload",
                @"extension": originalExtension ?: @""
            });
            if (requestedID.length) {
                amproj_presentImportError(
                    @"Share Extension 提供的请求描述或 payload.amproj 不完整。请重新分享，或点击“选择项目包”。");
            }
            continue;
        }

        BOOL prepared = NO;
        NSDictionary *options = @{
            @"AMProjOriginalFilename": originalName,
            @"AMProjDeleteInvalidSource": @YES,
            @"AMProjBackgroundWorker": @YES,
            @"AMProjIncomingCleanupURL": requestDirectory
        };
        AMProjIncomingURLResult result = amproj_handleIncomingProjectURLSafely(
            payloadURL, source.length ? source : @"share_inbox", options, &prepared);
        amproj_debugEvent(@"import.share_request", @{
            @"success": @(prepared),
            @"request_id": directoryID ?: @"",
            @"filename": originalName,
            @"bytes": actualSize ?: @0,
            @"result": @(result)
        });
        // Only a newly claimed transaction (or an explicitly requested share
        // request) owns this scan turn. Duplicate-content suppression must not
        // starve another independent request in the same inbox.
        if (prepared || requestedID.length) return YES;
    }

    if (!matchedRequestedID) {
        amproj_debugEvent(@"import.share_request", @{
            @"success": @NO,
            @"request_id": requestedID ?: @"",
            @"error": @"request_not_found"
        });
        amproj_presentImportError(
            @"没有找到 Share Extension 传递的项目包。请返回 QQ 重试，或点击“选择项目包”。");
    }
    return NO;
}

static void amproj_scanLocalImportInboxes(NSString *source, NSString *requestID) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        // Builds without the local engine must not consume Inbox files; AM
        // owns document delivery there.
        amproj_log865LegacyPathDisabled(@"local_import_inbox_scan");
        return;
    }
    NSString *sourceSnapshot = [source copy] ?: @"lifecycle_scan";
    NSString *requestSnapshot = [requestID copy];
    BOOL schedule = NO;
    @synchronized (amproj_importDedupeLock()) {
        if (amproj_importScanScheduled) {
            if (requestSnapshot.length) amproj_pendingScanRequestID = requestSnapshot;
            if (sourceSnapshot.length) amproj_pendingScanSource = sourceSnapshot;
            amproj_debugEvent(@"import.scan_coalesced", @{
                @"source": sourceSnapshot,
                @"request_id": requestSnapshot ?: @""
            });
        } else {
            amproj_importScanScheduled = YES;
            schedule = YES;
        }
    }
    if (!schedule) return;
    dispatch_async(amproj_importInboxQueue(), ^{
        @autoreleasepool {
            NSString *currentSource = sourceSnapshot;
            NSString *currentRequest = requestSnapshot;
            NSString *retrySource = nil;
            NSString *retryRequest = nil;
            @try {
                BOOL keepGoing = YES;
                do {
                    if (currentRequest.length) {
                        // A URL command names one Share Extension request; do
                        // not let an older Documents/Inbox item consume this
                        // lifecycle turn first.
                        (void)amproj_scanShareInboxNow(currentSource, currentRequest);
                    } else if (!amproj_scanDocumentsInboxNow(currentSource)) {
                        (void)amproj_scanShareInboxNow(currentSource, nil);
                    }
                    @synchronized (amproj_importDedupeLock()) {
                        currentSource = amproj_pendingScanSource;
                        currentRequest = amproj_pendingScanRequestID;
                        amproj_pendingScanSource = nil;
                        amproj_pendingScanRequestID = nil;
                        keepGoing = currentSource.length || currentRequest.length;
                        if (!keepGoing) amproj_importScanScheduled = NO;
                    }
                } while (keepGoing);
            } @catch (NSException *exception) {
                amproj_debugEvent(@"import.scan_exception", @{
                    @"name": exception.name ?: @"",
                    @"reason": exception.reason ?: @""
                });
                @synchronized (amproj_importDedupeLock()) {
                    retrySource = amproj_pendingScanSource.length
                        ? amproj_pendingScanSource : currentSource;
                    retryRequest = amproj_pendingScanRequestID.length
                        ? amproj_pendingScanRequestID : currentRequest;
                    amproj_pendingScanSource = nil;
                    amproj_pendingScanRequestID = nil;
                    amproj_importScanScheduled = NO;
                }
            }
            if (retrySource.length || retryRequest.length) {
                amproj_scanLocalImportInboxes(
                    retrySource.length ? retrySource : @"scan_exception_retry",
                    retryRequest);
            }
        }
    });
}

static void amproj_retryDeferredLaunchImportCandidates(void) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"deferred_launch_import");
        return;
    }
    NSArray<NSDictionary *> *candidates = nil;
    @synchronized (amproj_importDedupeLock()) {
        candidates = [amproj_deferredLaunchImportCandidates copy] ?: @[];
        [amproj_deferredLaunchImportCandidates removeAllObjects];
    }
    if (!candidates.count) return;

    __block BOOL scheduleDelayedRetry = NO;
    const NSUInteger maxLaunchRetryCount = 1;
    dispatch_async(amproj_importInboxQueue(), ^{
        for (NSUInteger index = 0; index < candidates.count; index++) {
            @autoreleasepool {
                if (amproj_importHasLiveTransaction()) {
                    // Keep launch candidates that were not reached. The first
                    // package owns the serial import turn; resumeQueuedImports
                    // will call this function again after it reaches a
                    // terminal state.
                    NSArray<NSDictionary *> *remaining =
                        [candidates subarrayWithRange:NSMakeRange(index,
                                                                  candidates.count - index)];
                    @synchronized (amproj_importDedupeLock()) {
                        if (!amproj_deferredLaunchImportCandidates) {
                            amproj_deferredLaunchImportCandidates = [NSMutableArray array];
                        }
                        for (NSDictionary *pending in remaining) {
                            NSString *key = [pending[@"key"] isKindOfClass:NSString.class]
                                ? pending[@"key"] : nil;
                            BOOL alreadyQueued = NO;
                            for (NSDictionary *existing in amproj_deferredLaunchImportCandidates) {
                                if (key.length && [existing[@"key"] isEqualToString:key]) {
                                    alreadyQueued = YES;
                                    break;
                                }
                            }
                            if (!alreadyQueued) {
                                [amproj_deferredLaunchImportCandidates addObject:pending];
                            }
                        }
                    }
                    amproj_debugEvent(@"import.launch_candidates_deferred", @{
                        @"remaining": @(remaining.count)
                    });
                    break;
                }
                NSDictionary *candidate = candidates[index];
                NSURL *URL = [candidate[@"url"] isKindOfClass:NSURL.class]
                    ? candidate[@"url"] : nil;
                NSString *source = [candidate[@"source"] isKindOfClass:NSString.class]
                    ? candidate[@"source"] : @"deferred_launch";
                if (!URL) continue;
                if ([candidate[@"command"] boolValue]) {
                    BOOL handled = amproj_handleImportCommandURL(
                        URL, [source stringByAppendingString:@"_retry"]);
                    amproj_debugEvent(@"import.launch_candidate_retry", @{
                        @"source": source,
                        @"command": @YES,
                        @"handled": @(handled)
                    });
                    continue;
                }

                NSMutableDictionary *options = [candidate[@"options"]
                    isKindOfClass:NSDictionary.class]
                    ? [candidate[@"options"] mutableCopy]
                    : [NSMutableDictionary dictionary];
                options[@"AMProjDirectStage"] = @YES;
                options[@"AMProjBackgroundWorker"] = @YES;
                BOOL launchStagingFailed =
                    [candidate[@"launch_staging_failed"] boolValue];
                NSUInteger retryCount =
                    [candidate[@"launch_retry_count"] unsignedIntegerValue];
                NSString *key = [candidate[@"key"] isKindOfClass:NSString.class]
                    ? candidate[@"key"] : nil;
                // Give File Provider one post-startup window before showing an
                // error. The second failure remains visible and offers picker fallback.
                options[@"AMProjSilentErrors"] =
                    @(launchStagingFailed && retryCount < maxLaunchRetryCount);
                // The first real copy failure intentionally leaves a short
                // provisional tombstone to absorb duplicate lifecycle callbacks.
                // A queued retry is the owner-requested retry, so clear that
                // tombstone before the second attempt instead of accepting it as
                // a completed duplicate.
                if (launchStagingFailed && retryCount > 0) {
                    options[@"AMProjExplicitRetry"] = @YES;
                }
                if (amproj_URLIsInDocumentsInbox(URL)) {
                    options[@"AMProjInboxWorker"] = @YES;
                }
                BOOL prepared = NO;
                AMProjIncomingURLResult result =
                    amproj_handleIncomingProjectURLSafely(
                        URL, [source stringByAppendingString:@"_activation_retry"],
                        options, &prepared);
                amproj_debugEvent(@"import.launch_candidate_retry", @{
                    @"source": source,
                    @"command": @NO,
                    @"result": @(result),
                    @"prepared": @(prepared),
                    @"filename": URL.lastPathComponent ?: @"",
                    @"launch_staged": @([candidate[@"launch_staged"] boolValue]),
                    @"launch_staging_failed": @(launchStagingFailed),
                    @"stage_error": candidate[@"launch_stage_error"] ?: @""
                });
                if (result == AMProjIncomingURLFailed && launchStagingFailed) {
                    if (retryCount >= maxLaunchRetryCount) {
                        @synchronized (amproj_importDedupeLock()) {
                            for (NSInteger candidateIndex =
                                     (NSInteger)amproj_deferredLaunchImportCandidates.count - 1;
                                 candidateIndex >= 0; candidateIndex--) {
                                NSDictionary *existing =
                                    amproj_deferredLaunchImportCandidates[(NSUInteger)candidateIndex];
                                if ([existing[@"key"] isEqual:key]) {
                                    [amproj_deferredLaunchImportCandidates
                                        removeObjectAtIndex:(NSUInteger)candidateIndex];
                                }
                            }
                        }
                        amproj_debugEvent(@"import.launch_candidate_exhausted", @{
                            @"filename": URL.lastPathComponent ?: @"",
                            @"retry_count": @(retryCount),
                            @"max_retries": @(maxLaunchRetryCount)
                        });
                        continue;
                    }
                    NSMutableDictionary *retryCandidate = [candidate mutableCopy];
                    retryCandidate[@"launch_retry_count"] = @(retryCount + 1);
                    BOOL alreadyQueued = NO;
                    @synchronized (amproj_importDedupeLock()) {
                        for (NSDictionary *existing in amproj_deferredLaunchImportCandidates) {
                            if (key.length && [existing[@"key"] isEqualToString:key]) {
                                alreadyQueued = YES;
                                break;
                            }
                        }
                        if (!alreadyQueued) {
                            [amproj_deferredLaunchImportCandidates addObject:retryCandidate];
                        }
                    }
                    if (!alreadyQueued && retryCount == 0) {
                        scheduleDelayedRetry = YES;
                    }
                    amproj_debugEvent(@"import.launch_candidate_requeued", @{
                        @"filename": URL.lastPathComponent ?: @"",
                        @"retry_count": @(retryCount + 1),
                        @"already_queued": @(alreadyQueued)
                    });
                }
            }
        }
        if (scheduleDelayedRetry) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (amproj_hasDeferredLaunchImportCandidates()) {
                    amproj_debugEvent(@"import.launch_candidate_delayed_retry", @{
                        @"delay_ms": @2000
                    });
                    amproj_retryDeferredLaunchImportCandidates();
                }
            });
        }
    });
}

static NSDictionary* amproj_deferredLaunchCandidateForURL(NSURL *URL) {
    NSString *key = amproj_normalizedFilePath(URL) ?: URL.absoluteString ?: @"";
    if (!key.length) return nil;
    @synchronized (amproj_importDedupeLock()) {
        for (NSDictionary *candidate in amproj_deferredLaunchImportCandidates) {
            if ([candidate[@"key"] isEqualToString:key]) {
                return [candidate copy];
            }
        }
    }
    return nil;
}

static BOOL amproj_deferredLaunchCandidateWasStaged(NSURL *URL) {
    return [[amproj_deferredLaunchCandidateForURL(URL)
        objectForKey:@"launch_staged"] boolValue];
}

static BOOL amproj_deferredLaunchCandidateNeedsRestaging(NSURL *URL) {
    return [[amproj_deferredLaunchCandidateForURL(URL)
        objectForKey:@"launch_staging_failed"] boolValue];
}

static void amproj_removeFailedDeferredLaunchCandidateForURL(NSURL *URL,
                                                              NSString *source) {
    NSString *key = amproj_normalizedFilePath(URL) ?: URL.absoluteString ?: @"";
    if (!key.length) return;
    BOOL removed = NO;
    @synchronized (amproj_importDedupeLock()) {
        for (NSInteger index =
                 (NSInteger)amproj_deferredLaunchImportCandidates.count - 1;
             index >= 0; index--) {
            NSDictionary *candidate =
                amproj_deferredLaunchImportCandidates[(NSUInteger)index];
            if ([candidate[@"key"] isEqualToString:key] &&
                [candidate[@"launch_staging_failed"] boolValue]) {
                [amproj_deferredLaunchImportCandidates
                    removeObjectAtIndex:(NSUInteger)index];
                removed = YES;
            }
        }
    }
    if (removed) {
        amproj_debugEvent(@"import.launch_failed_candidate_consumed", @{
            @"source": source ?: @"",
            @"filename": URL.lastPathComponent ?: @""
        });
    }
}

static NSURL *amproj_stagePublic865ProjectURL(
    NSURL *URL, NSString *source, NSDictionary *options,
    BOOL securityScopeAlreadyActive, NSError *__autoreleasing *error) {
    if (!amproj_runtimeUsesPublic865ImportHooks() ||
        !amproj_isIncomingProjectURL(URL, options)) {
        return nil;
    }
    if (amproj_runtimeUsesLocalImportEngine()) {
        // The local import engine owns the synchronous copy while the system
        // callback's security scope is valid. Staging a second handoff copy
        // here would double every large download, so report the engine route
        // and stage nothing.
        amproj_logCriticalEvent(@"import.865_public_stage_skipped_for_engine", @{
            @"source": source ?: @"public_document_callback",
            @"filename": URL.lastPathComponent ?: @""
        });
        return nil;
    }
    NSString *filename = [options[@"AMProjOriginalFilename"]
        isKindOfClass:NSString.class] ? options[@"AMProjOriginalFilename"]
                                      : URL.lastPathComponent;
    NSURL *stagedURL = nil;
    NSError *reportedError = nil;
    if (error) {
        stagedURL = AMProjV865ProjectFlowStageIncomingDocument(
            URL, filename, source.length ? source : @"public_document_callback",
            securityScopeAlreadyActive, error);
        reportedError = *error;
    } else {
        __autoreleasing NSError *localError = nil;
        stagedURL = AMProjV865ProjectFlowStageIncomingDocument(
            URL, filename, source.length ? source : @"public_document_callback",
            securityScopeAlreadyActive, &localError);
        reportedError = localError;
    }
    amproj_logCriticalEvent(@"import.865_public_stage", @{
        @"source": source ?: @"public_document_callback",
        @"filename": filename ?: @"",
        @"staged": @(stagedURL != nil),
        @"managed_source": @(AMProjV865ProjectFlowIsManagedStagedURL(URL)),
        @"security_scope": @(securityScopeAlreadyActive),
        @"error": reportedError.localizedDescription ?: @""
    });
    return stagedURL;
}

static BOOL amproj_captureSystemProjectURL(NSURL *URL, NSString *source,
                                           NSDictionary *systemOptions) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        // Returning NO preserves the original AppDelegate/SceneDelegate
        // callback and prevents a second consumer from touching the URL.
        amproj_log865LegacyPathDisabled(@"system_project_url_capture");
        return NO;
    }
    // Build 865 consumes recognized project documents in the plugin's own
    // transaction engine. Alight Motion's original openURL handler only offers
    // the online import page for XML and does nothing for .amproj, so the
    // callback must not be forwarded once the engine claimed the file.
    if (!amproj_isIncomingProjectURL(URL, systemOptions)) return NO;
    NSMutableDictionary *options = systemOptions
        ? [systemOptions mutableCopy] : [NSMutableDictionary dictionary];
    options[@"AMProjDirectStage"] = @YES;
    BOOL stableInboxURL = amproj_URLIsInDocumentsInbox(URL);
    BOOL heldSecurityScope = stableInboxURL ? NO : [URL startAccessingSecurityScopedResource];
    // File Provider grants can be valid only for the duration of this callback.
    // Copy provider-owned files synchronously; stable Documents/Inbox files can
    // safely move to the serial worker.
    BOOL copyOffMainThread = stableInboxURL;
    if (copyOffMainThread) options[@"AMProjBackgroundWorker"] = @YES;
    if (stableInboxURL) options[@"AMProjInboxWorker"] = @YES;
    if (heldSecurityScope) options[@"AMProjAlreadyScoped"] = @YES;
    AMProjImportKind importKind = amproj_importKindForURL(URL, options);

    amproj_logCriticalEvent(@"import.capture", @{
        @"source": source ?: @"system_callback",
        @"extension": URL.pathExtension.lowercaseString ?: @"",
        @"scheme": URL.scheme ?: @"",
        @"inbox": @(stableInboxURL),
        @"security_scope": @(heldSecurityScope),
        @"kind": importKind == AMProjImportKindXMLTemplate ? @"xml" : @"amproj"
    });

    NSString *sourceSnapshot = [source copy] ?: @"system_callback";
    NSDictionary *optionsSnapshot = [options copy];
    void (^capture)(void) = ^{
        AMProjIncomingURLResult result = AMProjIncomingURLFailed;
        BOOL prepared = NO;
        NSString *exceptionName = @"";
        NSString *exceptionReason = @"";
        @try {
            result = amproj_handleIncomingProjectURLWithResult(
                URL, sourceSnapshot, optionsSnapshot, &prepared);
        } @catch (NSException *exception) {
            exceptionName = exception.name ?: @"";
            exceptionReason = exception.reason ?: @"";
            NSString *incomingName = [optionsSnapshot[@"AMProjOriginalFilename"]
                isKindOfClass:NSString.class] ? optionsSnapshot[@"AMProjOriginalFilename"]
                                               : URL.lastPathComponent;
            amproj_releaseImportTransactionForURL(URL, incomingName);
            NSString *message = importKind == AMProjImportKindXMLTemplate
                ? @"处理系统提供的 XML 文件时发生异常，请使用“选择 XML 文件”重试。"
                : @"处理系统提供的项目包时发生异常，请使用“选择项目包”重试。";
            amproj_presentImportErrorForKind(message, importKind, YES);
        } @finally {
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        }
        if (prepared) {
            amproj_removeFailedDeferredLaunchCandidateForURL(URL, sourceSnapshot);
        }
        amproj_debugEvent(@"import.system_capture", @{
            @"source": sourceSnapshot,
            @"filename": URL.lastPathComponent ?: @"",
            @"result": @(result),
            @"prepared": @(prepared),
            @"security_scope": @(heldSecurityScope),
            @"stable_inbox": @(stableInboxURL),
            @"background_copy": @(copyOffMainThread),
            @"exception": exceptionName,
            @"exception_reason": exceptionReason,
            @"consumed": @YES
        });
    };
    if (copyOffMainThread) {
        dispatch_async(amproj_importInboxQueue(), capture);
    } else {
        capture();
    }
    // A recognized package is consumed even when copying fails. AM's original
    // AppDelegate route reports success but only forwards media/font/SVG files.
    return YES;
}

static BOOL hooked_applicationOpenURL(id self, SEL _cmd, UIApplication *application,
                                      NSURL *URL, NSDictionary *options) {
    amproj_logCriticalEvent(@"import.open_url_callback", @{
        @"delegate": NSStringFromClass([self class]) ?: @"",
        @"extension": URL.pathExtension.lowercaseString ?: @"",
        @"scheme": URL.scheme ?: @""
    });
    if (amproj_handleImportCommandURL(URL, @"application_open_url_command")) return YES;
    BOOL public865Project = amproj_runtimeUsesPublic865ImportHooks() &&
        amproj_isIncomingProjectURL(URL, options);
    BOOL heldSecurityScope = public865Project &&
        !AMProjV865ProjectFlowIsManagedStagedURL(URL)
        ? [URL startAccessingSecurityScopedResource] : NO;
    NSError *stageError = nil;
    NSURL *stagedURL = public865Project
        ? amproj_stagePublic865ProjectURL(
            URL, @"application_open_url", options, heldSecurityScope, &stageError)
        : nil;
    if (amproj_captureSystemProjectURL(URL, @"application_open_url", options)) {
        if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        return YES;
    }
    IMP original = amproj_openURLForwardDepth
        ? amproj_originalHookForReceiverSkippingExact(
              amproj_openURLHooks, sizeof(amproj_openURLHooks) / sizeof(amproj_openURLHooks[0]), self)
        : amproj_originalHookForReceiver(
              amproj_openURLHooks, sizeof(amproj_openURLHooks) / sizeof(amproj_openURLHooks[0]), self);
    if (!original && amproj_openURLForwardDepth &&
        amproj_nativeAppDelegateOpenURLIMP != (IMP)hooked_applicationOpenURL) {
        original = amproj_nativeAppDelegateOpenURLIMP;
    }
    BOOL nativeHandled = NO;
    BOOL forwarded = NO;
    if (original && original != (IMP)hooked_applicationOpenURL) {
        amproj_openURLForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationOpenURLIMP)original)(
                self, _cmd, application, URL, options);
            forwarded = YES;
        } @finally {
            amproj_openURLForwardDepth -= 1;
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        }
    } else if (heldSecurityScope) {
        [URL stopAccessingSecurityScopedResource];
    }
    if (public865Project) {
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            stagedURL ?: URL, @"application_open_url", forwarded);
        // A broker-created staged URL re-enters this hook when openURL is
        // used for the handoff. Its completion owns the single retry notice;
        // showing one here would race and replace that broker.
        if (stagedURL && !nativeHandled &&
            !AMProjV865ProjectFlowIsManagedStagedURL(URL)) {
            AMProjV865ProjectFlowPresentPendingNotice(
                stagedURL, stageError ? @"application_open_url_stage_error"
                                      : @"application_open_url_declined");
        }
    }
    amproj_debugEvent(@"import.native_initial", @{
        @"source": @"application_open_url",
        @"recognized": @(public865Project),
        @"accepted": @(nativeHandled),
        @"has_original": @(original != NULL),
        @"staged": @(stagedURL != nil),
        @"stage_error": stageError.localizedDescription ?: @""
    });
    return nativeHandled;
}

static NSURL* amproj_projectURLFromUserActivity(NSUserActivity *activity) {
    NSURL *webpageURL = activity.webpageURL;
    if (webpageURL.isFileURL) return webpageURL;
    for (id value in activity.userInfo.allValues) {
        if ([value isKindOfClass:NSURL.class] && [(NSURL *)value isFileURL]) {
            return value;
        }
        if ([value isKindOfClass:NSString.class]) {
            NSURL *candidate = [NSURL URLWithString:value];
            if (candidate.isFileURL) return candidate;
        }
    }
    return nil;
}

static NSDictionary* amproj_projectOptionsFromUserActivity(
    NSUserActivity *activity) {
    NSString *activityType = activity.activityType;
    return activityType.length
        ? @{@"AMProjUserActivityType": activityType}
        : nil;
}

// UIKit publicly exposes the nested user-activity launch-options dictionary.
// A few provider versions have also delivered a top-level compatibility key;
// keep that shape string-based so the dylib does not depend on an undeclared
// UIApplicationLaunchOptionsUserActivityKey symbol.
static NSString *const kAMProjLaunchOptionsUserActivityKey =
    @"UIApplicationLaunchOptionsUserActivityKey";

static NSDictionary* amproj_stageLaunchImportCandidate(
    NSURL *URL, NSString *source, NSDictionary *options) {
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL ||
        amproj_URLIsInDocumentsInbox(URL)) {
        return nil;
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *originalName = URL.lastPathComponent.length
        ? URL.lastPathComponent : @"project.amproj";
    NSURL *root = amproj_importCacheRoot();
    NSURL *directory = [root URLByAppendingPathComponent:
        [@"Launch-" stringByAppendingString:NSUUID.UUID.UUIDString]
                                         isDirectory:YES];
    NSURL *destination = [directory URLByAppendingPathComponent:
        amproj_importCacheFilename(originalName)];
    NSError *directoryError = nil;
    if (![manager createDirectoryAtURL:directory
           withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        amproj_debugEvent(@"import.launch_stage", @{
            @"success": @NO,
            @"source": source ?: @"",
            @"filename": originalName,
            @"phase": @"create_private_cache",
            @"error": directoryError.localizedDescription ?: @"Unable to create launch cache"
        });
        return @{
            @"launch_staging_failed": @YES,
            @"launch_stage_error": directoryError.localizedDescription ?: @"Unable to create launch cache"
        };
    }
    [root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    BOOL readableBeforeScope = [manager isReadableFileAtPath:URL.path];
    BOOL scoped = [URL startAccessingSecurityScopedResource];
    BOOL readableAfterScope = [manager isReadableFileAtPath:URL.path];
    __block BOOL accessorCalled = NO;
    __block BOOL copied = NO;
    __block uint64_t copiedBytes = 0;
    __block NSString *copyMethod = nil;
    __block NSError *copyError = nil;
    NSError *coordinationError = nil;
    NSFileCoordinator *coordinator =
        [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    @try {
        [coordinator coordinateReadingItemAtURL:URL
                                        options:NSFileCoordinatorReadingWithoutChanges
                                          error:&coordinationError
                                     byAccessor:^(NSURL *coordinatedURL) {
            accessorCalled = YES;
            copied = amproj_streamCopyIncomingFile(
                coordinatedURL, destination, &copiedBytes, &copyMethod, &copyError);
        }];
        if (!copied) {
            [manager removeItemAtURL:destination error:nil];
            amproj_removeIncomingPartials(destination);
            copied = amproj_streamCopyIncomingFile(
                URL, destination, &copiedBytes, &copyMethod, &copyError);
        }
    } @catch (NSException *exception) {
        copyError = amproj_importCopyException(exception);
    } @finally {
        if (scoped) [URL stopAccessingSecurityScopedResource];
    }

    NSError *finalError = copyError ?: coordinationError;
    amproj_debugEvent(@"import.launch_stage", @{
        @"success": @(copied),
        @"source": source ?: @"",
        @"filename": originalName,
        @"staging_sync": @YES,
        @"security_scope": @(scoped),
        @"readable_before_scope": @(readableBeforeScope),
        @"readable_after_scope": @(readableAfterScope),
        @"accessor_called": @(accessorCalled),
        @"bytes": @(copiedBytes),
        @"method": copyMethod ?: @"",
        @"duration_ms": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
        @"error": copied ? @"" : (finalError.localizedDescription ?: @"Unable to stage launch document")
    });
    if (!copied) {
        [manager removeItemAtURL:directory error:nil];
        return @{
            @"launch_staging_failed": @YES,
            @"launch_stage_error": finalError.localizedDescription ?: @"Unable to stage launch document"
        };
    }

    NSMutableDictionary *stagedOptions = options
        ? [options mutableCopy] : [NSMutableDictionary dictionary];
    stagedOptions[@"AMProjOriginalFilename"] = originalName;
    stagedOptions[@"AMProjIncomingCleanupURL"] = directory;
    stagedOptions[@"AMProjPreserveSource"] = @YES;
    return @{
        @"url": destination,
        @"options": [stagedOptions copy],
        @"launch_staged": @YES,
        @"launch_staging_failed": @NO
    };
}

static void amproj_recordDeferredLaunchCandidate(NSURL *URL,
                                                  NSString *source,
                                                  NSDictionary *options) {
    BOOL command = amproj_isImportCommandURL(URL);
    if (!command && !amproj_isIncomingProjectURL(URL, options)) return;
    NSString *key = amproj_normalizedFilePath(URL) ?: URL.absoluteString ?: @"";
    if (!key.length) return;
    @synchronized (amproj_importDedupeLock()) {
        if (!amproj_deferredLaunchImportCandidates) {
            amproj_deferredLaunchImportCandidates = [NSMutableArray array];
        }
        for (NSDictionary *candidate in amproj_deferredLaunchImportCandidates) {
            if ([candidate[@"key"] isEqualToString:key] &&
                ![candidate[@"launch_staging_failed"] boolValue]) {
                return;
            }
        }
    }
    NSDictionary *stage = command ? nil :
        amproj_stageLaunchImportCandidate(URL, source, options);
    NSURL *candidateURL = [stage[@"url"] isKindOfClass:NSURL.class]
        ? stage[@"url"] : URL;
    NSDictionary *candidateOptions = [stage[@"options"] isKindOfClass:NSDictionary.class]
        ? stage[@"options"] : (options ?: @{});
    BOOL launchStaged = [stage[@"launch_staged"] boolValue];
    BOOL launchStagingFailed = [stage[@"launch_staging_failed"] boolValue];
    NSDictionary *newCandidate = @{
        @"url": candidateURL,
        @"key": key,
        @"source": source ?: @"application_did_finish",
        @"options": candidateOptions,
        @"command": @(command),
        @"launch_staged": @(launchStaged),
        @"launch_staging_failed": @(launchStagingFailed),
        @"launch_stage_error": stage[@"launch_stage_error"] ?: @""
    };
    NSDictionary *discardedCandidate = nil;
    @synchronized (amproj_importDedupeLock()) {
        NSUInteger existingIndex = NSNotFound;
        for (NSUInteger index = 0;
             index < amproj_deferredLaunchImportCandidates.count; index++) {
            NSDictionary *candidate = amproj_deferredLaunchImportCandidates[index];
            if ([candidate[@"key"] isEqualToString:key]) {
                existingIndex = index;
                break;
            }
        }
        if (existingIndex == NSNotFound) {
            [amproj_deferredLaunchImportCandidates addObject:newCandidate];
        } else {
            NSDictionary *existingCandidate =
                amproj_deferredLaunchImportCandidates[existingIndex];
            BOOL existingStaged =
                [existingCandidate[@"launch_staged"] boolValue];
            // The private copy is the durable launch capability. Whichever
            // concurrent callback obtains it must win over an expired URL or
            // a failed staging attempt, independent of completion order.
            if (launchStaged && !existingStaged) {
                amproj_deferredLaunchImportCandidates[existingIndex] = newCandidate;
                discardedCandidate = existingCandidate;
            } else {
                discardedCandidate = newCandidate;
            }
        }
    }
    if ([discardedCandidate[@"launch_staged"] boolValue]) {
        NSDictionary *discardedOptions = [discardedCandidate[@"options"]
            isKindOfClass:NSDictionary.class] ? discardedCandidate[@"options"] : nil;
        NSURL *cleanupURL = [discardedOptions[@"AMProjIncomingCleanupURL"]
            isKindOfClass:NSURL.class]
            ? discardedOptions[@"AMProjIncomingCleanupURL"] : nil;
        if (cleanupURL) {
            [NSFileManager.defaultManager removeItemAtURL:cleanupURL error:nil];
        }
    }
}

static NSArray<NSURL *> *amproj_recordLaunchImportCandidates(
    NSDictionary *launchOptions, NSString *source) {
    NSMutableArray<NSURL *> *scopedURLs = [NSMutableArray array];
    if (![launchOptions isKindOfClass:NSDictionary.class]) return scopedURLs;
    if (amproj_runtimeUsesPublic865ImportHooks() &&
        !amproj_runtimeUsesLocalImportEngine()) {
        __block NSUInteger stagedCount = 0;
        void (^stageCandidate)(NSURL *, NSString *, NSDictionary *) =
            ^(NSURL *candidateURL, NSString *candidateSource,
              NSDictionary *candidateOptions) {
            if (!amproj_isIncomingProjectURL(candidateURL, candidateOptions)) return;
            BOOL heldSecurityScope =
                !AMProjV865ProjectFlowIsManagedStagedURL(candidateURL)
                    ? [candidateURL startAccessingSecurityScopedResource] : NO;
            if (heldSecurityScope) [scopedURLs addObject:candidateURL];
            NSError *error = nil;
            NSURL *stagedURL = nil;
            @try {
                stagedURL = amproj_stagePublic865ProjectURL(
                    candidateURL, candidateSource, candidateOptions,
                    heldSecurityScope, &error);
            } @catch (NSException *exception) {
                amproj_debugEvent(@"import.865_launch_stage_exception", @{
                    @"source": candidateSource ?: @"",
                    @"filename": candidateURL.lastPathComponent ?: @"",
                    @"exception": exception.name ?: @"unknown",
                    @"reason": exception.reason ?: @"unknown"
                });
            }
            if (stagedURL) stagedCount++;
        };
        NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
        if ([launchURL isKindOfClass:NSURL.class]) {
            stageCandidate(launchURL,
                [source stringByAppendingString:@"_url"], launchOptions);
        }
        id activityContainer =
            launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
        if ([activityContainer isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)activityContainer enumerateKeysAndObjectsUsingBlock:
                ^(__unused id key, id value, __unused BOOL *stop) {
                if (![value isKindOfClass:NSUserActivity.class]) return;
                NSURL *activityURL = amproj_projectURLFromUserActivity(value);
                stageCandidate(activityURL,
                    [source stringByAppendingString:@"_activity"],
                    amproj_projectOptionsFromUserActivity(value));
            }];
        }
        id topLevelActivity = launchOptions[kAMProjLaunchOptionsUserActivityKey];
        if ([topLevelActivity isKindOfClass:NSUserActivity.class]) {
            NSURL *activityURL = amproj_projectURLFromUserActivity(topLevelActivity);
            stageCandidate(activityURL,
                [source stringByAppendingString:@"_activity"],
                amproj_projectOptionsFromUserActivity(topLevelActivity));
        }
        amproj_debugEvent(@"import.865_launch_stage", @{
            @"source": source ?: @"",
            @"staged_count": @(stagedCount),
            @"scoped_count": @(scopedURLs.count),
            @"forwarded_unchanged": @YES
        });
        return [scopedURLs copy];
    }
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL isKindOfClass:NSURL.class]) {
        amproj_recordDeferredLaunchCandidate(
            launchURL, [source stringByAppendingString:@"_url"], launchOptions);
    }

    id activityContainer =
        launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
    if ([activityContainer isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)activityContainer enumerateKeysAndObjectsUsingBlock:
            ^(__unused id key, id value, __unused BOOL *stop) {
            if (![value isKindOfClass:NSUserActivity.class]) return;
            NSURL *activityURL = amproj_projectURLFromUserActivity(value);
            if (activityURL) {
                NSDictionary *activityOptions =
                    amproj_projectOptionsFromUserActivity(value);
                amproj_recordDeferredLaunchCandidate(
                    activityURL, [source stringByAppendingString:@"_activity"],
                    activityOptions);
            }
        }];
    }
    id topLevelActivity = launchOptions[kAMProjLaunchOptionsUserActivityKey];
    if ([topLevelActivity isKindOfClass:NSUserActivity.class]) {
        NSURL *activityURL = amproj_projectURLFromUserActivity(topLevelActivity);
        if (activityURL) {
            NSDictionary *activityOptions =
                amproj_projectOptionsFromUserActivity(topLevelActivity);
            amproj_recordDeferredLaunchCandidate(
                activityURL, [source stringByAppendingString:@"_activity"],
                activityOptions);
        }
    }
    NSUInteger candidateCount = 0;
    @synchronized (amproj_importDedupeLock()) {
        candidateCount = amproj_deferredLaunchImportCandidates.count;
    }
    amproj_debugEvent(@"import.launch_candidates", @{
        @"source": source ?: @"",
        @"candidate_count": @(candidateCount),
        @"forwarded_unchanged": @YES
    });
    return [scopedURLs copy];
}

static void amproj_restageFailedLaunchImportCandidates(
    NSDictionary *launchOptions, NSString *source) {
    if (![launchOptions isKindOfClass:NSDictionary.class]) return;
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL isKindOfClass:NSURL.class] &&
        amproj_deferredLaunchCandidateNeedsRestaging(launchURL)) {
        amproj_recordDeferredLaunchCandidate(
            launchURL, [source stringByAppendingString:@"_url"], launchOptions);
    }

    id topLevelActivity = launchOptions[kAMProjLaunchOptionsUserActivityKey];
    if ([topLevelActivity isKindOfClass:NSUserActivity.class]) {
        NSURL *activityURL = amproj_projectURLFromUserActivity(topLevelActivity);
        if (activityURL &&
            amproj_deferredLaunchCandidateNeedsRestaging(activityURL)) {
            NSDictionary *activityOptions =
                amproj_projectOptionsFromUserActivity(topLevelActivity);
            amproj_recordDeferredLaunchCandidate(
                activityURL, [source stringByAppendingString:@"_activity"],
                activityOptions);
        }
    }

    id activityContainer =
        launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
    if (![activityContainer isKindOfClass:NSDictionary.class]) return;
    [(NSDictionary *)activityContainer enumerateKeysAndObjectsUsingBlock:
        ^(__unused id key, id value, __unused BOOL *stop) {
        if (![value isKindOfClass:NSUserActivity.class]) return;
        NSURL *activityURL = amproj_projectURLFromUserActivity(value);
        if (activityURL &&
            amproj_deferredLaunchCandidateNeedsRestaging(activityURL)) {
            NSDictionary *activityOptions =
                amproj_projectOptionsFromUserActivity(value);
            amproj_recordDeferredLaunchCandidate(
                activityURL, [source stringByAppendingString:@"_activity"],
                activityOptions);
        }
    }];
}

static NSDictionary *amproj_launchOptionsForNativeAppDelegate(
    NSDictionary *launchOptions) {
    if (![launchOptions isKindOfClass:NSDictionary.class]) return launchOptions;
    // Every engine build (865 included) removes recognized project documents
    // from the forwarded startup payload. Otherwise Alight Motion's original
    // launch route would open the online XML import page or silently ignore
    // the .amproj file while the plugin's own transaction is still running.
    NSMutableDictionary *filtered = [launchOptions mutableCopy];
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    BOOL removedProjectLaunchURL = NO;
    // Never pass a recognized project document to AM's native startup route.
    // If the provider grant was not readable during didFinish, the deferred
    // candidate is retried after startup instead of entering the native XML
    // spinner or a duplicate package importer.
    if ([launchURL isKindOfClass:NSURL.class] &&
        amproj_isIncomingProjectURL(launchURL, launchOptions)) {
        removedProjectLaunchURL = YES;
        [filtered removeObjectForKey:UIApplicationLaunchOptionsURLKey];
    }
    BOOL removedProjectActivity = NO;
    NSString *remainingTopLevelActivityType = nil;
    BOOL hadTopLevelActivityType =
        [launchOptions objectForKey:UIApplicationLaunchOptionsUserActivityTypeKey] != nil;

    // UIKit has shipped both a nested activity dictionary shape and a
    // top-level user-activity key shape. Handle either without forwarding a
    // project activity back into AM's native XML route.
    id topLevelActivity =
        launchOptions[kAMProjLaunchOptionsUserActivityKey];
    if ([topLevelActivity isKindOfClass:NSUserActivity.class]) {
        NSUserActivity *userActivity = (NSUserActivity *)topLevelActivity;
        NSURL *activityURL = amproj_projectURLFromUserActivity(userActivity);
        NSDictionary *activityOptions =
            amproj_projectOptionsFromUserActivity(userActivity);
        if (activityURL &&
            amproj_isIncomingProjectURL(activityURL, activityOptions)) {
            removedProjectActivity = YES;
            [filtered removeObjectForKey:kAMProjLaunchOptionsUserActivityKey];
        } else {
            remainingTopLevelActivityType = [userActivity.activityType copy];
        }
    }

    id activityContainer = launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
    if ([activityContainer isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *activities = [activityContainer mutableCopy];
        id nestedActivityType =
            activities[UIApplicationLaunchOptionsUserActivityTypeKey];
        BOOL removedNestedProjectActivity = NO;
        NSString *remainingNestedActivityType = nil;
        for (id key in [activities.allKeys copy]) {
            id value = activities[key];
            NSUserActivity *userActivity =
                [value isKindOfClass:NSUserActivity.class]
                    ? (NSUserActivity *)value : nil;
            NSURL *activityURL = userActivity
                ? amproj_projectURLFromUserActivity(userActivity) : nil;
            NSDictionary *activityOptions =
                userActivity
                    ? amproj_projectOptionsFromUserActivity(userActivity) : nil;
            if (activityURL &&
                amproj_isIncomingProjectURL(activityURL, activityOptions)) {
                removedProjectActivity = YES;
                removedNestedProjectActivity = YES;
                [activities removeObjectForKey:key];
            } else if (userActivity && !remainingNestedActivityType.length) {
                NSString *activityType = [userActivity.activityType isKindOfClass:NSString.class]
                    ? userActivity.activityType : nil;
                NSString *selectedType = activityType.length
                    ? activityType
                    : ([nestedActivityType isKindOfClass:NSString.class]
                        ? nestedActivityType : nil);
                remainingNestedActivityType = [selectedType copy];
            }
        }
        if (removedNestedProjectActivity) {
            [activities removeObjectForKey:UIApplicationLaunchOptionsUserActivityTypeKey];
            if (remainingNestedActivityType.length &&
                [nestedActivityType isKindOfClass:NSString.class]) {
                activities[UIApplicationLaunchOptionsUserActivityTypeKey] =
                    remainingNestedActivityType;
            }
        }
        if (activities.count) filtered[UIApplicationLaunchOptionsUserActivityDictionaryKey] = activities;
        else [filtered removeObjectForKey:UIApplicationLaunchOptionsUserActivityDictionaryKey];
    }
    if (removedProjectLaunchURL || removedProjectActivity) {
        [filtered removeObjectForKey:UIApplicationLaunchOptionsUserActivityTypeKey];
        if (remainingTopLevelActivityType.length && hadTopLevelActivityType) {
            filtered[UIApplicationLaunchOptionsUserActivityTypeKey] =
                remainingTopLevelActivityType;
        }
    }
    return filtered;
}

static BOOL hooked_applicationWillFinish(id self, SEL _cmd,
                                          UIApplication *application,
                                          NSDictionary *launchOptions) {
    // Build 865 keeps a durable retry copy while forwarding the exact launch
    // dictionary. The verified 862 lane retains its existing filtered route.
    NSArray<NSURL *> *scopedURLs = amproj_recordLaunchImportCandidates(
        launchOptions, @"application_will_finish");
    NSDictionary *forwardedOptions = nil;
    IMP original = NULL;
    BOOL launched = YES;
    BOOL forwarded = NO;
    @try {
        forwardedOptions = amproj_launchOptionsForNativeAppDelegate(launchOptions);
        original = amproj_willFinishForwardDepth
            ? amproj_originalHookForReceiverSkippingExact(
                  amproj_willFinishHooks,
                  sizeof(amproj_willFinishHooks) / sizeof(amproj_willFinishHooks[0]), self)
            : amproj_originalHookForReceiver(
                  amproj_willFinishHooks,
                  sizeof(amproj_willFinishHooks) / sizeof(amproj_willFinishHooks[0]), self);
        if (original && original != (IMP)hooked_applicationWillFinish) {
            amproj_willFinishForwardDepth += 1;
            @try {
                launched = ((AMProjApplicationWillFinishIMP)original)(
                    self, _cmd, application, forwardedOptions);
            } @finally {
                amproj_willFinishForwardDepth -= 1;
            }
            forwarded = YES;
        }
    } @finally {
        for (NSURL *scopedURL in scopedURLs) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
    }
    if (amproj_willFinishForwardDepth) return launched;
    amproj_recordPublic865LaunchNativeRoute(
        launchOptions, @"application_will_finish", forwarded);
    amproj_debugEvent(@"import.will_finish_forward", @{
        @"has_original": @(forwarded),
        @"launch_result": @(launched),
        @"forwarded_project_url_removed":
            @(!(forwardedOptions == launchOptions ||
               [forwardedOptions isEqual:launchOptions]))
    });
    return launched;
}

static BOOL hooked_applicationDidFinish(id self, SEL _cmd, UIApplication *application,
                                          NSDictionary *launchOptions) {
    // Build 865 forwards the original launch dictionary unchanged. Only the
    // verified 862 lane filters and replays deferred launch candidates.
    NSArray<NSURL *> *scopedURLs = amproj_recordLaunchImportCandidates(
        launchOptions, @"application_did_finish");
    NSDictionary *forwardedOptions = nil;
    IMP original = NULL;
    BOOL launched = YES;
    BOOL forwarded = NO;
    @try {
        forwardedOptions = amproj_launchOptionsForNativeAppDelegate(launchOptions);
        original = amproj_didFinishForwardDepth
            ? amproj_originalHookForReceiverSkippingExact(
                  amproj_didFinishHooks,
                  sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]), self)
            : amproj_originalHookForReceiver(
                  amproj_didFinishHooks,
                  sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]), self);
        if (original && original != (IMP)hooked_applicationDidFinish) {
            amproj_didFinishForwardDepth += 1;
            @try {
                launched = ((AMProjApplicationDidFinishIMP)original)(
                    self, _cmd, application, forwardedOptions);
            } @finally {
                amproj_didFinishForwardDepth -= 1;
            }
            forwarded = YES;
        }
    } @finally {
        for (NSURL *scopedURL in scopedURLs) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
    }
    if (amproj_didFinishForwardDepth) return launched;
    // Some providers become readable only after AM finishes initialization.
    // Retry only candidates that are still failed; a successful openURL
    // delivery removes its failed candidate before this point.
    if (amproj_runtimeUsesLocalImportEngine()) {
        amproj_restageFailedLaunchImportCandidates(
            launchOptions, @"application_did_finish_after_native");
    }
    amproj_recordPublic865LaunchNativeRoute(
        launchOptions, @"application_did_finish", forwarded);
    amproj_debugEvent(@"import.did_finish_forward", @{
        @"has_original": @(forwarded),
        @"launch_result": @(launched),
        @"forwarded_project_url_removed":
            @(!(forwardedOptions == launchOptions ||
               [forwardedOptions isEqual:launchOptions]))
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        // Firebase may install its openURL proxy during AM's startup.
        amproj_installPublic865ImportHooks();
        amproj_installImportHook();
    });
    return launched;
}

static BOOL hooked_applicationContinueActivity(id self, SEL _cmd, UIApplication *application,
                                                 NSUserActivity *activity,
                                                 id restorationHandler) {
    NSURL *URL = amproj_projectURLFromUserActivity(activity);
    NSDictionary *options = amproj_projectOptionsFromUserActivity(activity);
    amproj_logCriticalEvent(@"import.activity_callback", @{
        @"delegate": NSStringFromClass([self class]) ?: @"",
        @"activity_type": activity.activityType ?: @"",
        @"extension": URL.pathExtension.lowercaseString ?: @""
    });
    if (amproj_handleImportCommandURL(URL, @"continue_user_activity_command")) return YES;
    BOOL public865Project = amproj_runtimeUsesPublic865ImportHooks() &&
        amproj_isIncomingProjectURL(URL, options);
    BOOL heldSecurityScope = public865Project &&
        !AMProjV865ProjectFlowIsManagedStagedURL(URL)
        ? [URL startAccessingSecurityScopedResource] : NO;
    NSError *stageError = nil;
    NSURL *stagedURL = public865Project
        ? amproj_stagePublic865ProjectURL(
            URL, @"continue_user_activity", options,
            heldSecurityScope, &stageError)
        : nil;
    if (amproj_captureSystemProjectURL(URL, @"continue_user_activity", options)) {
        if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        return YES;
    }
    IMP original = amproj_activityForwardDepth
        ? amproj_originalHookForReceiverSkippingExact(
              amproj_continueActivityHooks,
              sizeof(amproj_continueActivityHooks) / sizeof(amproj_continueActivityHooks[0]), self)
        : amproj_originalHookForReceiver(
              amproj_continueActivityHooks,
              sizeof(amproj_continueActivityHooks) / sizeof(amproj_continueActivityHooks[0]), self);
    BOOL nativeHandled = NO;
    BOOL forwarded = NO;
    if (original && original != (IMP)hooked_applicationContinueActivity) {
        amproj_activityForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationContinueActivityIMP)original)(
                self, _cmd, application, activity, restorationHandler);
            forwarded = YES;
        } @finally {
            amproj_activityForwardDepth -= 1;
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        }
    } else if (heldSecurityScope) {
        [URL stopAccessingSecurityScopedResource];
    }
    if (public865Project) {
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            stagedURL ?: URL, @"continue_user_activity", forwarded);
        if (stagedURL && !nativeHandled &&
            !AMProjV865ProjectFlowIsManagedStagedURL(URL)) {
            AMProjV865ProjectFlowPresentPendingNotice(
                stagedURL, stageError ? @"continue_user_activity_stage_error"
                                      : @"continue_user_activity_declined");
        }
    }
    return nativeHandled;
}

static BOOL hooked_applicationHandleOpenURL(id self, SEL _cmd,
                                             UIApplication *application, NSURL *URL) {
    amproj_logCriticalEvent(@"import.handle_open_url_callback", @{
        @"delegate": NSStringFromClass([self class]) ?: @"",
        @"extension": URL.pathExtension.lowercaseString ?: @""
    });
    if (amproj_handleImportCommandURL(URL, @"application_handle_open_url_command")) return YES;
    BOOL public865Project = amproj_runtimeUsesPublic865ImportHooks() &&
        amproj_isIncomingProjectURL(URL, nil);
    BOOL heldSecurityScope = public865Project &&
        !AMProjV865ProjectFlowIsManagedStagedURL(URL)
        ? [URL startAccessingSecurityScopedResource] : NO;
    NSError *stageError = nil;
    NSURL *stagedURL = public865Project
        ? amproj_stagePublic865ProjectURL(
            URL, @"application_handle_open_url", nil,
            heldSecurityScope, &stageError)
        : nil;
    if (amproj_captureSystemProjectURL(URL, @"application_handle_open_url", nil)) {
        if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        return YES;
    }
    IMP original = amproj_handleOpenURLForwardDepth
        ? amproj_originalHookForReceiverSkippingExact(
              amproj_handleOpenURLHooks,
              sizeof(amproj_handleOpenURLHooks) / sizeof(amproj_handleOpenURLHooks[0]), self)
        : amproj_originalHookForReceiver(
              amproj_handleOpenURLHooks,
              sizeof(amproj_handleOpenURLHooks) / sizeof(amproj_handleOpenURLHooks[0]), self);
    BOOL nativeHandled = NO;
    BOOL forwarded = NO;
    if (original && original != (IMP)hooked_applicationHandleOpenURL) {
        amproj_handleOpenURLForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationHandleOpenURLIMP)original)(
                self, _cmd, application, URL);
            forwarded = YES;
        } @finally {
            amproj_handleOpenURLForwardDepth -= 1;
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        }
    } else if (heldSecurityScope) {
        [URL stopAccessingSecurityScopedResource];
    }
    if (public865Project) {
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            stagedURL ?: URL, @"application_handle_open_url", forwarded);
        if (stagedURL && !nativeHandled &&
            !AMProjV865ProjectFlowIsManagedStagedURL(URL)) {
            AMProjV865ProjectFlowPresentPendingNotice(
                stagedURL, stageError ? @"application_handle_open_url_stage_error"
                                      : @"application_handle_open_url_declined");
        }
    }
    return nativeHandled;
}

static BOOL hooked_applicationLegacyOpenURL(id self, SEL _cmd, UIApplication *application,
                                            NSURL *URL, NSString *sourceApplication,
                                            id annotation) {
    amproj_logCriticalEvent(@"import.legacy_open_url_callback", @{
        @"delegate": NSStringFromClass([self class]) ?: @"",
        @"extension": URL.pathExtension.lowercaseString ?: @"",
        @"source_application": sourceApplication ?: @""
    });
    NSDictionary *options = sourceApplication.length
        ? @{@"source_application": sourceApplication} : nil;
    if (amproj_handleImportCommandURL(URL, @"application_legacy_open_url_command")) return YES;
    BOOL public865Project = amproj_runtimeUsesPublic865ImportHooks() &&
        amproj_isIncomingProjectURL(URL, options);
    BOOL heldSecurityScope = public865Project &&
        !AMProjV865ProjectFlowIsManagedStagedURL(URL)
        ? [URL startAccessingSecurityScopedResource] : NO;
    NSError *stageError = nil;
    NSURL *stagedURL = public865Project
        ? amproj_stagePublic865ProjectURL(
            URL, @"application_legacy_open_url", options,
            heldSecurityScope, &stageError)
        : nil;
    if (amproj_captureSystemProjectURL(URL, @"application_legacy_open_url", options)) {
        if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        return YES;
    }
    IMP original = amproj_legacyOpenURLForwardDepth
        ? amproj_originalHookForReceiverSkippingExact(
              amproj_legacyOpenURLHooks,
              sizeof(amproj_legacyOpenURLHooks) / sizeof(amproj_legacyOpenURLHooks[0]), self)
        : amproj_originalHookForReceiver(
              amproj_legacyOpenURLHooks,
              sizeof(amproj_legacyOpenURLHooks) / sizeof(amproj_legacyOpenURLHooks[0]), self);
    BOOL nativeHandled = NO;
    BOOL forwarded = NO;
    if (original && original != (IMP)hooked_applicationLegacyOpenURL) {
        amproj_legacyOpenURLForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationLegacyOpenURLIMP)original)(
                self, _cmd, application, URL, sourceApplication, annotation);
            forwarded = YES;
        } @finally {
            amproj_legacyOpenURLForwardDepth -= 1;
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        }
    } else if (heldSecurityScope) {
        [URL stopAccessingSecurityScopedResource];
    }
    if (public865Project) {
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            stagedURL ?: URL, @"application_legacy_open_url", forwarded);
        if (stagedURL && !nativeHandled &&
            !AMProjV865ProjectFlowIsManagedStagedURL(URL)) {
            AMProjV865ProjectFlowPresentPendingNotice(
                stagedURL, stageError ? @"application_legacy_open_url_stage_error"
                                      : @"application_legacy_open_url_declined");
        }
    }
    return nativeHandled;
}

// Scene-based cold launches deliver the document before `openURLContexts:`.
// Build 865 keeps a durable copy but leaves the immutable connection options
// untouched; the verified 862 lane retains its deferred import queue.
static NSArray<NSURL *> *amproj_recordSceneConnectionCandidates(
    UISceneConnectionOptions *connectionOptions, NSString *source) {
    NSMutableArray<NSURL *> *scopedURLs = [NSMutableArray array];
    if (!connectionOptions) return scopedURLs;
    NSUInteger URLCount = 0;
    NSUInteger activityCount = 0;
    BOOL public865 = amproj_runtimeUsesPublic865ImportHooks() &&
        !amproj_runtimeUsesLocalImportEngine();
    for (UIOpenURLContext *context in connectionOptions.URLContexts) {
        if (![context isKindOfClass:UIOpenURLContext.class] || !context.URL) continue;
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        UISceneOpenURLOptions *sceneOptions = context.options;
        options[UIApplicationOpenURLOptionsOpenInPlaceKey] =
            @(sceneOptions.openInPlace);
        if (sceneOptions.sourceApplication.length) {
            options[UIApplicationOpenURLOptionsSourceApplicationKey] =
                sceneOptions.sourceApplication;
        }
        if (public865) {
            NSURL *URL = context.URL;
            if (!amproj_isIncomingProjectURL(URL, options)) continue;
            BOOL heldSecurityScope =
                !AMProjV865ProjectFlowIsManagedStagedURL(URL)
                ? [URL startAccessingSecurityScopedResource] : NO;
            if (heldSecurityScope) [scopedURLs addObject:URL];
            NSError *stageError = nil;
            NSURL *stagedURL = nil;
            @try {
                stagedURL = amproj_stagePublic865ProjectURL(
                    URL, [source stringByAppendingString:@"_url"], options,
                    heldSecurityScope, &stageError);
            } @catch (NSException *exception) {
                amproj_debugEvent(@"import.865_scene_stage_exception", @{
                    @"source": source ?: @"",
                    @"filename": URL.lastPathComponent ?: @"",
                    @"exception": exception.name ?: @"unknown",
                    @"reason": exception.reason ?: @"unknown"
                });
            }
            if (stagedURL) URLCount++;
            continue;
        }
        NSUInteger before = 0;
        @synchronized (amproj_importDedupeLock()) {
            before = amproj_deferredLaunchImportCandidates.count;
        }
        amproj_recordDeferredLaunchCandidate(
            context.URL, [source stringByAppendingString:@"_url"], options);
        @synchronized (amproj_importDedupeLock()) {
            if (amproj_deferredLaunchImportCandidates.count != before) URLCount++;
        }
    }
    for (NSUserActivity *activity in connectionOptions.userActivities) {
        NSURL *URL = amproj_projectURLFromUserActivity(activity);
        if (!URL) continue;
        if (public865) {
            NSDictionary *options = amproj_projectOptionsFromUserActivity(activity);
            if (!amproj_isIncomingProjectURL(URL, options)) continue;
            BOOL heldSecurityScope =
                !AMProjV865ProjectFlowIsManagedStagedURL(URL)
                ? [URL startAccessingSecurityScopedResource] : NO;
            if (heldSecurityScope) [scopedURLs addObject:URL];
            NSError *stageError = nil;
            NSURL *stagedURL = nil;
            @try {
                stagedURL = amproj_stagePublic865ProjectURL(
                    URL, [source stringByAppendingString:@"_activity"], options,
                    heldSecurityScope, &stageError);
            } @catch (NSException *exception) {
                amproj_debugEvent(@"import.865_scene_stage_exception", @{
                    @"source": source ?: @"",
                    @"filename": URL.lastPathComponent ?: @"",
                    @"exception": exception.name ?: @"unknown",
                    @"reason": exception.reason ?: @"unknown"
                });
            }
            if (stagedURL) activityCount++;
            continue;
        }
        activityCount++;
        amproj_recordDeferredLaunchCandidate(
            URL, [source stringByAppendingString:@"_activity"],
            amproj_projectOptionsFromUserActivity(activity));
    }
    amproj_logCriticalEvent(@"import.scene_connection_candidates", @{
        @"source": source ?: @"",
        @"url_count": @(URLCount),
        @"activity_count": @(activityCount),
        @"received_url_contexts": @(connectionOptions.URLContexts.count),
        @"received_user_activities": @(connectionOptions.userActivities.count),
        @"forwarded_unchanged": @(public865),
        @"deferred_queue": @(!public865),
        @"scoped_count": @(scopedURLs.count)
    });
    return [scopedURLs copy];
}

static void amproj_recordPublic865SceneConnectionRoutes(
    UISceneConnectionOptions *connectionOptions, NSString *source,
    BOOL forwarded) {
    if (!amproj_runtimeUsesPublic865ImportHooks() || !connectionOptions) return;
    for (UIOpenURLContext *context in connectionOptions.URLContexts) {
        NSURL *URL = [context isKindOfClass:UIOpenURLContext.class]
            ? context.URL : nil;
        if (!amproj_isIncomingProjectURL(URL, nil)) continue;
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            URL, [source stringByAppendingString:@"_url"], forwarded);
    }
    for (NSUserActivity *activity in connectionOptions.userActivities) {
        NSURL *URL = amproj_projectURLFromUserActivity(activity);
        NSDictionary *options = amproj_projectOptionsFromUserActivity(activity);
        if (!amproj_isIncomingProjectURL(URL, options)) continue;
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            URL, [source stringByAppendingString:@"_activity"], forwarded);
    }
}

static UISceneConfiguration *hooked_applicationConfigurationForConnecting(
    id self, SEL _cmd, UIApplication *application, UISceneSession *session,
    UISceneConnectionOptions *connectionOptions) {
    BOOL public865 = amproj_runtimeUsesPublic865ImportHooks();
    // Stage before the native configuration callback while the provider grant
    // is valid, then keep every acquired scope alive until that callback ends.
    NSArray<NSURL *> *scopedURLs = amproj_recordSceneConnectionCandidates(
        connectionOptions, @"application_configuration_for_connecting");
    IMP original = NULL;
    UISceneConfiguration *configuration = nil;
    BOOL forwarded = NO;
    @try {
        original = amproj_configurationForwardDepth
            ? amproj_originalHookForReceiverSkippingExact(
                  amproj_configurationHooks,
                  sizeof(amproj_configurationHooks) /
                      sizeof(amproj_configurationHooks[0]), self)
            : amproj_originalHookForReceiver(
                  amproj_configurationHooks,
                  sizeof(amproj_configurationHooks) /
                      sizeof(amproj_configurationHooks[0]), self);
        if (original && original != (IMP)hooked_applicationConfigurationForConnecting) {
            amproj_configurationForwardDepth += 1;
            @try {
                configuration = ((AMProjApplicationConfigurationForConnectingIMP)original)(
                    self, _cmd, application, session, connectionOptions);
                forwarded = YES;
            } @finally {
                amproj_configurationForwardDepth -= 1;
            }
        }
    } @finally {
        for (NSURL *scopedURL in scopedURLs) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
    }
    if (public865) {
        amproj_installPublic865SceneHooksForClass(configuration.delegateClass);
        amproj_recordPublic865SceneConnectionRoutes(
            connectionOptions, @"application_configuration_for_connecting",
            forwarded);
    }
    amproj_debugEvent(@"import.scene_configuration_forward", @{
        @"delegate": NSStringFromClass([self class]) ?: @"",
        @"has_original": @(original != NULL),
        @"returned_configuration": @(configuration != nil)
    });
    return configuration;
}

static void hooked_sceneWillConnectToSession(
    id self, SEL _cmd, UIScene *scene, UISceneSession *session,
    UISceneConnectionOptions *connectionOptions) {
    NSArray<NSURL *> *scopedURLs = amproj_recordSceneConnectionCandidates(
        connectionOptions, @"scene_will_connect");
    IMP original = NULL;
    BOOL forwarded = NO;
    @try {
        original = amproj_sceneWillConnectForwardDepth
            ? amproj_originalHookForReceiverSkippingExact(
                  amproj_sceneWillConnectHooks,
                  sizeof(amproj_sceneWillConnectHooks) /
                      sizeof(amproj_sceneWillConnectHooks[0]), self)
            : amproj_originalHookForReceiver(
                  amproj_sceneWillConnectHooks,
                  sizeof(amproj_sceneWillConnectHooks) /
                      sizeof(amproj_sceneWillConnectHooks[0]), self);
        if (original && original != (IMP)hooked_sceneWillConnectToSession) {
            amproj_sceneWillConnectForwardDepth += 1;
            @try {
                ((AMProjSceneWillConnectIMP)original)(
                    self, _cmd, scene, session, connectionOptions);
                forwarded = YES;
            } @finally {
                amproj_sceneWillConnectForwardDepth -= 1;
            }
        }
    } @finally {
        for (NSURL *scopedURL in scopedURLs) {
            [scopedURL stopAccessingSecurityScopedResource];
        }
    }
    if (amproj_runtimeUsesPublic865ImportHooks()) {
        amproj_installPublic865SceneHooksForClass([self class]);
    }
    amproj_recordPublic865SceneConnectionRoutes(
        connectionOptions, @"scene_will_connect", forwarded);
}

static void hooked_sceneOpenURLContexts(id self, SEL _cmd, UIScene *scene,
                                        NSSet *URLContexts) {
    amproj_logCriticalEvent(@"import.scene_callback", @{
        @"delegate": NSStringFromClass([self class]) ?: @"",
        @"context_count": @(URLContexts.count)
    });
    IMP original = amproj_sceneOpenURLForwardDepth
        ? amproj_originalHookForReceiverSkippingExact(
              amproj_sceneOpenURLHooks,
              sizeof(amproj_sceneOpenURLHooks) / sizeof(amproj_sceneOpenURLHooks[0]), self)
        : amproj_originalHookForReceiver(
              amproj_sceneOpenURLHooks,
              sizeof(amproj_sceneOpenURLHooks) / sizeof(amproj_sceneOpenURLHooks[0]), self);
    if (amproj_sceneOpenURLForwardDepth) {
        if (original && original != (IMP)hooked_sceneOpenURLContexts) {
            amproj_sceneOpenURLForwardDepth += 1;
            @try {
                ((AMProjSceneOpenURLContextsIMP)original)(self, _cmd, scene, URLContexts);
            } @finally {
                amproj_sceneOpenURLForwardDepth -= 1;
            }
        }
        return;
    }

    if (amproj_runtimeUsesPublic865ImportHooks()) {
        // Build 865 consumes recognized project URLs through the local import
        // engine and forwards only the remaining contexts to Alight Motion.
        // The previous loop staged a handoff copy and then forwarded the very
        // same contexts, so AM's original route (online XML page, silent
        // .amproj handling) still owned the outcome.
        NSUInteger consumedCount = 0;
        NSMutableArray<NSURL *> *forwardContexts = [NSMutableArray array];
        for (id context in URLContexts) {
            UIOpenURLContext *openContext =
                [context isKindOfClass:UIOpenURLContext.class] ? context : nil;
            NSURL *URL = openContext.URL;
            if (!URL) {
                [forwardContexts addObject:context];
                continue;
            }
            NSMutableDictionary *options = [NSMutableDictionary dictionary];
            UISceneOpenURLOptions *sceneOptions = openContext.options;
            options[UIApplicationOpenURLOptionsOpenInPlaceKey] =
                @(sceneOptions.openInPlace);
            if (sceneOptions.sourceApplication.length) {
                options[UIApplicationOpenURLOptionsSourceApplicationKey] =
                    sceneOptions.sourceApplication;
            }
            if (!amproj_isIncomingProjectURL(URL, options)) {
                [forwardContexts addObject:context];
                continue;
            }
            BOOL heldSecurityScope =
                !AMProjV865ProjectFlowIsManagedStagedURL(URL)
                ? [URL startAccessingSecurityScopedResource] : NO;
            BOOL consumed = amproj_handleImportCommandURL(
                URL, @"scene_open_url_contexts_command") ||
                amproj_captureSystemProjectURL(
                    URL, @"scene_open_url_contexts", options);
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
            if (consumed) {
                consumedCount++;
            } else {
                [forwardContexts addObject:context];
            }
        }
        BOOL forwarded = NO;
        if (forwardContexts.count &&
            original && original != (IMP)hooked_sceneOpenURLContexts) {
            amproj_sceneOpenURLForwardDepth += 1;
            @try {
                ((AMProjSceneOpenURLContextsIMP)original)(
                    self, _cmd, scene, [forwardContexts copy]);
                forwarded = YES;
            } @finally {
                amproj_sceneOpenURLForwardDepth -= 1;
            }
        }
        amproj_debugEvent(@"import.865_scene_partition", @{
            @"received": @(URLContexts.count),
            @"consumed": @(consumedCount),
            @"forwarded": @(forwardContexts.count),
            @"native_forwarded": @(forwarded),
            @"engine": @"local_transaction"
        });
        return;
    }

    NSMutableSet *passthroughContexts = [NSMutableSet setWithCapacity:URLContexts.count];
    NSUInteger consumedCount = 0;
    for (id context in URLContexts) {
        NSURL *URL = nil;
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        @try {
            if (@available(iOS 13.0, *)) {
                UIOpenURLContext *openContext =
                    [context isKindOfClass:UIOpenURLContext.class] ? context : nil;
                URL = openContext.URL;
                UISceneOpenURLOptions *sceneOptions = openContext.options;
                options[UIApplicationOpenURLOptionsOpenInPlaceKey] =
                    @(sceneOptions.openInPlace);
                NSString *sourceApplication = sceneOptions.sourceApplication;
                if (sourceApplication.length) {
                    options[UIApplicationOpenURLOptionsSourceApplicationKey] = sourceApplication;
                }
            }
        } @catch (__unused NSException *exception) {
            URL = nil;
        }
        if (!URL) {
            if (context) [passthroughContexts addObject:context];
            continue;
        }
        if (amproj_handleImportCommandURL(URL, @"scene_open_url_contexts_command") ||
            amproj_captureSystemProjectURL(
                URL, @"scene_open_url_contexts", options)) {
            consumedCount++;
            continue;
        }
        if (context) [passthroughContexts addObject:context];
    }

    amproj_debugEvent(@"import.scene_partition", @{
        @"received": @(URLContexts.count),
        @"consumed": @(consumedCount),
        @"forwarded": @(passthroughContexts.count)
    });
    if (passthroughContexts.count &&
        original && original != (IMP)hooked_sceneOpenURLContexts) {
        amproj_sceneOpenURLForwardDepth += 1;
        @try {
            ((AMProjSceneOpenURLContextsIMP)original)(
                self, _cmd, scene, [passthroughContexts copy]);
        } @finally {
            amproj_sceneOpenURLForwardDepth -= 1;
        }
    }
}

static void (*orig_projectsImportAlertViewDidLoad)(id, SEL) = NULL;
static void (*orig_projectsImportAlertViewDidDisappear)(id, SEL, BOOL) = NULL;
static void (*orig_projectsImportAlertOnPressImport)(id, SEL, id) = NULL;
static void (*orig_projectsImportAlertOnPressCancel)(id, SEL, id) = NULL;
static char amproj_trackedProjectsImportAlertKey;
static char amproj_projectsImportActionKey;

static BOOL amproj_isTrackedProjectsImportAlert(id alert) {
    return [objc_getAssociatedObject(alert, &amproj_trackedProjectsImportAlertKey) boolValue];
}

static void hooked_projectsImportAlertViewDidLoad(id self, SEL _cmd) {
    if (orig_projectsImportAlertViewDidLoad) {
        orig_projectsImportAlertViewDidLoad(self, _cmd);
    }
    BOOL recognizedQueuedPackage = amproj_waitingForNativeImportAlert;
    if (!recognizedQueuedPackage) return;
    NSString *name = amproj_nativeImportRecognitionName ?: @"project.amproj";
    amproj_nativeImportAlertActive = YES;
    objc_setAssociatedObject(self, &amproj_trackedProjectsImportAlertKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    amproj_waitingForNativeImportAlert = NO;
    amproj_nativeImportRecognitionName = nil;
    ++amproj_nativeImportRecognitionGeneration;
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"recognized",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"filename": name
    });
    amproj_showImportStatus(
        @"AMProj \u00b7 AM \u5df2\u8bc6\u522b\u9879\u76ee\u5305\uff0c\u8bf7\u786e\u8ba4\u5bfc\u5165", NO);
}

static void hooked_projectsImportAlertOnPressImport(id self, SEL _cmd, id sender) {
    BOOL tracked = amproj_isTrackedProjectsImportAlert(self);
    if (!tracked) {
        if (orig_projectsImportAlertOnPressImport) {
            orig_projectsImportAlertOnPressImport(self, _cmd, sender);
        }
        return;
    }
    amproj_setNativeImportObservationPhase(@"commit");
    objc_setAssociatedObject(self, &amproj_projectsImportActionKey, @"import",
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"import_pressed",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"tracked": @YES
    });
    amproj_showImportStatus(
        @"AMProj \u00b7 AM \u6b63\u5728\u5bfc\u5165\u9879\u76ee\u5305", NO);
    if (orig_projectsImportAlertOnPressImport) {
        orig_projectsImportAlertOnPressImport(self, _cmd, sender);
    }
}

static void hooked_projectsImportAlertOnPressCancel(id self, SEL _cmd, id sender) {
    BOOL tracked = amproj_isTrackedProjectsImportAlert(self);
    if (!tracked) {
        if (orig_projectsImportAlertOnPressCancel) {
            orig_projectsImportAlertOnPressCancel(self, _cmd, sender);
        }
        return;
    }
    amproj_endNativeImportObservation();
    objc_setAssociatedObject(self, &amproj_projectsImportActionKey, @"cancel",
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"cancel_pressed",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"tracked": @YES
    });
    if (orig_projectsImportAlertOnPressCancel) {
        orig_projectsImportAlertOnPressCancel(self, _cmd, sender);
    }
}

static void hooked_projectsImportAlertViewDidDisappear(id self, SEL _cmd,
                                                       BOOL animated) {
    if (orig_projectsImportAlertViewDidDisappear) {
        orig_projectsImportAlertViewDidDisappear(self, _cmd, animated);
    }
    BOOL tracked = amproj_isTrackedProjectsImportAlert(self);
    if (!tracked) return;
    amproj_nativeImportAlertActive = NO;
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"disappeared",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"tracked": @YES
    });
    objc_setAssociatedObject(self, &amproj_trackedProjectsImportAlertKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    NSString *action = objc_getAssociatedObject(self, &amproj_projectsImportActionKey);
    objc_setAssociatedObject(self, &amproj_projectsImportActionKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    if (![action isEqualToString:@"import"]) {
        if (amproj_nativeImportObservationActive) {
            amproj_endNativeImportObservation();
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            amproj_resumeQueuedImports(@"native_alert_cancelled");
        });
    } else {
        NSUInteger observationGeneration = amproj_nativeImportObservationGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (observationGeneration != amproj_nativeImportObservationGeneration ||
                !amproj_nativeImportObservationActive) return;
            NSDictionary *observation = amproj_nativeImportObservationFields();
            amproj_endNativeImportObservation();
            amproj_importDispatchCoolingDown = NO;
            amproj_debugEvent(@"import.observation_finished", @{
                @"reason": @"timeout_after_import_pressed",
                @"attempt_id": observation[@"attempt_id"] ?: @"",
                @"filename": observation[@"filename"] ?: @"project.amproj",
                @"wait_seconds": @180
            });
            amproj_resumeQueuedImports(@"native_import_observation_timeout");
        });
        amproj_debugEvent(@"import.queue_paused", @{
            @"reason": @"native_import_committing"
        });
    }
}

static UIWindow* amproj_keyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
            if (!fallback && !window.hidden && window.alpha > 0.0 &&
                window.windowLevel == UIWindowLevelNormal) fallback = window;
        }
    }
    if (fallback) return fallback;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) return window;
        if (!fallback && !window.hidden && window.alpha > 0.0 &&
            window.windowLevel == UIWindowLevelNormal) fallback = window;
    }
    if (fallback) return fallback;
    id delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        @try {
            return ((UIWindow *(*)(id, SEL))(void *)objc_msgSend)(delegate, @selector(window));
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

static NSArray<NSString*>* amproj_controllerClassChain(void) {
    NSMutableArray<NSString*> *classes = [NSMutableArray array];
    NSMutableSet<NSValue*> *visited = [NSMutableSet set];
    UIViewController *controller = amproj_keyWindow().rootViewController;
    while (controller) {
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) break;
        [visited addObject:identity];
        [classes addObject:NSStringFromClass([controller class]) ?: @""];

        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)controller).visibleViewController;
        }
        if (!next && [controller isKindOfClass:[UITabBarController class]]) {
            next = ((UITabBarController *)controller).selectedViewController;
        }
        if (!next) next = controller.childViewControllers.lastObject;
        controller = next;
    }
    return classes;
}

static BOOL amproj_isPackageControllerName(NSString *className) {
    // Do not classify unrelated monetization/transport controllers as an
    // export package flow. The v27b binary's concrete controller is the
    // Swift-mangled ShareProjectPackageVC.
    return className.length && [className hasSuffix:@"ShareProjectPackageVC"];
}

static BOOL amproj_isSharePackageController(UIViewController *controller) {
    if (!controller) return NO;
    if (amproj_isPackageControllerName(NSStringFromClass(controller.class))) {
        return YES;
    }
    if (![controller isKindOfClass:UINavigationController.class]) return NO;
    UIViewController *visible =
        ((UINavigationController *)controller).visibleViewController;
    return visible &&
        amproj_isPackageControllerName(NSStringFromClass(visible.class));
}

static BOOL amproj_hasPackageController(NSArray<NSString*> *classes) {
    for (NSString *className in classes) {
        if (amproj_isPackageControllerName(className)) return YES;
    }
    return NO;
}

static BOOL amproj_hasSupportedItem(NSArray *items) {
    for (id item in items) {
        if ([item isKindOfClass:[UIImage class]] || [item isKindOfClass:[NSData class]] ||
            [item isKindOfClass:[NSURL class]]) return YES;
    }
    return NO;
}

static NSArray<NSString*>* amproj_itemClassNames(NSArray *items) {
    NSMutableArray *names = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) [names addObject:NSStringFromClass([item class]) ?: @"(null)"];
    return names;
}

static id hooked_initWithItems(id self, SEL _cmd, NSArray *activityItems,
                                NSArray *applicationActivities) {
    if (amproj_constructingDirectShare) {
        return orig_initWithItems(self, _cmd, activityItems, applicationActivities);
    }
    NSArray<NSString*> *controllerClasses = amproj_controllerClassChain();
#if AMPROJ_DEBUG
    BOOL isPackageExport = amproj_hasSupportedItem(activityItems) &&
        (amproj_hasPackageController(controllerClasses) ||
         atomic_load(&amproj_packageFlowActive)
        );
#else
    // Release builds export only from the semantic ShareNC action.  Treating
    // an arbitrary activity sheet under ShareProjectPackageVC as an export
    // re-enters AM's native image/package flow and was the source of the old
    // crash-prone fallback path.
    BOOL isPackageExport = AMProjV44ReleaseNativeActivityFallbackEnabled();
#endif
    NSString *mode = amproj_exportMode();

#if AMPROJ_DEBUG
    if (isPackageExport) amproj_beginPackageFlow(@"activity_init");
#endif
    amproj_setPhase(AMProjDebugPhaseActivityInit, @{
        @"detected": @(isPackageExport),
        @"mode": mode,
        @"items": amproj_itemClassNames(activityItems),
        @"controllers": controllerClasses
    });

    NSData *xmlData = nil;
    NSURL *replacementURL = nil;
    NSDictionary<NSString *, NSNumber *> *zipMetrics = nil;
    if (isPackageExport && ![mode isEqualToString:@"observe"]) {
        @try {
            NSDictionary *expected = nil;
            if ([mode isEqualToString:@"placeholder"]) {
                xmlData = amproj_placeholderXML();
                expected = @{@"title": @"AMProj_Placeholder", @"width": @1280,
                             @"height": @720, @"layers": @0, @"layers_known": @YES,
                             @"save_started": NSDate.date};
            } else {
                amproj_debugEvent(@"activity_fallback.full_skipped", @{
                    @"reason": @"native project XML is only exported by the direct ShareProjectPackageVC path"
                });
            }

            NSError *prepareError = nil;
            if (!xmlData || !expected ||
                !amproj_validateXMLAgainstScene(xmlData, expected, NULL, &prepareError)) {
                amproj_debugEvent(@"activity_fallback.invalid_xml", @{
                    @"error": prepareError.localizedDescription ?: @"scene unavailable"
                });
            } else {
                NSDictionary *prepared = amproj_collectResourcesAndRewriteXML(xmlData, nil, &prepareError);
                NSData *archiveXML = prepared[@"xml"];
                NSDictionary<NSString *, NSURL *> *resources = prepared[@"resources"];
                if (prepared && amproj_validateXMLAgainstScene(archiveXML, expected, NULL, &prepareError)) {
                    amproj_setPhase(AMProjDebugPhaseZIP, @{@"xml_bytes": @(archiveXML.length)});
                    replacementURL = amproj_createOutputURL(expected[@"title"], &prepareError);
                    if (replacementURL && AMProjZIPWriteProjectArchive(
                            replacementURL, archiveXML, resources, &zipMetrics, &prepareError)) {
                        xmlData = archiveXML;
                        activityItems = @[replacementURL];
                    } else {
                        replacementURL = nil;
                    }
                }
                if (prepareError) {
                    amproj_debugEvent(@"activity_fallback.failed", @{
                        @"error": prepareError.localizedDescription ?: @""
                    });
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[AMProjExport] Export failed: %@", exception);
            amproj_debugEvent(@"export.exception", @{
                @"name": exception.name ?: @"",
                @"reason": exception.reason ?: @""
            });
        }

        if (replacementURL) {
            NSNumber *archiveSize = nil;
            [replacementURL getResourceValue:&archiveSize forKey:NSURLFileSizeKey error:nil];
            amproj_setPhase(AMProjDebugPhaseFileWrite, @{@"bytes": archiveSize ?: @0});
            amproj_debugEvent(@"file_write.result", @{
                @"success": @YES,
                @"filename": replacementURL.lastPathComponent ?: @"",
                @"bytes": archiveSize ?: @0,
                @"crc_verified": zipMetrics[@"crc_verified"] ?: @NO,
                @"manifest_verified": zipMetrics[@"manifest_verified"] ?: @NO
            });

#if AMPROJ_DEBUG
            if (amproj_currentTransaction && amproj_captureCurrentTransaction) {
                [[AMDebugTransport shared] uploadArtifactData:xmlData
                                                         name:@"scene.xml"
                                                     mimeType:@"application/xml"
                                                  transaction:amproj_currentTransaction];
                if (archiveSize.unsignedLongLongValue <= 32ULL * 1024ULL * 1024ULL) {
                    NSData *archiveData = [NSData dataWithContentsOfURL:replacementURL
                                                                options:NSDataReadingMappedIfSafe error:nil];
                    if (archiveData) {
                        [[AMDebugTransport shared] uploadArtifactData:archiveData
                                                                 name:replacementURL.lastPathComponent
                                                             mimeType:@"application/x-amproj"
                                                          transaction:amproj_currentTransaction];
                    }
                }
            }
#endif
        }
    }

    amproj_setPhase(AMProjDebugPhaseOriginalInit, @{
        @"mode": mode,
        @"replacement": @(replacementURL != nil)
    });
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    id result = orig_initWithItems(self, _cmd, activityItems, applicationActivities);
    amproj_debugEvent(@"activity_init.return", @{
        @"duration_ms": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
        @"class": result ? NSStringFromClass([result class]) : @""
    });
    return result;
}

static BOOL amproj_IPAFireTextMatches(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return NO;
    NSString *normalized = text.lowercaseString;
    if ([normalized containsString:@"@ipafire"]) return YES;
    // Blatant welcome page (Frameworks/AlightMotion.dylib license overlay):
    // these markers never appear in Alight Motion's own localization tables,
    // so any one of them alone is a reliable fingerprint.
    if ([normalized containsString:@"cracked by"]) return YES;
    if ([normalized containsString:@"instant certificates"]) return YES;
    if ([normalized containsString:@"closing in"]) return YES;
    // Blatant license splash (close button, spinner, continue button). The
    // zh-Hans localization of the app does not contain this string.
    if ([text containsString:@"\u7ee7\u7eed\u8fdb\u5165"]) return YES;
    BOOL hasWelcome = [normalized containsString:@"welcome"];
    BOOL hasCracked = [normalized containsString:@"cracked by blatant"] ||
        [normalized containsString:@"instant certificates"];
    BOOL hasMoreApps = [normalized containsString:@"more apps"];
    return (hasWelcome && hasCracked) || (hasCracked && hasMoreApps);
}

static void amproj_IPAFireAppendLayerText(CALayer *layer,
                                          NSMutableString *output,
                                          NSUInteger depth) {
    if (!layer || !output || depth > 32 || output.length >= 131072) return;
    if ([layer isKindOfClass:CATextLayer.class]) {
        id value = ((CATextLayer *)layer).string;
        NSString *text = nil;
        if ([value isKindOfClass:NSString.class]) {
            text = value;
        } else if ([value isKindOfClass:NSAttributedString.class]) {
            text = ((NSAttributedString *)value).string;
        }
        if (text.length) [output appendFormat:@"%@\n", text];
    }
    for (CALayer *sublayer in layer.sublayers) {
        amproj_IPAFireAppendLayerText(sublayer, output, depth + 1);
        if (output.length >= 131072) break;
    }
}

static void amproj_IPAFireAppendViewText(UIView *view,
                                         NSMutableString *output,
                                         NSUInteger depth) {
    if (!view || !output || depth > 32 || output.length >= 131072) return;

    // The welcome page renders each marker in a separate UILabel. Aggregate
    // the subtree before matching so the fingerprint is evaluated across the
    // whole page instead of one control at a time.
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length) [output appendFormat:@"%@\n", text];
    }
    if ([view isKindOfClass:UIButton.class]) {
        NSString *text = ((UIButton *)view).currentTitle;
        if (text.length) [output appendFormat:@"%@\n", text];
    }
    if ([view isKindOfClass:UITextView.class]) {
        NSString *text = ((UITextView *)view).text;
        if (text.length) [output appendFormat:@"%@\n", text];
    }
    if ([view isKindOfClass:UITextField.class]) {
        NSString *text = ((UITextField *)view).text;
        if (text.length) [output appendFormat:@"%@\n", text];
    }
    if ([view.accessibilityLabel isKindOfClass:NSString.class] &&
        view.accessibilityLabel.length) {
        [output appendFormat:@"%@\n", view.accessibilityLabel];
    }
    if ([view.accessibilityValue isKindOfClass:NSString.class] &&
        view.accessibilityValue.length) {
        [output appendFormat:@"%@\n", view.accessibilityValue];
    }

    // SwiftUI may expose its labels as UIAccessibilityElement instances
    // without creating UILabel subviews. Read only bounded accessibility text
    // and keep the same subtree depth/size limits as the visual walk.
    for (id element in amproj_accessibilityChildren(view)) {
        if (!element || [element isKindOfClass:UIView.class]) continue;
        for (NSString *selectorName in @[
            NSStringFromSelector(@selector(accessibilityLabel)),
            NSStringFromSelector(@selector(accessibilityValue)),
            NSStringFromSelector(@selector(accessibilityHint))
        ]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![element respondsToSelector:selector]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(element, selector);
            if ([value isKindOfClass:NSString.class] && [value length]) {
                [output appendFormat:@"%@\n", value];
            }
            if (output.length >= 131072) break;
        }
        if (output.length >= 131072) break;
    }

    for (UIView *subview in view.subviews) {
        amproj_IPAFireAppendViewText(subview, output, depth + 1);
        if (output.length >= 131072) break;
    }
}

static BOOL amproj_IPAFireViewContainsMarker(UIView *view, NSUInteger depth) {
    if (!view || depth > 32) return NO;
    NSMutableString *content = [NSMutableString stringWithCapacity:256];
    amproj_IPAFireAppendViewText(view, content, depth);
    amproj_IPAFireAppendLayerText(view.layer, content, depth);
    return amproj_IPAFireTextMatches(content);
}

static UIView *amproj_IPAFireFindOverlayView(UIView *view, NSUInteger depth) {
    if (!view || depth > 36) return nil;
    // Prefer the smallest matching subtree so a welcome overlay attached to
    // the app's normal root view can be removed without hiding the app itself.
    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        UIView *candidate = amproj_IPAFireFindOverlayView(subview, depth + 1);
        if (candidate) return candidate;
    }
    return amproj_IPAFireViewContainsMarker(view, depth) ? view : nil;
}

// A rootless overlay window hosting a web view never exposes UIKit label text
// for the marker walk. Alight Motion always hosts web content below a root
// controller, so a visible window without a root that contains a web view is
// an injected overlay, never an application surface.
static BOOL amproj_windowContainsWebView(UIView *view, NSUInteger depth) {
    if (!view || depth > 24) return NO;
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (webViewClass && [view isKindOfClass:webViewClass]) return YES;
    for (UIView *subview in view.subviews) {
        if (amproj_windowContainsWebView(subview, depth + 1)) return YES;
    }
    return NO;
}

#pragma mark - Crack gate bypass

// Device syslog for the frozen build proved both earlier strategies wrong:
// hide-only deadlocks the app (the crack re-shows its gate immediately,
// 6153 suppressions in 110s, while no window stays key and every touch is
// dropped), and letting the gate render at all is exactly what must not
// happen. The gate window is therefore never allowed to become visible: the
// show paths (makeKeyAndVisible / setHidden / root swap) are blocked and the
// gate's own continue/close control is fired silently while the window is
// still hidden, so the crack state machine completes with zero rendered
// frames and the application window keeps key status throughout.

static BOOL amproj_gateWindowCollectButtons(UIView *view, NSUInteger depth,
                                            NSMutableArray<UIButton *> *out) {
    if (!view || depth > 24) return NO;
    if ([view isKindOfClass:UIButton.class]) {
        [out addObject:(UIButton *)view];
        if (out.count >= 32) return YES;
    }
    for (UIView *subview in view.subviews) {
        if (amproj_gateWindowCollectButtons(subview, depth + 1, out)) return YES;
    }
    return NO;
}

// A gate window is any window whose controller chain or view tree was built
// by the injected license module. The root can be nil when the crack adds
// its views directly, so the whole window tree is inspected.
static BOOL amproj_windowCarriesCrackGate(UIWindow *window) {
    if (!window) return NO;
    if (AMProjPresentationChainHasCrackController(window.rootViewController)) {
        return YES;
    }
    return AMProjViewHierarchyHasCrackClass(window, 0);
}

// Fires the gate's own skip control: prefer the literal continue-entrance
// title, then the bottom full-width button layout, then the small top-left
// close button. sendActionsForControlEvents reaches every target the crack
// wired, so its own state machine performs the completion and dismissal
// while the window stays invisible.
static BOOL amproj_fireGateSkipControl(UIWindow *window) {
    if (!window || !NSThread.isMainThread) return NO;
    UIViewController *root = window.rootViewController;
    if (root && !root.viewIfLoaded) {
        // Force the gate's own viewDidLoad so its controls exist; the window
        // stays hidden, so nothing is rendered by this.
        [root view];
    }
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    amproj_gateWindowCollectButtons(window, 0, buttons);
    if (!buttons.count) return NO;
    CGFloat width = window.bounds.size.width ?: 1.0;
    CGFloat height = window.bounds.size.height ?: 1.0;
    UIButton *picked = nil;
    NSString *continueTitle = @"\u7ee7\u7eed\u8fdb\u5165";
    for (UIButton *button in buttons) {
        NSString *title = button.currentTitle ?: @"";
        if ([title containsString:continueTitle]) {
            picked = button;
            break;
        }
    }
    if (!picked) {
        for (UIButton *button in buttons) {
            if (button.window != window) continue;
            CGRect frame = [window convertRect:button.bounds fromView:button];
            CGFloat centerRatio = CGRectGetMidY(frame) / height;
            CGFloat widthRatio = CGRectGetWidth(frame) / width;
            if (centerRatio > 0.70 && widthRatio > 0.40) {
                picked = button;
                break;
            }
        }
    }
    if (!picked) {
        for (UIButton *button in buttons) {
            if (button.window != window) continue;
            CGRect frame = [window convertRect:button.bounds fromView:button];
            if (CGRectGetMinX(frame) < 0.15 * width &&
                CGRectGetMinY(frame) < 0.15 * height &&
                CGRectGetWidth(frame) < 0.2 * width) {
                picked = button;
                break;
            }
        }
    }
    if (!picked) return NO;
    [picked sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}

// After any gate handling there must always be a usable key window, even if
// the gate window was the only key candidate and is now blocked.
static void amproj_ensureApplicationKeyWindow(void) {
    if (!NSThread.isMainThread) return;
    UIWindow *key = amproj_keyWindow();
    if (key && !key.hidden) return;
    UIWindow *best = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || !window.rootViewController) continue;
        if (window.windowLevel > UIWindowLevelNormal) continue;
        if (!best || window.windowLevel < best.windowLevel) best = window;
    }
#pragma clang diagnostic pop
    if (best && !best.isKeyWindow) [best makeKeyWindow];
}

static const void *amproj_gateWindowRoundsKey =
    &amproj_gateWindowRoundsKey;
static const void *amproj_gateWindowLastRoundKey =
    &amproj_gateWindowLastRoundKey;

// Device syslog for the frozen build and for the first bypass attempt fixed
// the design: the crack state machine only advances when its window runs a
// real native lifecycle (root assigned, controls wired), and it retries the
// show in a tight loop. Each gate window therefore gets a bounded number of
// native cycles: the show call proceeds exactly as the crack expects, and
// within the same runloop turn — before Core Animation commits — the cycle
// completes by hiding the window again and firing its continue/close control.
// No frame of the gate ever reaches the display, the crack finishes its own
// flow, and the application window is re-keyed every time.

// Returns YES when this hook may call the original implementation once more.
static BOOL amproj_gateCycleBegin(UIWindow *window) {
    if (!window) return NO;
    NSNumber *rounds = objc_getAssociatedObject(
        window, amproj_gateWindowRoundsKey);
    NSDate *lastCycle = objc_getAssociatedObject(
        window, amproj_gateWindowLastRoundKey);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastCycle &&
        now - lastCycle.timeIntervalSinceReferenceDate < 3.0) {
        return NO;
    }
    if (rounds.unsignedIntegerValue >= 4) return NO;
    objc_setAssociatedObject(window, amproj_gateWindowRoundsKey,
        @(rounds.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, amproj_gateWindowLastRoundKey,
        [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static void amproj_gateCycleEnd(UIWindow *window, NSString *via) {
    if (!window) return;
    BOOL fired = amproj_fireGateSkipControl(window);
    window.hidden = YES;
    amproj_ensureApplicationKeyWindow();
    NSNumber *rounds = objc_getAssociatedObject(
        window, amproj_gateWindowRoundsKey);
    amproj_logCriticalEvent(@"popup.suppressed", @{
        @"fingerprint": @"crack gate",
        @"via": via ?: @"cycle",
        @"skip_fired": @(fired),
        @"round": @(rounds.integerValue)
    });
}

// Window-sweep and presentation paths cannot replay the original call, so a
// gate that is already visible is fired and hidden here under the same
// budget and cooldown as the hook-driven cycles.
static void amproj_bypassGateWindow(UIWindow *window, NSString *source,
                                    NSString *fingerprint) {
    if (!window || !NSThread.isMainThread) return;
    if (!amproj_gateCycleBegin(window)) {
        amproj_ensureApplicationKeyWindow();
        return;
    }
    BOOL fired = amproj_fireGateSkipControl(window);
    window.hidden = YES;
    amproj_ensureApplicationKeyWindow();
    NSNumber *rounds = objc_getAssociatedObject(
        window, amproj_gateWindowRoundsKey);
    amproj_logCriticalEvent(@"popup.suppressed", @{
        @"fingerprint": fingerprint ?: @"crack gate",
        @"source": source ?: @"gate_bypass",
        @"skip_fired": @(fired),
        @"round": @(rounds.integerValue)
    });
}

// Some IPAFire builds install the welcome page directly as the key window's
// root view. In that layout there is no child overlay to remove. Hide only a
// strict, startup-only fingerprint and reveal the view once its markers are
// gone; this avoids blanking a normal AM screen after the page has closed.
static const void *amproj_IPAFireRootHiddenKey = &amproj_IPAFireRootHiddenKey;

static void amproj_IPAFireScheduleRootViewReveal(UIView *rootView) {
    if (!rootView) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (!rootView.window) {
            objc_setAssociatedObject(rootView, amproj_IPAFireRootHiddenKey,
                                     nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        if (amproj_IPAFireViewContainsMarker(rootView, 0)) {
            amproj_IPAFireScheduleRootViewReveal(rootView);
            return;
        }
        NSNumber *interactive = objc_getAssociatedObject(
            rootView, amproj_IPAFireRootHiddenKey);
        rootView.hidden = NO;
        rootView.userInteractionEnabled = interactive ? interactive.boolValue : YES;
        objc_setAssociatedObject(rootView, amproj_IPAFireRootHiddenKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static void amproj_recordPublic865LaunchNativeRoute(
    NSDictionary *launchOptions, NSString *source, BOOL forwarded) {
    if (!amproj_runtimeUsesPublic865ImportHooks() ||
        ![launchOptions isKindOfClass:NSDictionary.class]) return;
    void (^recordCandidate)(NSURL *, NSString *, NSDictionary *) =
        ^(NSURL *candidateURL, NSString *candidateSource,
          NSDictionary *candidateOptions) {
        if (!amproj_isIncomingProjectURL(candidateURL, candidateOptions)) return;
        AMProjV865ProjectFlowRecordNativeRouteDispatched(
            candidateURL, candidateSource, forwarded);
    };
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL isKindOfClass:NSURL.class]) {
        recordCandidate(launchURL, [source stringByAppendingString:@"_url"],
                        launchOptions);
    }
    id activityContainer =
        launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
    if ([activityContainer isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)activityContainer enumerateKeysAndObjectsUsingBlock:
            ^(__unused id key, id value, __unused BOOL *stop) {
            if (![value isKindOfClass:NSUserActivity.class]) return;
            NSURL *activityURL = amproj_projectURLFromUserActivity(value);
            recordCandidate(activityURL,
                [source stringByAppendingString:@"_activity"],
                amproj_projectOptionsFromUserActivity(value));
        }];
    }
    id topLevelActivity = launchOptions[kAMProjLaunchOptionsUserActivityKey];
    if ([topLevelActivity isKindOfClass:NSUserActivity.class]) {
        NSURL *activityURL = amproj_projectURLFromUserActivity(topLevelActivity);
        recordCandidate(activityURL,
            [source stringByAppendingString:@"_activity"],
            amproj_projectOptionsFromUserActivity(topLevelActivity));
    }
}

static void amproj_IPAFireHideRootViewTemporarily(UIView *rootView,
                                                  NSString *source) {
    if (!rootView) return;
    NSNumber *wasInteractive = objc_getAssociatedObject(
        rootView, amproj_IPAFireRootHiddenKey);
    if (!wasInteractive) {
        if (rootView.hidden) return;
        wasInteractive = @(rootView.userInteractionEnabled);
        objc_setAssociatedObject(rootView, amproj_IPAFireRootHiddenKey,
                                 wasInteractive, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        amproj_logCriticalEvent(@"popup.suppressed", @{
            @"fingerprint": @"IPAFire welcome",
            @"source": source ?: @"root_view",
            @"mutation": @"hide_root_view"
        });
    }
    rootView.hidden = YES;
    rootView.userInteractionEnabled = NO;
    amproj_IPAFireScheduleRootViewReveal(rootView);
}

static BOOL amproj_isIPAFireWelcome(UIViewController *controller) {
    if (![controller isKindOfClass:UIViewController.class]) return NO;
    if ([controller isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)controller;
        if (alert.preferredStyle != UIAlertControllerStyleAlert) return NO;
        NSString *content = [NSString stringWithFormat:@"%@\n%@", alert.title ?: @"", alert.message ?: @""];
        return amproj_IPAFireTextMatches(content) &&
            ([content containsString:@"Channel Telegram"] ||
             [content containsString:@"شكراً لاستخدامك تطبيقاتنا"] ||
             [content.lowercaseString containsString:@"instant certificates"]);
    }

    NSString *identity = [NSString stringWithFormat:@"%@ %@ %@ %@",
        NSStringFromClass(controller.class) ?: @"", controller.title ?: @"",
        controller.restorationIdentifier ?: @"", controller.accessibilityLabel ?: @""];
    if (amproj_IPAFireTextMatches(identity)) return YES;
    @try {
        // `viewIfLoaded` avoids forcing arbitrary AM controllers to construct
        // their view during presentation. The post-presentation probe below
        // catches welcome screens whose labels are created in viewDidAppear.
        return amproj_IPAFireViewContainsMarker(controller.viewIfLoaded, 0);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void amproj_dismissIPAFireWelcomeIfPresented(
    UIViewController *controller, NSString *source) {
    if (!controller || !amproj_isIPAFireWelcome(controller) ||
        !controller.presentingViewController) return;
    amproj_logCriticalEvent(@"popup.suppressed", @{
        @"fingerprint": @"IPAFire welcome",
        @"source": source ?: @"presentation",
        @"controller": NSStringFromClass(controller.class) ?: @""
    });
    [controller.presentingViewController dismissViewControllerAnimated:NO
                                                               completion:nil];
}

static void amproj_suppressIPAFireWelcomeWindows(NSString *source) {
    if (!amproj_runtimeIsBuild865() || !NSThread.isMainThread) return;

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState == UISceneActivationStateUnattached) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window && ![windows containsObject:window]) {
                    [windows addObject:window];
                }
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window && ![windows containsObject:window]) [windows addObject:window];
    }
#pragma clang diagnostic pop

    UIWindow *keyWindow = amproj_keyWindow();
    if (keyWindow && ![windows containsObject:keyWindow]) [windows addObject:keyWindow];

    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01) continue;

        // The Blatant license overlay is fingerprinted by its classes before
        // any text walk: its controllers and views decrypt at runtime and may
        // never expose readable labels. Only separate overlay windows above
        // the normal level are bypassed here; the app's own window keeps its
        // native lifecycle.
        if (window.windowLevel > UIWindowLevelNormal) {
            UIViewController *topForCrack =
                amproj_topViewController(window.rootViewController);
            if (AMProjPresentationChainHasCrackController(topForCrack) ||
                AMProjViewHierarchyHasCrackClass(window, 0)) {
                amproj_bypassGateWindow(window, source ?: @"window_scan",
                    @"Blatant license overlay");
                continue;
            }
            // Crack controllers registered at runtime have no image name, so
            // the class walk above can miss them. A standalone overlay window
            // (nothing presented onto its root) that hosts web content is
            // injected: Alight Motion's own web surfaces are always presented
            // controllers or live inside the normal-level key window. This is
            // how the welcome page renders when its strings are unreadable.
            UIViewController *topForWeb =
                amproj_topViewController(window.rootViewController);
            if (window.rootViewController && topForWeb &&
                !topForWeb.presentingViewController &&
                amproj_windowContainsWebView(window, 0)) {
                amproj_bypassGateWindow(window, source ?: @"window_scan_webview",
                    @"Blatant license overlay");
                continue;
            }
        }

        // A signed helper can briefly expose the page from an independent
        // UIWindow before assigning a root controller. The text walk is only
        // affordable on overlay windows; walking the app's own (SwiftUI-heavy)
        // window on every pass dominated the main thread.
        BOOL hasWindowFingerprint = NO;
        if (window.windowLevel > UIWindowLevelNormal) {
            hasWindowFingerprint = amproj_IPAFireViewContainsMarker(window, 0);
        }
        if (!window.rootViewController) {
            BOOL containsWebView = amproj_windowContainsWebView(window, 0);
            if ((hasWindowFingerprint || containsWebView) &&
                (window != keyWindow || window.windowLevel > UIWindowLevelNormal)) {
                amproj_bypassGateWindow(window, source ?: @"window_scan",
                    @"IPAFire welcome");
            }
            continue;
        }

        UIViewController *top = amproj_topViewController(window.rootViewController);
        if (top && amproj_isIPAFireWelcome(top)) {
            if (top.presentingViewController) {
                amproj_dismissIPAFireWelcomeIfPresented(top, source);
                continue;
            }
            // IPAFire can use a separate alert-level window instead of a
            // presented controller. Bypass only that identified overlay,
            // never the normal application key window.
            if (window != keyWindow && window.windowLevel > UIWindowLevelNormal) {
                amproj_bypassGateWindow(window, source ?: @"window_scan",
                    @"IPAFire welcome");
                continue;
            }

            // A normal app window may host the page as a child view instead of
            // presenting a controller. Remove only the matching child subtree.
            UIView *rootView = window.rootViewController.viewIfLoaded;
            UIView *overlay = amproj_IPAFireFindOverlayView(rootView, 0);
            if (overlay && overlay != rootView && overlay != window) {
                amproj_logCriticalEvent(@"popup.suppressed", @{
                    @"fingerprint": @"IPAFire welcome",
                    @"source": source ?: @"root_overlay_scan",
                    @"controller": NSStringFromClass(top.class) ?: @""
                });
                overlay.hidden = YES;
            } else if (rootView && amproj_IPAFireViewContainsMarker(rootView, 0)) {
                // The root-view layout has no smaller subtree to remove. The
                // fingerprint is strict and limited to build 865 startup, so
                // temporarily hiding this root is safer than leaving the
                // full-screen welcome page visible.
                amproj_IPAFireHideRootViewTemporarily(rootView, source);
            }
            continue;
        }

        UIView *rootView = window.rootViewController.viewIfLoaded;
        UIView *overlay = amproj_IPAFireFindOverlayView(rootView, 0);
        if (window != keyWindow && window.windowLevel > UIWindowLevelNormal &&
            (hasWindowFingerprint || overlay)) {
            amproj_bypassGateWindow(window, source ?: @"window_scan",
                @"IPAFire welcome");
        } else if (overlay && overlay != rootView && overlay != window) {
            amproj_logCriticalEvent(@"popup.suppressed", @{
                @"fingerprint": @"IPAFire welcome",
                @"source": source ?: @"root_overlay_scan"
            });
            overlay.hidden = YES;
        } else if (overlay == rootView &&
                   amproj_IPAFireViewContainsMarker(rootView, 0)) {
            amproj_IPAFireHideRootViewTemporarily(rootView, source);
        }
    }
}

static void amproj_scheduleIPAFireWelcomeSuppression(NSString *source) {
    if (!amproj_gateDefenseActive) return;
    if (!amproj_runtimeIsBuild865()) return;
    NSString *sourceSnapshot = [source copy] ?: @"startup";
    dispatch_async(dispatch_get_main_queue(), ^{
        amproj_suppressIPAFireWelcomeWindows(sourceSnapshot);
        // With the intro flow seeded away and the gate handled by the class
        // hooks, these passes are a cheap safety net; the early ones stay
        // dense for overlays that appear during launch.
        for (NSNumber *delay in @[@0.05, @0.3, @1.0, @2.0,
                                  @4.0, @8.0, @15.0, @21.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                amproj_suppressIPAFireWelcomeWindows(sourceSnapshot);
            });
        }
    });
}

// A self-signed build can leave StoreKit's SwiftUI paywall in an indefinite
// loading state before any accessibility strings are exposed. Keep a short
// startup-only fallback window so normal, intentionally opened subscription
// screens are never treated as stuck pages.
static CFAbsoluteTime amproj_paywallStartupFallbackUntil = 0;
static CFAbsoluteTime amproj_startupPaywallSuppressionUntil = 0;

typedef NS_ENUM(NSUInteger, AMProjStartupPaywallState) {
    AMProjStartupPaywallStateIdle = 0,
    AMProjStartupPaywallStateArmed,
    AMProjStartupPaywallStatePresentationSeen,
    AMProjStartupPaywallStateOuterPresented,
    AMProjStartupPaywallStateDismissRequested,
    AMProjStartupPaywallStateVerifying,
    AMProjStartupPaywallStateFallbackVisible,
    AMProjStartupPaywallStateMainVisible,
};

static AMProjStartupPaywallState amproj_startupPaywallState =
    AMProjStartupPaywallStateIdle;
static CFAbsoluteTime amproj_startupPaywallStartedAt = 0;
static NSUInteger amproj_startupPaywallGeneration = 0;
static NSUInteger amproj_startupPaywallDismissSequence = 0;
static NSUInteger amproj_startupPaywallDismissFailures = 0;
static BOOL amproj_startupPaywallDismissInFlight = NO;
static BOOL amproj_startupPaywallOuterPresentedRecorded = NO;
static CFAbsoluteTime amproj_startupPaywallTailSuppressionUntil = 0;

static void amproj_armPaywallStartupFallback(void) {
    if (![NSThread isMainThread]) return;
    if (amproj_paywallStartupFallbackUntil <= 0) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        // Device timeline (17:48 launch): the crack gate completes around
        // 17:48:33, and the subscription wall is only presented at ~17:51 —
        // well past the previous 120s window, which is why it survived. The
        // dismissal window now covers the whole startup funnel.
        amproj_paywallStartupFallbackUntil = now + 600.0;
        amproj_startupPaywallSuppressionUntil = now + 30.0;
        amproj_startupPaywallState = AMProjStartupPaywallStateArmed;
    }
}

static BOOL amproj_paywallContentContainsAny(NSString *content,
                                             NSArray<NSString *> *markers) {
    if (!content.length) return NO;
    for (NSString *marker in markers) {
        if (marker.length && [content containsString:marker]) return YES;
    }
    return NO;
}

static NSArray *amproj_accessibilityChildren(UIView *view) {
    if (!view) return @[];
    NSMutableArray *children = [NSMutableArray array];
    @try {
        NSArray *declared = view.accessibilityElements;
        if ([declared isKindOfClass:NSArray.class]) [children addObjectsFromArray:declared];
        NSInteger count = [view accessibilityElementCount];
        if (count > 0 && count != NSNotFound && count <= 256) {
            for (NSInteger index = 0; index < count; index++) {
                id element = [view accessibilityElementAtIndex:index];
                if (element && ![children containsObject:element]) [children addObject:element];
            }
        }
    } @catch (__unused NSException *exception) {
        // Some SwiftUI containers do not expose an accessibility tree until
        // their first layout pass. The ordinary subview walk remains valid.
    }
    return children;
}

static void amproj_appendPaywallViewText(UIView *view, NSMutableString *output,
                                         NSMutableSet<NSValue *> *visited,
                                         NSUInteger depth) {
    if (!view || !output || depth > 32) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    NSArray<NSString *> *values = @[
        view.accessibilityLabel ?: @"",
        [view.accessibilityValue isKindOfClass:NSString.class] ? view.accessibilityValue : @"",
        [view.accessibilityHint isKindOfClass:NSString.class] ? view.accessibilityHint : @"",
        [view isKindOfClass:UILabel.class] ? ((UILabel *)view).text ?: @"" : @"",
        [view isKindOfClass:UITextView.class] ? ((UITextView *)view).text ?: @"" : @"",
        [view isKindOfClass:UITextField.class] ? ((UITextField *)view).text ?: @"" : @""
    ];
    for (NSString *value in values) {
        if (value.length) {
            [output appendString:value];
            [output appendString:@"\n"];
        }
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal];
        if (title.length) {
            [output appendString:title];
            [output appendString:@"\n"];
        }
    }
    // SwiftUI often exposes its visible strings as UIAccessibilityElement
    // objects instead of UILabel subviews. Include that tree without forcing
    // view loading or reading arbitrary model/KVC values.
    NSArray *accessibilityElements = amproj_accessibilityChildren(view);
    if ([accessibilityElements isKindOfClass:NSArray.class]) {
        for (id element in accessibilityElements) {
            if (!element) continue;
            if ([element isKindOfClass:UIView.class]) {
                amproj_appendPaywallViewText((UIView *)element, output, visited, depth + 1);
                continue;
            }
            NSValue *elementIdentity = [NSValue valueWithPointer:(__bridge const void *)element];
            if ([visited containsObject:elementIdentity]) continue;
            [visited addObject:elementIdentity];
            for (NSString *selectorName in @[
                NSStringFromSelector(@selector(accessibilityLabel)),
                NSStringFromSelector(@selector(accessibilityValue)),
                NSStringFromSelector(@selector(accessibilityHint))
            ]) {
                SEL actualSelector = NSSelectorFromString(selectorName);
                if (![element respondsToSelector:actualSelector]) continue;
                NSString *value = ((id (*)(id, SEL))objc_msgSend)(element, actualSelector);
                if ([value isKindOfClass:NSString.class] && value.length) {
                    [output appendString:value];
                    [output appendString:@"\n"];
                }
            }
        }
    }
    for (UIView *child in view.subviews) {
        amproj_appendPaywallViewText(child, output, visited, depth + 1);
    }
}

static NSString *amproj_paywallTextForController(UIViewController *controller) {
    if (!controller) return @"";
    NSMutableString *text = [NSMutableString string];
    NSString *className = NSStringFromClass(controller.class);
    if (className.length) [text appendFormat:@"%@\n", className];
    if (controller.title.length) [text appendFormat:@"%@\n", controller.title];
    if (controller.navigationItem.title.length) {
        [text appendFormat:@"%@\n", controller.navigationItem.title];
    }
    UIView *view = controller.viewIfLoaded;
    if (view) {
        amproj_appendPaywallViewText(view, text, [NSMutableSet set], 0);
    }
    return text;
}

static BOOL amproj_paywallLayerHasAnimation(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > 8) return NO;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    BOOL compactSquare = width >= 16.0 && width <= 240.0 &&
        height >= 16.0 && height <= 240.0 && fabs(width - height) <= 24.0;
    if (compactSquare) {
        for (NSString *key in layer.animationKeys) {
            CAAnimation *animation = [layer animationForKey:key];
            if (animation && (isinf(animation.repeatCount) ||
                              isinf(animation.repeatDuration) ||
                              animation.repeatCount >= 8.0f ||
                              animation.repeatDuration >= 8.0)) {
                return YES;
            }
        }
    }
    for (CALayer *child in layer.sublayers) {
        if (amproj_paywallLayerHasAnimation(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL amproj_paywallViewHasLoadingIndicator(UIView *view,
                                                  NSMutableSet<NSValue *> *visited,
                                                  NSUInteger depth) {
    if (!view || depth > 32) return NO;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return NO;
    [visited addObject:identity];
    NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
    NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
    BOOL namedLoadingView = [className containsString:@"paywallloading"] ||
        [className containsString:@"loadingview"] ||
        [className containsString:@"progressview"] ||
        [className containsString:@"spinner"] ||
        [className containsString:@"activityindicator"] ||
        [label containsString:@"loading"] || [label containsString:@"加载"] ||
        [label containsString:@"正在加载"];
    if ([className containsString:@"paywallloading"] ||
        [label containsString:@"loading"] || [label containsString:@"加载"] ||
        [label containsString:@"正在加载"]) return YES;
    if ([view isKindOfClass:UIActivityIndicatorView.class] &&
        !view.hidden && view.alpha > 0.01) return YES;
    if (namedLoadingView && view.layer.animationKeys.count) return YES;
    if (namedLoadingView && ([view isKindOfClass:UIActivityIndicatorView.class] ||
                             [view isKindOfClass:UIProgressView.class])) return YES;
    if (amproj_paywallLayerHasAnimation(view.layer, 0)) return YES;
    for (UIView *child in view.subviews) {
        if (amproj_paywallViewHasLoadingIndicator(child, visited, depth + 1)) return YES;
    }
    return NO;
}

static BOOL amproj_isPaywallController(UIViewController *controller,
                                       NSDictionary **evidenceOut) {
    if (!controller) return NO;
    UIView *view = controller.viewIfLoaded;
    if (view && (view.hidden || view.alpha <= 0.01 || !view.window)) return NO;

    NSString *rawText = amproj_paywallTextForController(controller);
    NSString *content = rawText.lowercaseString;
    BOOL plan = amproj_paywallContentContainsAny(content, @[
        @"选择一个套餐", @"选择套餐", @"choose a plan", @"select a plan",
        @"choose a subscription", @"select a subscription"
    ]);
    BOOL purchased = amproj_paywallContentContainsAny(content, @[
        @"已经购买", @"已购买", @"already purchased", @"restore purchase",
        @"restore purchases"
    ]);
    BOOL cadence = amproj_paywallContentContainsAny(content, @[
        @"每周", @"每年", @"weekly", @"yearly", @"per week", @"per year",
        @"week", @"year"
    ]);
    BOOL continueMarker = amproj_paywallContentContainsAny(content, @[
        @"继续", @"continue", @"start free trial", @"subscribe"
    ]);
    NSString *className = NSStringFromClass(controller.class).lowercaseString ?: @"";
    BOOL classHint = [className containsString:@"paywall"] ||
        [className containsString:@"monetization"] ||
        [className containsString:@"comparison"] ||
        [className containsString:@"purchase"] ||
        [className containsString:@"subscription"] ||
        [className containsString:@"otheroptions"];
    BOOL loading = amproj_paywallViewHasLoadingIndicator(
        view, [NSMutableSet set], 0);
    BOOL markerMatch = plan && continueMarker &&
        ((purchased && cadence) || (purchased && classHint) || (cadence && classHint));
    UINavigationController *navigation = controller.navigationController;
    BOOL hostingClass = [className containsString:@"hosting"] ||
        [className containsString:@"storeproduct"];
    BOOL hasPresentationChain = controller.presentingViewController != nil ||
        navigation.presentingViewController != nil ||
        navigation.viewControllers.count > 1;
    BOOL hostedAtWindowRoot = view.window.rootViewController == controller ||
        (navigation && view.window.rootViewController == navigation);
    BOOL startupLoadingFallback = loading && hostingClass &&
        (hasPresentationChain || hostedAtWindowRoot) &&
        CFAbsoluteTimeGetCurrent() < amproj_paywallStartupFallbackUntil;
    if ((!markerMatch && !startupLoadingFallback) || !loading) return NO;

    if (evidenceOut) {
        *evidenceOut = @{
            @"controller": NSStringFromClass(controller.class) ?: @"",
            @"plan": @(plan),
            @"purchased": @(purchased),
            @"cadence": @(cadence),
            @"continue": @(continueMarker),
            @"class_hint": @(classHint),
            @"loading": @(loading),
            @"startup_fallback": @(startupLoadingFallback)
        };
    }
    return YES;
}

static void amproj_recordPaywallControllerAppearance(UIViewController *controller) {
#if AMPROJ_DEBUG
    if (!controller) return;
    NSString *className = NSStringFromClass(controller.class) ?: @"";
    NSString *classLower = className.lowercaseString;
    NSString *content = amproj_paywallTextForController(controller).lowercaseString;
    BOOL classHint = [classLower containsString:@"hosting"] ||
        [classLower containsString:@"paywall"] ||
        [classLower containsString:@"monetization"] ||
        [classLower containsString:@"purchase"] ||
        [classLower containsString:@"subscription"] ||
        [classLower containsString:@"storeproduct"];
    BOOL plan = amproj_paywallContentContainsAny(content, @[
        @"选择一个套餐", @"选择套餐", @"choose a plan", @"select a plan"
    ]);
    BOOL purchased = amproj_paywallContentContainsAny(content, @[
        @"已经购买", @"已购买", @"already purchased", @"restore purchase"
    ]);
    BOOL cadence = amproj_paywallContentContainsAny(content, @[
        @"每周", @"每年", @"weekly", @"yearly", @"per week", @"per year"
    ]);
    BOOL continueMarker = amproj_paywallContentContainsAny(content, @[
        @"继续", @"continue", @"start free trial", @"subscribe"
    ]);
    if (!classHint && !plan && !purchased && !cadence && !continueMarker) return;
    static NSMutableSet<NSString *> *reported;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ reported = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@/%d%d%d%d", className,
                     plan, purchased, cadence, continueMarker];
    if ([reported containsObject:key]) return;
    [reported addObject:key];
    UIView *view = controller.viewIfLoaded;
    BOOL loading = amproj_paywallViewHasLoadingIndicator(view, [NSMutableSet set], 0);
    amproj_debugEvent(@"paywall.controller_appeared", @{
        @"controller": className,
        @"view": NSStringFromClass(view.class) ?: @"",
        @"text_length": @(content.length),
        @"plan": @(plan),
        @"purchased": @(purchased),
        @"cadence": @(cadence),
        @"continue": @(continueMarker),
        @"loading": @(loading),
        @"has_window": @(view.window != nil),
        @"presenting": NSStringFromClass(controller.presentingViewController.class) ?: @""
    });
#else
    (void)controller;
#endif
}

static UIViewController *amproj_findPaywallController(UIViewController *controller,
                                                       NSMutableSet<NSValue *> *visited,
                                                       NSUInteger depth,
                                                       NSDictionary **evidenceOut) {
    if (!controller || depth > 16) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    // Check the visible modal/content child first so a paywall nested in a
    // navigation controller is dismissed at the correct presentation level.
    if (controller.presentedViewController) {
        UIViewController *found = amproj_findPaywallController(
            controller.presentedViewController, visited, depth + 1, evidenceOut);
        if (found) return found;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        UIViewController *found = amproj_findPaywallController(
            ((UINavigationController *)controller).visibleViewController,
            visited, depth + 1, evidenceOut);
        if (found) return found;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = amproj_findPaywallController(
            child, visited, depth + 1, evidenceOut);
        if (found) return found;
    }
    if (amproj_isPaywallController(controller, evidenceOut)) return controller;
    return nil;
}

static id amproj_findPaywallCloseView(UIView *view,
                                      NSMutableSet<NSValue *> *visited,
                                      NSUInteger depth) {
    if (!view || depth > 32) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
    NSString *title = @"";
    if ([view isKindOfClass:UIButton.class]) {
        title = [((UIButton *)view) titleForState:UIControlStateNormal].lowercaseString ?: @"";
    }
    BOOL closeLabel = [title isEqualToString:@"x"] || [title containsString:@"关闭"] ||
        [title containsString:@"close"] || [label isEqualToString:@"x"] ||
        [label containsString:@"关闭"] || [label containsString:@"close"];
    if (closeLabel && (view.isAccessibilityElement || [view isKindOfClass:UIButton.class])) {
        return view;
    }
    NSArray *accessibilityElements = amproj_accessibilityChildren(view);
    if ([accessibilityElements isKindOfClass:NSArray.class]) {
        for (id element in accessibilityElements) {
            if (!element || [element isKindOfClass:UIView.class]) continue;
            NSString *label = nil;
            if ([element respondsToSelector:@selector(accessibilityLabel)]) {
                label = ((id (*)(id, SEL))objc_msgSend)(
                    element, @selector(accessibilityLabel));
            }
            NSString *normalized = label.lowercaseString ?: @"";
            BOOL accessibilityClose = [normalized isEqualToString:@"x"] ||
                [normalized isEqualToString:@"×"] ||
                [normalized isEqualToString:@"close"] ||
                [normalized isEqualToString:@"关闭"] ||
                [normalized isEqualToString:@"取消"];
            CGRect accessibilityFrame = CGRectNull;
            if ([element respondsToSelector:@selector(accessibilityFrame)]) {
                accessibilityFrame = ((CGRect (*)(id, SEL))objc_msgSend)(
                    element, @selector(accessibilityFrame));
            }
            BOOL topLeftAction = !CGRectIsNull(accessibilityFrame) &&
                !CGRectIsEmpty(accessibilityFrame) &&
                CGRectGetMinX(accessibilityFrame) >= 0.0 &&
                CGRectGetMinX(accessibilityFrame) <= 128.0 &&
                CGRectGetMinY(accessibilityFrame) >= 40.0 &&
                CGRectGetMinY(accessibilityFrame) <= 260.0 &&
                CGRectGetWidth(accessibilityFrame) <= 128.0 &&
                CGRectGetHeight(accessibilityFrame) <= 128.0;
            if ((accessibilityClose || topLeftAction) &&
                [element respondsToSelector:@selector(accessibilityActivate)]) {
                return element;
            }
        }
    }
    for (UIView *child in view.subviews) {
        id closeView = amproj_findPaywallCloseView(child, visited, depth + 1);
        if (closeView) return closeView;
    }
    return nil;
}

static UIControl *amproj_findTopLeftPaywallControl(UIView *view,
                                                    NSMutableSet<NSValue *> *visited,
                                                    NSUInteger depth) {
    if (!view || depth > 32) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)view];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    if ([view isKindOfClass:UIControl.class] && view.window) {
        CGRect frame = [view convertRect:view.bounds toView:view.window];
        if (CGRectGetMinX(frame) >= 0.0 && CGRectGetMinX(frame) <= 128.0 &&
            CGRectGetMinY(frame) >= 72.0 && CGRectGetMinY(frame) <= 260.0 &&
            CGRectGetWidth(frame) <= 128.0 && CGRectGetHeight(frame) <= 128.0) {
            return (UIControl *)view;
        }
    }
    for (UIView *child in view.subviews) {
        UIControl *control = amproj_findTopLeftPaywallControl(child, visited, depth + 1);
        if (control) return control;
    }
    return nil;
}

static void amproj_recordPaywallScanRoot(UIViewController *root, NSString *source) {
#if AMPROJ_DEBUG
    if (!root) return;
    static NSMutableSet<NSValue *> *reported;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ reported = [NSMutableSet set]; });
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)root];
    if ([reported containsObject:identity]) return;
    [reported addObject:identity];

    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    __block void (^walk)(UIViewController *, NSUInteger);
    walk = ^(UIViewController *controller, NSUInteger depth) {
        if (!controller || depth > 8 || classes.count >= 32) return;
        NSValue *controllerID = [NSValue valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:controllerID]) return;
        [visited addObject:controllerID];
        NSString *name = NSStringFromClass(controller.class) ?: @"";
        if (name.length) [classes addObject:name];
        walk(controller.presentedViewController, depth + 1);
        if ([controller isKindOfClass:UINavigationController.class]) {
            walk(((UINavigationController *)controller).visibleViewController, depth + 1);
        }
        for (UIViewController *child in controller.childViewControllers) {
            walk(child, depth + 1);
        }
    };
    walk(root, 0);
    walk = nil;
    UIView *view = root.viewIfLoaded;
    NSString *content = amproj_paywallTextForController(root).lowercaseString;
    amproj_debugEvent(@"paywall.scan_root", @{
        @"source": source ?: @"unknown",
        @"root": NSStringFromClass(root.class) ?: @"",
        @"classes": classes,
        @"text_length": @(content.length),
        @"loading": @(amproj_paywallViewHasLoadingIndicator(view, [NSMutableSet set], 0)),
        @"has_window": @(view.window != nil),
        @"presented": NSStringFromClass(root.presentedViewController.class) ?: @""
    });
#else
    (void)root;
    (void)source;
#endif
}

static void amproj_dismissDetectedPaywallFrom(UIViewController *candidate,
                                              NSString *source) {
    if (![NSThread isMainThread]) {
        __weak UIViewController *weakCandidate = candidate;
        NSString *sourceCopy = [source copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_dismissDetectedPaywallFrom(weakCandidate, sourceCopy);
        });
        return;
    }
    if (!candidate) return;
    amproj_recordPaywallScanRoot(candidate, source);
    NSDictionary *evidence = nil;
    UIViewController *paywall = amproj_findPaywallController(
        candidate, [NSMutableSet set], 0, &evidence);
    if (!paywall) return;
    NSString *paywallClassName = NSStringFromClass(paywall.class) ?: @"";
    BOOL startupTransactionOwnsPaywall =
        amproj_startupPaywallState != AMProjStartupPaywallStateIdle &&
        amproj_startupPaywallState != AMProjStartupPaywallStateArmed &&
        amproj_startupPaywallState != AMProjStartupPaywallStateMainVisible &&
        ([paywallClassName containsString:@"PaywallLoadingScreenView"] ||
         [paywallClassName containsString:@"CloudCardsTiersPaywallView"]);
    if (startupTransactionOwnsPaywall) {
        amproj_debugEvent(@"startup_loading.legacy_scan_deferred", @{
            @"source": source ?: @"unknown",
            @"controller": paywallClassName
        });
        return;
    }

    static __weak UIViewController *lastPaywall;
    static CFAbsoluteTime lastDismissAt = 0;
    static __weak UIViewController *activePaywallAction;
    static CFAbsoluteTime activePaywallActionAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastPaywall == paywall && now - lastDismissAt < 10.0) return;
    if (activePaywallAction == paywall && now - activePaywallActionAt < 2.0) return;

    NSMutableDictionary *fields = [evidence mutableCopy] ?: [NSMutableDictionary dictionary];
    fields[@"source"] = source ?: @"unknown";
    amproj_debugEvent(@"paywall.detected", fields);
    NSLog(@"[AMProjExport] Detected stalled subscription paywall (%@)",
          fields[@"controller"] ?: @"");

    UIViewController *dismissOwner = paywall;
    while (dismissOwner.parentViewController && !dismissOwner.presentingViewController) {
        dismissOwner = dismissOwner.parentViewController;
    }
    UIViewController *presentingController = dismissOwner.presentingViewController ?
        dismissOwner.presentingViewController : paywall.presentingViewController;
    BOOL hasModalPresentation = presentingController != nil;
    if (hasModalPresentation) {
        activePaywallAction = paywall;
        activePaywallActionAt = now;
        __weak UIViewController *weakPaywall = paywall;
        [presentingController dismissViewControllerAnimated:YES completion:^{
            UIViewController *remaining = weakPaywall;
            BOOL gone = !remaining ||
                (!remaining.presentingViewController && !remaining.viewIfLoaded.window);
            amproj_debugEvent(gone ? @"paywall.dismissed" : @"paywall.dismiss_failed", @{
                @"source": source ?: @"unknown",
                @"controller": fields[@"controller"] ?: @"",
                @"method": @"dismiss",
                @"gone": @(gone)
            });
            if (gone) {
                lastPaywall = remaining;
                lastDismissAt = CFAbsoluteTimeGetCurrent();
                activePaywallAction = nil;
            } else {
                activePaywallAction = nil;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_dismissDetectedPaywallFrom(remaining, @"dismiss_verify");
                });
            }
        }];
        return;
    }

    UINavigationController *navigation = paywall.navigationController;
    if (navigation.topViewController == paywall && navigation.viewControllers.count > 1) {
        activePaywallAction = paywall;
        activePaywallActionAt = now;
        [navigation popViewControllerAnimated:YES];
        lastPaywall = paywall;
        lastDismissAt = now;
        activePaywallAction = nil;
        amproj_debugEvent(@"paywall.dismissed", @{
            @"source": source ?: @"unknown",
            @"controller": fields[@"controller"] ?: @"",
            @"method": @"navigation_pop"
        });
        return;
    }

    // Do not hide a root window to escape this state. UIKit can report transient
    // keyboard/tracking windows as an "alternate" window; hiding the real AM
    // window in that case leaves the process foregrounded on a black screen.
    // A root-hosted page may only be dismissed through its own close control.
    id closeView = amproj_findPaywallCloseView(
        paywall.viewIfLoaded, [NSMutableSet set], 0);
    if (!closeView) {
        closeView = amproj_findTopLeftPaywallControl(
            paywall.viewIfLoaded, [NSMutableSet set], 0);
    }
    if (closeView) {
        activePaywallAction = paywall;
        activePaywallActionAt = now;
        BOOL activated = NO;
        if ([closeView isKindOfClass:UIControl.class]) {
            UIControl *control = (UIControl *)closeView;
            control.enabled = YES;
            control.userInteractionEnabled = YES;
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            activated = YES;
        } else if ([closeView respondsToSelector:@selector(accessibilityActivate)]) {
            activated = ((BOOL (*)(id, SEL))objc_msgSend)(
                closeView, @selector(accessibilityActivate));
        }
        if (!activated) {
            activePaywallAction = nil;
            amproj_debugEvent(@"paywall.dismiss_failed", @{
                @"source": source ?: @"unknown",
                @"controller": fields[@"controller"] ?: @"",
                @"reason": @"close_activation_rejected"
            });
            return;
        }
        lastPaywall = paywall;
        lastDismissAt = now;
        amproj_debugEvent(@"paywall.dismissed", @{
            @"source": source ?: @"unknown",
            @"controller": fields[@"controller"] ?: @"",
            @"method": @"close_button",
            @"accessibility": @YES
        });
        __weak UIViewController *weakPaywall = paywall;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            UIViewController *remaining = weakPaywall;
            if (!remaining || !remaining.viewIfLoaded.window) return;
            lastPaywall = nil;
            activePaywallAction = nil;
            amproj_debugEvent(@"paywall.dismiss_failed", @{
                @"source": source ?: @"unknown",
                @"controller": fields[@"controller"] ?: @"",
                @"reason": @"close_button_still_visible"
            });
            amproj_dismissDetectedPaywallFrom(remaining, @"close_verify");
        });
    } else {
        amproj_debugEvent(@"paywall.dismiss_failed", @{
            @"source": source ?: @"unknown",
            @"controller": fields[@"controller"] ?: @"",
            @"reason": @"no_modal_or_labelled_close_button"
        });
    }
}

static void amproj_scanVisiblePaywall(NSString *source) {
    if (![NSThread isMainThread]) {
        NSString *sourceCopy = [source copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_scanVisiblePaywall(sourceCopy);
        });
        return;
    }
    NSMutableSet<NSValue *> *seenWindows = [NSMutableSet set];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateUnattached) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.rootViewController || window.hidden || window.alpha <= 0.01) continue;
            NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
            if ([seenWindows containsObject:identity]) continue;
            [seenWindows addObject:identity];
            amproj_dismissDetectedPaywallFrom(window.rootViewController, source);
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.rootViewController || window.hidden || window.alpha <= 0.01) continue;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([seenWindows containsObject:identity]) continue;
        [seenWindows addObject:identity];
        amproj_dismissDetectedPaywallFrom(window.rootViewController, source);
    }
}

static void amproj_schedulePaywallScan(UIViewController *candidate, NSString *source) {
#if !AMPROJ_DEBUG
    // The recursive release scan can walk and activate arbitrary SwiftUI
    // controls.  On 6.2.55 that includes project/template delete surfaces;
    // keep this diagnostic/recovery behavior Debug-only so stable builds do
    // not mutate unrelated native screens.
    (void)candidate;
    (void)source;
    return;
#else
    NSString *sourceCopy = [source copy] ?: @"unknown";
    __weak UIViewController *weakCandidate = candidate;
    NSArray<NSNumber *> *delays = @[
        @0.05, @0.25, @0.75, @1.5, @3.0, @6.0, @10.0, @20.0, @40.0, @80.0
    ];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                      (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *root = weakCandidate;
            if (root) {
                amproj_dismissDetectedPaywallFrom(root, sourceCopy);
            } else {
                amproj_scanVisiblePaywall(sourceCopy);
            }
        });
    }
#endif
}

// MARK: - Startup paywall recovery

typedef NS_ENUM(NSUInteger, AMProjStartupPresentationDecision) {
    AMProjStartupPresentationDecisionPass = 0,
    AMProjStartupPresentationDecisionTrackOuter,
    AMProjStartupPresentationDecisionSuppress,
};

static __weak UIViewController *amproj_startupPaywallOuter;
static __weak UIViewController *amproj_startupPaywallSuppressedRetryOuter;
static __weak UIViewController *amproj_startupPaywallPresenter;
static __weak UIButton *amproj_startupPaywallFallbackButton;
static __weak UIButton *amproj_startupPaywallCloseButton;
static NSUInteger amproj_startupPaywallRescueGeneration = 0;

static NSString *amproj_startupPaywallStateName(void) {
    switch (amproj_startupPaywallState) {
        case AMProjStartupPaywallStateArmed: return @"armed";
        case AMProjStartupPaywallStatePresentationSeen: return @"presentation_seen";
        case AMProjStartupPaywallStateOuterPresented: return @"outer_presented";
        case AMProjStartupPaywallStateDismissRequested: return @"dismiss_requested";
        case AMProjStartupPaywallStateVerifying: return @"verifying";
        case AMProjStartupPaywallStateFallbackVisible: return @"fallback_visible";
        case AMProjStartupPaywallStateMainVisible: return @"main_visible";
        default: return @"idle";
    }
}

static void amproj_startupPaywallEvent(NSString *name,
                                       NSDictionary<NSString *, id> *extra) {
    NSMutableDictionary *fields = [extra mutableCopy] ?: [NSMutableDictionary dictionary];
    fields[@"state"] = amproj_startupPaywallStateName();
    fields[@"failure_count"] = @(amproj_startupPaywallDismissFailures);
    fields[@"failure"] = [fields[@"failure"] isKindOfClass:NSString.class]
        ? fields[@"failure"] : @"";
    if (amproj_startupPaywallStartedAt > 0) {
        fields[@"elapsed_ms"] = @((CFAbsoluteTimeGetCurrent() -
                                     amproj_startupPaywallStartedAt) * 1000.0);
    }
    amproj_debugEvent([@"startup_loading." stringByAppendingString:name], fields);
}

static BOOL amproj_isStartupPaywallClassName(NSString *className) {
    return [className containsString:@"PaywallLoadingScreenView"] ||
        [className containsString:@"CloudCardsTiersPaywallView"];
}

static BOOL amproj_isStartupPaywallOuterClassName(NSString *className) {
    return [className containsString:@"PaywallLoadingScreenView"];
}

static BOOL amproj_isStartupPresenterClassName(NSString *className) {
    return [className containsString:
        @"NodeHostingControllerWithCustomStatusbarContent"];
}

static void amproj_inspectStartupController(UIViewController *controller,
                                            UIWindow *window,
                                            NSMutableSet<NSValue *> *visited,
                                            BOOL *mainNCVisible,
                                            BOOL *mainVCVisible,
                                            BOOL *paywallVisible,
                                            UIViewController *__autoreleasing *paywallOut) {
    if (!controller) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];

    UIView *view = controller.viewIfLoaded;
    BOOL mounted = view.window == window && !view.hidden && view.alpha > 0.01;
    NSString *className = NSStringFromClass(controller.class) ?: @"";
    if (mounted && ([className isEqualToString:@"AlightMotion.MainNC"] ||
                    [className hasSuffix:@".MainNC"])) {
        if (mainNCVisible) *mainNCVisible = YES;
    }
    if (mounted && ([className isEqualToString:@"AlightMotion.MainVC"] ||
                    [className hasSuffix:@".MainVC"])) {
        if (mainVCVisible) *mainVCVisible = YES;
    }
    if (mounted && amproj_isStartupPaywallClassName(className)) {
        if (paywallVisible) *paywallVisible = YES;
        if (paywallOut && !*paywallOut) *paywallOut = controller;
    }

    amproj_inspectStartupController(controller.presentedViewController, window,
        visited, mainNCVisible, mainVCVisible, paywallVisible, paywallOut);
    if ([controller isKindOfClass:UINavigationController.class]) {
        amproj_inspectStartupController(
            ((UINavigationController *)controller).visibleViewController, window,
            visited, mainNCVisible, mainVCVisible, paywallVisible, paywallOut);
    }
    for (UIViewController *child in controller.childViewControllers) {
        amproj_inspectStartupController(child, window, visited, mainNCVisible,
            mainVCVisible, paywallVisible, paywallOut);
    }
}

static void amproj_startupPaywallSnapshot(BOOL *mainVisibleOut,
                                           BOOL *paywallVisibleOut,
                                           UIWindow *__autoreleasing *mainWindowOut,
                                           UIViewController *__autoreleasing *paywallOut) {
    BOOL mainNCVisible = NO;
    BOOL mainVCVisible = NO;
    BOOL paywallVisible = NO;
    UIWindow *mainWindow = nil;
    UIViewController *visiblePaywall = nil;
    NSMutableSet<NSValue *> *seenWindows = [NSMutableSet set];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateUnattached) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
    for (UIWindow *window in windows) {
        if (!window.rootViewController || window.hidden || window.alpha <= 0.01) continue;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([seenWindows containsObject:identity]) continue;
        [seenWindows addObject:identity];
        BOOL windowMainNC = NO;
        BOOL windowMainVC = NO;
        amproj_inspectStartupController(window.rootViewController, window,
            [NSMutableSet set], &windowMainNC, &windowMainVC, &paywallVisible,
            &visiblePaywall);
        if ((windowMainNC || windowMainVC) && !mainWindow) mainWindow = window;
        mainNCVisible |= windowMainNC;
        mainVCVisible |= windowMainVC;
    }
    if (mainVisibleOut) *mainVisibleOut = mainNCVisible && mainVCVisible;
    if (paywallVisibleOut) *paywallVisibleOut = paywallVisible;
    if (mainWindowOut) *mainWindowOut = mainWindow;
    if (paywallOut) *paywallOut = visiblePaywall;
}

static void amproj_reconcileStartupPaywall(NSUInteger generation,
                                            NSString *source);
static void amproj_requestStartupPaywallDismiss(NSUInteger generation,
                                                 NSString *source);

static UIWindow *amproj_foregroundApplicationWindow(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateUnattached ||
            scene.activationState == UISceneActivationStateBackground) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    [windows addObjectsFromArray:UIApplication.sharedApplication.windows];

    UIWindow *best = nil;
    CGFloat bestArea = 0.0;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIWindow *window in windows) {
        if (!window.rootViewController || window.hidden || window.alpha <= 0.01 ||
            window.windowLevel > UIWindowLevelAlert) continue;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([visited containsObject:identity]) continue;
        [visited addObject:identity];
        CGFloat area = CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds);
        if (window.isKeyWindow) return window;
        if (area > bestArea) {
            best = window;
            bestArea = area;
        }
    }
    return best;
}

static void amproj_removeStartupPaywallFallbackButton(void) {
    UIButton *button = amproj_startupPaywallFallbackButton;
    UIButton *closeButton = amproj_startupPaywallCloseButton;
    [button removeFromSuperview];
    [closeButton removeFromSuperview];
    amproj_startupPaywallFallbackButton = nil;
    amproj_startupPaywallCloseButton = nil;
}

static UIViewController *amproj_findExactStartupPaywall(
    UIViewController *controller, UIWindow *window,
    NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!controller || depth > 16) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    UIViewController *found = amproj_findExactStartupPaywall(
        controller.presentedViewController, window, visited, depth + 1);
    if (found) return found;
    if ([controller isKindOfClass:UINavigationController.class]) {
        found = amproj_findExactStartupPaywall(
            ((UINavigationController *)controller).visibleViewController,
            window, visited, depth + 1);
        if (found) return found;
    }
    NSArray<UIViewController *> *children = controller.childViewControllers;
    for (UIViewController *child in [children reverseObjectEnumerator]) {
        found = amproj_findExactStartupPaywall(
            child, window, visited, depth + 1);
        if (found) return found;
    }

    NSString *className = NSStringFromClass(controller.class) ?: @"";
    UIView *view = controller.viewIfLoaded;
    if (view.window == window && !view.hidden && view.alpha > 0.01 &&
        amproj_isStartupPaywallClassName(className)) {
        return controller;
    }
    return nil;
}

static UIViewController *amproj_visibleStartupPaywall(UIWindow **windowOut) {
    UIWindow *preferred = amproj_foregroundApplicationWindow();
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (preferred) [windows addObject:preferred];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState == UISceneActivationStateUnattached ||
            scene.activationState == UISceneActivationStateBackground) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    [windows addObjectsFromArray:UIApplication.sharedApplication.windows];

    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIWindow *window in windows) {
        if (!window.rootViewController || window.hidden || window.alpha <= 0.01) continue;
        NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)window];
        if ([visited containsObject:identity]) continue;
        [visited addObject:identity];
        UIViewController *paywall = amproj_findExactStartupPaywall(
            window.rootViewController, window, [NSMutableSet set], 0);
        if (paywall) {
            if (windowOut) *windowOut = window;
            return paywall;
        }
    }
    if (windowOut) *windowOut = preferred;
    return nil;
}

static void amproj_verifyManualStartupExit(UIViewController *paywall,
                                           NSString *source) {
    __weak UIViewController *weakPaywall = paywall;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        UIViewController *remaining = weakPaywall;
        BOOL gone = !remaining || !remaining.viewIfLoaded.window;
        amproj_startupPaywallEvent(gone ? @"manual_exit_succeeded" :
                                        @"manual_exit_pending", @{
            @"source": source ?: @"manual",
            @"failure": gone ? @"" : @"paywall_still_visible"
        });
        if (gone) {
            amproj_removeStartupPaywallFallbackButton();
            return;
        }
        UIWindow *window = remaining.viewIfLoaded.window;
        UIButton *closeButton = amproj_startupPaywallCloseButton;
        UIButton *continueButton = amproj_startupPaywallFallbackButton;
        if (closeButton.superview == window) [window bringSubviewToFront:closeButton];
        if (continueButton.superview == window) [window bringSubviewToFront:continueButton];
    });
}

static void amproj_forceExitStartupPaywall(BOOL continueAction) {
    UIWindow *window = nil;
    UIViewController *paywall = amproj_visibleStartupPaywall(&window);
    NSString *source = continueAction ? @"manual_continue" : @"manual_close";
    amproj_startupPaywallEvent(@"fallback_tapped", @{
        @"source": source,
        @"manual": @YES,
        @"failure": @""
    });

    if (!paywall) {
        UIViewController *root = window.rootViewController;
        if (root.presentedViewController) {
            [root dismissViewControllerAnimated:NO completion:nil];
            amproj_verifyManualStartupExit(root.presentedViewController, source);
            return;
        }
        amproj_startupPaywallEvent(@"manual_exit_pending", @{
            @"source": source,
            @"failure": @"paywall_not_found"
        });
        return;
    }

    UIViewController *dismissOwner = paywall;
    while (dismissOwner.parentViewController &&
           !dismissOwner.presentingViewController) {
        dismissOwner = dismissOwner.parentViewController;
    }
    UIViewController *presenter = dismissOwner.presentingViewController ?:
        paywall.presentingViewController;
    if (presenter) {
        [presenter dismissViewControllerAnimated:NO completion:nil];
        amproj_verifyManualStartupExit(paywall, source);
        return;
    }

    id closeView = amproj_findPaywallCloseView(
        paywall.viewIfLoaded, [NSMutableSet set], 0);
    if (!closeView) {
        closeView = amproj_findTopLeftPaywallControl(
            paywall.viewIfLoaded, [NSMutableSet set], 0);
    }
    BOOL activated = NO;
    if ([closeView isKindOfClass:UIControl.class]) {
        UIControl *control = closeView;
        control.enabled = YES;
        control.userInteractionEnabled = YES;
        control.alpha = 1.0;
        control.hidden = NO;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        activated = YES;
    } else if ([closeView respondsToSelector:@selector(accessibilityActivate)]) {
        activated = ((BOOL (*)(id, SEL))objc_msgSend)(
            closeView, @selector(accessibilityActivate));
    }
    amproj_startupPaywallEvent(@"manual_native_action", @{
        @"source": source,
        @"activated": @(activated),
        @"action_class": closeView ? NSStringFromClass([closeView class]) : @"",
        @"failure": activated ? @"" : @"native_close_not_found"
    });
    amproj_verifyManualStartupExit(paywall, source);
}

@interface AMProjStartupHomeButton : UIButton
@end

@implementation AMProjStartupHomeButton
- (void)amproj_enterHomeTapped:(__unused id)sender {
    amproj_forceExitStartupPaywall(self.tag != 29);
}
@end

static void amproj_showStartupPaywallFallbackButton(NSString *failure) {
    UIWindow *paywallWindow = nil;
    UIViewController *visiblePaywall =
        amproj_visibleStartupPaywall(&paywallWindow);
    if (amproj_startupPaywallState == AMProjStartupPaywallStateMainVisible &&
        !visiblePaywall) return;
    BOOL mainVisible = NO;
    BOOL paywallVisible = NO;
    UIWindow *mainWindow = nil;
    amproj_startupPaywallSnapshot(&mainVisible, &paywallVisible, &mainWindow, nil);
    if (paywallWindow) mainWindow = paywallWindow;
    if (!mainWindow) mainWindow = amproj_foregroundApplicationWindow();
    if (!mainWindow) return;

    UIButton *existing = amproj_startupPaywallFallbackButton;
    UIButton *existingClose = amproj_startupPaywallCloseButton;
    if (existing.superview == mainWindow && existingClose.superview == mainWindow) {
        [mainWindow bringSubviewToFront:existingClose];
        [mainWindow bringSubviewToFront:existing];
        return;
    }
    [existing removeFromSuperview];
    [existingClose removeFromSuperview];

    AMProjStartupHomeButton *button = [AMProjStartupHomeButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = 30;
    [button setTitle:@"继续进入" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithRed:0.0 green:0.55 blue:0.42 alpha:0.96];
    button.layer.cornerRadius = 12.0;
    button.accessibilityLabel = @"继续进入 Alight Motion";
    [button addTarget:button action:@selector(amproj_enterHomeTapped:)
      forControlEvents:UIControlEventTouchUpInside];

    AMProjStartupHomeButton *closeButton =
        [AMProjStartupHomeButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    closeButton.tag = 29;
    [closeButton setTitle:@"×" forState:UIControlStateNormal];
    [closeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    closeButton.titleLabel.font = [UIFont systemFontOfSize:30.0 weight:UIFontWeightRegular];
    closeButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
    closeButton.layer.cornerRadius = 22.0;
    closeButton.accessibilityLabel = @"关闭启动套餐页";
    [closeButton addTarget:closeButton action:@selector(amproj_enterHomeTapped:)
          forControlEvents:UIControlEventTouchUpInside];

    [mainWindow addSubview:button];
    [mainWindow addSubview:closeButton];
    [NSLayoutConstraint activateConstraints:@[
        [button.bottomAnchor constraintEqualToAnchor:mainWindow.safeAreaLayoutGuide.bottomAnchor
                                            constant:-20.0],
        [button.leadingAnchor constraintEqualToAnchor:mainWindow.leadingAnchor constant:24.0],
        [button.trailingAnchor constraintEqualToAnchor:mainWindow.trailingAnchor constant:-24.0],
        [button.heightAnchor constraintEqualToConstant:54.0],
        [closeButton.leadingAnchor constraintEqualToAnchor:mainWindow.leadingAnchor constant:20.0],
        [closeButton.topAnchor constraintEqualToAnchor:mainWindow.safeAreaLayoutGuide.topAnchor
                                              constant:12.0],
        [closeButton.widthAnchor constraintEqualToConstant:44.0],
        [closeButton.heightAnchor constraintEqualToConstant:44.0]
    ]];
    [mainWindow bringSubviewToFront:closeButton];
    [mainWindow bringSubviewToFront:button];
    amproj_startupPaywallFallbackButton = button;
    amproj_startupPaywallCloseButton = closeButton;
    amproj_startupPaywallState = AMProjStartupPaywallStateFallbackVisible;
    amproj_startupPaywallEvent(@"dismiss_verified", @{
        @"success": @NO,
        @"source": @"fallback",
        @"failure": failure.length ? failure : @"dismiss_timeout",
        @"fallback_button": @YES,
        @"close_button": @YES,
        @"paywall_visible": @(paywallVisible),
        @"main_visible": @(mainVisible)
    });
}

static NSUInteger amproj_revealStartupPaywallControls(UIView *view,
                                                       NSUInteger depth) {
    if (!view || depth > 32) return 0;
    NSUInteger changes = 0;
    if ([view isKindOfClass:UIActivityIndicatorView.class]) {
        view.alpha = 0.0;
        view.hidden = YES;
        view.userInteractionEnabled = NO;
        changes++;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (button.currentTitle.length || button.accessibilityLabel.length) {
            button.alpha = 1.0;
            button.hidden = NO;
            button.enabled = YES;
            button.userInteractionEnabled = YES;
            [button.superview bringSubviewToFront:button];
            changes++;
        }
    }
    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *child in children) {
        changes += amproj_revealStartupPaywallControls(child, depth + 1);
    }
    return changes;
}

static void amproj_runStartupPaywallRescue(NSUInteger generation,
                                            NSUInteger attempt) {
    if (generation != amproj_startupPaywallRescueGeneration) return;
    UIWindow *window = nil;
    UIViewController *paywall = amproj_visibleStartupPaywall(&window);
    if (paywall && paywall.viewIfLoaded.window) {
        NSUInteger changes = amproj_revealStartupPaywallControls(
            paywall.viewIfLoaded, 0);
        amproj_showStartupPaywallFallbackButton(@"startup_page_stalled");
        if (attempt == 0 || attempt % 10 == 0) {
            amproj_startupPaywallEvent(@"manual_controls_visible", @{
                @"attempt": @(attempt),
                @"controller": NSStringFromClass(paywall.class) ?: @"",
                @"native_controls_revealed": @(changes),
                @"window": NSStringFromClass(window.class) ?: @"",
                @"failure": @""
            });
        }
    } else if (amproj_startupPaywallFallbackButton.superview ||
               amproj_startupPaywallCloseButton.superview) {
        amproj_removeStartupPaywallFallbackButton();
    }

    if (attempt >= 240) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_runStartupPaywallRescue(generation, attempt + 1);
    });
}

static void amproj_startStartupPaywallRescue(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_startStartupPaywallRescue();
        });
        return;
    }
    NSUInteger generation = ++amproj_startupPaywallRescueGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_runStartupPaywallRescue(generation, 0);
    });
}

static void amproj_markStartupMainVisible(NSString *source,
                                          NSUInteger verifiedAfterMS) {
    if (amproj_startupPaywallState == AMProjStartupPaywallStateMainVisible) return;
    amproj_startupPaywallState = AMProjStartupPaywallStateMainVisible;
    amproj_startupPaywallDismissInFlight = NO;
    amproj_startupPaywallTailSuppressionUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    amproj_removeStartupPaywallFallbackButton();
    amproj_startupPaywallEvent(@"main_visible", @{
        @"source": source ?: @"unknown",
        @"verified_after_ms": @(verifiedAfterMS),
        @"failure": @""
    });
}

static void amproj_verifyStartupPaywallDismiss(NSUInteger generation,
                                                NSUInteger dismissSequence,
                                                NSString *source) {
    if (generation != amproj_startupPaywallGeneration ||
        dismissSequence != amproj_startupPaywallDismissSequence ||
        amproj_startupPaywallState == AMProjStartupPaywallStateMainVisible) return;
    amproj_startupPaywallDismissInFlight = NO;
    amproj_startupPaywallState = AMProjStartupPaywallStateVerifying;
    BOOL mainVisible = NO;
    BOOL paywallVisible = NO;
    amproj_startupPaywallSnapshot(&mainVisible, &paywallVisible, nil, nil);
    BOOL success = mainVisible && !paywallVisible;
    if (success) {
        amproj_startupPaywallEvent(@"dismiss_verified", @{
            @"success": @YES,
            @"source": source ?: @"unknown",
            @"main_visible": @YES,
            @"paywall_visible": @NO,
            @"failure": @""
        });
        amproj_markStartupMainVisible(source, 500);
        return;
    }

    amproj_startupPaywallDismissFailures++;
    NSString *failure = paywallVisible ? @"paywall_still_visible" : @"main_not_visible";
    amproj_startupPaywallEvent(@"dismiss_verified", @{
        @"success": @NO,
        @"source": source ?: @"unknown",
        @"main_visible": @(mainVisible),
        @"paywall_visible": @(paywallVisible),
        @"failure": failure
    });
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - amproj_startupPaywallStartedAt;
    if (amproj_startupPaywallDismissFailures >= 3 || elapsed >= 3.0) {
        amproj_showStartupPaywallFallbackButton(failure);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_reconcileStartupPaywall(generation, @"verification_retry");
    });
}

static void amproj_requestStartupPaywallDismiss(NSUInteger generation,
                                                 NSString *source) {
    if (generation != amproj_startupPaywallGeneration ||
        amproj_startupPaywallState == AMProjStartupPaywallStateMainVisible ||
        amproj_startupPaywallDismissInFlight) return;
    UIViewController *outer = amproj_startupPaywallOuter;
    UIViewController *presenter = outer.presentingViewController;
    if (!outer || !presenter || !outer.viewIfLoaded.window ||
        outer.isBeingPresented || outer.isBeingDismissed ||
        presenter.isBeingDismissed || outer.transitionCoordinator) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_reconcileStartupPaywall(generation, @"presentation_settle");
        });
        return;
    }

    amproj_startupPaywallDismissInFlight = YES;
    amproj_startupPaywallState = AMProjStartupPaywallStateDismissRequested;
    NSUInteger dismissSequence = ++amproj_startupPaywallDismissSequence;
    amproj_startupPaywallEvent(@"dismiss_requested", @{
        @"source": source ?: @"unknown",
        @"attempt": @(dismissSequence),
        @"presenter": NSStringFromClass(presenter.class) ?: @"",
        @"controller": NSStringFromClass(outer.class) ?: @"",
        @"failure": @""
    });
    [presenter dismissViewControllerAnimated:NO completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_verifyStartupPaywallDismiss(generation, dismissSequence,
                                           source ?: @"unknown");
    });
}

static void amproj_markStartupPaywallOuterPresented(UIViewController *outer,
                                                     NSString *source) {
    if (!outer || outer != amproj_startupPaywallOuter ||
        !outer.presentingViewController || !outer.viewIfLoaded.window) return;
    if (!amproj_startupPaywallOuterPresentedRecorded) {
        amproj_startupPaywallOuterPresentedRecorded = YES;
        if (!amproj_startupPaywallFallbackButton.superview) {
            amproj_startupPaywallState = AMProjStartupPaywallStateOuterPresented;
        }
        amproj_startupPaywallEvent(@"outer_presented", @{
            @"source": source ?: @"unknown",
            @"presenter": NSStringFromClass(outer.presentingViewController.class) ?: @"",
            @"controller": NSStringFromClass(outer.class) ?: @"",
            @"failure": @""
        });
    }
}

static void amproj_reconcileStartupPaywall(NSUInteger generation,
                                            NSString *source) {
    if (generation != amproj_startupPaywallGeneration ||
        amproj_startupPaywallState == AMProjStartupPaywallStateIdle ||
        amproj_startupPaywallState == AMProjStartupPaywallStateArmed ||
        amproj_startupPaywallState == AMProjStartupPaywallStateMainVisible) return;
    if (amproj_startupPaywallState == AMProjStartupPaywallStateFallbackVisible) {
        BOOL mainVisible = NO;
        BOOL paywallVisible = NO;
        amproj_startupPaywallSnapshot(&mainVisible, &paywallVisible, nil, nil);
        if (mainVisible && !paywallVisible) {
            amproj_markStartupMainVisible(source, 0);
        }
        return;
    }
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - amproj_startupPaywallStartedAt;
    if (elapsed >= 3.0) {
        BOOL mainVisible = NO;
        BOOL paywallVisible = NO;
        amproj_startupPaywallSnapshot(&mainVisible, &paywallVisible, nil, nil);
        if (mainVisible && !paywallVisible) {
            amproj_startupPaywallEvent(@"dismiss_verified", @{
                @"success": @YES,
                @"source": source ?: @"unknown",
                @"main_visible": @YES,
                @"paywall_visible": @NO,
                @"failure": @""
            });
            amproj_markStartupMainVisible(
                source, (NSUInteger)MAX(0.0, elapsed * 1000.0));
            return;
        }
        amproj_showStartupPaywallFallbackButton(
            paywallVisible ? @"three_second_timeout" : @"presentation_not_established");
        return;
    }

    UIViewController *outer = amproj_startupPaywallOuter;
    if (outer.presentingViewController && outer.viewIfLoaded.window) {
        amproj_markStartupPaywallOuterPresented(outer, source);
        amproj_requestStartupPaywallDismiss(generation, source);
        return;
    }
    if (elapsed >= 3.0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        amproj_reconcileStartupPaywall(generation, @"outer_wait");
    });
}

static AMProjStartupPresentationDecision
amproj_startupPaywallPresentationDecision(UIViewController *presenter,
                                           UIViewController *controller,
                                           NSString **reasonOut) {
    if (![NSThread isMainThread] || !presenter || !controller) {
        return AMProjStartupPresentationDecisionPass;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL withinInitialWindow = amproj_startupPaywallSuppressionUntil > 0 &&
        now < amproj_startupPaywallSuppressionUntil;
    BOOL transactionActive = amproj_startupPaywallStartedAt > 0 &&
        amproj_startupPaywallState != AMProjStartupPaywallStateMainVisible;
    BOOL tailRetry = amproj_startupPaywallState ==
        AMProjStartupPaywallStateMainVisible &&
        now < amproj_startupPaywallTailSuppressionUntil &&
        presenter == amproj_startupPaywallPresenter;
    BOOL tailChild = amproj_startupPaywallState ==
        AMProjStartupPaywallStateMainVisible &&
        now < amproj_startupPaywallTailSuppressionUntil &&
        (presenter == amproj_startupPaywallOuter ||
         presenter == amproj_startupPaywallSuppressedRetryOuter);
    if (!withinInitialWindow && !transactionActive && !tailRetry && !tailChild) {
        return AMProjStartupPresentationDecisionPass;
    }

    NSString *controllerName = NSStringFromClass(controller.class) ?: @"";
    NSString *presenterName = NSStringFromClass(presenter.class) ?: @"";
    if (amproj_isStartupPaywallOuterClassName(controllerName) &&
        amproj_isStartupPresenterClassName(presenterName)) {
        if (amproj_startupPaywallState == AMProjStartupPaywallStateArmed) {
            amproj_startupPaywallState = AMProjStartupPaywallStatePresentationSeen;
            amproj_startupPaywallStartedAt = now;
            amproj_startupPaywallDismissFailures = 0;
            amproj_startupPaywallDismissInFlight = NO;
            amproj_startupPaywallOuterPresentedRecorded = NO;
            amproj_startupPaywallDismissSequence = 0;
            NSUInteger generation = ++amproj_startupPaywallGeneration;
            amproj_startupPaywallOuter = controller;
            amproj_startupPaywallPresenter = presenter;
            amproj_startupPaywallSuppressedRetryOuter = nil;
            amproj_startupPaywallTailSuppressionUntil = 0;
            if (reasonOut) *reasonOut = @"startup_loading_root";
            amproj_startupPaywallEvent(@"presentation_seen", @{
                @"reason": @"startup_loading_root",
                @"presenter": presenterName,
                @"controller": controllerName,
                @"suppressed": @NO,
                @"failure": @""
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                amproj_reconcileStartupPaywall(generation, @"three_second_watchdog");
            });
            return AMProjStartupPresentationDecisionTrackOuter;
        }
        if (transactionActive || tailRetry) {
            amproj_startupPaywallSuppressedRetryOuter = controller;
            if (reasonOut) *reasonOut = @"startup_loading_retry";
            amproj_startupPaywallEvent(@"presentation_seen", @{
                @"reason": @"startup_loading_retry",
                @"presenter": presenterName,
                @"controller": controllerName,
                @"suppressed": @YES,
                @"failure": @"retry_suppressed"
            });
            return AMProjStartupPresentationDecisionSuppress;
        }
    }

    if ([controllerName containsString:@"CloudCardsTiersPaywallView"] &&
        (presenter == amproj_startupPaywallOuter ||
         presenter == amproj_startupPaywallSuppressedRetryOuter) &&
        (transactionActive || tailChild)) {
        if (reasonOut) *reasonOut = @"startup_loading_child";
        amproj_startupPaywallEvent(@"presentation_seen", @{
            @"reason": @"startup_loading_child",
            @"presenter": presenterName,
            @"controller": controllerName,
            @"suppressed": @YES,
            @"failure": @"child_suppressed"
        });
        return AMProjStartupPresentationDecisionSuppress;
    }
    return AMProjStartupPresentationDecisionPass;
}

static NSString* amproj_projectTitleRecursive(UIViewController *controller, NSUInteger depth,
                                               NSMutableSet<NSValue *> *visited) {
    if (!controller || depth > 8) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];
    NSString *className = NSStringFromClass(controller.class);
    if ([className containsString:@"ProjectEdit"] || [className containsString:@"EditNavRoot"]) {
        NSString *title = controller.title ?: controller.navigationItem.title;
        if (title.length) return title;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        NSString *title = amproj_projectTitleRecursive(
            ((UINavigationController *)controller).visibleViewController, depth + 1, visited);
        if (title.length) return title;
    }
    for (UIViewController *child in controller.childViewControllers) {
        NSString *title = amproj_projectTitleRecursive(child, depth + 1, visited);
        if (title.length) return title;
    }
    return amproj_projectTitleRecursive(controller.presentedViewController, depth + 1, visited);
}

static NSString* amproj_currentProjectTitle(UIViewController *shareController) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIViewController *presenter = shareController.presentingViewController;
    while (presenter) {
        NSString *title = amproj_projectTitleRecursive(presenter, 0, visited);
        if (title.length) return title;
        presenter = presenter.presentingViewController;
    }
    return amproj_projectTitleRecursive(amproj_keyWindow().rootViewController, 0, visited);
}

static BOOL amproj_isExactShareVCClass(Class cls) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSString *name = NSStringFromClass(current);
        if ([name isEqualToString:@"AlightMotion.ShareVC"] ||
            [name isEqualToString:@"_TtC12AlightMotion7ShareVC"]) {
            return YES;
        }
    }
    return NO;
}

#if AMPROJ_CLOUD_SYNC
static void amproj_customizeCloudUploadLabelsInView(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *text = [label.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([text isEqualToString:@"上传到云端"] ||
            [text isEqualToString:@"Upload to Cloud"]) {
            label.text = @"上传到云项目";
        } else if ([text isEqualToString:@"确保您的项目安全！"] ||
                   [text isEqualToString:@"Keep your projects safe!"]) {
            label.text = @"选择性保存为云工程";
        }
    }
    for (UIView *subview in view.subviews) {
        amproj_customizeCloudUploadLabelsInView(subview);
    }
}

static void amproj_scheduleCloudUploadLabelCustomization(UIViewController *controller) {
    if (!controller || !amproj_isExactShareVCClass(controller.class)) return;
    __weak UIViewController *weakController = controller;
    for (NSNumber *delay in @[@0, @0.15, @0.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            if (strongController) {
                amproj_customizeCloudUploadLabelsInView(strongController.view);
            }
        });
    }
}
#endif

static BOOL amproj_readShareExportOption(id object, uint8_t *value) {
    if (!object || !amproj_isExactShareVCClass([object class])) return NO;
    NSString *bundleVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"];
    if (![bundleVersion isKindOfClass:NSString.class] ||
        ![bundleVersion isEqualToString:@"862"]) return NO;

    Ivar ivar = class_getInstanceVariable([object class], "selectedExportOptID");
    ptrdiff_t offset = ivar ? ivar_getOffset(ivar)
                            : AMProjShareVCSelectedExportOptionOffset;
    size_t instanceSize = class_getInstanceSize([object class]);
    if (offset < 0 || (size_t)offset + sizeof(uint8_t) > instanceSize) return NO;

    uint8_t raw = 0;
    const uint8_t *address =
        (const uint8_t *)(__bridge const void *)object + offset;
    memcpy(&raw, address, sizeof(raw));
    if (value) *value = raw;
    return YES;
}

static UIViewController* amproj_shareVCRecursive(
    UIViewController *controller, NSUInteger depth,
    NSMutableSet<NSValue *> *visited, uint8_t *selectedExportOption) {
    if (!controller || depth > 10) return nil;
    NSValue *identity =
        [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    if (amproj_readShareExportOption(controller, selectedExportOption)) {
        return controller;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation =
            (UINavigationController *)controller;
        UIViewController *found = amproj_shareVCRecursive(
            navigation.visibleViewController,
            depth + 1, visited, selectedExportOption);
        if (found) return found;
        for (UIViewController *stackController in
             navigation.viewControllers.reverseObjectEnumerator) {
            found = amproj_shareVCRecursive(
                stackController, depth + 1, visited, selectedExportOption);
            if (found) return found;
        }
    }
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = amproj_shareVCRecursive(
            child, depth + 1, visited, selectedExportOption);
        if (found) return found;
    }
    return amproj_shareVCRecursive(
        controller.presentedViewController, depth + 1, visited,
        selectedExportOption);
}

static BOOL amproj_isShareExportHostController(UIViewController *controller) {
    if (!controller) return NO;
    UIViewController *candidate = controller;
    if ([candidate isKindOfClass:UINavigationController.class]) {
        candidate = ((UINavigationController *)candidate).visibleViewController;
    }
    NSString *name = NSStringFromClass(candidate.class);
    return [name isEqualToString:@"AlightMotion.ShareNC"] ||
        [name isEqualToString:@"_TtC12AlightMotion7ShareNC"] ||
        [name isEqualToString:@"AlightMotion.ShareVC"] ||
        [name isEqualToString:@"_TtC12AlightMotion7ShareVC"];
}

static void hooked_shareNCOnTapExport(id self, SEL _cmd, id sender) {
    if (![NSThread isMainThread]) {
        if (orig_shareNCOnTapExport) orig_shareNCOnTapExport(self, _cmd, sender);
        return;
    }

#if AMPROJ_CLOUD_SYNC
    if (amproj_directAuthorizationPending) {
        ++amproj_directAuthorizationGeneration;
        amproj_directAuthorizationPending = NO;
        amproj_logCriticalEvent(@"direct.authorization_invalidated", @{
            @"reason": @"new_export_tap"
        });
    }
#endif

    UIViewController *shareController =
        [self isKindOfClass:UIViewController.class] ? self : nil;
    uint8_t selectedExportOption = UINT8_MAX;
    UIViewController *shareVC = nil;
    @try {
        shareVC = amproj_shareVCRecursive(
            shareController, 0, [NSMutableSet set], &selectedExportOption);
    } @catch (NSException *exception) {
        amproj_logCriticalEvent(@"direct.export_option_exception", @{
            @"name": exception.name ?: @"NSException",
            @"reason": exception.reason ?: @""
        });
    }

    BOOL isProjectPackage = shareVC &&
        AMProjV44IsDirectProjectPackageOption(selectedExportOption);
#if AMPROJ_CLOUD_SYNC
    BOOL isCloudUpload = shareVC &&
        selectedExportOption == AMProjShareCloudUploadOption;
#else
    BOOL isCloudUpload = NO;
#endif
    NSString *mode = amproj_exportMode();
    amproj_logCriticalEvent(@"direct.export_button", @{
        @"mode": mode ?: @"",
        @"selected_export_option": shareVC ? @(selectedExportOption) : @(-1),
        @"package": @(isProjectPackage),
        @"cloud_upload": @(isCloudUpload),
        @"controller": shareVC ? NSStringFromClass(shareVC.class) : @""
    });

    if ((!isProjectPackage && !isCloudUpload) ||
        [mode isEqualToString:@"observe"] ||
        !shareController || !orig_presentVC) {
        if (orig_shareNCOnTapExport) orig_shareNCOnTapExport(self, _cmd, sender);
        return;
    }

    NSString *title = amproj_currentProjectTitle(shareController);
    dispatch_async(dispatch_get_main_queue(), ^{
#if AMPROJ_CLOUD_SYNC
        if (isCloudUpload) {
            amproj_startCloudUpload(shareController, title);
            return;
        }
#endif
        amproj_startDirectExport(shareController, nil, YES, nil, title);
    });
}

static void hooked_navigationPush(id self, SEL _cmd,
                                  UIViewController *viewController,
                                  BOOL animated) {
#if AMPROJ_CLOUD_SYNC
    UIViewController *accountReplacement = nil;
    if ([self isKindOfClass:UINavigationController.class]) {
        accountReplacement = AMCloudSyncReplacementForNativeAccountPush(
            (UINavigationController *)self, viewController);
    }
    if (accountReplacement && orig_navigationPush) {
        amproj_logCriticalEvent(@"cloud.account.native_push_forward", @{
            @"replacement": NSStringFromClass(accountReplacement.class) ?: @""
        });
        orig_navigationPush(self, _cmd, accountReplacement, animated);
        return;
    }
#endif
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        // Build 865 does not expose the legacy ShareNC callback, but the
        // concrete project-package controller is a stable semantic boundary
        // used by the presentation hook as well. Handle only that exact
        // controller here so the package export button is not lost when AM
        // pushes it through a navigation controller. Every other navigation
        // remains native, including the 865 import/document flow.
        if (amproj_runtimeIsBuild865() &&
            AMProjV865ProjectFlowIsProjectPackageController(viewController) &&
            ![amproj_exportMode() isEqualToString:@"observe"] &&
            [self isKindOfClass:UIViewController.class] && orig_presentVC) {
            UIViewController *presenter = (UIViewController *)self;
            NSString *title = amproj_currentProjectTitle(presenter);
            amproj_logCriticalEvent(@"865.project_export_navigation_entry", @{
                @"controller": NSStringFromClass(viewController.class) ?: @"",
                @"destination": @"share_sheet",
                @"native_private_abi": @NO
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                amproj_startDirectExport(
                    presenter, viewController, animated, nil, title);
            });
            return;
        }
        amproj_log865LegacyPathDisabled(@"navigation_export");
        if (orig_navigationPush) {
            orig_navigationPush(self, _cmd, viewController, animated);
        }
        return;
    }
    // The concrete 6.2.55 project-package controller is the only export
    // boundary. Avoid private ShareVC ivars and leave every other navigation,
    // including project/template deletion, on AM's native path.
    if (amproj_isSharePackageController(viewController) &&
        [self isKindOfClass:UIViewController.class] && orig_presentVC) {
        NSString *mode = amproj_exportMode();
        if ([mode isEqualToString:@"observe"]) {
            if (orig_navigationPush) {
                orig_navigationPush(self, _cmd, viewController, animated);
            }
            return;
        }
        UIViewController *presenter = (UIViewController *)self;
        amproj_logCriticalEvent(@"direct.native_package_navigation", @{
            @"mode": mode ?: @"",
            @"controller": NSStringFromClass(viewController.class) ?: @"",
            @"action": @"direct_export_fallback"
        });
        NSString *title = amproj_currentProjectTitle(presenter);
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_startDirectExport(presenter, viewController, animated, nil, title);
        });
        return;
    }

    if (orig_navigationPush) {
        orig_navigationPush(self, _cmd, viewController, animated);
    }
    if (amproj_isShareExportHostController(viewController)) {
        amproj_installShareExportHook();
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_installShareExportHook();
#if AMPROJ_CLOUD_SYNC
            uint8_t selectedExportOption = UINT8_MAX;
            UIViewController *shareVC = amproj_shareVCRecursive(
                viewController, 0, [NSMutableSet set], &selectedExportOption);
            amproj_scheduleCloudUploadLabelCustomization(shareVC);
#endif
        });
    }
}

// MARK: - Cloud-controlled member state

// The repack's own user system (am.meowcr.cn) controls the entitlement
// flags: it serves member_flags.json under the API base and whoever edits
// that file in the user system controls every device. The plugin fetches it
// at launch and on activations; when it is unreachable the verified
// embedded defaults apply once so fresh installs still land as members.
// Values already present on the device are only overwritten when the cloud
// responds, so cloud state always wins and local user data is never lost.
static NSString *const AMProjMemberFlagsURL =
    @"https://am.meowcr.cn/api/member_flags.json";

static void amproj_applyMemberFlags(NSDictionary *flags) {
    if (!flags.count || !NSThread.isMainThread) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in flags) {
        id value = flags[key];
        if ([value isKindOfClass:NSNumber.class] ||
            [value isKindOfClass:NSString.class] ||
            [value isKindOfClass:NSArray.class] ||
            [value isKindOfClass:NSDictionary.class]) {
            [defaults setObject:value forKey:key];
        }
    }
    [defaults synchronize];
}

static void amproj_writeEmbeddedMemberStateIfAbsent(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"is_member"] != nil) return;
    NSDictionary *state = @{
        @"is_member": @YES,
        @"is_premium_member": @YES,
        @"is_max_member": @YES,
        @"is_pro_member": @YES,
        @"is_subscribed": @YES,
        @"has_subscription": @YES,
        @"has_watermark": @NO,
        @"should_add_watermark": @NO,
        @"should_show_watermark": @NO,
        @"watermark_enabled": @NO,
        @"is_authenticated": @YES,
        @"is_logged_in": @YES,
        @"has_logged_in": @YES,
        @"account_created": @YES,
        @"is_first_launch": @NO,
        @"is_first_session": @NO,
        @"GID_AppHasRunBefore": @YES,
        @"GID_MigrationCheckPerformed": @YES,
        @"templates_tab_seen": @YES,
        @"cloud_projects_subtab_seen": @YES,
        @"template_editor_seen": @YES,
        @"forcedSubscriptionTierKey": @"Cloud Subscriber",
        @"forced_subscription_tier_key": @"Cloud Subscriber",
        @"active_subscriptions_override":
            @[@"alightcreative.motion.1y_1y_t10"],
        @"active_benefits": @[@"RemoveWatermark", @"MemberEffects",
            @"ProjectPack", @"advancedEasing", @"layerParenting",
            @"cameraObject"],
        @"PaywallInteractionStorage.appCloseBeforeFirstPaywallCount": @294,
        @"user_mode": @2,
        @"project_package_freeuser_maxdownloadsize": @5242880,
    };
    for (NSString *key in state) {
        if ([defaults objectForKey:key] == nil) {
            [defaults setObject:state[key] forKey:key];
        }
    }
    [defaults synchronize];
    amproj_logCriticalEvent(@"member.embedded_state_applied", @{});
}

static void amproj_fetchMemberFlags(void) {
    NSURL *URL = [NSURL URLWithString:AMProjMemberFlagsURL];
    if (!URL) return;
    [[[NSURLSession sessionWithConfiguration:
        NSURLSessionConfiguration.ephemeralSessionConfiguration]
        dataTaskWithURL:URL
      completionHandler:^(NSData *data, NSURLResponse *response,
                          NSError *error) {
        if (!data.length || error) return;
        id payload = nil;
        @try {
            payload = [NSJSONSerialization JSONObjectWithData:data
                                                      options:0 error:nil];
        } @catch (__unused NSException *exception) {
            return;
        }
        if (![payload isKindOfClass:NSDictionary.class]) return;
        NSDictionary *payloadDict = payload;
        BOOL enabled = [payloadDict[@"enabled"] boolValue];
        NSDictionary *flags = payloadDict[@"flags"];
        if (![flags isKindOfClass:NSDictionary.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (enabled) amproj_applyMemberFlags(flags);
        });
    }] resume];
}

static CFAbsoluteTime amproj_lastMemberFlagSync = 0;

static void amproj_syncMemberFlags(NSString *source) {
    if (!NSThread.isMainThread) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - amproj_lastMemberFlagSync < 300.0) return;
    amproj_lastMemberFlagSync = now;
    amproj_logCriticalEvent(@"member.flags_sync", @{
        @"source": source ?: @"unknown"
    });
    amproj_fetchMemberFlags();
}

static void amproj_forwardPresentation(id self, SEL _cmd,
                                       UIViewController *controller,
                                       BOOL animated,
                                       void (^completion)(void)) {
    if (orig_presentVC) orig_presentVC(self, _cmd, controller, animated, completion);
}

// MARK: - Intro flow auto-close

// The intro flow (IntroFlowNavigation) hosts the subscription step and is
// presented by the crack module's own startup funnel; blocking its
// presentation deadlocked the launch (r11) and the crack's auto-skip does
// not always run. After it presents, its top-left close control is
// activated through accessibility - the same tap a user would make - and a
// final dismiss is the fallback, so the launch always proceeds to main.
static BOOL amproj_introCloseCandidateMatches(id element, UIView *hostView) {
    CGRect frame = CGRectNull;
    if ([element respondsToSelector:@selector(accessibilityFrame)]) {
        frame = [(id)element accessibilityFrame];
    } else if ([element isKindOfClass:UIView.class]) {
        frame = [(UIView *)element convertRect:((UIView *)element).bounds
                                        toView:nil];
    }
    if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) return NO;
    NSString *label = nil;
    if ([element respondsToSelector:@selector(accessibilityLabel)]) {
        id value = [(id)element accessibilityLabel];
        if ([value isKindOfClass:NSString.class]) label = value;
    }
    CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width ?: 1.0;
    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height ?: 1.0;
    if (label.length) {
        NSString *normalized = label.lowercaseString;
        if ([normalized containsString:@"关闭"] ||
            [normalized containsString:@"close"] ||
            [normalized containsString:@"skip"] ||
            [normalized containsString:@"跳过"]) {
            return YES;
        }
    }
    // The round close button sits in the top-left corner of every intro
    // page and is small by design.
    return (frame.origin.x < 0.15 * screenWidth &&
            frame.origin.y < 0.15 * screenHeight &&
            frame.size.width < 0.2 * screenWidth &&
            frame.size.height < 0.2 * screenHeight);
}

static void amproj_introCollectCloseCandidates(
    UIView *view, NSUInteger depth, NSMutableArray *out) {
    if (!view || depth > 24) return;
    for (id element in view.accessibilityElements ?: @[]) {
        if (amproj_introCloseCandidateMatches(element, view)) [out addObject:element];
    }
    if (amproj_introCloseCandidateMatches(view, nil)) [out addObject:view];
    for (UIView *subview in view.subviews) {
        amproj_introCollectCloseCandidates(subview, depth + 1, out);
    }
}

static BOOL amproj_activateIntroCloseControl(UIViewController *intro) {
    if (!intro.viewIfLoaded || !NSThread.isMainThread) return NO;
    NSMutableArray *candidates = [NSMutableArray array];
    amproj_introCollectCloseCandidates(intro.viewIfLoaded, 0, candidates);
    for (id candidate in candidates) {
        if ([(id)candidate accessibilityActivate]) return YES;
    }
    return NO;
}

static const void *amproj_introCloseRoundsKey = &amproj_introCloseRoundsKey;

// MARK: - Startup funnel sweep

// On slow-license nights the crack module holds didFinishLaunching open
// while its funnel (intro wall, gate spinner) renders as plain SwiftUI
// content inside the hosting hierarchy - no presentViewController, no
// window takeover, and the sweep ladder keyed off the deferred launch
// callback never runs. This sweep is scheduled from the constructor with
// absolute delays instead, so it fires regardless of that callback. It
// only closes funnel surfaces: the intro flow's own close control, and a
// bottom-area continue button activated through accessibility.
static NSUInteger amproj_funnelContinueActivations = 0;

static BOOL amproj_funnelActivateContinueInView(
    UIView *view, NSUInteger depth, CGFloat screenHeight, CGFloat screenWidth,
    NSString *source);

static void amproj_funnelSweep(NSString *source) {
    if (!amproj_gateDefenseActive || !amproj_funnelSweepEnabled) return;
    if (!NSThread.isMainThread) return;
    NSString *sourceSnapshot = [source copy] ?: @"funnel_sweep";

    // 1) Close any presented or embedded intro flow.
    NSMutableArray<UIViewController *> *funnelHosts = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *cursor = window.rootViewController;
            for (NSUInteger depth = 0; cursor && depth < 8; depth++) {
                NSString *name = NSStringFromClass(cursor.class) ?: @"";
                if ([name containsString:@"IntroFlowNavigation"] &&
                    ![funnelHosts containsObject:cursor]) {
                    [funnelHosts addObject:cursor];
                }
                UIViewController *next = cursor.presentedViewController;
                if (!next) {
                    for (UIViewController *child in
                             cursor.childViewControllers) {
                        if (!next) next = child;
                    }
                }
                cursor = next;
            }
        }
    }
    for (UIViewController *host in funnelHosts) {
        BOOL activated = amproj_activateIntroCloseControl(host);
        amproj_logCriticalEvent(@"startup.funnel_intro_close", @{
            @"source": sourceSnapshot,
            @"activated": @(activated)
        });
    }

    // 2) Fire a visible bottom-area continue button through accessibility.
    if (amproj_funnelContinueActivations >= 12) return;
    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height ?: 1.0;
    CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width ?: 1.0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden) continue;
            if (amproj_funnelActivateContinueInView(
                    window, 0, screenHeight, screenWidth, sourceSnapshot)) {
                return;
            }
        }
    }
}

// Activates a visible bottom-area control whose label is the continue
// entrance; the funnel pages render it as SwiftUI, so accessibility is the
// only reliable handle.
static BOOL amproj_funnelActivateContinueInView(
    UIView *view, NSUInteger depth, CGFloat screenHeight, CGFloat screenWidth,
    NSString *source) {
    if (!view || depth > 24) return NO;
    if (amproj_funnelContinueActivations >= 12) return NO;
    NSMutableArray *candidates = [NSMutableArray array];
    for (id element in view.accessibilityElements ?: @[]) {
        [candidates addObject:element];
    }
    [candidates addObject:view];
    NSString *continueTitle = @"\u7ee7\u7eed\u8fdb\u5165";
    for (id candidate in candidates) {
        NSString *label = nil;
        if ([candidate respondsToSelector:@selector(accessibilityLabel)]) {
            id value = [(id)candidate accessibilityLabel];
            if ([value isKindOfClass:NSString.class]) label = value;
        }
        if (![label containsString:continueTitle]) continue;
        CGRect frame = CGRectNull;
        if ([candidate respondsToSelector:@selector(accessibilityFrame)]) {
            frame = [(id)candidate accessibilityFrame];
        } else if ([candidate isKindOfClass:UIView.class]) {
            frame = [(UIView *)candidate convertRect:((UIView *)candidate).bounds
                                              toView:nil];
        }
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) continue;
        if (CGRectGetMidY(frame) / screenHeight < 0.65 ||
            CGRectGetWidth(frame) / screenWidth < 0.4) {
            continue;
        }
        if ([(id)candidate accessibilityActivate]) {
            amproj_funnelContinueActivations++;
            amproj_logCriticalEvent(@"startup.funnel_continue", @{
                @"source": source ?: @"funnel_sweep"
            });
            return YES;
        }
    }
    for (UIView *subview in view.subviews) {
        if (amproj_funnelActivateContinueInView(
                subview, depth + 1, screenHeight, screenWidth, source)) {
            return YES;
        }
    }
    return NO;
}

static BOOL amproj_isNativeImportFailureAlert(UIViewController *controller,
                                              NSString **titleOut,
                                              NSString **messageOut) {
    if (!amproj_nativeImportObservationActive ||
        ![controller isKindOfClass:UIAlertController.class]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    NSString *content = [[NSString stringWithFormat:@"%@\n%@", title, message] lowercaseString];
    BOOL matches = [content containsString:@"\u4e0a\u4f20\u5931\u8d25"] ||
        [content containsString:@"\u5bfc\u5165\u5931\u8d25"] ||
        [content containsString:@"\u65e0\u6cd5\u5bfc\u5165"] ||
        [content containsString:@"\u6587\u4ef6\u5df2\u635f\u574f"] ||
        [content containsString:@"\u683c\u5f0f\u4e0d\u6b63\u786e"] ||
        [content containsString:@"import failed"] ||
        [content containsString:@"upload failed"] ||
        [content containsString:@"unable to import"] ||
        [content containsString:@"incorrect format"] ||
        [content containsString:@"corrupt"] ||
        [content containsString:@"missing media"] ||
        [content containsString:@"media missing"] ||
        [content containsString:@"\u5a92\u4f53\u7f3a\u5931"] ||
        [content containsString:@"\u7f3a\u5c11\u5a92\u4f53"];
    if (matches) {
        if (titleOut) *titleOut = title;
        if (messageOut) *messageOut = message;
    }
    return matches;
}

// A standalone XML is intentionally allowed to contain references that only
// make sense in AM's built-in/template context.  This particular alert is not
// a native rejection: AM has already returned storage status 4 and explicitly
// says that it imported the package.  Do not extend this exception to .amproj
// archives, whose media manifest remains a strict integrity contract.
static BOOL amproj_isSuppressibleXMLMissingMediaAlert(
    UIViewController *controller, NSString **transactionIDOut,
    NSString **titleOut, NSString **messageOut) {
    if (!amproj_nativeImportObservationActive ||
        ![controller isKindOfClass:UIAlertController.class]) return NO;
    NSString *transactionID = [amproj_activeNativeImportTransactionID copy];
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(transactionID);
    if (!transaction || transaction.kind != AMProjImportKindXMLTemplate ||
        transaction.state != AMProjImportTransactionNativeActive ||
        !transaction.packageIntegrityVerified ||
        !transaction.nativeTerminalStatus4Observed) {
        return NO;
    }
    UIAlertController *alert = (UIAlertController *)controller;
    if (alert.actions.count != 1) return NO;
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    NSString *content = [[NSString stringWithFormat:@"%@\n%@", title, message]
        lowercaseString];
    BOOL missingMedia = [content containsString:@"missing media"] ||
        [content containsString:@"media missing"] ||
        [content containsString:@"媒体缺失"] ||
        [content containsString:@"缺少媒体"];
    BOOL importedAnyway = [content containsString:@"has been imported anyway"] ||
        [content containsString:@"仍已导入"] ||
        [content containsString:@"已经导入"];
    if (!missingMedia || !importedAnyway) return NO;
    if (transactionIDOut) *transactionIDOut = transactionID;
    if (titleOut) *titleOut = title;
    if (messageOut) *messageOut = message;
    return YES;
}

static void amproj_finishSuppressedXMLMissingMediaAlert(
    NSString *transactionID, NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        if (!transaction || transaction.kind != AMProjImportKindXMLTemplate ||
            transaction.state != AMProjImportTransactionNativeActive ||
            !transaction.xmlImportedAnywayWarningObserved ||
            ![amproj_activeNativeImportTransactionID
                isEqualToString:transactionID]) {
            return;
        }
        if (!transaction.nativeTerminalStatus4Returned) {
            if (attempt >= 40) {
                amproj_debugEvent(@"import.xml_missing_media_completion_deferred", @{
                    @"transaction_id": transactionID ?: @"",
                    @"attempt": @(attempt),
                    @"reason": @"storage_status_4_callback_not_returned"
                });
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         25 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_finishSuppressedXMLMissingMediaAlert(
                    transactionID, attempt + 1);
            });
            return;
        }
        BOOL bridgeHandled = AMProjNativePackageImportBridgeFinishSuccess();
        amproj_debugEvent(@"import.xml_missing_media_completion", @{
            @"transaction_id": transactionID ?: @"",
            @"bridge_completion_consumed": @(bridgeHandled),
            @"storage_status_4_returned": @YES,
            @"attempt": @(attempt)
        });
    });
}

typedef NS_ENUM(NSInteger, AMProjXMLImportAlertResult) {
    AMProjXMLImportAlertNone = 0,
    AMProjXMLImportAlertSuccess,
    AMProjXMLImportAlertFailure,
};

static AMProjXMLImportAlertResult amproj_XMLImportAlertResult(
    UIViewController *controller, UIViewController *presenter,
    NSString **titleOut, NSString **messageOut,
    NSUInteger *dispatchGenerationOut) {
    if (!amproj_xmlTemplateImportActive ||
        ![controller isKindOfClass:UIAlertController.class]) {
        return AMProjXMLImportAlertNone;
    }
    AMProjImportTransaction *transaction =
        amproj_importTransactionForID(amproj_xmlTemplateImportTransactionID);
    if (!transaction || transaction.kind != AMProjImportKindXMLTemplate ||
        !transaction.xmlTemplatePickerDelegateInvoked ||
        !transaction.xmlTemplateDispatchStarted ||
        transaction.xmlTemplateDispatchGeneration == 0 ||
        !transaction.xmlTemplateNativePicker ||
        !transaction.xmlTemplateNativePickerDelegate ||
        transaction.xmlTemplateDispatchStartedAt <= 0) {
        return AMProjXMLImportAlertNone;
    }
    if (!transaction.xmlTemplatePickerPresenter) {
        return AMProjXMLImportAlertNone;
    }
    UIWindow *ownerWindow = transaction.xmlTemplateOwner.viewIfLoaded.window;
    UIWindow *presenterWindow = presenter.viewIfLoaded.window;
    if (!ownerWindow || !presenterWindow || ownerWindow != presenterWindow) {
        return AMProjXMLImportAlertNone;
    }
    UIDocumentPickerViewController *expectedPicker =
        transaction.xmlTemplateNativePicker;
    UIViewController *expectedPresenter =
        transaction.xmlTemplatePickerPresenter;
    UIViewController *owner = transaction.xmlTemplateOwner;
    BOOL presenterMatches = presenter == expectedPicker ||
        presenter.presentingViewController == expectedPicker ||
        presenter == expectedPresenter || presenter == owner ||
        presenter.parentViewController == expectedPresenter ||
        expectedPresenter.parentViewController == presenter ||
        (owner.navigationController &&
         presenter.navigationController == owner.navigationController);
    if (!presenterMatches) return AMProjXMLImportAlertNone;
    UIAlertController *alert = (UIAlertController *)controller;
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    NSString *normalizedTitle = [[title
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    NSSet<NSString *> *failureTitles = [NSSet setWithArray:@[
        @"upload failed", @"upload incomplete", @"上传失败",
        @"上传未完成", @"无法上传"
    ]];
    NSSet<NSString *> *successTitles = [NSSet setWithArray:@[
        @"upload complete", @"successfully uploaded", @"上传完成",
        @"上传成功", @"成功上传"
    ]];
    BOOL failure = [failureTitles containsObject:normalizedTitle];
    BOOL success = [successTitles containsObject:normalizedTitle];
    if (!failure && !success) return AMProjXMLImportAlertNone;
    if (titleOut) *titleOut = title;
    if (messageOut) *messageOut = message;
    if (dispatchGenerationOut) {
        *dispatchGenerationOut = transaction.xmlTemplateDispatchGeneration;
    }
    return failure ? AMProjXMLImportAlertFailure
                   : AMProjXMLImportAlertSuccess;
}

// Deleting an existing project or template is never part of an import
// transaction. Keep ordinary confirmation alerts entirely on AM's native
// path; only the exact, active import contexts below may be observed.
static BOOL amproj_hasPluginManagedImportAlertContext(void) {
    AMProjImportTransaction *nativeTransaction =
        amproj_importTransactionForID(amproj_activeNativeImportTransactionID);
    if (amproj_nativeImportObservationActive && nativeTransaction &&
        nativeTransaction.state == AMProjImportTransactionNativeActive) {
        return YES;
    }

    AMProjImportTransaction *xmlTransaction =
        amproj_importTransactionForID(amproj_xmlTemplateImportTransactionID);
    return amproj_xmlTemplateImportActive && xmlTransaction &&
        xmlTransaction.kind == AMProjImportKindXMLTemplate &&
        xmlTransaction.state == AMProjImportTransactionNativeActive &&
        xmlTransaction.xmlTemplatePickerDelegateInvoked &&
        xmlTransaction.xmlTemplateDispatchStarted;
}

static void hooked_presentVC(id self, SEL _cmd, UIViewController *controller,
                             BOOL animated, void (^completion)(void)) {
    if (![NSThread isMainThread] || !controller || !orig_presentVC) {
        amproj_forwardPresentation(self, _cmd, controller, animated, completion);
        return;
    }
    // The Blatant license module (Frameworks/AlightMotion.dylib) presents its
    // welcome and continue-entrance pages as regular controllers. Their
    // classes decrypt at runtime, so the image-name chain is the fingerprint,
    // not any text or class name. The presentation is blocked so no frame of
    // either page can reach the screen, and the gate's own continue control
    // is fired on the not-yet-presented view so the crack state machine still
    // completes and the app proceeds as if the page had been confirmed. Only
    // the class chain is checked here: a per-presentation view-tree walk on
    // large controllers stalled the main thread.
    if (amproj_gateDefenseActive &&
        AMProjPresentationChainHasCrackController(controller)) {
        amproj_logCriticalEvent(@"popup.suppressed", @{
            @"fingerprint": @"Blatant license overlay",
            @"source": @"pre_presentation",
            @"controller": NSStringFromClass(controller.class) ?: @""
        });
        UIView *gateView = controller.viewIfLoaded;
        if (gateView) {
            amproj_bypassGateWindow(gateView.window, @"pre_presentation",
                @"crack gate");
        } else {
            amproj_ensureApplicationKeyWindow();
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    // The subscription wall and the intro flow are auto-skipped by the
    // repack's own crack module (handleIntroFlowHook*); intercepting those
    // presentations deadlocked the launch. They are no longer touched here.
#if AMPROJ_CLOUD_SYNC
    UIViewController *accountReplacement = nil;
    if ([self isKindOfClass:UIViewController.class]) {
        accountReplacement = AMCloudSyncReplacementForNativeAccountPresentation(
            (UIViewController *)self, controller);
    }
    if (accountReplacement) {
        amproj_logCriticalEvent(@"cloud.account.native_present_forward", @{
            @"replacement": NSStringFromClass(accountReplacement.class) ?: @""
        });
        orig_presentVC(self, _cmd, accountReplacement, animated, nil);
        return;
    }
#endif
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        if (amproj_isIPAFireWelcome(controller)) {
            // Some signed 6.2.58 packages present the IPAFire welcome screen
            // as a regular controller rather than an alert. Suppress it
            // before presentation when its marker text is already available.
            amproj_logCriticalEvent(@"popup.suppressed", @{
                @"fingerprint": @"IPAFire welcome",
                @"source": @"pre_presentation",
                @"controller": NSStringFromClass(controller.class) ?: @""
            });
            if (completion) dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        // Build 865 has a different private ShareVC ABI, but its concrete
        // project-package controller is stable enough to use as a semantic
        // boundary.  The adapter performs no selector/ivar calls; it only
        // decides whether our already-generated .amproj exporter should own
        // this presentation.  All other controllers remain native.
        if (amproj_runtimeIsBuild865() &&
            AMProjV865ProjectFlowIsProjectPackageController(controller)) {
            NSString *mode = amproj_exportMode();
            if (![mode isEqualToString:@"observe"] &&
                [self isKindOfClass:UIViewController.class]) {
                UIViewController *presenter = (UIViewController *)self;
                NSString *title = amproj_currentProjectTitle(presenter);
                void (^originalCompletion)(void) = [completion copy];
                amproj_logCriticalEvent(@"865.project_export_entry", @{
                    @"controller": NSStringFromClass(controller.class) ?: @"",
                    @"destination": @"share_sheet",
                    @"native_private_abi": @NO
                });
                dispatch_async(dispatch_get_main_queue(), ^{
                    amproj_startDirectExport(
                        presenter, controller, animated, originalCompletion, title);
                });
                return;
            }
        }
        // The account presentation replacement remains active above. All
        // other controllers, including document pickers, XML import alerts,
        // and activity sheets, must use the native lifecycle exactly once.
        // Do not wrap the completion or run a post-presentation window scan
        // here. On 6.2.58 those callbacks can be Swift-owned and are outside
        // the verified 862 ABI; touching them has caused XML picker/export
        // crashes even though the original presentation itself is valid.
        //
        // The package-share login gate: Alight Motion raises this alert from
        // ShareNC's export tap when the selected option is the project package
        // and no AM account is signed in. The message is matched through its
        // localization key, and only while the tap is still fresh, so other
        // sign-in prompts and other export options are untouched. Bypassing it
        // hands the package export to the plugin's own .amproj flow.
        if (amproj_runtimeIsBuild865() &&
            [controller isKindOfClass:UIAlertController.class] &&
            !amproj_directRequest) {
            UIAlertController *gateAlert = (UIAlertController *)controller;
            NSString *expectedGateMessage = NSLocalizedString(
                @"sign_in_for_package_share_msg", @"");
            BOOL tapIsRecent = amproj_865ShareExportTapAt > 0 &&
                CFAbsoluteTimeGetCurrent() - amproj_865ShareExportTapAt < 3.0;
            if (expectedGateMessage.length &&
                [gateAlert.message isEqualToString:expectedGateMessage] &&
                tapIsRecent &&
                [self isKindOfClass:UIViewController.class] &&
                ((UIViewController *)self).viewIfLoaded.window) {
                UIViewController *exportPresenter = (UIViewController *)self;
                amproj_865ShareExportTapAt = 0;
                amproj_logCriticalEvent(@"direct.865_login_wall_bypassed", @{
                    @"presenter": NSStringFromClass(exportPresenter.class) ?: @""
                });
                if (completion) dispatch_async(dispatch_get_main_queue(), completion);
                NSString *exportTitle =
                    amproj_currentProjectTitle(exportPresenter) ?: @"";
                dispatch_async(dispatch_get_main_queue(), ^{
                    amproj_startDirectExport(
                        exportPresenter, nil, animated, nil, exportTitle);
                });
                return;
            }
        }
        // The one exception is the document picker delegate proxy: with the
        // local engine enabled, a picked .amproj/.xml must enter the plugin's
        // transaction chain instead of Alight Motion's online upload page.
        // The proxy only rewrites delegate callbacks and never wraps the
        // presentation completion.
        if (amproj_runtimeUsesLocalImportEngine() &&
            [controller isKindOfClass:UIDocumentPickerViewController.class]) {
            @try { amproj_attachNativeXMLPickerProxy(controller); }
            @catch (NSException *exception) {
                amproj_logCriticalEvent(@"import.picker_proxy_exception", @{
                    @"name": exception.name ?: @"NSException",
                    @"reason": exception.reason ?: @""
                });
            }
        }
        amproj_log865LegacyPathDisabled(@"presentation_interception");
        orig_presentVC(self, _cmd, controller, animated, completion);
        return;
    }
    BOOL isShareExportHost = amproj_isShareExportHostController(controller);
    if (isShareExportHost) {
        amproj_installShareExportHook();
    }
    // Ordinary confirmations, including project/template deletion, must not
    // enter any startup, export, or private-controller inspection. Managed
    // import alerts are the only UIAlertController instances observed here.
    if ([controller isKindOfClass:UIAlertController.class] &&
        !amproj_hasPluginManagedImportAlertContext()) {
        orig_presentVC(self, _cmd, controller, animated, completion);
        return;
    }
    // The native Upload Project picker accepts both XML and .amproj. Those two
    // formats use the local importer; every unrelated picker result keeps AM's
    // original delegate path.
    if ([controller isKindOfClass:UIDocumentPickerViewController.class]) {
        @try { amproj_attachNativeXMLPickerProxy(controller); }
        @catch (NSException *exception) {
            amproj_logCriticalEvent(@"import.picker_proxy_exception", @{
                @"name": exception.name ?: @"NSException",
                @"reason": exception.reason ?: @""
            });
        }
    }
    NSString *startupPresentationReason = nil;
    AMProjStartupPresentationDecision startupDecision =
        amproj_startupPaywallPresentationDecision(
            [self isKindOfClass:UIViewController.class] ? self : nil,
            controller, &startupPresentationReason);
    if (startupDecision == AMProjStartupPresentationDecisionSuppress) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    if (startupDecision == AMProjStartupPresentationDecisionTrackOuter) {
        NSUInteger generation = amproj_startupPaywallGeneration;
        __weak UIViewController *weakOuter = controller;
        void (^originalCompletion)(void) = [completion copy];
        void (^trackedCompletion)(void) = ^{
            UIViewController *outer = weakOuter;
            amproj_markStartupPaywallOuterPresented(
                outer, @"presentation_completion");
            if (originalCompletion) originalCompletion();
            dispatch_async(dispatch_get_main_queue(), ^{
                amproj_reconcileStartupPaywall(
                    generation, @"presentation_completion");
            });
        };
        orig_presentVC(self, _cmd, controller, animated, trackedCompletion);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_reconcileStartupPaywall(generation, @"presentation_probe");
        });
        return;
    }
    if (amproj_isIPAFireWelcome(controller)) {
        NSLog(@"[AMProjExport] Suppressed IPAFire welcome alert");
        amproj_debugEvent(@"popup.suppressed", @{@"fingerprint": @"IPAFire welcome"});
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }

    NSString *XMLAlertTitle = nil;
    NSString *XMLAlertMessage = nil;
    NSUInteger XMLDispatchGeneration = 0;
    AMProjXMLImportAlertResult XMLAlertResult =
        amproj_XMLImportAlertResult(
            controller,
            [self isKindOfClass:UIViewController.class] ? self : nil,
            &XMLAlertTitle, &XMLAlertMessage, &XMLDispatchGeneration);
    if (XMLAlertResult != AMProjXMLImportAlertNone) {
        NSString *transactionID =
            [amproj_xmlTemplateImportTransactionID copy];
        amproj_xmlTemplateResultAlert = controller;
        amproj_debugEvent(
            XMLAlertResult == AMProjXMLImportAlertSuccess
                ? @"import.xml_native_success_alert"
                : @"import.xml_native_failure_alert", @{
            @"transaction_id": transactionID ?: @"",
            @"title": XMLAlertTitle ?: @"",
            @"message": XMLAlertMessage ?: @"",
            @"dispatch_generation": @(XMLDispatchGeneration),
            @"presenter": NSStringFromClass([self class]) ?: @""
        });
        orig_presentVC(self, _cmd, controller, animated, completion);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!transactionID.length ||
                ![amproj_xmlTemplateImportTransactionID
                    isEqualToString:transactionID]) return;
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionID);
            if (!transaction ||
                transaction.xmlTemplateDispatchGeneration !=
                    XMLDispatchGeneration ||
                !transaction.xmlTemplatePickerDelegateInvoked ||
                !transaction.xmlTemplateDispatchStarted) return;
            if (XMLAlertResult == AMProjXMLImportAlertSuccess) {
                transaction.nativeCompletionSucceeded = YES;
                amproj_waitForXMLPickerDismissal(
                    amproj_xmlTemplateImportGeneration,
                    transactionID, transaction.name ?: @"project.xml",
                    XMLDispatchGeneration, 0);
            } else {
                NSString *detail = XMLAlertMessage.length
                    ? XMLAlertMessage : XMLAlertTitle;
                amproj_finishXMLTemplateImportAfterPicker(
                    transactionID, NO,
                    detail.length ? detail : @"AM 原生 XML 导入失败",
                    NO, 0);
            }
        });
        return;
    }

    NSString *suppressedXMLTransactionID = nil;
    NSString *suppressedXMLTitle = nil;
    NSString *suppressedXMLMessage = nil;
    if (amproj_isSuppressibleXMLMissingMediaAlert(
            controller, &suppressedXMLTransactionID, &suppressedXMLTitle,
            &suppressedXMLMessage)) {
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(suppressedXMLTransactionID);
        transaction.xmlImportedAnywayWarningObserved = YES;
        amproj_debugEvent(@"import.xml_missing_media_suppressed", @{
            @"transaction_id": suppressedXMLTransactionID ?: @"",
            @"title": suppressedXMLTitle ?: @"",
            @"message": suppressedXMLMessage ?: @"",
            @"native_status_4_observed": @YES,
            @"native_status_4_returned":
                @(transaction.nativeTerminalStatus4Returned),
            @"action": @"suppress_then_complete_after_status_4_returns"
        });
        amproj_finishSuppressedXMLMissingMediaAlert(
            suppressedXMLTransactionID, 0);
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }

    NSString *nativeFailureTitle = nil;
    NSString *nativeFailureMessage = nil;
    if (amproj_isNativeImportFailureAlert(
            controller, &nativeFailureTitle, &nativeFailureMessage)) {
        NSDictionary *observation = amproj_nativeImportObservationFields();
        NSDictionary *parserSnapshot = amproj_currentNativeParserSnapshot();
        NSString *name = amproj_nativeImportObservationName ?:
            amproj_nativeImportRecognitionName ?: @"project.amproj";
        NSMutableArray<NSString *> *actionTitles = [NSMutableArray array];
        for (UIAlertAction *action in ((UIAlertController *)controller).actions) {
            if (action.title.length) [actionTitles addObject:action.title];
        }
        NSMutableDictionary *failureFields = [@{
            @"filename": name,
            @"attempt_id": observation[@"attempt_id"] ?: @"",
            @"import_phase": observation[@"phase"] ?: @"",
            @"elapsed_ms": observation[@"elapsed_ms"] ?: @0,
            @"title": nativeFailureTitle ?: @"",
            @"message": nativeFailureMessage ?: @"",
            @"actions": actionTitles,
            @"presenter": NSStringFromClass([self class]) ?: @"",
            @"controller": NSStringFromClass([controller class]) ?: @""
        } mutableCopy];
        if (parserSnapshot.count) failureFields[@"xml_parser"] = parserSnapshot;
        amproj_debugEvent(@"import.native_failure_alert", failureFields);
        NSString *parserSummary = amproj_visibleNativeParserSummary(parserSnapshot);
        NSString *nativeDetail = amproj_compactNativeDiagnostic(
            [NSString stringWithFormat:@"%@%@%@", nativeFailureTitle ?: @"",
                nativeFailureTitle.length && nativeFailureMessage.length ? @": " : @"",
                nativeFailureMessage ?: @""], 72);
        NSString *visibleDetail = parserSummary.length && nativeDetail.length
            ? [NSString stringWithFormat:@"%@ \u00b7 %@", parserSummary, nativeDetail]
            : (parserSummary.length ? parserSummary : nativeDetail);
        NSLog(@"[AMProjExport] Native import failed: %@; parser=%@",
              nativeDetail, parserSnapshot ?: @{});
        NSString *failureDescription = visibleDetail.length
            ? visibleDetail : @"AM \u539f\u751f\u5bfc\u5165\u5931\u8d25";
        NSError *bridgeError = [NSError errorWithDomain:@"com.amproj.import.native"
                                                     code:40
                                                 userInfo:@{
            NSLocalizedDescriptionKey: failureDescription,
            @"AMProjNativeAlertPresented": @YES
        }];
        BOOL bridgeHandled =
            AMProjNativePackageImportBridgeFinishFailure(bridgeError);
        if (!bridgeHandled) {
            amproj_waitingForNativeImportAlert = NO;
            amproj_activeNativeImportGeneration = 0;
            amproj_endNativeImportObservation();
            amproj_nativeImportRecognitionName = nil;
            ++amproj_nativeImportRecognitionGeneration;
            amproj_importDispatchCoolingDown = NO;
        }
        amproj_showImportStatus([NSString stringWithFormat:
            @"AMProj \u00b7 E40 \u00b7 %@", failureDescription], YES);
        amproj_flushDebugEvents();
        if (!bridgeHandled) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                amproj_resumeQueuedImports(@"native_import_failure");
            });
        }
    }

    NSString *mode = amproj_exportMode();
    // The exact package controller is the final semantic boundary before AM
    // enters its crash-prone native package flow. No private ShareVC state is
    // read, and every other export type continues on AM's native path.
    if (amproj_isSharePackageController(controller)) {
        amproj_debugEvent(@"direct.native_package_presentation", @{
            @"mode": mode ?: @"",
            @"controller": NSStringFromClass(controller.class) ?: @"",
            @"action": [mode isEqualToString:@"observe"]
                ? @"observe" : @"direct_export_fallback"
        });
        if (![mode isEqualToString:@"observe"] &&
            [self isKindOfClass:UIViewController.class] && orig_presentVC) {
            UIViewController *presenter = (UIViewController *)self;
            NSString *title = amproj_currentProjectTitle(presenter);
            void (^originalCompletion)(void) = [completion copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                amproj_startDirectExport(
                    presenter, controller, animated, originalCompletion, title);
            });
            return;
        }
    }

    BOOL isActivity = [controller isKindOfClass:[UIActivityViewController class]];
    if (isActivity) {
        amproj_setPhase(AMProjDebugPhasePresent, @{
            @"presenter": NSStringFromClass([self class]) ?: @"",
            @"controller": NSStringFromClass([controller class]) ?: @""
        });
        amproj_debugEvent(@"present.enter", @{
            @"presenter": NSStringFromClass([self class]) ?: @"",
            @"controller": NSStringFromClass([controller class]) ?: @""
        });
    }
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    orig_presentVC(self, _cmd, controller, animated, completion);
    // During the startup window, a just-presented controller is checked once
    // against the subscription-wall fingerprint. The SwiftUI class names of
    // the wall changed between builds, so this post-presentation probe is
    // what guarantees the wall closes within the same flow that opened it.
    if ([controller isKindOfClass:UIViewController.class]) {
        UIViewController *presented = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Export every presented chain once per class: the syslog
            // redacts dictionary values, so this file is how a modal whose
            // fingerprint escaped reports its real class names.
            NSString *presentedName = NSStringFromClass(presented.class) ?: @"";
            static NSMutableSet<NSString *> *amproj_chainExportedClasses;
            if (!amproj_chainExportedClasses) {
                amproj_chainExportedClasses = [NSMutableSet set];
            }
            if (presentedName.length &&
                ![amproj_chainExportedClasses containsObject:presentedName] &&
                amproj_chainExportedClasses.count < 24) {
                [amproj_chainExportedClasses addObject:presentedName];
                NSMutableArray<NSString *> *classes = [NSMutableArray array];
                UIViewController *cursor = presented;
                for (NSUInteger depth = 0; cursor && depth < 8; depth++) {
                    [classes addObject:NSStringFromClass(cursor.class) ?: @""];
                    cursor = cursor.presentingViewController;
                }
                amproj_exportPresentedChainDiagnostics(classes);
            }
            // The intro flow hosts the subscription step. Let it render and
            // wire its controls, then activate its top-left close control
            // the way a user would, with a hard dismiss as the fallback so
            // the launch always proceeds to main.
            if (!amproj_gateDefenseActive) return;
            if (!amproj_introAutocloseEnabled) return;
            if ([presentedName containsString:@"IntroFlowNavigation"]) {
                NSInteger rounds = [objc_getAssociatedObject(presented,
                    amproj_introCloseRoundsKey) integerValue];
                if (rounds < 3) {
                    objc_setAssociatedObject(presented,
                        amproj_introCloseRoundsKey, @(rounds + 1),
                        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    UIViewController *intro = presented;
                    for (NSNumber *delay in @[@1.2, @2.5]) {
                        dispatch_after(dispatch_time(
                            DISPATCH_TIME_NOW,
                            (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                            BOOL activated = amproj_activateIntroCloseControl(
                                intro);
                            amproj_logCriticalEvent(
                                @"startup.intro_autoclose", @{
                                @"delay": delay,
                                @"activated": @(activated),
                                @"round": @(rounds + 1)
                            });
                        });
                    }
                    dispatch_after(dispatch_time(
                        DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                        if (intro.presentingViewController) {
                            amproj_logCriticalEvent(
                                @"startup.intro_dismissed", @{
                                @"controller": NSStringFromClass(
                                    intro.class) ?: @""
                            });
                            [intro.presentingViewController
                                dismissViewControllerAnimated:YES
                                                   completion:nil];
                        }
                    });
                }
            }
        });
    }
#if AMPROJ_CLOUD_SYNC
    if (isShareExportHost) {
        dispatch_async(dispatch_get_main_queue(), ^{
            uint8_t selectedExportOption = UINT8_MAX;
            UIViewController *shareVC = amproj_shareVCRecursive(
                controller, 0, [NSMutableSet set], &selectedExportOption);
            amproj_scheduleCloudUploadLabelCustomization(shareVC);
        });
    }
#endif
    if (isActivity) {
        amproj_debugEvent(@"present.return", @{
            @"duration_ms": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0)
        });
    }
    if (!isActivity && ![controller isKindOfClass:UIAlertController.class]) {
        amproj_schedulePaywallScan(controller, @"presentation");
    }
}

#if AMPROJ_DEBUG
static void (*orig_viewDidAppear)(id, SEL, BOOL) = NULL;
static void (*orig_viewDidDisappear)(id, SEL, BOOL) = NULL;
static void (*orig_packageViewDidAppear)(id, SEL, BOOL) = NULL;
static void (*orig_packageViewDidDisappear)(id, SEL, BOOL) = NULL;
static void (*orig_setProgressAnimated)(id, SEL, float, BOOL) = NULL;
static void (*orig_setProgress)(id, SEL, float) = NULL;
static void (*orig_labelSetText)(id, SEL, NSString *) = NULL;

static BOOL amproj_isPackageController(id controller) {
    return amproj_isPackageControllerName(NSStringFromClass([controller class]));
}

static void hooked_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (amproj_isPackageController(self)) amproj_beginPackageFlow(@"view_did_appear");
    orig_viewDidAppear(self, _cmd, animated);
    if ([self isKindOfClass:UIViewController.class]) {
        amproj_recordPaywallControllerAppearance((UIViewController *)self);
        amproj_schedulePaywallScan((UIViewController *)self, @"view_did_appear");
    }
    if (amproj_isPackageController(self)) {
        amproj_debugEvent(@"package_vc.appeared", @{@"class": NSStringFromClass([self class]) ?: @""});
    }
}

static void hooked_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidDisappear(self, _cmd, animated);
    if (amproj_isPackageController(self)) {
        amproj_debugEvent(@"package_vc.disappeared", @{@"class": NSStringFromClass([self class]) ?: @""});
        amproj_endPackageFlow(@"view_disappeared");
    }
}

static void hooked_packageViewDidAppear(id self, SEL _cmd, BOOL animated) {
    amproj_beginPackageFlow(@"package_override_view_did_appear");
    orig_packageViewDidAppear(self, _cmd, animated);
    amproj_debugEvent(@"package_vc.appeared", @{
        @"class": NSStringFromClass([self class]) ?: @"",
        @"hook": @"subclass"
    });
}

static void hooked_packageViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    orig_packageViewDidDisappear(self, _cmd, animated);
    amproj_debugEvent(@"package_vc.disappeared", @{
        @"class": NSStringFromClass([self class]) ?: @"",
        @"hook": @"subclass"
    });
    amproj_endPackageFlow(@"subclass_view_disappeared");
}

static void amproj_recordProgress(float progress, NSString *source) {
    if (!atomic_load(&amproj_packageFlowActive)) return;
    float previous = atomic_load(&amproj_lastProgress);
    if (fabsf(previous - progress) < 0.0001f) return;
    uint64_t progressGeneration = atomic_fetch_add(&amproj_progressGeneration, 1) + 1;
    atomic_store(&amproj_lastProgress, progress);
    amproj_debugEvent(@"export.progress", @{@"value": @(progress), @"source": source ?: @""});
    if (progress >= amproj_stallProgressThreshold) {
        amproj_scheduleProgressWatchdog(progressGeneration);
    }
}

static void hooked_setProgressAnimated(id self, SEL _cmd, float progress, BOOL animated) {
    orig_setProgressAnimated(self, _cmd, progress, animated);
    amproj_recordProgress(progress, @"UIProgressView.animated");
}

static void hooked_setProgress(id self, SEL _cmd, float progress) {
    orig_setProgress(self, _cmd, progress);
    amproj_recordProgress(progress, @"UIProgressView");
}

static BOOL amproj_parseProgressLabel(NSString *text, float *progress) {
    NSRange percentRange = [text rangeOfString:@"%"];
    if (percentRange.location == NSNotFound) return NO;

    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSCharacterSet *numberCharacters =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789.,"];
    NSUInteger end = percentRange.location;
    while (end > 0 && [whitespace characterIsMember:[text characterAtIndex:end - 1]]) end--;
    NSUInteger start = end;
    while (start > 0 && [numberCharacters characterIsMember:[text characterAtIndex:start - 1]]) start--;
    if (start == end) return NO;

    NSString *number = [[text substringWithRange:NSMakeRange(start, end - start)]
        stringByReplacingOccurrencesOfString:@"," withString:@"."];
    double value = number.doubleValue;
    if (!isfinite(value) || value < 0.0 || value > 100.0) return NO;
    if (progress) *progress = (float)(value / 100.0);
    return YES;
}

static void hooked_labelSetText(id self, SEL _cmd, NSString *text) {
    orig_labelSetText(self, _cmd, text);
    if (atomic_load(&amproj_packageFlowActive) && [text containsString:@"%"] && text.length < 32) {
        amproj_debugEvent(@"export.progress_label", @{@"text": text});
        float progress = 0.0f;
        if (amproj_parseProgressLabel(text, &progress)) {
            amproj_recordProgress(progress, @"UILabel");
        }
    }
}

typedef void (^AMProjDataCompletion)(NSData *, NSURLResponse *, NSError *);
static NSURLSessionDataTask *(*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *, AMProjDataCompletion) = NULL;

static NSURLSessionDataTask* hooked_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request,
                                                        AMProjDataCompletion completion) {
    if (!atomic_load(&amproj_packageFlowActive) || AMDebugTransportIsInternalRequest(request)) {
        return orig_dataTaskWithRequest(self, _cmd, request, completion);
    }
    NSURL *url = request.URL;
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    amproj_debugEvent(@"network.start", @{
        @"method": request.HTTPMethod ?: @"GET",
        @"scheme": url.scheme ?: @"",
        @"host": url.host ?: @"",
        @"path": url.path ?: @""
    });
    AMProjDataCompletion wrapped = completion ? ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ?
            ((NSHTTPURLResponse *)response).statusCode : 0;
        amproj_debugEvent(@"network.finish", @{
            @"method": request.HTTPMethod ?: @"GET",
            @"host": url.host ?: @"",
            @"path": url.path ?: @"",
            @"status": @(status),
            @"duration_ms": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
            @"error": error.localizedDescription ?: @""
        });
        completion(data, response, error);
    } : nil;
    return orig_dataTaskWithRequest(self, _cmd, request, wrapped);
}
#endif

// ═══════════════════════════════════════════
// MARK: - Constructor
// ═══════════════════════════════════════════

static id amproj_willLaunchObserver = nil;
static id amproj_didLaunchObserver = nil;
static id amproj_didBecomeActiveObserver = nil;
static id amproj_willResignActiveObserver = nil;
static id amproj_sceneWillConnectObserver = nil;
static id amproj_sceneWillDeactivateObserver = nil;
static id amproj_windowDidBecomeKeyObserver = nil;
static id amproj_windowDidBecomeVisibleObserver = nil;
static id amproj_willEnterForegroundObserver = nil;
static void (*orig_windowMakeKeyAndVisible)(UIWindow *, SEL) = NULL;

static void hooked_windowMakeKeyAndVisible(UIWindow *window, SEL _cmd) {
    if (orig_windowMakeKeyAndVisible) {
        orig_windowMakeKeyAndVisible(window, _cmd);
    }
    if (!window || !amproj_runtimeIsBuild865() || !NSThread.isMainThread) return;

    // makeKeyAndVisible returns before Core Animation commits the next frame.
    // Suppress an already-built welcome hierarchy synchronously so it never
    // flashes, then retain the delayed probes for labels added after layout.
    amproj_suppressIPAFireWelcomeWindows(@"window_make_key_and_visible");
    amproj_scheduleIPAFireWelcomeSuppression(@"window_make_key_and_visible");
}

static IMP amproj_installMethodHook(Method method, IMP replacement,
                                    unsigned int expectedArguments, NSString *name) {
    if (!method || !replacement) return NULL;
    unsigned int arguments = method_getNumberOfArguments(method);
    if (arguments != expectedArguments) {
        const char *encoding = method_getTypeEncoding(method);
        NSLog(@"[AMProjExport] Refusing hook %@: expected %u args, got %u (%s)",
              name, expectedArguments, arguments, encoding ?: "unknown");
        amproj_debugEvent(@"hooks.rejected", @{
            @"name": name ?: @"",
            @"expected_arguments": @(expectedArguments),
            @"actual_arguments": @(arguments),
            @"encoding": encoding ? [NSString stringWithUTF8String:encoding] : @""
        });
        return NULL;
    }
    IMP current = method_getImplementation(method);
    if (current == replacement) {
        NSLog(@"[AMProjExport] Hook %@ is already installed", name);
        return NULL;
    }
    return method_setImplementation(method, replacement);
}

static Method amproj_ownInstanceMethod(Class cls, SEL selector) {
    if (!cls || !selector) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static void amproj_installIPAFireWindowHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!amproj_runtimeIsBuild865()) return;
        Method method = amproj_ownInstanceMethod(
            UIWindow.class, @selector(makeKeyAndVisible));
        if (!method) {
            amproj_logCriticalEvent(@"popup.window_hook_unavailable", @{
                @"selector": @"makeKeyAndVisible"
            });
            return;
        }
        orig_windowMakeKeyAndVisible = (void (*)(UIWindow *, SEL))
            amproj_installMethodHook(
                method, (IMP)hooked_windowMakeKeyAndVisible, 2,
                @"UIWindow.makeKeyAndVisible");
    });
}

static BOOL amproj_installTrackedHook(Class cls, SEL selector, IMP replacement,
                                      unsigned int expectedArguments,
                                      AMProjTrackedHook *hooks, NSUInteger hookCount,
                                      BOOL *changed) {
    if (changed) *changed = NO;
    if (!cls || !selector || !replacement) return NO;
    Method resolved = class_getInstanceMethod(cls, selector);
    if (!resolved || method_getNumberOfArguments(resolved) != expectedArguments) return NO;

    Method own = amproj_ownInstanceMethod(cls, selector);
    IMP current = method_getImplementation(own ?: resolved);
    if (current == replacement) return YES;
    const char *encoding = method_getTypeEncoding(resolved);
    if (!encoding) return NO;

    if (!amproj_storeOriginalHook(hooks, hookCount, cls, current)) return NO;
    if (own) {
        method_setImplementation(own, replacement);
    } else if (!class_addMethod(cls, selector, replacement, encoding)) {
        own = amproj_ownInstanceMethod(cls, selector);
        if (!own) return NO;
        current = method_getImplementation(own);
        if (current != replacement) {
            if (!amproj_storeOriginalHook(hooks, hookCount, cls, current)) return NO;
            method_setImplementation(own, replacement);
        }
    }
    if (changed) *changed = YES;
    return class_getMethodImplementation(cls, selector) == replacement;
}

static void hooked_applicationSetDelegate(UIApplication *application, SEL _cmd,
                                          id<UIApplicationDelegate> delegate) {
    if (orig_applicationSetDelegate) {
        orig_applicationSetDelegate(application, _cmd, delegate);
    }
    if (!delegate) return;
    if (amproj_runtimeUsesPublic865ImportHooks()) {
        amproj_public865Application = application;
        amproj_public865RuntimeDelegate = delegate;
    }

    // Install against the concrete delegate immediately after UIKit binds it.
    // A second main-queue pass catches proxy subclasses installed in the same
    // startup turn without delaying launch-option capture.
    amproj_installPublic865ImportHooks();
    amproj_installImportHook();
    __weak UIApplication *weakApplication = application;
    __weak id<UIApplicationDelegate> weakDelegate = delegate;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *strongApplication = weakApplication;
        id<UIApplicationDelegate> strongDelegate = weakDelegate;
        if (strongApplication.delegate == strongDelegate) {
            if (amproj_runtimeUsesPublic865ImportHooks()) {
                amproj_public865Application = strongApplication;
                amproj_public865RuntimeDelegate = strongDelegate;
            }
            amproj_installPublic865ImportHooks();
            amproj_installImportHook();
        }
    });
}

static void amproj_installApplicationDelegateHook(void) {
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"application_delegate_hook");
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod(
            [UIApplication class], @selector(setDelegate:));
        IMP previous = amproj_installMethodHook(
            method, (IMP)hooked_applicationSetDelegate, 3,
            @"UIApplication.setDelegate");
        if (previous) {
            orig_applicationSetDelegate = (AMProjApplicationSetDelegateIMP)previous;
        }
    });
}

static NSDictionary* amproj_nativeParserElementSnapshot(
    NSXMLParser *parser, NSString *elementName,
    NSDictionary<NSString *, NSString *> *attributes, NSString *delegateClass) {
    NSMutableDictionary *snapshot = [@{
        @"last_element": elementName ?: @"",
        @"line": @(parser.lineNumber),
        @"column": @(parser.columnNumber),
        @"delegate": delegateClass ?: @""
    } mutableCopy];
    NSArray<NSString *> *attributeKeys =
        [[attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]
            subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)24, attributes.count))];
    snapshot[@"attribute_keys"] = attributeKeys ?: @[];
    if ([elementName isEqualToString:@"property"]) {
        snapshot[@"property_name"] = attributes[@"name"] ?: @"";
        snapshot[@"property_type"] = attributes[@"type"] ?: @"";
    } else if ([elementName isEqualToString:@"effect"]) {
        snapshot[@"effect_id"] = attributes[@"id"] ?: @"";
    } else if ([elementName isEqualToString:@"scene"]) {
        snapshot[@"amver"] = attributes[@"amver"] ?: @"";
        snapshot[@"ffver"] = attributes[@"ffver"] ?: @"";
    }
    return snapshot;
}

static NSUInteger amproj_nativeSceneParserErrorCount(id delegate) {
#if AMPROJ_DEBUG
    if (!delegate) return NSNotFound;
    Ivar errors = class_getInstanceVariable([delegate class], "errors");
    if (!errors) return NSNotFound;
    ptrdiff_t offset = ivar_getOffset(errors);
    size_t instanceSize = class_getInstanceSize([delegate class]);
    if (offset <= 0 || (size_t)offset + sizeof(uintptr_t) > instanceSize) {
        return NSNotFound;
    }

    uintptr_t storage = 0;
    const uint8_t *objectBytes =
        (const uint8_t *)(__bridge const void *)delegate;
    memcpy(&storage, objectBytes + offset, sizeof(storage));
    if (storage < 0x1000 || (storage & (sizeof(uintptr_t) - 1)) != 0) {
        return NSNotFound;
    }
    uintptr_t count = 0;
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(), (vm_address_t)(storage + 0x10), sizeof(count),
        (vm_address_t)(uintptr_t)&count, &copied);
    if (result != KERN_SUCCESS || copied != sizeof(count)) return NSNotFound;
    return count <= (1U << 20) ? (NSUInteger)count : NSNotFound;
#else
    (void)delegate;
    return NSNotFound;
#endif
}

static NSMutableArray<NSString *>* amproj_nativeParserElementStack(
    NSXMLParser *parser, BOOL create) {
    NSMutableArray<NSString *> *stack = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserElementStackKey);
    if (!stack && create) {
        stack = [NSMutableArray array];
        objc_setAssociatedObject(parser, &amproj_nativeXMLParserElementStackKey,
                                 stack, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return stack;
}

static void amproj_recordNativeSceneParserError(
    id delegate, NSXMLParser *parser, NSString *callback,
    NSUInteger beforeCount, NSUInteger afterCount) {
    if (beforeCount == NSNotFound || afterCount == NSNotFound ||
        afterCount <= beforeCount) return;
    NSString *attemptID = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserAttemptKey);
    if (!attemptID.length) return;

    NSDictionary *current = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserLastElementKey);
    NSMutableDictionary *snapshot = [(current ?: @{}) mutableCopy];
    NSMutableArray<NSString *> *stack = amproj_nativeParserElementStack(parser, NO);
    NSArray<NSString *> *pathParts = stack.count > 16
        ? [stack subarrayWithRange:NSMakeRange(stack.count - 16, 16)] : stack;
    snapshot[@"semantic_error_count"] = @(afterCount);
    snapshot[@"semantic_error_delta"] = @(afterCount - beforeCount);
    snapshot[@"semantic_error_callback"] = callback ?: @"";
    snapshot[@"element_path"] = [pathParts componentsJoinedByString:@"/"] ?: @"";
    snapshot[@"line"] = @(parser.lineNumber);
    snapshot[@"column"] = @(parser.columnNumber);
    snapshot[@"delegate"] = NSStringFromClass([delegate class]) ?: @"";
    objc_setAssociatedObject(parser, &amproj_nativeXMLParserLastElementKey,
                             snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(parser, &amproj_nativeXMLParserSemanticErrorKey)) {
        objc_setAssociatedObject(parser, &amproj_nativeXMLParserSemanticErrorKey,
                                 snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSMutableDictionary *event = [snapshot mutableCopy];
    event[@"attempt_id"] = attemptID;
    amproj_debugEvent(@"import.native_scene_error", event);
}

static void hooked_nativeXMLParserDidStartElement(
    id self, SEL _cmd, NSXMLParser *parser, NSString *elementName,
    NSString *namespaceURI, NSString *qualifiedName,
    NSDictionary<NSString *, NSString *> *attributes) {
    NSString *attemptID = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserAttemptKey);
    NSMutableArray<NSString *> *stack = nil;
    if (attemptID.length) {
        stack = amproj_nativeParserElementStack(parser, YES);
        [stack addObject:elementName ?: @"?"];
        NSDictionary *snapshot = amproj_nativeParserElementSnapshot(
            parser, elementName, attributes ?: @{}, NSStringFromClass([self class]));
        NSMutableDictionary *withPath = [snapshot mutableCopy];
        NSArray<NSString *> *pathParts = stack.count > 16
            ? [stack subarrayWithRange:NSMakeRange(stack.count - 16, 16)] : stack;
        withPath[@"element_path"] =
            [pathParts componentsJoinedByString:@"/"] ?: @"";
        objc_setAssociatedObject(parser, &amproj_nativeXMLParserLastElementKey,
                                 withPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSNumber *previousCount = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserErrorCountKey);
    NSUInteger beforeCount = previousCount ? previousCount.unsignedIntegerValue : NSNotFound;
    IMP original = amproj_originalHookForReceiver(
        amproj_nativeXMLDelegateStartHooks,
        sizeof(amproj_nativeXMLDelegateStartHooks) /
            sizeof(amproj_nativeXMLDelegateStartHooks[0]), self);
    if (original) {
        ((void (*)(id, SEL, NSXMLParser *, NSString *, NSString *, NSString *,
                   NSDictionary *))(void *)original)(
            self, _cmd, parser, elementName, namespaceURI, qualifiedName, attributes);
    }
    NSUInteger afterCount = attemptID.length
        ? amproj_nativeSceneParserErrorCount(self) : NSNotFound;
    if (afterCount != NSNotFound) {
        objc_setAssociatedObject(parser, &amproj_nativeXMLParserErrorCountKey,
                                 @(afterCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    amproj_recordNativeSceneParserError(
        self, parser, @"did_start_element", beforeCount, afterCount);
}

static void hooked_nativeXMLParserDidEndElement(
    id self, SEL _cmd, NSXMLParser *parser, NSString *elementName,
    NSString *namespaceURI, NSString *qualifiedName) {
    NSString *attemptID = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserAttemptKey);
    NSNumber *previousCount = objc_getAssociatedObject(
        parser, &amproj_nativeXMLParserErrorCountKey);
    NSUInteger beforeCount = previousCount ? previousCount.unsignedIntegerValue : NSNotFound;
    IMP original = amproj_originalHookForReceiver(
        amproj_nativeXMLDelegateEndHooks,
        sizeof(amproj_nativeXMLDelegateEndHooks) /
            sizeof(amproj_nativeXMLDelegateEndHooks[0]), self);
    if (original) {
        ((void (*)(id, SEL, NSXMLParser *, NSString *, NSString *, NSString *))
            (void *)original)(self, _cmd, parser, elementName,
                              namespaceURI, qualifiedName);
    }
    NSUInteger afterCount = attemptID.length
        ? amproj_nativeSceneParserErrorCount(self) : NSNotFound;
    if (afterCount != NSNotFound) {
        objc_setAssociatedObject(parser, &amproj_nativeXMLParserErrorCountKey,
                                 @(afterCount), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    amproj_recordNativeSceneParserError(
        self, parser, @"did_end_element", beforeCount, afterCount);
    NSMutableArray<NSString *> *stack = amproj_nativeParserElementStack(parser, NO);
    if (attemptID.length && stack.count) [stack removeLastObject];
}

static BOOL hooked_nativeXMLParserParse(NSXMLParser *parser, SEL _cmd) {
    id delegate = parser.delegate;
    NSString *delegateClass = delegate ? NSStringFromClass([delegate class]) : @"";
    NSString *currentAttemptID = amproj_currentNativeImportAttemptID();
    NSString *attemptID = currentAttemptID.length &&
        [delegateClass containsString:@"SceneParserDelegate"]
        ? currentAttemptID : nil;
    NSString *importPhase = attemptID.length
        ? amproj_currentNativeImportObservationPhase() : nil;
    if (attemptID.length) {
        objc_setAssociatedObject(parser, &amproj_nativeXMLParserAttemptKey,
                                 attemptID, OBJC_ASSOCIATION_COPY_NONATOMIC);
        amproj_installNativeXMLDelegateHook(object_getClass(delegate));
        NSUInteger initialErrorCount = amproj_nativeSceneParserErrorCount(delegate);
        if (initialErrorCount != NSNotFound) {
            objc_setAssociatedObject(parser, &amproj_nativeXMLParserErrorCountKey,
                                     @(initialErrorCount),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        amproj_debugEvent(@"import.native_xml_parser", @{
            @"phase": @"begin",
            @"attempt_id": attemptID,
            @"import_phase": importPhase ?: @"",
            @"delegate": delegateClass ?: @""
        });
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    BOOL parsed = orig_nativeXMLParserParse
        ? orig_nativeXMLParserParse(parser, _cmd) : NO;
    if (attemptID.length) {
        NSError *error = parser.parserError;
        NSDictionary *lastElement = objc_getAssociatedObject(
            parser, &amproj_nativeXMLParserLastElementKey);
        NSDictionary *semanticError = objc_getAssociatedObject(
            parser, &amproj_nativeXMLParserSemanticErrorKey);
        NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
        [snapshot addEntriesFromDictionary:semanticError ?: lastElement ?: @{}];
        if (semanticError.count && lastElement.count) {
            snapshot[@"final_element"] = lastElement[@"last_element"] ?: @"";
            snapshot[@"final_line"] = lastElement[@"line"] ?: @0;
            snapshot[@"final_column"] = lastElement[@"column"] ?: @0;
        }
        snapshot[@"attempt_id"] = attemptID;
        snapshot[@"import_phase"] = importPhase ?: @"";
        snapshot[@"delegate"] = delegateClass ?: @"";
        snapshot[@"result"] = @(parsed);
        snapshot[@"duration_ms"] =
            @((CFAbsoluteTimeGetCurrent() - started) * 1000.0);
        snapshot[@"parser_line"] = @(parser.lineNumber);
        snapshot[@"parser_column"] = @(parser.columnNumber);
        snapshot[@"error_domain"] = error.domain ?: @"";
        snapshot[@"error_code"] = @(error.code);
        snapshot[@"error_description"] = error.localizedDescription ?: @"";
        amproj_storeNativeParserSnapshot(attemptID, snapshot);
        NSMutableDictionary *event = [snapshot mutableCopy];
        event[@"phase"] = @"end";
        amproj_debugEvent(@"import.native_xml_parser", event);
        NSLog(@"[AMProjExport] Native SceneParser result=%d element=%@ line=%@ "
              "column=%@ error=%@",
              parsed, snapshot[@"last_element"], snapshot[@"line"],
              snapshot[@"column"], error);
    }
    return parsed;
}

static void amproj_installNativeXMLDelegateHook(Class cls) {
    if (!cls) return;
    BOOL startChanged = NO;
    BOOL startInstalled = amproj_installTrackedHook(
        cls, @selector(parser:didStartElement:namespaceURI:qualifiedName:attributes:),
        (IMP)hooked_nativeXMLParserDidStartElement, 7,
        amproj_nativeXMLDelegateStartHooks,
        sizeof(amproj_nativeXMLDelegateStartHooks) /
            sizeof(amproj_nativeXMLDelegateStartHooks[0]), &startChanged);
    BOOL endChanged = NO;
    BOOL endInstalled = amproj_installTrackedHook(
        cls, @selector(parser:didEndElement:namespaceURI:qualifiedName:),
        (IMP)hooked_nativeXMLParserDidEndElement, 6,
        amproj_nativeXMLDelegateEndHooks,
        sizeof(amproj_nativeXMLDelegateEndHooks) /
            sizeof(amproj_nativeXMLDelegateEndHooks[0]), &endChanged);
    if (startChanged || endChanged) {
        amproj_debugEvent(@"import.native_xml_delegate_hook", @{
            @"class": NSStringFromClass(cls) ?: @"",
            @"start": @(startInstalled),
            @"end": @(endInstalled)
        });
    }
}

static void amproj_installNativeXMLParserHook(void) {
#if AMPROJ_DEBUG
    static BOOL installed = NO;
    if (installed) return;
    Method method = class_getInstanceMethod(NSXMLParser.class, @selector(parse));
    IMP previous = amproj_installMethodHook(
        method, (IMP)hooked_nativeXMLParserParse, 2, @"NSXMLParser.parse");
    if (previous) {
        orig_nativeXMLParserParse = (void *)previous;
        installed = YES;
    }
    amproj_debugEvent(@"import.native_xml_parser_hook", @{
        @"installed": @(installed)
    });
#endif
}

static NSString* amproj_compactNativeDiagnostic(NSString *text,
                                                NSUInteger maximumLength) {
    NSString *value = [[text ?: @""
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    while ([value containsString:@"  "]) {
        value = [value stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (value.length > maximumLength) {
        value = [[value substringToIndex:maximumLength] stringByAppendingString:@"..."];
    }
    return value;
}

static NSString* amproj_visibleNativeParserSummary(NSDictionary *snapshot) {
    if (!snapshot.count) return @"";
    BOOL parsed = [snapshot[@"result"] boolValue];
    NSString *element = [snapshot[@"last_element"] isKindOfClass:NSString.class]
        ? snapshot[@"last_element"] : @"";
    NSNumber *line = [snapshot[@"line"] isKindOfClass:NSNumber.class]
        ? snapshot[@"line"] : snapshot[@"parser_line"];
    NSNumber *column = [snapshot[@"column"] isKindOfClass:NSNumber.class]
        ? snapshot[@"column"] : snapshot[@"parser_column"];
    NSString *description = [snapshot[@"error_description"]
        isKindOfClass:NSString.class] ? snapshot[@"error_description"] : @"";
    NSUInteger semanticErrors = [snapshot[@"semantic_error_count"] unsignedIntegerValue];
    if (semanticErrors) {
        NSString *identity = @"";
        if ([snapshot[@"property_type"] length]) {
            identity = [NSString stringWithFormat:@" property %@:%@",
                snapshot[@"property_name"] ?: @"?", snapshot[@"property_type"]];
        } else if ([snapshot[@"effect_id"] length]) {
            identity = [NSString stringWithFormat:@" effect %@", snapshot[@"effect_id"]];
        }
        return [NSString stringWithFormat:
            @"Scene \u8bed\u4e49\u9519\u8bef <%@> L%@:%@%@", element.length ? element : @"?",
            line ?: @0, column ?: @0, identity];
    }
    if (!parsed) {
        NSString *detail = amproj_compactNativeDiagnostic(description, 72);
        return [NSString stringWithFormat:
            @"XML <%@> L%@:%@%@%@", element.length ? element : @"?",
            line ?: @0, column ?: @0, detail.length ? @" · " : @"", detail];
    }
    return @"XML 语法已完成，未捕获到具体语义错误";
}

static Class amproj_declaredAppDelegateClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.AppDelegate");
    if (!cls) cls = objc_getClass("_TtC12AlightMotion11AppDelegate");
    return cls;
}

static BOOL amproj_installColdLaunchHook(void) {
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"cold_launch_hook");
        return NO;
    }
    Class cls = amproj_declaredAppDelegateClass();
    if (!cls) return NO;

    SEL willFinishSelector =
        @selector(application:willFinishLaunchingWithOptions:);
    BOOL willFinishAdded = NO;
    if (!class_getInstanceMethod(cls, willFinishSelector)) {
        struct objc_method_description description = protocol_getMethodDescription(
            @protocol(UIApplicationDelegate), willFinishSelector, NO, YES);
        const char *encoding = description.types ?: "B32@0:8@16@24";
        willFinishAdded = class_addMethod(
            cls, willFinishSelector, (IMP)hooked_applicationWillFinish, encoding);
    }
    BOOL willFinishChanged = NO;
    BOOL willFinishInstalled = amproj_installTrackedHook(
        cls, willFinishSelector, (IMP)hooked_applicationWillFinish, 4,
        amproj_willFinishHooks,
        sizeof(amproj_willFinishHooks) / sizeof(amproj_willFinishHooks[0]),
        &willFinishChanged);

    BOOL didFinishChanged = NO;
    BOOL didFinishInstalled = amproj_installTrackedHook(
        cls, @selector(application:didFinishLaunchingWithOptions:),
        (IMP)hooked_applicationDidFinish, 4, amproj_didFinishHooks,
        sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]),
        &didFinishChanged);
    BOOL configurationChanged = NO;
    BOOL configurationInstalled = amproj_installTrackedHook(
        cls, @selector(application:configurationForConnectingSceneSession:options:),
        (IMP)hooked_applicationConfigurationForConnecting, 5,
        amproj_configurationHooks,
        sizeof(amproj_configurationHooks) / sizeof(amproj_configurationHooks[0]),
        &configurationChanged);
    if (willFinishAdded || willFinishChanged || didFinishChanged ||
        configurationChanged) {
        amproj_debugEvent(@"import.cold_launch_hook", @{
            @"class": NSStringFromClass(cls) ?: @"",
            @"will_finish": @(willFinishInstalled),
            @"will_finish_added": @(willFinishAdded),
            @"did_finish": @(didFinishInstalled),
            @"scene_configuration": @(configurationInstalled)
        });
        NSLog(@"[AMProjExport] Cold-launch hooks willFinish=%@ didFinish=%@ sceneConfiguration=%@ on %@",
              willFinishInstalled ? @"installed" : @"failed",
              didFinishInstalled ? @"installed" : @"failed",
              configurationInstalled ? @"installed" : @"missing",
              NSStringFromClass(cls));
    }
    return willFinishInstalled && didFinishInstalled;
}

// Firebase and other SDKs may replace the concrete delegate with a proxy
// subclass after the image constructor runs.  Keep the declared AppDelegate
// hook above, but also hook that live proxy once UIApplication has a delegate.
// This is limited to the two launch selectors and uses the same tracked
// original table, so forwarding remains stable across repeated installs.
static BOOL amproj_installRuntimeColdLaunchHook(void) {
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"runtime_cold_launch_hook");
        return NO;
    }
    id delegate = UIApplication.sharedApplication.delegate;
    Class runtimeClass = delegate ? object_getClass(delegate) : Nil;
    Class declaredClass = amproj_declaredAppDelegateClass();
    if (!runtimeClass || runtimeClass == declaredClass) return NO;

    SEL willFinishSelector = @selector(application:willFinishLaunchingWithOptions:);
    SEL didFinishSelector = @selector(application:didFinishLaunchingWithOptions:);
    if (!class_getInstanceMethod(runtimeClass, willFinishSelector)) {
        struct objc_method_description description = protocol_getMethodDescription(
            @protocol(UIApplicationDelegate), willFinishSelector, NO, YES);
        class_addMethod(runtimeClass, willFinishSelector,
                        (IMP)hooked_applicationWillFinish,
                        description.types ?: "B32@0:8@16@24");
    }
    if (!class_getInstanceMethod(runtimeClass, didFinishSelector)) {
        struct objc_method_description description = protocol_getMethodDescription(
            @protocol(UIApplicationDelegate), didFinishSelector, NO, YES);
        class_addMethod(runtimeClass, didFinishSelector,
                        (IMP)hooked_applicationDidFinish,
                        description.types ?: "B32@0:8@16@24");
    }

    BOOL willChanged = NO;
    BOOL willInstalled = amproj_installTrackedHook(
        runtimeClass, willFinishSelector, (IMP)hooked_applicationWillFinish, 4,
        amproj_willFinishHooks,
        sizeof(amproj_willFinishHooks) / sizeof(amproj_willFinishHooks[0]),
        &willChanged);
    BOOL didChanged = NO;
    BOOL didInstalled = amproj_installTrackedHook(
        runtimeClass, didFinishSelector, (IMP)hooked_applicationDidFinish, 4,
        amproj_didFinishHooks,
        sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]),
        &didChanged);
    BOOL configurationChanged = NO;
    BOOL configurationInstalled = amproj_installTrackedHook(
        runtimeClass,
        @selector(application:configurationForConnectingSceneSession:options:),
        (IMP)hooked_applicationConfigurationForConnecting, 5,
        amproj_configurationHooks,
        sizeof(amproj_configurationHooks) / sizeof(amproj_configurationHooks[0]),
        &configurationChanged);
    amproj_logCriticalEvent(@"import.runtime_cold_launch_hook", @{
        @"class": NSStringFromClass(runtimeClass) ?: @"",
        @"will_finish": @(willInstalled),
        @"did_finish": @(didInstalled),
        @"scene_configuration": @(configurationInstalled),
        @"changed": @(willChanged || didChanged || configurationChanged)
    });
    return willInstalled || didInstalled || configurationInstalled;
}

static BOOL amproj_installDeclaredURLHooks(void) {
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"declared_url_hooks");
        return NO;
    }
    Class cls = amproj_declaredAppDelegateClass();
    if (!cls) return NO;

    SEL modernSelector = @selector(application:openURL:options:);
    SEL legacySelector = NSSelectorFromString(
        @"application:openURL:sourceApplication:annotation:");
    SEL handleSelector = NSSelectorFromString(@"application:handleOpenURL:");
    Method nativeModernMethod = amproj_ownInstanceMethod(cls, modernSelector);
    if (!amproj_nativeAppDelegateOpenURLIMP && nativeModernMethod) {
        IMP candidate = method_getImplementation(nativeModernMethod);
        if (candidate && candidate != (IMP)hooked_applicationOpenURL) {
            amproj_nativeAppDelegateOpenURLIMP = candidate;
            amproj_debugEvent(@"import.native_route_captured", @{
                @"class": NSStringFromClass(cls) ?: @"",
                @"selector": NSStringFromSelector(modernSelector)
            });
        }
    }
    if (!class_getInstanceMethod(cls, modernSelector) &&
        !class_getInstanceMethod(cls, legacySelector) &&
        !class_getInstanceMethod(cls, handleSelector)) {
        struct objc_method_description description = protocol_getMethodDescription(
            @protocol(UIApplicationDelegate), modernSelector, NO, YES);
        const char *encoding = description.types ?: "B40@0:8@16@24@32";
        BOOL added = class_addMethod(
            cls, modernSelector, (IMP)hooked_applicationOpenURL, encoding);
        amproj_debugEvent(@"import.declared_url_method", @{
            @"class": NSStringFromClass(cls) ?: @"",
            @"selector": NSStringFromSelector(modernSelector),
            @"added": @(added)
        });
    }

    BOOL modernChanged = NO;
    BOOL modernInstalled = amproj_installTrackedHook(
        cls, modernSelector, (IMP)hooked_applicationOpenURL, 5,
        amproj_openURLHooks,
        sizeof(amproj_openURLHooks) / sizeof(amproj_openURLHooks[0]),
        &modernChanged);
    BOOL handleChanged = NO;
    BOOL handleInstalled = amproj_installTrackedHook(
        cls, handleSelector, (IMP)hooked_applicationHandleOpenURL, 4,
        amproj_handleOpenURLHooks,
        sizeof(amproj_handleOpenURLHooks) / sizeof(amproj_handleOpenURLHooks[0]),
        &handleChanged);
    BOOL legacyChanged = NO;
    BOOL legacyInstalled = amproj_installTrackedHook(
        cls, legacySelector, (IMP)hooked_applicationLegacyOpenURL, 6,
        amproj_legacyOpenURLHooks,
        sizeof(amproj_legacyOpenURLHooks) / sizeof(amproj_legacyOpenURLHooks[0]),
        &legacyChanged);
    if (modernChanged || handleChanged || legacyChanged) {
        amproj_debugEvent(@"import.declared_hook", @{
            @"class": NSStringFromClass(cls) ?: @"",
            @"open_url": @(modernInstalled),
            @"handle_open_url": @(handleInstalled),
            @"legacy_open_url": @(legacyInstalled)
        });
    }
    return modernInstalled || handleInstalled || legacyInstalled;
}

static BOOL amproj_installPublic865AppDelegateHooksForClass(
    Class cls, BOOL runtimeDelegate) {
    if (!amproj_runtimeUsesPublic865ImportHooks() || !cls) return NO;

    SEL modernSelector = @selector(application:openURL:options:);
    Method nativeModernMethod = amproj_ownInstanceMethod(cls, modernSelector);
    if (!amproj_nativeAppDelegateOpenURLIMP && nativeModernMethod) {
        IMP candidate = method_getImplementation(nativeModernMethod);
        if (candidate && candidate != (IMP)hooked_applicationOpenURL) {
            amproj_nativeAppDelegateOpenURLIMP = candidate;
        }
    }

    BOOL willChanged = NO;
    BOOL willInstalled = amproj_installTrackedHook(
        cls, @selector(application:willFinishLaunchingWithOptions:),
        (IMP)hooked_applicationWillFinish, 4, amproj_willFinishHooks,
        sizeof(amproj_willFinishHooks) / sizeof(amproj_willFinishHooks[0]),
        &willChanged);
    BOOL didChanged = NO;
    BOOL didInstalled = amproj_installTrackedHook(
        cls, @selector(application:didFinishLaunchingWithOptions:),
        (IMP)hooked_applicationDidFinish, 4, amproj_didFinishHooks,
        sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]),
        &didChanged);
    BOOL configurationChanged = NO;
    BOOL configurationInstalled = amproj_installTrackedHook(
        cls, @selector(application:configurationForConnectingSceneSession:options:),
        (IMP)hooked_applicationConfigurationForConnecting, 5,
        amproj_configurationHooks,
        sizeof(amproj_configurationHooks) / sizeof(amproj_configurationHooks[0]),
        &configurationChanged);
    BOOL openChanged = NO;
    BOOL openInstalled = amproj_installTrackedHook(
        cls, modernSelector, (IMP)hooked_applicationOpenURL, 5,
        amproj_openURLHooks,
        sizeof(amproj_openURLHooks) / sizeof(amproj_openURLHooks[0]),
        &openChanged);
    BOOL activityChanged = NO;
    BOOL activityInstalled = amproj_installTrackedHook(
        cls, @selector(application:continueUserActivity:restorationHandler:),
        (IMP)hooked_applicationContinueActivity, 5,
        amproj_continueActivityHooks,
        sizeof(amproj_continueActivityHooks) /
            sizeof(amproj_continueActivityHooks[0]),
        &activityChanged);
    BOOL handleChanged = NO;
    BOOL handleInstalled = amproj_installTrackedHook(
        cls, NSSelectorFromString(@"application:handleOpenURL:"),
        (IMP)hooked_applicationHandleOpenURL, 4, amproj_handleOpenURLHooks,
        sizeof(amproj_handleOpenURLHooks) / sizeof(amproj_handleOpenURLHooks[0]),
        &handleChanged);
    BOOL legacyChanged = NO;
    BOOL legacyInstalled = amproj_installTrackedHook(
        cls, NSSelectorFromString(
                 @"application:openURL:sourceApplication:annotation:"),
        (IMP)hooked_applicationLegacyOpenURL, 6, amproj_legacyOpenURLHooks,
        sizeof(amproj_legacyOpenURLHooks) / sizeof(amproj_legacyOpenURLHooks[0]),
        &legacyChanged);

    amproj_logCriticalEvent(@"import.865_public_app_delegate_hooks", @{
        @"class": NSStringFromClass(cls) ?: @"",
        @"runtime_delegate": @(runtimeDelegate),
        @"will_finish": @(willInstalled),
        @"did_finish": @(didInstalled),
        @"scene_configuration": @(configurationInstalled),
        @"open_url": @(openInstalled),
        @"continue_activity": @(activityInstalled),
        @"handle_open_url": @(handleInstalled),
        @"legacy_open_url": @(legacyInstalled),
        @"changed": @(willChanged || didChanged || configurationChanged ||
                       openChanged || activityChanged || handleChanged ||
                       legacyChanged)
    });
    return willInstalled || didInstalled || configurationInstalled ||
        openInstalled || activityInstalled || handleInstalled || legacyInstalled;
}

static void amproj_installPublic865ApplicationDelegateHook(void) {
    if (!amproj_runtimeUsesPublic865ImportHooks()) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method method = class_getInstanceMethod(
            UIApplication.class, @selector(setDelegate:));
        IMP previous = amproj_installMethodHook(
            method, (IMP)hooked_applicationSetDelegate, 3,
            @"UIApplication.setDelegate.865_public");
        if (previous) {
            orig_applicationSetDelegate =
                (AMProjApplicationSetDelegateIMP)previous;
        }
    });
}

static void amproj_installPublic865ImportHooks(void) {
    if (!amproj_runtimeUsesPublic865ImportHooks()) return;
    amproj_installPublic865ApplicationDelegateHook();
    Class declaredClass = amproj_declaredAppDelegateClass();
    (void)amproj_installPublic865AppDelegateHooksForClass(
        declaredClass, NO);
    id<UIApplicationDelegate> runtimeDelegate =
        amproj_public865RuntimeDelegate;
    Class runtimeClass = runtimeDelegate ? object_getClass(runtimeDelegate) : Nil;
    if (runtimeClass && runtimeClass != declaredClass) {
        (void)amproj_installPublic865AppDelegateHooksForClass(
            runtimeClass, YES);
    }
    UIApplication *application = amproj_public865Application;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            amproj_installPublic865SceneHooksForClass([scene.delegate class]);
        }
    }
}

static void amproj_installProjectsImportAlertHook(void) {
    static dispatch_once_t onceToken;
    Class cls = NSClassFromString(@"AlightMotion.ProjectsImportAlert");
    if (!cls) cls = objc_getClass("_TtC12AlightMotion19ProjectsImportAlert");
    if (!cls) return;
    dispatch_once(&onceToken, ^{
        Method loaded = amproj_ownInstanceMethod(cls, @selector(viewDidLoad));
        Method pressed = amproj_ownInstanceMethod(
            cls, NSSelectorFromString(@"onPressImport:"));
        Method cancelled = amproj_ownInstanceMethod(
            cls, NSSelectorFromString(@"onPressCancel:"));
        SEL disappearedSelector = @selector(viewDidDisappear:);
        Method disappeared = amproj_ownInstanceMethod(cls, disappearedSelector);
        Method resolvedDisappeared = class_getInstanceMethod(cls, disappearedSelector);
        BOOL disappearedInstalled = NO;
        if (loaded) {
            IMP previous = amproj_installMethodHook(
                loaded, (IMP)hooked_projectsImportAlertViewDidLoad, 2,
                @"ProjectsImportAlert.viewDidLoad");
            if (previous) orig_projectsImportAlertViewDidLoad = (void *)previous;
        }
        if (pressed) {
            IMP previous = amproj_installMethodHook(
                pressed, (IMP)hooked_projectsImportAlertOnPressImport, 3,
                @"ProjectsImportAlert.onPressImport");
            if (previous) orig_projectsImportAlertOnPressImport = (void *)previous;
        }
        if (cancelled) {
            IMP previous = amproj_installMethodHook(
                cancelled, (IMP)hooked_projectsImportAlertOnPressCancel, 3,
                @"ProjectsImportAlert.onPressCancel");
            if (previous) orig_projectsImportAlertOnPressCancel = (void *)previous;
        }
        if (disappeared) {
            IMP previous = amproj_installMethodHook(
                disappeared, (IMP)hooked_projectsImportAlertViewDidDisappear, 3,
                @"ProjectsImportAlert.viewDidDisappear");
            if (previous) {
                orig_projectsImportAlertViewDidDisappear = (void *)previous;
                disappearedInstalled = YES;
            }
        } else if (resolvedDisappeared) {
            const char *encoding = method_getTypeEncoding(resolvedDisappeared);
            IMP inherited = method_getImplementation(resolvedDisappeared);
            if (encoding && inherited && class_addMethod(
                    cls, disappearedSelector,
                    (IMP)hooked_projectsImportAlertViewDidDisappear, encoding)) {
                orig_projectsImportAlertViewDidDisappear = (void *)inherited;
                disappearedInstalled = YES;
            }
        }
        amproj_debugEvent(@"import.native_alert_hook", @{
            @"class": cls ? NSStringFromClass(cls) : @"",
            @"view_loaded": @(orig_projectsImportAlertViewDidLoad != NULL),
            @"import_pressed": @(orig_projectsImportAlertOnPressImport != NULL),
            @"cancel_pressed": @(orig_projectsImportAlertOnPressCancel != NULL),
            @"view_disappeared": @(disappearedInstalled)
        });
    });
}

static void amproj_installPublic865SceneHooksForClass(Class cls) {
    if (!amproj_runtimeUsesPublic865ImportHooks() || !cls) return;
    BOOL willConnectChanged = NO;
    BOOL willConnectInstalled = amproj_installTrackedHook(
        cls, @selector(scene:willConnectToSession:options:),
        (IMP)hooked_sceneWillConnectToSession, 5,
        amproj_sceneWillConnectHooks,
        sizeof(amproj_sceneWillConnectHooks) /
            sizeof(amproj_sceneWillConnectHooks[0]),
        &willConnectChanged);
    BOOL openChanged = NO;
    BOOL openInstalled = amproj_installTrackedHook(
        cls, NSSelectorFromString(@"scene:openURLContexts:"),
        (IMP)hooked_sceneOpenURLContexts, 4, amproj_sceneOpenURLHooks,
        sizeof(amproj_sceneOpenURLHooks) / sizeof(amproj_sceneOpenURLHooks[0]),
        &openChanged);
    amproj_logCriticalEvent(@"import.865_public_scene_hooks", @{
        @"class": NSStringFromClass(cls) ?: @"",
        @"will_connect": @(willConnectInstalled),
        @"open_url_contexts": @(openInstalled),
        @"changed": @(willConnectChanged || openChanged)
    });
}

static void amproj_installSceneImportHook(id sceneDelegate) {
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        amproj_log865LegacyPathDisabled(@"scene_import_hook");
        return;
    }
    if (!sceneDelegate) return;
    Class cls = object_getClass(sceneDelegate);
    SEL willConnectSelector =
        @selector(scene:willConnectToSession:options:);
    BOOL willConnectChanged = NO;
    BOOL willConnectInstalled = amproj_installTrackedHook(
        cls, willConnectSelector, (IMP)hooked_sceneWillConnectToSession, 5,
        amproj_sceneWillConnectHooks,
        sizeof(amproj_sceneWillConnectHooks) /
            sizeof(amproj_sceneWillConnectHooks[0]),
        &willConnectChanged);
    SEL selector = NSSelectorFromString(@"scene:openURLContexts:");
    BOOL changed = NO;
    BOOL installed = amproj_installTrackedHook(
        cls, selector, (IMP)hooked_sceneOpenURLContexts, 4,
        amproj_sceneOpenURLHooks,
        sizeof(amproj_sceneOpenURLHooks) / sizeof(amproj_sceneOpenURLHooks[0]),
        &changed);
    if (willConnectChanged || changed) {
        amproj_debugEvent(@"import.scene_hook", @{
            @"will_connect_installed": @(willConnectInstalled),
            @"installed": @(installed),
            @"class": NSStringFromClass(cls) ?: @""
        });
    }
}

static void amproj_installNativeProjectPickerHook(void) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        amproj_log865LegacyPathDisabled(@"native_document_picker");
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class pickerClass = UIDocumentPickerViewController.class;
        SEL modernSelector =
            @selector(initForOpeningContentTypes:asCopy:);
        Method modernMethod =
            class_getInstanceMethod(pickerClass, modernSelector);
        IMP modernPrevious = amproj_installMethodHook(
            modernMethod, (IMP)hooked_documentPickerModernInit, 4,
            @"UIDocumentPicker.initForOpeningContentTypes");
        if (modernPrevious) {
            orig_documentPickerModernInit = (void *)modernPrevious;
        }

        SEL legacySelector = @selector(initWithDocumentTypes:inMode:);
        Method legacyMethod =
            class_getInstanceMethod(pickerClass, legacySelector);
        IMP legacyPrevious = amproj_installMethodHook(
            legacyMethod, (IMP)hooked_documentPickerLegacyInit, 4,
            @"UIDocumentPicker.initWithDocumentTypes");
        if (legacyPrevious) {
            orig_documentPickerLegacyInit = (void *)legacyPrevious;
        }

        amproj_logCriticalEvent(@"import.native_project_picker_hook", @{
            @"modern": @(orig_documentPickerModernInit != NULL),
            @"legacy": @(orig_documentPickerLegacyInit != NULL),
            @"added_type": AMProjUTI
        });
    });
}

static void amproj_installImportHook(void) {
    if (!amproj_runtimeUsesLocalImportEngine()) {
        // Builds without the local engine must keep Alight Motion's own
        // document and delegate lifecycle untouched.
        amproj_log865LegacyPathDisabled(@"import_hooks");
        return;
    }
    // The document picker hook is build independent: it only routes a picked
    // .amproj/.xml into the local engine and forwards every other selection.
    amproj_installNativeProjectPickerHook();
    if (!amproj_runtimeUsesLegacyImportHooks()) {
        // Build 865: launch and declared-URL delivery run through the public
        // AppDelegate/Scene hooks instead of the 862 swizzles above, and the
        // private native importer observation must stay off.
        amproj_debugEvent(@"import.engine_hooks_865_scope", @{
            @"picker_hook": @YES,
            @"cold_launch_swizzles": @NO,
            @"declared_url_swizzles": @NO
        });
        return;
    }
    (void)amproj_installColdLaunchHook();
    (void)amproj_installRuntimeColdLaunchHook();
    (void)amproj_installDeclaredURLHooks();
    // NSXMLParser is used by AM's Swift importer on the same main-thread
    // transaction. A process-wide parser swizzle can change delegate timing
    // and is therefore kept opt-in while diagnosing native imports.
#if defined(AMPROJ_ENABLE_NATIVE_XML_DIAGNOSTICS) && AMPROJ_ENABLE_NATIVE_XML_DIAGNOSTICS
    amproj_installNativeXMLParserHook();
#else
    amproj_debugEvent(@"import.native_xml_parser_hook", @{
        @"installed": @NO,
        @"reason": @"disabled_for_native_import_stability"
    });
#endif
    Class declaredClass = amproj_declaredAppDelegateClass();
    id delegate = UIApplication.sharedApplication.delegate;
    Class runtimeClass = delegate ? object_getClass(delegate) : Nil;
    Class classes[2] = {declaredClass, runtimeClass};

    for (NSUInteger index = 0; index < 2; index++) {
        Class cls = classes[index];
        if (!cls || (index == 1 && cls == classes[0])) continue;
        BOOL openChanged = NO;
        BOOL openInstalled = amproj_installTrackedHook(
            cls, @selector(application:openURL:options:),
            (IMP)hooked_applicationOpenURL, 5, amproj_openURLHooks,
            sizeof(amproj_openURLHooks) / sizeof(amproj_openURLHooks[0]),
            &openChanged);
        BOOL activityChanged = NO;
        BOOL activityInstalled = amproj_installTrackedHook(
            cls, @selector(application:continueUserActivity:restorationHandler:),
            (IMP)hooked_applicationContinueActivity, 5, amproj_continueActivityHooks,
            sizeof(amproj_continueActivityHooks) /
                sizeof(amproj_continueActivityHooks[0]),
            &activityChanged);
        BOOL handleChanged = NO;
        BOOL handleInstalled = amproj_installTrackedHook(
            cls, NSSelectorFromString(@"application:handleOpenURL:"),
            (IMP)hooked_applicationHandleOpenURL, 4, amproj_handleOpenURLHooks,
            sizeof(amproj_handleOpenURLHooks) / sizeof(amproj_handleOpenURLHooks[0]),
            &handleChanged);
        BOOL legacyChanged = NO;
        BOOL legacyInstalled = amproj_installTrackedHook(
            cls, NSSelectorFromString(
                     @"application:openURL:sourceApplication:annotation:"),
            (IMP)hooked_applicationLegacyOpenURL, 6, amproj_legacyOpenURLHooks,
            sizeof(amproj_legacyOpenURLHooks) / sizeof(amproj_legacyOpenURLHooks[0]),
            &legacyChanged);
        if (openChanged || activityChanged || handleChanged || legacyChanged) {
            amproj_debugEvent(@"import.hook", @{
                @"class": NSStringFromClass(cls) ?: @"",
                @"runtime_delegate": @(cls == runtimeClass),
                @"open_url": @(openInstalled),
                @"continue_activity": @(activityInstalled),
                @"handle_open_url": @(handleInstalled),
                @"legacy_open_url": @(legacyInstalled)
            });
        }
        amproj_logCriticalEvent(@"import.hook_state", @{
            @"class": NSStringFromClass(cls) ?: @"",
            @"runtime_delegate": @(cls == runtimeClass),
            @"open_url": @(openInstalled),
            @"continue_activity": @(activityInstalled),
            @"handle_open_url": @(handleInstalled),
            @"legacy_open_url": @(legacyInstalled)
        });
    }

    // The legacy ProjectsImportAlert path is intentionally not installed.
    // Direct PackageImporter completion is the only source of queue progress;
    // unrelated AM alerts must never resume or duplicate a transaction.
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            amproj_installSceneImportHook(scene.delegate);
        }
    }
}

static void amproj_installShareExportHook(void) {
    static BOOL installed = NO;
    static NSObject *lock = nil;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{ lock = [NSObject new]; });

    @synchronized (lock) {
        if (installed) return;
        Class shareClass = NSClassFromString(@"AlightMotion.ShareNC");
        if (!shareClass) shareClass = objc_getClass("_TtC12AlightMotion7ShareNC");
        SEL selector = NSSelectorFromString(@"onTapExport:");
        Method method = class_getInstanceMethod(shareClass, selector);
        if (!method) {
            amproj_logCriticalEvent(@"share_export.hook", @{
                @"installed": @NO,
                @"class": shareClass ? NSStringFromClass(shareClass) : @"",
                @"reason": shareClass ? @"selector_missing" : @"class_missing"
            });
            return;
        }

        IMP previous = amproj_installMethodHook(
            method, (IMP)hooked_shareNCOnTapExport, 3,
            @"ShareNC.onTapExport");
        if (previous) {
            orig_shareNCOnTapExport = (void *)previous;
            installed = YES;
        } else if (method_getImplementation(method) ==
                   (IMP)hooked_shareNCOnTapExport) {
            installed = orig_shareNCOnTapExport != NULL;
        }
        amproj_logCriticalEvent(@"share_export.hook", @{
            @"installed": @(installed),
            @"class": NSStringFromClass(shareClass) ?: @""
        });
    }
}

#if AMPROJ_DEBUG
static Class amproj_findPackageControllerClass(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class __unsafe_unretained *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return Nil;
    count = objc_getClassList(classes, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"ShareProjectPackageVC"] &&
            [classes[i] isSubclassOfClass:[UIViewController class]]) {
            found = classes[i];
            break;
        }
    }
    free(classes);
    return found;
}
#endif

static void amproj_installNavigationExportHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @try {
            Method method = class_getInstanceMethod(
                [UINavigationController class],
                @selector(pushViewController:animated:));
            if (!method) return;
            IMP previous = amproj_installMethodHook(
                method, (IMP)hooked_navigationPush, 4,
                @"UINavigationController.pushViewController");
            if (previous) {
                orig_navigationPush = (void *)previous;
                amproj_logCriticalEvent(@"share_export.navigation_hook", @{
                    @"installed": @YES
                });
            }
        } @catch (NSException *exception) {
            amproj_logCriticalEvent(@"share_export.navigation_hook", @{
                @"installed": @NO,
                @"name": exception.name ?: @"NSException",
                @"reason": exception.reason ?: @""
            });
        }
    });
}

static void amproj_installPresentationHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[AMProjExport] Installing presentation filter");
        @try {
            Method method = class_getInstanceMethod(
                [UIViewController class],
                @selector(presentViewController:animated:completion:));
            if (method) {
                IMP previous = amproj_installMethodHook(
                    method, (IMP)hooked_presentVC, 5, @"UIViewController.present");
                if (previous) {
                    orig_presentVC = (void *)previous;
                    NSLog(@"[AMProjExport] Hooked UIViewController.presentViewController");
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[AMProjExport] Presentation hook failed: %@", exception);
        }
    });
}

static void amproj_installExportHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[AMProjExport] Installing export hooks after app launch");
        amproj_installPresentationHook();
        if (amproj_runtimeIsBuild865()) {
            // Keep only the public presentation hook and the navigation
            // semantic boundary above. The latter handles the exact 865
            // project-package controller; it does not inspect private ShareVC
            // state or intercept unrelated navigation.
            amproj_installNavigationExportHook();
            amproj_logCriticalEvent(@"export_hooks.865_project_boundary", @{
                @"presentation": @YES,
                @"navigation": @"project_package_boundary_and_account_replacement",
                @"legacy_share_hooks": @NO
            });
            return;
        }
        if (!amproj_runtimeUsesLegacyImportHooks()) {
            // Keep only the presentation hook for the account replacement on
            // non-legacy builds.
            // ShareNC, navigation and UIActivity interception all depend on
            // the older 6.2.55 project-export UI and are unsafe elsewhere.
            amproj_log865LegacyPathDisabled(@"export_hooks");
            return;
        }
        amproj_installNavigationExportHook();
        amproj_installShareExportHook();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_installShareExportHook();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            amproj_installShareExportHook();
        });

        @try {
            Method method = class_getInstanceMethod(
                [UIActivityViewController class],
                @selector(initWithActivityItems:applicationActivities:));
            if (method) {
                IMP previous = amproj_installMethodHook(
                    method, (IMP)hooked_initWithItems, 4, @"UIActivityViewController.init");
                if (previous) {
                    orig_initWithItems = (void *)previous;
                    NSLog(@"[AMProjExport] Hooked UIActivityViewController.init");
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[AMProjExport] Activity hook failed: %@", exception);
        }

#if AMPROJ_DEBUG
        @try {
            Method appeared = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
            Method disappeared = class_getInstanceMethod([UIViewController class], @selector(viewDidDisappear:));
            Method progressAnimated = class_getInstanceMethod([UIProgressView class], @selector(setProgress:animated:));
            Method progress = class_getInstanceMethod([UIProgressView class], @selector(setProgress:));
            Method labelText = class_getInstanceMethod([UILabel class], @selector(setText:));
            Method dataTask = class_getInstanceMethod(
                [NSURLSession class], @selector(dataTaskWithRequest:completionHandler:));

            if (appeared) {
                IMP previous = amproj_installMethodHook(
                    appeared, (IMP)hooked_viewDidAppear, 3, @"UIViewController.viewDidAppear");
                if (previous) orig_viewDidAppear = (void *)previous;
            }
            if (disappeared) {
                IMP previous = amproj_installMethodHook(
                    disappeared, (IMP)hooked_viewDidDisappear, 3, @"UIViewController.viewDidDisappear");
                if (previous) orig_viewDidDisappear = (void *)previous;
            }
            if (progressAnimated) {
                IMP previous = amproj_installMethodHook(
                    progressAnimated, (IMP)hooked_setProgressAnimated, 4, @"UIProgressView.setProgressAnimated");
                if (previous) orig_setProgressAnimated = (void *)previous;
            }
            if (progress) {
                IMP previous = amproj_installMethodHook(
                    progress, (IMP)hooked_setProgress, 3, @"UIProgressView.setProgress");
                if (previous) orig_setProgress = (void *)previous;
            }
            if (labelText) {
                IMP previous = amproj_installMethodHook(
                    labelText, (IMP)hooked_labelSetText, 3, @"UILabel.setText");
                if (previous) orig_labelSetText = (void *)previous;
            }
            if (dataTask) {
                IMP previous = amproj_installMethodHook(
                    dataTask, (IMP)hooked_dataTaskWithRequest, 4, @"NSURLSession.dataTaskWithRequest");
                if (previous) orig_dataTaskWithRequest = (void *)previous;
            }

            Class packageClass = amproj_findPackageControllerClass();
            Method packageAppeared = amproj_ownInstanceMethod(packageClass, @selector(viewDidAppear:));
            Method packageDisappeared = amproj_ownInstanceMethod(packageClass, @selector(viewDidDisappear:));
            if (packageAppeared) {
                IMP previous = amproj_installMethodHook(
                    packageAppeared, (IMP)hooked_packageViewDidAppear, 3,
                    @"ShareProjectPackageVC.viewDidAppear");
                if (previous) orig_packageViewDidAppear = (void *)previous;
            }
            if (packageDisappeared) {
                IMP previous = amproj_installMethodHook(
                    packageDisappeared, (IMP)hooked_packageViewDidDisappear, 3,
                    @"ShareProjectPackageVC.viewDidDisappear");
                if (previous) orig_packageViewDidDisappear = (void *)previous;
            }
            amproj_debugEvent(@"hooks.installed", @{
                @"view_lifecycle": @(appeared != NULL && disappeared != NULL),
                @"package_class": packageClass ? NSStringFromClass(packageClass) : @"",
                @"package_override": @(packageAppeared != NULL || packageDisappeared != NULL),
                @"progress": @(progressAnimated != NULL || progress != NULL),
                @"label": @(labelText != NULL),
                @"network": @(dataTask != NULL)
            });
        } @catch (NSException *exception) {
            NSLog(@"[AMProjExport] Debug hook failed: %@", exception);
            amproj_debugEvent(@"hooks.error", @{@"error": exception.reason ?: @""});
        }

        amproj_startHeartbeat();
#endif

        NSLog(@"[AMProjExport] ===== Ready — waiting for package export =====");
    });
}

static void amproj_removeBootstrapObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    id willLaunch = amproj_willLaunchObserver;
    id didLaunch = amproj_didLaunchObserver;
    amproj_willLaunchObserver = nil;
    amproj_didLaunchObserver = nil;
    if (willLaunch) [center removeObserver:willLaunch];
    if (didLaunch) [center removeObserver:didLaunch];
}

static void amproj_bootstrapAfterLaunch(NSString *trigger) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        amproj_removeBootstrapObservers();

#if AMPROJ_DEBUG
        if (amproj_mainThread == MACH_PORT_NULL) amproj_mainThread = mach_thread_self();
#endif
        amproj_installPresentationHook();
        if (amproj_runtimeIsBuild865()) {
            AMProjV865ProjectFlowInstall();
            amproj_install865ShareTapHook();
        }
        amproj_armPaywallStartupFallback();
        amproj_startStartupPaywallRescue();
        amproj_installPublic865ImportHooks();
        amproj_installImportHook();
        AMProjRegisterNativePackageImportEventHandler(
            ^(NSString *event, NSDictionary<NSString *, id> *fields) {
                NSMutableDictionary *enriched = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
                if (![enriched[@"transaction_id"] isKindOfClass:NSString.class] ||
                    ![enriched[@"transaction_id"] length]) {
                    NSString *transactionID = amproj_pendingImportTransactionID.length
                        ? amproj_pendingImportTransactionID
                        : (amproj_activeNativeImportTransactionID.length
                            ? amproj_activeNativeImportTransactionID
                            : amproj_importVerificationTransactionID);
                    if (transactionID.length) enriched[@"transaction_id"] = transactionID;
                }
                NSString *transactionID = [enriched[@"transaction_id"]
                    isKindOfClass:NSString.class] ? enriched[@"transaction_id"] : nil;
                if ([event isEqualToString:@"storage_write_start"] && transactionID.length) {
                    NSString *destination = [enriched[@"destination_path"]
                        isKindOfClass:NSString.class] ? enriched[@"destination_path"] : nil;
                    if (destination.length) {
                        @synchronized (amproj_importDedupeLock()) {
                            AMProjImportTransaction *transaction =
                                amproj_importTransactions[transactionID];
                            transaction.nativeTemporaryPath = [destination copy];
                        }
                    }
                }
                amproj_writeNativeEventBreadcrumb(transactionID, event, enriched);
                amproj_debugEvent(event, enriched);
                if ([event isEqualToString:@"storage_status_4"] &&
                    transactionID.length) {
                    AMProjImportTransaction *transaction =
                        amproj_importTransactionForID(transactionID);
                    if (transaction && [enriched[@"success"] boolValue]) {
                        transaction.nativeTerminalStatus4Observed = YES;
                    }
                }
                if ([event isEqualToString:@"storage_status_4_returned"] &&
                    transactionID.length) {
                    AMProjImportTransaction *transaction =
                        amproj_importTransactionForID(transactionID);
                    if (transaction && [enriched[@"success"] boolValue]) {
                        transaction.nativeTerminalStatus4Returned = YES;
                    }
                    if (transaction.kind == AMProjImportKindPackage) {
                        amproj_scheduleImportPersistenceProbe(
                            transactionID, @"storage_status_4", nil);
                    } else {
                        amproj_debugEvent(@"import.xml_persistence_probe_skipped", @{
                            @"transaction_id": transactionID,
                            @"reason": @"xml_success_requires_native_and_ui_evidence"
                        });
                    }
                }
                if ([event isEqualToString:@"native_completion"] &&
                    transactionID.length) {
                    AMProjImportTransaction *transaction =
                        amproj_importTransactionForID(transactionID);
                    if (transaction && [enriched[@"success"] boolValue]) {
                        transaction.nativeCompletionSucceeded = YES;
                    }
                    amproj_debugEvent(@"native_callback_received", @{
                        @"transaction_id": transactionID,
                        @"success": enriched[@"success"] ?: @NO,
                        @"generation": enriched[@"generation"] ?: @0
                    });
                }
            });
        // The private PackageImporter adapter belongs solely to the verified
        // 6.2.55/862 lane. Build 865 delegates project documents to AM itself.
        if (amproj_runtimeUsesLegacyImportHooks()) {
            AMProjInstallNativePackageImportBridge();
        } else {
            amproj_log865LegacyPathDisabled(@"native_package_bridge");
            AMProjRegisterNativePackageImportStarter(nil);
        }
#if AMPROJ_CLOUD_SYNC
        // Cloud project handoff has two different ABI/queue contracts. Build
        // 865 must stage asynchronously before entering UIKit; the verified
        // 862 bridge is a synchronous BOOL handler. Register exactly one lane
        // for the current bundle and clear both handlers for unknown builds.
        if (amproj_runtimeIsBuild865()) {
            AMCloudSyncInstallAsync(^(NSURL *URL, NSString *filename,
                                     NSURL *cleanupURL,
                                     AMCloudImportCompletion completion) {
                amproj_importCloudPackage(URL, filename, cleanupURL, completion);
            });
        } else if (amproj_runtimeUsesLegacyImportHooks()) {
            AMCloudSyncInstall(^(NSURL *URL, NSString *filename,
                                 NSURL *cleanupURL) {
                __block BOOL accepted = NO;
                amproj_importCloudPackage(URL, filename, cleanupURL,
                    ^(BOOL staged, NSError *error) {
                        (void)error;
                        accepted = staged;
                    });
                return accepted;
            });
        } else {
            amproj_log865LegacyPathDisabled(@"cloud_import_handler");
            AMCloudSyncInstall(nil);
        }
#endif

        NSString *startupTrigger = [trigger copy] ?: @"unknown";
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary *previousBreadcrumb = amproj_readImportBreadcrumb();
            if (previousBreadcrumb.count) {
                amproj_debugEvent(@"import.previous_breadcrumb", previousBreadcrumb);
                NSLog(@"[AMProjExport] Previous import phase=%@ transaction=%@ error=%@",
                      previousBreadcrumb[@"phase"] ?: @"",
                      previousBreadcrumb[@"transaction_id"] ?: @"",
                      previousBreadcrumb[@"error"] ?: @"");
                NSString *phase = [previousBreadcrumb[@"phase"]
                    isKindOfClass:NSString.class] ? previousBreadcrumb[@"phase"] : @"";
                NSString *interruptedStage =
                    amproj_nativeBreadcrumbDisplayStage(previousBreadcrumb);
                if (phase.length && ![phase isEqualToString:@"completed"] &&
                    ![phase isEqualToString:@"failed"]) {
                    amproj_showImportStatus([NSString stringWithFormat:
                        @"AMProj · 上次导入在 %@ 阶段中断，原项目包已保留，可重新打开重试",
                        interruptedStage], YES);
                }
            }
            if (amproj_runtimeUsesLocalImportEngine()) {
                amproj_purgeOldDirectExports();
                amproj_purgeOldImports();
                if (!amproj_hasDeferredLaunchImportCandidates()) {
                    amproj_scanLocalImportInboxes(@"bootstrap", nil);
                } else {
                    amproj_debugEvent(@"import.scan_deferred_priority", @{
                        @"reason": @"launch_candidate_pending"
                    });
                }
            } else {
                amproj_log865LegacyPathDisabled(@"bootstrap_import_scan");
            }
#if AMPROJ_DEBUG || AMPROJ_TELEMETRY
            [[AMDebugTransport shared] start];
            NSDictionary *bundleInfo = NSBundle.mainBundle.infoDictionary ?: @{};
            NSString *bundleVersion = [bundleInfo[@"CFBundleVersion"]
                isKindOfClass:NSString.class] ? bundleInfo[@"CFBundleVersion"] : @"";
            amproj_debugEvent(@"bootstrap.ready", @{
                @"trigger": startupTrigger,
                @"bundle_version": bundleVersion,
                @"supports_opening_documents_in_place":
                    @([bundleInfo[@"LSSupportsOpeningDocumentsInPlace"] boolValue]),
                @"supports_document_browser":
                    @([bundleInfo[@"UISupportsDocumentBrowser"] boolValue])
            });
#endif
            amproj_installExportHooks();
            amproj_schedulePaywallScan(nil, @"bootstrap");
        });
    });
}

// Escaping modals report their presented-chain class names to a file in the
// app's Documents directory; the syslog redacts dictionary values, so this
// file is the only way to read real class names back on Windows. Lines
// carry the defense round so a stale install is provable on device.
static void amproj_exportPresentedChainDiagnostics(
    NSArray<NSString *> *classes) {
    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs.length) return;
        NSString *path = [docs stringByAppendingPathComponent:
            @"amproj_chain.txt"];
        NSString *line = [NSString stringWithFormat:@"%@ r19 | %@\n",
            [NSDate date], [classes componentsJoinedByString:@" | "]];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } else {
            [line writeToFile:path
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
        }
    } @catch (__unused NSException *exception) {
    }
}

static BOOL AMProjNoopBoolIMP(__unused id self, __unused SEL _cmd) {
    return YES;
}

static void AMProjNoopVoidIMP(id self, SEL _cmd);

// MARK: - StoreKit request suppression

// Premium is flag-driven in this repack; nothing legitimately needs the
// App Store. The paywall's product fetch is what raised the "登录 Apple
// 账户" dialog, so StoreKit requests are no-ops during the startup window.
static CFAbsoluteTime amproj_storeKitSuppressUntil = 0;

static void AMProjStoreKitStartFail(SKRequest *self, SEL _cmd) {
    // Fail every StoreKit request asynchronously through the standard
    // delegate path: requesters observe a clean failure and stop waiting,
    // instead of spinning forever or raising the App Store sign-in dialog.
    dispatch_async(dispatch_get_main_queue(), ^{
        id delegate = [(id)self delegate];
        if (![delegate respondsToSelector:@selector(request:didFailWithError:)]) {
            return;
        }
        [(id)delegate request:self
            didFailWithError:[NSError errorWithDomain:@"AMProjStoreKitSuppressed"
                                                 code:1
                                             userInfo:nil]];
    });
}

static void amproj_installStoreKitSuppressor(void) {
    @try {
        Class cls = NSClassFromString(@"SKRequest");
        if (!cls) return;
        // Hook -start on the BASE class so every subclass (products,
        // receipt refresh, payment) routes through the same fail-fast path.
        Method method = class_getInstanceMethod(cls,
            NSSelectorFromString(@"start"));
        if (method) {
            method_setImplementation(method, (IMP)AMProjStoreKitStartFail);
        }
        NSLog(@"[AMProjExport] storekit fail-fast installed");
    } @catch (__unused NSException *exception) {
    }
}

// MARK: - Funnel haptic suppression

// The welcome/gate pages live inside the injected license module (the only
// UI-capable crack dylib) and buzz the haptic generators while their hidden
// lifecycle runs. During the funnel window the fire methods of the system
// feedback generators are no-ops; editor haptics after the window are
// untouched.
static CFAbsoluteTime amproj_hapticSuppressUntil = 0;

static void amproj_extendHapticSuppression(void) {
    CFAbsoluteTime target = CFAbsoluteTimeGetCurrent() + 10.0;
    CFAbsoluteTime cap = CFAbsoluteTimeGetCurrent() + 90.0;
    if (target > amproj_hapticSuppressUntil) amproj_hapticSuppressUntil = target;
    if (amproj_hapticSuppressUntil > cap) amproj_hapticSuppressUntil = cap;
}

static void amproj_installFunnelHapticSuppressor(void) {
    @try {
        NSDictionary<NSString *, NSArray<NSString *> *> *targets = @{
            @"UIImpactFeedbackGenerator":
                @[@"impactOccurred", @"impactOccurredWithIntensity:"],
            @"UINotificationFeedbackGenerator":
                @[@"notificationOccurred:"],
            @"UISelectionFeedbackGenerator": @[@"selectionChanged"],
        };
        for (NSString *className in targets) {
            Class cls = NSClassFromString(className);
            if (!cls) continue;
            for (NSString *selName in targets[className]) {
                SEL sel = NSSelectorFromString(selName);
                Method method = class_getInstanceMethod(cls, sel);
                if (method) {
                    method_setImplementation(method,
                        (IMP)AMProjNoopVoidIMP);
                }
            }
        }
        Class engineClass = NSClassFromString(@"CHHapticEngine");
        if (engineClass) {
            for (NSString *selName in @[@"start", @"startWithCompletionHandler:"]) {
                SEL sel = NSSelectorFromString(selName);
                Method method = class_getInstanceMethod(engineClass, sel);
                if (method) {
                    method_setImplementation(method,
                        (IMP)AMProjNoopBoolIMP);
                }
            }
        }
        NSLog(@"[AMProjExport] funnel haptic suppressor installed");
    } @catch (__unused NSException *exception) {
    }
}

// MARK: - Third-party crack welcome suppression (Blatant)

// The system rating prompt opens on its own session milestone. Every
// requestReview entry point on SKStoreReviewController is replaced with a
// no-op so no variant of the prompt - legacy class method, instance method,
// or the SwiftUI bridge - can appear. requestReview returns void, so a
// plain no-op IMP is signature-safe for all arities on arm64.
static void AMProjNoopVoidIMP(__unused id self, __unused SEL _cmd) {}

static void amproj_installRatingPromptSuppressor(void) {
    @try {
        Class cls = NSClassFromString(@"SKStoreReviewController");
        if (!cls) return;
        Class meta = object_getClass(cls);
        for (Class level in @[meta, cls]) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(level, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *sel = sel_getName(method_getName(methods[i]));
                if (strstr(sel, "requestReview")) {
                    method_setImplementation(methods[i],
                                             (IMP)AMProjNoopVoidIMP);
                    NSLog(@"[AMProjExport] rating prompt blocked: %s%s",
                          level == meta ? "+" : "-", sel);
                }
            }
            free(methods);
        }
    } @catch (__unused NSException *exception) {
    }
}

// The Blatant crack welcome page is not built by blatantroll/blatantsPatch.
// Static analysis of this package located the actual builder: the injected
// Frameworks/AlightMotion.dylib license module (BBAES-encrypted strings,
// bb_handlePopupButtonPress:, and a UIWindow at _UIWindowLevelAlert). It
// decrypts its controller and strings at runtime, so the class cannot be
// matched by name statically. class_getImageName survives encryption: any
// UIViewController class defined inside that image belongs to the crack,
// and its presentation or window takeover is suppressed before it can draw
// a single frame. The injected dylib is distinguished from the main
// executable (both named "AlightMotion") by the ".dylib" suffix. The match
// is done on the C string directly: this walks every view and layer of
// every window, so per-class NSString allocations are unaffordable.
static BOOL AMProjClassIsFromCrackDylib(Class cls) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        const char *imageName = class_getImageName(current);
        if (!imageName) continue;
        const char *base = strrchr(imageName, '/');
        base = base ? base + 1 : imageName;
        if (strncasecmp(base, "blatantroll", 11) == 0) return YES;
        if (strncasecmp(base, "blatantspatch", 13) == 0) return YES;
        if (strcasecmp(base, "alightmotion.dylib") == 0) return YES;
    }
    return NO;
}

// The crack may wrap its controller in a stock UINavigationController, so
// the presentation target itself can carry a UIKit image name. Walk the
// child chain (bounded) before allowing a presentation through.
static BOOL AMProjPresentationChainHasCrackController(
    UIViewController *controller) {
    UIViewController *current = controller;
    for (NSUInteger depth = 0; current && depth < 8; depth++) {
        if (AMProjClassIsFromCrackDylib(current.class)) return YES;
        if ([current isKindOfClass:UINavigationController.class]) {
            for (UIViewController *child in
                     ((UINavigationController *)current).viewControllers) {
                if (AMProjClassIsFromCrackDylib(child.class)) return YES;
            }
        }
        current = current.presentedViewController;
    }
    return NO;
}

// Views constructed by crack classes are instances of their own UIView/CALayer
// subclasses, so a window can be fingerprinted without reading any text. This
// covers pages whose labels are encrypted, drawn, or hosted in a web view.
static BOOL AMProjViewHierarchyHasCrackClass(UIView *view, NSUInteger depth) {
    if (!view || depth > 24) return NO;
    if (AMProjClassIsFromCrackDylib(view.class)) return YES;
    if (view.layer && AMProjClassIsFromCrackDylib(view.layer.class)) return YES;
    for (UIView *subview in view.subviews) {
        if (AMProjViewHierarchyHasCrackClass(subview, depth + 1)) return YES;
    }
    return NO;
}

static void (*orig_UIWindowMakeKeyAndVisible)(id, SEL) = NULL;
static void hooked_UIWindowMakeKeyAndVisible(id self, SEL _cmd) {
    UIWindow *window = (UIWindow *)self;
    // The gate never stays on screen: a bounded number of native cycles let
    // the crack wire its own controls, then the window is hidden again inside
    // the same runloop turn (no rendered frame) while its continue control
    // fires. Everything else is denied and the app window keeps key status.
    if (amproj_windowCarriesCrackGate(window)) {
        if (amproj_gateCycleBegin(window)) {
            amproj_extendHapticSuppression();
        amproj_logCriticalEvent(@"startup.crack_welcome_suppressed", @{
                @"via": @"makeKeyAndVisible",
                @"class": NSStringFromClass(
                    window.rootViewController.class) ?: @""
            });
            orig_UIWindowMakeKeyAndVisible(self, _cmd);
            amproj_gateCycleEnd(window, @"makeKeyAndVisible");
        } else {
            // Budget spent: never let the gate linger on screen either.
            if (!window.hidden && window.windowLevel > UIWindowLevelNormal) {
                window.hidden = YES;
            }
            amproj_ensureApplicationKeyWindow();
        }
        return;
    }
    orig_UIWindowMakeKeyAndVisible(self, _cmd);
}

static void (*orig_UIWindowSetRootViewController)(id, SEL, UIViewController *) = NULL;
static void hooked_UIWindowSetRootViewController(id self, SEL _cmd,
                                                 UIViewController *controller) {
    UIWindow *window = (UIWindow *)self;
    if (controller &&
        (AMProjPresentationChainHasCrackController(controller) ||
         AMProjClassIsFromCrackDylib(controller.class))) {
        // Let the gate root attach during a bounded native cycle so its
        // controls are wired, then hide the window inside the same runloop
        // turn. Alight Motion's own window (normal level) never hosts a crack
        // root: skipping the swap keeps its previous controller.
        if (amproj_gateCycleBegin(window)) {
            amproj_extendHapticSuppression();
        amproj_logCriticalEvent(@"startup.crack_welcome_suppressed", @{
                @"via": @"setRootViewController",
                @"class": NSStringFromClass(controller.class) ?: @""
            });
            orig_UIWindowSetRootViewController(self, _cmd, controller);
            amproj_gateCycleEnd(window, @"setRootViewController");
        } else {
            if (!window.hidden && window.windowLevel > UIWindowLevelNormal) {
                window.hidden = YES;
            }
            amproj_ensureApplicationKeyWindow();
        }
        return;
    }
    orig_UIWindowSetRootViewController(self, _cmd, controller);
}

static void (*orig_UIWindowSetHidden)(id, SEL, BOOL) = NULL;
static void hooked_UIWindowSetHidden(id self, SEL _cmd, BOOL hidden) {
    // Every reveal path for a gate window runs through the bounded cycle:
    // the window shows exactly long enough for the crack to wire its
    // controls (the hide lands before Core Animation commits), then it is
    // never shown again.
    if (!hidden) {
        UIWindow *window = (UIWindow *)self;
        if (amproj_windowCarriesCrackGate(window)) {
            if (amproj_gateCycleBegin(window)) {
                amproj_extendHapticSuppression();
        amproj_logCriticalEvent(@"startup.crack_welcome_suppressed", @{
                    @"via": @"setHidden",
                    @"class": NSStringFromClass(
                        window.rootViewController.class) ?: @""
                });
                orig_UIWindowSetHidden(self, _cmd, hidden);
                amproj_gateCycleEnd(window, @"setHidden");
            } else {
                if (!window.hidden && window.windowLevel > UIWindowLevelNormal) {
                    window.hidden = YES;
                }
                amproj_ensureApplicationKeyWindow();
            }
            return;
        }
    }
    orig_UIWindowSetHidden(self, _cmd, hidden);
}

static void amproj_installCrackWelcomeSuppressors(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!amproj_gateDefenseActive) return;
        if (!amproj_runtimeIsBuild865()) return;
        Method makeKeyMethod = class_getInstanceMethod(UIWindow.class,
            NSSelectorFromString(@"makeKeyAndVisible"));
        if (makeKeyMethod) {
            orig_UIWindowMakeKeyAndVisible = (void (*)(id, SEL))method_setImplementation(
                makeKeyMethod, (IMP)hooked_UIWindowMakeKeyAndVisible);
        }
        Method rootMethod = class_getInstanceMethod(UIWindow.class,
            NSSelectorFromString(@"setRootViewController:"));
        if (rootMethod) {
            orig_UIWindowSetRootViewController = (void (*)(id, SEL, UIViewController *))
                method_setImplementation(rootMethod,
                    (IMP)hooked_UIWindowSetRootViewController);
        }
        Method hiddenMethod = class_getInstanceMethod(UIWindow.class,
            NSSelectorFromString(@"setHidden:"));
        if (hiddenMethod) {
            orig_UIWindowSetHidden = (void (*)(id, SEL, BOOL))
                method_setImplementation(hiddenMethod,
                    (IMP)hooked_UIWindowSetHidden);
        }
        NSLog(@"[AMProjExport] crack welcome suppressors installed");
    });
}

__attribute__((constructor))
static void AMProjExportInit(void) {
    @autoreleasepool {
        // The repack's own crack module already auto-skips the intro flow
        // and its subscription step (handleIntroFlowHook* in the main
        // binary) - that is why the stock package never showed a wall.
        // Seeding onboarding flags or blocking those presentations fights
        // that hook and deadlocks the launch (r11: endless spinner plus a
        // vibration loop). The flags seeded by earlier rounds are removed
        // here so the crack's own state machine runs exactly as shipped.
        // Earlier rounds seeded YES into these flags; restore their
        // pristine (absent) state exactly once, then never touch them again
        // so writes from the crack module or the app always persist.
        if (![[NSUserDefaults standardUserDefaults]
                boolForKey:@"amproj_onboarding_flags_restored_r15"]) {
            [[NSUserDefaults standardUserDefaults]
                removeObjectForKey:@"hasOnboardingFlowBeenCompleted"];
            [[NSUserDefaults standardUserDefaults]
                removeObjectForKey:@"hasSkippedIntro"];
            [[NSUserDefaults standardUserDefaults]
                setBool:YES forKey:@"amproj_onboarding_flags_restored_r15"];
        }
        amproj_installRatingPromptSuppressor();
        amproj_installFunnelHapticSuppressor();
        amproj_installStoreKitSuppressor();
        amproj_hapticSuppressUntil = CFAbsoluteTimeGetCurrent() + 25.0;
        NSLog(@"[AMProjExport] gate defense round: %@",
              kAMProjGateDefenseRound);
#if AMPROJ_DEBUG
        NSLog(@"[AMProjExport] ===== Loading v44-debug =====");
#elif AMPROJ_TELEMETRY
        NSLog(@"[AMProjExport] ===== Loading v44-cloud =====");
#else
        NSLog(@"[AMProjExport] ===== Loading v44 =====");
#endif
        NSLog(@"%@", kAMProjCloudStabilityContract);
        amproj_installCrackWelcomeSuppressors();
        // Member state: embedded defaults for fresh installs, then the
        // cloud user system's member_flags.json controls the entitlements
        // (the user edits that file server-side; devices follow).
        amproj_writeEmbeddedMemberStateIfAbsent();
        amproj_syncMemberFlags(@"launch");
        for (NSNumber *delay in @[@15, @45, @90]) {
            dispatch_after(dispatch_time(
                DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                amproj_syncMemberFlags([NSString stringWithFormat:
                    @"launch+%@s", delay]);
            });
        }
#if AMPROJ_CLOUD_SYNC
        AMCloudSyncInstallPluginHooksEarly();
#endif
        amproj_restorePhotoAlbumMode();
        amproj_installIPAFireWindowHook();

        // ObjC classes are registered before image constructors. Installing only
        // this AppDelegate hook here avoids touching UIApplication or UIKit UI.
        // The didFinish hook synchronously stages cold-launch documents while
        // their grant is valid. Validation, unpacking, native import and UI wait
        // until activation; constructors still do not instantiate UIApplication/UI.
        if (amproj_runtimeUsesPublic865ImportHooks()) {
            // Constructor-safe: this installer only mutates already-registered
            // classes and never asks UIApplication for an instance.
            amproj_installPublic865ImportHooks();
        } else if (amproj_runtimeUsesLegacyImportHooks()) {
            amproj_installApplicationDelegateHook();
            (void)amproj_installColdLaunchHook();
            (void)amproj_installDeclaredURLHooks();
        } else {
            amproj_log865LegacyPathDisabled(@"constructor_import_hooks");
        }

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        if (amproj_runtimeIsBuild865() && !amproj_windowDidBecomeKeyObserver) {
            amproj_windowDidBecomeKeyObserver = [center
                addObserverForName:UIWindowDidBecomeKeyNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
                amproj_scheduleIPAFireWelcomeSuppression(@"window_did_become_key");
            }];
        }
        if (amproj_runtimeIsBuild865() && !amproj_windowDidBecomeVisibleObserver) {
            amproj_windowDidBecomeVisibleObserver = [center
                addObserverForName:UIWindowDidBecomeVisibleNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
                amproj_scheduleIPAFireWelcomeSuppression(@"window_did_become_visible");
            }];
        }
        if (amproj_runtimeIsBuild865() && !amproj_willEnterForegroundObserver) {
            amproj_willEnterForegroundObserver = [center
                addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
                amproj_scheduleIPAFireWelcomeSuppression(@"will_enter_foreground");
            }];
        }
        amproj_willLaunchObserver = [center
            addObserverForName:@"UIApplicationWillFinishLaunchingNotification"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            // This runs after other injected dylib constructors and before AM
            // creates the media browser, so their demo preset cannot win a
            // constructor-order race.
            amproj_restorePhotoAlbumMode();
            // UIKit's presentation hook must be present here because AM can
            // present its startup
            // PaywallLoadingScreenView before DidFinishLaunching. Do not consume
            // launch URLs here: Build 865 owns its own document lifecycle.
            UIApplication *application =
                [notification.object isKindOfClass:UIApplication.class]
                    ? notification.object : nil;
            if (amproj_runtimeUsesPublic865ImportHooks() && application.delegate) {
                amproj_public865Application = application;
                amproj_public865RuntimeDelegate = application.delegate;
            }
            amproj_installPresentationHook();
            amproj_installPublic865ImportHooks();
            amproj_installImportHook();
            amproj_scheduleIPAFireWelcomeSuppression(@"will_finish_launching");
        }];
        amproj_didLaunchObserver = [center
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            UIApplication *application =
                [notification.object isKindOfClass:UIApplication.class]
                    ? notification.object : nil;
            if (amproj_runtimeUsesPublic865ImportHooks() && application.delegate) {
                amproj_public865Application = application;
                amproj_public865RuntimeDelegate = application.delegate;
            }
            amproj_bootstrapAfterLaunch(@"did_finish_launching");
            amproj_installPublic865ImportHooks();
            amproj_installImportHook();
        }];
        amproj_didBecomeActiveObserver = [center
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                        queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *notification) {
            UIApplication *application =
                [notification.object isKindOfClass:UIApplication.class]
                    ? notification.object : nil;
            if (amproj_runtimeUsesPublic865ImportHooks() && application.delegate) {
                amproj_public865Application = application;
                amproj_public865RuntimeDelegate = application.delegate;
            }
            amproj_bootstrapAfterLaunch(@"did_become_active");
            amproj_installPublic865ImportHooks();
            amproj_installImportHook();
            amproj_armPaywallStartupFallback();
            amproj_startStartupPaywallRescue();
            amproj_schedulePaywallScan(nil, @"did_become_active");
            amproj_syncMemberFlags(@"did_become_active");
            amproj_scheduleIPAFireWelcomeSuppression(@"did_become_active");
            if (amproj_runtimeUsesLocalImportEngine()) {
                // The launch URL is the current user action. Consume its deferred
                // candidate first; only then inspect stale app-owned Inbox files.
                amproj_retryDeferredLaunchImportCandidates();
                amproj_scanLocalImportInboxes(@"did_become_active", nil);
                if (amproj_pendingImportURL) {
                    amproj_tryDispatchPendingImport(amproj_pendingImportGeneration);
                } else if (amproj_importDispatchCoolingDown &&
                           !amproj_nativeImportObservationActive &&
                           !amproj_nativeImportAlertActive &&
                           !amproj_waitingForNativeImportAlert) {
                    amproj_resumeQueuedImports(@"did_become_active");
                }
            } else {
                amproj_log865LegacyPathDisabled(@"did_become_active_import_replay");
            }
            static NSDate *lastDependencyRestore = nil;
            if (!lastDependencyRestore ||
                [NSDate.date timeIntervalSinceDate:lastDependencyRestore] > 10.0) {
                lastDependencyRestore = NSDate.date;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(2.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        amproj_restoreDependencies();
                    });
            }
            static dispatch_once_t restoreTimerToken;
            dispatch_once(&restoreTimerToken, ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(45.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [NSTimer scheduledTimerWithTimeInterval:45.0
                            target:[AMProjRestoreTimerProxy sharedProxy]
                            selector:@selector(restore)
                            userInfo:nil repeats:YES];
                    });
            });
            static dispatch_once_t depLocateToken;
            dispatch_once(&depLocateToken, ^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(12.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        amproj_locateDependencySamples();
                        amproj_logMediaTagSamples();
                    });
            });
        }];
        amproj_willResignActiveObserver = [center
            addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            // QQ/Files returns through openURL before the next didBecomeActive.
            // Reinstall here so late Firebase/AppDelegate swizzles cannot own
            // that callback window.
            amproj_installPublic865ImportHooks();
            amproj_installImportHook();
        }];
        if (@available(iOS 13.0, *)) {
            amproj_sceneWillConnectObserver = [center
                addObserverForName:@"UISceneWillConnectNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
                UIScene *scene = [notification.object isKindOfClass:UIScene.class]
                    ? notification.object : nil;
                if (amproj_runtimeUsesPublic865ImportHooks()) {
                    amproj_installPublic865SceneHooksForClass(
                        [scene.delegate class]);
                    amproj_installPublic865ImportHooks();
                } else if (amproj_runtimeUsesLegacyImportHooks()) {
                    amproj_installSceneImportHook(scene.delegate);
                } else {
                    amproj_log865LegacyPathDisabled(@"scene_connect_import_hook");
                }
            }];
            amproj_sceneWillDeactivateObserver = [center
                addObserverForName:UISceneWillDeactivateNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
                amproj_installPublic865ImportHooks();
                amproj_installImportHook();
            }];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            amproj_bootstrapAfterLaunch(@"main_queue_fallback");
            amproj_installPublic865ImportHooks();
            amproj_installImportHook();
            amproj_armPaywallStartupFallback();
            amproj_startStartupPaywallRescue();
            amproj_schedulePaywallScan(nil, @"main_queue_fallback");
            amproj_scheduleIPAFireWelcomeSuppression(@"main_queue_fallback");
        });

        NSLog(@"[AMProjExport] Hooks scheduled for launch, activation, and delayed fallback");
    }
}
