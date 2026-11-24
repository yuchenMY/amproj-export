"""Run the production welcome text walk against native-only host fixtures."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport/AMProjExport.m").read_text(encoding="utf-8")


class WelcomeScanPerformanceTests(unittest.TestCase):
    def test_normal_windows_exit_before_any_hierarchy_probe(self):
        sweep = SOURCE.split("static void amproj_suppressIPAFireWelcomeWindows(NSString *source) {", 1)[1]
        sweep = sweep.split("static void amproj_scheduleIPAFireWelcomeSuppression(NSString *source) {", 1)[0]
        gate = sweep.index("if (window.windowLevel <= UIWindowLevelNormal) continue;")
        for probe in ("AMProjViewHierarchyHasCrackClass(window, 0)",
                      "amproj_IPAFireViewContainsMarker(window, 0)",
                      "amproj_IPAFireFindOverlayView(rootView, 0)"):
            self.assertLess(gate, sweep.index(probe))

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_production_walk_does_not_request_accessibility_or_rescan_negative_subtrees(self):
        implementation = SOURCE.split("static BOOL amproj_IPAFireTextMatches(NSString *text) {", 1)[1]
        implementation = "static BOOL amproj_IPAFireTextMatches(NSString *text) {" + implementation
        implementation = implementation.split("// A rootless overlay window", 1)[0]
        fixture = (ROOT / "tests/welcome_scan_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_WELCOME_WALK", implementation)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "welcome.m"
            binary = Path(temporary) / "welcome"
            source.write_text(fixture, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(source),
                            "-o", str(binary)], check=True, capture_output=True, timeout=30)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("WELCOME_WALK_PASS nodes=1021 accessibility_reads=0", result.stdout)


if __name__ == "__main__":
    unittest.main()
