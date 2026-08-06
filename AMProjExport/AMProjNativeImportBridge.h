#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AMProjNativePackageImportCompletion)(BOOL success,
                                                     NSError * _Nullable error);
typedef BOOL (^AMProjNativePackageImportStarter)(
    NSURL *packageURL,
    NSString *originalName,
    AMProjNativePackageImportCompletion completion,
    NSError * _Nullable * _Nullable error);
typedef void (^AMProjNativePackageImportEventHandler)(
    NSString *event,
    NSDictionary<NSString *, id> *fields);

FOUNDATION_EXPORT void AMProjRegisterNativePackageImportStarter(
    AMProjNativePackageImportStarter _Nullable starter);

// Event handlers are copied under the bridge lock and always invoked on the
// main thread. Registering diagnostics does not change the starter contract.
FOUNDATION_EXPORT void AMProjRegisterNativePackageImportEventHandler(
    AMProjNativePackageImportEventHandler _Nullable handler);

FOUNDATION_EXPORT void AMProjInstallNativePackageImportBridge(void);

// Returns YES when an active local import consumed the native failure.
FOUNDATION_EXPORT BOOL AMProjNativePackageImportBridgeFinishFailure(
    NSError *error);

// A native XML warning can explicitly confirm that its template was imported
// even though AM displays a non-fatal Missing Media alert. Complete only that
// already-successful transaction without poisoning the bridge.
FOUNDATION_EXPORT BOOL AMProjNativePackageImportBridgeFinishSuccess(void);

// Returns YES while the native importer has an in-flight/finishing callback or
// has been poisoned by a timeout. Callers must keep later packages queued.
FOUNDATION_EXPORT BOOL AMProjNativePackageImportBridgeIsBusy(void);

// A native error may leave an old Swift completion closure alive. The bridge
// deliberately requires a process restart before accepting another package.
FOUNDATION_EXPORT BOOL AMProjNativePackageImportBridgeRequiresRestart(void);

FOUNDATION_EXPORT void AMProjBridgeNSURLToSwiftURL(
    void *function,
    void *resultBuffer,
    NSURL *url);

FOUNDATION_EXPORT void AMProjCallNativeLocalImportContinuation(
    void *function,
    id _Nullable storageSnapshot,
    id owner,
    id progressOwner,
    void *cleanupURL,
    void *packageImporter,
    uintptr_t swiftStringWord0,
    uintptr_t swiftStringWord1,
    void *packageURL,
    void *completionFunction,
    void * _Nullable completionContext);

NS_ASSUME_NONNULL_END
