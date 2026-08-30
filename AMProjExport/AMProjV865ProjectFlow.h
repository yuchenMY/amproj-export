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

/*
 * A successful UIKit openURL completion only means that LaunchServices
 * accepted the document route. It is not evidence that Alight Motion parsed
 * or saved the project. Callers can inspect the latest handoff state for
 * diagnostics; `unverified` is deliberately the terminal state until a
 * verified native import callback exists for Build 865.
 */
typedef NS_ENUM(NSInteger, AMProjV865ProjectHandoffStatus) {
    AMProjV865ProjectHandoffStatusFailed = 0,
    AMProjV865ProjectHandoffStatusReceived,
    AMProjV865ProjectHandoffStatusStaged,
    AMProjV865ProjectHandoffStatusRoutePending,
    AMProjV865ProjectHandoffStatusRouteAccepted,
    AMProjV865ProjectHandoffStatusFallbackPresented,
    AMProjV865ProjectHandoffStatusUnverified,
};

FOUNDATION_EXPORT NSString *AMProjV865ProjectFlowHandoffStatusString(
    AMProjV865ProjectHandoffStatus status);
FOUNDATION_EXPORT AMProjV865ProjectHandoffStatus
AMProjV865ProjectFlowLastHandoffStatus(void);

/*
 * Stages a downloaded document on a serial utility queue. The completion is
 * delivered on the main thread after the atomic copy and the first UIKit
 * handoff attempt complete. A staged result means that the receiving route
 * was established and the caller may release its original download directory;
 * it does not mean that Alight Motion has imported the project.
 */
typedef void (^AMProjV865ProjectFlowStageCompletion)(
    AMProjV865ProjectHandoffStatus status, NSError * _Nullable error);

/*
 * A request can be invalidated while staging is queued or while UIKit waits
 * for a visible presenter. Cancellation is idempotent and prevents a timed
 * out cloud download from opening a project after the caller has shown an
 * error. The returned object may be ignored by callers that do not need
 * cancellation.
 */
@interface AMProjV865ProjectFlowRequest : NSObject
@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

FOUNDATION_EXPORT void AMProjV865ProjectFlowCancelDocument(
    NSURL *fileURL);

/*
 * Copies an external document while its provider capability is still valid.
 * The returned URL is app-owned and remains available for retry. This is a
 * staging boundary only; it never reports the project as imported.
 *
 * Callers that already hold a security-scoped grant keep ownership of that
 * grant and must release it after forwarding the original lifecycle callback.
 */
FOUNDATION_EXPORT NSURL * _Nullable
AMProjV865ProjectFlowStageIncomingDocument(
    NSURL *fileURL, NSString * _Nullable filename, NSString *source,
    BOOL securityScopeAlreadyActive,
    NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowIsManagedStagedURL(
    NSURL * _Nullable fileURL);

/*
 * Records that an unchanged public AppDelegate/SceneDelegate callback was
 * dispatched. A callback return value is deliberately not treated as import
 * confirmation because Build 865 exposes no verified completion boundary.
 */
FOUNDATION_EXPORT void AMProjV865ProjectFlowRecordNativeRouteDispatched(
    NSURL *fileURL, NSString *source, BOOL forwarded);

/*
 * Presents an explicit retry state for a staged document. The Open In menu is
 * reachable only from the user's action in this notice.
 */
FOUNDATION_EXPORT void AMProjV865ProjectFlowPresentPendingNotice(
    NSURL *fileURL, NSString *source);

FOUNDATION_EXPORT AMProjV865ProjectFlowRequest *
AMProjV865ProjectFlowStageDocumentAsync(
    NSURL *fileURL, NSString * _Nullable filename,
    UIViewController * _Nullable presenter,
    AMProjV865ProjectFlowStageCompletion _Nullable completion);

/*
 * Compatibility-only synchronous entry point. It refuses main-thread calls
 * so an older caller cannot copy a large cloud project on the UI thread.
 */
FOUNDATION_EXPORT AMProjV865ProjectHandoffStatus
AMProjV865ProjectFlowStageDocument(
    NSURL *fileURL, NSString * _Nullable filename,
    UIViewController * _Nullable presenter);

FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowIsProjectPackageController(
    UIViewController * _Nullable controller);
FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowQueueDownloadedProject(
    NSURL *fileURL, NSString * _Nullable filename);
FOUNDATION_EXPORT BOOL AMProjV865ProjectFlowPresentDocument(
    NSURL *fileURL, NSString * _Nullable filename,
    UIViewController * _Nullable presenter);

NS_ASSUME_NONNULL_END
