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
    @unittest.skipUnless(sys.platform == "darwin", "Requires Objective-C/Foundation")
    def test_owned_alert_preserves_only_current_mounted_cloud_library(self):
        methods = []
        for signature in (
            "- (void)rememberCloudLibraryAlert:(UIAlertController *)alert {",
            "- (BOOL)keepsLibraryBehindOwnedAlert {",
        ):
            start = SOURCE.index(signature)
            methods.append(SOURCE[start:SOURCE.index("\n}\n", start) + 3])
        fixture = (ROOT / "tests/cloud_library_alert_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_ALERT_METHODS", "\n".join(methods))
        refresh = SOURCE.split("- (void)refreshWindowCloudOverlayVisibility {", 1)[1]
        self.assertLess(refresh.index("keepsLibraryBehindOwnedAlert"), refresh.index("AMCloudProjectsView()"))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            source = path / "alert.m"
            binary = path / "alert"
            source.write_text(fixture, encoding="utf-8")
            compiled = subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation",
                "-I", str(ROOT / "AMProjExport"), str(source), "-o", str(binary)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CLOUD_LIBRARY_ALERT_PASS", result.stdout)

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
        self.assertNotIn("addChildViewController", block)
        self.assertIn("[header addSubview:view]", block)
        self.assertIn("constraintEqualToAnchor:header.topAnchor constant:CGRectGetMaxY(row) + 8", block)
        self.assertIn("bottom = header.bottomAnchor", block)
        self.assertIn("UIUserInterfaceStyleLight", block)
        self.assertNotIn("rootViewController", block)
        self.assertNotIn("constant:120", block)

    def test_component_requires_real_project_container_and_supported_runtime(self):
        block = SOURCE.split("static BOOL AMCloudProjectContainerEligible", 1)[1]
        block = block.split("- (void)refreshWindowCloudOverlayVisibility", 1)[0]
        self.assertIn("AMProjV865ProjectFlowIsRuntimeSupported()", block)
        self.assertIn('containsString:@"ProjectListView"', block)
        self.assertIn("CGRectGetHeight(header.bounds) >= 320", block)
        self.assertIn("@interface AMCloudLibraryView : UIView", SOURCE)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_project_container_and_native_tap_routing(self):
        marker = "static BOOL AMCloudProjectContainerEligible(UIView *header) {"
        implementation = marker + SOURCE.split(marker, 1)[1].split(
            "#if AMPROJ_BETA_DIAGNOSTICS", 1)[0]
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

    def test_component_teardown_and_pending_tap_invalidation(self):
        block = SOURCE.split("- (void)setCloudLibraryVisible:(BOOL)visible {", 1)[1]
        block = block.split("- (void)attachCloudBackupBannerToController", 1)[0]
        self.assertIn("[library removeFromSuperview]", block)
        self.assertIn("self.embeddedLibrary = nil", block)
        self.assertNotIn("removeFromParentViewController", block)
        self.assertIn("manager.cloudSelectionGeneration++;", SOURCE)
        component = SOURCE.split("@implementation AMCloudLibraryView", 1)[1]
        self.assertNotIn("self.view", component)
        self.assertIn("presenter:AMCloudTopController(nil)", component)
        self.assertIn("removeObserver:self", component)

    def test_verified_cloud_tap_mounts_synchronously_without_animation_or_cover(self):
        block = SOURCE.split("- (void)refreshWindowCloudOverlayVisibility {", 1)[1]
        block = block.split("- (void)installCloudTabTapWatcher", 1)[0]
        self.assertIn("AMCloudTabAllowsDisplay((int)state", block)
        self.assertNotIn("cloudTransitionCover", block)
        self.assertIn("self.cachedLibraryAuthGeneration != authGeneration", block)
        self.assertIn("[library refreshForPresentation]", block)
        self.assertNotIn("animateWithDuration", block)
        tap = SOURCE.split("- (void)handleCloudTabTap:", 1)[1].split("- (void)setCloudLibraryVisible:", 1)[0]
        self.assertIn("[self showPreparedCloudLibraryInProjectsView:header row:verifiedRow]", tap)
        self.assertIn("AMCloudRowForVerifiedPill(header, self.cloudPillFrame)", tap)
        self.assertIn("!CGRectIsEmpty(manager.cloudSubTabFrame)", SOURCE)
        self.assertIn("if (!CGRectIsEmpty(tabFrame) || self.cloudSubTabHost != header)", block)
        self.assertIn("self.embeddedLibrary.superview == header", block)
        self.assertLess(tap.index("showPreparedCloudLibraryInProjectsView"), tap.index("scheduleCloudTabReconciliationForGeneration:generation"))
        self.assertIn("self.cloudTapTargetKnown = mainTab || knownPill", tap)
        self.assertIn("CGRectEqualToRect(self.cloudPillHostBounds, header.bounds)", tap)
        logout = SOURCE.split("- (void)pluginTokenChanged:", 1)[1].split("- (NSURL *)accountAvatarCacheURL", 1)[0]
        self.assertIn("self.cachedLibrary = nil", logout)
        self.assertIn("self.cloudSelectionGeneration++", logout)

    def test_known_route_does_not_render_or_force_native_root_layout(self):
        refresh = SOURCE.split("- (void)refreshWindowCloudOverlayVisibility {", 1)[1].split(
            "- (AMCloudLibraryView *)prepareCloudLibrary", 1)[0]
        self.assertLess(refresh.index("if (self.cloudTapTargetKnown)"), refresh.index("AMCloudDetectCloudPillSelected"))
        repair = SOURCE.split("- (void)repairKnownCloudTabForGeneration:(NSUInteger)generation {", 1)[1].split(
            "- (void)scheduleCloudTabReconciliation", 1)[0]
        self.assertNotIn("AMCloudDetectCloudPillSelected", repair)
        self.assertNotIn("AMCloudCaptureLayoutProbe", repair)
        mount = SOURCE.split("- (void)showPreparedCloudLibraryInProjectsView:(UIView *)header row:(CGRect)row {", 1)[1].split(
            "- (void)mountCloudSubview", 1)[0]
        self.assertNotIn("layoutIfNeeded", mount)
        tap = SOURCE.split("- (void)handleCloudTabTap:(UITapGestureRecognizer *)recognizer {", 1)[1].split(
            "- (void)repairKnownCloudTabForGeneration:", 1)[0]
        self.assertIn("AMCloudProjectAncestorForTap", tap)
        self.assertNotIn("AMCloudProjectsView()", tap)
        self.assertNotIn("@0.08", tap)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_reconciliation_scheduler_limits_pixel_checks_and_cancels_old_taps(self):
        marker = "- (void)scheduleCloudTabReconciliationForGeneration:(NSUInteger)generation verifiedCloudTap:(BOOL)verifiedCloudTap {"
        implementation = marker + SOURCE.split(marker, 1)[1].split("- (void)setCloudLibraryVisible:", 1)[0]
        fixture = (ROOT / "tests/cloud_tab_schedule_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_TAP_SCHEDULE", implementation)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "schedule.m"
            binary = Path(temporary) / "schedule"
            source.write_text(fixture, encoding="utf-8")
            compiled = subprocess.run(["clang", "-fobjc-arc", "-I", str(ROOT / "AMProjExport"), "-framework", "Foundation", str(source),
                "-o", str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("CLOUD_TAP_SCHEDULE_PASS", result.stdout)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native CoreGraphics")
    def test_actual_image_readback_preserves_top_origin_for_content_boundary(self):
        implementation = "size_t width = CGImageGetWidth(image)" + SOURCE.split(
            "size_t width = CGImageGetWidth(image)", 1)[1].split("free(pixels);", 1)[0] + "free(pixels);"
        fixture = (ROOT / "tests/cloud_tab_image_geometry_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_IMAGE_READBACK", implementation)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "geometry.m"
            binary = Path(temporary) / "geometry"
            source.write_text(fixture, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-I", str(ROOT / "AMProjExport"),
                "-framework", "Foundation", "-framework", "CoreGraphics", str(source),
                "-o", str(binary)], check=True, capture_output=True, timeout=30)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("CLOUD_IMAGE_GEOMETRY_PASS", result.stdout)

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_probe_walk_has_node_depth_and_hidden_subtree_limits(self):
        host_marker = "static BOOL AMCloudProjectContainerEligible(UIView *header) {"
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

    @unittest.skipUnless(sys.platform == "darwin", "Requires native Objective-C/Foundation")
    def test_actual_library_cache_refresh_and_old_account_response_rejection(self):
        component = SOURCE.split("@implementation AMCloudLibraryView", 1)[1]
        implementation = "- (void)reload {" + component.split("- (void)reload {", 1)[1].split(
            "- (void)applyUsage", 1)[0]
        fixture = (ROOT / "tests/cloud_library_refresh_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_LIBRARY_REFRESH", implementation)
        layout = "- (void)layoutSubviews {" + component.split("- (void)layoutSubviews {", 1)[1].split(
            "- (void)onUpload", 1)[0]
        fixture = fixture.replace("// AMPROJ_PRODUCTION_LIBRARY_LAYOUT", layout)
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "refresh.m"
            binary = Path(temporary) / "refresh"
            source.write_text(fixture, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(source),
                "-o", str(binary)], check=True, capture_output=True, timeout=30)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("CLOUD_LIBRARY_REFRESH_PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
