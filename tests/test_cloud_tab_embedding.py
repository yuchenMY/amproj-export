"""Cloud selection pixels and native page containment regressions."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport/AMCloudSync.m").read_text(encoding="utf-8")


class CloudTabEmbeddingTests(unittest.TestCase):
    def test_actual_pixel_classifier_rejects_unselected_text(self):
        command = json.loads(os.environ["AMPROJ_POLICY_CC"]) if os.environ.get("AMPROJ_POLICY_CC") else None
        if command is None:
            compiler = shutil.which("clang") or shutil.which("cc")
            if not compiler:
                self.skipTest("A C compiler is required")
            command = [compiler]
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / ("cloud.exe" if os.name == "nt" else "cloud")
            subprocess.run(command + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                str(ROOT / "tests/cloud_tab_policy_host.c"), "-o", str(binary)],
                check=True, capture_output=True, timeout=90)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("CLOUD_TAB_POLICY_PASS", result.stdout)

    def test_main_navigation_never_opens_from_touch_fraction(self):
        block = SOURCE.split("- (void)handleCloudTabTap:", 1)[1]
        block = block.split("- (void)setCloudLibraryVisible:", 1)[0]
        self.assertNotIn("fraction", block)
        self.assertNotIn("setCloudLibraryVisible:YES", block)
        self.assertIn("if (!mainTab && !subTab) return;", block)
        self.assertIn("generation != self.cloudSelectionGeneration", block)

    def test_child_is_inside_project_content_and_uses_native_header_boundary(self):
        block = SOURCE.split("- (void)refreshWindowCloudOverlayVisibility {", 1)[1]
        block = block.split("- (void)installCloudTabTapWatcher", 1)[0]
        self.assertIn("[host addChildViewController:library]", block)
        self.assertIn("[host.view addSubview:view]", block)
        self.assertIn("constraintEqualToAnchor:header.bottomAnchor", block)
        self.assertIn("UIUserInterfaceStyleLight", block)
        self.assertNotIn("rootViewController", block)
        self.assertNotIn("constant:120", block)

    def test_teardown_pairs_child_lifecycle_and_invalidates_pending_taps(self):
        block = SOURCE.split("- (void)setCloudLibraryVisible:(BOOL)visible {", 1)[1]
        block = block.split("- (void)attachCloudBackupBannerToController", 1)[0]
        for call in ("willMoveToParentViewController:nil", "removeFromSuperview",
                     "removeFromParentViewController"):
            self.assertIn(call, block)
        self.assertIn("manager.cloudSelectionGeneration++;", SOURCE)


if __name__ == "__main__":
    unittest.main()
