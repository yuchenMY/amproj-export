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

    def test_embedded_home_keeps_the_native_header_and_tab_bar(self):
        self.assertIn("/home?embed=1&platform=ios", SOURCE)
        self.assertIn("WKUserScriptInjectionTimeAtDocumentStart", SOURCE)
        self.assertIn(".home-header{display:none!important}", SOURCE)
        self.assertIn("data-am-native-embedded", SOURCE)

    def test_home_and_feed_hooks_restore_late_or_returned_home(self):
        self.assertIn('@"HomeVC"', SOURCE)
        self.assertIn('@"FeedVC"', SOURCE)
        self.assertIn('@"AlightMotion.HomeVC"', SOURCE)
        self.assertIn('@"AlightMotion.FeedVC"', SOURCE)
        self.assertIn('@"_TtC12AlightMotion6HomeVC"', SOURCE)
        self.assertIn('@"_TtC12AlightMotion6FeedVC"', SOURCE)
        self.assertIn("AMHomeUIDirectKindForClass", SOURCE)
        self.assertIn("AMHomeUIHomeViewDidAppear", SOURCE)
        self.assertIn("AMHomeUIFeedViewDidAppear", SOURCE)
        self.assertIn("AMHomeUIHookedHomeClass", SOURCE)
        self.assertIn("AMHomeUIHookedFeedClass", SOURCE)
        self.assertIn("AMHomeUIOriginalHomeViewDidAppear", SOURCE)
        self.assertIn("AMHomeUIOriginalFeedViewDidAppear", SOURCE)
        self.assertNotIn("AMHomeUIViewDidAppear", SOURCE)
        self.assertNotIn("AMHomeUIOriginalIMPKey", SOURCE)
        self.assertIn("AMHomeUIInstallControllerHooks();", SOURCE)
        self.assertIn("method_getNumberOfArguments(method) != 3", SOURCE)
        self.assertIn("AMHomeUIClassIsViewController", SOURCE)
        self.assertNotIn("[cls isSubclassOfClass:UIViewController.class]", SOURCE)
        self.assertIn("objc_copyClassList(&count)", SOURCE)
        self.assertNotIn("objc_getClassList(", SOURCE)
        self.assertIn('NSClassFromString(className)', SOURCE)
        self.assertIn('@"AlightMotion.HomeVC"', SOURCE)
        self.assertIn('@"_TtC12AlightMotion6HomeVC"', SOURCE)
        self.assertIn("AMHomeUIInstallControllerHook(cls, kind)", SOURCE)
        self.assertIn("dispatch_async(dispatch_get_main_queue(), ^{", SOURCE)
        self.assertIn("AMHomeUIAttachToController", SOURCE)
        self.assertIn("AMHomeUIAttach();", SOURCE)
        self.assertIn("AMHomeUIEmbeddedController.view.hidden = NO;", SOURCE)
        self.assertIn("AMHomeUIControllerKindFeed = 1", SOURCE)
        self.assertIn("AMHomeUIControllerKindHome = 2", SOURCE)
        self.assertIn("if (newKind == AMHomeUIControllerKindNone) return NO;", SOURCE)
        finder = SOURCE.split("static void AMHomeUIFindBestController", 1)[1].split(
            "static BOOL AMHomeUIAttachToController", 1
        )[0]
        attach = SOURCE.split("static BOOL AMHomeUIAttachToController", 2)[2].split(
            "static BOOL AMHomeUIAttach(void)", 1
        )[0]
        self.assertIn("UIView *view = root.viewIfLoaded", finder)
        self.assertIn("view.window", finder)
        self.assertIn("CGRectIntersectsRect", finder)
        self.assertIn("UIView *hostView = controller.viewIfLoaded", attach)
        self.assertIn("!hostView.window", attach)
        self.assertIn("AMHomeUIAttachEmbeddedView(controller)", attach)
        attempt = SOURCE.split(
            "static void AMHomeUIAttachAttempt(NSUInteger attempt) {", 1
        )[1].split("static void AMHomeUIScheduleAttachAttempts", 1)[0]
        self.assertIn("BOOL attached = AMHomeUIAttach();", attempt)
        self.assertIn("if (attached && AMHomeUIHookedHomeClass)", attempt)
        self.assertNotIn("if (AMHomeUIAttach())", attempt)
        self.assertLess(
            attempt.index("if (attached && AMHomeUIHookedHomeClass)"),
            attempt.index("if (attempt == 60)"),
        )
        did_appear = SOURCE.split(
            "static void AMHomeUIControllerDidAppear", 1
        )[1].split("static void AMHomeUIHomeViewDidAppear", 1)[0]
        self.assertLess(
            did_appear.index("AMHomeUIInstallControllerHooks();"),
            did_appear.index("AMHomeUIAttach();"),
        )

    def test_every_attach_retry_has_exception_protection(self):
        attempt = SOURCE.split(
            "static void AMHomeUIAttachAttempt(NSUInteger attempt) {", 1
        )[1].split("static void AMHomeUIScheduleAttachAttempts", 1)[0]
        self.assertIn("@try", attempt)
        self.assertIn("@catch (NSException *exception)", attempt)
        self.assertIn("AMHomeUIAttachAttempt(attempt + 1)", attempt)

    def test_missing_native_home_never_creates_a_floating_switcher(self):
        attempt = SOURCE.split(
            "static void AMHomeUIAttachAttempt(NSUInteger attempt) {", 1
        )[1].split("static void AMHomeUIScheduleAttachAttempts", 1)[0]
        self.assertIn("UIApplicationStateActive", attempt)
        self.assertIn("if (attempt == 60)", attempt)
        self.assertIn("continuing low-frequency discovery", attempt)
        self.assertIn("NSTimeInterval retryDelay = attempt < 60 ? 0.25 : 2.0", attempt)
        slow_retry = attempt.split("if (attempt == 60)", 1)[1].split(
            "} @catch", 1
        )[0]
        self.assertNotIn("return;", slow_retry)
        self.assertNotIn("web home disabled", attempt)
        self.assertNotIn("AMHomeUIShowFallback", SOURCE)
        self.assertNotIn("AMHomeUIOverlayWindow", SOURCE)
        self.assertNotIn("fallbackToggleButton", SOURCE)
        self.assertNotIn('house.fill', SOURCE)

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
        self.assertIn("AMHomeUIOriginalButtonConfigurationKey", SOURCE)
        self.assertIn("AMHomeUIOriginalButtonPresentationKey", SOURCE)
        self.assertIn("button.configuration", SOURCE)
        self.assertNotIn("AMHomeUIFindNativeAccountButton(window, window", SOURCE)
        self.assertIn("AMHomeUIFindNativeAccountButton(root, window", SOURCE)
        self.assertIn("current.parentViewController", SOURCE)
        self.assertIn("navigation.visibleViewController", SOURCE)
        self.assertIn('AMHomeUIObjectPropertyForController(controller, @"accountButton")', SOURCE)
        self.assertIn("method_copyReturnType", SOURCE)
        self.assertIn('isEqualToString:@"_TtC12AlightMotion6MainVC"', SOURCE)
        self.assertIn("AMHomeUIFindMainController", SOURCE)
        self.assertIn("AMHomeUIAppendUniqueController(mainController", SOURCE)
        self.assertIn("accountOwners", SOURCE)
        self.assertIn("homeControllers", SOURCE)
        self.assertIn(
            "for (UIViewController *candidate in accountOwners)", SOURCE
        )
        self.assertIn("for (UIButton *button in propertyButtons)", SOURCE)
        self.assertIn("for (UIBarButtonItem *item in propertyBarItems)", SOURCE)
        self.assertIn("propertyButtons.count == 0", SOURCE)
        self.assertIn("propertyBarItems.count == 0", SOURCE)
        self.assertIn("labeledBarItems.count == 1", SOURCE)
        self.assertIn("labeledButtons.count == 1", SOURCE)
        self.assertNotIn("barItems.count == 1", SOURCE)
        self.assertNotIn("uniqueButtons.count == 1", SOURCE)
        self.assertIn("AMHomeUIScheduleAvatarRefreshes", SOURCE)
        self.assertIn("AMHomeUIFindBestController(root", SOURCE)
        self.assertIn("avatarHost = best ?: AMHomeUIFindMainController", SOURCE)
        self.assertIn('originalPresentation[@"contentMode"]', SOURCE)
        self.assertIn('originalPresentation[@"cornerRadius"]', SOURCE)
        self.assertIn('originalPresentation[@"clipsToBounds"]', SOURCE)
        self.assertIn("AMHomeUIAvatarOverlayKey", SOURCE)
        self.assertIn('overlay.accessibilityIdentifier = @"AMHomeUIAccountAvatar"', SOURCE)
        self.assertIn("if (overlay.superview != button)", SOURCE)
        self.assertIn("[overlay removeFromSuperview]", SOURCE)
        self.assertIn("overlay.layer.cornerRadius = diameter * 0.5", SOURCE)
        self.assertIn("[button bringSubviewToFront:overlay]", SOURCE)
        self.assertIn("document.getElementById('refreshButton')", SOURCE)
        self.assertIn("bridge.postMessage({action:'openAccount'})", SOURCE)
        self.assertIn('isEqualToString:@"openAccount"', SOURCE)
        self.assertIn("[self updateAvatar];", SOURCE)
        self.assertNotIn("overlayAvatarEnabled", SOURCE)

    def test_avatar_never_replaces_an_unlabeled_top_right_button(self):
        native_avatar = SOURCE.split(
            "static void AMHomeUIApplyAvatarToNativeController", 1
        )[1].split("static void AMHomeUIControllerDidAppear", 1)[0]
        ancestor_walk = native_avatar.split(
            "UIViewController *current = controller;", 1
        )[1].split("UINavigationController *navigation", 1)[0]
        self.assertLess(
            ancestor_walk.index("accountOwners"),
            ancestor_walk.index("AMHomeUIKindForClass"),
        )
        self.assertIn("AMHomeUIStringLooksLikeAccount(label)", native_avatar)
        self.assertIn("labeledButtons.count == 1", native_avatar)
        self.assertIn("labeledBarItems.count == 1", native_avatar)
        self.assertIn("propertyButtons.count == 0", native_avatar)
        self.assertIn("propertyBarItems.count == 0", native_avatar)
        self.assertIn(
            "for (UIViewController *candidate in accountOwners)", native_avatar
        )
        self.assertIn(
            "for (UIViewController *candidate in homeControllers)", native_avatar
        )
        self.assertNotIn("uniqueButtons.count == 1", native_avatar)
        self.assertNotIn("items.count == 1", native_avatar)
        self.assertIn('@"login"', SOURCE)
        self.assertIn('@"sign in"', SOURCE)

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
