"""Cloud import terminal feedback and embedded-page preservation."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLOUD = (ROOT / "AMProjExport/AMCloudSync.m").read_text(encoding="utf-8")
EXPORT = (ROOT / "AMProjExport/AMProjExport.m").read_text(encoding="utf-8")


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n}\n", start) + 3]


class CloudImportFeedbackTests(unittest.TestCase):
    def test_handoff_preserves_presenter_and_does_not_claim_terminal_success(self):
        block = function(CLOUD, "- (void)downloadAndImportProject:(NSDictionary *)project\n                       presenter:(UIViewController *)presenter {")
        self.assertNotIn("[presenter dismissViewControllerAnimated:", block)
        self.assertNotIn("AMCloudSyncShowImportResult", block)
        self.assertIn('@"import_confirmed": @NO', block)
        self.assertIn("[weakSelf refreshWindowCloudOverlayVisibility]", block)
        self.assertIn("[strongSelf refreshWindowCloudOverlayVisibility]", block)
        wrapper = function(CLOUD, "void AMCloudSyncShowImportResult(")
        self.assertIn("dispatch_get_main_queue()", wrapper)

    def test_success_is_after_verified_store_write_and_duplicates_are_distinct(self):
        start = EXPORT.index("void (^presentStoreResult)(BOOL written, NSString *projectTitle)")
        block = EXPORT[start:EXPORT.index("void (^storeDenied)", start)]
        success, failure = block.split("} else {", 1)
        self.assertIn("if (written)", success)
        self.assertIn('if (finished.cloudResultRequested)', success)
        self.assertIn('AMCloudSyncShowImportResult(@"导入完成"', success)
        self.assertNotIn("AMCloudSyncShowImportResult", failure)
        duplicate_start = EXPORT.index("BOOL waitingForOwner = duplicateContent &&")
        duplicate = EXPORT[duplicate_start:EXPORT.index("// A duplicate-content callback", duplicate_start)]
        self.assertIn('if (duplicateContent && [source hasPrefix:@"cloud_download"])', duplicate)
        waiting, completed = duplicate.split('if (duplicateContent && [source hasPrefix:@"cloud_download"])', 1)[1].split("} else {", 1)
        self.assertIn("if (waitingForOwner)", waiting)
        self.assertNotIn("AMCloudSyncShowImportResult", waiting)
        self.assertIn('AMCloudSyncShowImportResult(@"文件已存在"', completed)

    def test_cloud_waiter_requests_final_feedback_from_the_real_owner(self):
        claim = function(EXPORT, "static BOOL amproj_claimImportTransaction(")
        self.assertIn('transaction.cloudResultRequested = [source hasPrefix:@"cloud_download"]', claim)
        self.assertIn('existing.cloudResultRequested = YES', claim)
        fingerprint = function(EXPORT, "static BOOL amproj_claimImportFingerprint(")
        owner_branch = fingerprint[fingerprint.index('if (ownerID && ![ownerID isEqualToString:transactionID])'):]
        self.assertIn('if (transaction.cloudResultRequested)', owner_branch)
        self.assertIn('amproj_importTransactions[ownerID].cloudResultRequested = YES', owner_branch)

    @unittest.skipUnless(sys.platform == "darwin", "Requires Objective-C/Foundation")
    def test_actual_result_queue_waits_for_ui_and_preserves_order(self):
        methods = "\n".join(function(CLOUD, signature) for signature in (
            "- (void)enqueueImportResultTitle:(NSString *)title message:(NSString *)message {",
            "- (void)showNextImportResult {",
        ))
        fixture = (ROOT / "tests/cloud_import_feedback_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_FEEDBACK_METHODS", methods)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "feedback.m"
            binary = Path(temporary) / "feedback"
            source.write_text(fixture, encoding="utf-8")
            compiled = subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation",
                str(source), "-o", str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("CLOUD_IMPORT_FEEDBACK_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
