import re
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


class CloudSyncSourceTests(unittest.TestCase):
    def test_cloud_build_is_isolated_from_release_and_debug_targets(self):
        cloud_rule = MAKEFILE.split("AMProjExportCloud.dylib:", 1)[1].split(
            "AMProjExportDebug.dylib:", 1
        )[0]
        self.assertIn("-DAMPROJ_CLOUD_SYNC=1", cloud_rule)
        self.assertIn("AMCloudSync.m", cloud_rule)
        self.assertIn("-framework Security", cloud_rule)
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
        self.assertIn("showAuthenticationFrom", CLOUD)
        self.assertIn("AMCloudAccountViewController", CLOUD)

    def test_native_my_account_route_is_replaced_before_presentation_or_push(self):
        for symbol in (
            "AMCloudSyncHandleNativeAccountPresentation",
            "AMCloudSyncHandleNativeAccountPush",
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
        handler = CLOUD.split(
            "BOOL AMCloudSyncHandleNativeAccountPresentation", 1
        )[1].split("BOOL AMCloudSyncHandleNativeAccountPush", 1)[0]
        self.assertIn("(void)completion;", handler)
        self.assertIn("[manager showAccountFrom:presenter];", handler)
        self.assertNotIn("[completion copy]", handler)
        self.assertNotIn("originalCompletion", handler)
        self.assertIsNone(re.search(r"\bcompletion\s*\(", handler))
        self.assertNotIn("presentationCompletion", CLOUD)
        dispatch = CLOUD.split(
            "__weak UINavigationController *weakNavigationController", 1
        )[1].split("return YES;", 1)[0]
        self.assertLess(
            dispatch.index("dispatch_async"),
            dispatch.index("navigation.visibleViewController"),
        )

        presentation = EXPORT.split("static void hooked_presentVC", 1)[1]
        presentation = presentation.split("#if AMPROJ_DEBUG", 1)[0]
        replacement = presentation.index(
            "AMCloudSyncHandleNativeAccountPresentation"
        )
        native_forward = presentation.index("orig_presentVC(self", replacement)
        self.assertLess(replacement, native_forward)

        navigation = EXPORT.split("static void hooked_navigationPush", 1)[1]
        navigation = navigation.split("static void amproj_forwardPresentation", 1)[0]
        replacement = navigation.index("AMCloudSyncHandleNativeAccountPush")
        native_push = navigation.index("orig_navigationPush", replacement)
        self.assertLess(replacement, native_push)

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


if __name__ == "__main__":
    unittest.main()
