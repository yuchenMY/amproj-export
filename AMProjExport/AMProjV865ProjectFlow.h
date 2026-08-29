#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/*
 * Public-API-only project handoff for Alight Motion 6.2.58 (Build 865).
 * This adapter deliberately does not call private Swift symbols. It keeps a
 * downloaded project alive, then asks UIKit to hand the file back to the
 * running app's registered document route. The system Open In menu remains a
 * user-driven fallback when the workspace declines the URL.
 */
FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowIsRuntimeSupported(void);
FOUNDATION_EXPORT void AMProjV865ProjectFlowInstall(void);
FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowIsProjectPackageController(
    UIViewController * _Nullable controller);
FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowQueueDownloadedProject(
    NSURL *fileURL, NSString * _Nullable filename);
FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowPresentDocument(
    NSURL *fileURL, NSString * _Nullable filename,
    UIViewController * _Nullable presenter);

NS_ASSUME_NONNULL_END
