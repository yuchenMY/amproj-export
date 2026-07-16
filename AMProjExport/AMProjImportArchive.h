#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const AMProjImportArchiveErrorDomain;

typedef NS_ENUM(NSInteger, AMProjImportArchiveErrorCode) {
    AMProjImportArchiveErrorInvalidArgument = 1,
    AMProjImportArchiveErrorSourceUnavailable,
    AMProjImportArchiveErrorInvalidZIP,
    AMProjImportArchiveErrorUnsupportedZIP,
    AMProjImportArchiveErrorUnsafeEntry,
    AMProjImportArchiveErrorLimitExceeded,
    AMProjImportArchiveErrorExtractionIO,
    AMProjImportArchiveErrorIntegrity,
    AMProjImportArchiveErrorInvalidXML,
};

/**
 Extracts a ZIP32 `.amproj` into a fresh directory below `workDirectoryURL`, then
 writes a sibling `<uuid>.native-import.xml` whose `amproj:` references point at
 the extracted files. The input archive is only opened for reading.

 Stored and raw-deflate entries are supported. Encrypted, split, ZIP64, unsafe,
 overlapping, oversized, or CRC-invalid archives are rejected. A package must
 contain exactly one XML entry and no more than one root `manifest.txt`.

 On success, `nativeXMLURL` is the rewritten XML URL. `metrics` includes
 `entry_count`, `file_count`, `directory_count`, `xml_count`, `manifest_count`,
 `archive_bytes`, `compressed_bytes`, `uncompressed_bytes`, `reference_count`,
 `rewritten_reference_count`, `missing_reference_count`, `extraction_directory`,
 and `native_xml`. References whose files are absent remain unchanged and are
 counted in `missing_reference_count`. The caller owns the successful extraction
 directory and should remove it after the native importer has finished reading.
 */
FOUNDATION_EXPORT BOOL AMProjPrepareNativeImport(
    NSURL *archiveURL,
    NSURL *workDirectoryURL,
    NSURL * _Nullable * _Nullable nativeXMLURL,
    NSDictionary<NSString *, id> * _Nullable * _Nullable metrics,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
