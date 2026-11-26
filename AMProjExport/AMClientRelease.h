// 猫鹤 AM · 独立发布编号与远程更新策略。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
/// 在启动后的主队列安装生命周期监听；不在构造期间创建 UIKit 对象。
FOUNDATION_EXPORT void AMClientReleaseInstall(void);
/// 项目页可见时尝试展示已取得的更新策略，不等待网络请求。
FOUNDATION_EXPORT void AMClientReleasePresentIfNeeded(void);
/// 仅由已确认原生工程浏览页的挂载点调用，兼容宿主控制器改名。
FOUNDATION_EXPORT void AMClientReleaseBrowsingControllerVisible(UIViewController *controller);
/// 为自有服务请求写入实际发布编号、渠道和插件提交标识。
FOUNDATION_EXPORT void AMClientReleaseAddHeaders(NSMutableURLRequest *request);
/// 返回插件编译时的发布编号、渠道与提交；用于工单和网页登录上下文。
FOUNDATION_EXPORT NSDictionary *AMClientReleaseIdentity(void);
/// 接收服务端 426 中的策略；仅接受当前渠道的完整有效策略，主队列更新状态。
FOUNDATION_EXPORT void AMClientReleaseHandleResponse(NSURLResponse * _Nullable response, NSData * _Nullable data);
NS_ASSUME_NONNULL_END
