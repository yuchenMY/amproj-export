// MeowRotate3D.m — 猫鹤AM 三轴3D旋转 mod · Phase A 侦察版
//
// 背景: Bending Spoons 865 的静态类名/方法名被 BBAES 类混淆, 静态读不到明文,
//       但运行时全部解密。本 dylib 不改任何行为, 只做一件事:
//       当 "Move & Transform" 面板出现时, 采集运行时状态供后续实现用:
//         1. 面板 VC 及相关类的 runtime 方法表 (真名!) + ivar 表
//         2. 面板视图树 (类名/frame/UIControl target-action/手势/辅助功能)
//         3. 响应链/父链上方的编辑器 VC
//         4. KVC 探针: 模型对象上的 transform/rotation/orientation/... 键
//       结果: NSLog + 沙盒文件 + UIPasteboard + POST 后端(失败忽略)。
//
// 后续 Phase B (功能版) 将用这些真名实现 X/Y/Z 三轴旋转注入。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 私有 _UIGestureRecognizerTarget 的桩声明 (编译期合法调用运行时私有方法)
@interface AMGRTargetStub : NSObject
- (id)target;
- (SEL)action;
@end

// ============ 配置 ============
static NSString *const kUploadURL = @"https://am.ayakameow.cn/api/modlog";
static const int      kMaxDumpsPerSession = 8;   // 防刷屏
static const int      kMaxLogChars        = 1500000;

// ============ 全局 ============
static int      gDumpCount = 0;
static BOOL     gInstalled = NO;
static IMP      orig_viewDidAppear = NULL;
static IMP      orig_viewWillAppear = NULL;

#define AMLOG(fmt, ...) [gLog appendFormat:@"%@ " fmt "\n", [NSDate date], ##__VA_ARGS__]
static NSMutableString *gLog = nil;

// ============ 工具 ============

static NSString *AMDesc(id obj, NSUInteger cap) {
    if (!obj) return @"(nil)";
    @try {
        NSString *d = [obj description];
        if (d.length > cap) d = [[d substringToIndex:cap] stringByAppendingString:@"…"];
        return d;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"(desc异常 %@)", e.name];
    }
}

static NSString *AMFrame(CGRect f) {
    return [NSString stringWithFormat:@"(%.0f,%.0f %.0fx%.0f)", f.origin.x, f.origin.y, f.size.width, f.size.height];
}

static NSString *AMClsName(id obj) {
    if (!obj) return @"nil";
    return NSStringFromClass([obj class]);
}

// 运行时按"包含子串"找类 (绕过静态混淆)
static Class AMFindClassBySubstring(NSString *needle) {
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    Class found = nil;
    for (unsigned int i = 0; i < n; i++) {
        NSString *nm = NSStringFromClass(classes[i]);
        if ([nm containsString:needle]) { found = classes[i]; break; }
    }
    free(classes);
    return found;
}

// ============ 方法表 dump (运行时真名!) ============

static void AMDumpMethods(Class c, NSMutableString *out) {
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    [out appendFormat:@"  -- instance methods (%u) --\n", cnt];
    for (unsigned int i = 0; i < cnt && i < 400; i++) {
        SEL s = method_getName(ms[i]);
        char *ret = method_copyReturnType(ms[i]);
        unsigned int nargs = method_getNumberOfArguments(ms[i]);
        [out appendFormat:@"    [%d] %@  (ret=%s, args=%u)\n", i,
            NSStringFromSelector(s), ret ? ret : "?", nargs];
        if (ret) free(ret);
    }
    if (ms) free(ms);
    cnt = 0;
    Method *cms = class_copyMethodList(object_getClass(c), &cnt);
    if (cnt) {
        [out appendFormat:@"  -- class methods (%u) --\n", cnt];
        for (unsigned int i = 0; i < cnt && i < 200; i++) {
            [out appendFormat:@"    [+] %@\n", NSStringFromSelector(method_getName(cms[i]))];
        }
    }
    if (cms) free(cms);
}

// ============ ivar dump (只取对象型, 防崩溃) ============

static void AMDumpIvars(id obj, NSMutableString *out, BOOL fetchValues) {
    Class c = [obj class];
    unsigned int cnt = 0;
    Ivar *ivs = class_copyIvarList(c, &cnt);
    [out appendFormat:@"  -- ivars of %@ (%u) --\n", AMClsName(obj) ?: @"?", cnt];
    for (unsigned int i = 0; i < cnt; i++) {
        const char *nm = ivar_getName(ivs[i]);
        const char *ty = ivar_getTypeEncoding(ivs[i]);
        [out appendFormat:@"    %@ : %s", nm ? @(nm) : @"?", ty ? ty : "?"];
        if (fetchValues && ty && ty[0] == '@') {
            @try {
                id v = object_getIvar(obj, ivs[i]);
                if (v) [out appendFormat:@"  = <%@> %@", AMClsName(v), AMDesc(v, 160)];
            } @catch (NSException *e) {}
        }
        [out appendString:@"\n"];
    }
    if (ivs) free(ivs);
}

// ============ 视图树 dump ============

static int gViewNodes = 0;

static void AMDumpView(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 14 || gViewNodes > 1500) return;
    gViewNodes++;
    NSString *ind = [@"                                                   " substringToIndex:MIN(depth * 2, 50)];
    [out appendFormat:@"%@%@ %@ hidden=%d alpha=%.2f", ind, AMClsName(v), AMFrame(v.frame),
        v.isHidden, v.alpha];
    if ([v.accessibilityLabel length]) [out appendFormat:@" a11y=\"%@\"", v.accessibilityLabel];
    if ([v.accessibilityIdentifier length]) [out appendFormat:@" id=%@", v.accessibilityIdentifier];
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) [out appendFormat:@" text=\"%@\"", [t substringToIndex:MIN(t.length, 60)]];
    }
    if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)v titleForState:UIControlStateNormal] ?: @"";
        if (t.length) [out appendFormat:@" btn=\"%@\"", t];
    }
    [out appendString:@"\n"];

    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *ctl = (UIControl *)v;
        for (id tgt in ctl.allTargets) {
            for (NSString *act in [ctl actionsForTarget:tgt forControlEvent:UIControlEventTouchUpInside]) {
                [out appendFormat:@"%@   ^ target=%@ action=%@ (UpInside)\n", ind, AMClsName(tgt), act];
            }
            for (NSString *act in [ctl actionsForTarget:tgt forControlEvent:UIControlEventValueChanged]) {
                [out appendFormat:@"%@   ^ target=%@ action=%@ (ValueChanged)\n", ind, AMClsName(tgt), act];
            }
            for (NSString *act in [ctl actionsForTarget:tgt forControlEvent:UIControlEventTouchDown]) {
                [out appendFormat:@"%@   ^ target=%@ action=%@ (TouchDown)\n", ind, AMClsName(tgt), act];
            }
        }
    }
    for (UIGestureRecognizer *g in v.gestureRecognizers ?: @[]) {
        // _UIGestureRecognizerTarget 私有类, 用桩接口声明拿 target/action
        id grTargets = nil; @try { grTargets = [g valueForKey:@"targets"]; } @catch (NSException *e) {}
        for (id inv in grTargets ?: @[]) {
            @try {
                AMGRTargetStub *stub = (AMGRTargetStub *)inv;
                id tgt = [stub target];
                SEL act = [stub action];
                [out appendFormat:@"%@   ~ gesture %@ target=%@ action=%@\n", ind,
                    AMClsName(g), AMClsName(tgt), act ? NSStringFromSelector(act) : @"?"];
            } @catch (NSException *e) {}
        }
    }
    for (UIView *sub in v.subviews) AMDumpView(sub, depth + 1, out);
}

// ============ KVC 探针 ============

static NSArray<NSString *> *AMModelKeys(void) {
    static NSArray *k = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = @[@"transform", @"rotation", @"orientation", @"location", @"pivot", @"scale",
              @"skew", @"opacity", @"angle", @"selectedLayer", @"selection", @"layer",
              @"layers", @"scene", @"document", @"editor", @"keyframes", @"value",
              @"model", @"item", @"panel", @"dataSource", @"viewModel"];
    });
    return k;
}

static int gProbeDepth = 0;

static void AMProbeKVC(id obj, NSMutableString *out, int depth) {
    if (!obj || depth > 2 || gProbeDepth > 400) return;
    gProbeDepth++;
    for (NSString *key in AMModelKeys()) {
        @try {
            if (![obj respondsToSelector:@selector(valueForKey:)]) continue;
            id v = [obj valueForKey:key];
            if (!v || v == obj || v == [NSNull null]) continue;
            if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]] ||
                [v isKindOfClass:[NSValue class]]) {
                [out appendFormat:@"  KVC %@.%@ = %@\n", AMClsName(obj), key, v];
            } else if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSDictionary class]]) {
                [out appendFormat:@"  KVC %@.%@ = <%@ count=%lu> %@\n", AMClsName(obj), key,
                    AMClsName(v), (unsigned long)[(NSArray *)v count], AMDesc(v, 120)];
            } else if (![v isKindOfClass:[UIView class]] && ![v isKindOfClass:[UIColor class]]) {
                [out appendFormat:@"  KVC %@.%@ -> <%@>\n", AMClsName(obj), key, AMClsName(v)];
                if (depth < 1) AMProbeKVC(v, out, depth + 1);
            }
        } @catch (NSException *e) {
            // valueForKey 不认识该键 -> 正常, 忽略
        }
    }
    gProbeDepth--;
}

// ============ 响应链 / 父链 ============

static void AMDumpChain(UIViewController *vc, NSMutableString *out) {
    [out appendString:@"=== responder/parent chain ===\n"];
    int i = 0;
    for (UIResponder *r = vc; r && i < 12; r = [r nextResponder], i++) {
        [out appendFormat:@"  [%d] %@\n", i, AMClsName(r)];
        if ([r isKindOfClass:[UIViewController class]]) {
            AMDumpIvars(r, out, NO);
        }
    }
}

// ============ 相关类全量扫描 ============

static void AMDumpRelatedClasses(NSMutableString *out) {
    NSArray *needles = @[@"TransformPanel", @"TransformInspector", @"Rotation", @"Orientation",
                         @"TransformRow", @"TransformCell", @"AngleRow", @"TransformView",
                         @"LayerTransform", @"Transform3D", @"Rotate3D"];
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    [out appendFormat:@"\n=== related classes (of %u) ===\n", n];
    int listed = 0;
    for (unsigned int i = 0; i < n && listed < 40; i++) {
        NSString *nm = NSStringFromClass(classes[i]);
        BOOL hit = NO;
        for (NSString *nd in needles) if ([nm containsString:nd]) { hit = YES; break; }
        if (!hit) continue;
        // 只对猫鹤主模块 + UI 相关的展开方法表, 避免日志爆炸
        BOOL expand = [nm hasPrefix:@"_TtC12AlightMotion"] || [nm hasPrefix:@"AlightMotion"];
        [out appendFormat:@"\n-- CLASS %@ --\n", nm];
        if (expand) AMDumpMethods(classes[i], out);
        listed++;
    }
    free(classes);
}

// ============ HUD ============

static void AMShowHUD(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) { win = [(UIWindowScene *)sc keyWindow]; break; }
        }
        if (!win) return;
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, win.bounds.size.width - 40, 34)];
        lb.text = msg; lb.textColor = UIColor.whiteColor; lb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        lb.font = [UIFont systemFontOfSize:13]; lb.textAlignment = NSTextAlignmentCenter;
        lb.layer.cornerRadius = 8; lb.clipsToBounds = YES; lb.tag = 0x4D4533; // 'ME3'
        [win addSubview:lb];
        [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{ lb.alpha = 0; }
                          completion:^(BOOL f){ [lb removeFromSuperview]; }];
    });
}

// ============ 采集与输出 ============

static void AMTransmit(NSString *text) {
    // 1) 剪贴板 (用户直接粘贴回来)
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    @try { [pb setString:[text substringToIndex:MIN(text.length, 900000)]]; } @catch (NSException *e) {}
    // 2) 沙盒文件
    @try {
        NSString *path = [NSTemporaryDirectory() stringByAppendingFormat:@"meow3d_dump_%d.txt", gDumpCount];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
    // 3) 后端 (失败忽略)
    @try {
        NSURL *u = [NSURL URLWithString:kUploadURL];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
        req.HTTPMethod = @"POST"; req.timeoutInterval = 8;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"tag": @"meow3d", @"n": @(gDumpCount), @"log": [text substringToIndex:MIN(text.length, 400000)] } options:0 error:NULL];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                         completionHandler:^(id d, id r, id e){}] resume];
    } @catch (NSException *e) {}
}

static void AMDumpPanel(id panelVC) {
    if (gDumpCount >= kMaxDumpsPerSession) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    static NSTimeInterval last = 0;
    if (now - last < 2.0) return;
    last = now;
    gDumpCount++;
    gLog = [NSMutableString string];
    gViewNodes = 0; gProbeDepth = 0;

    @try {
        AMLOG("=== MeowRotate3D recon dump #%d ===", gDumpCount);
        AMLOG("panel=%@ base=%@", AMClsName(panelVC), AMClsName([(UIViewController *)panelVC superclass]));

        // 1. 面板 VC 方法表 + ivar (带值)
        [gLog appendFormat:@"\n=== panel class methods ===\n"];
        AMDumpMethods([panelVC class], gLog);
        [gLog appendString:@"\n=== panel ivars ===\n"];
        AMDumpIvars(panelVC, gLog, YES);

        // 2. 视图树
        gViewNodes = 0;
        [gLog appendString:@"\n=== view tree ===\n"];
        AMDumpView([(UIViewController *)panelVC view], 0, gLog);

        // 3. 响应链
        AMDumpChain(panelVC, gLog);

        // 4. KVC 探针 (面板自身 + 其 ivar 里的对象)
        [gLog appendString:@"\n=== KVC probes ===\n"];
        gProbeDepth = 0;
        AMProbeKVC(panelVC, gLog, 0);
        unsigned int cnt = 0;
        Ivar *ivs = class_copyIvarList([panelVC class], &cnt);
        for (unsigned int i = 0; i < cnt; i++) {
            const char *ty = ivar_getTypeEncoding(ivs[i]);
            if (!ty || ty[0] != '@') continue;
            @try {
                id v = object_getIvar(panelVC, ivs[i]);
                if (v && ![v isKindOfClass:[UIView class]] && ![v isKindOfClass:[NSString class]]) {
                    gProbeDepth = 0;
                    AMProbeKVC(v, gLog, 0);
                }
            } @catch (NSException *e) {}
        }
        if (ivs) free(ivs);

        // 5. 相关类方法表扫描
        AMDumpRelatedClasses(gLog);

        [gLog appendFormat:@"\n=== end dump #%d (%lu chars) ===\n", gDumpCount, (unsigned long)gLog.length];
    } @catch (NSException *e) {
        AMLOG("!!! dump exception: %@ %@", e.name, e.reason);
    }

    NSString *text = gLog;
    gLog = nil;
    NSLog(@"[Meow3D]\n%@", text);
    AMTransmit(text);
    AMShowHUD([NSString stringWithFormat:@"猫鹤3D: 已采集 #%d (%lu 字符, 已进剪贴板)", gDumpCount, (unsigned long)text.length]);
}

// ============ hooks ============

static void hook_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_viewDidAppear) ((void(*)(id,SEL,BOOL))orig_viewDidAppear)(self, _cmd, animated);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AMDumpPanel(self);
    });
}

static void hook_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_viewWillAppear) ((void(*)(id,SEL,BOOL))orig_viewWillAppear)(self, _cmd, animated);
    // 出现前先记一笔 (有些面板每次进入会重建)
    NSLog(@"[Meow3D] panel willAppear: %@", AMClsName(self));
}

// ============ 安装 ============

static void AMInstall(void) {
    if (gInstalled) return;
    gInstalled = YES;

    Class panel = NSClassFromString(@"_TtC12AlightMotion23MoveAndTransformPanelVC");
    if (!panel) panel = AMFindClassBySubstring(@"MoveAndTransformPanelVC");
    NSLog(@"[Meow3D] panel class = %@", panel);

    if (panel) {
        Method m1 = class_getInstanceMethod(panel, @selector(viewDidAppear:));
        if (m1) { orig_viewDidAppear = method_getImplementation(m1); method_setImplementation(m1, (IMP)hook_viewDidAppear); }
        Method m2 = class_getInstanceMethod(panel, @selector(viewWillAppear:));
        if (m2) { orig_viewWillAppear = method_getImplementation(m2); method_setImplementation(m2, (IMP)hook_viewWillAppear); }
    }
    NSLog(@"[Meow3D] installed. dumps capped at %d", kMaxDumpsPerSession);
}

__attribute__((constructor))
static void MeowRotate3DInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { AMInstall(); } @catch (NSException *e) { NSLog(@"[Meow3D] install exception %@", e); }
    });
}
