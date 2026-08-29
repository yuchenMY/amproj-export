import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AMProjExport" / "AMProjImportArchive.m"
HEADER = ROOT / "AMProjExport" / "AMProjImportArchive.h"
MAKEFILE = ROOT / "AMProjExport" / "Makefile"
ZIP_SOURCE = ROOT / "AMProjExport" / "AMProjZIPWriter.m"
ZIP_HEADER = ROOT / "AMProjExport" / "AMProjZIPWriter.h"


class ImportArchiveSourceTests(unittest.TestCase):
    def test_public_api_and_build_include_module(self):
        header = HEADER.read_text(encoding="utf-8")
        self.assertIn("AMProjPrepareNativeImport", header)
        self.assertIn("AMProjNormalizeProjectArchive", header)
        self.assertIn("AMProjExtractPluginArchive", header)
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertEqual(makefile.count("AMProjZIPWriter.m AMProjImportArchive.m"), 3)
        self.assertIn("AMProjExport.dylib", makefile)
        self.assertIn("AMProjExportOffline.dylib", makefile)
        self.assertNotIn("AMProjExportCloud.dylib", makefile)

    def test_zip_safety_and_integrity_checks_are_present(self):
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "0x06054b50",
            "0x02014b50",
            "0x04034b50",
            "ZIP64",
            "Split project packages",
            "O_NOFOLLOW",
            "crc32",
            "inflateInit2(&stream, -MAX_WBITS)",
            "ZIP entries overlap",
        ):
            self.assertIn(required, source)

    def test_source_archive_is_never_opened_for_writing(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("open(archiveURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW)", source)
        self.assertNotIn("unlink(archiveURL.fileSystemRepresentation)", source)

    def test_xml_rewrite_and_atomic_publish_are_present(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("amproj:", source)
        self.assertIn('regularExpressionWithPattern:@"amproj:((?:&(?:amp|quot|apos|lt|gt);|[^\\\\\\\"\'<>&])+)"', source)
        self.assertIn("AMProjImportEscapeXMLValue(url.absoluteString)", source)
        self.assertIn(".native-import.xml", source)
        self.assertIn("missing_reference_count", source)
        self.assertIn("if (url) {", source)
        self.assertIn("NSMutableSet<NSString *> *missingReferences", source)
        self.assertIn("localRewrittenCount++", source)
        self.assertIn('\"rewritten_reference_count\": @(rewrittenCount)', source)
        self.assertIn("[missingReferences addObject:identity]", source)
        self.assertIn("*missingCount = missingReferences.count", source)
        self.assertNotIn('URLByAppendingPathComponent:@".missing"', source)
        self.assertIn("rename(temporaryURL.fileSystemRepresentation", source)

    def test_manifest_is_strictly_verified_against_streamed_resource_hashes(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("#import <CommonCrypto/CommonDigest.h>", source)
        self.assertIn("AMProjImportValidateManifest", source)
        self.assertIn("AMProjImportSHA1ForFileURL", source)
        self.assertIn("CC_SHA1_Init", source)
        self.assertIn("CC_SHA1_Update", source)
        self.assertIn("CC_SHA1_Final", source)
        self.assertIn("manifest.txt SHA-1 values must use 40 uppercase", source)
        self.assertIn("manifest.txt contains a duplicate resource filename", source)
        self.assertIn("manifest.txt contains a duplicate SHA-1 value", source)
        self.assertIn("manifest.txt lists a resource that is missing", source)
        self.assertIn("Project resources are missing from manifest.txt", source)
        self.assertIn("not XML or the manifest itself", source)
        self.assertIn('stringByReplacingOccurrencesOfString:@"\\r\\n"', source)

        validation = source.index("AMProjImportValidateManifest(entries")
        rewrite = source.index("AMProjImportRewriteXML(", validation)
        self.assertLess(validation, rewrite)

    def test_manifest_metrics_distinguish_legacy_and_verified_packages(self):
        source = SOURCE.read_text(encoding="utf-8")
        for metric in (
            '"resource_count": @(resourceCount)',
            '"manifest_entry_count": @(manifestEntryCount)',
            '"manifest_verified_resource_count": @(manifestVerifiedResourceCount)',
            '"manifest_verified": @(manifestVerified)',
        ):
            self.assertIn(metric, source)

        header = HEADER.read_text(encoding="utf-8")
        self.assertIn("UPPERCASE_SHA1:filename", header)
        self.assertIn("manifest_verified_resource_count", header)

    def test_media_signatures_are_derived_from_verified_manifest(self):
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "resourceHashesByNameOut",
            "media_signature_count",
            "rewritten_media_signature_count",
            "missing_media_signature_count",
            "AMProjImportMediaResourceName",
            "A project media sig does not match manifest.txt",
            "resourceHashesByName[AMProjImportFoldedName(resourceName)]",
        ):
            self.assertIn(required, source)
        self.assertIn('sig=\\\"%@\\\"', source)
        self.assertNotIn("(void)resourceHashesByName", source)
        self.assertIn("URI replacements and signature edits", source)

    def test_root_scene_is_normalized_to_project_without_touching_nested_scenes(self):
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "AMProjImportRootSceneTagRange",
            "AMProjImportEnsureProjectSceneRoot",
            '@"type"',
            '@"project"',
            'project_scene_count',
            'rewritten_project_scene_count',
        ):
            self.assertIn(required, source)
        self.assertIn(
            "projectSceneRewrites == 0", source
        )
        self.assertIn(
            "rewrittenProjectSceneCount == 0", source
        )
        self.assertIn("Attribute-looking text inside a quoted value", source)
        self.assertIn("[name caseInsensitiveCompare:attributeName]", source)

        header = HEADER.read_text(encoding="utf-8")
        self.assertIn('type="project"', header)
        self.assertIn("nested scenes are not", header)

    def test_native_preparation_accepts_multiple_xml_files_and_reports_names(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("if (xmlEntries.count == 0)", source)
        self.assertIn("for (AMProjImportEntry *xmlEntry in xmlEntries)", source)
        self.assertIn("NSMutableArray<NSString *> *xmlNames", source)
        self.assertIn('"xml_names": [xmlNames copy]', source)
        self.assertIn('"missing_reference_names"', source)
        self.assertNotIn("xmlEntries.count != 1", source)

    def test_normalization_rebuilds_complete_signed_multi_scene_archive(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("AMProjNormalizeProjectArchive", source)
        self.assertIn("AMProjImportPublishExactArchive", source)
        self.assertIn("AMProjZIPWriteProjectArchiveFiles(destinationURL", source)
        self.assertIn("signedSceneXMLFiles", source)
        self.assertIn("enumeratorAtURL:extractionURL", source)
        self.assertIn("resourceURLs", source)
        self.assertIn('preparationMetrics[@"missing_reference_count"]', source)
        self.assertIn('@"archive_preserved": @NO', source)
        self.assertIn('@"xml_preserved": @YES', source)

    def test_streaming_writer_accepts_safe_relative_paths_and_multiple_xml(self):
        source = ZIP_SOURCE.read_text(encoding="utf-8")
        header = ZIP_HEADER.read_text(encoding="utf-8")
        self.assertIn("AMProjZIPWriteProjectArchiveFiles", source)
        self.assertIn("AMProjZIPWriteProjectArchiveFiles", header)
        self.assertIn("sceneXMLFiles.count", source)
        self.assertIn('componentsSeparatedByString:@"/"', source)
        self.assertIn('[name hasPrefix:@"~"]', source)
        self.assertIn('[name containsString:@":"]', source)
        self.assertIn('[name containsString:@"\\\\"]', source)
        self.assertNotIn("filenames must be non-empty flat filenames", source)


if __name__ == "__main__":
    unittest.main()
