#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^AMCloudImportHandler)(NSURL *fileURL, NSString *filename,
                                     NSURL *cleanupURL);

FOUNDATION_EXPORT void AMCloudSyncInstall(AMCloudImportHandler importHandler);
FOUNDATION_EXPORT NSArray<UIActivity *> *AMCloudSyncUploadActivities(
    NSURL *fileURL, NSString *projectTitle, UIViewController *presenter);
/// 仅在主线程替换原生账户展示；命中返回 YES 且不执行原生 completion，
/// 未命中返回 NO，由调用方继续原生展示。
FOUNDATION_EXPORT BOOL AMCloudSyncHandleNativeAccountPresentation(
    UIViewController *presenter, UIViewController *controller,
    void (^ _Nullable completion)(void));
/// 在原生账户页入栈前改为猫鹤登录或账户流程；未命中时返回 NO。
FOUNDATION_EXPORT BOOL AMCloudSyncHandleNativeAccountPush(
    UINavigationController *navigationController, UIViewController *controller);

NS_ASSUME_NONNULL_END
