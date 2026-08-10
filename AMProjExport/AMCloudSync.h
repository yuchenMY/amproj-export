#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^AMCloudImportHandler)(NSURL *fileURL, NSString *filename,
                                     NSURL *cleanupURL);

FOUNDATION_EXPORT void AMCloudSyncInstall(AMCloudImportHandler importHandler);
FOUNDATION_EXPORT NSArray<UIActivity *> *AMCloudSyncUploadActivities(
    NSURL *fileURL, NSString *projectTitle, UIViewController *presenter);
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
