import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMWebHome.m").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
CLOUD_SYNC = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")


class WebHomeSourceTests(unittest.TestCase):
    def test_cloud_build_links_web_home_only_in_cloud_target(self):
        cloud_rule = MAKEFILE.split("AMProjExportCloud.dylib:", 1)[1].split(
            "AMProjExportDebug.dylib:", 1
        )[0]
        self.assertIn("AMWebHome.m", cloud_rule)
        self.assertIn("-framework WebKit", cloud_rule)
        release_rule = MAKEFILE.split("AMProjExport.dylib:", 1)[1].split(
            "AMProjExportCloud.dylib:", 1
        )[0]
        self.assertNotIn("AMWebHome.m", release_rule)

    def test_web_home_is_installed_with_cloud_runtime(self):
        self.assertIn('#import "AMWebHome.h"', CLOUD_SYNC)
        self.assertIn("AMWebHomeInstall();", CLOUD_SYNC)

    def test_web_message_action_is_type_checked_before_string_dispatch(self):
        self.assertIn("[rawAction isKindOfClass:NSString.class]", SOURCE)
        self.assertIn("NSString *action = rawAction;", SOURCE)

    def test_feed_view_did_appear_hook_restores_late_or_returned_home(self):
        self.assertIn("AMWebHomeFeedViewDidAppear", SOURCE)
        self.assertIn("AMWebHomeInstallFeedHooks();", SOURCE)
        self.assertIn("AMWebHomeAttachToFeedController", SOURCE)
        self.assertIn("home.view.hidden = NO;", SOURCE)


if __name__ == "__main__":
    unittest.main()
