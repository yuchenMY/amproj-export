"""Cloud selection pixels and native page containment regressions."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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

    def test_host_requires_project_ownership_not_just_generic_header(self):
        block = SOURCE.split("static UIViewController *AMCloudContentHostForHeader", 1)[1]
        block = block.split("- (void)refreshWindowCloudOverlayVisibility", 1)[0]
        self.assertIn("if (AMCloudIsProjectsControllerClass(controller.class)) return controller;", block)
        self.assertIn("AMProjV865ProjectFlowIsRuntimeSupported()", block)
        self.assertIn('containsString:@"NodeHostingController"', block)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_production_host_selection_with_swiftui_and_negative_owners(self):
        marker = "static UIViewController *AMCloudContentHostForHeader(UIView *header) {"
        implementation = marker + SOURCE.split(marker, 1)[1].split(
            "- (void)refreshWindowCloudOverlayVisibility", 1)[0]
        fixture = (ROOT / "tests/cloud_tab_containment_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_CLOUD_HOST", implementation)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "containment.m"
            binary = Path(temporary) / "containment"
            source.write_text(fixture, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(source),
                "-o", str(binary)], check=True, capture_output=True, timeout=30)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("CLOUD_CONTAINMENT_PASS", result.stdout)

    def test_teardown_pairs_child_lifecycle_and_invalidates_pending_taps(self):
        block = SOURCE.split("- (void)setCloudLibraryVisible:(BOOL)visible {", 1)[1]
        block = block.split("- (void)attachCloudBackupBannerToController", 1)[0]
        for call in ("willMoveToParentViewController:nil", "removeFromSuperview",
                     "removeFromParentViewController"):
            self.assertIn(call, block)
        self.assertIn("manager.cloudSelectionGeneration++;", SOURCE)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_probe_walk_has_node_depth_and_hidden_subtree_limits(self):
        host_marker = "static UIViewController *AMCloudContentHostForHeader(UIView *header) {"
        host = host_marker + SOURCE.split(host_marker, 1)[1].split(
            "#if AMPROJ_BETA_DIAGNOSTICS", 1)[0]
        tree_marker = "static NSDictionary *AMCloudProbeView(UIView *view, UIWindow *window) {"
        tree = tree_marker + SOURCE.split(tree_marker, 1)[1].split(
            "// 仅本机显式 flag", 1)[0]
        fixture = (ROOT / "tests/cloud_tab_containment_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_CLOUD_HOST", host)
        fixture = fixture.replace("// AMPROJ_PRODUCTION_PROBE_TREE", tree)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "probe.m"
            binary = Path(temporary) / "probe"
            source.write_text(fixture, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-DAMPROJ_PROBE_TREE_TEST=1", "-framework",
                "Foundation", str(source), "-o", str(binary)], check=True,
                capture_output=True, timeout=30)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("CLOUD_PROBE_BUDGET_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
