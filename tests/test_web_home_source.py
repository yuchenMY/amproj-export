import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMHomeUI.m").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
CLOUD_SYNC = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")


class WebHomeSourceTests(unittest.TestCase):
    def test_home_ui_stays_modular_but_is_linked_into_cloud_runtime(self):
        cloud_rule = MAKEFILE.split("AMProjExportCloud.dylib:", 1)[1].split(
            "AMProjExportDebug.dylib:", 1
        )[0]
        home_rule = MAKEFILE.split("AMHomeUI.dylib:", 1)[1].split("clean:", 1)[0]
        self.assertNotIn("AMHomeUI.m", cloud_rule)
        self.assertIn("AMHomeUI.dylib", cloud_rule)
        self.assertNotIn("AMWebHome.m", cloud_rule)
        self.assertIn("AMHomeUI.m", home_rule)
        self.assertIn("-framework WebKit", home_rule)
        self.assertIn("-framework CoreGraphics", home_rule)
        self.assertIn("-install_name @rpath/AMHomeUI.dylib", home_rule)

    def test_home_ui_is_directly_installed_by_cloud_bootstrap(self):
        self.assertNotIn("__attribute__((constructor))", SOURCE)
        self.assertIn("void AMHomeUIInstall(void)", SOURCE)
        self.assertNotIn("UIApplicationDidFinishLaunchingNotification", SOURCE)
        self.assertIn("AMHomeUIScheduleActivation(0.35)", SOURCE)
        self.assertIn('#import "AMHomeUI.h"', CLOUD_SYNC)
        self.assertIn("AMHomeUIInstall();", CLOUD_SYNC)
        self.assertNotIn("#import <dlfcn.h>", CLOUD_SYNC)
        self.assertNotIn("dlopen(", CLOUD_SYNC)
        self.assertNotIn("dlsym(", CLOUD_SYNC)
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
        self.assertIn("document.querySelectorAll('.home-header')", SOURCE)
        self.assertIn("header.hidden=true", SOURCE)
        self.assertIn("header.setAttribute('aria-hidden','true')", SOURCE)
        self.assertIn("new MutationObserver(apply)", SOURCE)
        self.assertIn("childList:true,subtree:true", SOURCE)
        self.assertIn("data-am-native-embedded", SOURCE)
        self.assertNotIn("document.createElement('style')", SOURCE)
        self.assertNotIn("style.textContent", SOURCE)
        self.assertIn("UIUserInterfaceStyleLight", SOURCE)
        self.assertIn(
            "self.webView.overrideUserInterfaceStyle = UIUserInterfaceStyleLight",
            SOURCE,
        )

    def test_home_embedding_targets_the_current_native_home_host(self):
        self.assertIn("AMHomeUIDirectKindForClass", SOURCE)
        self.assertIn("AMHomeUIClassIsViewController", SOURCE)
        self.assertIn("AMHomeUIClassIsMainController", SOURCE)
        self.assertNotIn("AMHomeUIInstallControllerHook", SOURCE)
        self.assertNotIn("class_replaceMethod", SOURCE)
        self.assertNotIn("viewDidAppear attach failed", SOURCE)
        self.assertIn("AMHomeUIAttachToHost", SOURCE)
        self.assertIn("AMHomeUIAttach();", SOURCE)
        self.assertIn("AMHomeUIControllerKindFeed = 1", SOURCE)
        self.assertIn("AMHomeUIControllerKindHome = 2", SOURCE)
        self.assertIn("AMHomeUIControllerKindMain = 3", SOURCE)
        self.assertIn('AMHomeUIObjectPropertyForController(controller, @"mainView")', SOURCE)
        self.assertIn('[controller valueForKey:@"mainView"]', SOURCE)
        self.assertIn('controller, @"topBar", controllerView, window', SOURCE)
        self.assertIn('controller, @"tabBarView", controllerView, window', SOURCE)
        self.assertIn("AMHomeUICommonAncestor", SOURCE)
        self.assertIn("AMHomeUIChromeDefinesRegion", SOURCE)
        self.assertIn("[name containsString:@\"HomeVC\"]", SOURCE)
        self.assertIn("[name containsString:@\"FeedVC\"]", SOURCE)
        self.assertIn("AMHomeUIViewIsVisible", SOURCE)
        self.assertIn("view.window != window", SOURCE)
        self.assertIn("current.hidden || current.alpha <= 0.01", SOURCE)
        self.assertIn("CGRectIntersectsRect(window.bounds, frame)", SOURCE)
        self.assertIn("AMHomeUIFindBestHostInView", SOURCE)
        self.assertIn("responder.nextResponder", SOURCE)
        self.assertIn("AMHomeUIFindBestHostInView(window", SOURCE)
        finder = SOURCE.split("static void AMHomeUIFindBestHost(", 1)[1].split(
            "static void AMHomeUIFindBestHostInView", 1
        )[0]
        attach = SOURCE.split("static BOOL AMHomeUIAttachToHost", 2)[2].split(
            "static AMHomeUIControllerKind AMHomeUIAttach(void)", 1
        )[0]
        self.assertIn("AMHomeUIHostViewForController(root, window)", finder)
        self.assertIn("hostView && kind > *bestKind", finder)
        self.assertIn("AMHomeUIEmbeddedHostView", attach)
        self.assertIn("!AMHomeUIIsMainController(controller)", attach)
        self.assertIn("[controller addChildViewController:AMHomeUIEmbeddedController]", attach)
        self.assertIn("AMHomeUIAttachEmbeddedView(", attach)
        self.assertIn("AMHomeUIClearEmbeddedAttachment();", attach)
        self.assertIn("syncTabSelectionVisibility", attach)
        embedded = SOURCE.split("static BOOL AMHomeUIAttachEmbeddedView", 1)[1].split(
            "static BOOL AMHomeUIAttachToHost", 1
        )[0]
        self.assertIn("[hostView addSubview:embeddedView]", embedded)
        self.assertIn("topBoundaryView.bottomAnchor", embedded)
        self.assertIn("bottomBoundaryView.topAnchor", embedded)
        self.assertIn("AMHomeUIEmbeddedConstraints", embedded)
        self.assertIn("AMHomeUIEmbeddedConstraintsAreActive()", embedded)
        layer_order = SOURCE.split(
            "static void AMHomeUIRefreshEmbeddedLayerOrder(void) {", 1
        )[1].split("static void AMHomeUIClearEmbeddedAttachment", 1)[0]
        self.assertIn("AMHomeUINativeContentAnchorView()", layer_order)
        self.assertIn(
            "[hostView insertSubview:embeddedView aboveSubview:nativeContentAnchor]",
            layer_order,
        )
        self.assertNotIn("[hostView bringSubviewToFront:embeddedView]", layer_order)
        self.assertNotIn("bringSubviewToFront:topChrome", layer_order)
        self.assertNotIn("bringSubviewToFront:bottomChrome", layer_order)
        attempt = SOURCE.split(
            "static void AMHomeUIAttachAttempt(NSUInteger attempt) {", 1
        )[1].split("static void AMHomeUIScheduleAttachAttempts", 1)[0]
        self.assertIn("AMHomeUIControllerKind attachedKind = AMHomeUIAttach();", attempt)
        self.assertIn("attachedKind == AMHomeUIControllerKindMain", attempt)
        self.assertIn("? 1.0 : (attempt < 60 ? 0.25 : 2.0)", attempt)
        self.assertIn("AMHomeUIAttachAttempt(attempt + 1)", attempt)
        self.assertIn("MainVC.mainView not ready", attempt)
        self.assertLess(
            attempt.index("AMHomeUIControllerKind attachedKind"),
            attempt.index("if (attempt == 60)"),
        )

    def test_non_main_fallback_is_never_left_visible(self):
        attempt = SOURCE.split(
            "static void AMHomeUIAttachAttempt(NSUInteger attempt) {", 1
        )[1].split("static void AMHomeUIScheduleAttachAttempts", 1)[0]
        self.assertIn("attachedKind == AMHomeUIControllerKindMain", attempt)
        self.assertIn("? 1.0 : (attempt < 60 ? 0.25 : 2.0)", attempt)
        self.assertNotIn("if (attachedKind != AMHomeUIControllerKindNone)", attempt)
        self.assertIn("AMHomeUIAttachAttempt(attempt + 1)", attempt)
        attach = SOURCE.split("static BOOL AMHomeUIAttachToHost", 2)[2].split(
            "static AMHomeUIControllerKind AMHomeUIAttach(void)", 1
        )[0]
        self.assertIn("AMHomeUIEmbeddedController.parentViewController != controller", attach)
        self.assertIn("BOOL hostChanged = needsNewController || oldHostView != hostView", attach)
        self.assertIn("!AMHomeUIIsMainController(controller)", attach)
        self.assertIn("if (!topBoundaryView || !bottomBoundaryView || !regionHost", attach)
        self.assertIn("AMHomeUIEmbeddedRegionHostView = regionHost", attach)
        self.assertNotIn("hostView = regionHost;", attach)
        self.assertGreaterEqual(attach.count("AMHomeUIClearEmbeddedAttachment();"), 3)
        choose_host = SOURCE.split(
            "static AMHomeUIControllerKind AMHomeUIAttach(void) {", 1
        )[1].split("static void AMHomeUIAttachAttempt", 1)[0]
        self.assertIn("if (bestKind != AMHomeUIControllerKindMain)", choose_host)
        self.assertIn("AMHomeUIClearEmbeddedAttachment();", choose_host)
        cleanup = SOURCE.split(
            "static void AMHomeUIClearEmbeddedAttachment(void) {", 1
        )[1].split("static BOOL AMHomeUIAttachEmbeddedView", 1)[0]
        self.assertIn("[controller observeTabController:nil]", cleanup)
        self.assertIn("deactivateConstraints:AMHomeUIEmbeddedConstraints", cleanup)
        self.assertIn("AMHomeUIEmbeddedRegionHostView = nil", cleanup)
        self.assertIn("[controller.viewIfLoaded removeFromSuperview]", cleanup)
        self.assertIn("[controller removeFromParentViewController]", cleanup)

    def test_native_home_rebuild_cannot_cover_the_embedded_web_view(self):
        anchor = SOURCE.split(
            "static UIView *AMHomeUINativeContentAnchorView(void) {", 1
        )[1].split("static void AMHomeUIRefreshEmbeddedLayerOrder", 1)[0]
        self.assertIn("AMHomeUISelectedBranchController(tabController)", anchor)
        self.assertIn("AMHomeUIDirectChildContainingView(hostView, selectedView)", anchor)
        self.assertIn("AMHomeUICollectNativeHomeMarkers", anchor)
        self.assertIn("if (subview == embeddedView) continue", anchor)

        layer_order = SOURCE.split(
            "static BOOL AMHomeUIEmbeddedLayerOrderNeedsRefresh(void) {", 1
        )[1].split("static void AMHomeUIClearEmbeddedAttachment", 1)[0]
        self.assertIn("embeddedIndex != nativeContentIndex + 1", layer_order)
        self.assertNotIn("nativeContentIndex > embeddedIndex", layer_order)
        self.assertNotIn("AMHomeUIEmbeddedTopBoundaryView", layer_order)
        self.assertNotIn("AMHomeUIEmbeddedBottomBoundaryView", layer_order)

    def test_home_visibility_tracks_embed_tab_selection(self):
        self.assertIn('AMHomeUIObjectPropertyForController(controller, @"embedTBC")', SOURCE)
        self.assertIn('[controller valueForKey:@"embedTBC"]', SOURCE)
        self.assertIn('AMHomeUIObjectIvarValue(controller, @"embedTBC")', SOURCE)
        self.assertIn('[tabController valueForKey:@"selectedIndex"]', SOURCE)
        self.assertIn("selectedIndex == 0", SOURCE)
        self.assertIn("AMHomeUISelectedBranchController", SOURCE)
        self.assertIn("AMHomeUINativeHomeVisible", SOURCE)
        self.assertNotIn("static NSInteger AMHomeUIDetectedHomeTabIndex", SOURCE)
        self.assertIn("detectedHomeTabController", SOURCE)
        self.assertIn("detectedHomeTabIndex = NSNotFound", SOURCE)
        self.assertIn("AMHomeUINativeHomeVisible(selectedBranch)", SOURCE)
        self.assertNotIn("AMHomeUINativeHomeVisible(controller)", SOURCE)
        self.assertNotIn("AMHomeUIDetectedHomeTabIndex = 0", SOURCE)
        self.assertIn("latest projects", SOURCE)
        self.assertIn("create new project", SOURCE)
        self.assertIn('addObserver:self\n                            forKeyPath:@"selectedIndex"', SOURCE)
        self.assertIn("AMHomeUITabSelectionContext", SOURCE)
        observation = SOURCE.split("- (void)observeTabController:", 1)[1].split(
            "- (void)observeValueForKeyPath", 1
        )[0]
        self.assertIn("self.detectedHomeTabController = tabController", observation)
        self.assertIn("self.detectedHomeTabIndex = NSNotFound", observation)
        selection = SOURCE.split("static BOOL AMHomeUIIsHomeTabSelected", 2)[2].split(
            "static id AMHomeUIAccountControlForController", 1
        )[0]
        self.assertIn("AMHomeUISelectedBranchController(tabController)", selection)
        self.assertIn("return known && selectedIndex == 0", selection)
        visibility = SOURCE.split("- (void)syncTabSelectionVisibility {", 1)[1].split(
            "- (void)updateAvatar", 1
        )[0]
        self.assertIn("AMHomeUIIsMainController(host)", visibility)
        self.assertIn("AMHomeUIIsHomeTabSelected(", visibility)
        self.assertIn("AMHomeUIEmbeddedConstraintsAreActive()", visibility)
        self.assertIn("embeddedView.hidden = !shouldShow", visibility)
        self.assertIn("AMHomeUIRefreshEmbeddedLayerOrder()", visibility)
        self.assertIn("AMHomeUIEmbeddedLayerOrderNeedsRefresh()", visibility)
        self.assertNotIn("self.view.hidden = NO", SOURCE)

    def test_inactive_middle_region_constraints_are_rebuilt(self):
        active_check = SOURCE.split(
            "static BOOL AMHomeUIEmbeddedConstraintsAreActive(void) {", 1
        )[1].split("static UIView *AMHomeUIDirectChildContainingView", 1)[0]
        self.assertIn("AMHomeUIEmbeddedConstraints.count != 4", active_check)
        self.assertIn("if (!constraint.active) return NO", active_check)

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
        self.assertIn("? 1.0 : (attempt < 60 ? 0.25 : 2.0)", attempt)
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
        self.assertIn('@"_TtC12AlightMotion6MainVC"', SOURCE)
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
        self.assertIn("uniqueButtons.count == 1", SOURCE)
        self.assertIn("UIView *mainView = mainController.viewIfLoaded", SOURCE)
        self.assertIn("[controller valueForKey:key]", SOURCE)
        self.assertIn("AMHomeUIScheduleAvatarRefreshes", SOURCE)
        self.assertIn("AMHomeUIFindBestHost(root, window", SOURCE)
        self.assertIn("avatarHost = bestController ?: AMHomeUIFindMainController", SOURCE)
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

    def test_avatar_prefers_account_metadata_then_unique_main_button(self):
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
        self.assertIn("uniqueButtons.count == 1", native_avatar)
        self.assertIn("UIView *mainView = mainController.viewIfLoaded", native_avatar)
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
        self.assertIn('assert "@rpath/AMHomeUI.dylib" in cloud_dependencies', WORKFLOW)
        self.assertIn('assert "_AMHomeUIInstall" not in cloud_defined_symbols', WORKFLOW)
        self.assertIn('assert "_AMHomeUIInstall" in cloud_symbols', WORKFLOW)
        self.assertIn('section["type"] in (0x9, 0x16)', WORKFLOW)
        self.assertIn('home_ui["external_defined_symbols"]', WORKFLOW)


if __name__ == "__main__":
    unittest.main()
