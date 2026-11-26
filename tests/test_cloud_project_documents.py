"""Cloud XML identity, legacy backup isolation, and bounded GET retries."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXPORT = (ROOT / "AMProjExport/AMProjExport.m").read_text(encoding="utf-8")
CLOUD = (ROOT / "AMProjExport/AMCloudSync.m").read_text(encoding="utf-8")


def function(source, signature):
    start = source.index(signature)
    end = source.index("\n}\n", start) + 3
    return source[start:end]


class CloudProjectDocumentTests(unittest.TestCase):
    def test_project_only_exits_before_material_resolution_and_zip(self):
        block = function(EXPORT, "static void amproj_writeDirectArchive(")
        branch = block.index("if (request.uploadToCloud && !request.includeMedia)")
        end = block.index('#endif', branch)
        self.assertLess(block.index("amproj_validateXMLAgainstScene"), branch)
        self.assertLess(end, block.index("amproj_collectResourcesAndRewriteXML"))
        self.assertIn("amproj_writeProjectOnlyXML(xmlData, title, &error)", block[branch:end])
        self.assertIn("amproj_beginDirectCloudUpload(request, documentURL);\n                return;", block)
        self.assertNotIn("resources = @{}", block)

    def test_backup_format_uses_filename_without_guessing_package_completeness(self):
        block = function(CLOUD, "static NSString *AMCloudProjectFormat(")
        self.assertIn('version[@"filename"]', block)
        self.assertNotIn("sizeBytes", block)
        self.assertNotIn("完整", block)

    def test_legacy_conversion_requires_verified_cloud_only_archive(self):
        block = function(EXPORT, "static void amproj_prepareCopiedArchive(")
        conversion = block.index("amproj_isLegacyCloudXMLBackup(sourceSnapshot,")
        self.assertLess(block.index("AMProjPrepareNativeImport("), conversion)
        conversion = block[conversion:block.index("if (extractionPath.length)", conversion)]
        self.assertIn('preparationMetrics[@"xml_names"]', conversion)
        self.assertIn("copyItemAtURL:originalXML", conversion)
        self.assertIn("if (copied)", conversion)
        self.assertIn("transaction.kind = AMProjImportKindXMLTemplate;", conversion)
        self.assertIn("amproj_prepareCopiedXML(documentURL", conversion)
        self.assertIn("prepared = NO;", conversion)

    def test_download_retry_keeps_auth_context_and_full_integrity_checks(self):
        start = CLOUD.index("- (void)downloadProject:(NSDictionary *)project request:",
                            CLOUD.index("@implementation AMCloudClient"))
        block = CLOUD[start:CLOUD.index("- (void)loadVersions:", start)]
        self.assertEqual(block.count("AMCloudAuthMatches(token, generation)"), 3)
        self.assertIn("AMCloudShouldRetryProjectDownload(networkError, attempt)", block)
        self.assertIn("attempt:attempt + 1", block)
        self.assertIn("authToken:token generation:generation completion:completion", block)
        self.assertLess(block.index("if (networkError)"), block.index("AMCloudSHA256(temporaryURL"))
        self.assertIn("caseInsensitiveCompare:expectedSHA", block)
        self.assertIn("sizeMismatch", block)
        ui = CLOUD[CLOUD.rindex("- (void)downloadAndImportProject:(NSDictionary *)project\n") :]
        self.assertIn("AMCloudAuthMatches(requestToken, requestGeneration)", ui)
        guard = ui.index("if (!AMCloudValidateProjectDownloadContext(data, requestToken, requestGeneration))")
        guard_end = ui.index("return;", guard)
        self.assertLess(guard_end, ui.index("asyncHandler(URL"))
        self.assertLess(guard_end, ui.index("importHandler(URL"))
        self.assertLess(ui.index('actionWithTitle:@"重试下载"'), ui.index("asyncHandler(URL"))

    @unittest.skipUnless(sys.platform == "darwin", "Requires Objective-C/Foundation")
    def test_actual_xml_writer_filename_legacy_policy_and_retry_policy(self):
        functions = [
            function(EXPORT, "static NSURL* amproj_createOutputURL(NSString *title, NSError **error) {"),
            function(EXPORT, "static NSURL *amproj_writeProjectOnlyXML("),
            function(EXPORT, "static BOOL amproj_isLegacyCloudXMLBackup("),
            function(CLOUD, "static NSString *AMCloudSafeFilename("),
            function(CLOUD, "static NSString *AMCloudUploadHeaderFilename("),
            function(CLOUD, "static BOOL AMCloudShouldRetryProjectDownload("),
            function(CLOUD, "static BOOL AMCloudProjectDownloadDirectoryIsDirectChild("),
            function(CLOUD, "static BOOL AMCloudValidateProjectDownloadContext("),
            function(CLOUD, "static NSString *AMCloudProjectFormat("),
            function(CLOUD, "static NSString *AMCloudProjectDownloadTitle(NSDictionary *project) {"),
        ]
        fixture = (ROOT / "tests/cloud_project_documents_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_DOCUMENT_FUNCTIONS", "\n".join(functions))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            source = path / "documents.m"
            binary = path / "documents"
            source.write_text(fixture, encoding="utf-8")
            compiled = subprocess.run([
                "clang", "-fobjc-arc", "-framework", "Foundation", "-lz",
                "-I", str(ROOT / "AMProjExport"), str(source),
                str(ROOT / "AMProjExport/AMProjImportArchive.m"),
                str(ROOT / "AMProjExport/AMProjZIPWriter.m"), "-o", str(binary),
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary), str(path)], capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("CLOUD_PROJECT_DOCUMENTS_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
