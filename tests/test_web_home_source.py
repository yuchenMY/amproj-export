import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMHomeUI.m").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
CLOUD_SYNC = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")


class WebHomeSourceTests(unittest.TestCase):
    def test_home_ui_is_a_standalone_dylib(self):
        cloud_rule = MAKEFILE.split("AMProjExportCloud.dylib:", 1)[1].split(
            "AMProjExportDebug.dylib:", 1
        )[0]
        home_rule = MAKEFILE.split("AMHomeUI.dylib:", 1)[1].split("clean:", 1)[0]
        self.assertNotIn("AMHomeUI.m", cloud_rule)
        self.assertNotIn("AMWebHome.m", cloud_rule)
        self.assertIn("AMHomeUI.m", home_rule)
        self.assertIn("-framework WebKit", home_rule)
        self.assertIn("-install_name @rpath/AMHomeUI.dylib", home_rule)

    def test_home_ui_self_installs_without_cloud_linkage(self):
        self.assertIn("__attribute__((constructor))", SOURCE)
        self.assertIn("AMHomeUIInstall();", SOURCE)
        self.assertNotIn('#import "AMHomeUI.h"', CLOUD_SYNC)
        self.assertNotIn("AMHomeUIInstall();", CLOUD_SYNC)
        self.assertNotIn("AMWebHome", CLOUD_SYNC)

    def test_web_message_action_is_type_checked_before_string_dispatch(self):
        self.assertIn("[rawAction isKindOfClass:NSString.class]", SOURCE)
        self.assertIn("NSString *action = rawAction;", SOURCE)
        self.assertIn("message.frameInfo.isMainFrame", SOURCE)
        self.assertIn('isEqualToString:@"amhome.meowcr.cn"', SOURCE)

    def test_home_and_feed_hooks_restore_late_or_returned_home(self):
        self.assertIn('@"HomeVC"', SOURCE)
        self.assertIn('@"FeedVC"', SOURCE)
        self.assertIn("AMHomeUIViewDidAppear", SOURCE)
        self.assertIn("AMHomeUIInstallControllerHooks();", SOURCE)
        self.assertIn("AMHomeUIAttachToController", SOURCE)
        self.assertIn("AMHomeUIEmbeddedController.view.hidden = NO;", SOURCE)

    def test_missing_native_home_has_full_screen_fallback(self):
        self.assertIn("AMHomeUIShowFallback", SOURCE)
        self.assertIn("AMHomeUIOverlayWindow", SOURCE)
        self.assertIn("if (attempt >= 60)", SOURCE)

    def test_native_editor_bridge_selects_projects_tab(self):
        self.assertIn("AMHomeUISelectProjectsTab", SOURCE)
        self.assertIn('@"openEditor"', SOURCE)
        self.assertIn('@"projects"', SOURCE)

    def test_avatar_uses_cloud_cache_and_change_notifications(self):
        self.assertIn('@"account-avatar.png"', SOURCE)
        self.assertIn('@"AMCloudAvatarChangedNotification"', SOURCE)
        self.assertIn('@"AMCloudTokenChangedNotification"', SOURCE)
        self.assertIn('@"AMHomeUIShowAccountNotification"', SOURCE)
        self.assertIn("AMCloudAvatarChangedNotification", CLOUD_SYNC)
        self.assertIn("AMHomeUIShowAccountNotification", CLOUD_SYNC)
        self.assertIn("AMHomeUIOriginalBarImageKey", SOURCE)
        self.assertIn("AMHomeUIOriginalButtonImageKey", SOURCE)
        self.assertIn("document.getElementById('refreshButton')", SOURCE)
        self.assertIn("bridge.postMessage({action:'openAccount'})", SOURCE)
        self.assertIn('isEqualToString:@"openAccount"', SOURCE)
        self.assertIn("[self updateAvatar];", SOURCE)
        self.assertNotIn("overlayAvatarEnabled", SOURCE)

    def test_ci_publishes_home_ui_binary(self):
        self.assertIn('Path("AMProjExport/AMHomeUI.dylib")', WORKFLOW)
        self.assertIn("AMProjExport/AMHomeUI.dylib", WORKFLOW)
        self.assertIn('"_AMHomeUIInstall"', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
