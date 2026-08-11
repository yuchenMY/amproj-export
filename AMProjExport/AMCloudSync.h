#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^AMCloudImportHandler)(NSURL *fileURL, NSString *filename,
                                     NSURL *cleanupURL);
typedef void (^AMCloudAuthorizationCompletion)(BOOL allowed,
                                                NSError * _Nullable error);

/// 构造期仅恢复与当前 Keychain token 匹配的云插件资源 Hook，不触碰 UIKit UI。
FOUNDATION_EXPORT void AMCloudSyncInstallPluginHooksEarly(void);
FOUNDATION_EXPORT void AMCloudSyncInstall(AMCloudImportHandler importHandler);
FOUNDATION_EXPORT NSArray<UIActivity *> *AMCloudSyncUploadActivities(
    NSURL *fileURL, NSString *projectTitle, UIViewController *presenter);
/// 在导入、导出或云端插件下载的最终入口向服务端校验 iOS 权限和设备绑定。
FOUNDATION_EXPORT void AMCloudAuthorizeFeature(
    NSString *feature, UIViewController * _Nullable presenter,
    AMCloudAuthorizationCompletion completion);
/// 仅在主线程把原生账户展示目标替换为猫鹤账户控制器。
/// 返回 nil 表示未命中或无法安全创建替换控制器，由调用方走原生路径。
FOUNDATION_EXPORT UIViewController * _Nullable
AMCloudSyncReplacementForNativeAccountPresentation(
    UIViewController *presenter, UIViewController *controller);
/// 在保留 UINavigationController 原始入栈语义的前提下替换账户控制器。
FOUNDATION_EXPORT UIViewController * _Nullable
AMCloudSyncReplacementForNativeAccountPush(
    UINavigationController *navigationController, UIViewController *controller);

NS_ASSUME_NONNULL_END
