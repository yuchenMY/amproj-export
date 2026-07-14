#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const AMProjZIPErrorDomain;

typedef NS_ENUM(NSInteger, AMProjZIPErrorCode) {
    AMProjZIPErrorInvalidArgument = 1,
    AMProjZIPErrorInvalidEntry,
    AMProjZIPErrorSourceUnavailable,
    AMProjZIPErrorZIP32Limit,
    AMProjZIPErrorInsufficientSpace,
    AMProjZIPErrorOutputIO,
    AMProjZIPErrorCompression,
    AMProjZIPErrorVerification,
};

/**
 Writes a deflated ZIP32 project package without loading resource files into memory.

 `sceneXML` is stored under a lowercase UUID filename. Resource keys are flat archive
 filenames and values are local file URLs. Resource filenames ending in `.xml` are
 rejected so that every successful archive contains exactly one XML entry. The final
 `manifest.txt` contains the uppercase SHA-1 and filename of every resource.

 The returned metrics contain numeric values for `entry_count`, `xml_count`, `manifest_count`,
 `uncompressed_bytes`, `compressed_bytes`, `archive_bytes`, `required_bytes`,
 `free_bytes_before`, `crc_verified`, and `manifest_verified`.
 */
FOUNDATION_EXPORT BOOL AMProjZIPWriteProjectArchive(
    NSURL *destinationURL,
    NSData *sceneXML,
    NSDictionary<NSString *, NSURL *> *resourceURLs,
    NSDictionary<NSString *, NSNumber *> * _Nullable * _Nullable metrics,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
