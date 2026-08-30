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
MIGRATION = (ROOT / "build_865_migration_package.py").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")


class V865ProjectFlowSourceTests(unittest.TestCase):
    def test_865_packager_uses_version_neutral_cloud_contract(self):
        self.assertIn("cloud_payload_contract", MIGRATION)
        self.assertNotIn("import build_862_direct_package", MIGRATION)
        self.assertIn("cloud_payload_contract.py", WORKFLOW)

    def test_865_workflow_checks_active_staging_symbol_and_legacy_wrapper(self):
        self.assertIn('"_AMProjV865ProjectFlowStageDocument"', WORKFLOW)
        self.assertIn('"_AMProjV865ProjectFlowStageDocumentAsync"', WORKFLOW)
        self.assertIn('"_AMProjV865ProjectFlowQueueDownloadedProject"', WORKFLOW)

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
        self.assertIn("AMProjV865ProjectFlowStageDocumentAsync", FLOW_HEADER)
        self.assertIn("AMProjV865StagingQueue", FLOW)
        self.assertIn("UIDocumentInteractionController", FLOW)
        self.assertIn("presentOpenInMenuFromRect", FLOW)
        self.assertIn("openURL:stagedURL options:@{}", FLOW)
        self.assertIn("nativeRouteInFlight", FLOW)
        self.assertIn("native document URL route accepted", FLOW)
        self.assertIn("native document URL route declined", FLOW)
        self.assertIn("copyItemAtURL:source", FLOW)
        self.assertIn("dispatch_queue_create(\"com.amproj.865.project-staging\"", FLOW)
        self.assertIn('document.partial', FLOW)
        self.assertIn("moveItemAtURL:temporary", FLOW)
        self.assertIn("AMProjV865ProjectFlowQueueDownloadedProject", FLOW)
        self.assertNotIn("AMProjNativePackageImport", FLOW)
        self.assertNotIn("AMProjCallNative", FLOW)
        self.assertNotIn("objc_msgSend", FLOW)
        self.assertNotIn("selectedExportOptID", FLOW)
        self.assertNotIn("AMProjMainAddress", FLOW)

    def test_865_handoff_exposes_an_explicit_unverified_result_contract(self):
        self.assertIn("AMProjV865ProjectHandoffStatus", FLOW_HEADER)
        for status in ("staged", "route_accepted", "fallback_presented", "unverified", "failed"):
            self.assertIn(f'@"{status}"', FLOW)
        self.assertIn("AMProjV865ProjectFlowLastHandoffStatus", FLOW_HEADER)
        self.assertIn("AMProjV865ProjectFlowHandoffStatusString", FLOW_HEADER)
        self.assertIn('@"verified": @NO', FLOW)
        self.assertIn("openURL_acceptance_is_not_import_confirmation", FLOW)

    def test_865_handoff_breadcrumbs_are_atomic_and_retained_before_delayed_cleanup(self):
        self.assertIn("last-handoff.plist", FLOW)
        self.assertIn("handoff.plist", FLOW)
        self.assertIn("NSDataWritingAtomic", FLOW)
        self.assertIn("24 * 60 * 60 * NSEC_PER_SEC", FLOW)
        self.assertIn("AMProjV865ScheduleDirectoryCleanup", FLOW)
        self.assertIn("AMProjV865ProjectHandoffStatusFailed", FLOW)

    def test_865_async_staging_contains_an_exception_boundary_and_one_shot_completion(self):
        start = FLOW.index("void AMProjV865ProjectFlowStageDocumentAsync")
        end = FLOW.index("AMProjV865ProjectHandoffStatus AMProjV865ProjectFlowStageDocument", start)
        async_stage = FLOW[start:end]
        self.assertIn("__block BOOL completionDelivered = NO", async_stage)
        self.assertIn("if (completionDelivered) return", async_stage)
        self.assertIn("@try {", async_stage)
        self.assertIn("} @catch (NSException *exception)", async_stage)
        self.assertIn("AMProjV865ProjectHandoffStatusFailed", async_stage)
        self.assertIn('@"exception":', async_stage)
        self.assertIn('@"reason":', async_stage)
        self.assertIn("completeOnce(AMProjV865ProjectHandoffStatusFailed, error)", async_stage)

    def test_865_async_main_queue_route_has_an_exception_boundary(self):
        start = FLOW.index("void AMProjV865ProjectFlowStageDocumentAsync")
        end = FLOW.index("AMProjV865ProjectHandoffStatus AMProjV865ProjectFlowStageDocument", start)
        async_stage = FLOW[start:end]
        self.assertIn(
            "dispatch_async(dispatch_get_main_queue(), ^{\n                @try {",
            async_stage,
        )
        self.assertIn('@"phase": @"main_queue_route"', async_stage)
        self.assertIn("865 project handoff route exception", async_stage)
        self.assertIn("AMProjV865ScheduleDirectoryCleanup(", async_stage)

    def test_865_copy_and_completion_boundaries_clean_up_and_swallow_callback_exceptions(self):
        copy_start = FLOW.index("static NSURL *AMProjV865CopyDocument")
        copy_end = FLOW.index("@interface AMProjV865DocumentBroker", copy_start)
        copy_helper = FLOW[copy_start:copy_end]
        self.assertIn("@catch (NSException *exception)", copy_helper)
        self.assertIn("if (directory) [manager removeItemAtURL:directory error:nil]", copy_helper)
        completion_start = FLOW.index("static void AMProjV865CompleteStage")
        completion_end = FLOW.index("static void AMProjV865ScheduleStagedPresentation", completion_start)
        completion = FLOW[completion_start:completion_end]
        self.assertIn("@try", completion)
        self.assertIn("handoff completion exception", completion)

    def test_865_adapter_has_public_native_url_route_before_open_in_fallback(self):
        native_route = FLOW[FLOW.index("BOOL canUseNativeRoute") :]
        self.assertIn("openURL:stagedURL options:@{}", native_route)
        self.assertIn("if (success)", native_route)
        self.assertIn("AMProjV865PresentOpenInFallback", native_route)

    def test_865_handoff_resolves_a_current_visible_presenter_after_dismissal(self):
        handoff = FLOW[FLOW.index("static void AMProjV865ScheduleStagedPresentation") :]
        current = handoff.index("UIViewController *owner = AMProjV865ForegroundPresenter()")
        stale_guard = handoff.index("candidate.viewIfLoaded.window", current)
        self.assertLess(current, stale_guard)

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

    def test_865_navigation_forwards_project_export_to_native_implementation(self):
        navigation = EXPORT[
            EXPORT.index("static void hooked_navigationPush"):
            EXPORT.index("static void amproj_forwardPresentation")
        ]
        nonlegacy = navigation[
            navigation.index("if (!amproj_runtimeUsesLegacyImportHooks())"):
        ]
        self.assertIn("orig_navigationPush(self, _cmd, viewController, animated)", nonlegacy)
        self.assertNotIn("865.project_export_navigation_entry", navigation)
        self.assertNotIn("AMProjV865ProjectFlowIsProjectPackageController(viewController)", navigation)

        installer = EXPORT[
            EXPORT.index("static void amproj_installExportHooks"):
            EXPORT.index("if (!amproj_runtimeUsesLegacyImportHooks())",
                         EXPORT.index("static void amproj_installExportHooks"))
        ]
        self.assertIn('export_hooks.865_native_navigation', installer)
        self.assertIn('account_replacement_only', installer)
        self.assertNotIn("amproj_installShareExportHook", installer)

    def test_cloud_download_uses_865_handoff_and_862_stays_gated(self):
        cloud = EXPORT[EXPORT.index("static void amproj_importCloudPackage") :]
        self.assertIn("amproj_runtimeIsBuild865()", cloud)
        self.assertIn("AMProjV865ProjectFlowStageDocumentAsync", cloud)
        self.assertIn("AMProjV865ProjectHandoffStatusStaged", cloud)
        self.assertIn('@"handoff_status":', cloud)
        self.assertIn('@"import_confirmed": @NO', cloud)
        self.assertNotIn("AMProjV865ProjectFlowQueueDownloadedProject", cloud)
        self.assertIn('legacy_862_bridge": @NO', cloud)
        self.assertIn("amproj_runtimeUsesLegacyImportHooks()", cloud)
        self.assertIn("amproj_log865LegacyPathDisabled", cloud)
        self.assertIn("AMProjIncomingCleanupURL", cloud)

    def test_bootstrap_registers_one_cloud_handler_for_both_verified_lanes(self):
        bootstrap = EXPORT[EXPORT.index("static void amproj_bootstrapAfterLaunch") :]
        handler = bootstrap[bootstrap.index("AMCloudSyncInstallAsync(") :]
        self.assertIn("AMCloudSyncInstallAsync(", handler)
        self.assertIn(
            "amproj_importCloudPackage(URL, filename, cleanupURL, completion);",
            handler,
        )
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
