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

FOUNDATION_EXPORT void AMProjRegisterNativePackageImportStarter(
    AMProjNativePackageImportStarter _Nullable starter);

FOUNDATION_EXPORT void AMProjInstallNativePackageImportBridge(void);

// Returns YES when an active local import consumed the native failure.
FOUNDATION_EXPORT BOOL AMProjNativePackageImportBridgeFinishFailure(
    NSError *error);

FOUNDATION_EXPORT void AMProjCallNativePackageImport(
    void *function,
    uintptr_t swiftStringWord0,
    uintptr_t swiftStringWord1,
    // The adapter maps this argument to the native entry's explicit x2.
    id storageReference,
    id _Nullable progressOwner,
    void *completionFunction,
    void * _Nullable completionContext,
    // The adapter maps this final argument to Swift's hidden x20 context.
    id presentationOwner);

NS_ASSUME_NONNULL_END
