import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AMProjExport" / "AMProjImportArchive.m"
HEADER = ROOT / "AMProjExport" / "AMProjImportArchive.h"
MAKEFILE = ROOT / "AMProjExport" / "Makefile"


class ImportArchiveSourceTests(unittest.TestCase):
    def test_public_api_and_build_include_module(self):
        header = HEADER.read_text(encoding="utf-8")
        self.assertIn("AMProjPrepareNativeImport", header)
        self.assertIn("AMProjNormalizeProjectArchive", header)
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertEqual(makefile.count("AMProjZIPWriter.m AMProjImportArchive.m"), 2)

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

    def test_native_preparation_accepts_multiple_xml_files_and_reports_names(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("if (xmlEntries.count == 0)", source)
        self.assertIn("for (AMProjImportEntry *xmlEntry in xmlEntries)", source)
        self.assertIn("NSMutableArray<NSString *> *xmlNames", source)
        self.assertIn('"xml_names": [xmlNames copy]', source)
        self.assertIn('"missing_reference_names"', source)
        self.assertNotIn("xmlEntries.count != 1", source)

    def test_normalization_rebuilds_manifest_and_preserves_missing_references(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("AMProjNormalizeProjectArchive", source)
        self.assertIn("AMProjZIPWriteProjectArchive", source)
        self.assertIn('preparationMetrics[@"missing_reference_count"]', source)
        self.assertIn('caseInsensitiveCompare:@"manifest.txt"', source)
        self.assertIn("resourceURLs[name] = child", source)
        self.assertIn("includingPropertiesForKeys:@[NSURLIsDirectoryKey", source)
        self.assertIn("options:0", source)
        self.assertIn("Unable to inspect an extracted project entry", source)


if __name__ == "__main__":
    unittest.main()
