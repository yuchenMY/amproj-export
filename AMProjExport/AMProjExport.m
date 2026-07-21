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
#import <Photos/Photos.h>
#import <CommonCrypto/CommonDigest.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <zlib.h>
#import <stdatomic.h>
#import <string.h>
#import <math.h>
#import <float.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "AMProjArchiveWriter.h"
#import "AMProjImportArchive.h"
#import "AMProjNativeImportBridge.h"

static NSString *const kAMProjPluginVersion = @"27";

#if AMPROJ_DEBUG
#import "AMDebugTransport.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/arm/thread_status.h>
#endif

// Forward declarations
typedef NS_ENUM(NSInteger, AMProjIncomingURLResult) {
    AMProjIncomingURLNotRecognized = 0,
    AMProjIncomingURLAccepted,
    AMProjIncomingURLFailed,
};

static NSData* amproj_buildXML(id sceneInfo);
static NSData* amproj_buildXMLInternal(id sceneInfo, NSMutableSet<NSValue*> *visited,
                                       NSUInteger depth, BOOL includeDeclaration);
static NSString* amproj_serializeLayer(id layer, NSMutableSet<NSValue*> *visited, NSUInteger depth);
static NSString* amproj_tagForType(NSString *type);
static UIWindow* amproj_keyWindow(void);
static NSURL* amproj_directExportRoot(void);
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
static void amproj_presentImportError(NSString *message);
static void amproj_presentImportErrorOfferingPicker(NSString *message,
                                                     BOOL offerPicker);
static void amproj_presentImportDocumentPicker(void);
static dispatch_queue_t amproj_importInboxQueue(void);
static void amproj_scanLocalImportInboxes(NSString *source, NSString *requestID);
static void amproj_installImportHook(void);
static Class amproj_declaredAppDelegateClass(void);

static void amproj_debugEvent(NSString *name, NSDictionary *fields) {
#if AMPROJ_DEBUG
    [[AMDebugTransport shared] emitEvent:name fields:fields ?: @{}];
#else
    (void)name;
    (void)fields;
#endif
}

static void amproj_flushDebugEvents(void) {
#if AMPROJ_DEBUG
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

static Ivar amproj_instanceIvar(id object, NSString *name) {
    if (!object || !name.length) return NULL;
    return class_getInstanceVariable([object class], name.UTF8String);
}

static BOOL amproj_swiftIntegerIvar(id object, NSString *name, NSInteger *value) {
    if (![name isEqualToString:@"selectedRow"]) return NO;
    if (![NSStringFromClass([object class]) containsString:@"ShareVC"]) return NO;
    Ivar ivar = amproj_instanceIvar(object, name);
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type && type[0] && type[0] != 'q' && type[0] != 'Q') return NO;
    NSInteger raw = 0;
    const uint8_t *address = (const uint8_t *)(__bridge const void *)object + ivar_getOffset(ivar);
    memcpy(&raw, address, sizeof(raw));
    if (value) *value = raw;
    return YES;
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
        NSString *filename = amproj_internalResourceFilename(reference);
        if (!filename.length) {
            amproj_debugEvent(@"direct.am_internal", @{
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
        amproj_debugEvent(@"direct.am_internal", @{
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
    if ([scheme isEqualToString:@"am-internal"]) {
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
        if ([scheme isEqualToString:@"am-internal"]) [internalReferences addObject:reference];
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
static BOOL amproj_bypassPackagePresentation = NO;
static NSUInteger amproj_bypassPackageGeneration = 0;

static void amproj_allowOriginalPackagePresentation(void) {
    amproj_bypassPackagePresentation = YES;
    NSUInteger generation = ++amproj_bypassPackageGeneration;
    amproj_debugEvent(@"direct.original_bypass", @{@"enabled": @YES});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * 60 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (amproj_bypassPackageGeneration == generation) {
            amproj_bypassPackagePresentation = NO;
        }
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
@property(nonatomic, copy) void (^fallbackAction)(void);
@end

@implementation AMProjDirectRequest
@end

static AMProjDirectRequest *amproj_directRequest = nil;
static BOOL amproj_constructingDirectShare = NO;

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
                activity = [[UIActivityViewController alloc]
                    initWithActivityItems:@[item] applicationActivities:nil];
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
        NSError *error = nil;
        AMProjXMLProbe *validated = nil;
        amproj_setPersistentStage(@"xml_validate");
        if (!amproj_validateXMLAgainstScene(xmlData, expected, &validated, &error)) {
            amproj_finishDirectFailure(request, error);
            return;
        }
        amproj_setPersistentStage(@"resource_rewrite");
        NSDictionary *prepared = amproj_collectResourcesAndRewriteXML(xmlData, XMLURL, &error);
        if (!prepared) {
            amproj_finishDirectFailure(request, error);
            return;
        }
        NSData *rewrittenXML = prepared[@"xml"];
        NSDictionary<NSString *, NSURL *> *resources = prepared[@"resources"];
        if (!amproj_validateXMLAgainstScene(rewrittenXML, expected, NULL, &error)) {
            amproj_finishDirectFailure(request, error);
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
        amproj_debugEvent(@"direct.archive_ready", @{
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
        amproj_presentDirectShare(request, outputURL);
    });
}

static void amproj_buildDirectPackage(AMProjDirectRequest *request) {
    if (amproj_directRequest != request) return;
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
    amproj_debugEvent(@"direct.scene_native_only", @{
        @"holder": @"not_accessed",
        @"scene": @"not_accessed",
        @"title": expected[@"title"],
        @"layers": expected[@"layers"],
        @"path_candidates": @(paths.count)
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
            amproj_debugEvent(@"direct.native_xml", @{
                @"found": @YES,
                @"path": [native[@"url"] lastPathComponent] ?: @"",
                @"score": native[@"score"] ?: @0
            });
            amproj_writeDirectArchive(request, native[@"data"], native[@"url"], validatedExpected, @"native");
            return;
        }
        amproj_debugEvent(@"direct.native_xml", @{@"found": @NO});
        amproj_finishDirectFailure(request,
            amproj_directError(51, @"Unable to locate Alight Motion's saved project XML; no incomplete fallback package was created"));
    });
}

static void amproj_startDirectExport(UIViewController *presenter,
                                     UIViewController *originalController,
                                     BOOL animated, void (^completion)(void),
                                     NSString *projectTitle, void (^fallbackAction)(void)) {
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
    request.fallbackAction = fallbackAction;
    request.mode = amproj_exportMode();
    request.progressAlert = [UIAlertController alertControllerWithTitle:@"正在生成 .amproj"
        message:@"正在读取项目与媒体文件，请稍候…" preferredStyle:UIAlertControllerStyleAlert];
    amproj_directRequest = request;
    amproj_setPersistentStage(@"progress_present");
    amproj_beginDirectFlow();
    amproj_debugEvent(@"direct.intercept", @{
        @"presenter": NSStringFromClass([presenter class]) ?: @"",
        @"controller": NSStringFromClass([originalController class]) ?: @"",
        @"holder": @"not_accessed",
        @"source": fallbackAction ? @"share_export_button" : @"package_presentation",
        @"mode": request.mode ?: @""
    });
    orig_presentVC(presenter, @selector(presentViewController:animated:completion:),
                   request.progressAlert, YES, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ amproj_buildDirectPackage(request); });
    });
}

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
        void (^fallbackAction)(void) = request.fallbackAction;
        void (^showFailure)(void) = ^{
            amproj_directRequest = nil;
            amproj_finishDirectFlow(@"failed");
            if (!presenter) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法生成 .amproj"
                message:error.localizedDescription ?: @"项目数据验证失败。"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    amproj_startDirectExport(presenter, originalController, animated, originalCompletion,
                                             projectTitle, fallbackAction);
                }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"使用原版二维码"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    if (fallbackAction) {
                        fallbackAction();
                    } else {
                        orig_presentVC(presenter, @selector(presentViewController:animated:completion:),
                                       originalController, animated, originalCompletion);
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
typedef BOOL (*AMProjApplicationDidFinishIMP)(id, SEL, UIApplication *, NSDictionary *);
typedef BOOL (*AMProjApplicationContinueActivityIMP)(id, SEL, UIApplication *,
                                                      NSUserActivity *, id);
typedef BOOL (*AMProjApplicationHandleOpenURLIMP)(id, SEL, UIApplication *, NSURL *);
typedef BOOL (*AMProjApplicationLegacyOpenURLIMP)(id, SEL, UIApplication *, NSURL *,
                                                  NSString *, id);
typedef void (*AMProjSceneOpenURLContextsIMP)(id, SEL, UIScene *, NSSet *);

@interface AMProjImportPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

typedef struct {
    __unsafe_unretained Class cls;
    IMP original;
    IMP base;
} AMProjTrackedHook;

static AMProjTrackedHook amproj_openURLHooks[12] = {0};
static AMProjTrackedHook amproj_didFinishHooks[12] = {0};
static AMProjTrackedHook amproj_continueActivityHooks[12] = {0};
static AMProjTrackedHook amproj_handleOpenURLHooks[12] = {0};
static AMProjTrackedHook amproj_legacyOpenURLHooks[12] = {0};
static AMProjTrackedHook amproj_sceneOpenURLHooks[12] = {0};
static AMProjTrackedHook amproj_nativeXMLDelegateStartHooks[8] = {0};
static AMProjTrackedHook amproj_nativeXMLDelegateEndHooks[8] = {0};
static IMP amproj_nativeAppDelegateOpenURLIMP = NULL;
static BOOL (*orig_nativeXMLParserParse)(NSXMLParser *, SEL) = NULL;
static char amproj_nativeXMLParserAttemptKey;
static char amproj_nativeXMLParserLastElementKey;
static char amproj_nativeXMLParserElementStackKey;
static char amproj_nativeXMLParserSemanticErrorKey;
static char amproj_nativeXMLParserErrorCountKey;
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
static NSString *amproj_activeNativeImportTransactionID = nil;
static BOOL amproj_importVerificationActive = NO;
static NSUInteger amproj_importVerificationGeneration = 0;
static NSString *amproj_importVerificationName = nil;
static NSString *amproj_importVerificationTransactionID = nil;
static NSUInteger amproj_importVerificationAttempt = 0;
static NSInteger amproj_importProjectRowBaselineCount = -1;
typedef NS_ENUM(NSInteger, AMProjImportTransactionState) {
    AMProjImportTransactionCaptured = 0,
    AMProjImportTransactionCopying,
    AMProjImportTransactionValidating,
    AMProjImportTransactionQueued,
    AMProjImportTransactionWaitingForProjects,
    AMProjImportTransactionNativeActive,
    AMProjImportTransactionCompleted,
    AMProjImportTransactionFailed,
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
@property(nonatomic) BOOL deleteIncomingSourceOnCompletion;
@property(nonatomic) AMProjImportTransactionState state;
@property(nonatomic) CFAbsoluteTime updatedAt;
@end

@implementation AMProjImportTransaction
@end

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
static NSUInteger amproj_importErrorGeneration = 0;
static BOOL amproj_latestImportErrorOffersPicker = YES;
static NSURL *amproj_retryImportURL = nil;
static NSString *amproj_retryImportName = nil;
static __thread NSUInteger amproj_openURLForwardDepth = 0;
static __thread NSUInteger amproj_handleOpenURLForwardDepth = 0;
static __thread NSUInteger amproj_activityForwardDepth = 0;
static __thread NSUInteger amproj_didFinishForwardDepth = 0;
static __thread NSUInteger amproj_legacyOpenURLForwardDepth = 0;
static __thread NSUInteger amproj_sceneOpenURLForwardDepth = 0;

static void amproj_tryDispatchPendingImport(NSUInteger generation);
static void amproj_activateNextPendingImport(void);
static void amproj_resumeQueuedImports(NSString *source);
static void amproj_queuePreparedImport(NSURL *URL, NSString *originalName,
                                       NSString *transactionID);
static void amproj_retryDeferredLaunchImportCandidates(void);
static void amproj_installNativeXMLDelegateHook(Class cls);
static NSString* amproj_compactNativeDiagnostic(NSString *text,
                                                NSUInteger maximumLength);
static NSString* amproj_visibleNativeParserSummary(NSDictionary *snapshot);
static void amproj_verifyImportedProjectRow(NSUInteger generation,
                                            NSString *name,
                                            NSString *transactionID,
                                            NSUInteger attempt);

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
            return now - amproj_importTombstones[candidate].doubleValue > 15.0;
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
        @"waiting_for_projects", @"native_active", @"completed", @"failed"
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
    if ([text containsString:@"2/4"]) return 2;
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
    NSString *diagnostics = amproj_copyDiagnosticSummary(error);
    if (diagnostics.length) {
        return [NSString stringWithFormat:@"AMProj v27 \u00b7 %@ (E%ld \u00b7 %@)",
                                          message, (long)error.code, diagnostics];
    }
    return [NSString stringWithFormat:@"AMProj v27 \u00b7 %@ (E%ld)",
                                      message, (long)error.code];
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
    return [base stringByAppendingPathExtension:@"amproj"];
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

static BOOL amproj_isIncomingProjectURL(NSURL *URL, NSDictionary *options) {
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL) return NO;
    NSString *extension = URL.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"amproj"] || [extension isEqualToString:@"zip"]) {
        return YES;
    }
    for (id value in options.allValues) {
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *identifier = [(NSString *)value lowercaseString];
        if ([identifier containsString:@"amproj"] ||
            [identifier isEqualToString:@"public.zip-archive"]) {
            return YES;
        }
    }

    // Never consume unrelated media/document URLs. QQ/Files preserves the
    // .amproj suffix in copy-in mode; providers that omit it must supply the UTI.
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
        amproj_presentImportError(@"请选择一个 .amproj 项目包。");
        return;
    }
    NSURL *selectedURL = [URLs.firstObject copy];
    BOOL heldSecurityScope = [selectedURL startAccessingSecurityScopedResource];
    amproj_showImportStatus(@"AMProj v27 · 1/4 已选择 .amproj 文件", NO);
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
            amproj_presentImportError(@"选择的文件不是可识别的 .amproj 项目包。");
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
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    if (projectType) [types addObject:projectType];
    if (archiveType) [types addObject:archiveType];
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
        alertControllerWithTitle:@"无法导入 .amproj"
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
        [alert addAction:[UIAlertAction actionWithTitle:@"选择项目包"
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
    NSString *snapshot = message.length ? [message copy] :
        @"请返回 QQ 或文件 App 后重新打开项目包。";
    dispatch_async(dispatch_get_main_queue(), ^{
        amproj_latestImportErrorMessage = snapshot;
        amproj_latestImportErrorOffersPicker = offerPicker;
        NSUInteger generation = ++amproj_importErrorGeneration;
        amproj_presentImportErrorAttempt(snapshot, generation, 0);
    });
}

static void amproj_presentImportError(NSString *message) {
    amproj_presentImportErrorOfferingPicker(message, YES);
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
        @"AMProj v27 \u539f\u751f\u5bfc\u5165\u5931\u8d25\uff0c\u8bf7\u5b8c\u5168\u5173\u95ed\u5e76\u91cd\u65b0\u6253\u5f00 Alight Motion \u540e\u518d\u91cd\u8bd5\u3002\u5df2\u4fdd\u7559\u5bfc\u5165\u7f13\u5b58\u5305\u3002";
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
                @"AMProj v27 \u00b7 2/4 \u5df2\u590d\u5236\uff0c\u6b63\u5728\u5b8c\u6574\u6821\u9a8c\u5e76\u89c4\u8303\u5316\u9879\u76ee\u5305",
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
                // Official Android packages can contain multiple independent
                // scene XML files. Keep a verified package byte-for-byte when
                // its XML already carries the manifest identities. Packages
                // exported by some Android builds omit `media sig`; the iOS
                // importer treats those resources as missing, so rebuild the
                // complete single-scene archive with the verified signatures.
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
                    if (signatureRewrites == 0) {
                        preparedURL = archiveSnapshot;
                        route = @"validated_original_package";
                    } else if (inputXMLCount == 1) {
                        NSURL *normalizedURL = [directorySnapshot URLByAppendingPathComponent:
                            [[@"normalized-signed-" stringByAppendingString:
                                NSUUID.UUID.UUIDString.lowercaseString]
                                stringByAppendingPathExtension:@"amproj"]];
                        BOOL normalized = AMProjNormalizeProjectArchive(
                            archiveSnapshot, directorySnapshot, normalizedURL,
                            &preparationMetrics, &preparationError);
                        if (normalized && normalizedURL.isFileURL) {
                            preparedURL = normalizedURL;
                            route = @"normalized_manifest_media_signatures";
                        }
                    } else {
                        preparationError = [NSError errorWithDomain:
                            @"com.amproj.import.archive" code:33 userInfo:@{
                                NSLocalizedDescriptionKey:
                                    @"A multi-scene project package has media without manifest signatures; it was not modified",
                                @"xml_count": @(inputXMLCount),
                                @"rewritten_media_signature_count": @(signatureRewrites)
                            }];
                    }
                }
            } else if (inputXMLCount == 1) {
                // Legacy exports without a manifest need one canonical rebuild.
                NSURL *normalizedURL = [directorySnapshot URLByAppendingPathComponent:
                    [[@"normalized-" stringByAppendingString:
                        NSUUID.UUID.UUIDString.lowercaseString]
                        stringByAppendingPathExtension:@"amproj"]];
                BOOL normalized = AMProjNormalizeProjectArchive(
                    archiveSnapshot, directorySnapshot, normalizedURL,
                    &preparationMetrics, &preparationError);
                if (normalized && normalizedURL.isFileURL) {
                    preparedURL = normalizedURL;
                    route = @"normalized_legacy_package";
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
                        @"AMProj v27 \u00b7 \u9879\u76ee\u5305\u65e0\u6cd5\u89c4\u8303\u5316\uff1a%@", detail];
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
                    @"AMProj 项目包中有 %lu 个媒体没有对应的 manifest SHA-1，已停止导入",
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
                                             sourceSnapshot, nil, nil, missingMediaMessage);
                if (!silentErrors) {
                    amproj_showImportStatusForTransaction(
                        missingMediaMessage, YES, transactionID);
                    amproj_presentImportError(missingMediaMessage);
                }
                return;
            }
            amproj_showImportStatusForTransaction(
                @"AMProj v27 \u00b7 2/4 \u9879\u76ee\u5305\u5b8c\u6574\u6821\u9a8c\u901a\u8fc7\uff0c\u6b63\u5728\u542f\u52a8\u672c\u5730\u5bfc\u5165",
                NO, transactionID);
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
                        @"AMProj v27 · 项目包处理异常：%@", reason];
                    amproj_showImportStatusForTransaction(visible, YES, transactionID);
                    amproj_presentImportError(visible);
                }
            }
        }
    });
}

static void amproj_activateNextPendingImport(void) {
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
    if (amproj_importVerificationActive || amproj_pendingImportURL || amproj_importDispatchCoolingDown ||
        amproj_nativeImportAlertActive) {
        amproj_debugEvent(@"import.queue_blocked", @{
            @"pending": @(amproj_pendingImportURL != nil),
            @"cooldown": @(amproj_importDispatchCoolingDown),
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
    amproj_pendingImportDeadline =
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive
        ? CFAbsoluteTimeGetCurrent() + 90.0 : 0;
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
        @"AMProj v27 \u00b7 2/4 \u6b63\u5728\u5bfc\u5165\u5230\u5e95\u90e8\u201c\u9879\u76ee\u201d",
        NO, transactionID);
    amproj_tryDispatchPendingImport(generation);
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
        for (UIViewController *child in controller.childViewControllers) walk(child);
        walk(controller.presentedViewController);
        if ([controller isKindOfClass:UINavigationController.class]) {
            for (UIViewController *child in ((UINavigationController *)controller).viewControllers) walk(child);
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            for (UIViewController *child in ((UITabBarController *)controller).viewControllers) walk(child);
        }
    };
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
    return result;
}

static void amproj_refreshVisibleProjectsRows(void) {
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        SEL selector = NSSelectorFromString(@"pCollectionView");
        id collection = nil;
        @try {
            if ([controller respondsToSelector:selector]) {
                collection = ((id (*)(id, SEL))(void *)objc_msgSend)(controller, selector);
            }
            if ([collection respondsToSelector:@selector(reloadData)]) {
                ((void (*)(id, SEL))(void *)objc_msgSend)(collection, @selector(reloadData));
            }
            [controller.viewIfLoaded setNeedsLayout];
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_refresh_exception", @{
                @"controller": NSStringFromClass(controller.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
}

static NSInteger amproj_visibleProjectsRowCount(void) {
    NSInteger total = -1;
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        @try {
            SEL selector = NSSelectorFromString(@"pCollectionView");
            id collection = [controller respondsToSelector:selector]
                ? ((id (*)(id, SEL))(void *)objc_msgSend)(controller, selector) : nil;
            if (![collection respondsToSelector:@selector(numberOfSections)] ||
                ![collection respondsToSelector:@selector(numberOfItemsInSection:)]) continue;
            NSInteger sections = ((NSInteger (*)(id, SEL))(void *)objc_msgSend)(
                collection, @selector(numberOfSections));
            NSInteger count = 0;
            for (NSInteger section = 0; section < sections && section < 32; section++) {
                count += ((NSInteger (*)(id, SEL, NSInteger))(void *)objc_msgSend)(
                    collection, @selector(numberOfItemsInSection:), section);
            }
            total = MAX(total, count);
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_count_exception", @{
                @"controller": NSStringFromClass(controller.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
    return total;
}

static BOOL amproj_projectRowVerifiedForName(NSString *name) {
    NSString *title = name.stringByDeletingPathExtension;
    if (!title.length) return NO;
    for (UIViewController *controller in amproj_visibleProjectsControllers()) {
        @try {
            NSMutableSet<NSValue *> *visited = [NSMutableSet set];
            if (amproj_viewTreeContainsImportedTitle(controller.viewIfLoaded, title, visited, 0)) {
                return YES;
            }
            SEL dataSourceSelector = NSSelectorFromString(@"pCollectionView");
            id collection = [controller respondsToSelector:dataSourceSelector]
                ? ((id (*)(id, SEL))(void *)objc_msgSend)(controller, dataSourceSelector) : nil;
            id dataSource = [collection respondsToSelector:@selector(dataSource)]
                ? ((id (*)(id, SEL))(void *)objc_msgSend)(collection, @selector(dataSource)) : nil;
            if (amproj_textMatchesImportedTitle([dataSource description], title)) return YES;
        } @catch (NSException *exception) {
            amproj_debugEvent(@"import.project_row_probe_exception", @{
                @"controller": NSStringFromClass(controller.class) ?: @"",
                @"reason": exception.reason ?: @""
            });
        }
    }
    return NO;
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
        BOOL rowAdded = amproj_importProjectRowBaselineCount >= 0 &&
            rowCount > amproj_importProjectRowBaselineCount;
        BOOL verified = rowAdded || amproj_projectRowVerifiedForName(name);
        amproj_debugEvent(verified ? @"import.project_row_verified"
                                   : @"import.project_row_probe", @{
            @"transaction_id": transactionID ?: @"",
            @"filename": name ?: @"project.amproj",
            @"attempt": @(attempt),
            @"row_count": @(rowCount),
            @"baseline_row_count": @(amproj_importProjectRowBaselineCount),
            @"verified": @(verified)
        });
        if (verified) {
            amproj_importVerificationActive = NO;
            amproj_importVerificationName = nil;
            amproj_importVerificationTransactionID = nil;
            amproj_importProjectRowBaselineCount = -1;
            AMProjImportTransaction *transaction =
                amproj_importTransactionForID(transactionID);
            amproj_retryImportURL = nil;
            amproj_retryImportName = nil;
            if (transaction.deleteIncomingSourceOnCompletion && transaction.incomingURL) {
                [NSFileManager.defaultManager removeItemAtURL:transaction.incomingURL error:nil];
            }
            if (transaction.incomingCleanupURL) {
                [NSFileManager.defaultManager removeItemAtURL:transaction.incomingCleanupURL
                                                          error:nil];
            }
            amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                         @"completed", transaction.source,
                                         nil, @4, nil);
            amproj_releaseImportTransaction(transactionID, YES);
            amproj_importVisibleStageRank = 0;
            amproj_visibleStatusTransactionID = nil;
            amproj_showImportStatusForTransaction(
                @"AMProj v27 · 4/4 已验证项目已出现在底部“项目”", NO,
                transactionID);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_resumeQueuedImports(@"project_row_verified");
            });
            return;
        }
        if (attempt < 30) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                amproj_verifyImportedProjectRow(generation, name, transactionID,
                                                attempt + 1);
            });
            return;
        }
        amproj_importVerificationActive = NO;
        amproj_importVerificationName = nil;
        amproj_importVerificationTransactionID = nil;
        amproj_importProjectRowBaselineCount = -1;
        NSError *verifyError = [NSError errorWithDomain:@"com.amproj.import.verify"
                                                    code:120
                                                userInfo:@{
            NSLocalizedDescriptionKey:
                @"原生导入回调已完成，但底部“项目”中没有找到新项目",
            @"AMProjProjectRowVerified": @NO,
            @"AMProjRetryable": @YES
        }];
        AMProjImportTransaction *transaction =
            amproj_importTransactionForID(transactionID);
        amproj_retryImportURL = transaction.archiveURL;
        amproj_retryImportName = [name copy];
        amproj_writeImportBreadcrumb(transactionID, transaction.fingerprint,
                                     @"failed", transaction.source, nil, @4,
                                     verifyError.localizedDescription);
        amproj_releaseImportTransaction(transactionID, NO);
        amproj_importVisibleStageRank = 0;
        amproj_visibleStatusTransactionID = nil;
        amproj_debugEvent(@"import.project_row_missing", @{
            @"transaction_id": transactionID ?: @"",
            @"filename": name ?: @"project.amproj",
            @"attempts": @(attempt + 1),
            @"cache_path": transaction.archiveURL.path ?: @"",
            @"error": verifyError.localizedDescription
        });
        NSString *visible = [NSString stringWithFormat:
            @"AMProj v27 · 导入未完成：%@。缓存包已保留，可重试。",
            verifyError.localizedDescription];
        amproj_showImportStatusForTransaction(visible, YES, transactionID);
        amproj_presentImportErrorOfferingPicker(visible, NO);
        amproj_activateNextPendingImport();
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
            amproj_activateNextPendingImport();
            return;
        }
        amproj_debugEvent(@"import.local_bridge_finished", @{
            @"success": @(success),
            @"filename": name ?: @"project.amproj",
            @"transaction_id": transactionID ?: @"",
            @"attempt_id": observation[@"attempt_id"] ?: @"",
            @"error_domain": error.domain ?: @"",
            @"error_code": @(error.code),
            @"error": error.localizedDescription ?: @""
        });
        if (success) {
            // PackageImporter completion only means its callback fired. Keep
            // the transaction claimed until the project row is visible in the
            // bottom Projects tab, otherwise a duplicate URL can race the
            // persistence step and produce a false 4/4.
            amproj_importVerificationActive = YES;
            ++amproj_importVerificationGeneration;
            amproj_importVerificationName = [name copy];
            amproj_importVerificationTransactionID = [transactionID copy];
            amproj_importVerificationAttempt = 0;
            amproj_writeImportBreadcrumb(transactionID,
                                         amproj_importTransactionForID(transactionID).fingerprint,
                                         @"verifying_project_row", nil, nil, @4, nil);
            amproj_showImportStatusForTransaction(
                @"AMProj v27 · 原生回调完成，正在确认项目已出现在底部“项目”",
                NO, transactionID);
            amproj_verifyImportedProjectRow(amproj_importVerificationGeneration,
                                            name ?: @"project.amproj",
                                            transactionID, 0);
        } else {
            AMProjImportTransaction *failedTransaction =
                amproj_importTransactionForID(transactionID);
            amproj_retryImportURL = failedTransaction.archiveURL;
            amproj_retryImportName = [name copy];
            amproj_releaseImportTransaction(transactionID, NO);
            amproj_writeImportBreadcrumb(transactionID,
                                         failedTransaction.fingerprint,
                                         @"failed", failedTransaction.source, nil, @5,
                                         error.localizedDescription);
            NSString *detail = error.localizedDescription.length
                ? error.localizedDescription : @"AM \u672c\u5730\u9879\u76ee\u5305\u5bfc\u5165\u5931\u8d25";
            NSString *visible = [NSString stringWithFormat:
                @"AMProj v27 \u00b7 \u65e0\u6cd5\u5bfc\u5165\u5230\u201c\u9879\u76ee\u201d\uff1a%@", detail];
            amproj_showImportStatusForTransaction(visible, YES, transactionID);
            if (![error.userInfo[@"AMProjNativeAlertPresented"] boolValue]) {
                amproj_presentImportErrorOfferingPicker(visible, NO);
            }
            amproj_importProjectRowBaselineCount = -1;
        }
        if (!success) {
            // Keep the failed Inbox source and staged cache for an explicit
            // retry, but do not scan it again immediately in a failure loop.
            amproj_activateNextPendingImport();
        }
    });
}

static void amproj_tryDispatchPendingImport(NSUInteger generation) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != amproj_pendingImportGeneration || !amproj_pendingImportURL) return;

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
        if (amproj_pendingImportDeadline <= 0) {
            amproj_pendingImportDeadline = CFAbsoluteTimeGetCurrent() + 90.0;
        }
        AMProjNativePackageImportStarter starter = amproj_nativePackageImportStarter;
        NSString *transactionID = amproj_pendingImportTransactionID ?: @"";
        if (starter) {
            NSURL *URL = amproj_pendingImportURL;
            NSString *name = amproj_pendingImportName ?: @"project.amproj";
            CFAbsoluteTime deadline = amproj_pendingImportDeadline;
            amproj_importDispatchCoolingDown = YES;
            amproj_markImportTransactionState(
                transactionID, AMProjImportTransactionNativeActive);
            if (amproj_importProjectRowBaselineCount < 0) {
                amproj_importProjectRowBaselineCount = amproj_visibleProjectsRowCount();
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
                amproj_debugEvent(@"import.local_bridge_retry", @{
                    @"filename": name,
                    @"error": startError.localizedDescription ?: @"",
                    @"remaining_ms": @(MAX(0, (deadline -
                        CFAbsoluteTimeGetCurrent()) * 1000.0))
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    amproj_tryDispatchPendingImport(generation);
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
                    @"AMProj v27 \u00b7 3/4 AM \u6b63\u5728\u89e3\u5305\u5e76\u5199\u5165\u5e95\u90e8\u201c\u9879\u76ee\u201d",
                    NO, transactionID);
                amproj_debugEvent(@"import.local_bridge_started", @{
                    @"success": @YES,
                    @"filename": name
                });
            }
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
                @"AMProj v27 \u00b7 AM \u672c\u5730\u9879\u76ee\u5bfc\u5165\u5668\u5c1a\u672a\u5c31\u7eea",
                YES, transactionID);
            amproj_presentImportErrorOfferingPicker(
                @"\u9879\u76ee\u5305\u5df2\u590d\u5236\u5e76\u6821\u9a8c\u901a\u8fc7\uff0c\u4f46 Alight Motion \u672c\u5730\u9879\u76ee\u5bfc\u5165\u5668\u672a\u80fd\u5c31\u7eea\u3002\u672c\u6b21\u6ca1\u6709\u56de\u9000\u5230\u4efb\u4f55\u4e0a\u4f20\u5165\u53e3\u3002",
                YES);
            amproj_activateNextPendingImport();
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!URL) return;
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
        amproj_activateNextPendingImport();
    });
}

static void amproj_resumeQueuedImports(NSString *source) {
    if (AMProjNativePackageImportBridgeRequiresRestart()) {
        amproj_pauseForNativeBridgeRestart(
            amproj_pendingImportTransactionID ?: amproj_activeNativeImportTransactionID,
            amproj_pendingImportName ?: amproj_nativeImportRecognitionName);
        return;
    }
    if (AMProjNativePackageImportBridgeIsBusy()) {
        amproj_debugEvent(@"import.resume_blocked", @{
            @"source": source ?: @"",
            @"reason": @"native_bridge_busy_or_poisoned"
        });
        return;
    }
    if (amproj_importVerificationActive || amproj_nativeImportObservationActive || amproj_nativeImportAlertActive ||
        amproj_waitingForNativeImportAlert) {
        return;
    }
    if (amproj_pendingImportURL) {
        amproj_tryDispatchPendingImport(amproj_pendingImportGeneration);
        return;
    }
    if (amproj_importDispatchCoolingDown) {
        amproj_importDispatchCoolingDown = NO;
        amproj_debugEvent(@"import.cooldown_finished", @{
            @"source": source ?: @""
        });
    }
    amproj_activateNextPendingImport();
    if (!amproj_pendingImportURL) {
        if (amproj_hasDeferredLaunchImportCandidates()) {
            amproj_retryDeferredLaunchImportCandidates();
        } else {
            amproj_scanLocalImportInboxes(source.length ? source : @"resume", nil);
        }
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
    @synchronized (amproj_importDedupeLock()) {
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
        @"filename": originalName ?: @""
    });
    amproj_debugEvent(@"import.url_received", @{
        @"source": source ?: @"",
        @"filename": originalName,
        @"file_url": @YES,
        @"extension": URL.pathExtension ?: @""
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
                    @"AMProj v27 \u00b7 \u521b\u5efa\u5bfc\u5165\u7f13\u5b58\u5931\u8d25",
                    YES, transactionID);
                amproj_presentImportError(@"无法创建导入缓存，请检查设备剩余空间后重试。");
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
            if (!silentErrors) {
                amproj_showImportStatusForTransaction(
                    amproj_visibleImportFileError(copyError), YES, transactionID);
            }
            NSString *diagnostics = amproj_copyDiagnosticSummary(copyError);
            NSString *message = @"无法读取 QQ 或文件 App 提供的项目包，请返回后重新打开一次。";
            message = [message stringByAppendingFormat:
                @"\n\n上下文：%@，scope=%@，openInPlace=%@，before=%@，after=%@，coordinated=%@",
                source ?: @"unknown", scoped ? @"1" : @"0",
                requestedOpenInPlace ? @"1" : @"0",
                readableBeforeScope ? @"1" : @"0", readableAfterScope ? @"1" : @"0",
                coordinatedReadable ? @"1" : @"0"];
            if (diagnostics.length) {
                message = [message stringByAppendingFormat:@"\n\n诊断：%@", diagnostics];
            }
            if (!silentErrors) amproj_presentImportError(message);
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
                NSString *message = @"项目包无法计算 SHA-256 指纹，已停止导入。";
                amproj_showImportStatusForTransaction(message, YES, transactionID);
                amproj_presentImportError(message);
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
        amproj_showImportStatusForTransaction(
            @"AMProj v27 \u00b7 1/4 \u5df2\u6536\u5230 .amproj \u6587件",
            NO, transactionID);
        amproj_showImportStatusForTransaction(
            @"AMProj v27 \u00b7 2/4 \u5df2\u590d\u5236\u9879\u76ee\u5305",
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
            amproj_presentImportError(
                @"处理项目包时发生异常，缓存包已保留；请点击重试或使用“选择项目包”。");
        }
        return AMProjIncomingURLFailed;
    }
}

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
        if (!regular.boolValue || ![extension isEqualToString:@"amproj"]) continue;

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
        BOOL descriptorValid = protocolVersion.integerValue == 1 &&
            descriptorID.length && [descriptorID isEqualToString:directoryID] &&
            originalName.length &&
            [originalName.pathExtension.lowercaseString isEqualToString:@"amproj"] &&
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
                @"error": @"invalid_descriptor_or_payload"
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
    NSArray<NSDictionary *> *candidates = nil;
    @synchronized (amproj_importDedupeLock()) {
        candidates = [amproj_deferredLaunchImportCandidates copy] ?: @[];
        [amproj_deferredLaunchImportCandidates removeAllObjects];
    }
    if (!candidates.count) return;

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
                options[@"AMProjSilentErrors"] = @YES;
                if (amproj_URLIsInDocumentsInbox(URL)) {
                    options[@"AMProjInboxWorker"] = @YES;
                }
                BOOL prepared = NO;
                AMProjIncomingURLResult result =
                    amproj_handleIncomingProjectURLSafely(
                        URL, [source stringByAppendingString:@"_silent_retry"],
                        options, &prepared);
                amproj_debugEvent(@"import.launch_candidate_retry", @{
                    @"source": source,
                    @"command": @NO,
                    @"result": @(result),
                    @"prepared": @(prepared),
                    @"filename": URL.lastPathComponent ?: @""
                });
            }
        }
    });
}

static BOOL amproj_captureSystemProjectURL(NSURL *URL, NSString *source,
                                           NSDictionary *systemOptions) {
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

    NSString *sourceSnapshot = [source copy] ?: @"system_callback";
    NSDictionary *optionsSnapshot = [options copy];
    void (^capture)(void) = ^{
        AMProjIncomingURLResult result = AMProjIncomingURLFailed;
        NSString *exceptionName = @"";
        NSString *exceptionReason = @"";
        @try {
            result = amproj_handleIncomingProjectURL(
                URL, sourceSnapshot, optionsSnapshot);
        } @catch (NSException *exception) {
            exceptionName = exception.name ?: @"";
            exceptionReason = exception.reason ?: @"";
            NSString *incomingName = [optionsSnapshot[@"AMProjOriginalFilename"]
                isKindOfClass:NSString.class] ? optionsSnapshot[@"AMProjOriginalFilename"]
                                               : URL.lastPathComponent;
            amproj_releaseImportTransactionForURL(URL, incomingName);
            amproj_presentImportError(
                @"\u5904\u7406\u7cfb\u7edf\u63d0\u4f9b\u7684\u9879\u76ee\u5305\u65f6\u53d1\u751f\u5f02\u5e38\uff0c\u8bf7\u4f7f\u7528\u201c\u9009\u62e9\u9879\u76ee\u5305\u201d\u91cd\u8bd5\u3002");
        } @finally {
            if (heldSecurityScope) [URL stopAccessingSecurityScopedResource];
        }
        amproj_debugEvent(@"import.system_capture", @{
            @"source": sourceSnapshot,
            @"filename": URL.lastPathComponent ?: @"",
            @"result": @(result),
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
    if (amproj_handleImportCommandURL(URL, @"application_open_url_command")) return YES;
    if (amproj_captureSystemProjectURL(URL, @"application_open_url", options)) {
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
    if (original && original != (IMP)hooked_applicationOpenURL) {
        amproj_openURLForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationOpenURLIMP)original)(
                self, _cmd, application, URL, options);
        } @finally {
            amproj_openURLForwardDepth -= 1;
        }
    }
    amproj_debugEvent(@"import.native_initial", @{
        @"source": @"application_open_url",
        @"recognized": @NO,
        @"accepted": @(nativeHandled),
        @"has_original": @(original != NULL)
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
            if ([candidate[@"key"] isEqualToString:key]) return;
        }
        [amproj_deferredLaunchImportCandidates addObject:@{
            @"url": URL,
            @"key": key,
            @"source": source ?: @"application_did_finish",
            @"options": options ?: @{},
            @"command": @(command)
        }];
    }
}

static void amproj_recordLaunchImportCandidates(NSDictionary *launchOptions,
                                                 NSString *source) {
    if (![launchOptions isKindOfClass:NSDictionary.class]) return;
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
                amproj_recordDeferredLaunchCandidate(
                    activityURL, [source stringByAppendingString:@"_activity"], nil);
            }
        }];
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
}

static NSDictionary *amproj_launchOptionsForNativeAppDelegate(
    NSDictionary *launchOptions) {
    if (![launchOptions isKindOfClass:NSDictionary.class]) return launchOptions;
    NSMutableDictionary *filtered = [launchOptions mutableCopy];
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if ([launchURL isKindOfClass:NSURL.class] &&
        amproj_isIncomingProjectURL(launchURL, launchOptions)) {
        [filtered removeObjectForKey:UIApplicationLaunchOptionsURLKey];
    }
    id activityContainer = launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey];
    if ([activityContainer isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *activities = [activityContainer mutableCopy];
        for (id key in [activities.allKeys copy]) {
            id value = activities[key];
            NSURL *activityURL = [value isKindOfClass:NSUserActivity.class]
                ? amproj_projectURLFromUserActivity(value) : nil;
            if (activityURL && amproj_isIncomingProjectURL(activityURL, nil)) {
                [activities removeObjectForKey:key];
            }
        }
        if (activities.count) filtered[UIApplicationLaunchOptionsUserActivityDictionaryKey] = activities;
        else [filtered removeObjectForKey:UIApplicationLaunchOptionsUserActivityDictionaryKey];
    }
    return filtered;
}

static BOOL hooked_applicationDidFinish(id self, SEL _cmd, UIApplication *application,
                                         NSDictionary *launchOptions) {
    // The initial File Provider sandbox grant is not reliably active here. Keep
    // the candidate, but remove only the project URL from AM's launch options so
    // its native route cannot process the same package a second time.
    amproj_recordLaunchImportCandidates(launchOptions, @"application_did_finish");
    NSDictionary *forwardedOptions = amproj_launchOptionsForNativeAppDelegate(launchOptions);
    IMP original = amproj_didFinishForwardDepth
        ? amproj_originalHookForReceiverSkippingExact(
              amproj_didFinishHooks,
              sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]), self)
        : amproj_originalHookForReceiver(
              amproj_didFinishHooks,
              sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]), self);
    BOOL launched = YES;
    BOOL forwarded = NO;
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
    if (amproj_didFinishForwardDepth) return launched;
    amproj_debugEvent(@"import.did_finish_forward", @{
        @"has_original": @(forwarded),
        @"launch_result": @(launched),
        @"forwarded_project_url_removed": @(![forwardedOptions isEqual:launchOptions])
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        // Firebase may install its openURL proxy during AM's startup.
        amproj_installImportHook();
    });
    return launched;
}

static BOOL hooked_applicationContinueActivity(id self, SEL _cmd, UIApplication *application,
                                                NSUserActivity *activity,
                                                id restorationHandler) {
    NSURL *URL = amproj_projectURLFromUserActivity(activity);
    if (amproj_handleImportCommandURL(URL, @"continue_user_activity_command")) return YES;
    if (amproj_captureSystemProjectURL(URL, @"continue_user_activity", nil)) {
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
    if (original && original != (IMP)hooked_applicationContinueActivity) {
        amproj_activityForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationContinueActivityIMP)original)(
                self, _cmd, application, activity, restorationHandler);
        } @finally {
            amproj_activityForwardDepth -= 1;
        }
    }
    return nativeHandled;
}

static BOOL hooked_applicationHandleOpenURL(id self, SEL _cmd,
                                             UIApplication *application, NSURL *URL) {
    if (amproj_handleImportCommandURL(URL, @"application_handle_open_url_command")) return YES;
    if (amproj_captureSystemProjectURL(URL, @"application_handle_open_url", nil)) {
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
    if (original && original != (IMP)hooked_applicationHandleOpenURL) {
        amproj_handleOpenURLForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationHandleOpenURLIMP)original)(
                self, _cmd, application, URL);
        } @finally {
            amproj_handleOpenURLForwardDepth -= 1;
        }
    }
    return nativeHandled;
}

static BOOL hooked_applicationLegacyOpenURL(id self, SEL _cmd, UIApplication *application,
                                            NSURL *URL, NSString *sourceApplication,
                                            id annotation) {
    NSDictionary *options = sourceApplication.length
        ? @{@"source_application": sourceApplication} : nil;
    if (amproj_handleImportCommandURL(URL, @"application_legacy_open_url_command")) return YES;
    if (amproj_captureSystemProjectURL(URL, @"application_legacy_open_url", options)) {
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
    if (original && original != (IMP)hooked_applicationLegacyOpenURL) {
        amproj_legacyOpenURLForwardDepth += 1;
        @try {
            nativeHandled = ((AMProjApplicationLegacyOpenURLIMP)original)(
                self, _cmd, application, URL, sourceApplication, annotation);
        } @finally {
            amproj_legacyOpenURLForwardDepth -= 1;
        }
    }
    return nativeHandled;
}

static void hooked_sceneOpenURLContexts(id self, SEL _cmd, UIScene *scene,
                                        NSSet *URLContexts) {
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
    NSString *name = amproj_nativeImportRecognitionName ?: @"project.amproj";
    amproj_nativeImportAlertActive = YES;
    if (recognizedQueuedPackage) {
        objc_setAssociatedObject(self, &amproj_trackedProjectsImportAlertKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        amproj_waitingForNativeImportAlert = NO;
        amproj_nativeImportRecognitionName = nil;
        ++amproj_nativeImportRecognitionGeneration;
    }
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": recognizedQueuedPackage ? @"recognized" : @"unrelated",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"filename": recognizedQueuedPackage ? name : @""
    });
    if (recognizedQueuedPackage) {
        amproj_showImportStatus(
            @"AMProj v27 \u00b7 AM \u5df2\u8bc6\u522b\u9879\u76ee\u5305\uff0c\u8bf7\u786e\u8ba4\u5bfc\u5165\u5230\u201c\u9879\u76ee\u201d", NO);
    }
}

static void hooked_projectsImportAlertOnPressImport(id self, SEL _cmd, id sender) {
    BOOL tracked = amproj_isTrackedProjectsImportAlert(self);
    if (tracked) {
        amproj_setNativeImportObservationPhase(@"commit");
        objc_setAssociatedObject(self, &amproj_projectsImportActionKey, @"import",
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"import_pressed",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"tracked": @(tracked)
    });
    if (tracked) {
        amproj_showImportStatus(
            @"AMProj v27 \u00b7 AM \u6b63\u5728\u5bfc\u5165\u5230\u5e95\u90e8\u201c\u9879\u76ee\u201d", NO);
    }
    if (orig_projectsImportAlertOnPressImport) {
        orig_projectsImportAlertOnPressImport(self, _cmd, sender);
    }
}

static void hooked_projectsImportAlertOnPressCancel(id self, SEL _cmd, id sender) {
    if (amproj_isTrackedProjectsImportAlert(self)) {
        amproj_endNativeImportObservation();
        objc_setAssociatedObject(self, &amproj_projectsImportActionKey, @"cancel",
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"cancel_pressed",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"tracked": @(amproj_isTrackedProjectsImportAlert(self))
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
    amproj_nativeImportAlertActive = NO;
    BOOL tracked = amproj_isTrackedProjectsImportAlert(self);
    amproj_debugEvent(@"import.native_alert", @{
        @"phase": @"disappeared",
        @"class": NSStringFromClass([self class]) ?: @"",
        @"tracked": @(tracked)
    });
    if (tracked) {
        objc_setAssociatedObject(self, &amproj_trackedProjectsImportAlertKey, nil,
                                 OBJC_ASSOCIATION_ASSIGN);
    }
    NSString *action = objc_getAssociatedObject(self, &amproj_projectsImportActionKey);
    objc_setAssociatedObject(self, &amproj_projectsImportActionKey, nil,
                             OBJC_ASSOCIATION_ASSIGN);
    if (!tracked || ![action isEqualToString:@"import"]) {
        if (tracked && amproj_nativeImportObservationActive) {
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
    return className.length && [className containsString:@"ShareProjectPackageVC"];
}

static BOOL amproj_isSharePackageControllerRecursive(UIViewController *controller,
                                                      NSUInteger depth,
                                                      NSMutableSet<NSValue *> *visited) {
    if (!controller || depth > 5) return NO;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return NO;
    [visited addObject:identity];
    if ([NSStringFromClass(controller.class) containsString:@"ShareProjectPackageVC"]) return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if (amproj_isSharePackageControllerRecursive(child, depth + 1, visited)) return YES;
    }
    if (controller.presentedViewController &&
        amproj_isSharePackageControllerRecursive(controller.presentedViewController,
                                                  depth + 1, visited)) return YES;
    return NO;
}

static BOOL amproj_isSharePackageController(UIViewController *controller) {
    return amproj_isSharePackageControllerRecursive(controller, 0, [NSMutableSet set]);
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
    BOOL isPackageExport = amproj_hasSupportedItem(activityItems) &&
        (amproj_hasPackageController(controllerClasses) ||
#if AMPROJ_DEBUG
         atomic_load(&amproj_packageFlowActive)
#else
         amproj_packageFlowActive
#endif
        );
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

static BOOL amproj_isIPAFireWelcome(UIViewController *controller) {
    if (![controller isKindOfClass:[UIAlertController class]]) return NO;
    UIAlertController *alert = (UIAlertController *)controller;
    if (alert.preferredStyle != UIAlertControllerStyleAlert) return NO;
    NSString *content = [NSString stringWithFormat:@"%@\n%@", alert.title ?: @"", alert.message ?: @""];
    return [content containsString:@"@IPAFire"] &&
        ([content containsString:@"Channel Telegram"] ||
         [content containsString:@"شكراً لاستخدامك تطبيقاتنا"]);
}

// A self-signed build can leave StoreKit's SwiftUI paywall in an indefinite
// loading state before any accessibility strings are exposed. Keep a short
// startup-only fallback window so normal, intentionally opened subscription
// screens are never treated as stuck pages.
static CFAbsoluteTime amproj_paywallStartupFallbackUntil = 0;

static void amproj_armPaywallStartupFallback(void) {
    if (![NSThread isMainThread]) return;
    if (amproj_paywallStartupFallbackUntil <= 0) {
        amproj_paywallStartupFallbackUntil = CFAbsoluteTimeGetCurrent() + 120.0;
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

static NSArray *amproj_paywallAccessibilityChildren(UIView *view) {
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
    NSArray *accessibilityElements = amproj_paywallAccessibilityChildren(view);
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
    NSArray *accessibilityElements = amproj_paywallAccessibilityChildren(view);
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
            if (accessibilityClose &&
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
}

// MARK: - Startup loading overlay bypass
// Runtime implementation from 跳过启动加载圈_代码.md.

static BOOL HideLoadingInView(UIView *view) {
    BOOL found = NO;
    if ([view isKindOfClass:UIActivityIndicatorView.class]) {
        view.alpha = 0.0;
        view.hidden = YES;
        found = YES;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (button.currentTitle.length > 0 || button.accessibilityLabel.length > 0) {
            view.alpha = 1.0;
            view.hidden = NO;
            [view.superview bringSubviewToFront:view];
            found = YES;
        }
    }
    NSArray<UIView *> *subviews = [view.subviews copy];
    for (UIView *subview in subviews) {
        found |= HideLoadingInView(subview);
    }
    return found;
}

static void SkipLoadingScreenOnce(void) {
    static int attempts = 0;
    if (attempts++ > 20) return;

    BOOL found = NO;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        found |= HideLoadingInView(window);
    }
    amproj_debugEvent(@"startup_loading.skip_pass", @{
        @"attempt": @(attempts),
        @"found": @(found)
    });

    if (!found) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            SkipLoadingScreenOnce();
        });
    }
}

static void SkipLoadingScreen(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        SkipLoadingScreenOnce();
    });
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

static void hooked_shareNCOnTapExport(id self, SEL _cmd, id sender) {
    UIViewController *shareController = [self isKindOfClass:UIViewController.class] ? self : nil;
    UIViewController *contentController = [self isKindOfClass:UINavigationController.class] ?
        ((UINavigationController *)self).topViewController : nil;
    NSInteger selectedRow = NSNotFound;
    BOOL hasSelectedRow = amproj_swiftIntegerIvar(contentController, @"selectedRow", &selectedRow);
    BOOL isProjectPackage = hasSelectedRow && selectedRow == 1;
    NSString *mode = amproj_exportMode();
    amproj_debugEvent(@"direct.export_button", @{
        @"mode": mode ?: @"",
        @"selected_row": hasSelectedRow ? @(selectedRow) : @(-1),
        @"package": @(isProjectPackage),
        @"controller": contentController ? NSStringFromClass(contentController.class) : @"",
        @"holder": @"not_accessed"
    });
    if (!isProjectPackage || [mode isEqualToString:@"observe"] || !shareController) {
        orig_shareNCOnTapExport(self, _cmd, sender);
        return;
    }
    NSString *title = amproj_currentProjectTitle(shareController);
    void (^fallbackAction)(void) = ^{
        amproj_allowOriginalPackagePresentation();
        orig_shareNCOnTapExport(self, _cmd, sender);
    };
    amproj_startDirectExport(shareController, nil, YES, nil, title, fallbackAction);
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

static void hooked_presentVC(id self, SEL _cmd, UIViewController *controller,
                             BOOL animated, void (^completion)(void)) {
    if (amproj_isIPAFireWelcome(controller)) {
        NSLog(@"[AMProjExport] Suppressed IPAFire welcome alert");
        amproj_debugEvent(@"popup.suppressed", @{@"fingerprint": @"IPAFire welcome"});
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
            @"AMProj v27 \u00b7 E40 \u00b7 %@", failureDescription], YES);
        amproj_flushDebugEvents();
        if (!bridgeHandled) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                amproj_resumeQueuedImports(@"native_import_failure");
            });
        }
    }

    NSString *mode = amproj_exportMode();
    if (amproj_bypassPackagePresentation && amproj_isSharePackageController(controller)) {
        amproj_bypassPackagePresentation = NO;
        amproj_debugEvent(@"direct.original_bypass", @{@"consumed": @YES});
        orig_presentVC(self, _cmd, controller, animated, completion);
        return;
    }
    if (amproj_isSharePackageController(controller) &&
        ![mode isEqualToString:@"observe"]) {
        amproj_startDirectExport(self, controller, animated, completion,
                                 nil, nil);
        return;
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
static id amproj_sceneWillConnectObserver = nil;

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
    Class cls = amproj_declaredAppDelegateClass();
    BOOL changed = NO;
    BOOL installed = amproj_installTrackedHook(
        cls, @selector(application:didFinishLaunchingWithOptions:),
        (IMP)hooked_applicationDidFinish, 4, amproj_didFinishHooks,
        sizeof(amproj_didFinishHooks) / sizeof(amproj_didFinishHooks[0]),
        &changed);
    if (changed) {
        NSLog(@"[AMProjExport] Cold-launch document hook %@ on %@",
              installed ? @"installed" : @"failed", NSStringFromClass(cls));
    }
    return installed;
}

static BOOL amproj_installDeclaredURLHooks(void) {
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

static void amproj_installSceneImportHook(id sceneDelegate) {
    if (!sceneDelegate) return;
    Class cls = object_getClass(sceneDelegate);
    SEL selector = NSSelectorFromString(@"scene:openURLContexts:");
    BOOL changed = NO;
    BOOL installed = amproj_installTrackedHook(
        cls, selector, (IMP)hooked_sceneOpenURLContexts, 4,
        amproj_sceneOpenURLHooks,
        sizeof(amproj_sceneOpenURLHooks) / sizeof(amproj_sceneOpenURLHooks[0]),
        &changed);
    if (changed) {
        amproj_debugEvent(@"import.scene_hook", @{
            @"installed": @(installed),
            @"class": NSStringFromClass(cls) ?: @""
        });
    }
}

static void amproj_installImportHook(void) {
    (void)amproj_installColdLaunchHook();
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
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class shareClass = NSClassFromString(@"AlightMotion.ShareNC");
        if (!shareClass) shareClass = objc_getClass("_TtC12AlightMotion7ShareNC");
        SEL selector = NSSelectorFromString(@"onTapExport:");
        Method method = class_getInstanceMethod(shareClass, selector);
        if (!method) {
            amproj_debugEvent(@"share_export.hook", @{
                @"installed": @NO,
                @"class": shareClass ? NSStringFromClass(shareClass) : @"",
                @"reason": shareClass ? @"selector_missing" : @"class_missing"
            });
            return;
        }
        IMP previous = amproj_installMethodHook(
            method, (IMP)hooked_shareNCOnTapExport, 3, @"ShareNC.onTapExport");
        if (previous) orig_shareNCOnTapExport = (void *)previous;
        amproj_debugEvent(@"share_export.hook", @{
            @"installed": @(previous != NULL),
            @"class": NSStringFromClass(shareClass) ?: @""
        });
    });
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
        amproj_installShareExportHook();

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
                amproj_writeNativeEventBreadcrumb(transactionID, event, enriched);
                amproj_debugEvent(event, enriched);
            });
        AMProjInstallNativePackageImportBridge();

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
                        @"AMProj v27 · 上次导入在 %@ 阶段中断，原项目包已保留，可重新打开重试",
                        interruptedStage], YES);
                }
            }
            amproj_purgeOldDirectExports();
            amproj_purgeOldImports();
            if (!amproj_hasDeferredLaunchImportCandidates()) {
                amproj_scanLocalImportInboxes(@"bootstrap", nil);
            } else {
                amproj_debugEvent(@"import.scan_deferred_priority", @{
                    @"reason": @"launch_candidate_pending"
                });
            }
#if AMPROJ_DEBUG
            [[AMDebugTransport shared] start];
            amproj_debugEvent(@"bootstrap.ready", @{@"trigger": startupTrigger});
#endif
            amproj_installExportHooks();
            amproj_armPaywallStartupFallback();
            amproj_schedulePaywallScan(nil, @"bootstrap");
        });
    });
}

__attribute__((constructor))
static void AMProjExportInit(void) {
    @autoreleasepool {
#if AMPROJ_DEBUG
        NSLog(@"[AMProjExport] ===== Loading v27-debug =====");
#else
        NSLog(@"[AMProjExport] ===== Loading v27 =====");
#endif

        // ObjC classes are registered before image constructors. Installing only
        // this AppDelegate hook here avoids touching UIApplication or UIKit UI.
        // Cold-launch document URLs are recorded only; reading waits until the
        // later authorized callback or the app-owned Documents/Inbox scan.
        (void)amproj_installColdLaunchHook();
        (void)amproj_installDeclaredURLHooks();

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        amproj_willLaunchObserver = [center
            addObserverForName:@"UIApplicationWillFinishLaunchingNotification"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            // Install only the app/scene delivery hooks here. UIKit presentation
            // hooks remain deferred until the app has finished launching. Do not
            // consume launchOptions here: notification URLs may lack the delegate
            // callback's temporary sandbox extension.
            amproj_installImportHook();
        }];
        amproj_didLaunchObserver = [center
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            amproj_bootstrapAfterLaunch(@"did_finish_launching");
            amproj_installImportHook();
        }];
        amproj_didBecomeActiveObserver = [center
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                        queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            amproj_bootstrapAfterLaunch(@"did_become_active");
            amproj_installImportHook();
            amproj_armPaywallStartupFallback();
            amproj_schedulePaywallScan(nil, @"did_become_active");
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
        }];
        if (@available(iOS 13.0, *)) {
            amproj_sceneWillConnectObserver = [center
                addObserverForName:@"UISceneWillConnectNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
                UIScene *scene = [notification.object isKindOfClass:UIScene.class]
                    ? notification.object : nil;
                amproj_installSceneImportHook(scene.delegate);
            }];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            amproj_bootstrapAfterLaunch(@"main_queue_fallback");
            amproj_installImportHook();
            amproj_armPaywallStartupFallback();
            amproj_schedulePaywallScan(nil, @"main_queue_fallback");
        });

        // The delayed task is safe during early process initialization and
        // implements the startup-loading bypass documented for this build.
        SkipLoadingScreen();
        NSLog(@"[AMProjExport] Hooks scheduled for launch, activation, and delayed fallback");
    }
}
