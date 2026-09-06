// MeowRotate3D.m — 猫鹤AM 三轴3D旋转 mod · Phase A3 侦察版(全Pad页强制挂钩)
//
// v1 战果: 运行时类名 = "AlightMotion.XXX" 新格式; 核心控件 AlightMotion.ValueSpinner;
//          面板页 = AlightMotion.*PadVC 家族 (ScalePadVC 已完整解剖)。
// v3 改进:
//   1. 不只 hook 面板容器: 扫描所有 AlightMotion.*PadVC/*PanelVC, 每个 Pad 页
//      都挂钩 (没有自己的 viewDidAppear/viewWillAppear/viewDidLoad 就用
//      class_addMethod 补一个调用 super 的), 保证旋转页一定能采到
//   2. dump 去重: 类的方法表/ivar 本会话只采一次
//   3. 树内/子VC/响应链上的 AlightMotion.* 类全部顺带采集
//   4. holder 等 ivar 对象递归 KVC 探查 (找 transform/orientation 模型)
//   5. ValueSpinner 实例带值采集 (value/delegate/target 绑定关系)
//   输出: NSLog + 沙盒文件 + UIPasteboard + POST 后端(失败忽略)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 私有 _UIGestureRecognizerTarget 的桩声明
@interface AMGRTargetStub : NSObject
- (id)target;
- (SEL)action;
@end

static NSString *const kUploadURL = @"https://am.ayakameow.cn/api/modlog";
static const int      kMaxDumpsPerSession = 24;

static int      gDumpCount = 0;
static BOOL     gInstalled = NO;
static NSMutableString *gLog = nil;
static NSMutableDictionary *gDumpedClasses;   // 类名 -> YES
static NSTimeInterval   gLastDumpAt = 0;

#define AMLOG(fmt, ...) [gLog appendFormat:@"%@ " fmt "\n", [NSDate date], ##__VA_ARGS__]

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

static BOOL AMIsModuleClass(NSString *nm) {
    return [nm hasPrefix:@"AlightMotion."] || [nm hasPrefix:@"_TtC12AlightMotion"] || [nm hasPrefix:@"_TtCV12AlightMotion"];
}

// ============ 方法表 / ivar ============

static void AMDumpMethods(Class c, NSMutableString *out) {
    unsigned int cnt = 0;
    Method *ms = class_copyMethodList(c, &cnt);
    [out appendFormat:@"  -- instance methods (%u) --\n", cnt];
    for (unsigned int i = 0; i < cnt && i < 500; i++) {
        char *ret = method_copyReturnType(ms[i]);
        [out appendFormat:@"    [%d] %@ (ret=%s)\n", i,
            NSStringFromSelector(method_getName(ms[i])), ret ? ret : "?"];
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

static void AMDumpIvars(id obj, NSMutableString *out, BOOL fetchValues) {
    Class c = [obj class];
    unsigned int cnt = 0;
    Ivar *ivs = class_copyIvarList(c, &cnt);
    [out appendFormat:@"  -- ivars of %@ (%u) --\n", AMClsName(obj), cnt];
    for (unsigned int i = 0; i < cnt; i++) {
        const char *nm = ivar_getName(ivs[i]);
        const char *ty = ivar_getTypeEncoding(ivs[i]);
        [out appendFormat:@"    %@ : %s", nm ? @(nm) : @"?", ty ? ty : "?"];
        if (fetchValues && ty && ty[0] == '@') {
            @try {
                id v = object_getIvar(obj, ivs[i]);
                if (v) [out appendFormat:@"  = <%@> %@", AMClsName(v), AMDesc(v, 220)];
            } @catch (NSException *e) {}
        }
        [out appendString:@"\n"];
    }
    if (ivs) free(ivs);
}

// 类级采集(去重)
static void AMDumpClassIfNew(Class c, NSMutableString *out) {
    if (!c) return;
    NSString *nm = NSStringFromClass(c);
    if (!AMIsModuleClass(nm)) return;
    if (gDumpedClasses[nm]) return;
    [gDumpedClasses setObject:@YES forKey:nm];
    [out appendFormat:@"\n#### CLASS %@ (super=%@) ####\n", nm, AMClsName([c superclass])];
    AMDumpMethods(c, out);
    unsigned int cnt = 0;
    Ivar *ivs = class_copyIvarList(c, &cnt);
    [out appendFormat:@"  -- ivars (%u) --\n", cnt];
    for (unsigned int i = 0; i < cnt; i++) {
        [out appendFormat:@"    %@ : %s\n", ivar_getName(ivs[i]) ? @(ivar_getName(ivs[i])) : @"?",
                          ivar_getTypeEncoding(ivs[i]) ?: "?"];
    }
    if (ivs) free(ivs);
}

// ============ 视图树 ============

static int gViewNodes = 0;

static void AMDumpView(UIView *v, int depth, NSMutableString *out) {
    if (!v || depth > 14 || gViewNodes > 2000) return;
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
    [out appendString:@"\n"];

    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *ctl = (UIControl *)v;
        for (id tgt in ctl.allTargets) {
            for (NSString *act in [ctl actionsForTarget:tgt forControlEvent:UIControlEventTouchUpInside]) {
                [out appendFormat:@"%@   ^ %@ action=%@ (UpInside)\n", ind, AMClsName(tgt), act];
            }
            for (NSString *act in [ctl actionsForTarget:tgt forControlEvent:UIControlEventValueChanged]) {
                [out appendFormat:@"%@   ^ %@ action=%@ (ValueChanged)\n", ind, AMClsName(tgt), act];
            }
        }
    }
    for (UIGestureRecognizer *g in v.gestureRecognizers ?: @[]) {
        id grTargets = nil;
        @try { grTargets = [g valueForKey:@"targets"]; } @catch (NSException *e) {}
        for (id inv in grTargets ?: @[]) {
            @try {
                id tgt = [(AMGRTargetStub *)inv target];
                SEL act = [(AMGRTargetStub *)inv action];
                [out appendFormat:@"%@   ~ %@ -> %@ action=%@\n", ind,
                    AMClsName(g), AMClsName(tgt), act ? (NSString *)NSStringFromSelector(act) : @"?"];
            } @catch (NSException *e) {}
        }
    }
    AMDumpClassIfNew([v class], out);
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
              @"model", @"item", @"panel", @"holder", @"dataSource", @"viewModel",
              @"transformHolder", @"padModel", @"currentValue", @"animatedValue",
              @"rotationX", @"rotationY", @"rotationZ", @"angleX", @"angleY", @"angleZ"];
    });
    return k;
}

static int gProbeDepth = 0;

static void AMProbeKVC(id obj, NSMutableString *out, int depth) {
    if (!obj || depth > 3 || gProbeDepth > 500) return;
    gProbeDepth++;
    for (NSString *key in AMModelKeys()) {
        @try {
            if (![obj respondsToSelector:@selector(valueForKey:)]) continue;
            id v = [obj valueForKey:key];
            if (!v || v == obj || v == [NSNull null]) continue;
            if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]] ||
                [v isKindOfClass:[NSValue class]]) {
                [out appendFormat:@"  KVC [%@ d%d] .%@ = %@\n", AMClsName(obj), depth, key, v];
            } else if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSDictionary class]]) {
                [out appendFormat:@"  KVC [%@ d%d] .%@ = <%@ n=%lu> %@\n", AMClsName(obj), depth, key,
                    AMClsName(v), (unsigned long)[(NSArray *)v count], AMDesc(v, 150)];
            } else if (![v isKindOfClass:[UIView class]] && ![v isKindOfClass:[UIColor class]]) {
                [out appendFormat:@"  KVC [%@ d%d] .%@ -> <%@>\n", AMClsName(obj), depth, key, AMClsName(v)];
                AMDumpClassIfNew([v class], out);
                if (depth < 2) AMProbeKVC(v, out, depth + 1);
            }
        } @catch (NSException *e) {}
    }
    gProbeDepth--;
}

static void AMProbeIvarObjects(id obj, NSMutableString *out, int depth) {
    if (!obj || depth > 1) return;
    unsigned int cnt = 0;
    Ivar *ivs = class_copyIvarList([obj class], &cnt);
    for (unsigned int i = 0; i < cnt; i++) {
        const char *ty = ivar_getTypeEncoding(ivs[i]);
        const char *nm = ivar_getName(ivs[i]);
        if (!ty || ty[0] != '@') continue;
        @try {
            id v = object_getIvar(obj, ivs[i]);
            if (!v || [v isKindOfClass:[UIView class]] || [v isKindOfClass:[UIColor class]]) continue;
            NSString *nms = nm ? @(nm) : @"?";
            [out appendFormat:@"  IVAROBJ [%@] %@ -> <%@>\n", AMClsName(obj), nms, AMClsName(v)];
            gProbeDepth = 0;
            AMProbeKVC(v, out, 0);
            AMProbeIvarObjects(v, out, depth + 1);
        } @catch (NSException *e) {}
    }
    if (ivs) free(ivs);
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
        lb.layer.cornerRadius = 8; lb.clipsToBounds = YES;
        [win addSubview:lb];
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ lb.alpha = 0; }
                          completion:^(BOOL f){ [lb removeFromSuperview]; }];
    });
}

// ============ 输出 ============

static void AMTransmit(NSString *text) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    @try { [pb setString:[text substringToIndex:MIN(text.length, 900000)]]; } @catch (NSException *e) {}
    @try {
        NSString *path = [NSTemporaryDirectory() stringByAppendingFormat:@"meow3d_dump_%d.txt", gDumpCount];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
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

// ============ 采集 ============

static void AMDumpPadVC(id vc, NSString *reason) {
    if (gDumpCount >= kMaxDumpsPerSession) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - gLastDumpAt < 1.2) return;
    gLastDumpAt = now;
    gDumpCount++;
    gLog = [NSMutableString string];
    gViewNodes = 0;

    @try {
        AMLOG("=== MeowRotate3D v3 dump #%d (%@) ===", gDumpCount, reason);
        AMLOG("vc=%@ base=%@", AMClsName(vc), AMClsName([(UIViewController *)vc superclass]));

        AMDumpClassIfNew([vc class], gLog);
        [gLog appendString:@"\n=== vc ivars (带值) ===\n"];
        AMDumpIvars(vc, gLog, YES);

        [gLog appendString:@"\n=== child VCs ===\n"];
        for (UIViewController *ch in [(UIViewController *)vc childViewControllers]) {
            [gLog appendFormat:@"  child: %@ view=%@\n", AMClsName(ch), AMFrame(ch.view.frame)];
            AMDumpClassIfNew([ch class], gLog);
            AMDumpIvars(ch, gLog, YES);
            AMProbeIvarObjects(ch, gLog, 0);
        }

        gViewNodes = 0;
        [gLog appendString:@"\n=== view tree ===\n"];
        AMDumpView([(UIViewController *)vc view], 0, gLog);

        [gLog appendString:@"\n=== responder chain ===\n"];
        int i = 0;
        for (UIResponder *r = vc; r && i < 12; r = [r nextResponder], i++) {
            [gLog appendFormat:@"  [%d] %@\n", i, AMClsName(r)];
            if ([r isKindOfClass:[UIViewController class]]) AMDumpClassIfNew([r class], gLog);
        }

        [gLog appendString:@"\n=== KVC probes ===\n"];
        gProbeDepth = 0;
        AMProbeKVC(vc, gLog, 0);
        AMProbeIvarObjects(vc, gLog, 0);

        [gLog appendFormat:@"\n=== end dump #%d (%lu chars, unique %lu) ===\n",
            gDumpCount, (unsigned long)gLog.length, (unsigned long)gDumpedClasses.count];
    } @catch (NSException *e) {
        AMLOG("!!! dump exception: %@ %@", e.name, e.reason);
    }

    NSString *text = gLog;
    gLog = nil;
    NSLog(@"[Meow3D]\n%@", text);
    AMTransmit(text);
    AMShowHUD([NSString stringWithFormat:@"猫鹤3D: #%d %@ (%lu字符, 已进剪贴板)",
        gDumpCount, AMClsName(vc), (unsigned long)text.length]);
}

static void AMHookPadVCNow(id vc) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AMDumpPadVC(vc, @"页面出现");
    });
}

// 为没有自己实现的类补一个调用 super 的方法
static void added_viewDidAppear(id self, SEL _cmd, BOOL anim) {
    struct objc_super sup = { self, class_getSuperclass([self class]) };
    ((void(*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, @selector(viewDidAppear:), anim);
    AMHookPadVCNow(self);
}
static void added_viewWillAppear(id self, SEL _cmd, BOOL anim) {
    struct objc_super sup = { self, class_getSuperclass([self class]) };
    ((void(*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, @selector(viewWillAppear:), anim);
    AMHookPadVCNow(self);
}
static void added_viewDidLoad(id self, SEL _cmd) {
    struct objc_super sup = { self, class_getSuperclass([self class]) };
    ((void(*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, @selector(viewDidLoad));
    AMHookPadVCNow(self);
}

static void AMHookOnePadClass(Class c) {
    if (!c) return;
    NSString *nm = NSStringFromClass(c);
    NSString *hkey = [@"HOOKED:" stringByAppendingString:nm];
    if (gDumpedClasses[hkey]) return;
    [gDumpedClasses setObject:@YES forKey:hkey];

    // 替换式: 类有自己的实现就替换(用 imp_implementationWithBlock 保住原实现)
    SEL sel1 = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(c, sel1);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^(id self, BOOL anim) {
            ((void(*)(id, SEL, BOOL))orig)(self, sel1, anim);
            AMHookPadVCNow(self);
        });
        method_setImplementation(m, hook);
        NSLog(@"[Meow3D] hooked(替换) %@ viewDidAppear:", nm);
        return;
    }
    SEL sel2 = @selector(viewWillAppear:);
    m = class_getInstanceMethod(c, sel2);
    if (m) {
        IMP orig = method_getImplementation(m);
        IMP hook = imp_implementationWithBlock(^(id self, BOOL anim) {
            ((void(*)(id, SEL, BOOL))orig)(self, sel2, anim);
            AMHookPadVCNow(self);
        });
        method_setImplementation(m, hook);
        NSLog(@"[Meow3D] hooked(替换) %@ viewWillAppear:", nm);
        return;
    }
    // 补充式: 没有自己的实现 -> class_addMethod 调 super
    if (class_addMethod(c, @selector(viewDidAppear:), (IMP)added_viewDidAppear, "v@:@c")) {
        NSLog(@"[Meow3D] hooked(补) %@ viewDidAppear:", nm);
        return;
    }
    if (class_addMethod(c, @selector(viewWillAppear:), (IMP)added_viewWillAppear, "v@:@c")) {
        NSLog(@"[Meow3D] hooked(补) %@ viewWillAppear:", nm);
        return;
    }
    if (class_addMethod(c, @selector(viewDidLoad), (IMP)added_viewDidLoad, "v@:")) {
        NSLog(@"[Meow3D] hooked(补) %@ viewDidLoad", nm);
    }
}

static void AMInstall(void) {
    if (gInstalled) return;
    gInstalled = YES;
    gDumpedClasses = [NSMutableDictionary new];

    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    int hooked = 0;
    for (unsigned int i = 0; i < n; i++) {
        NSString *nm = NSStringFromClass(classes[i]);
        if (!AMIsModuleClass(nm)) continue;
        BOOL isPad = [nm hasSuffix:@"PadVC"] || [nm hasSuffix:@"PanelVC"] ||
                     [nm containsString:@"RotationPad"] || [nm containsString:@"TransformPanel"];
        if (!isPad) continue;
        AMHookOnePadClass(classes[i]);
        hooked++;
    }
    free(classes);
    NSLog(@"[Meow3D] installed v3: hooked %d pad/panel classes", hooked);
}

__attribute__((constructor))
static void MeowRotate3DInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try { AMInstall(); } @catch (NSException *e) { NSLog(@"[Meow3D] install exception %@", e); }
    });
}
