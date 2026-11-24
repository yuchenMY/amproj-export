// 猫鹤 AM · Beta 卡顿诊断。按需采集，不读取文字、素材、截图或令牌。
#import "AMProjBetaDiagnostics.h"
#import "AMProjPerformancePolicy.h"
#import "AMCloudSync.h"
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/utsname.h>

#if !AMPROJ_BETA_DIAGNOSTICS
#error This source belongs exclusively to the Beta target.
#endif
#ifndef AMPROJ_DIAGNOSTIC_BUILD_ID
#define AMPROJ_DIAGNOSTIC_BUILD_ID "local-beta"
#endif

static NSString *const AMPerfChanged = @"AMProjBetaDiagnosticsChanged";
static atomic_bool AMPerfRecording = false;
static CFTimeInterval AMPerfNow(void) { return CACurrentMediaTime(); }
static uint64_t AMPerfMicros(void) { return (uint64_t)(AMPerfNow() * 1000000.0); }
static UIColor *AMPerfTeal(void) { return [UIColor colorWithRed:0.224 green:0.773 blue:0.733 alpha:1]; }
static UIColor *AMPerfInk(void) { return [UIColor colorWithRed:0.051 green:0.180 blue:0.176 alpha:1]; }
static UIColor *AMPerfBackground(void) { return [UIColor colorWithRed:0.949 green:0.984 blue:0.980 alpha:1]; }
static NSString *AMPerfPath(void) {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"AMProjExport.performance.json"];
}
static NSString *AMPerfShort(NSString *value) {
    return value.length > 96 ? [value substringToIndex:96] : (value ?: @"");
}

@interface AMPerfSession : NSObject {
@public
    atomic_bool active;
    atomic_uint_fast64_t pingAt;
    atomic_uint_fast64_t frames;
    atomic_uint_fast64_t maxFrameGap;
}
@property(nonatomic) CFTimeInterval started;
@property(nonatomic) CFTimeInterval stopped;
@property(nonatomic) CFTimeInterval previousFrame;
@property(nonatomic) CFTimeInterval lastTouch;
@property(nonatomic) NSInteger hudSecond;
@property(nonatomic) CFTimeInterval lastSample;
@property(nonatomic) CFTimeInterval lastSave;
@property(nonatomic) BOOL stalled;
@property(nonatomic) BOOL finished;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) NSUInteger dropped;
@property(nonatomic, copy) NSString *captureID;
@property(nonatomic, copy) NSDictionary *environment;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, strong) dispatch_source_t timer;
@end
@implementation AMPerfSession
- (instancetype)init {
    if ((self = [super init])) {
        atomic_init(&active, true); atomic_init(&pingAt, 0);
        atomic_init(&frames, 0); atomic_init(&maxFrameGap, 0);
        _events = [NSMutableArray array];
    }
    return self;
}
@end

@interface AMPerfHUDWindow : UIWindow
@end
@implementation AMPerfHUDWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    for (UIView *view = hit; view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) return hit;
    }
    return nil;
}
@end

@interface AMPerfButton : UIButton
@end
@implementation AMPerfButton
+ (Class)layerClass { return CAGradientLayer.class; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
        gradient.colors = @[(id)AMPerfTeal().CGColor,
            (id)[UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:1].CGColor];
        gradient.startPoint = CGPointMake(0, 0.5); gradient.endPoint = CGPointMake(1, 0.5);
        self.layer.cornerRadius = 24; self.clipsToBounds = YES;
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [self setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    }
    return self;
}
@end

@interface AMPerfController : UIViewController
@property(nonatomic) BOOL menu;
@property(nonatomic, strong) UILabel *headline;
@property(nonatomic, strong) UILabel *body;
@property(nonatomic, strong) AMPerfButton *primary;
@property(nonatomic, strong) UIButton *secondary;
@end

@interface AMPerfRecorder : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(atomic, strong) AMPerfSession *session;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) AMPerfHUDWindow *hud;
@property(nonatomic, strong) UIButton *hudButton;
@property(nonatomic, strong) NSData *pending;
@property(nonatomic, copy) NSString *ticketID;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) BOOL uploading;
@property(nonatomic) BOOL saved;
@property(nonatomic) UIBackgroundTaskIdentifier backgroundTask;
+ (instancetype)shared;
- (void)start;
- (void)stop:(NSString *)reason;
- (void)append:(NSString *)event fields:(NSDictionary *)fields session:(AMPerfSession *)session;
- (void)captureTouch:(UIEvent *)event;
- (void)upload;
- (void)showReport;
@end

static UIViewController *AMPerfTopController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || [window isKindOfClass:AMPerfHUDWindow.class]) continue;
            UIViewController *top = window.rootViewController;
            for (NSUInteger depth = 0; top && depth < 24; depth++) {
                UIViewController *next = top.presentedViewController;
                if (!next && [top isKindOfClass:UINavigationController.class])
                    next = ((UINavigationController *)top).visibleViewController;
                if (!next && [top isKindOfClass:UITabBarController.class])
                    next = ((UITabBarController *)top).selectedViewController;
                if (!next || next == top) break;
                top = next;
            }
            return top;
        }
    }
    return nil;
}

// 触摸 hook 仅采集中安装。若其他模块后来接管同一方法，不破坏其 hook 链。
static IMP AMPerfOriginalSendEvent;
static Class AMPerfEventClass;
static BOOL AMPerfEventHookInstalled;
static void AMPerfSendEvent(UIApplication *application, SEL selector, UIEvent *event) {
    BOOL recording = atomic_load(&AMPerfRecording);
    if (recording) [[AMPerfRecorder shared] captureTouch:event];
    CFTimeInterval started = recording ? AMPerfNow() : 0;
    ((void (*)(id, SEL, UIEvent *))AMPerfOriginalSendEvent)(application, selector, event);
    if (recording) AMProjBetaDiagnosticsEndSpan(@"ui.send_event", started);
}
static void AMPerfInstallEventHook(void) {
    if (AMPerfEventHookInstalled) return;
    Class cls = object_getClass(UIApplication.sharedApplication);
    Method method = class_getInstanceMethod(cls, @selector(sendEvent:));
    if (!method || method_getNumberOfArguments(method) != 3) return;
    IMP original = method_getImplementation(method);
    if (original == (IMP)AMPerfSendEvent) return;
    AMPerfOriginalSendEvent = original; AMPerfEventClass = cls;
    if (!class_addMethod(cls, @selector(sendEvent:), (IMP)AMPerfSendEvent, method_getTypeEncoding(method)))
        class_replaceMethod(cls, @selector(sendEvent:), (IMP)AMPerfSendEvent, method_getTypeEncoding(method));
    AMPerfEventHookInstalled = YES;
}
static void AMPerfRemoveEventHook(void) {
    if (!AMPerfEventHookInstalled) return;
    Method method = class_getInstanceMethod(AMPerfEventClass, @selector(sendEvent:));
    if (method_getImplementation(method) == (IMP)AMPerfSendEvent) {
        class_replaceMethod(AMPerfEventClass, @selector(sendEvent:), AMPerfOriginalSendEvent,
            method_getTypeEncoding(method));
        AMPerfEventHookInstalled = NO;
    }
}

@implementation AMPerfRecorder
+ (instancetype)shared {
    static AMPerfRecorder *recorder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        recorder = [AMPerfRecorder new];
        recorder.backgroundTask = UIBackgroundTaskInvalid;
        recorder.queue = dispatch_queue_create("cn.meowcr.beta.performance", DISPATCH_QUEUE_SERIAL);
        NSData *data = [NSData dataWithContentsOfFile:AMPerfPath() options:NSDataReadingMappedIfSafe error:nil];
        if (data.length && data.length <= AMPROJ_PERF_MAX_BYTES) {
            id report = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([report isKindOfClass:NSDictionary.class] && [report[@"kind"] isEqual:@"performance"] &&
                [report[@"capture_id"] isKindOfClass:NSString.class]) {
                recorder.pending = data; recorder.saved = YES;
            }
        }
    });
    return recorder;
}
- (void)changed {
    [NSNotificationCenter.defaultCenter postNotificationName:AMPerfChanged object:self];
}
- (void)addEvent:(NSString *)name fields:(NSDictionary *)fields to:(AMPerfSession *)session at:(double)observed {
    if (session.finished) return;
    NSDictionary *event = @{@"seq": @(session.sequence++),
        @"t_ms": @(AMProjPerfElapsed(session.started, observed) * 1000),
        @"event": AMPerfShort(name), @"fields": fields ?: @{}};
    if (session.events.count < AMPROJ_PERF_MAX_EVENTS) [session.events addObject:event];
    else {
        session.events[(session.sequence - 1) % AMPROJ_PERF_MAX_EVENTS] = event;
        session.dropped++;
    }
}
- (void)append:(NSString *)event fields:(NSDictionary *)fields session:(AMPerfSession *)session {
    if (!session || !atomic_load(&session->active)) return;
    double observed = AMPerfNow();
    dispatch_async(self.queue, ^{ [self addEvent:event fields:fields to:session at:observed]; });
}
- (NSData *)report:(AMPerfSession *)session reason:(NSString *)reason {
    NSArray *events = [session.events sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"seq"] compare:b[@"seq"]];
    }];
    NSDictionary *payload = @{@"schema": @1, @"kind": @"performance", @"capture_id": session.captureID,
        @"environment": session.environment, @"duration_ms": @(AMProjPerfElapsed(session.started, session.stopped ?: AMPerfNow()) * 1000),
        @"finish_reason": reason, @"events_dropped": @(session.dropped), @"events": events,
        @"measurement_notes": @"Display-link delivery and main-queue response; not GPU render FPS or CPU stack samples. Project contents are not inspected."};
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    return data.length <= AMPROJ_PERF_MAX_BYTES ? data : nil;
}
- (BOOL)persist:(NSData *)data {
    if (!data.length) return NO;
    return [data writeToFile:AMPerfPath()
        options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}
- (void)start {
    if (!AMProjBetaDiagnosticsAvailable() || self.session || self.uploading || self.pending) return;
    self.ticketID = nil; self.message = nil;
    AMPerfSession *session = [AMPerfSession new];
    session.started = AMPerfNow(); session.captureID = NSUUID.UUID.UUIDString;
    struct utsname machine; memset(&machine, 0, sizeof(machine)); uname(&machine);
    session.environment = @{
        @"machine": [NSString stringWithUTF8String:machine.machine] ?: @"unknown",
        @"ios": UIDevice.currentDevice.systemVersion ?: @"",
        @"app_version": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"",
        @"app_build": NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"",
        @"plugin_build": @AMPROJ_DIAGNOSTIC_BUILD_ID,
        @"screen_max_hz": @(UIScreen.mainScreen.maximumFramesPerSecond),
        @"low_power": @(NSProcessInfo.processInfo.lowPowerModeEnabled),
        @"project_metadata": @"not_collected"};
    self.session = session; atomic_store(&AMPerfRecording, true);
    AMPerfInstallEventHook();
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillShowNotification object:nil];
    [center addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillHideNotification object:nil];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    session.timer = timer;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ [weakSelf tick:session]; });
    [self append:@"capture.started" fields:@{} session:session];
    dispatch_resume(timer);
    [self showHUD]; [self changed];
}
- (void)frame:(CADisplayLink *)link {
    AMPerfSession *session = self.session;
    if (!session || !atomic_load(&session->active)) return;
    atomic_fetch_add(&session->frames, 1);
    if (session.previousFrame > 0 && link.timestamp >= session.previousFrame) {
        uint64_t delta = (uint64_t)((link.timestamp - session.previousFrame) * 1000000);
        uint64_t previous = atomic_load(&session->maxFrameGap);
        while (delta > previous && !atomic_compare_exchange_weak(&session->maxFrameGap, &previous, delta)) {}
    }
    session.previousFrame = link.timestamp;
}
- (void)tick:(AMPerfSession *)session {
    if (!atomic_load(&session->active)) return;
    double now = AMPerfNow();
    if (AMProjPerfExpired(session.started, now)) { [self stop:@"timeout"]; return; }
    uint64_t requested = atomic_load(&session->pingAt);
    if (!requested) {
        atomic_store(&session->pingAt, AMPerfMicros());
        // 一次只排一个回执。主线程阻塞时不会持续堆积待执行 block。
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!atomic_load(&session->active)) return;
            uint64_t sent = atomic_exchange(&session->pingAt, 0);
            double delay = sent ? ((double)AMPerfMicros() - sent) / 1000000.0 : 0;
            if (delay >= AMPROJ_PERF_STALL_SECONDS)
                [self append:@"main_queue.recovered" fields:@{@"delay_ms": @(delay * 1000)} session:session];
            NSInteger second = (NSInteger)AMProjPerfElapsed(session.started, AMPerfNow());
            if (session.hudSecond != second && self.session == session) {
                session.hudSecond = second;
                [self.hudButton setTitle:[NSString stringWithFormat:@"诊断中 %02ld 秒 · 结束", (long)second]
                    forState:UIControlStateNormal];
            }
        });
        session.stalled = NO;
    } else if (AMProjPerfIsStall((double)requested / 1000000.0, now) && !session.stalled) {
        session.stalled = YES;
        [self addEvent:@"main_queue.stalled" fields:@{@"pending_ms": @((now - (double)requested / 1000000.0) * 1000)} to:session at:now];
    }
    if (now - session.lastSample >= 1) {
        session.lastSample = now;
        task_vm_info_data_t memory;
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count);
        [self addEvent:@"performance.sample" fields:@{
            @"display_link_frames": @(atomic_exchange(&session->frames, 0)),
            @"display_link_max_gap_ms": @((double)atomic_exchange(&session->maxFrameGap, 0) / 1000.0),
            @"memory_bytes": @(status == KERN_SUCCESS ? memory.phys_footprint : 0),
            @"memory_available": @(status == KERN_SUCCESS),
            @"thermal_state": @(NSProcessInfo.processInfo.thermalState),
            @"main_queue_pending_ms": @(requested ? (now - (double)requested / 1000000.0) * 1000 : 0)
        } to:session at:now];
    }
    if (now - session.lastSave >= 2) {
        session.lastSave = now;
        [self persist:[self report:session reason:@"interrupted_if_not_finished"]];
    }
}
- (void)stop:(NSString *)reason {
    // 既可由主线程按钮调用，也可由后台计时器调用；唯一胜者负责收口。
    AMPerfSession *session = self.session;
    if (!session || !atomic_exchange(&session->active, false)) return;
    double stopped = AMPerfNow();
    atomic_store(&AMPerfRecording, false);
    dispatch_source_cancel(session.timer);
    dispatch_async(self.queue, ^{
        session.stopped = stopped;
        uint64_t ping = atomic_load(&session->pingAt);
        [self addEvent:@"capture.stopped" fields:@{@"reason": reason ?: @"user",
            @"main_queue_pending_ms": @(ping ? MAX(0, (stopped - (double)ping / 1000000) * 1000) : 0),
            @"display_link_frames_remaining": @(atomic_exchange(&session->frames, 0)),
            @"display_link_max_gap_ms": @((double)atomic_exchange(&session->maxFrameGap, 0) / 1000)}
            to:session at:stopped];
        NSData *data = [self report:session reason:reason ?: @"user"];
        BOOL saved = [self persist:data]; session.finished = YES;
        dispatch_source_set_event_handler(session.timer, nil);
        session.timer = nil;
        // 不在诊断期间读取全量系统日志，也不把任何内容送入崩溃信号处理器。
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.session != session) return;
            [self.displayLink invalidate]; self.displayLink = nil;
            AMPerfRemoveEventHook();
            [NSNotificationCenter.defaultCenter removeObserver:self];
            self.pending = data; self.saved = saved; self.session = nil;
            if (self.backgroundTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
                self.backgroundTask = UIBackgroundTaskInvalid;
            }
            [self.hudButton setTitle:@"诊断已结束 · 查看" forState:UIControlStateNormal];
            if (!data) self.message = @"日志整理失败，请重新诊断。";
            [self changed];
            if ([reason isEqualToString:@"user"]) [self showReport];
        });
    });
}
- (void)captureTouch:(UIEvent *)event {
    AMPerfSession *session = self.session;
    if (!session || event.type != UIEventTypeTouches) return;
    UITouch *touch = event.allTouches.anyObject;
    if (!touch || [touch.window isKindOfClass:AMPerfHUDWindow.class] || touch.phase == UITouchPhaseStationary) return;
    double now = AMPerfNow();
    if (touch.phase == UITouchPhaseMoved && now - session.lastTouch < 0.1) return;
    session.lastTouch = now;
    CGPoint point = [touch locationInView:touch.window];
    CGSize size = touch.window.bounds.size;
    [self append:@"input.touch" fields:@{@"phase": @(touch.phase), @"touches": @(event.allTouches.count),
        @"view_class": AMPerfShort(NSStringFromClass(touch.view.class)),
        @"x_bin": @(size.width > 0 ? (NSInteger)(20 * point.x / size.width) : 0),
        @"y_bin": @(size.height > 0 ? (NSInteger)(20 * point.y / size.height) : 0)} session:session];
}
- (void)keyboard:(NSNotification *)notification {
    AMProjBetaDiagnosticsNote(@"input.keyboard", [notification.name isEqual:UIKeyboardWillShowNotification] ? @"show" : @"hide");
}
- (void)background:(NSNotification *)notification {
    (void)notification;
    if (!atomic_load(&AMPerfRecording)) return;
    self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"SaveBetaDiagnostics"
        expirationHandler:^{
            if (self.backgroundTask != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
                self.backgroundTask = UIBackgroundTaskInvalid;
            }
        }];
    [self stop:@"background"];
}
- (void)showHUD {
    UIViewController *top = AMPerfTopController();
    UIWindowScene *scene = top.viewIfLoaded.window.windowScene;
    if (!scene) return;
    AMPerfHUDWindow *window = [[AMPerfHUDWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds; window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelNormal + 1;
    UIViewController *root = [UIViewController new]; root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = [AMPerfTeal() colorWithAlphaComponent:0.94];
    button.layer.cornerRadius = 15;
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    [button setTitleColor:AMPerfInk() forState:UIControlStateNormal];
    [button setTitle:@"诊断中 00 秒 · 结束" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(hudTapped) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:46],
        [button.centerXAnchor constraintEqualToAnchor:root.view.centerXAnchor],
        [button.widthAnchor constraintEqualToConstant:210], [button.heightAnchor constraintEqualToConstant:32]]];
    self.hud = window; self.hudButton = button;
    window.hidden = NO; // 不 makeKey，保留编辑器和键盘原有焦点。
}
- (void)hudTapped {
    if (atomic_load(&AMPerfRecording)) [self stop:@"user"];
    else if (!self.session) [self showReport];
}
- (void)showReport {
    UIViewController *top = AMPerfTopController();
    if (!top || [top isKindOfClass:AMPerfController.class]) return;
    AMPerfController *controller = [AMPerfController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:navigation animated:YES completion:nil];
}
- (void)upload {
    if (self.uploading || !self.pending || self.session) return;
    NSData *data = self.pending;
    NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *captureID = report[@"capture_id"];
    if (![captureID isKindOfClass:NSString.class] || !captureID.length) return;
    self.uploading = YES; self.message = nil; [self changed];
    AMCloudSubmitPerformanceTicket(captureID, data, ^(BOOL ok, NSString *ticket, NSString *message) {
        self.uploading = NO; self.message = message;
        if (ok) {
            self.ticketID = ticket; self.pending = nil;
            dispatch_async(self.queue, ^{ [NSFileManager.defaultManager removeItemAtPath:AMPerfPath() error:nil]; });
            self.hud.hidden = YES; self.hud = nil; self.hudButton = nil;
        }
        [self changed];
    });
}
@end

static UILabel *AMPerfLabel(CGFloat size, UIFontWeight weight) {
    UILabel *label = [UILabel new]; label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:size weight:weight]; label.textColor = AMPerfInk();
    return label;
}
@implementation AMPerfController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AMPerfBackground(); self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(close)];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.8]; stack.layer.cornerRadius = 16;
    stack.layer.borderColor = [AMPerfTeal() colorWithAlphaComponent:0.18].CGColor; stack.layer.borderWidth = 1;
    stack.layoutMarginsRelativeArrangement = YES; stack.layoutMargins = UIEdgeInsetsMake(24, 20, 24, 20);
    [scroll addSubview:stack];
    self.headline = AMPerfLabel(23, UIFontWeightSemibold);
    self.body = AMPerfLabel(14, UIFontWeightRegular);
    self.body.textColor = [UIColor colorWithRed:0.353 green:0.541 blue:0.533 alpha:1];
    self.primary = [[AMPerfButton alloc] initWithFrame:CGRectZero];
    [self.primary addTarget:self action:@selector(primaryTapped) forControlEvents:UIControlEventTouchUpInside];
    self.secondary = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.secondary setTitleColor:AMPerfInk() forState:UIControlStateNormal];
    [self.secondary addTarget:self action:@selector(secondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[self.headline, self.body, self.primary, self.secondary]) [stack addArrangedSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-14],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-28],
        [self.primary.heightAnchor constraintEqualToConstant:48], [self.secondary.heightAnchor constraintEqualToConstant:44]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:AMPerfChanged object:nil];
    [self refresh];
}
- (void)refresh {
    AMPerfRecorder *recorder = AMPerfRecorder.shared;
    self.primary.enabled = !recorder.uploading && !(recorder.session && !atomic_load(&AMPerfRecording));
    self.secondary.hidden = self.menu || recorder.uploading;
    if (self.menu) {
        self.title = @"测试与诊断"; self.headline.text = @"卡顿诊断";
        self.body.text = @"复现操作，帮助定位卡顿。\n\n仅 Beta 测试版提供。";
        [self.primary setTitle:@"打开卡顿诊断" forState:UIControlStateNormal]; return;
    }
    self.title = @"卡顿诊断";
    if (recorder.ticketID.length) {
        self.headline.text = [NSString stringWithFormat:@"上传成功\n诊断编号 #%@", recorder.ticketID];
        self.body.text = @"把诊断编号发给管理员，即可在反馈与工单中对应查看。";
        [self.primary setTitle:@"复制编号" forState:UIControlStateNormal];
        [self.secondary setTitle:@"完成" forState:UIControlStateNormal];
    } else if (recorder.session) {
        self.headline.text = atomic_load(&AMPerfRecording) ? @"正在诊断" : @"正在整理日志…";
        self.body.text = @"进入工程正常操作，复现卡顿后点顶部「结束」。最长记录 60 秒。";
        [self.primary setTitle:@"结束诊断" forState:UIControlStateNormal];
        [self.secondary setTitle:@"返回工程继续操作" forState:UIControlStateNormal];
    } else if (recorder.pending) {
        NSDictionary *report = [NSJSONSerialization JSONObjectWithData:recorder.pending options:0 error:nil];
        self.headline.text = @"诊断已结束";
        self.body.text = [NSString stringWithFormat:@"记录时长 %.1f 秒\n%@\n\n%@",
            [report[@"duration_ms"] doubleValue] / 1000,
            recorder.saved ? @"日志已保存在本机。" : @"日志暂存在本次会话，请勿退出应用。",
            recorder.message ?: @"上传后，管理员可查看本次性能日志。不会上传输入文字、素材或截图。"];
        [self.primary setTitle:recorder.uploading ? @"正在上传…" : @"上传诊断日志" forState:UIControlStateNormal];
        [self.secondary setTitle:@"暂不上传" forState:UIControlStateNormal];
        if (!self.navigationItem.leftBarButtonItem) self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithTitle:@"重新诊断" style:UIBarButtonItemStylePlain target:self action:@selector(discardAndStart)];
    } else {
        self.headline.text = @"记录一次卡顿";
        self.body.text = recorder.message ?: @"开始后进入工程，正常操作并复现卡顿。\n\n最长 60 秒，到时自动停止，等待你确认上传。\n不采集文字与素材内容。切入后台会停止并保存已有记录。";
        [self.primary setTitle:@"开始诊断" forState:UIControlStateNormal];
        [self.secondary setTitle:@"返回" forState:UIControlStateNormal];
    }
    if (!recorder.pending) self.navigationItem.leftBarButtonItem = nil;
    self.modalInPresentation = recorder.uploading;
    self.navigationController.modalInPresentation = recorder.uploading;
    self.navigationItem.leftBarButtonItem.enabled = !recorder.uploading;
}
- (void)primaryTapped {
    AMPerfRecorder *recorder = AMPerfRecorder.shared;
    if (self.menu) {
        [self.navigationController pushViewController:[AMPerfController new] animated:YES]; return;
    }
    if (recorder.ticketID.length) {
        UIPasteboard.generalPasteboard.string = [@"#" stringByAppendingString:recorder.ticketID];
        [self.primary setTitle:@"已复制编号" forState:UIControlStateNormal];
    } else if (recorder.session) [recorder stop:@"user"];
    else if (recorder.pending) [recorder upload];
    else { [recorder start]; [self returnToEditor]; }
}
- (void)discardAndStart {
    AMPerfRecorder *recorder = AMPerfRecorder.shared;
    if (recorder.uploading || recorder.session) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重新诊断？"
        message:@"尚未上传的这份日志将被替换。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重新诊断" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        recorder.pending = nil; recorder.ticketID = nil; recorder.message = nil;
        // 与后台快照共用串行队列，防止旧删除任务晚于新会话写入。
        dispatch_async(recorder.queue, ^{ [NSFileManager.defaultManager removeItemAtPath:AMPerfPath() error:nil]; });
        [recorder start]; [self returnToEditor];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)returnToEditor {
    UINavigationController *navigation = self.navigationController;
    if (navigation.presentingViewController) [navigation dismissViewControllerAnimated:YES completion:nil];
    else [navigation popToRootViewControllerAnimated:YES];
}
- (void)secondaryTapped { [self close]; }
- (void)close {
    if (AMPerfRecorder.shared.uploading) return;
    if (AMPerfRecorder.shared.ticketID.length) {
        AMPerfRecorder.shared.ticketID = nil; AMPerfRecorder.shared.message = nil;
    }
    AMPerfRecorder.shared.hud.hidden = AMPerfRecorder.shared.session ? NO : YES;
    if (self.navigationController.viewControllers.firstObject != self)
        [self.navigationController popViewControllerAnimated:YES];
    else [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

BOOL AMProjBetaDiagnosticsAvailable(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [info[@"CFBundleVersion"] isEqual:@"865"] && [info[@"CFBundleShortVersionString"] isEqual:@"6.2.58"];
}
NSString *AMProjBetaDiagnosticsAccountScript(void) {
    return @"(function(){if(location.protocol!=='https:'||location.hostname!=='am.meowcr.cn'||"
        "(location.port&&location.port!=='443')||location.pathname!=='/me.html'){return;}"
        "var host=document.getElementById('meContent'),logout=document.getElementById('btnLogout');"
        "if(!host||!logout||document.getElementById('am-beta-diagnostics')){return;}"
        "var entry=document.createElement('button');entry.id='am-beta-diagnostics';entry.type='button';"
        "entry.className='af-glass me-card mt12';"
        "entry.style.cssText='width:100%;padding:14px;display:flex;align-items:center;gap:8px;text-align:left;color:inherit;font:inherit;cursor:pointer';"
        "entry.innerHTML='<span style=\"display:flex;align-items:center;justify-content:center;width:36px;height:36px;border-radius:10px;background:rgba(57,197,187,.12);color:var(--af-brand-700)\">'+"
        "(window.AF?AF.icon('settings',18):'')+'</span><span style=\"flex:1\"><span class=\"s14 w6\" style=\"display:block\">测试与诊断</span>"
        "<span class=\"s11 af-t3 mt2\" style=\"display:block\">Beta 专属 · 卡顿反馈</span></span><span aria-hidden=\"true\">›</span>';"
        "entry.onclick=function(){var h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.amAccount;"
        "if(h){h.postMessage({type:'diagnostics'});}};logout.parentElement.before(entry);})();";
}
void AMProjBetaDiagnosticsPresent(UIViewController *presenter) {
    if (!NSThread.isMainThread || !AMProjBetaDiagnosticsAvailable() || !presenter) return;
    AMPerfController *controller = [AMPerfController new]; controller.menu = YES;
    if (presenter.navigationController) [presenter.navigationController pushViewController:controller animated:YES];
    else {
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
        [presenter presentViewController:navigation animated:YES completion:nil];
    }
}
void AMProjBetaDiagnosticsNote(NSString *event, NSString *detail) {
    if (!atomic_load(&AMPerfRecording) || !NSThread.isMainThread) return;
    AMPerfRecorder *recorder = AMPerfRecorder.shared;
    [recorder append:event fields:@{@"detail": AMPerfShort(detail)} session:recorder.session];
}
CFTimeInterval AMProjBetaDiagnosticsBeginSpan(void) {
    return atomic_load(&AMPerfRecording) ? AMPerfNow() : 0;
}
void AMProjBetaDiagnosticsEndSpan(NSString *name, CFTimeInterval start) {
    if (!start || !atomic_load(&AMPerfRecording) || !NSThread.isMainThread) return;
    double elapsed = (AMPerfNow() - start) * 1000;
    if (elapsed < 4) return;
    AMPerfRecorder *recorder = AMPerfRecorder.shared;
    [recorder append:@"plugin.slow_span" fields:@{@"name": AMPerfShort(name), @"elapsed_ms": @(elapsed)} session:recorder.session];
}
