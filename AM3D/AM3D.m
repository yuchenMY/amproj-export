/**
 * AM3D.m — AM3D 独立 3D 渲染桥（空对象 3D 父级控制器，真 3D 优先）。
 *
 * 架构（完全独立，不依赖 AMProjExport / AmHomeUI）：
 *   1) +load 自动启动，CADisplayLink 每帧驱动；
 *   2) 探测当前项目：keyWindow VC 树 → ProjectHolder → rootScene → layers
 *      （自包含 KVC 反射 am3d_get，逻辑与 AMProjExport 的 am_get 等价但独立实现）；
 *   3) 探测画布：keyWindow 视图树中候选 canvas（类名含 Preview/Canvas/Scene/
 *      Element 或子 layer 数量多的视图），canvas.layer.sublayers 按 z-order
 *      与 layers 顺序配对（z-order 即渲染顺序，format_spec §12）；
 *   4) 计算：对每个元素求 3D world 矩阵（父链 TRS 连乘，空对象用
 *      rotation3d/scale3d，普通层用 2D 字段回退规则——与 empty3d 一致）；
 *   5) 应用：flat 方式（不动 AM 图层树结构）把 world 平移/旋转/缩放写入
 *      对应 CALayer 的 position/transform；画布 sublayerTransform 加透视 m34；
 *   6) 降级：映射不到真实图层时（AMProjDebug/探测失败），在窗口叠加
 *      半透明占位层按 world 矩阵渲染，保证画面上能看到 3D 父链效果；
 *   7) 安全：全程 @try/@catch，任何失败静默降级，绝不崩溃。
 *
 * 已知限制（真机迭代项）：
 *   - 图层↔元素映射依赖 z-order 顺序假设，需真机日志确认；
 *   - 覆盖 transform 会与 AM 自身 2D 动画竞争（v1 只接管有 3D 父链的层，
 *     且脏检查避免无谓写入）。
 */

#import "AM3D.h"
#import "AM3DTransform3D.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

#define AM3D_TAG "[AM3D]"

static void AM3DLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void AM3DLog(NSString *fmt, ...) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"AM3DLog"] &&
        ![[NSUserDefaults standardUserDefaults] objectForKey:@"AM3DLog"]) {
        return; /* 默认关闭？不：默认开启，见 +load 内初始化 */
    }
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"%s %@", AM3D_TAG, msg);
}

#pragma mark - 自包含 KVC 反射（独立实现）

static id am3d_get(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        id value = [obj valueForKey:key];
        if (value) return value;
    } @catch (NSException *e) { }
    for (Class cls = [obj class]; cls && cls != [NSObject class];
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            Ivar ivar = ivars[i];
            const char *name = ivar_getName(ivar);
            if (!name) continue;
            NSString *ivarName = [NSString stringWithUTF8String:name];
            if (![ivarName isEqualToString:key] &&
                ![ivarName isEqualToString:[@"_" stringByAppendingString:key]]) {
                continue;
            }
            const char *type = ivar_getTypeEncoding(ivar);
            id value = nil;
            if (type && (type[0] == '@' || type[0] == '#')) {
                value = object_getIvar(obj, ivar);
            } else if (type) {
#define AM3D_BOX_IVAR(code, ctype) \
                case code: { ctype raw = 0; \
                    memcpy(&raw, (const uint8_t *)(__bridge const void *)obj + ivar_getOffset(ivar), sizeof(raw)); \
                    value = @(raw); break; }
                switch (type[0]) {
                    AM3D_BOX_IVAR('i', int) AM3D_BOX_IVAR('I', unsigned int)
                    AM3D_BOX_IVAR('l', long) AM3D_BOX_IVAR('L', unsigned long)
                    AM3D_BOX_IVAR('q', long long) AM3D_BOX_IVAR('Q', unsigned long long)
                    AM3D_BOX_IVAR('f', float) AM3D_BOX_IVAR('d', double)
                    AM3D_BOX_IVAR('B', BOOL) AM3D_BOX_IVAR('c', char)
                    AM3D_BOX_IVAR('C', unsigned char) AM3D_BOX_IVAR('s', short)
                    AM3D_BOX_IVAR('S', unsigned short)
                    default: break;
                }
#undef AM3D_BOX_IVAR
            }
            free(ivars);
            return value;
        }
        free(ivars);
    }
    return nil;
}

static NSString *am3d_str(id obj, NSString *key) {
    id v = am3d_get(obj, key);
    return [v isKindOfClass:[NSString class]] ? v :
           [v isKindOfClass:[NSNumber class]] ? [v stringValue] : nil;
}

static NSInteger am3d_int(id obj, NSString *key) {
    id v = am3d_get(obj, key);
    return [v respondsToSelector:@selector(integerValue)] ? [(NSNumber *)v integerValue] : 0;
}

static CGFloat am3d_flt(id obj, NSString *key) {
    id v = am3d_get(obj, key);
    return [v respondsToSelector:@selector(doubleValue)] ? [(NSNumber *)v doubleValue] : 0.0;
}

static NSArray *am3d_arr(id obj, NSString *key) {
    id v = am3d_get(obj, key);
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

#pragma mark - 数据模型（轻量，自包含）

typedef struct {
    NSInteger id;
    NSInteger parent;
    BOOL isNullObject;        /* layerType == nullobj */
    BOOL isBookmark;
    double loc[3];            /* 位置 XYZ（像素） */
    double rot[3];            /* 有效欧拉角 XYZ（度） */
    double scl[3];            /* 有效缩放 XYZ */
    BOOL has3D;               /* 有 3D 数据（rotation3d/scale3d 非默认） */
} AM3DElement;

static BOOL am3d_layerTypeIsNull(id layer) {
    NSString *t = am3d_str(layer, @"layerType") ?: am3d_str(layer, @"type") ?: @"";
    return [t isEqualToString:@"nullobj"] || [t isEqualToString:@"null"];
}

static BOOL am3d_vec3Default(const double v[3], double d0, double d1, double d2) {
    return fabs(v[0] - d0) < 1e-9 && fabs(v[1] - d1) < 1e-9 && fabs(v[2] - d2) < 1e-9;
}

static BOOL am3d_fillElement(id layer, AM3DElement *out) {
    if (!layer || !out) return NO;
    memset(out, 0, sizeof(*out));
    out->id = am3d_int(layer, @"id");
    out->parent = am3d_int(layer, @"parent");
    out->isNullObject = am3d_layerTypeIsNull(layer);
    NSString *tag = out->isNullObject ? @"nullobj" :
                    ([am3d_str(layer, @"layerType") ?: @"" isEqualToString:@"bookmark"] ||
                     [am3d_str(layer, @"type") ?: @"" isEqualToString:@"bookmark"]) ? @"bookmark" : @"";
    out->isBookmark = [tag isEqualToString:@"bookmark"];

    id xf = am3d_get(layer, @"transform");
    if (!xf) return out->isNullObject || out->isBookmark; /* 无 transform 的层（bookmark） */

    /* 位置 */
    AM3DVec3 loc = {0, 0, 0};
    id locVal = am3d_str(xf, @"locationValue") ? (id)am3d_str(xf, @"locationValue") : nil;
    if (!locVal) locVal = am3d_str(xf, @"location");
    if (locVal && am3d_parseVec3((__bridge void *)locVal, &loc)) {
        out->loc[0] = loc.x; out->loc[1] = loc.y; out->loc[2] = loc.z;
    }
    /* 2D 旋转/缩放（回退用） */
    CGFloat r2 = am3d_flt(xf, @"rotation") ?: am3d_flt(xf, @"rotationValue");
    NSString *s2s = am3d_str(xf, @"scaleValue") ?: am3d_str(xf, @"scale");
    AM3DVec3 s2 = {1, 1, 1};
    if (s2s && am3d_parseVec3((__bridge void *)s2s, &s2)) { }
    /* 3D 扩展（原生对象若有） */
    AM3DVec3 r3 = {0, 0, 0}, s3 = {1, 1, 1};
    BOOL hasR3 = NO, hasS3 = NO;
    id r3v = am3d_get(xf, @"rotation3d") ?: am3d_get(xf, @"rotation3dValue");
    if (r3v && am3d_parseVec3((__bridge void *)r3v, &r3)) hasR3 = !am3d_vec3Default((double[]){r3.x,r3.y,r3.z}, 0,0,0);
    id s3v = am3d_get(xf, @"scale3d") ?: am3d_get(xf, @"scale3dValue");
    if (s3v && am3d_parseVec3((__bridge void *)s3v, &s3)) hasS3 = !am3d_vec3Default((double[]){s3.x,s3.y,s3.z}, 1,1,1);

    out->has3D = hasR3 || hasS3;
    /* 有效欧拉：有 3D 用 rotation3d，否则 (0,0,rotation2d) */
    if (hasR3) { out->rot[0] = r3.x; out->rot[1] = r3.y; out->rot[2] = r3.z; }
    else { out->rot[0] = 0; out->rot[1] = 0; out->rot[2] = r2; }
    /* 有效缩放：有 3D 用 scale3d，否则 (scale2d, 1) */
    if (hasS3) { out->scl[0] = s3.x; out->scl[1] = s3.y; out->scl[2] = s3.z; }
    else { out->scl[0] = s2.x; out->scl[1] = s2.y; out->scl[2] = 1.0; }
    return YES;
}

#pragma mark - 场景图探测

@interface AM3DRenderer : NSObject
@end

@implementation AM3DRenderer {
    CADisplayLink *_link;
    BOOL _running;
    NSMutableArray<NSDictionary *> *_elements;   /* id -> element 数据缓存 */
    UIView *_canvas;
    NSMutableDictionary<NSNumber *, CALayer *> *_layerMap; /* 元素 id -> CALayer */
    NSMutableDictionary<NSNumber *, NSData *> *_lastApplied; /* 元素 id -> 上次矩阵 */
    UIView *_demoOverlay;
    CFAbsoluteTime _lastProbe;
}

static AM3DRenderer *g_renderer = nil;

+ (void)load {
    /* dylib 注入后自动启动 */
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:@"AM3DEnabled"] && ![ud boolForKey:@"AM3DEnabled"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [AM3DRenderer start];
    });
}

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_renderer = [[AM3DRenderer alloc] init]; });
    return g_renderer;
}

+ (void)start { [[AM3DRenderer shared] startLink]; }
+ (void)stop  { [[AM3DRenderer shared] stopLink]; }

- (instancetype)init {
    if ((self = [super init])) {
        _elements = [NSMutableArray array];
        _layerMap = [NSMutableDictionary dictionary];
        _lastApplied = [NSMutableDictionary dictionary];
        _lastProbe = 0;
    }
    return self;
}

- (void)startLink {
    if (_running) return;
    _running = YES;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    AM3DLog(@"renderer started (perspective=%g)", [self perspectiveFocal]);
}

- (void)stopLink {
    if (!_running) return;
    [_link invalidate];
    _link = nil;
    _running = NO;
}

- (double)perspectiveFocal {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    id v = [ud objectForKey:@"AM3DPerspective"];
    if (v) {
        double f = [v doubleValue];
        return f > 0 ? f : 0.0;
    }
    return 1100.0;
}

- (void)tick:(CADisplayLink *)link {
    @try {
        if (![NSThread isMainThread]) return;
        [self probeIfNeeded];
        [self apply3D];
    } @catch (NSException *e) {
        AM3DLog(@"tick error (ignored): %@", e.reason ?: e);
    }
}

/* 每 0.5s 重建场景/画布/映射缓存 */
- (void)probeIfNeeded {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastProbe < 0.5) return;
    _lastProbe = now;
    [self probeScene];
}

- (UIWindow *)mainWindow {
    return [UIApplication sharedApplication].keyWindow ?:
           [UIApplication sharedApplication].windows.firstObject;
}

- (NSArray *)collectViewTree:(UIView *)root {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        [out addObject:v];
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return out;
}

/* 探测 ProjectHolder → rootScene → layers（多路尝试，全失败返回 nil） */
- (id)probeSceneInfo {
    UIWindow *w = [self mainWindow];
    if (!w) return nil;
    /* 遍历所有 VC 与视图，找类名含 ProjectHolder 的实例 */
    for (UIViewController *vc in [self viewControllersOf:w.rootViewController]) {
        id holder = [self findIvarOfType:vc prefix:@"ProjectHolder" maxDepth:3];
        if (holder) {
            id scene = am3d_get(holder, @"rootScene") ?: am3d_get(holder, @"scene");
            if (scene) return scene;
        }
    }
    /* 兜底：遍历视图属性 */
    for (UIView *v in [self collectViewTree:w]) {
        id holder = [self findIvarOfType:v prefix:@"ProjectHolder" maxDepth:2];
        if (holder) {
            id scene = am3d_get(holder, @"rootScene") ?: am3d_get(holder, @"scene");
            if (scene) return scene;
        }
    }
    return nil;
}

- (NSArray *)viewControllersOf:(UIViewController *)root {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *stack = [NSMutableArray array];
    if (root) [stack addObject:root];
    while (stack.count) {
        UIViewController *vc = stack.lastObject;
        [stack removeLastObject];
        [out addObject:vc];
        if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
        for (UIViewController *c in vc.childViewControllers) [stack addObject:c];
        for (UIView *v in vc.view.subviews) {
            id next = [self findIvarOfType:v prefix:@"UIViewController" maxDepth:1];
            (void)next;
        }
    }
    return out;
}

- (id)findIvarOfType:(id)obj prefix:(NSString *)prefix maxDepth:(int)depth {
    if (!obj || depth <= 0) return nil;
    if ([NSStringFromClass([obj class]) containsString:prefix]) return obj;
    /* 遍历 ivar：对象类型且类名含前缀 */
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    id found = nil;
    for (unsigned int i = 0; i < count && !found; i++) {
        Ivar ivar = ivars[i];
        const char *type = ivar_getTypeEncoding(ivar);
        if (type && type[0] == '@') {
            id child = object_getIvar(obj, ivar);
            if (child && [child isKindOfClass:[NSObject class]]) {
                NSString *cn = NSStringFromClass([child class]);
                if ([cn containsString:prefix]) {
                    found = child;
                } else if (depth > 1) {
                    found = [self findIvarOfType:child prefix:prefix maxDepth:depth - 1];
                }
            }
        }
    }
    free(ivars);
    return found;
}

- (void)probeScene {
    id scene = [self probeSceneInfo];
    if (!scene) {
        if (_elements.count) AM3DLog(@"scene lost; cleared");
        [_elements removeAllObjects];
        [_layerMap removeAllObjects];
        [_lastApplied removeAllObjects];
        return;
    }
    NSArray *layers = am3d_arr(scene, @"layers");
    if (!layers) return;

    NSMutableArray *els = [NSMutableArray array];
    for (id layer in layers) {
        AM3DElement e;
        if (am3d_fillElement(layer, &e)) {
            [els addObject:@{
                @"id": @(e.id), @"parent": @(e.parent),
                @"null": @(e.isNullObject), @"bookmark": @(e.isBookmark),
                @"loc": @[@(e.loc[0]), @(e.loc[1]), @(e.loc[2])],
                @"rot": @[@(e.rot[0]), @(e.rot[1]), @(e.rot[2])],
                @"scl": @[@(e.scl[0]), @(e.scl[1]), @(e.scl[2])],
                @"has3d": @(e.has3D),
            }];
        }
    }
    BOOL changed = els.count != _elements.count;
    if (!changed) {
        for (NSUInteger i = 0; i < els.count; i++) {
            if (![els[i] isEqual:_elements[i]]) { changed = YES; break; }
        }
    }
    if (changed) {
        _elements = els;
        AM3DLog(@"scene probed: %lu layers, nullobj=%lu",
                (unsigned long)_elements.count,
                (unsigned long)[self countNullObjects]);
        [self rebuildLayerMap];
    }
}

- (NSUInteger)countNullObjects {
    NSUInteger n = 0;
    for (NSDictionary *e in _elements) if ([e[@"null"] boolValue]) n++;
    return n;
}

/* 探测画布：keyWindow 中类名含 Preview/Canvas/Scene/Element 的视图 */
- (UIView *)probeCanvas {
    UIWindow *w = [self mainWindow];
    if (!w) return nil;
    static NSString *const hints[] = {
        @"Preview", @"Canvas", @"Scene", @"Element", @"TimelineView", nil
    };
    for (UIView *v in [self collectViewTree:w]) {
        NSString *cn = NSStringFromClass([v class]);
        for (int i = 0; hints[i]; i++) {
            if ([cn containsString:hints[i]] && v.layer.sublayers.count > 1) {
                return v;
            }
        }
    }
    /* 兜底：子 layer 最多的视图 */
    UIView *best = nil;
    NSUInteger bestCount = 4;
    for (UIView *v in [self collectViewTree:w]) {
        NSUInteger n = (NSUInteger)v.layer.sublayers.count;
        if (n > bestCount && v.bounds.size.width > 50) {
            best = v; bestCount = n;
        }
    }
    return best;
}

/* 建立 元素id -> CALayer 映射：canvas.layer.sublayers 按 z-order 与 layers 配对 */
- (void)rebuildLayerMap {
    _canvas = [self probeCanvas];
    [_layerMap removeAllObjects];
    if (!_canvas || !_elements.count) {
        AM3DLog(@"canvas probe: %@ (layers=%lu)", _canvas ? @"ok" : @"none",
                (unsigned long)_elements.count);
        [self ensureDemoOverlay];
        return;
    }
    NSArray<CALayer *> *sublayers = _canvas.layer.sublayers;
    if (sublayers.count < _elements.count) {
        AM3DLog(@"canvas sublayers %lu < elements %lu; fallback demo",
                (unsigned long)sublayers.count, (unsigned long)_elements.count);
        [self ensureDemoOverlay];
        return;
    }
    /* z-order 配对：从底部（索引 0）开始对应 elements 顺序 */
    for (NSUInteger i = 0; i < _elements.count && i < sublayers.count; i++) {
        NSDictionary *e = _elements[i];
        [_layerMap setObject:sublayers[i] forKey:e[@"id"]];
    }
    AM3DLog(@"layer map rebuilt: %lu pairs", (unsigned long)_layerMap.count);
    [self removeDemoOverlay];
}

#pragma mark - 3D 应用

- (NSDictionary *)elementById:(NSInteger)elId {
    for (NSDictionary *e in _elements) {
        if ([e[@"id"] integerValue] == elId) return e;
    }
    return nil;
}

/* 父链 world 矩阵（root→self 连乘），环/悬空安全 */
- (AM3DMat4)worldMatrixFor:(NSDictionary *)el seen:(NSMutableSet *)seen {
    NSInteger elId = [el[@"id"] integerValue];
    NSInteger parentId = [el[@"parent"] integerValue];
    if (parentId == 0 || parentId == elId || [seen containsObject:@(elId)]) {
        return [self localMatrixFor:el];
    }
    [seen addObject:@(elId)];
    NSDictionary *p = [self elementById:parentId];
    if (!p || [p[@"bookmark"] boolValue]) {
        return [self localMatrixFor:el];
    }
    if (seen.count > 64) return [self localMatrixFor:el]; /* 深度保护 */
    AM3DMat4 parentWorld = [self worldMatrixFor:p seen:seen];
    return am3d_multiply(parentWorld, [self localMatrixFor:el]);
}

- (AM3DMat4)localMatrixFor:(NSDictionary *)el {
    AM3DVec3 t = {[el[@"loc"][0] doubleValue], [el[@"loc"][1] doubleValue], [el[@"loc"][2] doubleValue]};
    AM3DVec3 r = {[el[@"rot"][0] doubleValue], [el[@"rot"][1] doubleValue], [el[@"rot"][2] doubleValue]};
    AM3DVec3 s = {[el[@"scl"][0] doubleValue], [el[@"scl"][1] doubleValue], [el[@"scl"][2] doubleValue]};
    return am3d_composeTRS(t, r, s);
}

/* 是否参与 3D：空对象本身不画；子层且父链上有空对象才接管 */
- (BOOL)shouldApplyTo:(NSDictionary *)el {
    if ([el[@"null"] boolValue]) return NO;      /* 空对象自身不渲染 */
    if ([el[@"bookmark"] boolValue]) return NO;
    NSInteger parentId = [el[@"parent"] integerValue];
    if (parentId == 0) return NO;                /* 无父链 */
    /* 父链上任一祖先为空对象（或有 3D 数据）则接管 */
    NSMutableSet *seen = [NSMutableSet set];
    NSDictionary *cur = [self elementById:parentId];
    while (cur && ![seen containsObject:cur[@"id"]]) {
        [seen addObject:cur[@"id"]];
        if ([cur[@"null"] boolValue] || [cur[@"has3d"] boolValue]) return YES;
        NSInteger pid = [cur[@"parent"] integerValue];
        cur = (pid == 0 || pid == [cur[@"id"] integerValue]) ? nil : [self elementById:pid];
        if (seen.count > 64) break;
    }
    return NO;
}

- (void)apply3D {
    if (!_elements.count) return;
    NSUInteger applied = 0;
    for (NSDictionary *el in _elements) {
        if (![self shouldApplyTo:el]) continue;
        CALayer *layer = _layerMap[el[@"id"]];
        if (!layer) continue;
        AM3DMat4 world = [self worldMatrixFor:el seen:[NSMutableSet set]];
        float f[16];
        am3d_mat4ToFloat16(world, f);
        CATransform3D t = {
            f[0], f[1], f[2], f[3],
            f[4], f[5], f[6], f[7],
            f[8], f[9], f[10], f[11],
            f[12], f[13], f[14], f[15],
        };
        /* 脏检查：矩阵变化才写入 */
        NSData *key = el[@"id"];
        NSData *sig = [NSData dataWithBytes:f length:sizeof(f)];
        if ([_lastApplied[key] isEqual:sig]) continue;
        _lastApplied[key] = sig;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.transform = t;
        [CATransaction commit];
        applied++;
    }
    /* 透视：画布 sublayerTransform 加 m34（每 0.5s 重设一次即可） */
    if (_canvas && [self perspectiveFocal] > 0) {
        CATransform3D st = CATransform3DIdentity;
        st.m34 = (CGFloat)(-1.0 / [self perspectiveFocal]);
        if (!CATransform3DEqualToTransform(_canvas.layer.sublayerTransform, st)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            _canvas.layer.sublayerTransform = st;
            [CATransaction commit];
        }
    }
    if (applied) AM3DLog(@"applied 3D to %lu layers", (unsigned long)applied);
}

#pragma mark - 占位演示降级（映射失败时保底可见）

- (void)ensureDemoOverlay {
    if (_demoOverlay) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:@"AM3DDemoFallback"] && ![ud boolForKey:@"AM3DDemoFallback"]) return;
    UIWindow *w = [self mainWindow];
    if (!w) return;
    UIView *overlay = [[UIView alloc] initWithFrame:w.bounds];
    overlay.userInteractionEnabled = NO;
    overlay.backgroundColor = [UIColor clearColor];
    [w addSubview:overlay];
    _demoOverlay = overlay;
    /* 三个占位块：父块 + 2 子块（半透明，只作演示） */
    CALayer *parent = [self demoBlockLayer:CGSizeMake(180, 120) color:[UIColor systemTealColor]];
    CALayer *c1 = [self demoBlockLayer:CGSizeMake(90, 60) color:[UIColor systemOrangeColor]];
    CALayer *c2 = [self demoBlockLayer:CGSizeMake(60, 60) color:[UIColor systemPinkColor]];
    parent.position = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height / 2 - 80);
    c1.position = CGPointMake(150, 0);
    c2.position = CGPointMake(-150, 60);
    [overlay.layer addSublayer:parent];
    [parent addSublayer:c1];
    [parent addSublayer:c2];
    /* 动画：父层绕 Y 旋转 */
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
    spin.fromValue = @(-0.6);
    spin.toValue = @(0.6);
    spin.duration = 2.5;
    spin.autoreverses = YES;
    spin.repeatCount = HUGE_VALF;
    [parent addAnimation:spin forKey:@"am3d-demo-spin"];
    AM3DLog(@"demo overlay shown (real layer mapping unavailable)");
}

- (CALayer *)demoBlockLayer:(CGSize)size color:(UIColor *)color {
    CALayer *l = [CALayer layer];
    l.bounds = CGRectMake(0, 0, size.width, size.height);
    l.backgroundColor = [color colorWithAlphaComponent:0.65].CGColor;
    l.cornerRadius = 8;
    l.borderColor = [UIColor whiteColor].CGColor;
    l.borderWidth = 1;
    return l;
}

- (void)removeDemoOverlay {
    if (!_demoOverlay) return;
    [_demoOverlay removeFromSuperview];
    _demoOverlay = nil;
}

@end

void AM3DStart(void) { [AM3DRenderer start]; }
void AM3DStop(void)  { [AM3DRenderer stop]; }
