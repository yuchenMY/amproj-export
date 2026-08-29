import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORT = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
FLOW_HEADER = (ROOT / "AMProjExport" / "AMProjV865ProjectFlow.h").read_text(
    encoding="utf-8"
)
FLOW = (ROOT / "AMProjExport" / "AMProjV865ProjectFlow.m").read_text(
    encoding="utf-8"
)
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")


class V865ProjectFlowSourceTests(unittest.TestCase):
    def test_default_865_outputs_keep_the_feature_libraries_separate(self):
        all_rule = MAKEFILE.split("all:", 1)[1].split("\n", 1)[0]
        self.assertIn("AMProjExport.dylib", all_rule)
        self.assertIn("AMHomeUI.dylib", all_rule)
        self.assertNotIn("AMProjExportCloud.dylib", all_rule)

        cloud_rule = MAKEFILE.split("AMProjExport.dylib:", 1)[1].split(
            "AMProjExportOffline.dylib:", 1
        )[0]
        self.assertIn("AMProjV865ProjectFlow.m", cloud_rule)
        self.assertIn("-install_name @rpath/AMProjExport.dylib", cloud_rule)
        self.assertNotIn("AMHomeUI.m", cloud_rule)

    def test_865_adapter_has_an_exact_runtime_gate(self):
        gate = FLOW[FLOW.index("BOOL AMProjV865ProjectFlowIsRuntimeSupported") :]
        self.assertIn('AMProjV865Version = @"6.2.58"', FLOW)
        self.assertIn('AMProjV865Build = @"865"', FLOW)
        self.assertIn('CFBundleShortVersionString', gate)
        self.assertIn('CFBundleVersion', gate)
        self.assertIn("[version isEqualToString:AMProjV865Version]", gate)
        self.assertIn("[build isEqualToString:AMProjV865Build]", gate)

    def test_865_adapter_uses_public_document_handoff_only(self):
        # UIKit's document broker is an implementation detail; the header
        # intentionally exposes only the small C-facing adapter contract.
        self.assertIn("AMProjV865ProjectFlowPresentDocument", FLOW_HEADER)
        self.assertIn("UIDocumentInteractionController", FLOW)
        self.assertIn("presentOpenInMenuFromRect", FLOW)
        self.assertIn("copyItemAtURL:source", FLOW)
        self.assertIn('document.partial', FLOW)
        self.assertIn("moveItemAtURL:temporary", FLOW)
        self.assertIn("AMProjV865ProjectFlowQueueDownloadedProject", FLOW)
        self.assertNotIn("AMProjNativePackageImport", FLOW)
        self.assertNotIn("AMProjCallNative", FLOW)
        self.assertNotIn("objc_msgSend", FLOW)
        self.assertNotIn("selectedExportOptID", FLOW)
        self.assertNotIn("AMProjMainAddress", FLOW)

    def test_865_adapter_matches_only_the_verified_package_controller(self):
        self.assertIn('AlightMotion.ShareProjectPackageVC', FLOW)
        self.assertIn('_TtC12AlightMotion21ShareProjectPackageVC', FLOW)
        self.assertIn("AMProjV865ProjectFlowIsRuntimeSupported()", FLOW)
        self.assertNotIn('hasSuffix:@"ShareProjectPackageVC"', FLOW)

    def test_export_source_routes_865_package_presentation_to_adapter(self):
        self.assertIn('#import "AMProjV865ProjectFlow.h"', EXPORT)
        self.assertIn("AMProjV865ProjectFlowIsProjectPackageController", EXPORT)
        self.assertIn('amproj_logCriticalEvent(@"865.project_export_entry"', EXPORT)
        self.assertIn('destination": @"share_sheet"', EXPORT)
        self.assertIn('native_private_abi": @NO', EXPORT)
        self.assertIn("amproj_startDirectExport(", EXPORT)

    def test_cloud_download_uses_865_handoff_and_862_stays_gated(self):
        cloud = EXPORT[EXPORT.index("static BOOL amproj_importCloudPackage") :]
        self.assertIn("amproj_runtimeIsBuild865()", cloud)
        self.assertIn("AMProjV865ProjectFlowQueueDownloadedProject", cloud)
        self.assertIn('legacy_862_bridge": @NO', cloud)
        self.assertIn("amproj_runtimeUsesLegacyImportHooks()", cloud)
        self.assertIn("amproj_log865LegacyPathDisabled", cloud)
        self.assertIn("AMProjIncomingCleanupURL", cloud)

    def test_bootstrap_registers_one_cloud_handler_for_both_verified_lanes(self):
        bootstrap = EXPORT[EXPORT.index("static void amproj_bootstrapAfterLaunch") :]
        handler = bootstrap[bootstrap.index("AMCloudSyncInstall(") :]
        self.assertIn("amproj_importCloudPackage(URL, filename, cleanupURL)", handler)
        self.assertNotIn('cloud_project_import")', handler)
        self.assertIn("AMProjV865ProjectFlowInstall();", bootstrap)

    def test_865_release_does_not_install_a_global_action_observer(self):
        self.assertNotIn("sendAction:to:from:forEvent:", EXPORT)
        self.assertNotIn("sendAction:to:from:forEvent:", FLOW)

    def test_865_release_keeps_native_document_callbacks_unowned(self):
        self.assertIn("AMProjV865ProjectFlowInstall", EXPORT)
        self.assertIn("Build 865 owns its own document lifecycle", EXPORT)
        self.assertIn("amproj_attachNativeXMLPickerProxy(controller)", EXPORT)
        self.assertIn("amproj_log865LegacyPathDisabled(@\"native_xml_picker_proxy\")", EXPORT)
        self.assertIn("AMProjRegisterNativePackageImportStarter(nil);", EXPORT)


if __name__ == "__main__":
    unittest.main()
