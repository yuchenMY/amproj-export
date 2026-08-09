import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLOUD = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")
HEADER = (ROOT / "AMProjExport" / "AMCloudSync.h").read_text(encoding="utf-8")
EXPORT = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")


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

    def test_export_share_exposes_cloud_upload_activity(self):
        self.assertIn("AMCloudSyncUploadActivities", HEADER)
        self.assertIn("AMCloudSyncUploadActivities(fileURL", EXPORT)
        self.assertIn("applicationActivities:cloudActivities", EXPORT)
        self.assertIn('return @"上传云工程"', CLOUD)


if __name__ == "__main__":
    unittest.main()
