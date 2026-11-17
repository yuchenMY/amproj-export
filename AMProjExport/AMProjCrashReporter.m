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

void AMProjCrashReporterPresentPromptIfNeeded(void) {
    if (gAMProjCrashPromptShown) return;
    if (!AMProjCrashReporterHasPendingReport()) return;
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

    NSMutableString *message = [NSMutableString string];
    [message appendFormat:@"上次使用猫鹤AM时闪退了（%@）。\n", summary];
    [message appendString:@"日志已经记录在手机上。上传后我们能直接定位原因，修好会随版本更新。"];
    [message appendString:@"\n\n上传内容：崩溃位置、iPhone 机型与系统版本、最近的操作记录，不含你的作品内容。"];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"上次闪退了"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"上传日志"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        AMProjCrashNote(@"prompt: 用户选择上传日志");
#if AMPROJ_CLOUD_SYNC
        UIViewController *host = AMProjCrashTopViewController();
        NSString *path = AMProjCrashReporterPendingReportPath();
        if (!path) return;
        if (!AMCloudSyncHasLoggedInAccount()) {
            UIAlertController *login = [UIAlertController
                alertControllerWithTitle:@"需要先登录"
                                 message:@"上传日志要走猫鹤账户，登录后回到这里再点一次「上传日志」。"
                          preferredStyle:UIAlertControllerStyleAlert];
            [login addAction:[UIAlertAction actionWithTitle:@"去登录"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *inner) {
                AMCloudSyncShowAccountLoginFrom(AMProjCrashTopViewController() ?: host);
            }]];
            [login addAction:[UIAlertAction actionWithTitle:@"取消"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            UIViewController *target = AMProjCrashTopViewController() ?: host;
            if (target) [target presentViewController:login animated:YES completion:nil];
            return;
        }
        // 工单正文有 2000 字上限：只放摘要，全文走附件。
        NSString *content = [NSString stringWithFormat:
            @"用户在 App 内点击“上传日志”。\n%@\n日志见附件。", summary];
        AMCloudSubmitCrashTicket(@"猫鹤AM 崩溃日志", content, path,
            ^(BOOL ok, NSString *messageText) {
                UIAlertController *result = [UIAlertController
                    alertControllerWithTitle:ok ? @"已上传" : @"上传失败"
                                     message:messageText
                              preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"好"
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil]];
                UIViewController *target = AMProjCrashTopViewController() ?: host;
                if (target) [target presentViewController:result animated:YES completion:nil];
                if (ok) AMProjCrashReporterDiscardPending();
            });
#else
        (void)summary;
#endif
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"复制日志"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = reportText;
        AMProjCrashNote(@"prompt: 用户复制日志");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"删除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        AMProjCrashNote(@"prompt: 用户删除日志");
        AMProjCrashReporterDiscardPending();
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"以后再说"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [presenter presentViewController:alert animated:YES completion:nil];
    AMProjCrashNote(@"prompt: presented (%@)", summary);
}
