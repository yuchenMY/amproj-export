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
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <zlib.h>
#import <stdatomic.h>
#import <string.h>
#import <math.h>

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

static void amproj_debugEvent(NSString *name, NSDictionary *fields) {
#if AMPROJ_DEBUG
    [[AMDebugTransport shared] emitEvent:name fields:fields ?: @{}];
#else
    (void)name;
    (void)fields;
#endif
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

// ═══════════════════════════════════════════
// MARK: - 核心: 劫持 UIActivityViewController
// ═══════════════════════════════════════════

static id (*orig_initWithItems)(id, SEL, NSArray *, NSArray *) = NULL;
static void (*orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;

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
static atomic_bool amproj_watchdogScheduled = false;
static atomic_bool amproj_mainStallReported = false;
static _Atomic(float) amproj_lastProgress = 0.0f;
static atomic_int amproj_currentPhase = AMProjDebugPhaseIdle;
static atomic_uint_fast64_t amproj_flowGeneration = 0;
static atomic_uint_fast64_t amproj_lastMainHeartbeatMs = 0;
static NSString *amproj_currentTransaction = nil;
static BOOL amproj_captureCurrentTransaction = NO;
static mach_port_t amproj_mainThread = MACH_PORT_NULL;
static dispatch_source_t amproj_heartbeatTimer = nil;

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
    atomic_store(&amproj_watchdogScheduled, false);
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
    atomic_store(&amproj_watchdogScheduled, false);
    amproj_setPhase(AMProjDebugPhaseComplete, @{@"result": result ?: @"finished"});
    if (amproj_currentTransaction) {
        [[AMDebugTransport shared] endExportTransaction:amproj_currentTransaction
                                                fields:@{@"result": result ?: @"finished"}];
    }
    amproj_currentTransaction = nil;
    amproj_captureCurrentTransaction = NO;
}

static void amproj_scheduleProgressWatchdog(void) {
    if (atomic_exchange(&amproj_watchdogScheduled, true)) return;
    uint64_t generation = atomic_load(&amproj_flowGeneration);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL stalled = atomic_load(&amproj_packageFlowActive) &&
                       atomic_load(&amproj_flowGeneration) == generation &&
                       atomic_load(&amproj_lastProgress) >= 0.98f;
        if (stalled) {
            AMProjDebugPhase phase = (AMProjDebugPhase)atomic_load(&amproj_currentPhase);
            amproj_debugEvent(@"export.stall", @{
                @"progress": @(atomic_load(&amproj_lastProgress)),
                @"phase": amproj_phaseName(phase),
                @"main_thread": amproj_mainThreadSnapshot()
            });
        }
        atomic_store(&amproj_watchdogScheduled, false);
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

static BOOL amproj_hasPackageController(NSArray<NSString*> *classes) {
    for (NSString *className in classes) {
        if ([className containsString:@"ShareProjectPackage"] ||
            [className containsString:@"ExportProjectPackage"]) return YES;
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
    NSData *amprojData = nil;
    if (isPackageExport && ![mode isEqualToString:@"observe"]) {
        @try {
            if ([mode isEqualToString:@"placeholder"]) {
                xmlData = amproj_placeholderXML();
            } else {
                amproj_setPhase(AMProjDebugPhaseSceneFind, @{});
                id delegate = [UIApplication sharedApplication].delegate;
                id sceneInfo = delegate ? am_findScene(delegate) : nil;
                amproj_debugEvent(@"scene_find.result", @{
                    @"found": @(sceneInfo != nil),
                    @"class": sceneInfo ? NSStringFromClass([sceneInfo class]) : @""
                });

                amproj_setPhase(AMProjDebugPhaseXML, @{@"scene_found": @(sceneInfo != nil)});
                if (sceneInfo) xmlData = amproj_buildXML(sceneInfo);
                if (!xmlData || xmlData.length < 200) xmlData = amproj_placeholderXML();
            }

            amproj_setPhase(AMProjDebugPhaseZIP, @{@"xml_bytes": @(xmlData.length)});
            amprojData = amproj_createZIP(xmlData, @{});
            amproj_debugEvent(@"zip.result", @{@"bytes": @(amprojData.length)});
        } @catch (NSException *exception) {
            NSLog(@"[AMProjExport] Export failed: %@", exception);
            amproj_debugEvent(@"export.exception", @{
                @"name": exception.name ?: @"",
                @"reason": exception.reason ?: @""
            });
        }

        if (amprojData.length > 100) {
            amproj_setPhase(AMProjDebugPhaseFileWrite, @{@"bytes": @(amprojData.length)});
            NSString *filename = [NSString stringWithFormat:@"project_%@.amproj", NSUUID.UUID.UUIDString];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
            NSError *writeError = nil;
            BOOL written = [amprojData writeToFile:path options:NSDataWritingAtomic error:&writeError];
            amproj_debugEvent(@"file_write.result", @{
                @"success": @(written),
                @"filename": filename,
                @"bytes": @(amprojData.length),
                @"error": writeError.localizedDescription ?: @""
            });
            if (written) activityItems = @[[NSURL fileURLWithPath:path]];

#if AMPROJ_DEBUG
            if (amproj_currentTransaction && amproj_captureCurrentTransaction) {
                [[AMDebugTransport shared] uploadArtifactData:xmlData
                                                         name:@"scene.xml"
                                                     mimeType:@"application/xml"
                                                  transaction:amproj_currentTransaction];
                [[AMDebugTransport shared] uploadArtifactData:amprojData
                                                         name:filename
                                                     mimeType:@"application/x-amproj"
                                                  transaction:amproj_currentTransaction];
            }
#endif
        }
    }

    amproj_setPhase(AMProjDebugPhaseOriginalInit, @{
        @"mode": mode,
        @"replacement": @(isPackageExport && ![mode isEqualToString:@"observe"] && amprojData.length > 100)
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

static void hooked_presentVC(id self, SEL _cmd, UIViewController *controller,
                             BOOL animated, void (^completion)(void)) {
    if (amproj_isIPAFireWelcome(controller)) {
        NSLog(@"[AMProjExport] Suppressed IPAFire welcome alert");
        amproj_debugEvent(@"popup.suppressed", @{@"fingerprint": @"IPAFire welcome"});
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
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
    return [NSStringFromClass([controller class]) containsString:@"ShareProjectPackageVC"];
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
    float previous = atomic_exchange(&amproj_lastProgress, progress);
    if (fabsf(previous - progress) < 0.0001f) return;
    amproj_debugEvent(@"export.progress", @{@"value": @(progress), @"source": source ?: @""});
    if (progress >= 0.98f) amproj_scheduleProgressWatchdog();
}

static void hooked_setProgressAnimated(id self, SEL _cmd, float progress, BOOL animated) {
    orig_setProgressAnimated(self, _cmd, progress, animated);
    amproj_recordProgress(progress, @"UIProgressView.animated");
}

static void hooked_setProgress(id self, SEL _cmd, float progress) {
    orig_setProgress(self, _cmd, progress);
    amproj_recordProgress(progress, @"UIProgressView");
}

static void hooked_labelSetText(id self, SEL _cmd, NSString *text) {
    orig_labelSetText(self, _cmd, text);
    if (atomic_load(&amproj_packageFlowActive) && [text containsString:@"%"] && text.length < 32) {
        amproj_debugEvent(@"export.progress_label", @{@"text": text});
        if ([text containsString:@"99%"] || [text containsString:@"100%"] ) {
            atomic_store(&amproj_lastProgress, [text containsString:@"100%"] ? 1.0f : 0.99f);
            amproj_scheduleProgressWatchdog();
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

__attribute__((constructor))
static void AMProjExportInit(void) {
    @autoreleasepool {
#if AMPROJ_DEBUG
        NSLog(@"[AMProjExport] ===== Loading v0.4-debug =====");
#else
        NSLog(@"[AMProjExport] ===== Loading v0.4 =====");
#endif

        amproj_didLaunchObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            id observer = amproj_didLaunchObserver;
            amproj_didLaunchObserver = nil;
            if (observer) [[NSNotificationCenter defaultCenter] removeObserver:observer];

#if AMPROJ_DEBUG
            if (amproj_mainThread == MACH_PORT_NULL) amproj_mainThread = mach_thread_self();
#endif
            // Install only the narrow alert/presentation filter synchronously.
            // Export and telemetry hooks wait until this launch callback unwinds.
            amproj_installPresentationHook();

            dispatch_async(dispatch_get_main_queue(), ^{
#if AMPROJ_DEBUG
                [[AMDebugTransport shared] start];
#endif
                amproj_installExportHooks();
            });
        }];

        NSLog(@"[AMProjExport] Hooks scheduled for application lifecycle notifications");
    }
}
