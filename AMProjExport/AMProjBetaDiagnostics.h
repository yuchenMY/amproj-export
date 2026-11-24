// 猫鹤 AM · Beta 性能诊断。正式目标不链接本模块。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#if AMPROJ_BETA_DIAGNOSTICS
NS_ASSUME_NONNULL_BEGIN
/// 仅支持已验证的 6.2.58 / 865；不通过包名猜测 Beta 身份。
FOUNDATION_EXPORT BOOL AMProjBetaDiagnosticsAvailable(void);
/// 为受信账户页增加 Beta 入口，不修改线上通用页面。
FOUNDATION_EXPORT NSString *AMProjBetaDiagnosticsAccountScript(void);
/// 在主线程打开测试与诊断页。
FOUNDATION_EXPORT void AMProjBetaDiagnosticsPresent(UIViewController *presenter);
/// 只记录类名与预定义事件，不得传入文本、令牌、文件路径或工程内容。
FOUNDATION_EXPORT void AMProjBetaDiagnosticsNote(NSString *event, NSString *detail);
/// 未采集时返回零；只在采集中对已知插件路径计时。
FOUNDATION_EXPORT CFTimeInterval AMProjBetaDiagnosticsBeginSpan(void);
/// 记录插件路径耗时，调用方使用固定名称。
FOUNDATION_EXPORT void AMProjBetaDiagnosticsEndSpan(NSString *name, CFTimeInterval start);
NS_ASSUME_NONNULL_END
#endif
