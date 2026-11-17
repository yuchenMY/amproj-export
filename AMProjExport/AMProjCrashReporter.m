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

#pragma mark - 提示卡片（自绘，不用系统弹窗）

static UIColor *AMProjCrashColor(NSUInteger rgbaHex, CGFloat alpha) {
    return [UIColor colorWithRed:((rgbaHex >> 16) & 0xFF) / 255.0
                           green:((rgbaHex >> 8) & 0xFF) / 255.0
                            blue:(rgbaHex & 0xFF) / 255.0
                           alpha:alpha];
}

// 品牌色：中文段青绿 #39C5BB → 英文段天蓝 #66CCFF，和主页标题同一组。
static UIColor *AMProjCrashBrandStart(void) { return AMProjCrashColor(0x39C5BB, 1.0); }
static UIColor *AMProjCrashBrandEnd(void) { return AMProjCrashColor(0x66CCFF, 1.0); }

static CAGradientLayer *AMProjCrashAttachGradient(UIView *view) {
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[(id)AMProjCrashBrandStart().CGColor,
                        (id)AMProjCrashBrandEnd().CGColor];
    gradient.startPoint = CGPointMake(0.0, 0.5);
    gradient.endPoint = CGPointMake(1.0, 0.5);
    gradient.frame = view.bounds;
    gradient.cornerRadius = view.layer.cornerRadius;
    [view.layer insertSublayer:gradient atIndex:0];
    return gradient;
}

@interface AMProjCrashPromptCard : UIViewController
@property (nonatomic, copy) NSString *headline;
@property (nonatomic, copy) NSString *meta;
@property (nonatomic, copy) NSString *bodyText;
@property (nonatomic, copy) NSString *primaryTitle;
@property (nonatomic, copy) NSString *footnote;
@property (nonatomic, copy) void (^primaryHandler)(void);
@property (nonatomic, copy) void (^copyHandler)(void);
@property (nonatomic, copy) void (^laterHandler)(void);
- (void)dismissCard;
- (void)showStateWithHeadline:(NSString *)headline meta:(NSString *)meta
                     bodyText:(NSString *)body primaryTitle:(NSString *)primaryTitle
                     footnote:(NSString *)footnote;
@end

static void AMProjCrashUploadLog(AMProjCrashPromptCard *card, NSString *summary);

@implementation AMProjCrashPromptCard {
    UIView *_card;
    UIView *_iconBadge;
    CAGradientLayer *_iconGradient;
    UIImageView *_iconView;
    UILabel *_headlineLabel;
    UILabel *_metaLabel;
    UILabel *_bodyLabel;
    UILabel *_footnoteLabel;
    UIButton *_primaryButton;
    CAGradientLayer *_primaryGradient;
    UIButton *_copyButton;
    UIButton *_laterButton;
    UILabel *_linkSeparator;
    UIControl *_dimView;
    BOOL _dismissing;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 必须在 present 之前设置，写进 viewDidLoad 等于没写（r104 踩过）。
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _dimView = [[UIControl alloc] initWithFrame:self.view.bounds];
    _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    [_dimView addTarget:self action:@selector(noop:)
       forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_dimView];

    _card = [[UIView alloc] initWithFrame:CGRectZero];
    _card.backgroundColor = AMProjCrashColor(0x171A21, 0.985);
    _card.layer.cornerRadius = 26;
    _card.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    _card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    _card.layer.shadowColor = UIColor.blackColor.CGColor;
    _card.layer.shadowOpacity = 0.45;
    _card.layer.shadowRadius = 28;
    _card.layer.shadowOffset = CGSizeMake(0, 12);
    [self.view addSubview:_card];

    _iconBadge = [[UIView alloc] initWithFrame:CGRectZero];
    _iconBadge.layer.cornerRadius = 17;
    _iconBadge.layer.masksToBounds = YES;
    [_card addSubview:_iconBadge];
    _iconGradient = AMProjCrashAttachGradient(_iconBadge);

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeCenter;
    _iconView.tintColor = AMProjCrashColor(0x08131A, 1.0);
    if (@available(iOS 13.0, *)) {
        UIImageConfiguration *config = [UIImageSymbolConfiguration
            configurationWithPointSize:22 weight:UIImageSymbolWeightBold];
        _iconView.image = [UIImage systemImageNamed:@"exclamationmark"
                                 withConfiguration:config];
    }
    [_iconBadge addSubview:_iconView];

    _headlineLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _headlineLabel.textColor = UIColor.whiteColor;
    _headlineLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    _headlineLabel.numberOfLines = 1;
    [_card addSubview:_headlineLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.textColor = AMProjCrashColor(0x8E96A3, 1.0);
    _metaLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    _metaLabel.numberOfLines = 1;
    [_card addSubview:_metaLabel];

    _bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _bodyLabel.textColor = AMProjCrashColor(0xB9C0CA, 1.0);
    _bodyLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular];
    _bodyLabel.numberOfLines = 0;
    [_card addSubview:_bodyLabel];

    _primaryButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _primaryButton.layer.cornerRadius = 16;
    _primaryButton.layer.masksToBounds = YES;
    _primaryButton.titleLabel.font =
        [UIFont systemFontOfSize:16.5 weight:UIFontWeightSemibold];
    [_primaryButton setTitleColor:AMProjCrashColor(0x08131A, 1.0)
                         forState:UIControlStateNormal];
    [_primaryButton addTarget:self action:@selector(primaryTapped:)
             forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_primaryButton];
    _primaryGradient = AMProjCrashAttachGradient(_primaryButton);

    _copyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _copyButton.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [_copyButton setTitle:@"复制日志" forState:UIControlStateNormal];
    [_copyButton setTitleColor:AMProjCrashColor(0x9AA3AF, 1.0)
                      forState:UIControlStateNormal];
    [_copyButton addTarget:self action:@selector(copyTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_copyButton];

    _linkSeparator = [[UILabel alloc] initWithFrame:CGRectZero];
    _linkSeparator.text = @"·";
    _linkSeparator.textColor = AMProjCrashColor(0x5A6270, 1.0);
    _linkSeparator.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    _linkSeparator.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:_linkSeparator];

    _laterButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _laterButton.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightMedium];
    [_laterButton setTitle:@"以后再说" forState:UIControlStateNormal];
    [_laterButton setTitleColor:AMProjCrashColor(0x9AA3AF, 1.0)
                       forState:UIControlStateNormal];
    [_laterButton addTarget:self action:@selector(laterTapped:)
           forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_laterButton];

    _footnoteLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _footnoteLabel.textColor = AMProjCrashColor(0x6E7681, 1.0);
    _footnoteLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _footnoteLabel.numberOfLines = 2;
    _footnoteLabel.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:_footnoteLabel];

    [self applyContent];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _card.transform = CGAffineTransformMakeScale(0.94, 0.94);
    _card.alpha = 0.0;
    [UIView animateWithDuration:0.34 delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self->_card.transform = CGAffineTransformIdentity;
        self->_card.alpha = 1.0;
    } completion:nil];
}

- (void)noop:(__unused id)sender {}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat padding = 22.0;
    CGFloat cardWidth = MIN(CGRectGetWidth(self.view.bounds) - 44.0, 340.0);
    CGFloat innerWidth = cardWidth - padding * 2;

    CGSize bodySize = [_bodyLabel sizeThatFits:CGSizeMake(innerWidth, CGFLOAT_MAX)];
    CGFloat iconSize = 54.0;
    CGFloat primaryHeight = 52.0;
    CGFloat height = padding + iconSize + 18.0 + 27.0 + 3.0 + 17.0 + 14.0
        + ceil(bodySize.height) + 20.0 + primaryHeight + 14.0 + 24.0 + 14.0 + 26.0;

    _card.frame = CGRectMake(0, 0, cardWidth, height);
    _card.center = CGPointMake(CGRectGetMidX(self.view.bounds),
                               CGRectGetMidY(self.view.bounds) - 8.0);

    CGFloat y = padding;
    _iconBadge.frame = CGRectMake(padding, y, iconSize, iconSize);
    _iconGradient.frame = _iconBadge.bounds;
    _iconView.frame = _iconBadge.bounds;
    y = CGRectGetMaxY(_iconBadge.frame) + 18.0;

    _headlineLabel.frame = CGRectMake(padding, y, innerWidth, 27.0);
    y = CGRectGetMaxY(_headlineLabel.frame) + 3.0;

    _metaLabel.frame = CGRectMake(padding, y, innerWidth, 17.0);
    y = CGRectGetMaxY(_metaLabel.frame) + 14.0;

    _bodyLabel.frame = CGRectMake(padding, y, innerWidth, ceil(bodySize.height));
    y = CGRectGetMaxY(_bodyLabel.frame) + 20.0;

    _primaryButton.frame = CGRectMake(padding, y, innerWidth, primaryHeight);
    _primaryGradient.frame = _primaryButton.bounds;
    y = CGRectGetMaxY(_primaryButton.frame) + 14.0;

    CGFloat linkWidth = 62.0;
    CGFloat separatorWidth = 18.0;
    CGFloat totalWidth = linkWidth * 2 + separatorWidth;
    CGFloat linkX = padding + (innerWidth - totalWidth) / 2.0;
    _copyButton.frame = CGRectMake(linkX, y, linkWidth, 24.0);
    _linkSeparator.frame = CGRectMake(CGRectGetMaxX(_copyButton.frame), y,
                                      separatorWidth, 24.0);
    _laterButton.frame = CGRectMake(CGRectGetMaxX(_linkSeparator.frame), y,
                                    linkWidth, 24.0);
    y = CGRectGetMaxY(_copyButton.frame) + 14.0;

    _footnoteLabel.frame = CGRectMake(padding, y, innerWidth, 26.0);
}

- (NSAttributedString *)attributedBody:(NSString *)text {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 5.0;
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:13.5 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: AMProjCrashColor(0xB9C0CA, 1.0),
        NSParagraphStyleAttributeName: style
    }];
}

- (void)applyContent {
    _headlineLabel.text = self.headline ?: @"";
    _metaLabel.text = self.meta ?: @"";
    _bodyLabel.attributedText = [self attributedBody:self.bodyText ?: @""];
    [_primaryButton setTitle:self.primaryTitle ?: @"好" forState:UIControlStateNormal];
    _footnoteLabel.text = self.footnote ?: @"";
    _metaLabel.hidden = (self.meta.length == 0);
    _footnoteLabel.hidden = (self.footnote.length == 0);
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
    [self dismissCard];
}

- (void)dismissCard {
    if (_dismissing) return;
    _dismissing = YES;
    [UIView animateWithDuration:0.2 animations:^{
        self->_card.alpha = 0.0;
        self->_card.transform = CGAffineTransformMakeScale(0.97, 0.97);
        self->_dimView.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}

- (void)showStateWithHeadline:(NSString *)headline meta:(NSString *)meta
                     bodyText:(NSString *)body primaryTitle:(NSString *)primaryTitle
                     footnote:(NSString *)footnote {
    self.headline = headline;
    self.meta = meta;
    self.bodyText = body;
    self.primaryTitle = primaryTitle;
    self.footnote = footnote;
    [self applyContent];
    [UIView transitionWithView:_card duration:0.18
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

@end

static void AMProjCrashUploadLog(AMProjCrashPromptCard *card, NSString *summary) {
    if (!card) return;
    NSString *path = AMProjCrashReporterPendingReportPath();
    if (!path) {
        [card showStateWithHeadline:@"日志已经不在了"
                               meta:@""
                           bodyText:@"可能是系统清理了缓存，这次就不用发了。"
                       primaryTitle:@"好"
                           footnote:@""];
        card.primaryHandler = ^{ [card dismissCard]; };
        return;
    }
#if AMPROJ_CLOUD_SYNC
    if (!AMCloudSyncHasLoggedInAccount()) {
        [card showStateWithHeadline:@"需要先登录"
                               meta:@"上传日志要走猫鹤账户"
                           bodyText:@"登录之后回到这里，再点一次「上传日志」就可以了。"
                       primaryTitle:@"去登录"
                           footnote:@"不登录也能正常用 App，只是日志发不出去"];
        card.primaryHandler = ^{
            AMCloudSyncShowAccountLoginFrom(AMProjCrashTopViewController());
            [card dismissCard];
        };
        return;
    }
    // 工单正文有 2000 字上限：只放摘要，全文走附件。
    NSString *content = [NSString stringWithFormat:
        @"用户在 App 内点击“上传日志”。\n%@\n日志见附件。", summary ?: @""];
    [card showStateWithHeadline:@"正在上传…"
                           meta:summary ?: @""
                       bodyText:@"日志正在发到猫鹤服务器，几秒钟就好。"
                   primaryTitle:@"请稍候"
                       footnote:@""];
    card.primaryHandler = nil;
    __weak AMProjCrashPromptCard *weakCard = card;
    AMCloudSubmitCrashTicket(@"猫鹤AM 崩溃日志", content, path,
        ^(BOOL ok, NSString *messageText) {
            AMProjCrashPromptCard *target = weakCard;
            if (!target) return;
            if (ok) {
                AMProjCrashReporterDiscardPending();
                [target showStateWithHeadline:@"已收到"
                                         meta:@""
                                     bodyText:messageText ?: @"日志已经到我们手上了。"
                                 primaryTitle:@"好"
                                     footnote:@"修好会随版本更新，谢谢"];
                target.primaryHandler = ^{ [target dismissCard]; };
            } else {
                [target showStateWithHeadline:@"没传上去"
                                         meta:@""
                                     bodyText:messageText ?: @"网络不太好，稍后再试一次。"
                                 primaryTitle:@"重试"
                                     footnote:@"日志还在手机上，不会丢"];
                __weak AMProjCrashPromptCard *retryCard = target;
                target.primaryHandler = ^{
                    AMProjCrashPromptCard *strong = retryCard;
                    if (strong) AMProjCrashUploadLog(strong, summary);
                };
            }
        });
#else
    [card showStateWithHeadline:@"这个版本不支持上传"
                           meta:@""
                       bodyText:@"可以先点「复制日志」，把内容发给猫鹤。"
                   primaryTitle:@"好"
                       footnote:@""];
    card.primaryHandler = ^{ [card dismissCard]; };
#endif
}

void AMProjCrashReporterPresentPromptIfNeeded(void) {
    if (gAMProjCrashPromptShown) return;
    if (!AMProjCrashReporterHasPendingReport()) return;
    // 「以后再说」= 24 小时内不再打扰；报告本身保留，下次仍可上传。
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSTimeInterval snoozeUntil = [defaults doubleForKey:@"amproj_crash_prompt_snooze_until"];
    if (snoozeUntil > [NSDate date].timeIntervalSince1970) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMProjCrashReporterPresentPromptIfNeeded();
        });
        return;
    }

    UIViewController *presenter = AMProjCrashTopViewController();
    if (!presenter || presenter.isBeingPresented || presenter.isBeingDismissed) {
        // 界面还没就绪：3 秒后再试，最多重试 5 次。
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
    if (presenter.presentedViewController) return;

    NSString *reportText = AMProjCrashReporterPendingReportText() ?: @"";
    NSString *summary = AMProjCrashSummaryLine(reportText);
    gAMProjCrashPromptShown = YES;

    AMProjCrashPromptCard *card = [[AMProjCrashPromptCard alloc] init];
    card.headline = @"上次闪退了";
    card.meta = summary;
    card.bodyText = @"日志已经记录在手机上。上传后我们能直接定位原因，修好会随版本更新。\n\n"
                    @"只会发送崩溃位置、iPhone 机型和最近的操作记录，不含你的作品内容。";
    card.primaryTitle = @"上传日志";
    card.footnote = @"断网或没登录都不影响你继续用 App";

    __weak AMProjCrashPromptCard *weakCard = card;
    card.primaryHandler = ^{
        AMProjCrashNote(@"prompt: 用户选择上传日志");
        AMProjCrashUploadLog(weakCard, summary);
    };
    card.copyHandler = ^{
        UIPasteboard.generalPasteboard.string = reportText;
        AMProjCrashNote(@"prompt: 用户复制日志");
        AMProjCrashPromptCard *target = weakCard;
        if (!target) return;
        [target showStateWithHeadline:@"已复制"
                                 meta:@""
                             bodyText:@"日志全文已经在剪贴板，直接粘贴给猫鹤就行。"
                         primaryTitle:@"好"
                             footnote:@""];
        target.primaryHandler = ^{ [target dismissCard]; };
    };
    card.laterHandler = ^{
        [NSUserDefaults.standardUserDefaults
            setDouble:([NSDate date].timeIntervalSince1970 + 24 * 60 * 60)
               forKey:@"amproj_crash_prompt_snooze_until"];
        AMProjCrashNote(@"prompt: 用户选择以后再说");
    };

    [presenter presentViewController:card animated:YES completion:nil];
    AMProjCrashNote(@"prompt: presented (%@)", summary);
}
