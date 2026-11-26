"""Narrow DeviceCheck capability exception recovery; preserve normal validation outcomes."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'AMProjExport/AMProjExport.m').read_text(encoding='utf-8')


class AppAttestCapabilityTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Requires Objective-C/Foundation runtime')
    def test_actual_guard_keeps_original_results_and_only_catches_known_exception(self):
        start = SOURCE.index('// #27：')
        implementation = SOURCE[start:SOURCE.index('static BOOL amproj_runtimeIsLegacy862', start)]
        fixture = (ROOT / 'tests/app_attest_capability_smoke.m').read_text(encoding='utf-8')
        fixture = fixture.replace('// AMPROJ_PRODUCTION_ATTEST_GUARD', implementation)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'attest.m'
            binary = Path(temporary) / 'attest'
            source.write_text(fixture, encoding='utf-8')
            compiled = subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation',
                str(source), '-o', str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('APP_ATTEST_CAPABILITY_GUARD_PASS', result.stdout)

    def test_guard_installs_before_app_launch_and_retries_on_activation(self):
        constructor = SOURCE.split('static void AMProjExportInit(void) {', 1)[1]
        self.assertLess(constructor.index('amproj_installAppAttestCapabilityGuard();'),
            constructor.index('amproj_installPublic865ImportHooks();'))
        observers = SOURCE.split('static void amproj_installCrashReporter(void) {', 1)[1]
        observers = observers.split('static BOOL amproj_runtimeIsBuild865', 1)[0]
        active = observers.split('UIApplicationDidBecomeActiveNotification', 1)[1]
        self.assertIn('amproj_installAppAttestCapabilityGuard();', active)


if __name__ == '__main__':
    unittest.main()
