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
        self.assertIn("-framework Security", cloud_rule)
        self.assertIn("-framework WebKit", cloud_rule)
        self.assertIn("#if AMPROJ_CLOUD_SYNC", EXPORT)

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

    def test_cloud_plugins_are_downloaded_installed_and_removed_automatically(self):
        for symbol in (
            "AMCloudPluginsInstallBundleHooks",
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
        self.assertIn('valueForHTTPHeaderField:@"X-AM-Plugin-SHA256"', CLOUD)
        self.assertIn("AMCloudPluginsRemoveAllIf", CLOUD)
        self.assertIn("permission_disabled", CLOUD)
        self.assertNotIn("plugin picker", CLOUD.lower())

    def test_stale_authenticated_responses_cannot_delete_a_new_token(self):
        self.assertIn("AMCloudInvalidateTokenForRequest", CLOUD)
        self.assertIn('valueForHTTPHeaderField:@"Authorization"', CLOUD)
        self.assertIn("AMCloudInvalidateToken(logoutToken)", CLOUD)
        self.assertIn("AMCloudInvalidateToken(activationToken)", CLOUD)
        self.assertIn("AMCloudAuthPerformSync", CLOUD)
        self.assertIn("AMCloudDeleteTokenMatching(token, YES)", CLOUD)
        self.assertIn("AMCloudPluginsSetAuthorizationGeneration", CLOUD)
        self.assertIn("AMCloudCleanupPluginsForAuth(nil, generation, hadToken)", CLOUD)
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
        self.assertIn("AMCloudCommitIfAuthMatches", CLOUD)
        self.assertIn("authorizationGeneration", PLUGINS)
        self.assertIn('@"authorization_key"', PLUGINS)

    def test_bundle_hook_overrides_builtin_xml_and_appends_new_effects(self):
        for selector in (
            "URLsForResourcesWithExtension:subdirectory:",
            "URLForResource:withExtension:subdirectory:",
            "pathsForResourcesOfType:inDirectory:",
            "pathForResource:ofType:inDirectory:",
        ):
            self.assertIn(selector, PLUGINS)
        self.assertIn('caseInsensitiveCompare:@"BuiltinEffects"', PLUGINS)
        self.assertIn("remaining[key] = URL", PLUGINS)
        self.assertIn("[merged addObject:replacement ?: URL]", PLUGINS)
        self.assertIn("[merged addObjectsFromArray:newURLs]", PLUGINS)
        self.assertIn("contentsOfDirectoryAtURL", PLUGINS)
        self.assertNotIn("enumeratorAtURL", PLUGINS)
        self.assertIn("AMCloudPluginsRelativeDirectory", PLUGINS)
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
        self.assertIn('return @"上传云工程"', CLOUD)

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
