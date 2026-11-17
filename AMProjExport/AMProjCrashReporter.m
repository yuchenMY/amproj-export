//
//  AMProjCrashReporter.m
//  猫鹤 AM · 865
//
//  目的：用户闪退后，下一次启动能看到「上次闪退了」，并把日志一键上传成工单。
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
        BOOL hasBody = [NSData dataWithContentsOfFile:existing].length > 0;
        if (!hasBody) {
            // 信号处理器多半没跑起来（被 SIGKILL / watchdog 杀掉），
            // 这里补一份「上一轮没正常结束」的最小报告。
            AMProjCrashNote(@"session: 上一轮异常结束（无信号处理器报告）");
            AMProjCrashRecordUncleanExit(@"unclean_exit");
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
            break;
        }
    }
    return [NSString stringWithFormat:@"%@ · %@", kind, AMProjCrashBuildTag()];
}

#pragma mark - 提示 UI：顶部横幅 + 底部抽屉（浅色，跟 App 首页一个语言）

static UIColor *AMProjCrashColor(NSUInteger rgbaHex, CGFloat alpha) {
    return [UIColor colorWithRed:((rgbaHex >> 16) & 0xFF) / 255.0
                           green:((rgbaHex >> 8) & 0xFF) / 255.0
                            blue:(rgbaHex & 0xFF) / 255.0
                           alpha:alpha];
}

// 首页那套浅色：白卡 + 近黑字 + 中灰说明；强调色只在必要时用一点点。
static UIColor *AMProjCrashInk(void) { return AMProjCrashColor(0x0B0F14, 1.0); }
static UIColor *AMProjCrashBody(void) { return AMProjCrashColor(0x5B6472, 1.0); }
static UIColor *AMProjCrashMute(void) { return AMProjCrashColor(0x9AA1AD, 1.0); }
static UIColor *AMProjCrashHairline(void) { return AMProjCrashColor(0xE8EBF0, 1.0); }
static UIColor *AMProjCrashCanvas(void) { return AMProjCrashColor(0xFFFFFF, 1.0); }

static UIFont *AMProjCrashFont(CGFloat size, UIFontWeight weight) {
    return [UIFont systemFontOfSize:size weight:weight];
}

#pragma mark - 底部抽屉

@interface AMProjCrashSheet : UIViewController
@property (nonatomic, copy) NSString *headline;
@property (nonatomic, copy) NSString *meta;
@property (nonatomic, copy) NSString *bodyText;
@property (nonatomic, copy) NSString *primaryTitle;
@property (nonatomic, copy) void (^primaryHandler)(void);
@property (nonatomic, copy) void (^copyHandler)(void);
@property (nonatomic, copy) void (^laterHandler)(void);
- (void)dismissSheet;
- (void)showStateWithHeadline:(NSString *)headline meta:(NSString *)meta
                     bodyText:(NSString *)body primaryTitle:(NSString *)primaryTitle
                     showLinks:(BOOL)showLinks;
@end

static void AMProjCrashUploadLog(AMProjCrashSheet *sheet, NSString *summary);

@implementation AMProjCrashSheet {
    UIView *_panel;
    UILabel *_headlineLabel;
    UILabel *_metaLabel;
    UILabel *_bodyLabel;
    UIButton *_primaryButton;
    UIButton *_copyButton;
    UIButton *_laterButton;
    UILabel *_linkSeparator;
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
    _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [_dimView addTarget:self action:@selector(noop:)
       forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_dimView];

    _panel = [[UIView alloc] initWithFrame:CGRectZero];
    _panel.backgroundColor = AMProjCrashCanvas();
    _panel.layer.cornerRadius = 28;
    _panel.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _panel.layer.masksToBounds = NO;
    [self.view addSubview:_panel];

    // 抓手
    UIView *grabber = [[UIView alloc] initWithFrame:CGRectZero];
    grabber.backgroundColor = AMProjCrashColor(0xD1D5DB, 1.0);
    grabber.layer.cornerRadius = 2.5;
    grabber.tag = 9001;
    [_panel addSubview:grabber];

    _headlineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headlineLabel.textColor = AMProjCrashInk();
    _headlineLabel.font = AMProjCrashFont(19, UIFontWeightBold);
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
    _primaryButton.backgroundColor = AMProjCrashInk();
    _primaryButton.layer.cornerRadius = 14;
    _primaryButton.layer.masksToBounds = YES;
    _primaryButton.titleLabel.font = AMProjCrashFont(16, UIFontWeightSemibold);
    [_primaryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_primaryButton addTarget:self action:@selector(primaryTapped:)
             forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_primaryButton];

    _copyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _copyButton.titleLabel.font = AMProjCrashFont(13, UIFontWeightRegular);
    [_copyButton setTitle:@"复制日志" forState:UIControlStateNormal];
    [_copyButton setTitleColor:AMProjCrashMute() forState:UIControlStateNormal];
    [_copyButton addTarget:self action:@selector(copyTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_copyButton];

    _linkSeparator = [[UILabel alloc] initWithFrame:CGRectZero];
    _linkSeparator.text = @"·";
    _linkSeparator.textColor = AMProjCrashMute();
    _linkSeparator.font = AMProjCrashFont(13, UIFontWeightRegular);
    _linkSeparator.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:_linkSeparator];

    _laterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _laterButton.titleLabel.font = AMProjCrashFont(13, UIFontWeightRegular);
    [_laterButton setTitle:@"以后再说" forState:UIControlStateNormal];
    [_laterButton setTitleColor:AMProjCrashMute() forState:UIControlStateNormal];
    [_laterButton addTarget:self action:@selector(laterTapped:)
           forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_laterButton];

    [self applyContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat pad = 24.0;
    CGFloat inner = width - pad * 2;

    // 面板高度跟着内容走：内容短就短，不留一大块空白。
    CGSize bodySize = [_bodyLabel sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)];
    CGFloat bodyHeight = ceil(bodySize.height);
    CGFloat contentHeight = 32 + 26 + (_metaLabel.hidden ? 0 : 17) + 14
        + bodyHeight + 24 + 50 + 12 + 20 + 16;
    CGFloat panelHeight = contentHeight + self.view.safeAreaInsets.bottom;

    _panel.frame = CGRectMake(0, CGRectGetHeight(self.view.bounds) - panelHeight,
                              width, panelHeight);
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.12;
    _panel.layer.shadowRadius = 24;
    _panel.layer.shadowOffset = CGSizeMake(0, -8);

    UIView *grabber = [_panel viewWithTag:9001];
    grabber.frame = CGRectMake((width - 36) / 2.0, 10, 36, 5);

    CGFloat y = 32;
    _headlineLabel.frame = CGRectMake(pad, y, inner, 26);
    y += 26;
    if (!_metaLabel.hidden) {
        _metaLabel.frame = CGRectMake(pad, y, inner, 17);
        y += 17;
    }
    y += 14;
    _bodyLabel.frame = CGRectMake(pad, y, inner, bodyHeight);
    y += bodyHeight + 24;

    _primaryButton.frame = CGRectMake(pad, y, inner, 50);
    y += 50 + 12;

    CGFloat linkWidth = 62;
    CGFloat separatorWidth = 16;
    CGFloat total = linkWidth * 2 + separatorWidth;
    CGFloat linkX = (width - total) / 2.0;
    _copyButton.frame = CGRectMake(linkX, y, linkWidth, 20);
    _linkSeparator.frame = CGRectMake(linkX + linkWidth, y, separatorWidth, 20);
    _laterButton.frame = CGRectMake(linkX + linkWidth + separatorWidth, y,
                                    linkWidth, 20);
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

- (void)noop:(__unused id)sender {}

- (NSAttributedString *)attributedBody:(NSString *)text {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 6.0;
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
    _metaLabel.hidden = (self.meta.length == 0);
    [self.view setNeedsLayout];
}

- (void)primaryTapped:(__unused id)sender {
    void (^handler)(void) = self.primaryHandler;
    if (handler) handler();
}

- (void)copyTapped:(__unused id)sender {
    void (^handler)(void) = self.copyHandler;
    if (handler) handler();
}

- (void)laterTapped:(__unused id)sender {
    void (^handler)(void) = self.laterHandler;
    if (handler) handler();
    [self dismissSheet];
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
                     bodyText:(NSString *)body primaryTitle:(NSString *)primaryTitle
                     showLinks:(BOOL)showLinks {
    self.headline = headline;
    self.meta = meta;
    self.bodyText = body;
    self.primaryTitle = primaryTitle;
    [self applyContent];
    _copyButton.hidden = !showLinks;
    _linkSeparator.hidden = !showLinks;
    _laterButton.hidden = NO;
    [_laterButton setTitle:(showLinks ? @"以后再说" : @"关闭")
                  forState:UIControlStateNormal];
    [UIView animateWithDuration:0.15 animations:^{
        [self.view layoutIfNeeded];
    }];
}

@end

#pragma mark - 顶部横幅

@interface AMProjCrashBanner : UIView
@property (nonatomic, copy) void (^openHandler)(void);
@property (nonatomic, copy) void (^closeHandler)(void);
- (void)showInWindow:(UIWindow *)window;
- (void)hide;
@end

@implementation AMProjCrashBanner {
    UIButton *_sendButton;
    UIButton *_closeButton;
    NSTimer *_autoHideTimer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = AMProjCrashCanvas();
        self.layer.cornerRadius = 16;
        self.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        self.layer.borderColor = AMProjCrashHairline().CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.08;
        self.layer.shadowRadius = 14;
        self.layer.shadowOffset = CGSizeMake(0, 6);

        UIView *badge = [[UIView alloc] initWithFrame:CGRectZero];
        badge.backgroundColor = AMProjCrashColor(0xF2F4F7, 1.0);
        badge.layer.cornerRadius = 13;
        badge.tag = 9101;
        [self addSubview:badge];

        UILabel *bang = [[UILabel alloc] initWithFrame:CGRectZero];
        bang.text = @"!";
        bang.textColor = AMProjCrashInk();
        bang.font = AMProjCrashFont(13, UIFontWeightBold);
        bang.textAlignment = NSTextAlignmentCenter;
        [badge addSubview:bang];
        bang.tag = 9102;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
        title.text = @"上次闪退了";
        title.textColor = AMProjCrashInk();
        title.font = AMProjCrashFont(13.5, UIFontWeightBold);
        title.tag = 9103;
        [self addSubview:title];

        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectZero];
        subtitle.text = @"点这里把日志发给我们";
        subtitle.textColor = AMProjCrashMute();
        subtitle.font = AMProjCrashFont(11.5, UIFontWeightRegular);
        subtitle.tag = 9104;
        [self addSubview:subtitle];

        _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _sendButton.backgroundColor = AMProjCrashInk();
        _sendButton.layer.cornerRadius = 15;
        _sendButton.titleLabel.font = AMProjCrashFont(12, UIFontWeightSemibold);
        [_sendButton setTitle:@"发送" forState:UIControlStateNormal];
        [_sendButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [_sendButton addTarget:self action:@selector(openTapped:)
              forControlEvents:UIControlEventTouchUpInside];
        _sendButton.tag = 9105;
        [self addSubview:_sendButton];

        _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_closeButton setTitle:@"×" forState:UIControlStateNormal];
        [_closeButton setTitleColor:AMProjCrashMute() forState:UIControlStateNormal];
        _closeButton.titleLabel.font = AMProjCrashFont(13, UIFontWeightRegular);
        [_closeButton addTarget:self action:@selector(closeTapped:)
               forControlEvents:UIControlEventTouchUpInside];
        _closeButton.tag = 9106;
        [self addSubview:_closeButton];

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openTapped:)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat w = CGRectGetWidth(self.bounds);

    CGFloat badgeSize = 26;
    UIView *badge = [self viewWithTag:9101];
    badge.frame = CGRectMake(16, (h - badgeSize) / 2.0, badgeSize, badgeSize);
    [badge viewWithTag:9102].frame = badge.bounds;

    CGFloat closeSize = 28;
    _closeButton.frame = CGRectMake(w - 12 - closeSize, (h - closeSize) / 2.0,
                                    closeSize, closeSize);

    CGFloat pillWidth = 62;
    CGFloat pillHeight = 30;
    _sendButton.frame = CGRectMake(CGRectGetMinX(_closeButton.frame) - 8 - pillWidth,
                                   (h - pillHeight) / 2.0, pillWidth, pillHeight);

    CGFloat textX = CGRectGetMaxX(badge.frame) + 10;
    CGFloat textWidth = CGRectGetMinX(_sendButton.frame) - 10 - textX;
    [self viewWithTag:9103].frame = CGRectMake(textX, h / 2.0 - 19, textWidth, 19);
    [self viewWithTag:9104].frame = CGRectMake(textX, h / 2.0 + 1, textWidth, 16);
}

- (void)showInWindow:(UIWindow *)window {
    if (!window) return;
    CGFloat width = CGRectGetWidth(window.bounds) - 32;
    CGFloat top = window.safeAreaInsets.top + 8;
    self.frame = CGRectMake(16, top - 78, width, 64);
    [window addSubview:self];
    [UIView animateWithDuration:0.3 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.frame = CGRectMake(16, top, width, 64);
    } completion:nil];
    // 15 秒后自动收起（只是不挡视线，不写入 24 小时 snooze）。
    _autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
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

- (void)closeTapped:(__unused id)sender {
    void (^handler)(void) = self.closeHandler;
    [self hide];
    if (handler) handler();
}

- (void)hide {
    [_autoHideTimer invalidate];
    _autoHideTimer = nil;
    [UIView animateWithDuration:0.22 animations:^{
        self.alpha = 0.0;
        self.transform = CGAffineTransformMakeTranslation(0, -24);
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
                            bodyText:@"可能是系统清理了缓存，这次就不用发了。"
                        primaryTitle:@"好" showLinks:NO];
        sheet.primaryHandler = ^{ [sheet dismissSheet]; };
        return;
    }
#if AMPROJ_CLOUD_SYNC
    if (!AMCloudSyncHasLoggedInAccount()) {
        [sheet showStateWithHeadline:@"需要先登录" meta:@"上传日志要走猫鹤账户"
                            bodyText:@"登录之后回到这里，再点一次「发送日志」就可以了。"
                        primaryTitle:@"去登录" showLinks:NO];
        sheet.primaryHandler = ^{
            AMCloudSyncShowAccountLoginFrom(AMProjCrashTopViewController());
            [sheet dismissSheet];
        };
        return;
    }
    NSString *content = [NSString stringWithFormat:
        @"用户在 App 内点击“发送日志”。\n%@\n日志见附件。", summary ?: @""];
    [sheet showStateWithHeadline:@"正在发送…" meta:summary ?: @""
                        bodyText:@"日志正在发到猫鹤服务器，几秒钟就好。"
                    primaryTitle:@"请稍候" showLinks:NO];
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
                                primaryTitle:@"好" showLinks:NO];
                target.primaryHandler = ^{ [target dismissSheet]; };
            } else {
                [target showStateWithHeadline:@"没发出去" meta:@""
                                    bodyText:messageText ?: @"网络不太好，稍后再试一次。"
                                primaryTitle:@"重试" showLinks:NO];
                __weak AMProjCrashSheet *retrySheet = target;
                target.primaryHandler = ^{
                    AMProjCrashSheet *strong = retrySheet;
                    if (strong) AMProjCrashUploadLog(strong, summary);
                };
            }
        });
#else
    [sheet showStateWithHeadline:@"这个版本不支持上传" meta:@""
                        bodyText:@"可以先点「复制日志」，把内容发给猫鹤。"
                    primaryTitle:@"好" showLinks:NO];
    sheet.primaryHandler = ^{ [sheet dismissSheet]; };
#endif
}

#pragma mark - 入口

static void AMProjCrashPresentSheet(NSString *reportText, NSString *summary) {
    UIViewController *presenter = AMProjCrashTopViewController();
    if (!presenter || presenter.presentedViewController) return;

    AMProjCrashSheet *sheet = [[AMProjCrashSheet alloc] init];
    sheet.headline = @"上次闪退了";
    sheet.meta = summary;
    sheet.bodyText = @"日志已经记录在手机上。发给我们就能定位原因，修好会随版本更新。\n\n"
                     @"只发送崩溃位置、机型和最近的操作，不含你的作品内容。";
    sheet.primaryTitle = @"发送日志";

    __weak AMProjCrashSheet *weakSheet = sheet;
    sheet.primaryHandler = ^{
        AMProjCrashNote(@"prompt: 用户选择发送日志");
        AMProjCrashUploadLog(weakSheet, summary);
    };
    sheet.copyHandler = ^{
        UIPasteboard.generalPasteboard.string = reportText;
        AMProjCrashNote(@"prompt: 用户复制日志");
        AMProjCrashSheet *target = weakSheet;
        if (!target) return;
        [target showStateWithHeadline:@"已复制" meta:@""
                            bodyText:@"日志全文已经在剪贴板，直接粘贴给猫鹤就行。"
                        primaryTitle:@"好" showLinks:NO];
        target.primaryHandler = ^{ [target dismissSheet]; };
    };
    sheet.laterHandler = ^{
        [NSUserDefaults.standardUserDefaults
            setDouble:([NSDate date].timeIntervalSince1970 + 24 * 60 * 60)
               forKey:@"amproj_crash_prompt_snooze_until"];
        AMProjCrashNote(@"prompt: 用户选择以后再说");
    };

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
    // 「×」= 24 小时内不再打扰；报告本身保留，下次仍可发送。
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
    banner.closeHandler = ^{
        [NSUserDefaults.standardUserDefaults
            setDouble:([NSDate date].timeIntervalSince1970 + 24 * 60 * 60)
               forKey:@"amproj_crash_prompt_snooze_until"];
        AMProjCrashNote(@"prompt: 横幅关闭（24h snooze）");
    };
    gAMProjCrashBanner = banner;
    [banner showInWindow:window];
    AMProjCrashNote(@"prompt: banner shown (%@)", summary);
}
