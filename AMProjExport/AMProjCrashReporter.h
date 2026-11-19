#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 构造函数里第一件事调用：安装未捕获异常 + 信号处理器、写启动哨兵、
/// 判断上一轮是否异常退出。只碰 Foundation/C，不创建任何 UI 对象。
FOUNDATION_EXPORT void AMProjCrashReporterInstall(void);

/// 面包屑。调用方保证不传裸基本类型（与 r89 事故同一纪律）。
/// 只保留最近 60 条、单条最长 160 字节，超出自动丢弃最旧的。
FOUNDATION_EXPORT void AMProjCrashNote(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 进入后台时调用：把哨兵标记为 background，避免被系统回收也当成崩溃。
FOUNDATION_EXPORT void AMProjCrashReporterMarkBackgrounded(void);

/// 回到前台时调用：把哨兵重新标记为 running。
FOUNDATION_EXPORT void AMProjCrashReporterMarkForegrounded(void);

/// 是否有待处理的崩溃报告。
FOUNDATION_EXPORT BOOL AMProjCrashReporterHasPendingReport(void);

/// 待处理报告的绝对路径（没有则返回 nil）。
FOUNDATION_EXPORT NSString *_Nullable AMProjCrashReporterPendingReportPath(void);

/// 在窗口就绪后调用一次：有新报告就弹「上次闪退了」提示。
FOUNDATION_EXPORT void AMProjCrashReporterPresentPromptIfNeeded(void);

/// 丢弃待处理报告（用户主动删除 / 上传成功后）。
FOUNDATION_EXPORT void AMProjCrashReporterDiscardPending(void);

/// 把报告正文读成字符串（上传、复制都用它）。
FOUNDATION_EXPORT NSString *_Nullable AMProjCrashReporterPendingReportText(void);

/// 验收用：写一份 kind=demo 的演示报告并立刻走真实提示流程
/// （横幅 → 抽屉 → 发送/复制/以后再说）。演示报告下次启动会被自动删掉。
FOUNDATION_EXPORT void AMProjCrashReporterPresentDemoPrompt(void);

/// 验收用：在 keyWindow 上装「三指双击」触发上面那套提示（幂等）。
FOUNDATION_EXPORT void AMProjCrashInstallDemoTrigger(void);

NS_ASSUME_NONNULL_END
