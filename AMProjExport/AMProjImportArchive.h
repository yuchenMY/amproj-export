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
 contain at least one XML entry and no more than one root `manifest.txt`.

 On success, `nativeXMLURL` is the rewritten XML URL. `metrics` includes
 `entry_count`, `file_count`, `directory_count`, `xml_count`, `manifest_count`,
 `archive_bytes`, `compressed_bytes`, `uncompressed_bytes`, `reference_count`,
 `rewritten_reference_count`, `missing_reference_count`,
 `missing_reference_names`, `xml_names`, `extraction_directory`, and
 `native_xml`. For compatibility with the legacy single-XML bridge,
 `nativeXMLURL` points to the first rewritten XML; every XML and resource is
 still extracted and integrity-checked. References whose files are absent remain
 unchanged and are counted in `missing_reference_count`. The caller owns the
 successful extraction directory and should remove it after use.
 */
FOUNDATION_EXPORT BOOL AMProjPrepareNativeImport(
    NSURL *archiveURL,
    NSURL *workDirectoryURL,
    NSURL * _Nullable * _Nullable nativeXMLURL,
    NSDictionary<NSString *, id> * _Nullable * _Nullable metrics,
    NSError * _Nullable * _Nullable error);

/**
 Fully validates and extracts an input package, then writes a canonical ZIP32
 `.amproj` with resources first, one UUID scene XML, and a recalculated
 `manifest.txt`. Missing input manifests are synthesized. Missing `amproj:`
 resources remain referenced so Alight Motion can use its native missing-media
 warning flow.
 */
FOUNDATION_EXPORT BOOL AMProjNormalizeProjectArchive(
    NSURL *archiveURL,
    NSURL *workDirectoryURL,
    NSURL *destinationURL,
    NSDictionary<NSString *, id> * _Nullable * _Nullable metrics,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
