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

#if AMPROJ_DEBUG
#import "AMDebugTransport.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/arm/thread_status.h>
#endif

// Forward declarations
static NSData* amproj_buildXML(id sceneInfo);
static NSData* amproj_buildXMLInternal(id sceneInfo, NSMutableSet<NSValue*> *visited,
                                       NSUInteger depth, BOOL includeDeclaration);
static NSString* amproj_serializeLayer(id layer, NSMutableSet<NSValue*> *visited, NSUInteger depth);
static NSString* amproj_tagForType(NSString *type);
static UIWindow* amproj_keyWindow(void);
static NSURL* amproj_directExportRoot(void);
static BOOL amproj_handleIncomingProjectURL(NSURL *URL, NSString *source);

static void amproj_debugEvent(NSString *name, NSDictionary *fields) {
#if AMPROJ_DEBUG
    [[AMDebugTransport shared] emitEvent:name fields:fields ?: @{}];
#else
    (void)name;
    (void)fields;
#endif
}

static NSString* amproj_stageFilePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"AMProjExport.laststage"];
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
            if (!modified || [modified compare:cutoff] == NSOrderedAscending) {
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
static AMProjApplicationOpenURLIMP orig_applicationOpenURL = NULL;
static NSURL *amproj_pendingImportURL = nil;
static NSString *amproj_pendingImportName = nil;
static NSUInteger amproj_pendingImportGeneration = 0;
static CFAbsoluteTime amproj_pendingImportDeadline = 0;
static NSString *amproj_lastIncomingURLKey = nil;
static CFAbsoluteTime amproj_lastIncomingURLTime = 0;

static NSURL* amproj_importCacheRoot(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"AMProjImports" isDirectory:YES];
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
            if (!modified || [modified compare:cutoff] == NSOrderedAscending) {
                [manager removeItemAtURL:entry error:nil];
            }
        }
    });
}

static BOOL amproj_isIncomingProjectURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL) return NO;
    return [URL.pathExtension caseInsensitiveCompare:@"amproj"] == NSOrderedSame;
}

static UIViewController* amproj_findTemplatesControllerRecursive(
    UIViewController *controller, NSUInteger depth, NSMutableSet<NSValue *> *visited) {
    if (!controller || depth > 12) return nil;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return nil;
    [visited addObject:identity];

    SEL importSelector = NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:");
    NSString *className = NSStringFromClass(controller.class);
    if ([className containsString:@"TemplatesListVC"] &&
        [controller respondsToSelector:importSelector]) {
        return controller;
    }

    UIViewController *found = amproj_findTemplatesControllerRecursive(
        controller.presentedViewController, depth + 1, visited);
    if (found) return found;
    for (UIViewController *child in controller.childViewControllers) {
        found = amproj_findTemplatesControllerRecursive(child, depth + 1, visited);
        if (found) return found;
    }
    return nil;
}

static UIViewController* amproj_findTemplatesController(void) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *found = amproj_findTemplatesControllerRecursive(
                window.rootViewController, 0, visited);
            if (found) return found;
        }
    }

    UIWindow *delegateWindow = nil;
    id delegate = application.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        @try {
            delegateWindow = ((UIWindow *(*)(id, SEL))(void *)objc_msgSend)(delegate, @selector(window));
        } @catch (__unused NSException *exception) {
            delegateWindow = nil;
        }
    }
    return amproj_findTemplatesControllerRecursive(delegateWindow.rootViewController, 0, visited);
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

static void amproj_presentImportError(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = amproj_topViewController(amproj_keyWindow().rootViewController);
        if (!presenter || [presenter isKindOfClass:UIAlertController.class] ||
            presenter.presentedViewController) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"无法导入 .amproj"
                             message:message.length ? message : @"请返回 QQ 或文件 App 后重新打开项目包。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void amproj_tryDispatchPendingImport(NSUInteger generation) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != amproj_pendingImportGeneration || !amproj_pendingImportURL) return;

        UIApplication *application = UIApplication.sharedApplication;
        UIViewController *controller = application.applicationState == UIApplicationStateActive ?
            amproj_findTemplatesController() : nil;
        SEL selector = NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:");
        if (controller && [controller respondsToSelector:selector]) {
            NSURL *URL = amproj_pendingImportURL;
            NSString *name = amproj_pendingImportName ?: @"project.amproj";
            amproj_pendingImportURL = nil;
            amproj_pendingImportName = nil;
            amproj_debugEvent(@"import.dispatch", @{
                @"controller": NSStringFromClass(controller.class) ?: @"",
                @"filename": name,
                @"bridge_filename": URL.lastPathComponent ?: @""
            });
            @try {
                ((void (*)(id, SEL, id, NSArray *))(void *)objc_msgSend)(
                    controller, selector, nil, @[URL]);
                amproj_debugEvent(@"import.dispatched", @{@"success": @YES});
            } @catch (NSException *exception) {
                amproj_debugEvent(@"import.dispatched", @{
                    @"success": @NO,
                    @"exception": exception.name ?: @"",
                    @"reason": exception.reason ?: @""
                });
                amproj_presentImportError(@"Alight Motion 的原生导入入口调用失败，请重新打开项目包。");
            }
            return;
        }

        if (CFAbsoluteTimeGetCurrent() >= amproj_pendingImportDeadline) {
            NSString *name = amproj_pendingImportName ?: @"project.amproj";
            amproj_pendingImportURL = nil;
            amproj_pendingImportName = nil;
            amproj_debugEvent(@"import.controller_timeout", @{
                @"filename": name,
                @"selector_available": @(NSClassFromString(@"AlightMotion.TemplatesListVC") != Nil ||
                                           objc_getClass("_TtC12AlightMotion15TemplatesListVC") != Nil)
            });
            amproj_presentImportError(@"Alight Motion 的项目列表尚未加载，请进入项目列表后再从 QQ 或文件 App 打开一次。");
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            amproj_tryDispatchPendingImport(generation);
        });
    });
}

static void amproj_queuePreparedImport(NSURL *URL, NSString *originalName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        amproj_pendingImportURL = URL;
        amproj_pendingImportName = originalName.length ? originalName : @"project.amproj";
        amproj_pendingImportDeadline = CFAbsoluteTimeGetCurrent() + 60.0;
        NSUInteger generation = ++amproj_pendingImportGeneration;
        amproj_debugEvent(@"import.queued", @{
            @"filename": amproj_pendingImportName,
            @"wait_seconds": @60
        });
        amproj_tryDispatchPendingImport(generation);
    });
}

static BOOL amproj_handleIncomingProjectURL(NSURL *URL, NSString *source) {
    if (!amproj_isIncomingProjectURL(URL)) return NO;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *URLKey = URL.absoluteString ?: URL.path ?: @"";
    if (URLKey.length && [URLKey isEqualToString:amproj_lastIncomingURLKey] &&
        now - amproj_lastIncomingURLTime < 3.0) {
        amproj_debugEvent(@"import.duplicate", @{
            @"source": source ?: @"",
            @"filename": URL.lastPathComponent ?: @""
        });
        return YES;
    }
    amproj_lastIncomingURLKey = [URLKey copy];
    amproj_lastIncomingURLTime = now;

    NSString *originalName = URL.lastPathComponent ?: @"project.amproj";
    amproj_debugEvent(@"import.url_received", @{
        @"source": source ?: @"",
        @"filename": originalName,
        @"file_url": @YES
    });

    // Acquire the sandbox extension before the delegate callback returns.
    BOOL scoped = [URL startAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSError *error = nil;
        NSURL *root = amproj_importCacheRoot();
        NSURL *directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                                                 isDirectory:YES];
        if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                attributes:nil error:&error]) {
            if (scoped) [URL stopAccessingSecurityScopedResource];
            amproj_debugEvent(@"import.copy", @{
                @"success": @NO,
                @"scoped": @(scoped),
                @"error": error.localizedDescription ?: @"Unable to create import cache"
            });
            amproj_presentImportError(@"无法创建导入缓存，请检查设备剩余空间后重试。");
            return;
        }

        NSURL *destination = [directory URLByAppendingPathComponent:@"projectfiles.zip"];
        __block NSError *copyError = nil;
        __block BOOL copied = NO;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError = nil;
        [coordinator coordinateReadingItemAtURL:URL
                                        options:NSFileCoordinatorReadingWithoutChanges
                                          error:&coordinationError
                                     byAccessor:^(NSURL *coordinatedURL) {
            copied = [manager copyItemAtURL:coordinatedURL toURL:destination error:&copyError];
        }];
        if (!copied && !copyError) copyError = coordinationError;
        if (scoped) [URL stopAccessingSecurityScopedResource];

        NSNumber *fileSize = nil;
        if (copied) {
            [destination getResourceValue:&fileSize forKey:NSURLFileSizeKey error:&copyError];
            if (fileSize.unsignedLongLongValue == 0) {
                copied = NO;
                copyError = [NSError errorWithDomain:@"com.amproj.import"
                                                code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"Project package is empty"}];
            }
        }
        if (!copied) {
            [manager removeItemAtURL:directory error:nil];
            amproj_debugEvent(@"import.copy", @{
                @"success": @NO,
                @"scoped": @(scoped),
                @"error": copyError.localizedDescription ?: @"Unable to copy project package"
            });
            amproj_presentImportError(@"无法读取 QQ 或文件 App 提供的项目包，请返回后重新打开一次。");
            return;
        }

        amproj_debugEvent(@"import.copy", @{
            @"success": @YES,
            @"scoped": @(scoped),
            @"bytes": fileSize ?: @0,
            @"bridge_filename": destination.lastPathComponent ?: @""
        });
        amproj_queuePreparedImport(destination, originalName);
    });
    return YES;
}

static BOOL hooked_applicationOpenURL(id self, SEL _cmd, UIApplication *application,
                                      NSURL *URL, NSDictionary *options) {
    if (amproj_handleIncomingProjectURL(URL, @"application_open_url")) return YES;
    return orig_applicationOpenURL ?
        orig_applicationOpenURL(self, _cmd, application, URL, options) : NO;
}

static UIWindow* amproj_keyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
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
    return className.length && [className containsString:@"Package"];
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

static void hooked_presentVC(id self, SEL _cmd, UIViewController *controller,
                             BOOL animated, void (^completion)(void)) {
    if (amproj_isIPAFireWelcome(controller)) {
        NSLog(@"[AMProjExport] Suppressed IPAFire welcome alert");
        amproj_debugEvent(@"popup.suppressed", @{@"fingerprint": @"IPAFire welcome"});
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
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

static id amproj_didLaunchObserver = nil;
static id amproj_didBecomeActiveObserver = nil;

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

static void amproj_installImportHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class appDelegateClass = NSClassFromString(@"AlightMotion.AppDelegate");
        if (!appDelegateClass) {
            appDelegateClass = objc_getClass("_TtC12AlightMotion11AppDelegate");
        }
        SEL selector = @selector(application:openURL:options:);
        Method method = amproj_ownInstanceMethod(appDelegateClass, selector);
        if (!method) method = class_getInstanceMethod(appDelegateClass, selector);
        IMP previous = amproj_installMethodHook(
            method, (IMP)hooked_applicationOpenURL, 5, @"AppDelegate.application.openURL");
        if (previous) orig_applicationOpenURL = (AMProjApplicationOpenURLIMP)previous;
        amproj_debugEvent(@"import.hook", @{
            @"installed": @(previous != NULL),
            @"class": appDelegateClass ? NSStringFromClass(appDelegateClass) : @"",
            @"selector": NSStringFromSelector(selector)
        });
    });
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
    id didLaunch = amproj_didLaunchObserver;
    id didBecomeActive = amproj_didBecomeActiveObserver;
    amproj_didLaunchObserver = nil;
    amproj_didBecomeActiveObserver = nil;
    if (didLaunch) [center removeObserver:didLaunch];
    if (didBecomeActive) [center removeObserver:didBecomeActive];
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

        NSString *startupTrigger = [trigger copy] ?: @"unknown";
        dispatch_async(dispatch_get_main_queue(), ^{
            amproj_purgeOldDirectExports();
            amproj_purgeOldImports();
#if AMPROJ_DEBUG
            [[AMDebugTransport shared] start];
            amproj_debugEvent(@"bootstrap.ready", @{@"trigger": startupTrigger});
#endif
            amproj_installExportHooks();
        });
    });
}

__attribute__((constructor))
static void AMProjExportInit(void) {
    @autoreleasepool {
#if AMPROJ_DEBUG
        NSLog(@"[AMProjExport] ===== Loading v8-debug =====");
#else
        NSLog(@"[AMProjExport] ===== Loading v8 =====");
#endif

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        amproj_didLaunchObserver = [center
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            amproj_bootstrapAfterLaunch(@"did_finish_launching");
            NSURL *launchURL = [notification.userInfo objectForKey:UIApplicationLaunchOptionsURLKey];
            if ([launchURL isKindOfClass:NSURL.class]) {
                amproj_handleIncomingProjectURL(launchURL, @"launch_options");
            }
        }];
        amproj_didBecomeActiveObserver = [center
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            amproj_bootstrapAfterLaunch(@"did_become_active");
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            amproj_bootstrapAfterLaunch(@"main_queue_fallback");
        });

        NSLog(@"[AMProjExport] Hooks scheduled for launch, activation, and delayed fallback");
    }
}
