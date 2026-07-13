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

// Forward declarations
static NSString* amproj_serializeLayer(id layer);
static NSString* amproj_tagForType(NSString *type);

// ═══════════════════════════════════════════
// MARK: - ZIP Creator
// ═══════════════════════════════════════════

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
        uint32_t cs = (uint32_t)d.length, us = cs, lo = (uint32_t)z.length;
        [z appendBytes:"PK\3\4" length:4];
        w16(20);w16(0);w16(0);w16(0);w16(0);
        w32(0);w32(cs);w32(us);
        w16((uint16_t)n.length);w16(0);
        [z appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
        [z appendData:d];
        [cd addObject:@{@"n":n,@"o":@(lo),@"cs":@(cs),@"us":@(us)}];
    }

    uint32_t cds = (uint32_t)z.length;
    for (NSDictionary *e in cd) {
        NSString *n = e[@"n"];
        uint32_t lo=[e[@"o"] unsignedIntValue], cs=[e[@"cs"] unsignedIntValue], us=[e[@"us"] unsignedIntValue];
        [z appendBytes:"PK\1\2" length:4];
        w16(20);w16(20);w16(0);w16(0);w16(0);w16(0);
        w32(0);w32(cs);w32(us);
        w16((uint16_t)n.length);w16(0);w16(0);
        w16(0);w16(0);w32(0);w32(lo);
        [z appendData:[n dataUsingEncoding:NSUTF8StringEncoding]];
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
    SEL sel = NSSelectorFromString(key);
    if ([obj respondsToSelector:sel]) {
        @try { return ((id(*)(id,SEL))objc_msgSend)(obj, sel); } @catch(NSException *e){}
    }
    @try { return [obj valueForKey:key]; } @catch(NSException *e){}
    // ivar fallback
    unsigned int count;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *n = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
        if ([n isEqualToString:key] || [n isEqualToString:[@"_" stringByAppendingString:key]]) {
            @try { id v = object_getIvar(obj, ivars[i]); free(ivars); return v; }
            @catch(NSException *e){}
        }
    }
    free(ivars);
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

static id am_findScene(id obj, int depth) {
    if (!obj || depth > 4) return nil;
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
            [n.lowercaseString containsString:@"project"]) {
            @try {
                id v = [obj valueForKey:n];
                if (v) { id f = am_findScene(v, depth+1); if (f) { free(props); return f; } }
            } @catch(NSException *e){}
        }
    }
    free(props);

    unsigned int ic;
    Ivar *ivars = class_copyIvarList([obj class], &ic);
    for (unsigned int i = 0; i < ic; i++) {
        NSString *ivn = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
        if ([ivn.lowercaseString containsString:@"scene"]) {
            @try {
                id v = object_getIvar(obj, ivars[i]);
                if (v) { id f = am_findScene(v, depth+1); if (f) { free(ivars); return f; } }
            } @catch(NSException *e){}
        }
    }
    free(ivars);
    return nil;
}

// ─── XML 构建 ───

static NSData* amproj_buildXML(id sceneInfo) {
    if (!sceneInfo) return nil;
    @try {
        NSMutableString *x = [NSMutableString string];
        [x appendString:@"<?xml version='1.0' encoding='UTF-8' ?>\n"];

        NSString *title = am_str(sceneInfo, @"title") ?: @"Exported Project";
        NSInteger w = am_int(sceneInfo, @"width") ?: 1280;
        NSInteger h = am_int(sceneInfo, @"height") ?: 720;
        NSInteger fps = am_int(sceneInfo, @"fps") ?: 60;
        NSInteger tt = am_int(sceneInfo, @"totalTime") ?: 5000;
        NSString *bg = am_str(sceneInfo, @"bgcolor") ?: @"#ff000000";

        [x appendFormat:@"<scene title=\"%@\" width=\"%ld\" height=\"%ld\" "
                          "exportWidth=\"%ld\" exportHeight=\"%ld\" "
                          "fps=\"%ld\" totalTime=\"%ld\" bgcolor=\"%@\">\n",
                          title, (long)w, (long)h, (long)w, (long)h, (long)fps, (long)tt, bg];

        // 序列化 layers
        NSArray *layers = am_arr(sceneInfo, @"layers");
        if (layers) {
            for (id layer in layers) {
                NSString *lx = amproj_serializeLayer(layer);
                if (lx) [x appendString:lx];
            }
        }

        // 序列化 media
        NSArray *media = am_arr(sceneInfo, @"media");
        if (media) {
            for (id m in media) {
                [x appendFormat:@"<media uri=\"%@\" filename=\"%@\" type=\"%@\" />\n",
                    am_str(m, @"uri") ?: @"",
                    am_str(m, @"filename") ?: @"",
                    am_str(m, @"mediaType") ?: @""];
            }
        }

        [x appendString:@"</scene>\n"];
        return [x dataUsingEncoding:NSUTF8StringEncoding];
    } @catch (NSException *e) {
        NSLog(@"[AMProjExport] XML build error: %@", e);
        return nil;
    }
}

static NSString* amproj_serializeLayer(id layer) {
    if (!layer) return nil;
    @try {
        NSString *type = am_str(layer, @"layerType") ?:
                          am_str(layer, @"type") ?: @"shape";
        NSInteger lid = am_int(layer, @"id");
        NSString *label = am_str(layer, @"label") ?: @"";
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
        if (fillType) [l appendFormat:@" fillType=\"%@\"", fillType];
        NSString *blending = am_str(layer, @"blending");
        if (blending) [l appendFormat:@" blending=\"%@\"", blending];

        // shape specific
        NSString *shapeType = am_str(layer, @"shapeType") ?: am_str(layer, @"s");
        if (shapeType) [l appendFormat:@" s=\"%@\"", shapeType];
        CGFloat speed = am_flt(layer, @"speed");
        if (speed > 0 && speed != 1.0) [l appendFormat:@" speed=\"%g\"", speed];

        // text specific
        NSString *font = am_str(layer, @"font");
        if (font) [l appendFormat:@" font=\"%@\"", font];
        CGFloat fontSize = am_flt(layer, @"size");
        if (fontSize > 0) [l appendFormat:@" size=\"%g\"", fontSize];
        NSString *align = am_str(layer, @"align");
        if (align) [l appendFormat:@" align=\"%@\"", align];
        CGFloat wrap = am_flt(layer, @"wrapWidth");
        if (wrap > 0) [l appendFormat:@" wrapWidth=\"%g\"", wrap];

        [l appendString:@">\n"];

        // transform
        id xf = am_get(layer, @"transform");
        if (xf) {
            [l appendString:@"<transform>\n"];
            NSString *loc = am_str(xf, @"locationValue") ?: am_str(xf, @"location");
            if (loc) [l appendFormat:@"<location value=\"%@\" />\n", loc];
            NSString *piv = am_str(xf, @"pivotValue") ?: am_str(xf, @"pivot");
            if (piv) [l appendFormat:@"<pivot value=\"%@\" />\n", piv];
            CGFloat rot = am_flt(xf, @"rotation") ?: am_flt(xf, @"rotationValue");
            [l appendFormat:@"<rotation value=\"%g\" />\n", rot];
            NSString *scl = am_str(xf, @"scaleValue") ?: am_str(xf, @"scale");
            [l appendFormat:@"<scale value=\"%@\" />\n", scl ?: @"1.0,1.0"];
            CGFloat op = am_flt(xf, @"opacity") ?: am_flt(xf, @"opacityValue") ?: 1.0;
            [l appendFormat:@"<opacity value=\"%g\" />\n", op];
            [l appendString:@"</transform>\n"];
        }

        // fillColor
        NSString *fc = am_str(layer, @"fillColor");
        if (fc) [l appendFormat:@"<fillColor value=\"%@\" />\n", fc];

        // content (text)
        NSString *content = am_str(layer, @"content");
        if (content) [l appendFormat:@"<content>%@</content>\n", content];

        // effects
        NSArray *effects = am_arr(layer, @"effects");
        if (effects) {
            for (id eff in effects) {
                NSString *eid = am_str(eff, @"id") ?: am_str(eff, @"effectId") ?: @"";
                BOOL local = [am_get(eff, @"locallyApplied") boolValue];
                [l appendFormat:@"<effect id=\"%@\"%@>\n", eid, local ? @" locallyApplied=\"true\"" : @""];
                NSArray *props = am_arr(eff, @"properties");
                for (id p in props) {
                    [l appendFormat:@"<property name=\"%@\" type=\"%@\" value=\"%@\" />\n",
                        am_str(p, @"name") ?: @"",
                        am_str(p, @"type") ?: am_str(p,@"propType") ?: @"float",
                        am_str(p, @"value") ?: @""];
                }
                [l appendString:@"</effect>\n"];
            }
        }

        // path
        NSString *pathD = am_str(layer, @"pathData") ?: am_str(layer, @"d");
        if (pathD) [l appendFormat:@"<path d=\"%@\" />\n", pathD];

        // gradient
        id grad = am_get(layer, @"gradient");
        if (grad) {
            [l appendFormat:@"<gradient type=\"%@\" startColor=\"%@\" endColor=\"%@\" />\n",
                am_str(grad, @"gradientType") ?: @"linear",
                am_str(grad, @"startColor") ?: @"#ff000000",
                am_str(grad, @"endColor") ?: @"#ffffffff"];
        }

        // stroke
        id stroke = am_get(layer, @"stroke") ?: am_get(layer, @"pathStroke");
        if (stroke) {
            [l appendFormat:@"<path-stroke direction=\"%@\">",
                am_str(stroke, @"direction") ?: @"center"];
            NSString *sc = am_str(stroke, @"colorValue") ?: am_str(stroke, @"color");
            if (sc) [l appendFormat:@"<color value=\"%@\" />", sc];
            [l appendString:@"</path-stroke>\n"];
        }

        // nested scene
        if ([tag isEqualToString:@"embedScene"]) {
            id nested = am_get(layer, @"scene");
            if (nested) {
                NSData *nx = amproj_buildXML(nested);
                if (nx) [l appendString:[[NSString alloc] initWithData:nx encoding:NSUTF8StringEncoding]];
            }
        }

        [l appendFormat:@"</%@>\n", tag];
        return l;
    } @catch (NSException *e) {
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

static BOOL amproj_isPackageExport = NO;

// 原始 initWithActivityItems:
static id (*orig_initWithItems)(id, SEL, NSArray *, NSArray *) = NULL;

static id hooked_initWithItems(id self, SEL _cmd, NSArray *activityItems,
                                NSArray *applicationActivities) {
    // 检查: 当前 items 是否包含图片 (项目包导出目前输出 PNG)
    // 且当前调用栈是否来自 ShareProjectPackageVC
    BOOL isPkgExport = NO;

    if (amproj_isPackageExport) {
        isPkgExport = YES;
        amproj_isPackageExport = NO; // reset
    }

    // 检查 items 内容: 如果全部是 UIImage/NSData(图片)/NSURL(图片),
    // 并且当前 VC 名称包含 Package/Share, 则认为是项目包导出
    if (!isPkgExport) {
        BOOL hasImageItem = NO;
        for (id item in activityItems) {
            if ([item isKindOfClass:[UIImage class]]) { hasImageItem = YES; break; }
        }
        if (hasImageItem) {
            // 检查 presenting VC
            UIViewController *top = nil;
            @try {
                UIWindow *win = nil;
                if (@available(iOS 13.0, *)) {
                    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                        if ([s isKindOfClass:[UIWindowScene class]] &&
                            s.activationState == UISceneActivationStateForegroundActive) {
                            for (UIWindow *w in ((UIWindowScene *)s).windows)
                                if (w.isKeyWindow) { win = w; break; }
                        }
                    }
                }
                if (!win) win = [UIApplication sharedApplication].keyWindow;
                top = win.rootViewController;
                while (top.presentedViewController) top = top.presentedViewController;
            } @catch (NSException *e) {}

            // 如果当前最顶层 VC 在被替换前是 project package VC
            // 或者之前的某个 VC 包含 Package
            UIViewController *check = top;
            while (check) {
                NSString *cn = NSStringFromClass([check class]);
                if ([cn containsString:@"Package"] || [cn containsString:@"ShareProject"]) {
                    isPkgExport = YES;
                    break;
                }
                check = check.presentingViewController;
            }
        }
    }

    if (isPkgExport) {
        NSLog(@"[AMProjExport] === Detected project package export! ===");
        NSLog(@"[AMProjExport] Original items: %lu", (unsigned long)activityItems.count);

        // 生成 .amproj 替换原来的图片
        NSData *amprojData = nil;

        @try {
            // 尝试找到 scene 数据
            id sceneInfo = nil;

            // 从 app delegate 递归查找
            id delegate = [UIApplication sharedApplication].delegate;
            if (delegate) sceneInfo = am_findScene(delegate, 0);

            // 构建 XML
            NSData *xmlData = nil;
            if (sceneInfo) {
                xmlData = amproj_buildXML(sceneInfo);
            }
            if (!xmlData || xmlData.length < 200) {
                xmlData = amproj_placeholderXML();
            }
            NSLog(@"[AMProjExport] XML: %lu bytes", (unsigned long)xmlData.length);

            // ZIP
            amprojData = amproj_createZIP(xmlData, @{});

        } @catch (NSException *e) {
            NSLog(@"[AMProjExport] Export failed: %@", e);
        }

        if (amprojData && amprojData.length > 100) {
            // 写临时文件
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"project_%@.amproj", [[NSUUID UUID] UUIDString]]];
            [amprojData writeToFile:tmp atomically:YES];
            NSLog(@"[AMProjExport] Saved: %@ (%lu bytes)", tmp, (unsigned long)amprojData.length);

            // 替换 items: 用 .amproj 文件 URL 替换原来的图片
            NSURL *url = [NSURL fileURLWithPath:tmp];
            activityItems = @[url];
        }
    }

    // 调用原始方法
    return orig_initWithItems(self, _cmd, activityItems, applicationActivities);
}

// ═══════════════════════════════════════════
// MARK: - 备选: 也 hook presentViewController 提前标记
// ═══════════════════════════════════════════

static void (*orig_presentVC)(id, SEL, id, BOOL, id);

static void hooked_presentVC(id self, SEL _cmd, id vc, BOOL animated, id completion) {
    // 检测是否即将 present 项目包导出的 UIActivityViewController
    NSString *vcClass = NSStringFromClass([vc class]);
    if ([vcClass isEqualToString:@"UIActivityViewController"]) {
        NSString *myClass = NSStringFromClass([self class]);
        if ([myClass containsString:@"Package"] || [myClass containsString:@"ShareProject"]) {
            amproj_isPackageExport = YES;
            NSLog(@"[AMProjExport] Package export VC detected: %@ -> UIActivityViewController", myClass);
        }
    }
    orig_presentVC(self, _cmd, vc, animated, completion);
}

// ═══════════════════════════════════════════
// MARK: - Constructor
// ═══════════════════════════════════════════

static id amproj_launchObserver = nil;

static void amproj_installHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[AMProjExport] Installing hooks after app launch");

        // Hook 1: UIActivityViewController 初始化 — 替换 items
        @try {
            Method m = class_getInstanceMethod(
                [UIActivityViewController class],
                @selector(initWithActivityItems:applicationActivities:));
            if (m) {
                orig_initWithItems = (void*)method_getImplementation(m);
                method_setImplementation(m, (IMP)hooked_initWithItems);
                NSLog(@"[AMProjExport] Hooked UIActivityViewController.init");
            }
        } @catch (NSException *e) {
            NSLog(@"[AMProjExport] Hook1 failed: %@", e);
        }

        // Hook 2: UIViewController.presentViewController — 提前标记
        @try {
            Method m2 = class_getInstanceMethod(
                [UIViewController class],
                @selector(presentViewController:animated:completion:));
            if (m2) {
                orig_presentVC = (void*)method_getImplementation(m2);
                method_setImplementation(m2, (IMP)hooked_presentVC);
                NSLog(@"[AMProjExport] Hooked UIViewController.presentViewController");
            }
        } @catch (NSException *e) {
            NSLog(@"[AMProjExport] Hook2 failed: %@", e);
        }

        NSLog(@"[AMProjExport] ===== Ready — waiting for package export =====");
    });
}

__attribute__((constructor))
static void AMProjExportInit(void) {
    @autoreleasepool {
        NSLog(@"[AMProjExport] ===== Loading v0.3 (deferred-hook mode) =====");

        // Do not touch UIKit class implementations while dyld is still running
        // initializers. UIApplication posts this notification on the main thread
        // after application:didFinishLaunchingWithOptions: has returned.
        amproj_launchObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *notification) {
            id observer = amproj_launchObserver;
            amproj_launchObserver = nil;
            if (observer) {
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                amproj_installHooks();
            });
        }];

        NSLog(@"[AMProjExport] Hook installation deferred until app launch completes");
    }
}
