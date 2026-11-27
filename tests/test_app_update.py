"""Execute the native update URL, installation-claim and profile identity checks."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AppUpdateTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires real WebKit content rule compiler')
    def test_actual_webkit_association_rule_compiler(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'association-webkit'
            built = subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'WebKit', '-I', str(ROOT / 'AMProjExport'), str(ROOT / 'tests/app_update_webkit_smoke.m'), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn('APP_UPDATE_WEBKIT_RULES_PASS', result.stdout)

    @unittest.skipUnless(sys.platform == 'darwin', 'Requires Objective-C/Foundation')
    def test_actual_native_update_policy(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'update-policy'
            built = subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', '-I', str(ROOT / 'AMProjExport'), str(ROOT / 'tests/app_update_policy_smoke.m'), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('APP_UPDATE_POLICY_PASS', result.stdout)
