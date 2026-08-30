import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLOUD = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")
HEADER = (ROOT / "AMProjExport" / "AMCloudSync.h").read_text(encoding="utf-8")
EXPORT = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
DEBUG_HEADER = (ROOT / "AMProjExport" / "AMDebugTransport.h").read_text(
    encoding="utf-8"
)
DEBUG_SOURCE = (ROOT / "AMProjExport" / "AMDebugTransport.m").read_text(
    encoding="utf-8"
)
PLUGINS = (ROOT / "AMProjExport" / "AMCloudPlugins.m").read_text(
    encoding="utf-8"
)
PLUGIN_HEADER = (ROOT / "AMProjExport" / "AMCloudPlugins.h").read_text(
    encoding="utf-8"
)
EDITOR = (ROOT / "AMProjExport" / "AMEditorCustomization.m").read_text(
    encoding="utf-8"
)
IMPORT_ARCHIVE = (ROOT / "AMProjExport" / "AMProjImportArchive.m").read_text(
    encoding="utf-8"
)


class MirroredQuickActionsModel:
    @staticmethod
    def matches(root_size, add_frame, candidate_frame, safe_bottom=34):
        root_width, root_height = root_size
        add_x, add_y, add_width, add_height = add_frame
        candidate_x, candidate_y, candidate_width, candidate_height = candidate_frame
        add_mid_x = add_x + add_width / 2
        add_mid_y = add_y + add_height / 2
        candidate_mid_x = candidate_x + candidate_width / 2
        candidate_mid_y = candidate_y + candidate_height / 2
        root_mid_x = root_width / 2
        bottom_edge_y = root_height - max(0, safe_bottom)
        maximum_bottom_distance = max(44, min(72, add_height * 1.25))
        if (
            root_width <= 0
            or root_height <= 0
            or add_width <= 0
            or add_height <= 0
            or add_mid_x <= root_mid_x + max(24, add_width * 0.5)
            or abs(bottom_edge_y - (add_y + add_height))
            > maximum_bottom_distance
        ):
            return False
        expected_x = root_width - add_mid_x
        horizontal_tolerance = max(8, min(16, add_width * 0.22))
        vertical_tolerance = max(6, min(14, add_height * 0.18))
        width_tolerance = max(5, add_width * 0.12)
        height_tolerance = max(5, add_height * 0.12)
        return (
            candidate_mid_x < root_mid_x - max(24, add_width * 0.5)
            and abs(bottom_edge_y - (candidate_y + candidate_height))
            <= maximum_bottom_distance
            and abs(candidate_mid_x - expected_x) <= horizontal_tolerance
            and abs(candidate_mid_y - add_mid_y) <= vertical_tolerance
            and abs(candidate_width - add_width) <= width_tolerance
            and abs(candidate_height - add_height) <= height_tolerance
        )


class CloudSyncSourceTests(unittest.TestCase):
    def test_cloud_build_is_isolated_from_release_and_debug_targets(self):
        cloud_rule = MAKEFILE.split("AMProjExport.dylib:", 1)[1].split(
            "AMProjExportOffline.dylib:", 1
        )[0]
        self.assertIn("-DAMPROJ_CLOUD_SYNC=1", cloud_rule)
        self.assertIn("AMCloudSync.m", cloud_rule)
        self.assertIn("AMCloudPlugins.m", cloud_rule)
        self.assertIn("AMEditorCustomization.m", cloud_rule)
        self.assertIn("-framework Security", cloud_rule)
        self.assertIn("-framework WebKit", cloud_rule)
        self.assertIn("-install_name @rpath/AMProjExport.dylib", cloud_rule)
        self.assertNotIn("AMProjExportCloud.dylib", MAKEFILE)
        self.assertIn("#if AMPROJ_CLOUD_SYNC", EXPORT)

    def test_editor_buttons_are_customized_only_on_project_edit_controller(self):
        self.assertIn('@"AlightMotion.ProjectEditVC"', EDITOR)
        self.assertIn('objc_getClass("_TtC12AlightMotion13ProjectEditVC")', EDITOR)
        self.assertIn('@"quickActionsButton"', EDITOR)
        self.assertIn("AMEditorFindMirroredQuickActionsControl", EDITOR)
        self.assertIn("AMEditorCollectControls", EDITOR)
        self.assertIn("bottomEdgeY", EDITOR)
        self.assertIn("rootView.safeAreaInsets.bottom", EDITOR)
        self.assertIn("maximumBottomDistance", EDITOR)
        self.assertIn("fabs(dx) > horizontalTolerance", EDITOR)
        self.assertIn("fabs(dy) > verticalTolerance", EDITOR)
        self.assertIn("widthDelta > widthTolerance", EDITOR)
        self.assertIn("heightDelta > heightTolerance", EDITOR)
        self.assertIn("AMEditorHideView(quickActionsView)", EDITOR)
        self.assertIn("view.hidden = YES", EDITOR)
        self.assertIn("view.userInteractionEnabled = NO", EDITOR)
        self.assertNotIn("AMEditorMirroredQuickActionsButton", EDITOR)
        self.assertIn('@"addLibraryButton"', EDITOR)
        self.assertIn('@"autfeng_add_layer_button"', EDITOR)
        self.assertIn("UIImageRenderingModeAlwaysOriginal", EDITOR)
        self.assertIn("configuration.image = image", EDITOR)
        self.assertIn("@selector(viewDidLayoutSubviews)", EDITOR)
        self.assertNotIn("class_getInstanceMethod(UIButton.class", EDITOR)
        self.assertIn("AMEditorCustomizationInstall();", CLOUD)

    def test_mirrored_quick_actions_requires_close_position_and_matching_size(self):
        root = (390, 844)
        add = (326, 760, 48, 48)
        self.assertTrue(
            MirroredQuickActionsModel.matches(root, add, (16, 760, 48, 48))
        )
        self.assertFalse(
            MirroredQuickActionsModel.matches(root, add, (70, 760, 48, 48))
        )
        self.assertFalse(
            MirroredQuickActionsModel.matches(root, add, (16, 760, 84, 48))
        )
        self.assertFalse(
            MirroredQuickActionsModel.matches(root, add, (16, 500, 48, 48))
        )
        self.assertFalse(
            MirroredQuickActionsModel.matches(
                root,
                (326, 526, 48, 48),
                (16, 526, 48, 48),
            )
        )

    def test_other_effect_category_uses_its_dedicated_background(self):
        self.assertIn('@"AlightMotion.EffectBrowser"', EDITOR)
        self.assertIn('objc_getClass("_TtC12AlightMotion13EffectBrowser")', EDITOR)
        self.assertIn('@"AlightMotion.CategoryCell"', EDITOR)
        self.assertIn('objc_getClass("_TtC12AlightMotion12CategoryCell")', EDITOR)
        self.assertIn('@"AlightMotion.EffectPickerMainCell"', EDITOR)
        self.assertIn(
            'objc_getClass("_TtC12AlightMotion20EffectPickerMainCell")',
            EDITOR,
        )
        self.assertIn('@selector(collectionView:cellForItemAtIndexPath:)', EDITOR)
        self.assertIn('@selector(layoutSubviews)', EDITOR)
        self.assertIn("AMEditorOriginalCategoryCellLayout", EDITOR)
        self.assertIn("AMEditorCategoryCellLayout", EDITOR)
        self.assertIn("AMEditorInstallCategoryCellCustomization", EDITOR)
        self.assertIn(
            "AMEditorInstallCategoryCellCustomization();",
            EDITOR,
        )
        self.assertIn("AMEditorOriginalEffectPickerMainCellLayout", EDITOR)
        self.assertIn("AMEditorEffectPickerMainCellLayout", EDITOR)
        self.assertIn("AMEditorInstallEffectPickerMainCellCustomization", EDITOR)
        self.assertIn(
            "AMEditorInstallEffectPickerMainCellCustomization();",
            EDITOR,
        )
        self.assertIn('@"fxcat_other"', EDITOR)
        self.assertIn('@"ic_category_thumbnail_other"', EDITOR)
        self.assertIn('@"BuiltinCategory/thumb"', EDITOR)
        self.assertIn("AMEditorCollectLabels", EDITOR)
        self.assertIn("AMEditorCategoryBackgroundImageView", EDITOR)
        self.assertIn("AMEditorCategoryCellLabel", EDITOR)
        self.assertIn('AMEditorViewForKey(cell, @"label")', EDITOR)
        self.assertIn('AMEditorViewForKey(cell, @"titleLabel")', EDITOR)
        self.assertIn("AMEditorViewContainsOtherAccessibilityTitle", EDITOR)
        self.assertIn('AMEditorViewForKey(cell, @"thumbnailImageView")', EDITOR)
        self.assertIn("[target addSubview:imageView]", EDITOR)
        self.assertIn("[cell.contentView insertSubview:imageView atIndex:0]", EDITOR)
        self.assertIn("installedView.frame = installedView.superview.bounds", EDITOR)
        self.assertIn("UIViewContentModeScaleAspectFill", EDITOR)
        self.assertNotIn("indexPath.item == 11", EDITOR)
        self.assertNotIn("indexPath.item == itemCount - 1", EDITOR)
        self.assertNotIn("numberOfItemsInSection", EDITOR)

    def test_effect_addition_requires_login_without_gating_existing_rendering(self):
        self.assertIn("AMCloudSyncHasLoggedInAccount", HEADER)
        self.assertIn("AMCloudSyncShowAccountLoginFrom", HEADER)
        status = CLOUD.split("BOOL AMCloudSyncHasLoggedInAccount", 1)[1].split(
            "void AMCloudSyncShowAccountLoginFrom", 1
        )[0]
        self.assertIn("AMCloudReadToken().length > 0", status)
        self.assertNotIn("authorizeFeature", status)
        login_route = CLOUD.split("void AMCloudSyncShowAccountLoginFrom", 1)[1].split(
            "void AMCloudAuthorizeFeature", 1
        )[0]
        self.assertIn("dispatch_get_main_queue()", login_route)
        self.assertIn("showAccountFrom:top", login_route)
        self.assertNotIn("showAuthenticationFrom", login_route)

        self.assertIn('#import "AMCloudSync.h"', EDITOR)
        for class_name, mangled_name in (
            (
                '@"AlightMotion.EffectGroupController"',
                '"_TtC12AlightMotion21EffectGroupController"',
            ),
            (
                '@"AlightMotion.EffectPickerPanelContentVC"',
                '"_TtC12AlightMotion26EffectPickerPanelContentVC"',
            ),
            (
                '@"AlightMotion.EffectPickerPersistCollectionView"',
                '"_TtC12AlightMotion33EffectPickerPersistCollectionView"',
            ),
            (
                '@"AlightMotion.EffectPickerCategoryVC"',
                '"_TtC12AlightMotion22EffectPickerCategoryVC"',
            ),
            (
                '@"AlightMotion.EffectPickerRecommendCollectionView"',
                '"_TtC12AlightMotion35EffectPickerRecommendCollectionView"',
            ),
            (
                '@"AlightMotion.EffectPickerSearchVC"',
                '"_TtC12AlightMotion20EffectPickerSearchVC"',
            ),
        ):
            self.assertIn(class_name, EDITOR)
            self.assertIn(mangled_name, EDITOR)

        gate = EDITOR.split("static BOOL AMEditorAllowEffectSelection", 1)[1].split(
            "static void AMEditorEffectGroupSelection", 1
        )[0]
        self.assertIn("AMCloudSyncHasLoggedInAccount()", gate)
        self.assertIn("AMEditorDeselectEffectItem", gate)
        self.assertIn("AMCloudSyncShowAccountLoginFrom", gate)
        self.assertIn('alertControllerWithTitle:@"请先登录"', gate)
        self.assertNotIn("AMCloudAuthorizeFeature", gate)

        wrappers = (
            ("AMEditorEffectGroupSelection", "AMEditorOriginalEffectGroupSelection"),
            (
                "AMEditorEffectPanelPresetSelection",
                "AMEditorOriginalEffectPanelPresetSelection",
            ),
            (
                "AMEditorEffectPersistSelection",
                "AMEditorOriginalEffectPersistSelection",
            ),
            (
                "AMEditorEffectCategorySelection",
                "AMEditorOriginalEffectCategorySelection",
            ),
            (
                "AMEditorEffectRecommendSelection",
                "AMEditorOriginalEffectRecommendSelection",
            ),
            (
                "AMEditorEffectSearchSelection",
                "AMEditorOriginalEffectSearchSelection",
            ),
        )
        for index, (wrapper_name, original_name) in enumerate(wrappers):
            start = EDITOR.index(f"static void {wrapper_name}")
            if index + 1 < len(wrappers):
                end = EDITOR.index(f"static void {wrappers[index + 1][0]}", start)
            else:
                end = EDITOR.index("static UIView *AMEditorViewForKey", start)
            wrapper = EDITOR[start:end]
            self.assertIn("if (!AMEditorAllowEffectSelection", wrapper)
            self.assertIn("return;", wrapper)
            if wrapper_name != "AMEditorEffectSearchSelection":
                self.assertLess(
                    wrapper.index("AMEditorAllowEffectSelection"),
                    wrapper.index(original_name),
                )

        search_start = EDITOR.index("static void AMEditorEffectSearchSelection")
        search_end = EDITOR.index("static UIView *AMEditorViewForKey", search_start)
        search_wrapper = EDITOR[search_start:search_end]
        self.assertIn('@"resultCollectionView"', search_wrapper)
        self.assertIn("collectionView != resultCollectionView", search_wrapper)
        self.assertLess(
            search_wrapper.index("collectionView != resultCollectionView"),
            search_wrapper.index("AMEditorAllowEffectSelection"),
        )
        self.assertGreaterEqual(
            search_wrapper.count("AMEditorOriginalEffectSearchSelection"), 4
        )
        self.assertGreater(
            search_wrapper.rindex("AMEditorOriginalEffectSearchSelection"),
            search_wrapper.index("AMEditorAllowEffectSelection"),
        )

        self.assertIn("AMEditorInstallEffectGroupLoginGate();", EDITOR)
        self.assertIn("AMEditorInstallEffectPanelPresetLoginGate();", EDITOR)
        self.assertIn("AMEditorInstallEffectPersistLoginGate();", EDITOR)
        self.assertIn("AMEditorInstallEffectCategoryLoginGate();", EDITOR)
        self.assertIn("AMEditorInstallEffectRecommendLoginGate();", EDITOR)
        self.assertIn("AMEditorInstallEffectSearchLoginGate();", EDITOR)
        self.assertNotIn("AMEditorInstallEffectBrowserLoginGate", EDITOR)
        self.assertNotIn("AMEditorEffectRender", EDITOR)

    def test_token_is_stored_only_in_keychain(self):
        self.assertIn("SecItemCopyMatching", CLOUD)
        self.assertIn("SecItemUpdate", CLOUD)
        self.assertIn("SecItemAdd", CLOUD)
        self.assertIn("SecItemDelete", CLOUD)
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", CLOUD)
        self.assertNotIn("NSUserDefaults", CLOUD)

    def test_auth_and_cloud_routes_match_server_contract(self):
        for route in (
            "/auth/login",
            "/auth/register",
            "/auth/logout",
            "/ios/session/activate",
            "/ios/authorize",
            "/ios/plugins/manifest",
            "/ios/plugins/releases/",
            "/user/me",
            "/cloud/projects",
            "/upload",
            "/download",
            "/versions",
            "/restore",
        ):
            self.assertIn(route, CLOUD)
        self.assertIn('[@"Bearer " stringByAppendingString:token]', CLOUD)
        self.assertIn('forHTTPHeaderField:@"Authorization"', CLOUD)
        self.assertIn('json[@"code"]', CLOUD)
        self.assertIn('json[@"data"]', CLOUD)

    def test_plugin_network_methods_belong_to_cloud_client(self):
        client = CLOUD.split("@implementation AMCloudClient", 1)[1].split("\n@end", 1)[0]
        webview = CLOUD.split("@implementation AMCloudAccountWebViewController", 1)[1]
        webview = webview.split("\n@end", 1)[0]
        for method in ("loadPluginManifest:", "downloadPluginRelease:"):
            self.assertIn(method, client)
            self.assertNotIn(method, webview)
        self.assertIn("[self performMethod:", client)
        self.assertIn("self.session", client)

    def test_cloud_plugins_are_downloaded_installed_and_removed_automatically(self):
        for symbol in (
            "AMCloudPluginsInstallBundleHooks",
            "AMCloudPluginsRestoreInstalledReleaseForAuthorization",
            "AMCloudPluginsCurrentState",
            "AMCloudPluginsInstallArchive",
            "AMCloudPluginsRemoveAllIf",
            "AMCloudPluginsRemoveAll",
        ):
            self.assertIn(symbol, PLUGIN_HEADER)
            self.assertIn(symbol, PLUGINS)
        for trigger in (
            '@"install"',
            '@"did_become_active"',
            '@"foreground_timer"',
            '@"token_changed"',
            '@"account_activation"',
        ):
            self.assertIn(trigger, CLOUD)
        self.assertIn("scheduledTimerWithTimeInterval:60.0", CLOUD)
        self.assertIn("downloadPluginRelease", CLOUD)
        self.assertIn("AMCloudPluginsActivateInstalledRelease", CLOUD)
        self.assertIn('valueForHTTPHeaderField:@"X-AM-Plugin-SHA256"', CLOUD)
        self.assertIn("AMCloudPluginsRemoveAllIf", CLOUD)
        self.assertIn("permission_disabled", CLOUD)
        self.assertNotIn("plugin picker", CLOUD.lower())

    def test_plugin_sync_activates_ios_session_before_manifest(self):
        sync = CLOUD.rsplit("- (void)syncPluginsNow:", 1)[1].split(
            "- (void)syncPluginCatalog:", 1
        )[0]
        self.assertIn("pluginIOSSessionToken", CLOUD)
        self.assertIn("pluginIOSSessionActivationInFlight", CLOUD)
        self.assertIn("pluginIOSSessionActivationOperationID", CLOUD)
        self.assertIn("activateIOSSessionThenSyncPlugins:reason", sync)
        self.assertLess(
            sync.index("activateIOSSessionThenSyncPlugins:reason"),
            sync.index("self.pluginSyncInFlight = YES"),
        )
        activation = CLOUD.rsplit(
            "- (void)activateIOSSessionThenSyncPlugins:", 1
        )[1].split("- (void)downloadPluginCatalogItems:", 1)[0]
        self.assertIn("[self.client activateIOSSession", activation)
        self.assertIn("NSString *operationID = NSUUID.UUID.UUIDString", activation)
        self.assertIn(
            "if (![self.pluginIOSSessionActivationOperationID isEqualToString:operationID]) return;",
            activation,
        )
        self.assertIn("self.pluginIOSSessionActivationOperationID = operationID", activation)
        self.assertIn("self.pluginIOSSessionActivationOperationID = nil", activation)
        self.assertIn("self.pluginIOSSessionToken = token", activation)
        self.assertIn("[self syncPluginsNow:@\"session_activation\"]", activation)
        self.assertIn("cloud.plugins.session_activation_failed", activation)
        self.assertIn("self.pluginIOSSessionToken = nil", CLOUD)
        self.assertNotIn("self.pluginSyncPending = YES", activation)

    def test_cloud_plugins_support_per_item_incremental_delivery(self):
        for symbol in (
            "AMCloudPluginsInstallItemArchive",
            "AMCloudPluginsInstallItemArchiveWithMetadata",
            "AMCloudPluginsActivateCatalog",
        ):
            self.assertIn(symbol, PLUGIN_HEADER)
            self.assertIn(symbol, PLUGINS)
        self.assertIn("downloadPluginItem:", CLOUD)
        self.assertIn("syncPluginCatalog:", CLOUD)
        self.assertIn('manifest[@"protocolVersion"]', CLOUD)
        self.assertIn('manifest[@"catalogRevision"]', CLOUD)
        self.assertIn('manifest[@"plugins"]', CLOUD)
        self.assertIn('@"/ios/plugins/items/%@/versions/%@/download"', CLOUD)
        self.assertIn('AMCloudPluginsCatalogProtocolVersion = 8', PLUGINS)
        self.assertIn('@"protocol_version": @(AMCloudPluginsCatalogProtocolVersion)', PLUGINS)
        self.assertIn('AMCloudPluginsCatalogProtocolVersion', PLUGIN_HEADER)
        self.assertIn('@"catalog_revision"', PLUGINS)
        self.assertIn('@"plugins": statePlugins', PLUGINS)
        self.assertIn("AMCloudPluginsCopyCatalogDirectory", PLUGINS)
        self.assertIn("AMCloudPluginsCopyCatalogDirectorySkippingPaths", PLUGINS)
        self.assertIn("AMCloudPluginsValidateCatalogItemFiles", PLUGINS)
        self.assertIn("Cloud plugin items contain conflicting resource paths", PLUGINS)
        self.assertIn("Builtin override may contain only its target XML", PLUGINS)
        self.assertIn("legacy_path_override", PLUGINS)
        self.assertIn("AMCloudPluginsItemAllowsLegacyPathOverride", PLUGINS)
        self.assertIn("AMCloudPluginsLegacyXMLCanOverrideBundledOfficial", PLUGINS)
        self.assertIn("AMCloudPluginsIsLegacyCustomEffectID", PLUGINS)
        self.assertIn("AMCloudPluginsIsOfficialEffectID", PLUGINS)
        self.assertIn("Legacy plugin target XML effect id does not match metadata", PLUGINS)
        self.assertIn("isLegacyImageReplacement", PLUGINS)
        self.assertIn("isBuiltinImageReplacement", PLUGINS)
        self.assertIn("targetReferences containsObject", PLUGINS)
        self.assertIn("targetReferencedEffectIDs", PLUGINS)
        self.assertIn("AMCloudPluginsReferencedEffectIDsForXMLURL", PLUGINS)
        self.assertIn("AMCloudPluginsParseEffectData", PLUGINS)
        self.assertIn("narrow root-tag fallback", PLUGINS)
        self.assertIn("AMCloudPluginsIsLegacyCustomEffectID(sourceID)", PLUGINS)
        self.assertIn("resourceOwners[relativeKey]", PLUGINS)
        self.assertIn("sourceData isEqualToData:bundledData", PLUGINS)
        self.assertIn("AMCloudPluginsValidateLegacyCustomOverride", PLUGINS)
        self.assertIn("Conflicting cloud plugin targetPath or effectId", PLUGINS)
        self.assertIn("bundledEffectsURL, NSError **error", PLUGINS)
        self.assertIn("sourceID caseInsensitiveCompare:bundledID", PLUGINS)
        self.assertIn("isLegacyOfficialDependency", PLUGINS)
        self.assertIn("legacyPathOverride", CLOUD)
        activation = PLUGINS.split(
            "NSMutableArray *statePlugins", 1
        )[1].split("NSObject *commitLock", 1)[0]
        self.assertLess(
            activation.index("AMCloudPluginsValidateCatalogItemFiles"),
            activation.index("AMCloudPluginsCopyCatalogDirectorySkippingPaths"),
        )
        self.assertIn("AMCloudPluginsBundledEffectsURL", PLUGINS)
        self.assertIn("replaceExisting", PLUGINS)
        self.assertIn("Plugin dependency conflict", PLUGINS)
        self.assertIn("installed.count == plugins.count", CLOUD)

    def test_catalog_deduplicates_root_effect_ids_and_drops_legacy_releases(self):
        self.assertIn("AMCloudPluginsDedupeCatalogRootEffects", PLUGINS)
        self.assertIn("builtinOverridePaths", PLUGINS)
        self.assertIn("isBuiltinOverride", PLUGINS)
        self.assertIn("com.autfeng ID is a separate custom plugin", PLUGINS)
        self.assertIn("Official ids must stay at their IPA filename", PLUGINS)
        self.assertIn("A repaired official", PLUGINS)
        self.assertNotIn("AMCloudPluginsOfficialNamespaceAliasID", PLUGINS)
        self.assertNotIn("namespace-renamed copy of an IPA built-in", PLUGINS)
        self.assertIn("multiple primary XML files for effect id", PLUGINS)
        activation = PLUGINS.split(
            "NSMutableArray *statePlugins", 1
        )[1].split("NSObject *commitLock", 1)[0]
        self.assertIn("AMCloudPluginsDedupeCatalogRootEffects", activation)
        self.assertIn('URLByAppendingPathComponent:@"releases"', PLUGINS)
        self.assertIn("AMCloudPluginsCatalogProtocolVersion = 8", PLUGINS)
        legacy_restore = PLUGINS.split(
            "BOOL AMCloudPluginsRestoreInstalledReleaseForAuthorization", 1
        )[1]
        self.assertIn("Legacy full-release state predates the per-effect catalog", legacy_restore)
        self.assertIn('URLByAppendingPathComponent:@"releases"', legacy_restore)
        legacy_install = PLUGINS.split(
            "BOOL AMCloudPluginsInstallArchive", 1
        )[1].split("BOOL AMCloudPluginsRemoveAllIf", 1)[0]
        self.assertIn("AMCloudPluginsDedupeCatalogRootEffects", legacy_install)

    def test_client_skips_only_explicit_official_alias_manifest_items(self):
        self.assertIn("AMCloudManifestItemIsOfficialAlias", CLOUD)
        helper = CLOUD.split("static BOOL AMCloudManifestItemIsOfficialAlias", 1)[1]
        helper = helper.split("static NSError *AMCloudError", 1)[0]
        self.assertIn('[@"kind"]', helper)
        self.assertIn('[@"type"]', helper)
        self.assertIn('[@"officialAlias"]', helper)
        self.assertIn('[@"official_alias"]', helper)
        self.assertIn('@"custom_plugin"', helper)
        sync = CLOUD.rsplit("- (void)syncPluginCatalog:", 1)[1].split(
            "NSDictionary *state", 1
        )[0]
        self.assertIn("visiblePlugins", sync)
        self.assertIn("AMCloudManifestItemIsOfficialAlias", sync)
        self.assertIn("plugins = visiblePlugins", sync)
        self.assertNotIn("hasPrefix:@\"com.autfeng.\"", helper)

    def test_catalog_failure_clears_legacy_release_state(self):
        self.assertIn("cloud.plugins.legacy_release_cleared", CLOUD)
        failure = CLOUD.split("if (!activated) {", 1)[1].split(
            "NSDictionary *newState", 1
        )[0]
        self.assertIn('failedState[@"release_id"]', failure)
        self.assertIn("AMCloudPluginsRemoveAllIf", failure)
        self.assertIn("catalog_activation_failed", failure)

    def test_custom_plugins_cannot_claim_a_bundled_official_effect_path(self):
        self.assertIn(
            "AMCloudPluginsCustomPluginTargetsBundledEffect", PLUGINS
        )
        helper = PLUGINS.split(
            "static BOOL AMCloudPluginsCustomPluginTargetsBundledEffect", 1
        )[1].split("static BOOL AMCloudPluginsValidateBuiltinOverride", 1)[0]
        self.assertIn('isEqualToString:@"custom_plugin"', helper)
        self.assertIn("AMCloudPluginsBuiltinTargetURL", helper)
        self.assertIn("AMCloudPluginsBundledEffectsURL", helper)
        self.assertIn("AMCloudPluginsEffectIDForXMLURL", helper)
        self.assertIn("AMCloudPluginsIsOfficialEffectID(bundledID)", helper)

        catalog_entry = PLUGINS.split(
            "static BOOL AMCloudPluginsCatalogEntryIsSafe", 1
        )[1].split("static NSURL *AMCloudPluginsBuiltinTargetURL", 1)[0]
        self.assertIn(
            "AMCloudPluginsCustomPluginTargetsBundledEffect(plugin)) return NO;",
            catalog_entry,
        )

        identity = PLUGINS.split(
            "static BOOL AMCloudPluginsValidateCatalogIdentity", 1
        )[1].split("static void AMCloudPluginsSetActiveState", 1)[0]
        self.assertIn("AMCloudPluginsCustomPluginTargetsBundledEffect", identity)
        self.assertIn("cannot reuse an IPA built-in effect id", identity)
        self.assertIn(
            "Custom plugins may not replace a bundled official effect", identity
        )

        installer = PLUGINS.split(
            "BOOL AMCloudPluginsInstallItemArchiveWithMetadata", 1
        )[1].split("static NSURL *AMCloudPluginsBundledEffectsURL", 1)[0]
        self.assertIn("AMCloudPluginsCustomPluginTargetsBundledEffect", installer)
        self.assertIn("return NO;", installer)

    def test_custom_plugin_identity_is_checked_before_item_commit_and_catalog_copy(self):
        self.assertIn("AMCloudPluginsValidateCustomPluginIdentity", PLUGINS)
        self.assertIn("Custom plugin XML effect id does not match metadata", PLUGINS)
        self.assertIn("Custom plugin cannot use an IPA official effect id", PLUGINS)
        installer = PLUGINS.split(
            "BOOL AMCloudPluginsInstallItemArchiveWithMetadata", 1
        )[1].split("static NSURL *AMCloudPluginsBundledEffectsURL", 1)[0]
        self.assertLess(
            installer.index("AMCloudPluginsValidateCustomPluginIdentity"),
            installer.index("moveItemAtURL:stagingURL toURL:finalURL"),
        )
        validator = PLUGINS.split(
            "static BOOL AMCloudPluginsValidateCatalogItemFiles", 1
        )[1].split("BOOL AMCloudPluginsActivateCatalog", 1)[0]
        self.assertIn("AMCloudPluginsValidateCustomPluginIdentity", validator)

    def test_legacy_full_release_validates_official_ids_at_original_paths(self):
        self.assertIn("AMCloudPluginsValidateLegacyReleaseEffects", PLUGINS)
        self.assertIn("Legacy release official XML id does not match the IPA baseline", PLUGINS)
        self.assertIn("Legacy release cannot relocate an IPA official effect id", PLUGINS)
        restore = PLUGINS.split(
            "static BOOL AMCloudPluginsActivatePersistedState", 1
        )[1].split("static BOOL AMCloudPluginsActivatePersistedCatalog", 1)[0]
        self.assertIn("AMCloudPluginsValidateLegacyReleaseEffects", restore)
        install = PLUGINS.split(
            "BOOL AMCloudPluginsInstallArchive", 1
        )[1].split("BOOL AMCloudPluginsRemoveAllIf", 1)[0]
        self.assertIn("AMCloudPluginsValidateLegacyReleaseEffects", install)

    def test_catalog_identity_errors_include_item_context(self):
        self.assertIn("AMCloudPluginsValidationErrorForItem", PLUGINS)
        self.assertIn('plugin=%@', PLUGINS)
        self.assertIn('name=%@', PLUGINS)
        self.assertIn('version=%@', PLUGINS)
        self.assertIn('effectId=%@', PLUGINS)
        self.assertIn('targetPath=%@', PLUGINS)
        self.assertIn('sourceId=%@', PLUGINS)
        self.assertIn('source=%@', PLUGINS)
        self.assertIn(
            "Legacy plugin override XML effect id does not match metadata (sourceId=%@)",
            PLUGINS,
        )

    def test_builtin_override_repairs_ios_compatibility_from_ipa_baseline(self):
        self.assertIn("rootAttributes", PLUGINS)
        self.assertIn("AMCloudPluginsRootAttributeForXMLURL", PLUGINS)
        self.assertIn("AMCloudPluginsEnsureRootAttribute", PLUGINS)
        self.assertIn("AMCloudPluginsRepairBuiltinCompatibility", PLUGINS)
        self.assertIn('@"compat"', PLUGINS)
        self.assertIn('@"maxoverdraw"', PLUGINS)
        self.assertIn('@"max-overdraw"', PLUGINS)
        self.assertIn("Builtin override compat does not match the IPA baseline", PLUGINS)
        self.assertIn("AMCloudPluginsRepairBuiltinCompatibility(cloudURL, bundledURL, error)", PLUGINS)
        self.assertIn("AMCloudPluginsRepairBuiltinCompatibility(sourceURL, bundledURL, error)", PLUGINS)
        validation = PLUGINS.split(
            "static BOOL AMCloudPluginsValidateBuiltinOverride(", 1
        )[1].split("static BOOL AMCloudPluginsValidateLegacyCustomOverride(", 1)[0]
        self.assertLess(
            validation.index("AMCloudPluginsRepairBuiltinCompatibility"),
            validation.index("AMCloudPluginsEffectIDForXMLURL(cloudURL"),
        )

    def test_catalog_activation_repairs_stale_cached_items_once(self):
        self.assertIn("pluginCatalogRepairAttempted", CLOUD)
        self.assertIn("AMCloudCatalogActivationErrorMayBeStaleCache", CLOUD)
        self.assertIn("cloud.plugins.catalog_repair_begin", CLOUD)
        self.assertIn("cloud.plugins.catalog_repair_retry", CLOUD)
        self.assertIn("cloud.plugins.catalog_repair_failed", CLOUD)
        self.assertIn("AMCloudPluginsRemoveAllIf", CLOUD)
        self.assertIn("self.pluginCatalogRepairAttempted = YES", CLOUD)
        self.assertIn("[self syncPluginCatalog:plugins revision:revision", CLOUD)
        repair = CLOUD.split(
            "if (!activated && !self.pluginCatalogRepairAttempted", 1
        )[1].split("NSDictionary *newState", 1)[0]
        self.assertIn("AMCloudAuthMatches(token, authorizationGeneration)", repair)
        self.assertIn("if (cleared)", repair)

    def test_persisted_catalog_is_invalidated_when_ipa_builtin_effects_change(self):
        self.assertIn("AMCloudPluginsBundledEffectsFingerprint", PLUGINS)
        self.assertIn('bundled_effects_fingerprint', PLUGINS)
        self.assertIn('The IPA was replaced while the app data survived', PLUGINS)
        self.assertIn("AMCloudPluginsInvalidateStaleCatalog", PLUGINS)
        self.assertIn("AMCloudPluginsInvalidatePersistedState(manager)", PLUGINS)
        self.assertIn("removeItemAtURL:catalogURL", PLUGINS)
        restore = PLUGINS.split(
            "static BOOL AMCloudPluginsActivatePersistedCatalog", 1
        )[1].split("BOOL AMCloudPluginsRestoreInstalledReleaseForAuthorization", 1)[0]
        self.assertIn("storedFingerprint", restore)
        self.assertIn("currentFingerprint", restore)
        self.assertIn("AMCloudPluginsSetActiveState(nil, nil, 0)", restore)
        self.assertIn("AMCloudPluginsInvalidateStaleCatalog(manager)", restore)
        self.assertIn("AMCloudPluginsCatalogContainsBundledEffects", PLUGINS)
        self.assertIn("Older catalogs could contain only cloud-delivered files", PLUGINS)
        self.assertIn("persistedEffectsURL", restore)
        self.assertLess(
            restore.index("storedFingerprint"),
            restore.index("for (NSDictionary *plugin in plugins)"),
        )
        legacy_restore = PLUGINS.split(
            "static BOOL AMCloudPluginsActivatePersistedState", 1
        )[1].split("static BOOL AMCloudPluginsActivatePersistedCatalog", 1)[0]
        self.assertIn("Legacy release state predates the merged-catalog fingerprint", PLUGINS)
        self.assertIn("AMCloudPluginsCatalogContainsBundledEffects", legacy_restore)
        self.assertIn("AMCloudPluginsInvalidateStaleCatalog(manager)", legacy_restore)
        self.assertIn("AMCloudPluginsCatalogProtocolVersion", restore)
        self.assertIn("AMCloudPluginsInvalidateStaleCatalog(NSFileManager.defaultManager)", PLUGINS)

    def test_catalog_passive_dependencies_do_not_claim_or_overwrite_paths(self):
        validator = PLUGINS.split(
            "static BOOL AMCloudPluginsValidateCatalogItemFiles(", 1
        )[1].split("BOOL AMCloudPluginsActivateCatalog", 1)[0]
        self.assertIn(
            "BOOL baselineIdentical = bundled.length && [bundled isEqualToData:incoming]",
            validator,
        )
        passive_branch = validator.split("if (baselineIdentical) {", 1)[1].split(
            "if (!ownedURL && resourceOwners)", 1
        )[0]
        self.assertIn("[skipRelativePaths addObject:relativeKey]", passive_branch)
        self.assertNotIn("resourceOwners[relativeKey] =", passive_branch)
        self.assertLess(
            validator.index("if (baselineIdentical) {"),
            validator.index("resourceOwners[relativeKey] = sourceURL"),
        )

        copier = PLUGINS.split(
            "static BOOL AMCloudPluginsCopyCatalogDirectorySkippingPaths(", 1
        )[1].split("static BOOL AMCloudPluginsCopyCatalogDirectory(", 1)[0]
        self.assertIn("[skipRelativePaths containsObject:relativeKey]", copier)

        activation = PLUGINS.split(
            "NSMutableArray *statePlugins", 1
        )[1].split("NSObject *commitLock", 1)[0]
        self.assertIn("NSMutableSet<NSString *> *skipRelativePaths", activation)
        self.assertIn("resourceOwners, skipRelativePaths", activation)
        self.assertIn("skipRelativePaths,\n\t\t\t\t\tsourceEffects", activation)

    def test_non_target_dependencies_require_target_xml_authorization(self):
        validator = PLUGINS.split(
            "static BOOL AMCloudPluginsValidateCatalogItemFiles(", 1
        )[1].split("BOOL AMCloudPluginsActivateCatalog", 1)[0]
        self.assertIn(
            "targetReferencedEffectIDs = AMCloudPluginsReferencedEffectIDsForXMLURL(\n"
            "            targetURL",
            validator,
        )
        self.assertNotIn("[referencedEffectIDs unionSet:", validator)
        self.assertIn(
            "bundledURL, targetReferencedEffectIDs)",
            validator,
        )
        self.assertIn(
            "BOOL isReferencedByTarget = [targetReferences containsObject:relativeKey]",
            validator,
        )
        self.assertIn(
            "isLegacyImageReplacement = legacyPathOverride && imageReplacement &&\n"
            "            isReferencedByTarget && bundled.length",
            validator,
        )
        self.assertIn(
            "isBuiltinImageReplacement = [kind isEqualToString:@\"builtin_override\"] &&\n"
            "            imageReplacement && isReferencedByTarget && bundled.length",
            validator,
        )
        self.assertIn(
            "BOOL isSharedNewResource = !bundled.length && ownedURL && ownedIdentical",
            validator,
        )
        self.assertNotIn("BOOL identical = existing", validator)
        rejection = validator.split(
            "if (!isSharedNewResource && !isTarget", 1
        )[1].split("return NO;", 1)[0]
        for required_gate in (
            "!isLegacyOfficialDependency",
            "!isBuiltinImageReplacement",
            "!isLegacyImageReplacement",
        ):
            self.assertIn(required_gate, rejection)
        self.assertIn("Builtin override may contain only its target XML", validator)

    def test_catalog_state_restore_accepts_flattened_item_metadata(self):
        version_helper = PLUGINS.split(
            "static NSString *AMCloudPluginsItemVersionID", 1
        )[1].split("static NSString *AMCloudPluginsItemSHA", 1)[0]
        sha_helper = PLUGINS.split(
            "static NSString *AMCloudPluginsItemSHA", 1
        )[1].split("static BOOL AMCloudPluginsCatalogEntryIsSafe", 1)[0]
        self.assertIn('plugin[@"version_id"]', version_helper)
        self.assertIn('plugin[@"sha256"]', sha_helper)
        self.assertIn('version[@"id"]', version_helper)
        self.assertIn('version[@"sha256"]', sha_helper)
        self.assertIn("AMCloudPluginsInstallItemArchiveWithMetadata", PLUGINS)
        self.assertIn(
            "AMCloudPluginsInstallItemArchiveWithMetadata(\n                archiveURL, pluginID, versionID, sha, plugin",
            CLOUD,
        )
        install = PLUGINS.split(
            "BOOL AMCloudPluginsInstallItemArchiveWithMetadata", 1
        )[1].split("static NSURL *AMCloudPluginsBundledEffectsURL", 1)[0]
        self.assertIn("AMCloudPluginsValidateBuiltinOverride", install)
        self.assertIn('@"kind": kind', install)
        self.assertIn('storedMetadata[@"target_path"]', install)

    def test_plugin_download_has_visible_start_and_result_alerts(self):
        self.assertIn("beginPluginDownloadNoticeForRelease", CLOUD)
        self.assertIn("finishPluginDownloadNoticeInstalled", CLOUD)
        self.assertIn('@"正在下载云端插件"', CLOUD)
        self.assertIn('@"云端插件下载完成"', CLOUD)
        self.assertIn('@"云端插件下载失败"', CLOUD)
        sync = CLOUD.rsplit("- (void)syncPluginsNow:", 1)[1].split(
            "- (void)finishPluginSync", 1
        )[0]
        self.assertLess(
            sync.index("beginPluginDownloadNoticeForRelease"),
            sync.index("downloadPluginRelease:release"),
        )
        self.assertIn("effect_count", sync)
        self.assertIn("showPluginDownloadNoticeIfPossible", CLOUD)
        self.assertIn("hidePluginDownloadNotice", CLOUD)
        self.assertIn("cancelPluginDownloadNotice", CLOUD)
        self.assertIn("[window addSubview:overlay]", CLOUD)
        self.assertIn('@"后台继续下载" : @"知道了"', CLOUD)
        self.assertIn("pluginDownloadNoticeGeneration", CLOUD)
        self.assertIn("pluginDownloadNoticeOperationID", CLOUD)
        self.assertIn("AMCloudGradientProgressView", CLOUD)
        self.assertIn("AMCloudGradientButton", CLOUD)
        self.assertIn("#import <QuartzCore/QuartzCore.h>", CLOUD)
        self.assertIn("updatePluginDownloadNoticeCompletedBytes", CLOUD)
        self.assertIn("AMCloudTrackDownloadTask", CLOUD)
        self.assertIn("systemImageNamed:", CLOUD)
        self.assertIn("panel.layer.cornerRadius = 24", CLOUD)
        self.assertIn("pluginSyncOperationID = nil", CLOUD)
        self.assertIn("pluginSyncInFlight = NO", CLOUD)
        self.assertIn("AMCloudPostTokenChanged();", CLOUD)
        self.assertLess(
            CLOUD.index("AMCloudPostTokenChanged();", CLOUD.index("if (changed)")),
            CLOUD.index("AMCloudCleanupPluginsForAuth(token, generation);"),
        )
        cleanup = CLOUD.split("static void AMCloudCleanupPluginsForAuth", 1)[1].split(
            "static BOOL AMCloudWriteToken", 1
        )[0]
        self.assertNotIn("AMCloudPostTokenChanged", cleanup)
        self.assertIn("if (cleanupURL)", sync)
        self.assertGreaterEqual(
            sync.count("[self.pluginSyncOperationID isEqualToString:operationID]"),
            4,
        )
        self.assertIn("UILayoutPriorityDefaultHigh", CLOUD)
        self.assertIn("constraintLessThanOrEqualToAnchor:overlay.widthAnchor", CLOUD)
        self.assertIn("finishPluginSyncAllowingPending:NO", sync)
        item_progress = CLOUD.split(
            "[self.client downloadPluginItem:plugin progress:", 1
        )[1].split("long long delta", 1)[0]
        self.assertIn(
            "[self.pluginSyncOperationID isEqualToString:operationID]",
            item_progress,
        )
        self.assertIn(
            "[self.pluginDownloadNoticeOperationID isEqualToString:operationID]",
            item_progress,
        )
        self.assertIn("AMCloudAuthMatches(token, authorizationGeneration)", item_progress)
        initial_progress = CLOUD.split("progressLabel.text =", 1)[1].split(
            ': @"正在连接云端";', 1
        )[0]
        self.assertIn("self.pluginDownloadCompletedBytes", initial_progress)
        self.assertIn("self.pluginDownloadCompletedItems", initial_progress)
        timer = CLOUD.split("- (void)pluginSyncTimerFired:", 1)[1].split(
            "- (void)syncPluginsNow:", 1
        )[0]
        self.assertIn('@"foreground_timer"', timer)
        in_flight = sync.split("if (self.pluginSyncInFlight)", 1)[1].split(
            "self.pluginSyncInFlight = YES", 1
        )[0]
        self.assertIn('![reason isEqualToString:@"foreground_timer"]', in_flight)

    def test_stale_authenticated_responses_cannot_delete_a_new_token(self):
        self.assertIn("AMCloudInvalidateTokenForRequest", CLOUD)
        self.assertIn('valueForHTTPHeaderField:@"Authorization"', CLOUD)
        self.assertIn("AMCloudInvalidateToken(logoutToken)", CLOUD)
        self.assertNotIn("AMCloudInvalidateToken(activationToken)", CLOUD)
        self.assertIn("if (response.statusCode == 401 && authenticated)", CLOUD)
        self.assertGreaterEqual(
            CLOUD.count("AMCloudInvalidateTokenForRequest(request)"), 3
        )
        self.assertIn("AMCloudAuthPerformSync", CLOUD)
        self.assertIn("AMCloudDeleteTokenMatching(token, YES)", CLOUD)
        self.assertIn("AMCloudPluginsSetAuthorizationGeneration", CLOUD)
        self.assertIn("if (hadToken) AMCloudPostTokenChanged();", CLOUD)
        self.assertIn("AMCloudCleanupPluginsForAuth(nil, generation);", CLOUD)
        self.assertNotIn(
            "if (response.statusCode == 401) AMCloudDeleteToken();", CLOUD
        )
        self.assertNotIn(
            "if (response.statusCode == 401 && authenticated) AMCloudDeleteToken();",
            CLOUD,
        )

    def test_plugin_install_and_cleanup_share_a_serial_commit_lane(self):
        self.assertIn("AMCloudPluginsMutationQueue", PLUGINS)
        self.assertIn("DISPATCH_QUEUE_SERIAL", PLUGINS)
        self.assertIn("AMCloudPluginsPerformMutation", PLUGINS)
        self.assertIn("AMCloudPluginsCommitGuard", PLUGIN_HEADER)
        self.assertIn("commitGuard(commit)", PLUGINS)
        self.assertIn("if (commitGuardReturned || commitInvoked) return;", PLUGINS)
        self.assertIn("@synchronized (commitLock)", PLUGINS)
        self.assertIn("不得保存或逃逸 commit", PLUGIN_HEADER)
        self.assertIn("返回 NO 时不得调用 commit", PLUGIN_HEADER)
        self.assertIn("if (!authorized && commitAccepted && installed)", PLUGINS)
        self.assertIn("AMCloudCommitIfAuthMatches", CLOUD)
        self.assertIn("authorizationGeneration", PLUGINS)
        self.assertIn('@"authorization_key"', PLUGINS)

    def test_plugin_state_restore_and_cleanup_are_fail_closed(self):
        load_state = PLUGINS.split("static BOOL AMCloudPluginsActivatePersistedState", 1)[1]
        load_state = load_state.split("static NSString *AMCloudPluginsRelativeDirectory", 1)[0]
        self.assertIn("id object =", load_state)
        self.assertIn("[object isKindOfClass:NSDictionary.class]", load_state)
        self.assertIn("AMCloudPluginsRevocationURL", load_state)

        cleanup = PLUGINS.split("BOOL AMCloudPluginsRemoveAllIf", 1)[1]
        cleanup = cleanup.split("void AMCloudPluginsRemoveAll", 1)[0]
        invalidate_at = cleanup.index("AMCloudPluginsInvalidatePersistedState")
        remove_root_at = cleanup.index("removeItemAtURL:rootURL")
        self.assertLess(invalidate_at, remove_root_at)
        self.assertIn("AMCloudPluginsPersistRevocationMarker", cleanup)
        self.assertIn("removed = rootKnown && !rootExists", cleanup)
        self.assertIn("attributesOfItemAtPath", PLUGINS)
        self.assertNotIn("fileExistsAtPath", PLUGINS)
        self.assertIn("NSDataWritingAtomic", PLUGINS)
        self.assertIn("插件根目录已不存在", PLUGIN_HEADER)

        hook_install = PLUGINS.split("void AMCloudPluginsInstallBundleHooks", 1)[1]
        hook_install = hook_install.split("BOOL AMCloudPluginsActivateInstalledRelease", 1)[0]
        self.assertNotIn("ActivatePersistedState", hook_install)

        early_restore = CLOUD.split("void AMCloudSyncInstallPluginHooksEarly", 1)[1]
        early_restore = early_restore.split("void AMCloudSyncInstall", 1)[0]
        self.assertIn("AMCloudReadAuthContext", early_restore)
        self.assertIn("AMCloudPluginsRestoreInstalledReleaseForAuthorization", early_restore)
        self.assertIn("不会从磁盘恢复插件", PLUGIN_HEADER)

        manifest = CLOUD.split("BOOL enabled =", 1)[1].split(
            "[self.client downloadPluginRelease", 1
        )[0]
        activate_at = manifest.index("AMCloudPluginsActivateInstalledRelease")
        up_to_date_at = manifest.index('AMCloudDiagnostic(@"cloud.plugins.up_to_date"')
        self.assertLess(activate_at, up_to_date_at)

    def test_bundle_hook_overrides_only_changed_resources_and_appends_new_effects(self):
        for selector in (
            "URLsForResourcesWithExtension:subdirectory:",
            "URLForResource:withExtension:subdirectory:",
            "pathsForResourcesOfType:inDirectory:",
            "pathForResource:ofType:inDirectory:",
        ):
            self.assertIn(selector, PLUGINS)
        self.assertIn('caseInsensitiveCompare:@"BuiltinEffects"', PLUGINS)
        self.assertIn("remaining[key] = URL", PLUGINS)
        self.assertIn("AMCloudPluginsShouldUseCloudResource", PLUGINS)
        self.assertIn("? replacement : URL", PLUGINS)
        self.assertIn("[merged addObjectsFromArray:newURLs]", PLUGINS)
        self.assertIn("contentsOfDirectoryAtURL", PLUGINS)
        self.assertNotIn("enumeratorAtURL", PLUGINS)
        self.assertIn("AMCloudPluginsRelativeDirectory", PLUGINS)
        self.assertNotIn("AMCloudPluginsBuiltinEffectsRootURL", PLUGINS)
        self.assertIn("NSURL *bundled = AMCloudOriginalBundleURL", PLUGINS)
        self.assertIn("NSString *bundled = AMCloudOriginalBundlePath", PLUGINS)
        self.assertIn("AMCloudPluginsShouldUseCloudResource(cloud, bundled)", PLUGINS)
        self.assertIn("AMCloudPluginsShouldUseCloudResource(cloud, bundledURL)", PLUGINS)
        self.assertNotIn("@selector(URLForResource:withExtension:),", PLUGINS)
        self.assertNotIn("@selector(pathForResource:ofType:),", PLUGINS)
        self.assertIn("AMCloudBundleHookGuardKey", PLUGINS)
        self.assertIn("AMCloudSyncInstallPluginHooksEarly();", EXPORT)

    def test_bundle_resource_hot_path_uses_bounded_caches_and_invalidates_them(self):
        self.assertIn("AMCloudPluginsFilesCache", PLUGINS)
        self.assertIn("AMCloudPluginsResourceDecisionCache", PLUGINS)
        self.assertIn("cache.countLimit = 256", PLUGINS)
        self.assertIn("cache.countLimit = 1024", PLUGINS)
        self.assertIn("AMCloudPluginsClearRuntimeCaches();", PLUGINS)
        self.assertIn("[AMCloudPluginsFilesCache() removeAllObjects]", PLUGINS)
        self.assertIn("[AMCloudPluginsResourceDecisionCache() removeAllObjects]", PLUGINS)
        active_state = PLUGINS.split("static void AMCloudPluginsSetActiveState", 1)[1]
        active_state = active_state.split("void AMCloudPluginsSetAuthorizationGeneration", 1)[0]
        self.assertIn("AMCloudPluginsClearRuntimeCaches();", active_state)
        generation = PLUGINS.split("void AMCloudPluginsSetAuthorizationGeneration", 1)[1]
        generation = generation.split("static uint64_t AMCloudPluginsAuthorizationGeneration", 1)[0]
        self.assertIn("AMCloudPluginsClearRuntimeCaches();", generation)
        files = PLUGINS.split("static NSArray<NSURL *> *AMCloudPluginsFiles", 1)[1]
        files = files.split("static BOOL AMCloudPluginsShouldUseCloudResource", 1)[0]
        self.assertIn("objectForKey:cacheKey", files)
        self.assertIn("setObject:result forKey:cacheKey", files)
        decision = PLUGINS.split("static BOOL AMCloudPluginsShouldUseCloudResource", 1)[1]
        decision = decision.split("static NSArray<NSURL *> *AMCloudPluginsMergeResourceURLs", 1)[0]
        self.assertIn("objectForKey:cacheKey", decision)
        self.assertIn("setObject:@(useCloud) forKey:cacheKey", decision)

    def test_plugin_zip_uses_existing_strict_extractor(self):
        self.assertIn("AMProjExtractPluginArchive", IMPORT_ARCHIVE)
        for required in (
            "AMProjImportReadDirectory",
            "AMProjImportValidateLocalHeaders",
            "AMProjImportExtractEntry",
            '@"BuiltinEffects/"',
            '@"xml", @"png", @"jpg", @"webp"',
            "AMProjImportArchiveErrorUnsafeEntry",
        ):
            self.assertIn(required, IMPORT_ARCHIVE)

    def test_upload_is_file_backed_and_integrity_claimed(self):
        self.assertIn("uploadTaskWithRequest:request fromFile:fileURL", CLOUD)
        self.assertIn('forHTTPHeaderField:@"Content-Length"', CLOUD)
        self.assertIn('forHTTPHeaderField:@"X-AMProj-Filename"', CLOUD)
        self.assertIn('forHTTPHeaderField:@"X-AMProj-SHA256"', CLOUD)
        self.assertIn("AMCloudSHA256(fileURL", CLOUD)

    def test_project_download_is_verified_then_staged_without_claiming_import_success(self):
        self.assertIn("downloadTaskWithRequest:request", CLOUD)
        self.assertIn("caseInsensitiveCompare:expectedSHA", CLOUD)
        self.assertIn("response.expectedContentLength", CLOUD)
        download_start = CLOUD.rindex("- (void)downloadAndImportProject:")
        project_download = CLOUD[download_start:]
        project_download = project_download.split(
            "- (void)showVersionsForProject:", 1
        )[0]
        self.assertIn(
            "AMCloudImportAsyncHandler asyncHandler = manager.asyncImportHandler",
            project_download,
        )
        self.assertIn(
            "asyncHandler(URL, filename, cleanupURL, handoffCompletion)",
            project_download,
        )
        self.assertIn("AMCloudImportHandler importHandler = manager.importHandler", project_download)
        self.assertIn("importHandler(URL, filename, cleanupURL)", project_download)
        self.assertIn("AMCloudRetainProjectDownloadForRetry", project_download)
        self.assertIn("@catch (NSException *exception)", project_download)
        self.assertNotIn("@finally", project_download)
        self.assertIn('@"cloud.project_handoff_staged"', project_download)
        self.assertIn('@"import_confirmed": @NO', project_download)
        self.assertIn("if (!staged)", project_download)
        self.assertIn("dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)", project_download)
        self.assertIn("completionCalled", project_download)
        self.assertIn("AMCloudProjectHandoffTimeout", project_download)
        self.assertIn('cloud.project_handoff_timeout', project_download)
        self.assertIn('cloud.project_handoff_manager_deallocated', project_download)
        self.assertIn('cloud.project_handoff_completion_exception', project_download)

    def test_project_download_retention_is_marked_and_only_cleans_its_own_uuid_directory(self):
        self.assertIn('AMCloudProjectRetryMarkerFilename = @".amproj-retry.plist"', CLOUD)
        self.assertIn('AMCloudProjectRetryRetention = 24 * 60 * 60', CLOUD)
        self.assertIn("AMCloudProjectDownloadDirectoryIsDirectChild", CLOUD)
        self.assertIn("AMCloudCleanupExpiredProjectDownloads", CLOUD)
        self.assertIn("NSPropertyListSerialization", CLOUD)
        self.assertIn("marker_written", CLOUD)
        self.assertIn("currentExpiry", CLOUD)

    def test_cloud_import_handler_installers_are_mutually_exclusive(self):
        sync = CLOUD.split("- (void)installWithImportHandler:", 1)[1].split(
            "- (void)applicationDidBecomeActive:", 1
        )[0]
        async_install = CLOUD.split("- (void)installWithAsyncImportHandler:", 1)[1].split(
            "- (void)applicationDidBecomeActive:", 1
        )[0]
        self.assertIn("self.asyncImportHandler = nil", sync)
        self.assertIn("[self installWithImportHandler:nil]", async_install)

    def test_async_cloud_install_entrypoint_is_explicit(self):
        self.assertIn("AMCloudImportAsyncHandler", HEADER)
        self.assertIn("AMCloudSyncInstallAsync", HEADER)
        self.assertIn("void AMCloudSyncInstallAsync", CLOUD)
        self.assertIn("installWithAsyncImportHandler", CLOUD)

    def test_json_envelope_requires_explicit_zero_code(self):
        self.assertIn("|| !code", CLOUD)
        self.assertIn("if (code.integerValue != 0)", CLOUD)

    def test_projects_account_entry_replaces_the_existing_rightmost_item(self):
        self.assertIn('hasSuffix:@"ProjectsVC"', CLOUD)
        self.assertIn('hasSuffix:@"ProjectsListVC"', CLOUD)
        self.assertIn("AMCloudProjectsViewDidAppear", CLOUD)
        self.assertIn("if (updated.count) updated[0] = accountItem", CLOUD)
        self.assertIn("person.crop.circle", CLOUD)
        self.assertIn("AMCloudAccountWebViewController", CLOUD)
        self.assertIn("WKWebView", CLOUD)
        self.assertIn("https://am.meowcr.cn/me.html?embed=1&platform=ios", CLOUD)
        self.assertIn('name:@"amAccount"', CLOUD)

    def test_native_my_account_route_is_replaced_before_presentation_or_push(self):
        for symbol in (
            "AMCloudSyncReplacementForNativeAccountPresentation",
            "AMCloudSyncReplacementForNativeAccountPush",
        ):
            self.assertIn(symbol, HEADER)
            self.assertIn(symbol, CLOUD)
            self.assertIn(symbol, EXPORT)
        self.assertIn('isEqualToString:@"AlightMotion.MyAccountVC"', CLOUD)
        self.assertIn(
            'isEqualToString:@"_TtC12AlightMotion11MyAccountVC"', CLOUD
        )
        self.assertNotIn('hasSuffix:@"MyAccountVC"', CLOUD)
        self.assertIn("AMCloudContainsNativeAccountController", CLOUD)
        detector = CLOUD.split(
            "static BOOL AMCloudContainsNativeAccountController", 1
        )[1].split("static IMP AMCloudOriginalProjectsViewDidAppear", 1)[0]
        self.assertIn(".topViewController", detector)
        self.assertIn(".selectedViewController", detector)
        self.assertNotIn("childViewControllers", detector)
        self.assertIn("![NSThread isMainThread]", CLOUD)
        presentation_handler = CLOUD.split(
            "AMCloudSyncReplacementForNativeAccountPresentation", 1
        )[1].split("AMCloudSyncReplacementForNativeAccountPush", 1)[0]
        self.assertIn("newAccountControllerForRoute", presentation_handler)
        self.assertIn("return navigation;", presentation_handler)
        self.assertNotIn("dispatch_async", presentation_handler)

        push_handler = CLOUD.split(
            "AMCloudSyncReplacementForNativeAccountPush", 1
        )[1].split("AMCloudSyncUploadActivities", 1)[0]
        self.assertIn("newAccountControllerForRoute", push_handler)
        self.assertIn("return account;", push_handler)
        self.assertNotIn("dispatch_async", push_handler)
        self.assertNotIn("weakNavigationController", push_handler)

        presentation = EXPORT.split("static void hooked_presentVC", 1)[1]
        presentation = presentation.split("#if AMPROJ_DEBUG", 1)[0]
        replacement = presentation.index(
            "AMCloudSyncReplacementForNativeAccountPresentation"
        )
        native_forward = presentation.index("orig_presentVC(self", replacement)
        self.assertLess(replacement, native_forward)
        self.assertIn(
            "orig_presentVC(self, _cmd, accountReplacement, animated, nil)",
            presentation,
        )

        navigation = EXPORT.split("static void hooked_navigationPush", 1)[1]
        navigation = navigation.split("static void amproj_forwardPresentation", 1)[0]
        replacement = navigation.index(
            "AMCloudSyncReplacementForNativeAccountPush"
        )
        native_push = navigation.index("orig_navigationPush", replacement)
        self.assertLess(replacement, native_push)
        self.assertIn(
            "orig_navigationPush(self, _cmd, accountReplacement, animated)",
            navigation,
        )

    def test_account_webview_syncs_keychain_token_and_device_context(self):
        self.assertIn("AMCloudDeviceKeychainAccount", CLOUD)
        self.assertIn("AMCloudDeviceIdentifier", CLOUD)
        self.assertIn("AMCloudDeviceName", CLOUD)
        self.assertIn("window.AF_NATIVE_CONTEXT", CLOUD)
        self.assertIn("localStorage.setItem('af-token'", CLOUD)
        self.assertIn("AMCloudWriteToken(token)", CLOUD)
        self.assertIn("activateIOSSession", CLOUD)
        self.assertIn('forHTTPHeaderField:@"X-AM-Device-ID"', CLOUD)

        account_impl = CLOUD.split(
            "@implementation AMCloudAccountWebViewController", 1
        )[1].split("@implementation AMCloudWeakScriptMessageHandler", 1)[0]
        account = account_impl.split("- (void)viewDidLoad", 1)[1].split(
            "- (void)loadAccountWebsiteWithToken:", 1
        )[0]
        self.assertIn("pluginIOSSessionToken", account)
        self.assertIn("pluginIOSSessionActivationInFlight", account)
        self.assertIn(
            "[self loadAccountWebsiteWithToken:token activationError:nil]", account
        )

        device_identifier = CLOUD.split(
            "static NSString *AMCloudDeviceIdentifier", 1
        )[1].split("static NSString *AMCloudDeviceName", 1)[0]
        self.assertIn("AMCloudIsValidDeviceIdentifier", device_identifier)
        self.assertIn("status != errSecItemNotFound", device_identifier)
        self.assertIn("writeStatus == errSecSuccess", device_identifier)
        self.assertIn("errSecDuplicateItem", device_identifier)
        self.assertNotIn("SecItemDelete", device_identifier)

        webview = CLOUD.split("@implementation AMCloudAccountWebViewController", 1)[1]
        webview = webview.split("@implementation AMCloudWeakScriptMessageHandler", 1)[0]
        self.assertIn("AMCloudIsTrustedAccountURL", webview)
        self.assertIn("location.protocol!=='https:'", webview)
        self.assertIn("location.hostname!=='am.meowcr.cn'", webview)
        self.assertIn("message.frameInfo", webview)
        self.assertIn("frameInfo.isMainFrame", webview)
        self.assertIn("frameInfo.securityOrigin", webview)
        self.assertIn("WKNavigationActionPolicyCancel", webview)

    def test_account_refresh_only_targets_the_legacy_native_controller(self):
        self.assertNotIn("[weakSelf.accountController reloadCloudData]", CLOUD)
        refresh = CLOUD.split("- (void)reloadAccountControllerIfSupported", 1)[1]
        refresh = refresh.split("- (void)showAccountFrom", 1)[0]
        self.assertIn("respondsToSelector:@selector(reloadCloudData)", refresh)
        self.assertIn("(AMCloudAccountViewController *)account", refresh)

    def test_account_avatar_is_synced_to_home_and_web_account(self):
        self.assertIn('profile[@"avatarUrl"]', CLOUD)
        self.assertIn("loadAvatarURL", CLOUD)
        self.assertIn("circularAvatarImage", CLOUD)
        self.assertIn("UIImageRenderingModeAlwaysOriginal", CLOUD)
        self.assertIn("self.accountAvatarImage", CLOUD)
        self.assertIn("updateAccountEntryImage", CLOUD)
        self.assertIn("AMCloudAvatarCacheFilename", CLOUD)
        self.assertIn("AMCloudAvatarChangedNotification", CLOUD)
        self.assertIn("AMHomeUIShowAccountNotification", CLOUD)
        self.assertIn("handleHomeAccountNotification", CLOUD)
        self.assertIn('[body[@"type"] isEqualToString:@"profile"]', CLOUD)
        self.assertIn("[self.manager applyAccountProfile:profile]", CLOUD)
        self.assertIn("[self clearAccountAvatar]", CLOUD)
        install = CLOUD.split("- (void)installWithImportHandler:", 1)[1].split(
            "- (void)applicationDidBecomeActive:", 1
        )[0]
        self.assertIn("if (startupToken.length)", install)
        self.assertIn("[self loadCachedAccountAvatar]", install)
        self.assertIn("[self refreshAccountAvatar]", install)
        self.assertIn("[self clearAccountAvatar]", install)
        cached_avatar = CLOUD.split("- (void)loadCachedAccountAvatar", 1)[1].split(
            "- (UIImage *)circularAvatarImage", 1
        )[0]
        self.assertIn("UIImageRenderingModeAlwaysOriginal", cached_avatar)
        update_entry = CLOUD.split("- (void)updateAccountEntryImage", 1)[1].split(
            "- (void)pluginSyncTimerFired", 1
        )[0]
        self.assertIn("AMCloudAttachVisibleProjectsControllers();", update_entry)

    def test_home_ui_is_not_linked_or_installed_by_cloud(self):
        self.assertNotIn('#import "AMHomeUI.h"', CLOUD)
        install = CLOUD.split("void AMCloudSyncInstall(", 1)[1].split(
            "void AMCloudAuthorizeFeature", 1
        )[0]
        self.assertNotIn("AMHomeUIInstall();", install)
        self.assertNotIn('cloud.home_ui.linked_install', install)
        self.assertNotIn("AMCloudLoadHomeUI", CLOUD)
        self.assertNotIn("AMCloudScheduleHomeUILoad", CLOUD)
        self.assertNotIn("dlopen(", CLOUD)
        self.assertNotIn("dlsym(", CLOUD)

    def test_account_route_emits_immediately_flushable_diagnostic_stages(self):
        self.assertIn("emitCriticalEvent", DEBUG_HEADER)
        self.assertIn("- (void)emitCriticalEvent", DEBUG_SOURCE)
        critical = DEBUG_SOURCE.split("- (void)emitCriticalEvent", 1)[1].split(
            "- (void)appendEvent", 1
        )[0]
        self.assertIn("[self performSync:", critical)
        self.assertIn("[self flushEvents]", critical)
        header_contract = DEBUG_HEADER.split("- (void)emitCriticalEvent", 1)[0]
        self.assertIn("best-effort", header_contract)
        self.assertIn("任意线程", header_contract)
        self.assertIn("内存队列", header_contract)
        for event in (
            "cloud.account.tap",
            "cloud.account.route",
            "cloud.account.controller_create_begin",
            "cloud.account.controller_created",
            "cloud.account.present_begin",
            "cloud.account.present_completed",
            "cloud.account.view_load_enter",
            "cloud.account.view_load_super_returned",
            "cloud.account.view_load_configured",
            "cloud.account.reload_begin",
            "cloud.account.exception",
            "cloud.account.native_present_intercepted",
            "cloud.account.native_push_intercepted",
            "cloud.account.native_present_replacement_ready",
            "cloud.account.native_push_replacement_ready",
            "cloud.account.token_read_begin",
            "cloud.account.token_read_end",
            "cloud.account.view_did_appear",
        ):
            self.assertIn(f'@"{event}"', CLOUD)
        manager = CLOUD.split("@implementation AMCloudManager", 1)[1]
        account_route = manager.split("- (void)showAccountFrom:", 1)[1].split(
            "- (void)handleHomeAccountNotification", 1
        )[0]
        self.assertIn("} @catch (NSException *exception)", account_route)
        self.assertIn(
            'AMCloudDiagnostic(@"cloud.account.exception"', account_route
        )
        self.assertNotIn("showError:", account_route)

    def test_export_share_exposes_cloud_upload_activity(self):
        self.assertIn("AMCloudSyncUploadActivities", HEADER)
        self.assertIn("AMCloudSyncUploadActivities(fileURL", EXPORT)
        self.assertIn("applicationActivities:cloudActivities", EXPORT)
        self.assertIn('return @"上传到云项目"', CLOUD)

    def test_native_cloud_export_saves_to_autfeng_hub_only_when_selected(self):
        self.assertIn("AMCloudSyncBeginUploadFile", HEADER)
        direct_upload = EXPORT.split(
            "static void amproj_beginDirectCloudUpload", 1
        )[1].split("static void amproj_presentDirectShare", 1)[0]
        self.assertIn("AMCloudSyncBeginUploadFile(fileURL", direct_upload)
        self.assertIn('amproj_finishDirectFlow(@"cloud_upload_ready")', direct_upload)

        export_action = EXPORT.split(
            "static void hooked_shareNCOnTapExport", 1
        )[1].split("static void hooked_navigationPush", 1)[0]
        self.assertIn("AMProjShareCloudUploadOption = 6", EXPORT)
        self.assertIn(
            "selectedExportOption == AMProjShareCloudUploadOption", export_action
        )
        self.assertIn("amproj_startCloudUpload(shareController, title)", export_action)
        self.assertIn("orig_shareNCOnTapExport", export_action)
        self.assertIn("(!isProjectPackage && !isCloudUpload)", export_action)
        self.assertIn("amproj_directAuthorizationPending", export_action)
        self.assertIn('reason\": @"new_export_tap"', export_action)

        authorization = EXPORT.split(
            "static void amproj_startDirectExportWithDestination", 1
        )[1].split("static void amproj_startDirectExport", 1)[0]
        self.assertIn("++amproj_directAuthorizationGeneration", authorization)
        self.assertIn(
            "authorizationGeneration != amproj_directAuthorizationGeneration",
            authorization,
        )
        self.assertIn(
            "selectedExportOption != AMProjShareCloudUploadOption", authorization
        )
        self.assertIn('direct.authorization_selection_changed', authorization)

        archive_ready = EXPORT.split(
            "static void amproj_writeDirectArchive", 1
        )[1].split("static void amproj_buildDirectPackage", 1)[0]
        self.assertIn("if (request.uploadToCloud)", archive_ready)
        self.assertIn("amproj_beginDirectCloudUpload(request, outputURL)", archive_ready)
        self.assertIn("amproj_presentDirectShare(request, outputURL)", archive_ready)

    def test_native_cloud_export_uses_autfeng_hub_copy(self):
        self.assertIn('@"上传到云项目"', EXPORT)
        self.assertIn('@"选择性保存为云工程"', EXPORT)
        self.assertIn('@"上传到云项目"', CLOUD)
        self.assertNotIn('@"保存到 AutFeng Hub"', EXPORT)
        self.assertNotIn('@"保存到 AutFeng Hub"', CLOUD)
        self.assertIn('@"新建云工程"', CLOUD)
        self.assertIn("chooseUploadTarget", CLOUD)

    def test_cloud_project_upload_can_retry_the_generated_package(self):
        upload = CLOUD.rsplit("- (void)uploadFile:(NSURL *)fileURL", 1)[1].split(
            "- (void)showActionsForProject", 1
        )[0]
        self.assertIn('@"云工程上传失败"', upload)
        self.assertIn('actionWithTitle:@"重试"', upload)
        self.assertIn("[weakSelf uploadFile:fileURL title:title", upload)
        self.assertIn("error.code == 401", upload)
        self.assertIn("showAuthenticationFrom:retryPresenter", upload)
        self.assertIn('AMCloudAuthorizeFeature(@"export", retryPresenter', upload)
        self.assertIn("if (!allowed) return", upload)

    def test_cloud_export_revalidates_its_visible_presenter(self):
        top_controller = CLOUD.split(
            "static UIViewController *AMCloudTopController", 1
        )[1].split("static NSDictionary *AMCloudEnvelope", 1)[0]
        self.assertIn("!controller.viewIfLoaded.window", top_controller)
        self.assertIn("NSMutableSet<NSValue *> *visited", top_controller)
        self.assertIn("!next || !next.viewIfLoaded.window", top_controller)
        self.assertNotIn("return AMCloudTopController", top_controller)

        cloud_ready = EXPORT.split(
            "static UIViewController *amproj_visibleCloudUploadPresenter", 1
        )[1].split("static void amproj_presentDirectShare", 1)[0]
        self.assertIn("amproj_topViewController(preferred)", cloud_ready)
        self.assertIn("amproj_keyWindow().rootViewController", cloud_ready)
        self.assertLess(
            cloud_ready.index("amproj_visibleCloudUploadPresenter(request.presenter)"),
            cloud_ready.index("amproj_directRequest = nil"),
        )

        authorization = EXPORT.split(
            "static void amproj_startDirectExportWithDestination", 1
        )[1].split("static void amproj_startDirectExport", 1)[0]
        self.assertIn("if (!presenter.viewIfLoaded.window)", authorization)
        self.assertIn("direct.authorization_presenter_detached", authorization)

    def test_import_and_export_require_server_authorization(self):
        self.assertIn("AMCloudAuthorizeFeature", HEADER)
        self.assertIn('AMCloudAuthorizeFeature(@"export"', EXPORT)
        self.assertIn('AMCloudAuthorizeFeature(@"import"', EXPORT)
        self.assertIn("amproj_importAuthorizationPending", EXPORT)
        self.assertIn('body:@{ @"feature": feature ?: @"" }', CLOUD)

        export_boundary = EXPORT.split(
            "static void amproj_startDirectExport", 1
        )[1].split("static void amproj_finishDirectFailure", 1)[0]
        self.assertIn('AMCloudAuthorizeFeature(@"export"', export_boundary)
        self.assertIn("amproj_startAuthorizedDirectExport", export_boundary)
        retry = EXPORT.split('actionWithTitle:@"重试"', 1)[1].split(
            "actionWithTitle", 1
        )[0]
        self.assertIn("amproj_startDirectExport", retry)
        self.assertNotIn("amproj_startAuthorizedDirectExport", retry)

        import_dispatch = EXPORT.rsplit(
            "static void amproj_tryDispatchPendingImport(NSUInteger generation) {", 1
        )[1].split("static void amproj_queuePreparedImport", 1)[0]
        authorize_at = import_dispatch.index('AMCloudAuthorizeFeature(@"import"')
        starter_at = import_dispatch.index("AMProjNativePackageImportStarter starter")
        self.assertGreater(authorize_at, starter_at)
        authorization_callback = import_dispatch[authorize_at:]
        self.assertIn("BOOL stillReady", authorization_callback)
        self.assertIn("startAuthorized();", authorization_callback)
        self.assertNotIn("amproj_importAuthorizedGeneration", EXPORT)

    def test_account_summary_renders_ios_membership_term(self):
        self.assertIn('self.account[@"iosAccess"]', CLOUD)
        self.assertIn('membershipPermanent', CLOUD)
        self.assertIn('iOS 月卡', CLOUD)
        self.assertIn('iOS 永久会员', CLOUD)


if __name__ == "__main__":
    unittest.main()
