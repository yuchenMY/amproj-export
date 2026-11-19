//
//  AMProjCrashReporter.m
//  猫鹤 AM · 865
//
//  目的：用户闪退后，下一次启动能看到「上次崩溃了」，并把日志一键上传成工单。
//
//  设计纪律（与 r72/r89/r121 三次闪退教训一致）：
//  1. 信号处理器里只做 async-signal-safe 的事：write() + 预先渲染好的面包屑，
//     格式化用 snprintf，不碰 ObjC、不 malloc、不读文件。
//  2. 未捕获异常处理器可以走 ObjC（此时进程还活着），写完整栈与异常原因。
//  3. 崩溃报告只在下次启动时做「补全」（版本、机型、日志尾巴），
//     因为那一步可以安全地读文件、读 Info.plist。
//  4. 本模块任何一步失败都不允许影响 App：全部 @try 兜底，失败就静默。
//  5. 日志文件名固定，写完即覆盖，不会膨胀；单份上限 128KB。
//

#import "AMProjCrashReporter.h"
#if AMPROJ_CLOUD_SYNC
#import "AMCloudSync.h"
#endif

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <signal.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <limits.h>
#import <unistd.h>
#import <fcntl.h>
#import <time.h>
#import <dlfcn.h>
#import <sys/time.h>
#import <sys/utsname.h>

// 系统 .ips 才是权威栈；这里只负责「用户点什么 → 崩在哪一步」这条线。
// backtrace 在 iOS 上存在于 libSystem 但不在公开头文件里：用 dlsym 拿，
// 拿不到就不写栈，绝不因为链接不到的符号让整个 dylib 加载失败。
typedef int (*AMProjBacktraceFn)(void **buffer, int size);
typedef void (*AMProjBacktraceSymbolsFdFn)(void *const *buffer, int size, int fd);

static NSString *const AMProjCrashReportName = @"AMProjExport.crashreport";
static NSString *const AMProjCrashSessionName = @"AMProjExport.session";
static NSString *const AMProjCrashPromptMarkName = @"AMProjExport.crashprompt";

// 面包屑：固定 4KB，进程内预渲染，信号处理器里直接 write 出去。
#define AMProjCrashTrailCapacity 4096
static char gAMProjCrashTrail[AMProjCrashTrailCapacity];
static long gAMProjCrashTrailLength = 0;

static char gAMProjCrashReportPath[PATH_MAX];
static char gAMProjCrashSessionPath[PATH_MAX];
static AMProjBacktraceFn gAMProjBacktrace = NULL;
static AMProjBacktraceSymbolsFdFn gAMProjBacktraceSymbolsFd = NULL;

static BOOL gAMProjCrashInstalled = NO;
static BOOL gAMProjCrashPromptShown = NO;

#pragma mark - 路径

static NSString *AMProjCrashCacheDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject;
    return base.length ? base : NSTemporaryDirectory();
}

static NSString *AMProjCrashPathForName(NSString *name) {
    return [AMProjCrashCacheDirectory() stringByAppendingPathComponent:name ?: @""];
}

static void AMProjCrashCopyPath(const char *source, char *destination) {
    if (!source || !destination) return;
    size_t length = strlen(source);
    if (length >= PATH_MAX) length = PATH_MAX - 1;
    memcpy(destination, source, length);
    destination[length] = '\0';
}

#pragma mark - 面包屑

void AMProjCrashNote(NSString *format, ...) {
    if (!format.length) return;
    @autoreleasepool {
        va_list args;
        va_start(args, format);
        NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        if (!line.length) return;
        if (line.length > 160) line = [line substringToIndex:160];
        // 换行会破坏「一行一条」的格式，直接压成空格。
        line = [line stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        const char *utf8 = line.UTF8String;
        if (!utf8) return;

        long length = __atomic_load_n(&gAMProjCrashTrailLength, __ATOMIC_ACQUIRE);
        if (length < 0 || length > AMProjCrashTrailCapacity - 1) length = 0;
        int available = (int)(AMProjCrashTrailCapacity - (size_t)length);
        if (available < 64) {
            // 满了就清空重来，保留最近这一段，避免无限增长。
            length = 0;
            available = (int)AMProjCrashTrailCapacity;
            gAMProjCrashTrail[0] = '\0';
        }
        int written = snprintf(gAMProjCrashTrail + length, (size_t)available,
                               "%lld %s\n", (long long)time(NULL), utf8);
        if (written <= 0) return;
        long next = length + written;
        if (next > AMProjCrashTrailCapacity - 1) next = AMProjCrashTrailCapacity - 1;
        __atomic_store_n(&gAMProjCrashTrailLength, next, __ATOMIC_RELEASE);
    }
}

#pragma mark - 环境信息

static NSString *AMProjCrashBuildTag(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *shortVersion = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
        ? info[@"CFBundleShortVersionString"] : @"?";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class]
        ? info[@"CFBundleVersion"] : @"?";
    return [NSString stringWithFormat:@"%@ (%@)", shortVersion, build];
}

static NSString *AMProjCrashDeviceSummary(void) {
    UIDevice *device = UIDevice.currentDevice;
    NSString *model = device.model ?: @"iOS";
    NSString *machine = nil;
    // uname 拿具体机型（iPhone15,2 之类），拿不到就退回 model。
    @try {
        struct utsname info;
        if (uname(&info) == 0) machine = [NSString stringWithUTF8String:info.machine];
    } @catch (__unused NSException *exception) {
        machine = nil;
    }
    NSString *system = [NSString stringWithFormat:@"%@ %@",
                        device.systemName ?: @"iOS", device.systemVersion ?: @"?"];
    if (machine.length) {
        return [NSString stringWithFormat:@"%@ / %@ / %@", model, machine, system];
    }
    return [NSString stringWithFormat:@"%@ / %@", model, system];
}

static NSString *AMProjCrashTailOfLog(NSString *name, NSUInteger maxBytes) {
    NSString *path = AMProjCrashPathForName(name);
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return @"";
    NSData *slice = data;
    if (data.length > maxBytes) {
        slice = [data subdataWithRange:NSMakeRange(data.length - maxBytes, maxBytes)];
    }
    NSString *text = [[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding];
    if (!text.length) text = @"(日志不是 UTF-8，已跳过)";
    return text ?: @"";
}

static NSString *AMProjCrashEnvironmentText(void) {
    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"env.app=%@\n", AMProjCrashBuildTag()];
    [text appendFormat:@"env.device=%@\n", AMProjCrashDeviceSummary()];
    [text appendFormat:@"env.bundle=%@\n", NSBundle.mainBundle.bundleIdentifier ?: @"?"];
    [text appendFormat:@"env.collected=%lld\n", (long long)time(NULL)];
    [text appendFormat:@"env.ios_app_group=%@\n",
        [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                               inDomains:NSUserDomainMask].firstObject.path ?: @"?"];

    NSString *pluginLog = AMProjCrashTailOfLog(@"AMProjExport.pluginlog", 24 * 1024);
    if (pluginLog.length) {
        [text appendString:@"\n--- pluginlog (tail) ---\n"];
        [text appendString:pluginLog];
        [text appendString:@"\n"];
    }
    NSString *bannerLog = AMProjCrashTailOfLog(@"AMProjExport.bannerlog", 16 * 1024);
    if (bannerLog.length) {
        [text appendString:@"\n--- bannerlog (tail) ---\n"];
        [text appendString:bannerLog];
        [text appendString:@"\n"];
    }
    return text;
}

#pragma mark - 写报告

static void AMProjCrashWriteReport(NSString *body) {
    if (!body.length) return;
    @try {
        if (body.length > 128 * 1024) {
            body = [body substringToIndex:128 * 1024];
        }
        NSString *path = AMProjCrashPathForName(AMProjCrashReportName);
        [body writeToFile:path atomically:YES
                 encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *exception) {
        // 写不进去就算了，不能让记录日志这件事把 App 弄崩。
    }
}

static void AMProjCrashRecordUncleanExit(NSString *reason) {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"猫鹤AM 崩溃报告\n"];
    [text appendFormat:@"kind=%@\n", reason ?: @"unclean_exit"];
    [text appendFormat:@"time=%lld\n", (long long)time(NULL)];
    [text appendFormat:@"app=%@\n", AMProjCrashBuildTag()];
    [text appendString:@"note=上一轮进程没有正常结束（闪退 / 被系统杀掉 / 用户强退），下面是上一次留下的面包屑。\n"];
    long length = __atomic_load_n(&gAMProjCrashTrailLength, __ATOMIC_ACQUIRE);
    if (length > 0 && length < AMProjCrashTrailCapacity) {
        [text appendString:@"\n--- trail ---\n"];
        NSString *trail = [[NSString alloc] initWithBytes:gAMProjCrashTrail
                                                   length:(NSUInteger)length
                                                 encoding:NSUTF8StringEncoding];
        if (trail.length) [text appendString:trail];
    }
    AMProjCrashWriteReport(text);
}

#pragma mark - 信号 / 异常处理器

static void AMProjCrashSignalHandler(int signalNumber) {
    int fd = -1;
    if (gAMProjCrashReportPath[0]) {
        fd = open(gAMProjCrashReportPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    }
    if (fd >= 0) {
        char header[256];
        int length = snprintf(header, sizeof(header),
                              "猫鹤AM 崩溃报告\nkind=signal\nsignal=%d\npid=%d\ntime=%lld\n",
                              signalNumber, (int)getpid(), (long long)time(NULL));
        if (length > 0) {
            ssize_t ignored = write(fd, header, (size_t)length);
            (void)ignored;
        }
        long trailLength = __atomic_load_n(&gAMProjCrashTrailLength, __ATOMIC_ACQUIRE);
        if (trailLength > 0 && trailLength < AMProjCrashTrailCapacity) {
            ssize_t ignored = write(fd, "\n--- trail ---\n", 16);
            (void)ignored;
            ignored = write(fd, gAMProjCrashTrail, (size_t)trailLength);
            (void)ignored;
        }
        if (gAMProjBacktrace && gAMProjBacktraceSymbolsFd) {
            void *frames[48];
            int count = gAMProjBacktrace(frames, 48);
            if (count > 0) {
                ssize_t ignored = write(fd, "\n--- backtrace ---\n", 19);
                (void)ignored;
                gAMProjBacktraceSymbolsFd(frames, count, fd);
            }
        }
        close(fd);
    }
    // 交还给系统：恢复默认处理再抛一次，保证系统仍然生成 .ips。
    signal(signalNumber, SIG_DFL);
    raise(signalNumber);
}

static void AMProjCrashExceptionHandler(NSException *exception) {
    @autoreleasepool {
        NSMutableString *text = [NSMutableString string];
        [text appendString:@"猫鹤AM 崩溃报告\n"];
        [text appendString:@"kind=exception\n"];
        [text appendFormat:@"time=%lld\n", (long long)time(NULL)];
        [text appendFormat:@"app=%@\n", AMProjCrashBuildTag()];
        [text appendFormat:@"dev=%@\n", AMProjCrashDeviceSummary()];
        [text appendFormat:@"exception=%@\n", exception.name ?: @"?"];
        [text appendFormat:@"reason=%@\n", exception.reason ?: @"?"];
        NSArray<NSString *> *symbols = exception.callStackSymbols;
        if (symbols.count) {
            [text appendString:@"\n--- call stack ---\n"];
            NSUInteger limit = MIN(symbols.count, (NSUInteger)64);
            for (NSUInteger index = 0; index < limit; index++) {
                [text appendFormat:@"%@\n", symbols[index]];
            }
        }
        long length = __atomic_load_n(&gAMProjCrashTrailLength, __ATOMIC_ACQUIRE);
        if (length > 0 && length < AMProjCrashTrailCapacity) {
            NSString *trail = [[NSString alloc] initWithBytes:gAMProjCrashTrail
                                                       length:(NSUInteger)length
                                                     encoding:NSUTF8StringEncoding];
            if (trail.length) {
                [text appendString:@"\n--- trail ---\n"];
                [text appendString:trail];
            }
        }
        AMProjCrashWriteReport(text);
    }
}

#pragma mark - 启动哨兵

static NSString *AMProjCrashReadSession(void) {
    NSString *path = AMProjCrashPathForName(AMProjCrashSessionName);
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    return [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void AMProjCrashWriteSession(NSString *state) {
    @try {
        NSString *path = AMProjCrashPathForName(AMProjCrashSessionName);
        NSString *line = [NSString stringWithFormat:@"%@ %d %lld\n",
                          state ?: @"running", (int)getpid(), (long long)time(NULL)];
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - 生命周期钩子

void AMProjCrashReporterMarkBackgrounded(void) {
    AMProjCrashWriteSession(@"background");
}

void AMProjCrashReporterMarkForegrounded(void) {
    AMProjCrashWriteSession(@"running");
}

#pragma mark - 安装

// 演示/测试写入的报告带 kind=demo：下次启动直接删掉，不弹、不上传。
static BOOL AMProjCrashReportIsDemo(NSString *path) {
    if (!path.length) return NO;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    return [text containsString:@"kind=demo"];
}

void AMProjCrashReporterInstall(void) {
    if (gAMProjCrashInstalled) return;
    gAMProjCrashInstalled = YES;

    @try {
        NSString *reportPath = AMProjCrashPathForName(AMProjCrashReportName);
        AMProjCrashCopyPath(reportPath.UTF8String, gAMProjCrashReportPath);
        NSString *sessionPath = AMProjCrashPathForName(AMProjCrashSessionName);
        AMProjCrashCopyPath(sessionPath.UTF8String, gAMProjCrashSessionPath);

        void *handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_NOLOAD);
        if (!handle) handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW);
        if (handle) {
            gAMProjBacktrace = (AMProjBacktraceFn)dlsym(handle, "backtrace");
            gAMProjBacktraceSymbolsFd =
                (AMProjBacktraceSymbolsFdFn)dlsym(handle, "backtrace_symbols_fd");
            dlclose(handle);
        }
    } @catch (__unused NSException *exception) {
    }

    // 上一轮是 running 就说明没正常退出（闪退 / 强退 / 系统回收前台进程）。
    NSString *previous = AMProjCrashReadSession();
    BOOL previousWasRunning = [previous hasPrefix:@"running"];

    @try {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = AMProjCrashSignalHandler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_RESETHAND;
        int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
        for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
            sigaction(signals[index], &action, NULL);
        }
        NSSetUncaughtExceptionHandler(&AMProjCrashExceptionHandler);
    } @catch (__unused NSException *exception) {
    }

    if (previousWasRunning) {
        NSString *existing = AMProjCrashPathForName(AMProjCrashReportName);
        if (AMProjCrashReportIsDemo(existing)) {
            // 上一轮只是点了测试入口，不算崩溃。
            [[NSFileManager defaultManager] removeItemAtPath:existing error:NULL];
            NSLog(@"[AMProjExport] demo crash report cleared on launch");
        } else {
            BOOL hasBody = [NSData dataWithContentsOfFile:existing].length > 0;
            if (!hasBody) {
                // 信号处理器多半没跑起来（被 SIGKILL / watchdog 杀掉），
                // 这里补一份「上一轮没正常结束」的最小报告。
                AMProjCrashNote(@"session: 上一轮异常结束（无信号处理器报告）");
                AMProjCrashRecordUncleanExit(@"unclean_exit");
            }
        }
    }

    AMProjCrashWriteSession(@"running");
    AMProjCrashNote(@"launch: %@", AMProjCrashBuildTag());
}

#pragma mark - 待处理报告

NSString *AMProjCrashReporterPendingReportPath(void) {
    NSString *path = AMProjCrashPathForName(AMProjCrashReportName);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                               error:NULL];
    return attributes ? path : nil;
}

BOOL AMProjCrashReporterHasPendingReport(void) {
    return AMProjCrashReporterPendingReportPath() != nil;
}

NSString *AMProjCrashReporterPendingReportText(void) {
    NSString *path = AMProjCrashReporterPendingReportPath();
    if (!path) return nil;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!text.length) {
        text = @"(报告无法按 UTF-8 读取)";
    }
    return [text stringByAppendingFormat:@"\n%@", AMProjCrashEnvironmentText()];
}

void AMProjCrashReporterDiscardPending(void) {
    @try {
        NSString *path = AMProjCrashPathForName(AMProjCrashReportName);
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:
            AMProjCrashPathForName(AMProjCrashPromptMarkName) error:NULL];
    } @catch (__unused NSException *exception) {
    }
}

#pragma mark - 提示 UI

static UIViewController *AMProjCrashTopViewController(void) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow && !candidate.hidden) {
                    window = candidate;
                    break;
                }
            }
            if (!window) window = windowScene.windows.firstObject;
            if (window) break;
        }
    }
    if (!window) window = UIApplication.sharedApplication.keyWindow;

    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController &&
            !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
            continue;
        }
        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible =
                ((UINavigationController *)controller).visibleViewController;
            if (visible && visible != controller) { controller = visible; continue; }
        }
        if ([controller isKindOfClass:UITabBarController.class]) {
            UIViewController *selected =
                ((UITabBarController *)controller).selectedViewController;
            if (selected && selected != controller) { controller = selected; continue; }
        }
        break;
    }
    return controller;
}

static NSString *AMProjCrashSummaryLine(NSString *reportText) {
    NSString *kind = @"异常退出";
    for (NSString *line in [reportText componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"kind="]) {
            NSString *value = [line substringFromIndex:5];
            if ([value isEqualToString:@"signal"]) kind = @"崩溃（信号）";
            else if ([value isEqualToString:@"exception"]) kind = @"崩溃（异常）";
            else if ([value isEqualToString:@"unclean_exit"]) kind = @"异常退出";
            else if ([value isEqualToString:@"demo"]) kind = @"演示数据";
            break;
        }
    }
    return [NSString stringWithFormat:@"%@ · %@", kind, AMProjCrashBuildTag()];
}

#pragma mark - 提示 UI：一行横幅 + 底部抽屉（浅色，克制版）

static UIColor *AMProjCrashColor(NSUInteger rgbaHex, CGFloat alpha) {
    return [UIColor colorWithRed:((rgbaHex >> 16) & 0xFF) / 255.0
                           green:((rgbaHex >> 8) & 0xFF) / 255.0
                            blue:(rgbaHex & 0xFF) / 255.0
                           alpha:alpha];
}

// 首页那套浅色：白卡 + 近黑字 + 中灰说明。强调色只用在主按钮上，且是
// App 里「上传」那颗胶囊的淡紫（#C9C4FF），不用渐变、不用高饱和绿。
static UIColor *AMProjCrashInk(void) { return AMProjCrashColor(0x0B0F14, 1.0); }
static UIColor *AMProjCrashBody(void) { return AMProjCrashColor(0x5B6472, 1.0); }
static UIColor *AMProjCrashMute(void) { return AMProjCrashColor(0x9AA1AD, 1.0); }
static UIColor *AMProjCrashHairline(void) { return AMProjCrashColor(0xE8EBF0, 1.0); }
static UIColor *AMProjCrashAccent(void) { return AMProjCrashColor(0xC9C4FF, 1.0); }

static UIFont *AMProjCrashFont(CGFloat size, UIFontWeight weight) {
    return [UIFont systemFontOfSize:size weight:weight];
}

#pragma mark - 底部抽屉

@interface AMProjCrashSheet : UIViewController
@property (nonatomic, copy) NSString *headline;
@property (nonatomic, copy) NSString *meta;
@property (nonatomic, copy) NSString *bodyText;
@property (nonatomic, copy) NSString *primaryTitle;
@property (nonatomic, copy) NSString *secondaryTitle;
@property (nonatomic, copy) void (^primaryHandler)(void);
@property (nonatomic, copy) void (^secondaryHandler)(void);
@property (nonatomic, copy) void (^copyHandler)(void);
- (void)dismissSheet;
- (void)showStateWithHeadline:(NSString *)headline meta:(NSString *)meta
                     bodyText:(NSString *)body
                 primaryTitle:(NSString *)primaryTitle
               secondaryTitle:(NSString *)secondaryTitle;
@end

static void AMProjCrashUploadLog(AMProjCrashSheet *sheet, NSString *summary);

@implementation AMProjCrashSheet {
    UIView *_panel;
    UILabel *_headlineLabel;
    UILabel *_metaLabel;
    UILabel *_bodyLabel;
    UIButton *_primaryButton;
    UIButton *_secondaryButton;
    UIControl *_dimView;
    BOOL _dismissing;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 必须在 present 之前设置（r104 的教训：写进 viewDidLoad 等于没写）。
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _dimView = [[UIControl alloc] initWithFrame:self.view.bounds];
    _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [_dimView addTarget:self action:@selector(noop:)
       forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_dimView];

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = UIColor.whiteColor;
    _panel.layer.cornerRadius = 24;
    _panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [self.view addSubview:_panel];

    UIView *grabber = [[UIView alloc] initWithFrame:CGRectZero];
    grabber.backgroundColor = AMProjCrashColor(0xDDE1E7, 1.0);
    grabber.layer.cornerRadius = 2.0;
    grabber.tag = 9001;
    [_panel addSubview:grabber];

    _headlineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headlineLabel.textColor = AMProjCrashInk();
    _headlineLabel.font = AMProjCrashFont(20, UIFontWeightBold);
    _headlineLabel.numberOfLines = 1;
    [_panel addSubview:_headlineLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.textColor = AMProjCrashMute();
    _metaLabel.font = AMProjCrashFont(12, UIFontWeightRegular);
    _metaLabel.numberOfLines = 1;
    [_panel addSubview:_metaLabel];

    _bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bodyLabel.textColor = AMProjCrashBody();
    _bodyLabel.numberOfLines = 0;
    [_panel addSubview:_bodyLabel];

    _primaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _primaryButton.backgroundColor = AMProjCrashAccent();
    _primaryButton.layer.cornerRadius = 16;
    _primaryButton.layer.masksToBounds = YES;
    _primaryButton.titleLabel.font = AMProjCrashFont(16, UIFontWeightSemibold);
    [_primaryButton setTitleColor:AMProjCrashColor(0x1A1636, 1.0)
                         forState:UIControlStateNormal];
    [_primaryButton addTarget:self action:@selector(primaryTapped:)
             forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_primaryButton];

    _secondaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _secondaryButton.titleLabel.font = AMProjCrashFont(13.5, UIFontWeightRegular);
    [_secondaryButton setTitleColor:AMProjCrashMute() forState:UIControlStateNormal];
    [_secondaryButton addTarget:self action:@selector(secondaryTapped:)
               forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_secondaryButton];

    [self applyContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat pad = 28.0;
    CGFloat inner = width - pad * 2;

    CGSize bodySize = [_bodyLabel sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)];
    CGFloat bodyHeight = ceil(bodySize.height);
    BOOL hasMeta = (_metaLabel.text.length > 0);
    BOOL hasSecondary = (_secondaryButton.titleLabel.text.length > 0 &&
                         !_secondaryButton.hidden);

    CGFloat contentHeight = 26 + 26                       // 抓手留白 + 标题
        + (hasMeta ? 6 + 16 : 0)                          // meta
        + 18 + bodyHeight
        + 28 + 52                                          // 主按钮
        + (hasSecondary ? 12 + 20 : 0)
        + 26;
    CGFloat panelHeight = contentHeight + self.view.safeAreaInsets.bottom;

    _panel.frame = CGRectMake(0, CGRectGetHeight(self.view.bounds) - panelHeight,
                              width, panelHeight);
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.10;
    _panel.layer.shadowRadius = 20;
    _panel.layer.shadowOffset = CGSizeMake(0, -6);

    UIView *grabber = [_panel viewWithTag:9001];
    grabber.frame = CGRectMake((width - 32) / 2.0, 10, 32, 4);

    CGFloat y = 26;
    _headlineLabel.frame = CGRectMake(pad, y, inner, 26);
    y += 26;
    if (hasMeta) {
        _metaLabel.frame = CGRectMake(pad, y + 6, inner, 16);
        y += 6 + 16;
    }
    y += 18;
    _bodyLabel.frame = CGRectMake(pad, y, inner, bodyHeight);
    y += bodyHeight + 28;

    _primaryButton.frame = CGRectMake(pad, y, inner, 52);
    y += 52;

    if (hasSecondary) {
        _secondaryButton.frame = CGRectMake(0, y + 12, width, 20);
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGRect target = _panel.frame;
    _panel.frame = CGRectOffset(target, 0, height);
    [UIView animateWithDuration:0.32 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_panel.frame = target;
    } completion:nil];
}

- (void)noop:(__unused id)sender { [self dismissSheet]; }

- (NSAttributedString *)attributedBody:(NSString *)text {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 7.0;
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: AMProjCrashFont(14, UIFontWeightRegular),
        NSForegroundColorAttributeName: AMProjCrashBody(),
        NSParagraphStyleAttributeName: style
    }];
}

- (void)applyContent {
    _headlineLabel.text = self.headline ?: @"";
    _metaLabel.text = self.meta ?: @"";
    _bodyLabel.attributedText = [self attributedBody:self.bodyText ?: @""];
    [_primaryButton setTitle:self.primaryTitle ?: @"好" forState:UIControlStateNormal];
    [_secondaryButton setTitle:(self.secondaryTitle ?: @"")
                      forState:UIControlStateNormal];
    _metaLabel.hidden = (self.meta.length == 0);
    _secondaryButton.hidden = (self.secondaryTitle.length == 0);
    [self.view setNeedsLayout];
}

- (void)primaryTapped:(__unused id)sender {
    void (^handler)(void) = self.primaryHandler;
    if (handler) handler();
}

- (void)secondaryTapped:(__unused id)sender {
    void (^handler)(void) = self.secondaryHandler;
    if (handler) handler();
}

- (void)dismissSheet {
    if (_dismissing) return;
    _dismissing = YES;
    [UIView animateWithDuration:0.22 animations:^{
        self->_panel.transform = CGAffineTransformMakeTranslation(
            0, CGRectGetHeight(self.view.bounds));
        self->_dimView.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (void)showStateWithHeadline:(NSString *)headline meta:(NSString *)meta
                     bodyText:(NSString *)body
                 primaryTitle:(NSString *)primaryTitle
               secondaryTitle:(NSString *)secondaryTitle {
    self.headline = headline;
    self.meta = meta;
    self.bodyText = body;
    self.primaryTitle = primaryTitle;
    self.secondaryTitle = secondaryTitle;
    [self applyContent];
    [UIView animateWithDuration:0.18 animations:^{
        [self.view layoutIfNeeded];
    }];
}

@end

#pragma mark - 一行横幅

@interface AMProjCrashBanner : UIView
@property (nonatomic, copy) void (^openHandler)(void);
- (void)showInWindow:(UIWindow *)window;
- (void)hide;
@end

@implementation AMProjCrashBanner {
    UILabel *_titleLabel;
    UILabel *_actionLabel;
    UILabel *_chevronLabel;
    NSTimer *_autoHideTimer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.whiteColor;
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        self.layer.borderColor = AMProjCrashHairline().CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.07;
        self.layer.shadowRadius = 12;
        self.layer.shadowOffset = CGSizeMake(0, 5);

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.text = @"上次崩溃了";
        _titleLabel.textColor = AMProjCrashInk();
        _titleLabel.font = AMProjCrashFont(13.5, UIFontWeightSemibold);
        [self addSubview:_titleLabel];

        _actionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _actionLabel.text = @"发送日志";
        _actionLabel.textColor = AMProjCrashInk();
        _actionLabel.font = AMProjCrashFont(13, UIFontWeightRegular);
        _actionLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_actionLabel];

        _chevronLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _chevronLabel.text = @"›";
        _chevronLabel.textColor = AMProjCrashMute();
        _chevronLabel.font = AMProjCrashFont(16, UIFontWeightRegular);
        _chevronLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_chevronLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(openTapped:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat pad = 18;

    CGFloat chevronWidth = 14;
    CGFloat actionWidth = 62;
    _chevronLabel.frame = CGRectMake(w - pad - chevronWidth, (h - 20) / 2.0,
                                     chevronWidth, 20);
    _actionLabel.frame = CGRectMake(CGRectGetMinX(_chevronLabel.frame) - actionWidth - 2,
                                    (h - 18) / 2.0, actionWidth, 18);
    CGFloat titleWidth = CGRectGetMinX(_actionLabel.frame) - 12 - pad;
    _titleLabel.frame = CGRectMake(pad, (h - 18) / 2.0, titleWidth, 18);
}

- (void)showInWindow:(UIWindow *)window {
    if (!window) return;
    CGFloat width = CGRectGetWidth(window.bounds) - 32;
    CGFloat top = window.safeAreaInsets.top + 8;
    CGFloat height = 52;
    self.frame = CGRectMake(16, top - height - 6, width, height);
    [window addSubview:self];
    [UIView animateWithDuration:0.3 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.frame = CGRectMake(16, top, width, height);
    } completion:nil];
    // 12 秒后自动收起：它只是个提示条，不该长期占据屏幕顶部。
    _autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:12.0
                                                      target:self
                                                    selector:@selector(autoHide:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)autoHide:(__unused NSTimer *)timer { [self hide]; }

- (void)openTapped:(__unused id)sender {
    void (^handler)(void) = self.openHandler;
    [self hide];
    if (handler) handler();
}

- (void)hide {
    [_autoHideTimer invalidate];
    _autoHideTimer = nil;
    [UIView animateWithDuration:0.22 animations:^{
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeTranslation(0, -20);
    } completion:^(__unused BOOL finished) {
        [self removeFromSuperview];
    }];
}

@end

static AMProjCrashBanner *gAMProjCrashBanner = nil;

#pragma mark - 上传

static void AMProjCrashUploadLog(AMProjCrashSheet *sheet, NSString *summary) {
    if (!sheet) return;
    NSString *path = AMProjCrashReporterPendingReportPath();
    if (!path) {
        [sheet showStateWithHeadline:@"日志已经不在了" meta:@""
                            bodyText:@"可能是系统清理了缓存，这次不用发了。"
                        primaryTitle:@"好" secondaryTitle:nil];
        sheet.primaryHandler = ^{ [sheet dismissSheet]; };
        return;
    }
#if AMPROJ_CLOUD_SYNC
    if (!AMCloudSyncHasLoggedInAccount()) {
        [sheet showStateWithHeadline:@"需要先登录" meta:@"上传日志要走猫鹤账户"
                            bodyText:@"登录后回到这里，再点一次「发送日志」就可以了。"
                        primaryTitle:@"去登录" secondaryTitle:@"复制日志"];
        sheet.primaryHandler = ^{
            AMCloudSyncShowAccountLoginFrom(AMProjCrashTopViewController());
            [sheet dismissSheet];
        };
        sheet.secondaryHandler = sheet.copyHandler;
        return;
    }
    NSString *content = [NSString stringWithFormat:
        @"用户在 App 内点击“发送日志”。\n%@\n日志见附件。", summary ?: @""];
    [sheet showStateWithHeadline:@"正在发送…" meta:summary ?: @""
                        bodyText:@"日志正在发到猫鹤服务器，几秒钟就好。"
                    primaryTitle:@"请稍候" secondaryTitle:nil];
    sheet.primaryHandler = nil;
    __weak AMProjCrashSheet *weakSheet = sheet;
    AMCloudSubmitCrashTicket(@"猫鹤AM 崩溃日志", content, path,
        ^(BOOL ok, NSString *messageText) {
            AMProjCrashSheet *target = weakSheet;
            if (!target) return;
            if (ok) {
                AMProjCrashReporterDiscardPending();
                [target showStateWithHeadline:@"已收到" meta:@""
                                    bodyText:messageText ?: @"日志已经到我们手上了。"
                                primaryTitle:@"好" secondaryTitle:nil];
                target.primaryHandler = ^{ [target dismissSheet]; };
            } else {
                [target showStateWithHeadline:@"没发出去" meta:@""
                                    bodyText:messageText ?: @"网络不太好，稍后再试一次。"
                                primaryTitle:@"重试" secondaryTitle:@"复制日志"];
                __weak AMProjCrashSheet *retrySheet = target;
                target.primaryHandler = ^{
                    AMProjCrashSheet *strong = retrySheet;
                    if (strong) AMProjCrashUploadLog(strong, summary);
                };
                target.secondaryHandler = target.copyHandler;
            }
        });
#else
    [sheet showStateWithHeadline:@"这个版本不支持上传" meta:@""
                        bodyText:@"可以把日志内容复制下来发给猫鹤。"
                    primaryTitle:@"好" secondaryTitle:nil];
    sheet.primaryHandler = ^{ [sheet dismissSheet]; };
#endif
}

#pragma mark - 入口

static void AMProjCrashPresentSheet(NSString *reportText, NSString *summary) {
    UIViewController *presenter = AMProjCrashTopViewController();
    if (!presenter || presenter.presentedViewController) return;

    AMProjCrashSheet *sheet = [[AMProjCrashSheet alloc] init];
    sheet.headline = @"上次崩溃了";
    sheet.meta = summary;
    sheet.bodyText = @"崩溃时的状态已经记录下来了。发给我们，就能定位是哪一步出的问题。\n"
                     @"只包含崩溃位置、机型和最近的操作，不含你的作品内容。";
    sheet.primaryTitle = @"发送日志";
    sheet.secondaryTitle = @"以后再说";

    __weak AMProjCrashSheet *weakSheet = sheet;
    sheet.primaryHandler = ^{
        AMProjCrashNote(@"prompt: 用户选择发送日志");
        AMProjCrashUploadLog(weakSheet, summary);
    };
    sheet.secondaryHandler = ^{
        [NSUserDefaults.standardUserDefaults
            setDouble:([NSDate date].timeIntervalSince1970 + 24 * 60 * 60)
               forKey:@"amproj_crash_prompt_snooze_until"];
        AMProjCrashNote(@"prompt: 用户选择以后再说");
        [weakSheet dismissSheet];
    };
    sheet.copyHandler = ^{
        UIPasteboard.generalPasteboard.string = reportText;
        AMProjCrashNote(@"prompt: 用户复制日志");
        AMProjCrashSheet *target = weakSheet;
        if (!target) return;
        [target showStateWithHeadline:@"已复制" meta:@""
                            bodyText:@"日志全文已经在剪贴板，直接粘贴给猫鹤就行。"
                        primaryTitle:@"好" secondaryTitle:nil];
        target.primaryHandler = ^{ [target dismissSheet]; };
    };
    (void)reportText;

    [presenter presentViewController:sheet animated:YES completion:nil];
}

static UIWindow *AMProjCrashKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow && !candidate.hidden) return candidate;
            }
            if (windowScene.windows.count) return windowScene.windows.firstObject;
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

void AMProjCrashReporterPresentPromptIfNeeded(void) {
    if (gAMProjCrashPromptShown) return;
    if (!AMProjCrashReporterHasPendingReport()) return;
    // 横幅自己 12 秒后收起，不写 snooze；只有在抽屉里点「以后再说」才静默 24h。
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval snoozeUntil = [defaults doubleForKey:@"amproj_crash_prompt_snooze_until"];
    if (snoozeUntil > [NSDate date].timeIntervalSince1970) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjCrashReporterPresentPromptIfNeeded();
        });
        return;
    }

    UIWindow *window = AMProjCrashKeyWindow();
    if (!window) {
        // 窗口还没就绪：3 秒后再试，最多重试 5 次。
        static NSInteger retries = 0;
        if (retries < 5) {
            retries++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                AMProjCrashReporterPresentPromptIfNeeded();
            });
        }
        return;
    }

    NSString *reportText = AMProjCrashReporterPendingReportText() ?: @"";
    NSString *summary = AMProjCrashSummaryLine(reportText);
    gAMProjCrashPromptShown = YES;

    [gAMProjCrashBanner removeFromSuperview];
    AMProjCrashBanner *banner = [[AMProjCrashBanner alloc] initWithFrame:CGRectZero];
    banner.openHandler = ^{
        AMProjCrashNote(@"prompt: 打开详情");
        AMProjCrashPresentSheet(reportText, summary);
    };
    gAMProjCrashBanner = banner;
    [banner showInWindow:window];
    AMProjCrashNote(@"prompt: banner shown (%@)", summary);
}

#pragma mark - 手动触发（给不会闪退的设备做验收用）

// 手势 target：手势识别器只弱引用 target，必须有个常驻对象接住回调。
@interface AMProjCrashTapProxy : NSObject
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)tap;
@end

@implementation AMProjCrashTapProxy
+ (instancetype)shared {
    static AMProjCrashTapProxy *proxy = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        proxy = [[AMProjCrashTapProxy alloc] init];
    });
    return proxy;
}
- (void)handleTap:(__unused UITapGestureRecognizer *)tap {
    AMProjCrashReporterPresentDemoPrompt();
}
@end

// 写一份带 kind=demo 的假报告，然后立刻走真实提示流程：
// 看到的就是用户崩溃后下次启动看到的那一套（横幅 → 抽屉 → 发送/复制/以后再说）。
// 假报告不会在下次启动再弹（安装时会删掉），也不含任何真实崩溃信息。
void AMProjCrashReporterPresentDemoPrompt(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjCrashReporterPresentDemoPrompt();
        });
        return;
    }
    @try {
        NSMutableString *demo = [NSMutableString string];
        [demo appendString:@"猫鹤AM 崩溃报告\n"];
        [demo appendString:@"kind=demo\n"];
        [demo appendFormat:@"time=%lld\n", (long long)time(NULL)];
        [demo appendFormat:@"app=%@\n", AMProjCrashBuildTag()];
        [demo appendFormat:@"dev=%@\n", AMProjCrashDeviceSummary()];
        [demo appendString:@"note=这是测试入口生成的演示日志，不是真实崩溃。\n"];
        [demo appendString:@"\n--- trail ---\n"];
        [demo appendString:@"present HomepageTabBarView\n"];
        [demo appendString:@"present ProjectsVC\n"];
        [demo appendString:@"present EditorViewController\n"];
        NSString *path = AMProjCrashPathForName(AMProjCrashReportName);
        [demo writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (__unused NSException *exception) {
        return;
    }
    // 让「再来一次」总能弹：清掉 snooze 与本进程已弹过的标记。
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"amproj_crash_prompt_snooze_until"];
    gAMProjCrashPromptShown = NO;
    [gAMProjCrashBanner removeFromSuperview];
    gAMProjCrashBanner = nil;
    AMProjCrashNote(@"demo: 手动触发崩溃提示");
    AMProjCrashReporterPresentPromptIfNeeded();
}

// 三指双击屏幕任意位置 = 手动触发上面那套提示。
// 挂在 keyWindow 上，不拦截单指手势（cancelsTouchesInView = NO）。
void AMProjCrashInstallDemoTrigger(void) {
    static BOOL installed = NO;
    if (installed) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjCrashInstallDemoTrigger();
        });
        return;
    }
    UIWindow *window = AMProjCrashKeyWindow();
    if (!window) return;
    installed = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:[AMProjCrashTapProxy shared] action:@selector(handleTap:)];
    tap.numberOfTapsRequired = 2;
    tap.numberOfTouchesRequired = 3;
    tap.cancelsTouchesInView = NO;
    [window addGestureRecognizer:tap];
    NSLog(@"[AMProjExport] demo trigger installed (3-finger double tap)");
}
