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


class CloudSyncSourceTests(unittest.TestCase):
    def test_cloud_build_is_isolated_from_release_and_debug_targets(self):
        cloud_rule = MAKEFILE.split("AMProjExportCloud.dylib:", 1)[1].split(
            "AMProjExportDebug.dylib:", 1
        )[0]
        self.assertIn("-DAMPROJ_CLOUD_SYNC=1", cloud_rule)
        self.assertIn("AMCloudSync.m", cloud_rule)
        self.assertIn("AMCloudPlugins.m", cloud_rule)
        self.assertIn("AMEditorCustomization.m", cloud_rule)
        self.assertIn("-framework Security", cloud_rule)
        self.assertIn("-framework WebKit", cloud_rule)
        self.assertIn("#if AMPROJ_CLOUD_SYNC", EXPORT)

    def test_editor_buttons_are_customized_only_on_project_edit_controller(self):
        self.assertIn('@"AlightMotion.ProjectEditVC"', EDITOR)
        self.assertIn('objc_getClass("_TtC12AlightMotion13ProjectEditVC")', EDITOR)
        self.assertIn('@"quickActionsButton"', EDITOR)
        self.assertIn("quickActionsButton.hidden = YES", EDITOR)
        self.assertIn("quickActionsButton.userInteractionEnabled = NO", EDITOR)
        self.assertIn('@"addLibraryButton"', EDITOR)
        self.assertIn('@"autfeng_add_layer_button"', EDITOR)
        self.assertIn("UIImageRenderingModeAlwaysOriginal", EDITOR)
        self.assertIn("@selector(viewDidLayoutSubviews)", EDITOR)
        self.assertNotIn("class_getInstanceMethod(UIButton.class", EDITOR)
        self.assertIn("AMEditorCustomizationInstall();", CLOUD)

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

    def test_cloud_plugins_support_per_item_incremental_delivery(self):
        for symbol in (
            "AMCloudPluginsInstallItemArchive",
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
        self.assertIn('@"protocol_version": @2', PLUGINS)
        self.assertIn('@"catalog_revision"', PLUGINS)
        self.assertIn('@"plugins": statePlugins', PLUGINS)
        self.assertIn("AMCloudPluginsCopyCatalogDirectory", PLUGINS)
        self.assertIn("AMCloudPluginsBundledEffectsURL", PLUGINS)
        self.assertIn("replaceExisting", PLUGINS)
        self.assertIn("Plugin dependency conflict", PLUGINS)
        self.assertIn("installed.count == plugins.count", CLOUD)

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

    def test_bundle_hook_overrides_builtin_xml_and_appends_new_effects(self):
        for selector in (
            "URLsForResourcesWithExtension:subdirectory:",
            "URLForResource:withExtension:subdirectory:",
            "URLForResource:withExtension:",
            "pathsForResourcesOfType:inDirectory:",
            "pathForResource:ofType:inDirectory:",
            "pathForResource:ofType:",
        ):
            self.assertIn(selector, PLUGINS)
        self.assertIn('caseInsensitiveCompare:@"BuiltinEffects"', PLUGINS)
        self.assertIn("remaining[key] = URL", PLUGINS)
        self.assertIn("[merged addObject:replacement ?: URL]", PLUGINS)
        self.assertIn("[merged addObjectsFromArray:newURLs]", PLUGINS)
        self.assertIn("contentsOfDirectoryAtURL", PLUGINS)
        self.assertNotIn("enumeratorAtURL", PLUGINS)
        self.assertIn("AMCloudPluginsRelativeDirectory", PLUGINS)
        self.assertIn("AMCloudPluginsBuiltinEffectsRootURL", PLUGINS)
        self.assertIn("AMCloudBundleHookGuardKey", PLUGINS)
        self.assertIn("AMCloudSyncInstallPluginHooksEarly();", EXPORT)

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

    def test_download_is_verified_before_reusing_v44_import_lane(self):
        self.assertIn("downloadTaskWithRequest:request", CLOUD)
        self.assertIn("caseInsensitiveCompare:expectedSHA", CLOUD)
        self.assertIn("response.expectedContentLength", CLOUD)
        self.assertIn("weakSelf.importHandler(URL, filename, cleanupURL)", CLOUD)
        self.assertIn("removeItemAtURL:cleanupURL", CLOUD)
        self.assertIn('URL, @"cloud_download", options, &prepared', EXPORT)
        self.assertIn('AMProjIncomingCleanupURL', EXPORT)

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
        self.assertIn('[body[@"type"] isEqualToString:@"profile"]', CLOUD)
        self.assertIn("[self.manager applyAccountProfile:profile]", CLOUD)
        self.assertIn("[self clearAccountAvatar]", CLOUD)

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
        catch_block = CLOUD.split("} @catch (NSException *exception)", 1)[1].split(
            "- (void)beginUploadFile", 1
        )[0]
        self.assertIn('AMCloudDiagnostic(@"cloud.account.exception"', catch_block)
        self.assertNotIn("showError:", catch_block)

    def test_export_share_exposes_cloud_upload_activity(self):
        self.assertIn("AMCloudSyncUploadActivities", HEADER)
        self.assertIn("AMCloudSyncUploadActivities(fileURL", EXPORT)
        self.assertIn("applicationActivities:cloudActivities", EXPORT)
        self.assertIn('return @"保存到 AutFeng Hub"', CLOUD)

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
        self.assertIn('@"保存到 AutFeng Hub"', EXPORT)
        self.assertIn('@"选择性保存为云工程"', EXPORT)
        self.assertIn('@"保存到 AutFeng Hub"', CLOUD)
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


if __name__ == "__main__":
    unittest.main()
