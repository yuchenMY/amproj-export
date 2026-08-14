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
        self.assertIn("-framework CoreGraphics", home_rule)
        self.assertIn("-install_name @rpath/AMHomeUI.dylib", home_rule)

    def test_home_ui_is_explicitly_loaded_after_cloud_bootstrap(self):
        self.assertNotIn("__attribute__((constructor))", SOURCE)
        self.assertIn("void AMHomeUIInstall(void)", SOURCE)
        self.assertNotIn("UIApplicationDidFinishLaunchingNotification", SOURCE)
        self.assertIn("AMHomeUIScheduleActivation(0.35)", SOURCE)
        self.assertNotIn('#import "AMHomeUI.h"', CLOUD_SYNC)
        self.assertIn("#import <dlfcn.h>", CLOUD_SYNC)
        self.assertIn("dlopen(homeUIPath.fileSystemRepresentation", CLOUD_SYNC)
        self.assertIn("RTLD_NOW | RTLD_LOCAL", CLOUD_SYNC)
        self.assertIn('dlsym(handle, "AMHomeUIInstall")', CLOUD_SYNC)
        self.assertIn("AMCloudScheduleHomeUILoad();", CLOUD_SYNC)
        self.assertNotIn("dlclose(", CLOUD_SYNC)
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
        self.assertIn("method_getNumberOfArguments(method) != 3", SOURCE)
        self.assertIn("AMHomeUIClassIsViewController", SOURCE)
        self.assertNotIn("[cls isSubclassOfClass:UIViewController.class]", SOURCE)
        self.assertIn("objc_copyClassList(&count)", SOURCE)
        self.assertNotIn("objc_getClassList(", SOURCE)
        self.assertIn("dispatch_async(dispatch_get_main_queue(), ^{", SOURCE)
        self.assertIn("AMHomeUIAttachToController", SOURCE)
        self.assertIn("AMHomeUIEmbeddedController.view.hidden = NO;", SOURCE)

    def test_every_attach_retry_has_exception_protection(self):
        attempt = SOURCE.split(
            "static void AMHomeUIAttachAttempt(NSUInteger attempt) {", 1
        )[1].split("static void AMHomeUIScheduleAttachAttempts", 1)[0]
        self.assertIn("@try", attempt)
        self.assertIn("@catch (NSException *exception)", attempt)
        self.assertIn("AMHomeUIAttachAttempt(attempt + 1)", attempt)

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

    def test_web_account_button_survives_spa_dom_rebuilds(self):
        self.assertIn("window.__amHomeAccountButtonState", SOURCE)
        self.assertIn("new MutationObserver", SOURCE)
        self.assertIn("node.querySelector('#refreshButton')", SOURCE)
        self.assertIn("attributeFilter:['id','class','disabled'", SOURCE)
        self.assertIn("state.schedule(force)", SOURCE)
        self.assertIn("state.observer.disconnect()", SOURCE)
        self.assertIn("finally{state.observe();}", SOURCE)
        self.assertIn("current.__amHomeAccountButtonReady===true", SOURCE)
        self.assertIn("button.__amHomeAvatar=state.avatar", SOURCE)
        self.assertIn("state.avatar=avatar||''", SOURCE)
        self.assertIn("else{button.style.padding='';", SOURCE)

    def test_ci_publishes_home_ui_binary(self):
        self.assertIn('Path("AMProjExport/AMHomeUI.dylib")', WORKFLOW)
        self.assertIn("AMProjExport/AMHomeUI.dylib", WORKFLOW)
        self.assertIn('"_AMHomeUIInstall"', WORKFLOW)
        self.assertIn('["otool", "-L", "AMProjExport/AMProjExportCloud.dylib"]', WORKFLOW)
        self.assertIn('section["type"] in (0x9, 0x16)', WORKFLOW)
        self.assertIn('home_ui["external_defined_symbols"]', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
