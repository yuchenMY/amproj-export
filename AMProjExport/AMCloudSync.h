#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^AMCloudImportHandler)(NSURL *fileURL, NSString *filename,
                                     NSURL *cleanupURL);

FOUNDATION_EXPORT void AMCloudSyncInstall(AMCloudImportHandler importHandler);
FOUNDATION_EXPORT NSArray<UIActivity *> *AMCloudSyncUploadActivities(
    NSURL *fileURL, NSString *projectTitle, UIViewController *presenter);

NS_ASSUME_NONNULL_END
