#import "AMProjZIPWriter.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL AMProjWriteArchive(
    NSURL *destinationURL,
    NSData *xmlData,
    NSString *xmlFilename,
    NSDictionary<NSString *, NSURL *> *resourceURLs,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
