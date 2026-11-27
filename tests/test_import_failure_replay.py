"""An unchanged failed Inbox file must not restart when the app becomes active."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'AMProjExport/AMProjExport.m').read_text(encoding='utf-8')

class ImportFailureReplayTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires Objective-C/Foundation')
    def test_actual_failure_records_survive_restart_and_allow_changed_files(self):
        start = SOURCE.index('static NSDictionary *amproj_automaticImportFileIdentity(')
        helpers = SOURCE[start:SOURCE.index('static void amproj_releaseImportTransaction(', start)]
        fixture = (ROOT / 'tests/import_failure_replay_smoke.m').read_text(encoding='utf-8')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            code, binary = root / 'replay.m', root / 'replay'
            code.write_text(fixture.replace('// AMPROJ_PRODUCTION_REPLAY_HELPERS', helpers), encoding='utf-8')
            compiled = subprocess.run(['clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', str(code), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            suite = 'cn.ayakameow.am.import-replay-test.' + uuid.uuid4().hex
            for phase, marker in [('seed', 'IMPORT_REPLAY_SEED_PASS'), ('verify', 'IMPORT_FAILURE_REPLAY_PASS')]:
                result = subprocess.run([str(binary), phase, suite, str(root)], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(marker, result.stdout)

    def test_only_failed_validation_records_a_file(self):
        start = SOURCE.index('static void amproj_releaseImportTransaction(')
        release = SOURCE[start:SOURCE.index('static void amproj_releaseImportTransactionForURL(', start)]
        self.assertIn('!success && transaction.state == AMProjImportTransactionValidating', release)
        self.assertIn('!transaction.packageIntegrityVerified', release)
        self.assertIn('amproj_rememberFailedAutomaticImport(transaction.incomingFileIdentity', release)
        self.assertIn('amproj_forgetFailedAutomaticImport(transaction.incomingURL', release)

    def test_automatic_scans_skip_failures_but_explicit_actions_do_not(self):
        start = SOURCE.index('static BOOL amproj_scanDocumentsInboxNow(')
        documents = SOURCE[start:SOURCE.index('static NSDictionary* amproj_shareRequestDescriptor(', start)]
        self.assertLess(documents.index('amproj_shouldSkipFailedAutomaticImport'), documents.index('amproj_handleIncomingProjectURLSafely'))
        start = SOURCE.index('static BOOL amproj_scanShareInboxNow(')
        share = SOURCE[start:SOURCE.index('static void amproj_scanLocalImportInboxes(', start)]
        self.assertIn('if (!requestedID.length && amproj_shouldSkipFailedAutomaticImport', share)
        start = SOURCE.index('static void amproj_clearImportSuppression(NSURL *URL, NSString *name) {')
        clear = SOURCE[start:SOURCE.index('static void amproj_markImportTransactionState(', start)]
        self.assertIn('amproj_forgetFailedAutomaticImport(URL', clear)

if __name__ == '__main__':
    unittest.main()
