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
 Multiple XML entries are accepted only when that manifest is present;
 ambiguous multi-XML archives without a manifest are rejected. When present,
 `manifest.txt` must contain one `UPPERCASE_SHA1:filename` line for every
 non-XML resource and no other entries. Resource SHA-1 values are calculated
 from the extracted files using streaming reads.

 On success, `nativeXMLURL` is the rewritten XML URL. `metrics` includes
 `entry_count`, `file_count`, `directory_count`, `xml_count`, `manifest_count`,
 `resource_count`, `manifest_entry_count`,
 `manifest_verified_resource_count`, `manifest_verified`, `archive_bytes`,
 `compressed_bytes`, `uncompressed_bytes`, `reference_count`,
 `rewritten_reference_count`, `missing_reference_count`,
 `missing_reference_names`, `xml_names`, `extraction_directory`, and
 `native_xml`. For compatibility with the legacy single-XML bridge,
 `nativeXMLURL` points to the first rewritten XML; every XML and resource is
 still extracted and integrity-checked. References whose files are absent remain
 unchanged and are counted in `missing_reference_count`. The caller owns the
 successful extraction directory and should remove it after use.

 PackageImporter on this iOS build resolves packaged media through the
 uppercase SHA-1 in each matching `<media sig>` attribute. Missing attributes
 are filled from the verified manifest; existing attributes must match it.
 Metrics include `media_signature_count`, `rewritten_media_signature_count`,
 `missing_media_signature_count`, `project_scene_count`,
 `rewritten_project_scene_count`, and the internal `resource_hashes` map. Every
 rewritten XML has `type="project"` on its root `<scene>`; nested scenes are not
 modified.
 */
FOUNDATION_EXPORT BOOL AMProjPrepareNativeImport(
    NSURL *archiveURL,
    NSURL *workDirectoryURL,
    NSURL * _Nullable * _Nullable nativeXMLURL,
    NSDictionary<NSString *, id> * _Nullable * _Nullable metrics,
    NSError * _Nullable * _Nullable error);

/**
 Fully validates an input package for the iOS PackageImporter. A manifest
 package whose XML already carries every required media signature and whose
 root scenes all have `type="project"` is copied byte-for-byte. A package with
 missing signatures or a missing/non-project root type is rebuilt as a complete
 ZIP containing every normalized XML, every original resource path, and a
 recalculated manifest. Multi-XML packages without a manifest remain
 unsupported.
 */
FOUNDATION_EXPORT BOOL AMProjNormalizeProjectArchive(
    NSURL *archiveURL,
    NSURL *workDirectoryURL,
    NSURL *destinationURL,
    NSDictionary<NSString *, id> * _Nullable * _Nullable metrics,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
