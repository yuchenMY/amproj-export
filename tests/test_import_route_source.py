import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
BRIDGE_SOURCE = (ROOT / "AMProjExport" / "AMProjNativeImportBridge.m").read_text(
    encoding="utf-8"
)
BRIDGE_HEADER = (ROOT / "AMProjExport" / "AMProjNativeImportBridge.h").read_text(
    encoding="utf-8"
)
BRIDGE_ASSEMBLY = (ROOT / "AMProjExport" / "AMProjNativeImportBridge.S").read_text(
    encoding="utf-8"
)
STABILITY_ASSEMBLY = (
    ROOT / "AMProjExport" / "AMProjStabilityContract.S"
).read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
DEBUG_TRANSPORT_SOURCE = (
    ROOT / "AMProjExport" / "AMDebugTransport.m"
).read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(
    encoding="utf-8"
)
BUILD_SCRIPT = (ROOT / "build_and_inject.bat").read_text(encoding="utf-8")
SHARE_EXTENSION_SOURCE = (
    ROOT / "AMProjShareExtension" / "AMProjShareViewController.m"
).read_text(encoding="utf-8")


def source_body(source: str, signature: str, next_signature: str) -> str:
    start = source.rindex(signature)
    end = source.index(next_signature, start)
    return source[start:end]


def function_body(signature: str, next_signature: str) -> str:
    return source_body(SOURCE, signature, next_signature)


class ImportLaneModel:
    """Executable model of the main-thread package/XML lane arbitration."""

    def __init__(self):
        self.active = None
        self.packages = []
        self.xml_files = []

    def enqueue_package(self, name):
        self.packages.append(name)
        self.schedule()

    def enqueue_xml(self, name):
        self.xml_files.append(name)
        self.schedule()

    def schedule(self):
        if self.active is not None:
            return
        if self.packages:
            self.active = ("package", self.packages.pop(0))
        elif self.xml_files:
            self.active = ("xml", self.xml_files.pop(0))

    def finish(self):
        self.active = None
        self.schedule()


class TemplateAbsenceModel:
    def __init__(self):
        self.exact_cycles = 0
        self.stable = False
        self.verified = False

    def observe(self, exact):
        if exact:
            self.exact_cycles += 1
        else:
            self.exact_cycles = 0
            self.stable = False
            self.verified = False
        if self.exact_cycles >= 6:
            self.stable = True

    def final_check(self, exact):
        self.verified = self.stable and exact
        if not exact:
            self.observe(False)


class NativeXMLMissingMediaRaceModel:
    """Models the one-shot bridge completion around AM's non-fatal XML alert."""

    def __init__(self, kind="xml"):
        self.kind = kind
        self.integrity_verified = True
        self.status4_observed = False
        self.status4_returned = False
        self.completion_source = None

    def observe_status4(self):
        self.status4_observed = True

    def return_status4_handler(self):
        self.status4_returned = True

    def suppressible_missing_media(self, imported_anyway=True):
        return (
            self.kind == "xml"
            and self.integrity_verified
            and self.status4_observed
            and imported_anyway
        )

    def finish(self, source):
        if self.completion_source is not None:
            return False
        self.completion_source = source
        return True

    def finish_suppressed_alert(self):
        if not self.status4_returned:
            return False
        return self.finish("suppressed_alert")

    def finish_native_thunk(self):
        return self.finish("native_thunk")


class LaunchUserActivityFilterModel:
    DICTIONARY_KEY = "UIApplicationLaunchOptionsUserActivityDictionaryKey"
    ACTIVITY_KEY = "UIApplicationLaunchOptionsUserActivityKey"
    TYPE_KEY = "UIApplicationLaunchOptionsUserActivityTypeKey"

    @classmethod
    def filter(cls, launch_options, project_activity):
        filtered = dict(launch_options)
        nested = dict(filtered.get(cls.DICTIONARY_KEY, {}))
        removed_top = filtered.get(cls.ACTIVITY_KEY) == project_activity
        if removed_top:
            filtered.pop(cls.ACTIVITY_KEY, None)
            filtered.pop(cls.TYPE_KEY, None)
        removed_nested = False
        remaining_nested_type = None
        for key, value in list(nested.items()):
            if key == cls.TYPE_KEY:
                continue
            if value == project_activity:
                nested.pop(key, None)
                removed_nested = True
            elif isinstance(value, tuple) and len(value) > 1:
                remaining_nested_type = value[1]
        if removed_nested:
            had_nested_type = cls.TYPE_KEY in nested
            nested.pop(cls.TYPE_KEY, None)
            if had_nested_type and remaining_nested_type:
                nested[cls.TYPE_KEY] = remaining_nested_type
        if nested:
            filtered[cls.DICTIONARY_KEY] = nested
        else:
            filtered.pop(cls.DICTIONARY_KEY, None)
        return filtered


class NativeImportRouteSourceTests(unittest.TestCase):
    def test_release_version_metadata_is_consistent(self):
        self.assertIn('kAMProjPluginVersion = @"44";', SOURCE)
        self.assertIn('kAMDebugPluginVersion = @"44";', DEBUG_TRANSPORT_SOURCE)
        self.assertNotIn("AMProj v44", SOURCE)
        self.assertIn("AMProj ·", SOURCE)
        self.assertNotIn("AMProj v31", SOURCE)
        self.assertNotIn("AMProj v29", SOURCE)
        self.assertNotIn("AMProj v28", SOURCE)
        self.assertNotIn("AMProj v23", SOURCE)
        self.assertIn("AMProjExport-v${{ env.AMPROJ_RELEASE_VERSION }}-dylibs", WORKFLOW)
        self.assertIn("AMPROJ_RELEASE_VERSION: '44'", WORKFLOW)
        self.assertIn('"commit": os.environ["GITHUB_SHA"]', WORKFLOW)
        self.assertIn('"run_id": os.environ["GITHUB_RUN_ID"]', WORKFLOW)
        self.assertIn('"sha256": {', WORKFLOW)
        self.assertIn("build-metadata.json", WORKFLOW)
        self.assertIn("am_v77_ownbase_directCloud_LCSign.ipa", README)
        self.assertIn("build_862_direct_package.py", README)
        self.assertIn("am_v77_ownbase_directCloud_LCSign.ipa", BUILD_SCRIPT)
        self.assertIn("CFBundleVersion=862", README)
        self.assertIn("build_862_direct_package.py", BUILD_SCRIPT)
        self.assertNotIn("--zsign", BUILD_SCRIPT)
        self.assertNotIn("inject_dylib.py", BUILD_SCRIPT)
        self.assertNotIn("--bundle-version", BUILD_SCRIPT)
        self.assertIn("01b73017-1a6e-3b17-8f59-c27462dea563", README)
        self.assertIn(
            "37054D3ED49DEBF44D6534DAA6B266888A41AA5068A4FFD8FA884EF5EC4999D4",
            README,
        )
        self.assertNotIn("--share-extension", BUILD_SCRIPT)
        self.assertNotIn("--app-group-id", BUILD_SCRIPT)
        self.assertNotIn("AMProjShareExtension", BUILD_SCRIPT)
        self.assertNotIn("AMProjShareExtension", WORKFLOW)
        self.assertIn("稳定包只使用主 App 的文档 URL/文件选择器链路", README)
        self.assertIn("AMProjExport.dylib", MAKEFILE)
        self.assertIn("AMProjExport/AMProjExport.dylib", WORKFLOW)
        self.assertNotIn("AMProjExportCloud.dylib", WORKFLOW)
        self.assertIn("cloud_payload_contract.py", WORKFLOW)
        self.assertIn("from cloud_payload_contract import verify_cloud_stability_contract", WORKFLOW)
        self.assertIn('config[@"BuildIdentifier"]', DEBUG_TRANSPORT_SOURCE)
        self.assertIn('kAMDebugPluginVariant = @"cloud"', DEBUG_TRANSPORT_SOURCE)
        self.assertIn('kAMDebugPluginVariant = @"debug"', DEBUG_TRANSPORT_SOURCE)
        self.assertIn('@"variant": kAMDebugPluginVariant', DEBUG_TRANSPORT_SOURCE)
        self.assertIn('@"build_id": self.buildIdentifier', DEBUG_TRANSPORT_SOURCE)
        self.assertIn('@"bundle_version": bundleVersion', SOURCE)
        self.assertIn('@"supports_opening_documents_in_place"', SOURCE)
        self.assertIn('@"supports_document_browser"', SOURCE)

    def test_cloud_variant_reports_core_events_without_debug_instrumentation(self):
        self.assertIn("-DAMPROJ_TELEMETRY=1", MAKEFILE)
        self.assertIn("#if AMPROJ_DEBUG || AMPROJ_TELEMETRY", SOURCE)
        self.assertIn("#elif AMPROJ_TELEMETRY", SOURCE)
        self.assertIn("Loading v44-cloud", SOURCE)
        self.assertIn("#if AMPROJ_TELEMETRY", DEBUG_TRANSPORT_SOURCE)
        self.assertIn("kAMDebugPluginVariant = @\"cloud\"", DEBUG_TRANSPORT_SOURCE)
        self.assertIn("kAMDebugDefaultBuildIdentifier = @\"v44-cloud\"", DEBUG_TRANSPORT_SOURCE)
        self.assertIn("(void)defaultMode", DEBUG_TRANSPORT_SOURCE)
        self.assertIn("_discoveryEnabled = NO", DEBUG_TRANSPORT_SOURCE)
        self.assertIn("- (void)pollCommands", DEBUG_TRANSPORT_SOURCE)
        self.assertIn("- (BOOL)uploadArtifactData", DEBUG_TRANSPORT_SOURCE)

        debug_hooks = function_body(
            "static void amproj_installExportHooks",
            "static void amproj_removeBootstrapObservers",
        )
        self.assertIn("#if AMPROJ_DEBUG", debug_hooks)
        self.assertNotIn("#if AMPROJ_TELEMETRY", debug_hooks)

    def test_share_extension_accepts_amproj_and_xml_inputs(self):
        self.assertIn('kAMProjXMLTypeIdentifier = @"public.xml"', SHARE_EXTENSION_SOURCE)
        self.assertIn('isEqualToString:@"xml"', SHARE_EXTENSION_SOURCE)
        self.assertIn('@"public.xml"', SHARE_EXTENSION_SOURCE)
        self.assertIn('declaredXML ? @"xml" : @"amproj"', SHARE_EXTENSION_SOURCE)
        share_scan = function_body(
            "static BOOL amproj_scanShareInboxNow",
            "static void amproj_scanLocalImportInboxes",
        )
        self.assertIn("supportedShareExtensionName", share_scan)
        self.assertIn('isEqualToString:@"xml"', share_scan)

    def test_paywall_filter_requires_multiple_subscription_markers(self):
        self.assertIn("paywall.detected", SOURCE)
        self.assertIn("paywall.dismissed", SOURCE)
        self.assertIn("选择一个套餐", SOURCE)
        self.assertIn("已经购买", SOURCE)
        self.assertIn("每周", SOURCE)
        self.assertIn("continue", SOURCE)
        self.assertIn("amproj_schedulePaywallScan", SOURCE)
        self.assertIn("did_become_active", SOURCE)
        will_finish = SOURCE[
            SOURCE.index('addObserverForName:@"UIApplicationWillFinishLaunchingNotification"') :
            SOURCE.index("amproj_didLaunchObserver =", SOURCE.index(
                'addObserverForName:@"UIApplicationWillFinishLaunchingNotification"'
            ))
        ]
        self.assertIn("amproj_installPresentationHook();", will_finish)
        # A generic hosting controller must not be dismissed by class name alone.
        self.assertIn("BOOL markerMatch = plan && continueMarker", SOURCE)
        self.assertIn("if ((!markerMatch && !startupLoadingFallback) || !loading) return NO;", SOURCE)
        self.assertIn("UIActivityIndicatorView", SOURCE)
        self.assertIn("accessibilityActivate", SOURCE)
        self.assertIn("accessibilityElements", SOURCE)
        self.assertIn("paywall.scan_root", SOURCE)
        self.assertIn("amproj_armPaywallStartupFallback", SOURCE)
        self.assertIn("startupLoadingFallback", SOURCE)
        self.assertNotIn("HideLoadingInView", SOURCE)
        self.assertNotIn("startup_loading.skip_pass", SOURCE)
        self.assertNotIn("SkipLoadingScreen", SOURCE)
        self.assertNotIn("hide_dedicated_window", SOURCE)
        self.assertNotIn("amproj_alternateVisibleWindow", SOURCE)
        self.assertIn("[presentingController dismissViewControllerAnimated", SOURCE)
        self.assertIn('gone ? @"paywall.dismissed" : @"paywall.dismiss_failed"', SOURCE)
        self.assertIn("ShareProjectPackageVC", SOURCE)

        dismiss = function_body(
            "static void amproj_dismissDetectedPaywallFrom",
            "static void amproj_scanVisiblePaywall",
        )
        self.assertIn("[presentingController dismissViewControllerAnimated", dismiss)
        self.assertNotIn("paywallWindow.hidden = YES", dismiss)
        self.assertNotIn("makeKeyAndVisible", dismiss)
        self.assertIn("startupTransactionOwnsPaywall", dismiss)
        self.assertIn("startup_loading.legacy_scan_deferred", dismiss)

    def test_global_md_loading_scan_is_replaced_by_state_machine(self):
        self.assertNotIn("HideLoadingInView", SOURCE)
        self.assertNotIn("SkipLoadingScreenOnce", SOURCE)
        self.assertNotIn("SkipLoadingScreen", SOURCE)
        self.assertNotIn("startup_loading.skip_pass", SOURCE)
        self.assertIn("AMProjStartupPaywallState", SOURCE)

    def test_stalled_startup_paywall_establishes_then_dismisses(self):
        state_machine = function_body(
            "typedef NS_ENUM(NSUInteger, AMProjStartupPresentationDecision)",
            "static NSString* amproj_projectTitleRecursive",
        )
        for symbol in (
            "PaywallLoadingScreenView",
            "CloudCardsTiersPaywallView",
            "NodeHostingControllerWithCustomStatusbarContent",
            "AMProjStartupPresentationDecisionTrackOuter",
            "AMProjStartupPresentationDecisionSuppress",
            "presenter == amproj_startupPaywallOuter",
            "presenter == amproj_startupPaywallSuppressedRetryOuter",
            "dismissViewControllerAnimated:NO",
            "500 * NSEC_PER_MSEC",
            "amproj_startupPaywallDismissFailures >= 3",
            "elapsed >= 3.0",
            '@"\u7ee7\u7eed\u8fdb\u5165"',
            "mainWindow addSubview:button",
            "mainWindow addSubview:closeButton",
            "amproj_foregroundApplicationWindow",
            "amproj_startStartupPaywallRescue",
            "amproj_findExactStartupPaywall",
            "if (paywallWindow) mainWindow = paywallWindow;",
            "mainNCVisible && mainVCVisible",
            "amproj_startupPaywallTailSuppressionUntil",
            "presenter == amproj_startupPaywallPresenter",
        ):
            self.assertIn(symbol, state_machine)
        for event in (
            "presentation_seen",
            "outer_presented",
            "dismiss_requested",
            "dismiss_verified",
            "main_visible",
        ):
            self.assertIn(f'@"{event}"', state_machine)
        self.assertIn('fields[@"state"]', state_machine)
        self.assertIn('fields[@"failure_count"]', state_machine)
        self.assertIn('fields[@"failure"]', state_machine)
        self.assertNotIn("window.hidden = YES", state_machine)
        self.assertNotIn("[[UIWindow alloc]", state_machine)
        self.assertNotIn("makeKey", state_machine)
        self.assertNotIn("rootViewController =", state_machine)
        self.assertNotIn("reconcileRetry", state_machine)
        self.assertIn(
            "amproj_startupPaywallTailSuppressionUntil = "
            "CFAbsoluteTimeGetCurrent() + 1.5",
            state_machine,
        )

        verify = source_body(
            state_machine,
            "static void amproj_verifyStartupPaywallDismiss",
            "static void amproj_requestStartupPaywallDismiss",
        )
        fallback = verify.index("amproj_showStartupPaywallFallbackButton(failure)")
        retry = verify.index("amproj_reconcileStartupPaywall", fallback)
        self.assertIn("return;", verify[fallback:retry])

        reconcile = source_body(
            state_machine,
            "static void amproj_reconcileStartupPaywall",
            "static AMProjStartupPresentationDecision",
        )
        stable_fallback = reconcile.index(
            "amproj_startupPaywallState == "
            "AMProjStartupPaywallStateFallbackVisible"
        )
        auto_dismiss = reconcile.index(
            "amproj_requestStartupPaywallDismiss", stable_fallback
        )
        self.assertIn("return;", reconcile[stable_fallback:auto_dismiss])

        arm = function_body(
            "static void amproj_armPaywallStartupFallback",
            "static BOOL amproj_paywallContentContainsAny",
        )
        self.assertIn("amproj_startupPaywallSuppressionUntil = now + 30.0", arm)
        self.assertIn("AMProjStartupPaywallStateArmed", arm)

        present = function_body("static void hooked_presentVC", "#if AMPROJ_DEBUG")
        self.assertIn("amproj_startupPaywallPresentationDecision", present)
        self.assertIn("AMProjStartupPresentationDecisionTrackOuter", present)
        self.assertIn("amproj_markStartupPaywallOuterPresented", present)
        self.assertIn("presentation_completion", present)
        self.assertIn("dispatch_async(dispatch_get_main_queue(), completion)", present)
        native_alert = present.index("!amproj_hasPluginManagedImportAlertContext()")
        native_original = present.index(
            "orig_presentVC(self, _cmd, controller, animated, completion)",
            native_alert,
        )
        decision = present.index("amproj_startupPaywallPresentationDecision")
        original = present.rindex(
            "orig_presentVC(self, _cmd, controller, animated, completion)"
        )
        tracked_original = present.index(
            "orig_presentVC(self, _cmd, controller, animated, trackedCompletion)"
        )
        self.assertLess(native_alert, native_original)
        self.assertLess(native_original, decision)
        self.assertLess(decision, tracked_original)
        self.assertLess(tracked_original, original)
        self.assertNotIn("amproj_scheduleLatePaywallLoadingBypass", SOURCE)
        self.assertNotIn("startup_loading.controller_pass", SOURCE)

    def test_package_flow_predicate_is_narrow(self):
        body = function_body(
            "static BOOL amproj_isPackageControllerName",
            "static BOOL amproj_isSharePackageController",
        )
        self.assertIn("ShareProjectPackageVC", body)
        self.assertIn('hasSuffix:@"ShareProjectPackageVC"', body)
        self.assertNotIn('containsString:@"Package"]', body)

        presented = function_body(
            "static BOOL amproj_isSharePackageController",
            "static BOOL amproj_hasPackageController",
        )
        self.assertIn("UINavigationController.class", presented)
        self.assertIn("visibleViewController", presented)
        self.assertNotIn("childViewControllers", presented)
        self.assertNotIn("presentedViewController", presented)
        self.assertNotIn("Recursive", presented)

    def test_release_cloud_disables_native_activity_sheet_export_fallback(self):
        body = function_body(
            "static id hooked_initWithItems",
            "static BOOL amproj_isIPAFireWelcome",
        )
        self.assertIn("#if AMPROJ_DEBUG", body)
        self.assertIn(
            "BOOL isPackageExport = AMProjV44ReleaseNativeActivityFallbackEnabled();",
            body,
        )
        release_branch = body[body.index("#else") : body.index("#endif")]
        self.assertNotIn("amproj_hasPackageController", release_branch)
        self.assertNotIn("amproj_hasSupportedItem", release_branch)
        self.assertIn("kAMProjCloudStabilityContract", SOURCE)
        self.assertIn(
            "v44-stable:semantic-option-7,no-native-activity-fallback", SOURCE
        )

    def test_v44_stability_contract_assembly_is_exact(self):
        instructions = [
            line.strip()
            for line in STABILITY_ASSEMBLY.splitlines()
            if line.strip() and not line.strip().startswith(".")
        ]
        self.assertEqual(
            instructions,
            [
                "_AMProjV44ReleaseNativeActivityFallbackEnabled:",
                "mov w0, #0",
                "ret",
                "_AMProjV44IsDirectProjectPackageOption:",
                "cmp w0, #7",
                "cset w0, eq",
                "ret",
            ],
        )
        self.assertEqual(MAKEFILE.count("AMProjStabilityContract.S"), 6)

    def test_v44_project_package_uses_exact_6255_controller_boundary(self):
        self.assertIn("selectedExportOptID", SOURCE)
        self.assertIn("AMProjShareVCSelectedExportOptionOffset = 0x120", SOURCE)
        self.assertIn("hooked_shareNCOnTapExport", SOURCE)
        self.assertIn("amproj_installShareExportHook", SOURCE)

        option_reader = function_body(
            "static BOOL amproj_readShareExportOption",
            "static UIViewController* amproj_shareVCRecursive",
        )
        self.assertIn('isEqualToString:@"862"', option_reader)
        self.assertIn("class_getInstanceVariable", option_reader)
        self.assertIn("class_getInstanceSize", option_reader)
        self.assertIn("AMProjShareVCSelectedExportOptionOffset", option_reader)

        action = function_body(
            "static void hooked_shareNCOnTapExport",
            "static void hooked_navigationPush",
        )
        self.assertIn("AMProjV44IsDirectProjectPackageOption", action)
        self.assertIn("AMProjShareCloudUploadOption", action)
        self.assertIn("amproj_startCloudUpload", action)
        self.assertIn("amproj_startDirectExport", action)
        self.assertIn("orig_shareNCOnTapExport", action)
        self.assertNotIn("amproj_viewVisibleText", action)
        self.assertNotIn("senderLooksLikeProjectPackage", action)

        present = function_body("static void hooked_presentVC", "#if AMPROJ_DEBUG")
        self.assertIn('direct.native_package_presentation', present)
        fallback = present[present.index("if (amproj_isSharePackageController") :]
        self.assertIn('direct_export_fallback', fallback)
        self.assertIn("amproj_startDirectExport", fallback)
        self.assertIn("return;", fallback)
        package_predicate = function_body(
            "static BOOL amproj_isPackageControllerName",
            "static BOOL amproj_isSharePackageController",
        )
        self.assertIn('hasSuffix:@"ShareProjectPackageVC"', package_predicate)
        self.assertNotIn('containsString:@"Package"', package_predicate)

        presentation_predicate = function_body(
            "static BOOL amproj_isSharePackageController",
            "static BOOL amproj_hasPackageController",
        )
        self.assertIn("visibleViewController", presentation_predicate)
        self.assertNotIn("childViewControllers", presentation_predicate)
        self.assertNotIn("presentedViewController", presentation_predicate)

        install = function_body(
            "static void amproj_installExportHooks",
            "static void amproj_removeBootstrapObservers",
        )
        self.assertIn("amproj_installNavigationExportHook();", install)
        self.assertIn("amproj_installPresentationHook();", install)
        self.assertIn("amproj_installShareExportHook();", install)

    def test_v44_direct_share_contains_only_generated_amproj_file(self):
        item_source = source_body(
            SOURCE, "@implementation AMProjActivityItemSource", "@end"
        )
        self.assertEqual(item_source.count("return self.fileURL;"), 2)

        output = function_body(
            "static NSURL* amproj_createOutputURL",
            "static void amproj_finishDirectFailure",
        )
        self.assertIn('stringByAppendingPathExtension:@"amproj"', output)

        direct_share = function_body(
            "static void amproj_presentDirectShare",
            "static void amproj_writeDirectArchive",
        )
        self.assertIn("item.fileURL = fileURL", direct_share)
        self.assertIn("#if AMPROJ_CLOUD_SYNC", direct_share)
        self.assertIn("AMCloudSyncUploadActivities", direct_share)
        self.assertIn(
            "initWithActivityItems:@[item] applicationActivities:cloudActivities",
            direct_share,
        )
        self.assertNotIn("UIImage", direct_share)
        self.assertNotIn(".png", direct_share.lower())
        self.assertNotRegex(direct_share.lower(), r"https?://|qr(?:code)?")

    def test_v44_direct_export_failure_cannot_fall_back_to_native_export(self):
        failure = function_body(
            "static void amproj_finishDirectFailure(AMProjDirectRequest *request, NSError *error) {",
            "// MARK: - Local .amproj import bridge",
        )
        self.assertEqual(failure.count("[alert addAction:"), 2)
        self.assertIn('actionWithTitle:@"\u91cd\u8bd5"', failure)
        self.assertIn('actionWithTitle:@"\u53d6\u6d88"', failure)
        self.assertNotIn("fallbackAction", failure)
        self.assertNotIn("\u4f7f\u7528\u539f\u7248\u4e8c\u7ef4\u7801", failure)
        self.assertNotIn("orig_shareNCOnTapExport", failure)

    def assert_capture_short_circuits_original(
        self, signature: str, next_signature: str, native_imp_type: str
    ) -> None:
        body = function_body(signature, next_signature)
        capture = re.search(
            r"if\s*\([^;]*amproj_captureSystemProjectURL\([^;]+?\)\)\s*"
            r"\{\s*(?:if\s*\(heldSecurityScope\)\s*\[URL stopAccessingSecurityScopedResource\];\s*)?return YES;\s*\}",
            body,
            re.DOTALL,
        )
        self.assertIsNotNone(capture, signature)
        self.assertLess(capture.end(), body.index("IMP original"), signature)
        self.assertLess(capture.end(), body.index(native_imp_type), signature)

    def test_v40_xml_wraps_original_bytes_in_a_local_native_package(self):
        self.assertIn('public.xml', SOURCE)
        self.assertIn('AMProjImportKindXMLTemplate', SOURCE)
        self.assertIn('import.xml_local_package_created', SOURCE)
        self.assertIn('import.xml_template_started', SOURCE)
        self.assertIn('import.xml_template_verified', SOURCE)

        prepare = function_body(
            "static void amproj_prepareCopiedXML",
            "static void amproj_prepareCopiedArchive",
        )
        self.assertRegex(
            prepare,
            re.compile(
                r"AMProjZIPWriteProjectArchive\(\s*localPackageURL,\s*data,\s*@\{\}",
                re.DOTALL,
            ),
        )
        self.assertIn("[zipMetrics[@\"xml_count\"] unsignedIntegerValue] == 1", prepare)
        self.assertIn(
            "[zipMetrics[@\"manifest_count\"] unsignedIntegerValue] == 1",
            prepare,
        )
        self.assertIn("[zipMetrics[@\"entry_count\"] unsignedIntegerValue] == 2", prepare)
        self.assertIn("transaction.packageIntegrityVerified = YES", prepare)
        self.assertIn(
            "amproj_queuePreparedImport(\n                localPackageURL, nameSnapshot, transactionID);",
            prepare,
        )
        self.assertNotIn("amproj_enqueueXMLTemplateImport(", prepare)
        self.assertNotIn("documentPicker:didPickDocumentsAtURLs:", prepare)
        self.assertNotRegex(
            prepare,
            re.compile(r"\bAMProjNormalizeProjectArchive\s*\(", re.DOTALL),
        )

    def test_native_upload_project_picker_accepts_xml_and_amproj_offline(self):
        proxy = SOURCE[
            SOURCE.index("static NSArray<UTType *> *amproj_expandNativeProjectContentTypes") :
            SOURCE.index("static void amproj_presentImportDocumentPickerAttempt")
        ]
        self.assertIn("URLs.count != 1", proxy)
        self.assertIn('isEqualToString:@"xml"', proxy)
        self.assertIn('isEqualToString:@"amproj"', proxy)
        self.assertIn('@"native_xml_picker_local"', proxy)
        self.assertIn('@"native_package_picker_local"', proxy)
        self.assertIn('@"AMProjDirectStage": @YES', proxy)
        self.assertIn('@"AMProjDeclaredType": XML ? @"public.xml" : AMProjUTI', proxy)
        self.assertIn('@"online_delegate_called": @NO', proxy)
        self.assertIn("startAccessingSecurityScopedResource", proxy)
        self.assertIn("stopAccessingSecurityScopedResource", proxy)
        self.assertIn("amproj_handleIncomingProjectURLSafely", proxy)
        self.assertIn("amproj_expandNativeProjectContentTypes", proxy)
        self.assertIn("amproj_expandNativeProjectDocumentTypes", proxy)
        self.assertIn('isEqualToString:@"public.xml"', proxy)
        self.assertIn("[expanded addObject:projectType]", proxy)
        self.assertIn("[expanded addObject:AMProjUTI]", proxy)

        modern_expansion = function_body(
            "static NSArray<UTType *> *amproj_expandNativeProjectContentTypes",
            "static NSArray<NSString *> *amproj_expandNativeProjectDocumentTypes",
        )
        self.assertIn("if (!includesXML) return contentTypes;", modern_expansion)
        self.assertNotIn("public.zip-archive", modern_expansion)
        self.assertNotIn("UTTypeData", modern_expansion)
        legacy_expansion = function_body(
            "static NSArray<NSString *> *amproj_expandNativeProjectDocumentTypes",
            "static id hooked_documentPickerModernInit",
        )
        self.assertIn("if (!includesXML ||", legacy_expansion)
        self.assertIn("return documentTypes;", legacy_expansion)

        installer = function_body(
            "static void amproj_installNativeProjectPickerHook",
            "static void amproj_installImportHook",
        )
        self.assertIn("initForOpeningContentTypes:asCopy:", installer)
        self.assertIn("hooked_documentPickerModernInit", installer)
        self.assertIn("initWithDocumentTypes:inMode:", installer)
        self.assertIn("hooked_documentPickerLegacyInit", installer)
        import_install = function_body(
            "static void amproj_installImportHook",
            "static void amproj_installShareExportHook",
        )
        self.assertIn("amproj_installNativeProjectPickerHook();", import_install)

        present = function_body(
            "static void hooked_presentVC",
            "#if AMPROJ_DEBUG",
        )
        picker_attach = present.index("amproj_attachNativeXMLPickerProxy(controller)")
        self.assertLess(
            picker_attach,
            present.index("orig_presentVC(", picker_attach),
        )

    def test_native_project_picker_proxy_preserves_every_other_delegate_path(self):
        proxy = SOURCE[
            SOURCE.index("@implementation AMProjNativeXMLPickerProxy") :
            SOURCE.index("static void amproj_presentImportDocumentPickerAttempt")
        ]
        self.assertEqual(proxy.count("amproj_routeNativeProjectPicker("), 2)
        self.assertIn("amproj_restoreNativeXMLPickerDelegate", proxy)
        self.assertIn("documentPickerWasCancelled", proxy)
        self.assertEqual(
            proxy.count("amproj_finishOriginalPickerAsCancelled("),
            3,
        )
        self.assertIn("forwardingTargetForSelector", proxy)
        self.assertIn("original, multipleSelector, controller, URLs", proxy)
        self.assertIn("original, singleSelector, controller, URL", proxy)
        self.assertIn(
            "[delegate isKindOfClass:AMProjImportPickerDelegate.class]",
            proxy,
        )
        self.assertIn(
            "objc_setAssociatedObject(picker, &amproj_nativeXMLPickerProxyKey, proxy",
            proxy,
        )

    def test_v44_xml_uses_projects_host_and_native_persistence_evidence(self):
        complete = function_body(
            "static BOOL amproj_completeNativeXMLTemplateImport",
            "static void amproj_failNativeXMLTemplateImport",
        )
        for gate in (
            "transaction.packageIntegrityVerified",
            "transaction.nativeTerminalStatus4Returned",
            "transaction.nativeCompletionSucceeded",
            "transaction.nativeTemporaryConsumed",
            "persistenceConfirmed",
        ):
            self.assertIn(gate, complete)
        self.assertIn('"import.xml_template_verified"', complete)
        self.assertIn('"persistence_delta_used": @YES', complete)
        self.assertIn('"host": @"projects"', complete)
        self.assertIn("amproj_selectMainTab(NO, transactionID)", complete)
        self.assertNotIn("amproj_selectMainTab(YES, transactionID)", complete)

        verifier = function_body(
            "static void amproj_verifyNativeXMLTemplateImport",
            "static void amproj_verifyImportedProjectRow",
        )
        self.assertIn("amproj_selectMainTab(NO, transactionID)", verifier)
        self.assertIn("amproj_visibleProjectsControllers", verifier)
        self.assertIn("transaction.xmlImportedAnywayWarningObserved", verifier)
        self.assertIn("BOOL importConfirmed = temporaryConsumed", verifier)
        self.assertIn("importConfirmed && nativeTerminalReady", verifier)
        self.assertIn('"native_imported_anyway_warning"', verifier)
        self.assertIn("amproj_completeNativeXMLTemplateImport", verifier)
        self.assertNotIn("amproj_verifyImportedProjectRow(", verifier)
        self.assertIn("amproj_scheduleImportPersistenceProbe(", verifier)
        self.assertNotIn("amproj_probeXMLPersistence(", verifier)
        self.assertNotIn("amproj_importPersistenceDelta(", verifier)
        self.assertNotIn("amproj_selectMainTab(YES", verifier)
        self.assertNotIn("amproj_visibleTemplatesControllers", verifier)

        persistence = function_body(
            "static void amproj_scheduleImportPersistenceProbe",
            "static void amproj_captureTemplatePromotionPersistenceBaseline",
        )
        accepted = persistence.index("if (accepted) {")
        verified = persistence.index("if (acceptedVerified)", accepted)
        self.assertIn("transaction.nativeTemporaryConsumed", persistence[accepted:verified])
        self.assertLess(accepted, verified)

        finish = function_body(
            "static void amproj_finishNativePackageImport",
            "static void amproj_tryDispatchPendingImport",
        )
        self.assertIn("activeTransaction.kind == AMProjImportKindXMLTemplate", finish)
        self.assertIn("amproj_verifyNativeXMLTemplateImport(", finish)
        self.assertIn("if (transaction.kind == AMProjImportKindPackage)", SOURCE)

    def test_v40_xml_missing_media_warning_is_only_a_verified_xml_success(self):
        helper = function_body(
            "static BOOL amproj_isSuppressibleXMLMissingMediaAlert",
            "typedef NS_ENUM(NSInteger, AMProjXMLImportAlertResult)",
        )
        for requirement in (
            "AMProjImportKindXMLTemplate",
            "AMProjImportTransactionNativeActive",
            "transaction.packageIntegrityVerified",
            "transaction.nativeTerminalStatus4Observed",
            "alert.actions.count != 1",
            'containsString:@"missing media"',
            'containsString:@"has been imported anyway"',
            "if (!missingMedia || !importedAnyway) return NO;",
        ):
            self.assertIn(requirement, helper)
        self.assertNotIn("AMProjImportKindPackage", helper)

        complete = function_body(
            "static BOOL amproj_completeNativeXMLTemplateImport",
            "static void amproj_failNativeXMLTemplateImport",
        )
        self.assertIn("transaction.xmlImportedAnywayWarningObserved", complete)
        self.assertIn("(!persistenceConfirmed && !nativeWarningConfirmed)", complete)
        self.assertIn('"native_imported_anyway_warning"', complete)

        verifier = function_body(
            "static void amproj_verifyNativeXMLTemplateImport",
            "static void amproj_verifyImportedProjectRow",
        )
        self.assertIn("BOOL importedAnywayConfirmed", verifier)
        self.assertIn("BOOL importConfirmed = temporaryConsumed", verifier)
        self.assertIn("if (importConfirmed && nativeTerminalReady)", verifier)
        self.assertIn(': @"native_imported_anyway_warning"', verifier)

    def test_v40_xml_missing_media_completion_is_one_shot_in_both_orders(self):
        forced_first = NativeXMLMissingMediaRaceModel()
        forced_first.observe_status4()
        self.assertTrue(forced_first.suppressible_missing_media())
        self.assertFalse(forced_first.finish_suppressed_alert())
        forced_first.return_status4_handler()
        self.assertTrue(forced_first.finish_suppressed_alert())
        self.assertFalse(forced_first.finish_native_thunk())
        self.assertEqual(forced_first.completion_source, "suppressed_alert")

        native_first = NativeXMLMissingMediaRaceModel()
        native_first.observe_status4()
        native_first.return_status4_handler()
        self.assertTrue(native_first.finish_native_thunk())
        self.assertFalse(native_first.finish_suppressed_alert())
        self.assertEqual(native_first.completion_source, "native_thunk")

        package = NativeXMLMissingMediaRaceModel(kind="amproj")
        package.observe_status4()
        package.return_status4_handler()
        self.assertFalse(package.suppressible_missing_media())
        self.assertFalse(package.suppressible_missing_media(imported_anyway=False))

    def test_v40_xml_missing_media_is_suppressed_before_generic_failure_only(self):
        detector = function_body(
            "static BOOL amproj_isNativeImportFailureAlert",
            "static BOOL amproj_isSuppressibleXMLMissingMediaAlert",
        )
        self.assertIn('containsString:@"missing media"', detector)

        present = function_body("static void hooked_presentVC", "#if AMPROJ_DEBUG")
        suppression = present.index("amproj_isSuppressibleXMLMissingMediaAlert")
        generic_failure = present.index("amproj_isNativeImportFailureAlert")
        self.assertLess(suppression, generic_failure)
        suppression_branch = present[suppression:generic_failure]
        self.assertIn("transaction.xmlImportedAnywayWarningObserved = YES", suppression_branch)
        self.assertIn('amproj_debugEvent(@"import.xml_missing_media_suppressed"', suppression_branch)
        self.assertIn("amproj_finishSuppressedXMLMissingMediaAlert", suppression_branch)
        self.assertNotIn("AMProjNativePackageImportBridgeFinishFailure", suppression_branch)
        self.assertIn("return;", suppression_branch)

        deferred_completion = function_body(
            "static void amproj_finishSuppressedXMLMissingMediaAlert",
            "typedef NS_ENUM(NSInteger, AMProjXMLImportAlertResult)",
        )
        self.assertIn("transaction.nativeTerminalStatus4Returned", deferred_completion)
        self.assertIn("AMProjNativePackageImportBridgeFinishSuccess()", deferred_completion)
        self.assertIn('amproj_debugEvent(@"import.xml_missing_media_completion"', deferred_completion)
        self.assertNotIn("AMProjNativePackageImportBridgeFinishFailure", deferred_completion)
        self.assertIn('isEqualToString:@"storage_status_4"', SOURCE)
        self.assertIn("transaction.nativeTerminalStatus4Observed = YES", SOURCE)

        generic_failure_branch = present[generic_failure:]
        self.assertIn("AMProjNativePackageImportBridgeFinishFailure", generic_failure_branch)
        self.assertIn('containsString:@"missing media"', detector)

        self.assertIn("AMProjNativePackageImportBridgeFinishSuccess", BRIDGE_HEADER)
        success_start = BRIDGE_SOURCE.index(
            "BOOL AMProjNativePackageImportBridgeFinishSuccess"
        )
        success_end = BRIDGE_SOURCE.index(
            "BOOL AMProjNativePackageImportBridgeIsBusy", success_start
        )
        success = BRIDGE_SOURCE[success_start:success_end]
        self.assertIn("AMProjFinishNativeBridge(YES, nil)", success)
        self.assertNotIn("AMProjPoisonNativeBridgeIfActive", success)

    def test_v40_amproj_unresolved_terminal_keeps_all_five_evidence_gates(self):
        unresolved_completion = function_body(
            "static BOOL amproj_completePackageWithUnresolvedDestination",
            "static BOOL amproj_completePackageAsTemplate",
        )
        for gate in (
            "transaction.packageIntegrityVerified",
            "transaction.nativeTerminalStatus4Returned",
            "transaction.nativeCompletionSucceeded",
            "transaction.nativeTemporaryConsumed",
            "transaction.persistenceVerified",
        ):
            self.assertIn(gate, unresolved_completion)
        self.assertIn('"import.package_destination_unresolved"', unresolved_completion)
        self.assertIn('"native_terminal_destination_unknown"', unresolved_completion)
        self.assertNotIn("amproj_selectMainTab", unresolved_completion)

        template_completion = function_body(
            "static BOOL amproj_completePackageAsTemplate",
            "static BOOL amproj_completePackageTransaction",
        )
        self.assertIn("if (!UIKitTemplateAdded && !SwiftUITemplateAdded) return NO;", template_completion)
        self.assertNotIn("nativeTerminalFallback", template_completion)
        self.assertNotIn("native_terminal_destination_unknown", template_completion)
        self.assertIn('"import.package_template_verified"', template_completion)

        project_completion = function_body(
            "static BOOL amproj_completePackageTransaction",
            "static void amproj_failTemplatePromotion",
        )
        self.assertIn("!transaction.persistenceVerified || !routeGateSatisfied", project_completion)
        self.assertIn("transaction.templatePersistenceVerified", project_completion)
        self.assertIn("transaction.templateCleanupVerified", project_completion)

    def test_v44_projects_host_is_the_only_native_dispatch_prerequisite(self):
        capture = function_body(
            "static void amproj_captureActivatedPackageBaselinesAttempt",
            "static void amproj_captureActivatedPackageBaselines(",
        )
        self.assertIn("amproj_selectMainTab(NO, transactionID)", capture)
        self.assertIn("amproj_visibleProjectsControllers", capture)
        self.assertIn("amproj_captureActivatedPersistenceBaseline", capture)
        self.assertNotIn("amproj_selectMainTab(YES, transactionID)", capture)
        self.assertNotIn("amproj_prepareVisibleTemplateProbe", capture)
        self.assertNotIn("templateProbeCapability", capture)

        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("projectUIOwnerReady", dispatch)
        self.assertIn("laneOwner.persistenceBaselineCaptured", dispatch)
        self.assertIn("laneOwner.projectTitleBaselineCaptured", dispatch)
        self.assertNotIn("templateProbeReady", dispatch)
        self.assertNotIn("laneOwner.templateBaselineCaptured", dispatch)

        resume = function_body(
            "static void amproj_resumeQueuedImports",
            "static BOOL amproj_isImportCommandURL",
        )
        self.assertIn("owner.persistenceBaselineCaptured", resume)
        self.assertIn("owner.projectTitleBaselineCaptured", resume)
        self.assertNotIn("templateProbeReady", resume)
        self.assertNotIn("owner.templateBaselineCaptured", resume)

        xml_begin = function_body(
            "static void amproj_beginXMLTemplateImport",
            "static BOOL amproj_persistencePathIsPluginOwned",
        )
        self.assertIn("initForOpeningContentTypes", xml_begin)
        self.assertIn("amproj_selectMainTab(NO, transactionID)", xml_begin)
        self.assertIn("amproj_visibleProjectsControllers", xml_begin)
        self.assertNotIn("amproj_selectMainTab(YES", xml_begin)
        self.assertNotIn("amproj_visibleTemplatesControllers", xml_begin)
        self.assertNotIn("amproj_prepareVisibleTemplateProbe", xml_begin)
        self.assertLess(
            xml_begin.index("amproj_captureXMLPersistenceBaseline"),
            xml_begin.index("owner, multipleSelector, nativePicker, @[URL]"),
        )

        xml_verify = function_body(
            "static void amproj_verifyXMLTemplateImport",
            "static void amproj_beginXMLTemplateImport",
        )
        self.assertIn("amproj_selectMainTab(NO, transactionID)", xml_verify)
        self.assertIn("amproj_visibleProjectsControllers", xml_verify)
        self.assertIn("transaction.nativeCompletionSucceeded", xml_verify)
        self.assertIn("transaction.persistenceVerified", xml_verify)
        self.assertIn("amproj_probeXMLPersistence", xml_verify)
        self.assertNotIn("amproj_visibleTemplate", xml_verify)
        self.assertNotIn("amproj_newTemplateCandidateForTransaction", xml_verify)
        self.assertNotIn("amproj_selectMainTab(YES", xml_verify)
        self.assertIn("attempt >= 60", xml_verify)
        self.assertIn("cached file retained", xml_verify)

        alert = function_body(
            "static AMProjXMLImportAlertResult amproj_XMLImportAlertResult",
            "static void hooked_presentVC",
        )
        self.assertIn("AMProjXMLImportAlertSuccess", alert)
        self.assertIn("AMProjXMLImportAlertFailure", alert)
        self.assertIn("upload complete", alert)
        self.assertIn("upload failed", alert)
        present = function_body("static void hooked_presentVC", "#if AMPROJ_DEBUG")
        self.assertIn("import.xml_native_success_alert", present)
        self.assertIn("import.xml_native_failure_alert", present)
        xml_branch = present[
            present.index("AMProjXMLImportAlertResult XMLAlertResult") :
            present.index("NSString *nativeFailureTitle")
        ]
        self.assertIn("transaction.nativeCompletionSucceeded = YES", xml_branch)
        self.assertIn("amproj_waitForXMLPickerDismissal", xml_branch)
        self.assertNotIn("amproj_finishXMLTemplateImport(transactionID, YES", xml_branch)
        self.assertIn("amproj_finishXMLTemplateImportAfterPicker", xml_branch)
        self.assertIn("NO, 0);", xml_branch)
        self.assertLess(
            xml_branch.index("orig_presentVC(self, _cmd, controller, animated, completion)"),
            xml_branch.index("transaction.nativeCompletionSucceeded = YES"),
        )

    def test_v40_routes_are_serial_and_template_cleanup_is_identity_safe(self):
        self.assertIn("amproj_xmlTemplatePendingQueue", SOURCE)
        self.assertIn("amproj_enqueueXMLTemplateImport", SOURCE)
        self.assertIn("amproj_pumpXMLTemplateImports", SOURCE)
        xml_begin = function_body(
            "static void amproj_beginXMLTemplateImport",
            "static BOOL amproj_persistencePathIsPluginOwned",
        )
        self.assertIn("amproj_xmlTemplateImportTransactionID", xml_begin)
        self.assertIn("amproj_enqueueXMLTemplateImport(URL, name, transactionID)", xml_begin)
        self.assertIn("UIDocumentPickerViewController *nativePicker", xml_begin)
        self.assertIn("nativePicker.delegate", xml_begin)
        self.assertIn("owner, multipleSelector, nativePicker, @[URL]", xml_begin)
        self.assertIn("xmlTemplateDispatchStarted", xml_begin)

        baseline = function_body(
            "static void amproj_captureTemplateBaseline(AMProjImportTransaction",
            "static NSDictionary *amproj_newTemplateCandidateForTransaction",
        )
        self.assertIn("templateBaselineCandidateKeys", baseline)
        self.assertIn("templateBaselineListReady", baseline)
        candidate = function_body(
            "static NSDictionary *amproj_newTemplateCandidateForTransaction",
            "static BOOL amproj_invokeTemplateCandidate",
        )
        self.assertIn("baselineKeys containsObject:key", candidate)
        self.assertIn("added.count == 1", candidate)

        # Stable builds retain native template imports but deliberately do not
        # automate SwiftUI "create project" or delete-template controls.
        disabled = SOURCE[SOURCE.index("#if 0\nstatic void amproj_failTemplatePromotion") :
                          SOURCE.index("#endif\n\nstatic BOOL amproj_completeNativeXMLTemplateImport")]
        self.assertIn("amproj_cleanupPromotedTemplate", disabled)
        self.assertIn("amproj_cleanupSwiftUIPromotedTemplate", disabled)
        self.assertIn("amproj_unwindTemplatePresentation", disabled)

    def test_v40_import_lane_interleavings_do_not_deadlock(self):
        lane = ImportLaneModel()
        lane.enqueue_xml("xml-1")
        lane.enqueue_package("package-1")
        lane.enqueue_xml("xml-2")
        self.assertEqual(lane.active, ("xml", "xml-1"))
        lane.finish()
        self.assertEqual(lane.active, ("package", "package-1"))
        lane.finish()
        self.assertEqual(lane.active, ("xml", "xml-2"))
        lane.finish()
        self.assertIsNone(lane.active)

        prepare = function_body(
            "static void amproj_prepareCopiedArchive",
            "static void amproj_activateNextPendingImport",
        )
        self.assertIn("amproj_queuePreparedImport(preparedURL", prepare)
        self.assertNotIn("amproj_captureTemplateBaselineAndQueue(", prepare)
        activation = function_body(
            "static void amproj_activateNextPendingImport",
            "static AMProjNativePackageImportStarter",
        )
        self.assertLess(
            activation.index("amproj_pendingImportTransactionID ="),
            activation.index("amproj_captureActivatedPackageBaselines("),
        )
        capture = function_body(
            "static void amproj_captureActivatedPackageBaselinesAttempt",
            "static void amproj_captureActivatedPackageBaselines(",
        )
        self.assertIn("ownsLane", capture)
        self.assertIn("projectTitleBaselineCaptured = YES", capture)
        self.assertNotIn("amproj_queuePreparedImport", capture)
        pump = function_body(
            "static void amproj_pumpXMLTemplateImports",
            "static void amproj_finishXMLTemplateImport",
        )
        self.assertNotIn("amproj_hasLivePackageTransaction", pump)
        resume = function_body(
            "static void amproj_resumeQueuedImports",
            "static BOOL amproj_isImportCommandURL",
        )
        self.assertLess(
            resume.index("amproj_pendingImportQueue.count"),
            resume.index("amproj_xmlTemplatePendingQueue.count"),
        )

    def test_v44_direct_project_completes_without_online_template_absence(self):
        verifier = function_body(
            "static void amproj_verifyImportedProjectRow",
            "static void amproj_finishNativePackageImport",
        )
        completion = function_body(
            "static BOOL amproj_completePackageTransaction",
            "static void amproj_failTemplatePromotion",
        )
        verified = verifier.index("if (verified)")
        direct_completion = verifier.index(
            "amproj_completePackageTransaction(", verified
        )
        package_only = verifier.index(
            "if (probeTransaction.kind == AMProjImportKindPackage) {",
            direct_completion,
        )
        legacy_template_code = verifier.index(
            "probeTransaction.templateProbeCapability", package_only
        )
        package_route = verifier[package_only:legacy_template_code]
        self.assertLess(verified, direct_completion)
        self.assertIn("amproj_selectMainTab(NO, transactionID)", package_route)
        self.assertIn("amproj_scheduleImportPersistenceProbe", package_route)
        self.assertIn("return;", package_route)
        self.assertNotIn("amproj_selectMainTab(YES", package_route)
        self.assertNotIn("amproj_visibleTemplatesControllers", package_route)

        for gate in (
            "transaction.directProjectVerified",
            "transaction.packageIntegrityVerified",
            "transaction.nativeTerminalStatus4Returned",
            "transaction.nativeCompletionSucceeded",
            "transaction.nativeTemporaryConsumed",
            "transaction.persistenceVerified",
        ):
            self.assertIn(gate, completion)
        self.assertNotIn("templateAbsenceVerified", completion)
        self.assertNotIn("amproj_templateBaselineStillExact", completion)
        self.assertNotIn("amproj_visibleTemplateViewTitleCount", completion)

    def test_v40_xml_bypasses_unreachable_swiftui_upload_button(self):
        picker_flow = function_body(
            "static void amproj_beginXMLTemplateImport",
            "static BOOL amproj_persistencePathIsPluginOwned",
        )
        self.assertNotIn("xmlTemplateUploadAttemptedIdentities", picker_flow)
        self.assertNotIn("amproj_activateXMLUploadView", picker_flow)
        self.assertNotIn('import.xml_upload_control_missing', picker_flow)
        self.assertIn("respondsToSelector:multipleSelector", picker_flow)
        self.assertIn("nativePicker.delegate = (id<UIDocumentPickerDelegate>)owner", picker_flow)
        self.assertIn("owner, multipleSelector, nativePicker, @[URL]", picker_flow)
        self.assertIn('route\": @\"projects_direct_delegate\"', picker_flow)
        self.assertIn("amproj_selectMainTab(NO, transactionID)", picker_flow)
        self.assertIn("amproj_visibleProjectsControllers", picker_flow)
        self.assertNotIn("amproj_selectMainTab(YES", picker_flow)
        self.assertNotIn("amproj_visibleTemplatesControllers", picker_flow)
        self.assertNotIn("amproj_prepareVisibleTemplateProbe", picker_flow)

    def test_v40_xml_failures_use_xml_specific_alert_title(self):
        alert = function_body(
            "static void amproj_presentXMLImportError",
            "static BOOL amproj_pauseForNativeBridgeRestart",
        )
        finish = function_body(
            "static void amproj_finishXMLTemplateImportInternal",
            "static void amproj_finishXMLTemplateImport(",
        )
        staging = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURL(",
        )
        safe_wrapper = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLSafely",
            "static dispatch_queue_t amproj_importInboxQueue",
        )
        system_capture = function_body(
            "static BOOL amproj_captureSystemProjectURL",
            "static BOOL hooked_applicationOpenURL",
        )
        self.assertIn('@"无法导入 XML"', alert)
        self.assertIn('@"选择 XML 文件"', SOURCE)
        self.assertIn("amproj_presentXMLImportError", finish)
        self.assertNotIn("amproj_presentImportErrorOfferingPicker(visible", finish)
        self.assertGreaterEqual(
            staging.count("amproj_presentImportErrorForKind"), 3
        )
        self.assertNotIn("amproj_presentImportError(", staging)
        self.assertIn("amproj_importKindForURL", safe_wrapper)
        self.assertIn("amproj_presentImportErrorForKind", safe_wrapper)
        self.assertNotIn("amproj_presentImportError(", safe_wrapper)
        self.assertIn("amproj_importKindForURL", system_capture)
        self.assertIn("amproj_presentImportErrorForKind", system_capture)
        self.assertNotIn("amproj_presentImportError(", system_capture)

    def test_v40_xml_direct_delegate_and_unresolved_package_terminal_are_evidence_gated(self):
        xml_persistence = function_body(
            "static void amproj_captureXMLPersistenceBaseline",
            "static void amproj_scheduleImportPersistenceProbe",
        )
        self.assertIn("amproj_xmlTemplateImportGeneration", xml_persistence)
        self.assertIn("!transaction.xmlTemplateDispatchStarted", xml_persistence)
        self.assertIn("amproj_importPersistenceDelta", xml_persistence)
        self.assertIn('import.xml_persistence_baseline', xml_persistence)
        self.assertIn('import.xml_persistence_probe', xml_persistence)
        self.assertIn("transaction.persistenceVerified = YES", xml_persistence)

        verifier = function_body(
            "static void amproj_verifyImportedProjectRow",
            "static void amproj_finishNativePackageImport",
        )
        unresolved_terminal = verifier.index(
            "amproj_completePackageWithUnresolvedDestination"
        )
        self.assertLess(verifier.index("attempt >= 3"), unresolved_terminal)
        self.assertLess(
            unresolved_terminal,
            verifier.index("templateProbeCapability", unresolved_terminal),
        )
        hard_timeout = verifier.rindex("if (attempt < 30)")
        self.assertLess(unresolved_terminal, hard_timeout)
        self.assertIn(
            "amproj_completePackageWithUnresolvedDestination",
            verifier[hard_timeout:],
        )

        completion = function_body(
            "static BOOL amproj_completePackageWithUnresolvedDestination",
            "static BOOL amproj_completePackageAsTemplate",
        )
        for evidence in (
            "packageIntegrityVerified",
            "nativeTerminalStatus4Returned",
            "nativeCompletionSucceeded",
            "nativeTemporaryConsumed",
            "persistenceVerified",
        ):
            self.assertIn(evidence, completion)
        self.assertIn('import.package_destination_unresolved', completion)
        self.assertIn('native_terminal_destination_unknown', completion)
        self.assertNotIn("amproj_selectMainTab", completion)

        template_completion = function_body(
            "static BOOL amproj_completePackageAsTemplate",
            "static BOOL amproj_completePackageTransaction",
        )
        self.assertIn('ui_template_verified', template_completion)
        self.assertIn('route": @"template_final"', template_completion)
        self.assertNotIn('template_native_terminal_fallback', template_completion)

    def test_v40_persistence_baseline_is_captured_by_active_lane_owner(self):
        prepare = function_body(
            "static void amproj_prepareCopiedArchive",
            "static void amproj_activateNextPendingImport",
        )
        capture = function_body(
            "static void amproj_captureActivatedPersistenceBaseline",
            "static NSString* amproj_relativeSandboxPath",
        )
        active = function_body(
            "static void amproj_captureActivatedPackageBaselinesAttempt",
            "static void amproj_captureActivatedPackageBaselines(",
        )
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("amproj_storeImportProjectTitle", prepare)
        self.assertNotIn("amproj_captureImportPersistenceSnapshot", prepare)
        self.assertIn("generation == amproj_pendingImportGeneration", capture)
        self.assertIn("amproj_pendingImportTransactionID", capture)
        self.assertIn("ui_owner_ready", capture)
        self.assertIn("persistenceBaselineCaptured = YES", capture)
        self.assertIn("persistenceBaselineGeneration = generation", capture)
        self.assertIn("amproj_captureActivatedPersistenceBaseline", active)
        self.assertLess(
            active.index("projectTitleBaselineCaptured = YES"),
            active.index("amproj_captureActivatedPersistenceBaseline"),
        )
        self.assertIn("laneOwner.persistenceBaselineGeneration == generation", dispatch)
        self.assertIn("projectUIOwnerReady", dispatch)
        retry = dispatch[dispatch.index("if (retryable)") :]
        self.assertIn(
            "amproj_invalidatePersistenceBaseline(dispatchTransaction)", retry
        )
        self.assertIn("++amproj_pendingImportGeneration", retry)
        self.assertIn("amproj_captureActivatedPackageBaselines", retry)
        self.assertLess(
            retry.index("amproj_invalidatePersistenceBaseline(dispatchTransaction)"),
            retry.index("amproj_captureActivatedPackageBaselines"),
        )

    def test_v40_runtime_identity_and_async_generation_guards(self):
        accessibility = function_body(
            "static NSArray *amproj_accessibilityChildren",
            "static void amproj_appendPaywallViewText",
        )
        self.assertIn("accessibilityElementCount", accessibility)
        self.assertIn("accessibilityElementAtIndex", accessibility)
        collect_text = function_body(
            "static void amproj_collectViewTexts",
            "static BOOL amproj_objectHasExactTemplateTitle",
        )
        self.assertIn("amproj_accessibilityChildren(view)", collect_text)
        activatable = function_body(
            "static id amproj_findActivatableViewWithTerms",
            "static BOOL amproj_activateView",
        )
        self.assertIn("amproj_accessibilityChildren(view)", activatable)

        activate_control = function_body(
            "static BOOL amproj_activateControl",
            "static NSString *amproj_viewVisibleText",
        )
        self.assertIn("control.allControlEvents", activate_control)
        self.assertIn("UIControlEventPrimaryActionTriggered", activate_control)
        self.assertIn("accessibilityActivate", activate_control)
        self.assertIn("@catch (__unused NSException *exception) {\n        return NO;", activate_control)
        self.assertNotIn(
            "sendActionsForControlEvents:UIControlEventTouchUpInside];\n        return YES",
            activate_control,
        )

        pickers = function_body(
            "amproj_visibleXMLDocumentPickers(void)",
            "static NSString *amproj_xmlUploadComparableText",
        )
        self.assertIn("amproj_visibleXMLDocumentPickerIdentities", pickers)
        self.assertIn("amproj_newXMLDocumentPicker", pickers)
        self.assertIn("xmlTemplatePickerBaseline", pickers)
        self.assertIn("ownerWindow", pickers)

        upload = function_body(
            "static NSString *amproj_xmlUploadComparableText",
            "static void amproj_waitForXMLPickerDismissal",
        )
        self.assertIn('xml_importer.entry_point.button', upload)
        self.assertIn("UIAccessibilityTraitButton", upload)
        self.assertIn("amproj_collectViewTexts", upload)
        self.assertIn("amproj_collectXMLUploadCandidates", upload)
        self.assertIn("amproj_activateView(object)", upload)
        self.assertIn('right[@"score"]', upload)

        xml_begin = function_body(
            "static void amproj_beginXMLTemplateImport",
            "static BOOL amproj_persistencePathIsPluginOwned",
        )
        self.assertNotIn("amproj_visibleXMLDocumentPickerIdentities", xml_begin)
        self.assertNotIn("amproj_activateXMLUploadView", xml_begin)
        self.assertIn("amproj_captureXMLPersistenceBaseline", xml_begin)
        self.assertIn("persistenceBaselineGeneration != generation", xml_begin)
        self.assertIn("xmlTemplateNativePicker = nativePicker", xml_begin)
        self.assertIn("++transaction.xmlTemplateDispatchGeneration", xml_begin)
        self.assertLess(
            xml_begin.index("xmlTemplatePickerDelegateInvoked = YES"),
            xml_begin.index("owner, multipleSelector, nativePicker, @[URL]"),
        )
        self.assertIn("amproj_verifyXMLTemplateImport", xml_begin)

        picker_wait = function_body(
            "static void amproj_waitForXMLPickerDismissal",
            "static void amproj_beginXMLTemplateImport",
        )
        self.assertIn("dismissViewControllerAnimated:NO", picker_wait)
        self.assertIn("xmlTemplatePickerDismissVerified = YES", picker_wait)
        self.assertIn("attempt >= 40", picker_wait)

        picker_finish = function_body(
            "static void amproj_finishXMLTemplateImportAfterPicker",
            "static void amproj_finishXMLTemplateImport(",
        )
        self.assertIn("pickerVisible && attempt < 40", picker_finish)
        self.assertIn("finalSuccess = success && pickerClosed", picker_finish)

        finish_internal = function_body(
            "static void amproj_finishXMLTemplateImportInternal",
            "static void amproj_finishXMLTemplateImportAfterPicker",
        )
        self.assertIn("transaction.nativeCompletionSucceeded", finish_internal)
        self.assertIn("transaction.persistenceVerified", finish_internal)
        self.assertIn("requestedSuccess && !success", finish_internal)

        alert = function_body(
            "static AMProjXMLImportAlertResult amproj_XMLImportAlertResult",
            "static void hooked_presentVC",
        )
        self.assertIn("xmlTemplatePickerDelegateInvoked", alert)
        self.assertIn("xmlTemplateDispatchStarted", alert)
        self.assertIn("xmlTemplateDispatchGeneration", alert)
        self.assertIn("xmlTemplateNativePicker", alert)
        self.assertIn("ownerWindow != presenterWindow", alert)
        self.assertIn("xmlTemplatePickerPresenter", alert)
        self.assertIn("presenterMatches", alert)
        self.assertIn("presenter == expectedPicker", alert)
        self.assertIn("presenter == expectedPresenter", alert)
        self.assertIn("presenter == owner", alert)
        self.assertIn("owner.navigationController", alert)
        self.assertIn("failureTitles containsObject:normalizedTitle", alert)
        self.assertIn("successTitles containsObject:normalizedTitle", alert)
        self.assertNotIn("content containsString", alert)

        persistence = function_body(
            "static void amproj_scheduleImportPersistenceProbe",
            "static void amproj_captureTemplatePromotionPersistenceBaseline",
        )
        self.assertIn("persistenceProbeEpoch == probeEpoch", persistence)
        self.assertIn("persistenceBaselineGeneration == baselineGeneration", persistence)
        self.assertIn("AMProjImportTransactionNativeActive", persistence)
        self.assertIn("snapshot_truncated", persistence)
        self.assertIn("persistence_probe_stale", persistence)

        completion = function_body(
            "static BOOL amproj_completePackageTransaction",
            "static void amproj_failTemplatePromotion",
        )
        self.assertIn("return NO", completion)
        self.assertIn("return YES", completion)
        self.assertNotIn("templateAbsenceProbeUnavailableAccepted", completion)
        self.assertIn("BOOL directProjectReady", completion)
        self.assertIn("transaction.directProjectVerified", completion)
        self.assertIn("transaction.nativeTerminalStatus4Returned", completion)
        self.assertNotIn("SwiftUITemplateAbsence", completion)

        verifier = function_body(
            "static void amproj_verifyImportedProjectRow",
            "static void amproj_finishNativePackageImport",
        )
        swiftui_route = verifier[
            verifier.index("AMProjTemplateProbeCapabilitySwiftUIUnavailable") :
            verifier.index("AMProjTemplateProbeCapabilityUIKitReady")
        ]
        self.assertIn("verified || probeTransaction.directProjectVerified", swiftui_route)
        self.assertIn("probeTransaction.directProjectRowCount", swiftui_route)

        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        retry = dispatch[dispatch.index("if (retryable)") :]
        self.assertIn("amproj_invalidateTemplateProbe(dispatchTransaction)", retry)
        self.assertLess(
            retry.index("amproj_invalidateTemplateProbe(dispatchTransaction)"),
            retry.index("++amproj_pendingImportGeneration"),
        )

        pump = function_body(
            "static void amproj_pumpXMLTemplateImports",
            "static void amproj_resumeAfterXMLResultAlert",
        )
        resume = function_body(
            "static void amproj_resumeQueuedImports",
            "static BOOL amproj_isImportCommandURL",
        )
        self.assertIn("amproj_xmlTemplateResultQuarantineUntil", pump)
        self.assertIn("amproj_xmlTemplateResultQuarantineUntil", resume)
        self.assertIn("amproj_resumeAfterXMLResultAlert(0)", pump)
        self.assertIn("amproj_resumeAfterXMLResultAlert(0)", resume)
        self.assertGreaterEqual(
            verifier.count("amproj_failImportedProjectVerification"), 4
        )

    def test_v44_manual_deletion_stays_outside_plugin_hooks(self):
        present = function_body("static void hooked_presentVC", "#if AMPROJ_DEBUG")
        gate_start = present.index("if (!amproj_runtimeUsesLegacyImportHooks())")
        pre_gate = present[:gate_start]
        self.assertNotIn("amproj_startupPaywallPresentationDecision", pre_gate)
        self.assertNotIn("amproj_isSharePackageController", pre_gate)
        self.assertIn("UIAlertController.class", present)
        self.assertIn("amproj_hasPluginManagedImportAlertContext", present)
        self.assertIn("orig_presentVC(self, _cmd, controller, animated, completion)", present)

        view_load = function_body(
            "static void hooked_projectsImportAlertViewDidLoad",
            "static void hooked_projectsImportAlertOnPressImport",
        )
        self.assertIn("if (!recognizedQueuedPackage) return;", view_load)
        self.assertLess(
            view_load.index("if (!recognizedQueuedPackage) return;"),
            view_load.index("amproj_nativeImportAlertActive = YES"),
        )

        disappeared = function_body(
            "static void hooked_projectsImportAlertViewDidDisappear",
            "static UIWindow* amproj_keyWindow",
        )
        self.assertIn("if (!tracked) return;", disappeared)
        self.assertLess(
            disappeared.index("if (!tracked) return;"),
            disappeared.index("amproj_nativeImportAlertActive = NO"),
        )

    def test_native_local_continuation_exceptions_are_contained(self):
        self.assertIn("The native local project importer raised an exception", BRIDGE_SOURCE)
        self.assertIn("AMProjPoisonNativeBridge()", BRIDGE_SOURCE)
        self.assertGreaterEqual(BRIDGE_SOURCE.count('@catch (NSException *exception)'), 3)

    def test_native_package_bridge_has_explicit_full_project_contract(self):
        bridge = function_body(
            "static AMProjNativePackageImportStarter amproj_nativePackageImportStarter",
            "static void amproj_tryDispatchPendingImport",
        )
        self.assertIn("AMProjNativePackageImportStarter", bridge)
        self.assertIn("AMProjRegisterNativePackageImportStarter", bridge)
        self.assertIn("package, XML and bundled resources", bridge)
        self.assertIn('amproj_debugEvent(@"import.local_bridge_finished"', bridge)
        self.assertIn("4/4", bridge)
        self.assertIn("\\u9879\\u76ee", bridge)

    def test_native_bridge_uses_complete_package_and_skips_firebase_download(self):
        self.assertNotIn("AMProjLocalStorageReference", BRIDGE_SOURCE)
        self.assertNotIn("AMProjLocalStorageTask", BRIDGE_SOURCE)
        self.assertNotIn("writeToFile:", BRIDGE_SOURCE)
        self.assertNotIn("observeStatus:", BRIDGE_SOURCE)
        self.assertIn("amproj_local_import_%@", BRIDGE_SOURCE)
        self.assertIn("copyItemAtURL:packageURL", BRIDGE_SOURCE)
        self.assertIn("AMProjBridgeNSURLToSwiftURL", BRIDGE_SOURCE)
        self.assertIn("AMProjCallNativeLocalImportContinuation", BRIDGE_SOURCE)
        self.assertIn("AMProjEmitStorageStatus(2, NO", BRIDGE_SOURCE)
        self.assertIn("AMProjEmitStorageStatus(4, NO", BRIDGE_SOURCE)
        self.assertIn("AMProjEmitStorageStatus(5, NO", BRIDGE_SOURCE)
        self.assertIn("QOS_CLASS_USER_INITIATED", BRIDGE_SOURCE)
        self.assertNotIn("AMProjExtractProjectArchive", BRIDGE_SOURCE)
        self.assertNotIn("nativeXMLURL", BRIDGE_SOURCE)

    def test_native_bridge_requires_visible_projects_tab_before_starting(self):
        start = BRIDGE_SOURCE.index("static UIViewController *AMProjPresentationOwner(void)")
        end = BRIDGE_SOURCE.index("static BOOL AMProjIsProjectsController", start)
        owner = BRIDGE_SOURCE[start:end]
        self.assertIn("UIApplicationStateActive", owner)
        self.assertIn("if (AMProjSelectProjectsTab(projects))", owner)
        self.assertIn("waiting for next run loop", owner)
        self.assertNotIn("window.rootViewController", owner)
        selection = source_body(
            BRIDGE_SOURCE,
            "static BOOL AMProjSelectProjectsTab",
            "static void AMProjNativeImportCompletionThunk",
        )
        self.assertIn("BOOL changed = NO", selection)
        self.assertIn("changed = YES", selection)
        self.assertIn("return changed", selection)

    def test_native_bridge_ranks_real_project_controller_candidates_without_root_fallback(self):
        self.assertIn('hasSuffix:@"ProjectsVC"', BRIDGE_SOURCE)
        self.assertIn('hasSuffix:@"ProjectsListVC"', BRIDGE_SOURCE)
        self.assertIn("connectedScenes", BRIDGE_SOURCE)
        self.assertIn("application.windows", BRIDGE_SOURCE)
        self.assertIn("AMProjBestProjectControllerCandidate", BRIDGE_SOURCE)
        self.assertIn("AMProjControllerIsMountedVisible", BRIDGE_SOURCE)
        owner_start = BRIDGE_SOURCE.index(
            "static UIViewController *AMProjPresentationOwner(void)"
        )
        owner_end = BRIDGE_SOURCE.index(
            "static BOOL AMProjIsProjectsController", owner_start
        )
        owner = BRIDGE_SOURCE[owner_start:owner_end]
        self.assertIn("AMProjProjectControllerCandidates()", owner)
        self.assertIn("AMProjSelectProjectsTab(projects)", owner)
        self.assertIn("no foreground mounted candidate", BRIDGE_SOURCE)
        self.assertIn("AMProjProjectOwnerIsUnobstructed", owner)
        self.assertNotIn("return window.rootViewController", owner)

    def test_native_bridge_has_no_arbitrary_root_or_visible_window_fallback(self):
        self.assertNotIn("AMProjVisibleWindowPresentationOwner", BRIDGE_SOURCE)
        self.assertNotIn("AMProjUsablePresentationOwner", BRIDGE_SOURCE)
        self.assertNotIn("AMProjTopController", BRIDGE_SOURCE)
        self.assertIn("if (!candidate.foregroundActive || !candidate.visibleWindow)",
                      BRIDGE_SOURCE)
        owner_guard = source_body(
            BRIDGE_SOURCE,
            "static BOOL AMProjProjectOwnerIsUnobstructed",
            "static UIViewController *AMProjPresentationOwner",
        )
        self.assertIn("AMProjIsProjectsController", owner_guard)
        self.assertIn("AMProjControllerIsMountedVisible", owner_guard)
        self.assertIn("presentedViewController", owner_guard)

    def test_native_bridge_creates_and_retains_progress_owner(self):
        call_start = BRIDGE_SOURCE.index("AMProjCallNativeLocalImportContinuation(")
        call_end = BRIDGE_SOURCE.index("NULL);", call_start) + len("NULL);")
        call = BRIDGE_SOURCE[call_start:call_end]
        self.assertIn("localContinuation,", call)
        self.assertIn("nil,", call)
        self.assertIn("owner,", call)
        self.assertIn("progressOwner,", call)
        self.assertIn("swiftCleanupURL,", call)
        self.assertIn("packageImporter,", call)
        self.assertIn("swiftName.word0,", call)
        self.assertIn("swiftName.word1,", call)
        self.assertIn("swiftPackageURL,", call)
        self.assertIn("AMProjNativeImportCompletionThunk", call)
        self.assertIn("NULL);", call)
        self.assertIn('storyboardWithName:@"AMProgressAlert"', BRIDGE_SOURCE)
        self.assertIn('hasSuffix:@"AMProgressAlert"', BRIDGE_SOURCE)
        self.assertIn("amproj_nativeBridgeProgressOwner = progressOwner", BRIDGE_SOURCE)
        self.assertIn("amproj_nativeBridgeProgressOwner = nil", BRIDGE_SOURCE)
        self.assertIn('progress_owner_created', BRIDGE_SOURCE)
        self.assertIn('progress_owner_class', BRIDGE_SOURCE)
        self.assertIn('progress_owner_presented', BRIDGE_SOURCE)
        self.assertIn("id progressOwner", BRIDGE_HEADER)
        self.assertNotIn("id _Nullable progressOwner", BRIDGE_HEADER)

    def test_copy_failure_reports_status_five_before_finishing(self):
        start = BRIDGE_SOURCE.index("if (copyError) {")
        end = BRIDGE_SOURCE.index("AMProjNSStringToSwiftStringFn", start)
        failure = BRIDGE_SOURCE[start:end]
        self.assertIn("AMProjEmitStorageStatus(5, NO", failure)
        self.assertIn("AMProjEmitStorageStatus(5, YES", failure)
        self.assertIn("AMProjFinishNativeBridge(NO, copyError)", failure)
        self.assertLess(
            failure.index("AMProjEmitStorageStatus(5, YES"),
            failure.index("AMProjFinishNativeBridge(NO, copyError)"),
        )

    def test_native_local_success_preserves_status_two_and_four_order(self):
        start = BRIDGE_SOURCE.index("AMProjEmitStorageStatus(2, NO")
        end = BRIDGE_SOURCE.index("@catch (NSException *exception)", start)
        success = BRIDGE_SOURCE[start:end]
        markers = (
            "AMProjEmitStorageStatus(2, NO",
            "AMProjEmitStorageStatus(2, YES",
            "AMProjEmitStorageStatus(4, NO",
            "AMProjCallNativeLocalImportContinuation(",
            "AMProjEmitStorageStatus(4, YES",
        )
        positions = [success.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))

    def test_swift_url_values_use_runtime_layout_and_balanced_destroy(self):
        create = source_body(
            BRIDGE_SOURCE,
            "static BOOL AMProjCreateSwiftURLValue",
            "static void AMProjDestroySwiftURLValue",
        )
        destroy = source_body(
            BRIDGE_SOURCE,
            "static void AMProjDestroySwiftURLValue",
            "static BOOL AMProjStartNativePackageImport",
        )
        self.assertIn("valueWitnesses + 0x40", create)
        self.assertIn("valueWitnesses + 0x48", create)
        self.assertIn("valueWitnesses + 0x50", create)
        self.assertIn("posix_memalign", create)
        self.assertIn("AMProjBridgeNSURLToSwiftURL", create)
        self.assertIn("valueWitnesses + 0x08", destroy)
        self.assertIn("destroy(value, metadata)", destroy)
        self.assertIn("free(value)", destroy)

    def test_native_bridge_events_are_thread_safe_and_main_thread_delivered(self):
        self.assertIn("AMProjNativePackageImportEventHandler", BRIDGE_HEADER)
        self.assertIn("AMProjRegisterNativePackageImportEventHandler", BRIDGE_HEADER)
        self.assertIn("@synchronized (AMProjNativeBridgeLock())", BRIDGE_SOURCE)
        emitter = source_body(
            BRIDGE_SOURCE,
            "static void AMProjEmitNativeBridgeEvent",
            "static NSError *AMProjNativeBridgeError",
        )
        self.assertIn("NSThread.isMainThread", emitter)
        self.assertIn("dispatch_get_main_queue()", emitter)
        for event in (
            "native_entry_start",
            "native_entry_return",
            "storage_write_start",
            "native_completion",
        ):
            self.assertIn(f'@"{event}"', BRIDGE_SOURCE)
        self.assertIn("AMProjStorageStatusReturnedEventName", BRIDGE_SOURCE)
        self.assertIn('stringByAppendingString:@"_returned"', BRIDGE_SOURCE)
        self.assertIn("AMProjEmitStorageStatus", BRIDGE_SOURCE)
        self.assertNotIn("storage_observer_registered", BRIDGE_SOURCE)
        self.assertIn("amproj_nativeBridgeFinishPending", BRIDGE_SOURCE)

    def test_native_events_are_persisted_for_offline_crash_diagnosis(self):
        writer = source_body(
            SOURCE,
            "static void amproj_writeImportBreadcrumb",
            "static NSDictionary *amproj_readImportBreadcrumb",
        )
        breadcrumb = source_body(
            SOURCE,
            "static void amproj_writeNativeEventBreadcrumb",
            "static void amproj_setPersistentStage",
        )
        self.assertIn("amproj_importBreadcrumbLock", SOURCE)
        self.assertIn("@synchronized (amproj_importBreadcrumbLock())", writer)
        self.assertIn("[previous mutableCopy]", writer)
        self.assertIn("sameTransaction", writer)
        self.assertIn('record[@"last_native_event"]', breadcrumb)
        self.assertIn('record[@"native_status"]', breadcrumb)
        self.assertIn('record[@"native_fields"]', breadcrumb)
        self.assertIn('@"returned"', breadcrumb)
        self.assertIn('@"exception"', breadcrumb)
        self.assertIn("NSDataWritingAtomic", breadcrumb)
        self.assertNotIn("amproj_nativeBreadcrumbPhase", SOURCE)
        self.assertIn(
            "amproj_writeNativeEventBreadcrumb(transactionID, event, enriched);",
            SOURCE,
        )
        display = source_body(
            SOURCE,
            "static NSString *amproj_nativeBreadcrumbDisplayStage",
            "static void amproj_writeNativeEventBreadcrumb",
        )
        self.assertIn('breadcrumb[@"last_native_event"]', display)
        self.assertIn('breadcrumb[@"native_status"]', display)
        self.assertIn("storage_observer_%@_registered", display)
        self.assertIn("amproj_nativeBreadcrumbDisplayStage(previousBreadcrumb)", SOURCE)

    def test_native_completion_does_not_refresh_projects_ui_directly(self):
        completion = source_body(
            BRIDGE_SOURCE,
            "static void AMProjNativeImportCompletionThunk",
            "static BOOL AMProjStartNativePackageImport",
        )
        self.assertIn("BOOL success = result != NULL", completion)
        self.assertIn("Alight Motion returned no imported project", completion)
        self.assertIn("AMProjFinishNativeBridge(success, error)", completion)
        self.assertNotIn("AMProjFinishNativeBridge(YES, nil)", completion)
        self.assertNotIn("AMProjRefreshProjectsController", completion)
        self.assertNotIn("reloadData", completion)
        self.assertNotIn("AMProjRefreshProjectsController", BRIDGE_SOURCE)

    def test_timeout_poison_prevents_a_late_callback_from_finishing_a_new_import(self):
        self.assertIn("amproj_nativeBridgePoisoned", BRIDGE_SOURCE)
        self.assertIn("if (stillActive) amproj_nativeBridgePoisoned = YES", BRIDGE_SOURCE)
        poison_check = BRIDGE_SOURCE.index("if (amproj_nativeBridgePoisoned)")
        active_guard = (
            "if (amproj_nativeBridgeCompletion || "
            "amproj_nativeBridgeFinishPending)"
        )
        self.assertIn(active_guard, BRIDGE_SOURCE)
        active_check = BRIDGE_SOURCE.index(active_guard)
        self.assertLess(poison_check, active_check)
        self.assertIn("Fully close and reopen Alight Motion", BRIDGE_SOURCE)

    def test_native_failure_poison_prevents_late_swift_callback_reuse(self):
        failure_start = BRIDGE_SOURCE.index(
            "BOOL AMProjNativePackageImportBridgeFinishFailure"
        )
        failure_end = BRIDGE_SOURCE.index(
            "BOOL AMProjNativePackageImportBridgeIsBusy", failure_start
        )
        failure = BRIDGE_SOURCE[failure_start:failure_end]
        self.assertIn("AMProjPoisonNativeBridgeIfActive", failure)
        self.assertIn("late Swift callback", BRIDGE_SOURCE)
        self.assertIn("amproj_nativeBridgePoisoned ||", BRIDGE_SOURCE)

    def test_native_bridge_is_locked_to_verified_6255_binary(self):
        self.assertIn("0x01, 0xb7, 0x30, 0x17", BRIDGE_SOURCE)
        self.assertIn(
            "AMProjNativeLocalImportContinuation = 0x10026596cULL",
            BRIDGE_SOURCE,
        )
        self.assertIn(
            "AMProjPackageImporterMetadataAccessor = 0x100310768ULL",
            BRIDGE_SOURCE,
        )
        self.assertNotIn("0x100604ac4", BRIDGE_SOURCE)
        self.assertNotIn("AMProjNativeImportEntry", BRIDGE_SOURCE)
        self.assertIn("Alight Motion 6.2.55 (862)", BRIDGE_SOURCE)
        self.assertNotIn("AMProjNSStringToSwiftStringStub", BRIDGE_SOURCE)
        self.assertNotIn("AMProjSwiftBridgeReleaseStub", BRIDGE_SOURCE)
        self.assertNotIn("0x101fb678cULL", BRIDGE_SOURCE)
        self.assertNotIn("0x101fbc1bcULL", BRIDGE_SOURCE)
        self.assertIn("expectedLocalContinuation", BRIDGE_SOURCE)
        self.assertIn("expectedMetadataAccessor", BRIDGE_SOURCE)
        self.assertIn("LC_UUID", BRIDGE_SOURCE)
        self.assertIn("memcmp(localContinuation, expectedLocalContinuation", BRIDGE_SOURCE)
        self.assertIn("memcmp(metadataAccessor, expectedMetadataAccessor", BRIDGE_SOURCE)
        self.assertIn("allocObject(packageImporterMetadata, 0x10, 0x7)", BRIDGE_SOURCE)
        self.assertIn("dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)", BRIDGE_SOURCE)

    def test_arm64_shims_bridge_url_and_map_ten_continuation_arguments(self):
        self.assertIn("_AMProjBridgeNSURLToSwiftURL", BRIDGE_ASSEMBLY)
        self.assertIn("mov x8, x1", BRIDGE_ASSEMBLY)
        self.assertIn("br x9", BRIDGE_ASSEMBLY)
        self.assertIn("_AMProjCallNativeLocalImportContinuation", BRIDGE_ASSEMBLY)
        self.assertIn("ldr x11, [x29, #16]", BRIDGE_ASSEMBLY)
        self.assertIn("ldr x12, [x29, #24]", BRIDGE_ASSEMBLY)
        self.assertIn("ldr x13, [x29, #32]", BRIDGE_ASSEMBLY)
        self.assertIn("mov x0, x1", BRIDGE_ASSEMBLY)
        self.assertIn("mov x5, x6", BRIDGE_ASSEMBLY)
        self.assertIn("mov x6, x7", BRIDGE_ASSEMBLY)
        self.assertIn("mov x7, x11", BRIDGE_ASSEMBLY)
        self.assertIn("stp x12, x13, [sp, #-16]!", BRIDGE_ASSEMBLY)
        self.assertIn("blr x10", BRIDGE_ASSEMBLY)
        self.assertIn("add sp, sp, #16", BRIDGE_ASSEMBLY)
        self.assertIn(".cfi_startproc", BRIDGE_ASSEMBLY)
        self.assertIn(".cfi_endproc", BRIDGE_ASSEMBLY)
        self.assertIn("AMProjNativeImportBridge.S", MAKEFILE)
        self.assertEqual(MAKEFILE.count("AMProjNativeImportBridge.S"), 6)
        self.assertIn('"_AMProjBridgeNSURLToSwiftURL"', WORKFLOW)
        self.assertIn('"_AMProjCallNativeLocalImportContinuation"', WORKFLOW)
        self.assertNotIn('"_AMProjCallNativePackageImportBody"', WORKFLOW)

    def test_bridge_registers_after_launch_and_finishes_only_from_native_result(self):
        bootstrap = function_body(
            "static void amproj_bootstrapAfterLaunch",
            "__attribute__((constructor))",
        )
        legacy_gate = bootstrap.index("if (amproj_runtimeUsesLegacyImportHooks())")
        bridge_install = bootstrap.index("AMProjInstallNativePackageImportBridge()")
        disabled_branch = bootstrap.index("} else {", legacy_gate)
        self.assertLess(legacy_gate, bridge_install)
        self.assertLess(bridge_install, disabled_branch)
        self.assertIn(
            "AMProjRegisterNativePackageImportStarter(nil);",
            bootstrap[disabled_branch:],
        )
        self.assertIn("AMProjRegisterNativePackageImportStarter", BRIDGE_HEADER)
        self.assertIn("AMProjNativeImportCompletionThunk", BRIDGE_SOURCE)
        self.assertIn("AMProjFinishNativeBridge(success, error)", BRIDGE_SOURCE)
        self.assertIn("300 * NSEC_PER_SEC", BRIDGE_SOURCE)

    def test_native_failure_alert_completes_active_bridge_without_double_reset(self):
        present = function_body("static void hooked_presentVC", "#if AMPROJ_DEBUG")
        self.assertIn("AMProjNativePackageImportBridgeFinishFailure", present)
        self.assertIn("AMProjNativeAlertPresented", present)
        self.assertIn("if (!bridgeHandled)", present)
        finish = function_body(
            "static void amproj_finishNativePackageImport",
            "static void amproj_tryDispatchPendingImport",
        )
        self.assertIn("AMProjNativeAlertPresented", finish)

    def test_delegate_url_entrypoints_capture_project_before_original(self):
        entrypoints = (
            (
                "static BOOL hooked_applicationOpenURL",
                "static NSURL* amproj_projectURLFromUserActivity",
                "AMProjApplicationOpenURLIMP",
            ),
            (
                "static BOOL hooked_applicationContinueActivity",
                "static BOOL hooked_applicationHandleOpenURL",
                "AMProjApplicationContinueActivityIMP",
            ),
            (
                "static BOOL hooked_applicationHandleOpenURL",
                "static BOOL hooked_applicationLegacyOpenURL",
                "AMProjApplicationHandleOpenURLIMP",
            ),
            (
                "static BOOL hooked_applicationLegacyOpenURL",
                "static void hooked_sceneOpenURLContexts",
                "AMProjApplicationLegacyOpenURLIMP",
            ),
        )
        for signature, next_signature, native_imp_type in entrypoints:
            with self.subTest(entrypoint=signature):
                self.assert_capture_short_circuits_original(
                    signature, next_signature, native_imp_type
                )

    def test_modern_url_reentry_falls_back_to_immutable_native_imp(self):
        body = function_body(
            "static BOOL hooked_applicationOpenURL",
            "static NSURL* amproj_projectURLFromUserActivity",
        )
        self.assertIn("amproj_openURLForwardDepth &&", body)
        self.assertIn("original = amproj_nativeAppDelegateOpenURLIMP;", body)

    def test_reinstalled_hooks_preserve_base_implementation(self):
        tracked = function_body(
            "static IMP amproj_originalHookForReceiver",
            "static UIWindow* amproj_importForegroundWindow",
        )
        self.assertIn("IMP base;", SOURCE)
        self.assertIn("hooks[index].original != hooks[index].base", tracked)
        self.assertIn("return hooks[index].base;", tracked)
        self.assertIn("if (!hooks[index].base)", tracked)

    def test_cold_launch_records_candidates_and_filters_project_options_before_staging(self):
        recognizer = function_body(
            "static BOOL amproj_isIncomingProjectURL",
            "static UIViewController* amproj_topViewController",
        )
        self.assertIn('[extension isEqualToString:@"amproj"]', recognizer)
        self.assertIn('[extension isEqualToString:@"xml"]', recognizer)
        self.assertIn('[identifier isEqualToString:@"public.xml"]', recognizer)

        recorder = function_body(
            "static NSArray<NSURL *> *amproj_recordLaunchImportCandidates",
            "static NSDictionary *amproj_launchOptionsForNativeAppDelegate",
        )
        self.assertIn("amproj_recordDeferredLaunchCandidate", recorder)
        self.assertNotIn("amproj_captureSystemProjectURL", recorder)
        self.assertNotIn("amproj_handleIncomingProjectURL", recorder)
        self.assertNotIn("removeObjectForKey", recorder)
        self.assertIn("startAccessingSecurityScopedResource", recorder)
        self.assertIn("scopedURLs", recorder)
        self.assertIn("return [scopedURLs copy]", recorder)

        stager = function_body(
            "static NSDictionary* amproj_stageLaunchImportCandidate",
            "static void amproj_recordDeferredLaunchCandidate",
        )
        self.assertIn("NSFileCoordinator", stager)
        self.assertIn("amproj_streamCopyIncomingFile", stager)
        self.assertIn('stagedOptions[@"AMProjIncomingCleanupURL"]', stager)
        self.assertIn('stagedOptions[@"AMProjPreserveSource"] = @YES', stager)
        self.assertIn('@"import.launch_stage"', stager)
        self.assertNotIn("amproj_prepareCopiedArchive", stager)
        self.assertNotIn("amproj_handleIncomingProjectURL", stager)
        self.assertLess(
            stager.index("amproj_URLIsInDocumentsInbox"),
            stager.index("createDirectoryAtURL"),
        )

        deferred = function_body(
            "static void amproj_recordDeferredLaunchCandidate",
            "static NSArray<NSURL *> *amproj_recordLaunchImportCandidates",
        )
        first_dedupe = deferred.index("@synchronized")
        stage_call = deferred.index("amproj_stageLaunchImportCandidate")
        self.assertLess(first_dedupe, stage_call)
        self.assertIn(
            '![candidate[@"launch_staging_failed"] boolValue]',
            deferred[:stage_call],
        )
        self.assertIn("if (launchStaged && !existingStaged)", deferred)
        self.assertIn("discardedCandidate = existingCandidate", deferred)
        self.assertIn("discardedCandidate = newCandidate", deferred)
        self.assertIn("amproj_deferredLaunchImportCandidates[existingIndex] = newCandidate", deferred)
        self.assertIn("removeItemAtURL:cleanupURL", deferred)

        filterer = function_body(
            "static NSDictionary *amproj_launchOptionsForNativeAppDelegate",
            "static BOOL hooked_applicationDidFinish",
        )
        self.assertIn("NSMutableDictionary *filtered = [launchOptions mutableCopy]", filterer)
        self.assertIn("amproj_isIncomingProjectURL(launchURL, launchOptions)", filterer)
        self.assertNotIn("amproj_deferredLaunchCandidateWasStaged(launchURL)", filterer)
        self.assertIn(
            "[filtered removeObjectForKey:UIApplicationLaunchOptionsURLKey]",
            filterer,
        )
        self.assertIn("BOOL removedProjectLaunchURL = NO", filterer)
        self.assertIn("removedProjectLaunchURL = YES", filterer)
        self.assertIn("NSMutableDictionary *activities", filterer)
        self.assertIn(
            "amproj_isIncomingProjectURL(activityURL, activityOptions)", filterer
        )
        self.assertNotIn("amproj_deferredLaunchCandidateWasStaged(activityURL)", filterer)
        self.assertIn("BOOL removedProjectActivity = NO", filterer)
        self.assertIn("removedProjectActivity = YES", filterer)
        self.assertIn("[activities removeObjectForKey:key]", filterer)
        pair_cleanup = filterer.index("if (removedNestedProjectActivity)")
        self.assertIn(
            "removeObjectForKey:UIApplicationLaunchOptionsUserActivityTypeKey",
            filterer[pair_cleanup:],
        )
        self.assertIn(
            "[filtered removeObjectForKey:UIApplicationLaunchOptionsUserActivityTypeKey]",
            filterer[pair_cleanup:],
        )
        self.assertIn(
            "if (removedProjectLaunchURL || removedProjectActivity)", filterer
        )
        self.assertIn("remainingTopLevelActivityType", filterer)
        self.assertIn("remainingNestedActivityType", filterer)
        self.assertIn("kAMProjLaunchOptionsUserActivityKey", filterer)
        self.assertIn("kAMProjLaunchOptionsUserActivityKey =", SOURCE)
        self.assertNotIn(
            "launchOptions[UIApplicationLaunchOptionsUserActivityKey]", SOURCE
        )
        self.assertIn("return filtered", filterer)

        activity = ("project", "public.xml")
        other_activity = ("other", "com.example.other")
        original = {
            LaunchUserActivityFilterModel.ACTIVITY_KEY: activity,
            LaunchUserActivityFilterModel.TYPE_KEY: "public.xml",
            LaunchUserActivityFilterModel.DICTIONARY_KEY: {
                LaunchUserActivityFilterModel.ACTIVITY_KEY: activity,
                "other_activity": other_activity,
                LaunchUserActivityFilterModel.TYPE_KEY: "public.xml",
            },
            "unrelated": "preserved",
        }
        consumed = LaunchUserActivityFilterModel.filter(original, activity)
        self.assertNotIn(LaunchUserActivityFilterModel.ACTIVITY_KEY, consumed)
        self.assertNotIn(LaunchUserActivityFilterModel.TYPE_KEY, consumed)
        self.assertEqual(
            consumed[LaunchUserActivityFilterModel.DICTIONARY_KEY]["other_activity"],
            other_activity,
        )
        self.assertEqual(
            consumed[LaunchUserActivityFilterModel.DICTIONARY_KEY][
                LaunchUserActivityFilterModel.TYPE_KEY
            ],
            "com.example.other",
        )
        self.assertEqual(
            consumed["unrelated"], "preserved"
        )

        top_level_other = {
            LaunchUserActivityFilterModel.ACTIVITY_KEY: other_activity,
            LaunchUserActivityFilterModel.TYPE_KEY: "com.example.other",
            LaunchUserActivityFilterModel.DICTIONARY_KEY: {
                LaunchUserActivityFilterModel.ACTIVITY_KEY: activity,
                LaunchUserActivityFilterModel.TYPE_KEY: "public.xml",
            },
        }
        retained = LaunchUserActivityFilterModel.filter(top_level_other, activity)
        self.assertEqual(
            retained[LaunchUserActivityFilterModel.ACTIVITY_KEY], other_activity
        )
        self.assertEqual(
            retained[LaunchUserActivityFilterModel.TYPE_KEY], "com.example.other"
        )

        hook = function_body(
            "static BOOL hooked_applicationDidFinish",
            "static BOOL hooked_applicationContinueActivity",
        )
        record = hook.index("amproj_recordLaunchImportCandidates")
        filter_call = hook.index("amproj_launchOptionsForNativeAppDelegate")
        original = hook.index("IMP original")
        native_call = hook.index("self, _cmd, application, forwardedOptions);")
        restage = hook.index("amproj_restageFailedLaunchImportCandidates")
        self.assertLess(record, filter_call)
        self.assertLess(original, filter_call)
        self.assertLess(filter_call, native_call)
        self.assertLess(native_call, restage)
        self.assertIn("self, _cmd, application, forwardedOptions);", hook)
        self.assertIn('application_did_finish_after_native', hook)
        self.assertIn('@"forwarded_project_url_removed"', hook)
        self.assertLess(
            hook.index("self, _cmd, application, forwardedOptions);"),
            hook.index("stopAccessingSecurityScopedResource"),
        )

    def test_non_scene_cold_launch_stages_at_will_finish_before_did_finish(self):
        will_finish = function_body(
            "static BOOL hooked_applicationWillFinish",
            "static BOOL hooked_applicationDidFinish",
        )
        record = will_finish.index("amproj_recordLaunchImportCandidates")
        filter_call = will_finish.index("amproj_launchOptionsForNativeAppDelegate")
        original = will_finish.index("IMP original")
        native_call = will_finish.index("self, _cmd, application, forwardedOptions);")
        self.assertLess(record, filter_call)
        self.assertLess(original, filter_call)
        self.assertLess(filter_call, native_call)
        scope_release = will_finish.index("stopAccessingSecurityScopedResource")
        self.assertLess(native_call, scope_release)
        self.assertIn('application_will_finish', will_finish)
        self.assertIn("BOOL launched = YES", will_finish)
        self.assertIn('@"forwarded_project_url_removed"', will_finish)

        installer = function_body(
            "static BOOL amproj_installColdLaunchHook",
            "static BOOL amproj_installDeclaredURLHooks",
        )
        selector = installer.index(
            "@selector(application:willFinishLaunchingWithOptions:)"
        )
        add_method = installer.index("class_addMethod", selector)
        tracked_hook = installer.index("amproj_willFinishHooks", add_method)
        did_finish = installer.index(
            "@selector(application:didFinishLaunchingWithOptions:)"
        )
        self.assertLess(selector, add_method)
        self.assertLess(add_method, tracked_hook)
        self.assertLess(tracked_hook, did_finish)
        self.assertIn("@protocol(UIApplicationDelegate)", installer)
        self.assertIn('"B32@0:8@16@24"', installer)

        did_finish = function_body(
            "static BOOL hooked_applicationDidFinish",
            "static BOOL hooked_applicationContinueActivity",
        )
        self.assertLess(
            did_finish.index("self, _cmd, application, forwardedOptions);"),
            did_finish.index("stopAccessingSecurityScopedResource"),
        )

        warm = function_body(
            "static BOOL hooked_applicationOpenURL",
            "static NSURL* amproj_projectURLFromUserActivity",
        )
        self.assertIn(
            'amproj_captureSystemProjectURL(URL, @"application_open_url", options)',
            warm,
        )
        self.assertNotIn("application_will_finish", warm)

    def test_runtime_delegate_binding_and_pre_handoff_reinstall_url_hooks(self):
        delegate_hook = function_body(
            "static void hooked_applicationSetDelegate",
            "static NSDictionary* amproj_nativeParserElementSnapshot",
        )
        self.assertIn("orig_applicationSetDelegate(application, _cmd, delegate)", delegate_hook)
        self.assertIn("amproj_installImportHook();", delegate_hook)
        self.assertIn("strongApplication.delegate == strongDelegate", delegate_hook)
        self.assertIn('@"UIApplication.setDelegate"', delegate_hook)

        constructor = SOURCE[SOURCE.index("static void AMProjExportInit(void)") :]
        delegate_install = constructor.index("amproj_installApplicationDelegateHook();")
        cold_install = constructor.index("amproj_installColdLaunchHook();")
        self.assertLess(delegate_install, cold_install)
        self.assertIn("UIApplicationWillResignActiveNotification", constructor)
        will_resign = constructor.index("UIApplicationWillResignActiveNotification")
        scene_deactivate = constructor.index("UISceneWillDeactivateNotification")
        self.assertIn("amproj_installImportHook();", constructor[will_resign:scene_deactivate])

    def test_user_activity_type_reaches_every_xml_recognition_stage(self):
        activity_options = function_body(
            "static NSDictionary* amproj_projectOptionsFromUserActivity",
            "static NSDictionary* amproj_stageLaunchImportCandidate",
        )
        self.assertIn("activity.activityType", activity_options)
        self.assertIn('@"AMProjUserActivityType": activityType', activity_options)

        launch_pipeline = function_body(
            "static NSArray<NSURL *> *amproj_recordLaunchImportCandidates",
            "static BOOL hooked_applicationDidFinish",
        )
        self.assertGreaterEqual(
            launch_pipeline.count("amproj_projectOptionsFromUserActivity"), 3
        )
        self.assertIn(
            "launchOptions[kAMProjLaunchOptionsUserActivityKey]",
            launch_pipeline,
        )
        self.assertIn(
            "amproj_isIncomingProjectURL(activityURL, activityOptions)",
            launch_pipeline,
        )

        continuation = function_body(
            "static BOOL hooked_applicationContinueActivity",
            "static BOOL hooked_applicationHandleOpenURL",
        )
        self.assertIn("amproj_projectOptionsFromUserActivity(activity)", continuation)
        self.assertIn(
            'amproj_captureSystemProjectURL(URL, @"continue_user_activity", options)',
            continuation,
        )

    def test_cold_launch_failed_candidate_requires_durable_capture_before_consumption(self):
        helpers = function_body(
            "static NSDictionary* amproj_deferredLaunchCandidateForURL",
            "static BOOL amproj_captureSystemProjectURL",
        )
        self.assertIn('objectForKey:@"launch_staged"', helpers)
        self.assertIn('objectForKey:@"launch_staging_failed"', helpers)
        self.assertIn("amproj_removeFailedDeferredLaunchCandidateForURL", helpers)
        self.assertIn('[candidate[@"launch_staging_failed"] boolValue]', helpers)
        self.assertIn("removeObjectAtIndex", helpers)

        capture = function_body(
            "static BOOL amproj_captureSystemProjectURL",
            "static BOOL hooked_applicationOpenURL",
        )
        prepared = capture.index("BOOL prepared = NO")
        handler = capture.index("amproj_handleIncomingProjectURLWithResult")
        durable = capture.index("if (prepared)", handler)
        remove_failed = capture.index(
            "amproj_removeFailedDeferredLaunchCandidateForURL", durable
        )
        telemetry = capture.index('amproj_debugEvent(@"import.system_capture"')
        self.assertLess(prepared, handler)
        self.assertIn("&prepared", capture[handler:durable])
        self.assertLess(durable, remove_failed)
        self.assertLess(remove_failed, telemetry)
        self.assertIn('@"prepared": @(prepared)', capture)
        self.assertNotIn("result == AMProjIncomingURLAccepted", capture)

        incoming = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURL(",
        )
        rejected_claim = incoming[
            incoming.index("if (!amproj_claimImportTransaction") :
            incoming.index("amproj_markImportTransactionState")
        ]
        self.assertIn("duplicate ? AMProjIncomingURLAccepted", rejected_claim)
        self.assertNotIn("*prepared = YES", rejected_claim)

        restager = function_body(
            "static void amproj_restageFailedLaunchImportCandidates",
            "static NSDictionary *amproj_launchOptionsForNativeAppDelegate",
        )
        self.assertGreaterEqual(
            restager.count("amproj_deferredLaunchCandidateNeedsRestaging"), 2
        )
        self.assertGreaterEqual(restager.count("amproj_recordDeferredLaunchCandidate"), 2)

    def test_scene_partitions_project_contexts_before_forwarding(self):
        body = function_body(
            "static void hooked_sceneOpenURLContexts",
            "static void (*orig_projectsImportAlertViewDidLoad)",
        )
        partition = body.index("NSMutableSet *passthroughContexts")
        capture = body.index("amproj_captureSystemProjectURL", partition)
        passthrough = body.index("[passthroughContexts addObject:context]", capture)
        native_forward = body.index("[passthroughContexts copy]", capture)
        self.assertLess(capture, passthrough)
        self.assertLess(passthrough, native_forward)
        self.assertIn("consumedCount++;", body[capture:passthrough])
        self.assertIn("continue;", body[capture:passthrough])
        self.assertIn("if (passthroughContexts.count &&", body)
        self.assertNotIn("amproj_stageForwardedProjectURL", body)

    def test_scene_cold_launch_captures_connection_options_before_native(self):
        recorder = function_body(
            "static NSArray<NSURL *> *amproj_recordSceneConnectionCandidates",
            "static UISceneConfiguration *hooked_applicationConfigurationForConnecting",
        )
        self.assertIn("connectionOptions.URLContexts", recorder)
        self.assertIn("amproj_recordDeferredLaunchCandidate", recorder)
        self.assertIn("connectionOptions.userActivities", recorder)
        self.assertNotIn("amproj_captureSystemProjectURL", recorder)

        configuration = function_body(
            "static UISceneConfiguration *hooked_applicationConfigurationForConnecting",
            "static void hooked_sceneWillConnectToSession",
        )
        record_call = configuration.index("amproj_recordSceneConnectionCandidates")
        native_call = configuration.index(
            "configuration = ((AMProjApplicationConfigurationForConnectingIMP)original)"
        )
        scope_release = configuration.index("stopAccessingSecurityScopedResource")
        self.assertLess(record_call, native_call)
        self.assertLess(native_call, scope_release)
        self.assertIn("amproj_recordSceneConnectionCandidates", configuration)
        self.assertIn("AMProjApplicationConfigurationForConnectingIMP", configuration)
        self.assertIn("return configuration", configuration)

        scene_connect = function_body(
            "static void hooked_sceneWillConnectToSession",
            "static void hooked_sceneOpenURLContexts",
        )
        self.assertLess(
            scene_connect.index("self, _cmd, scene, session, connectionOptions);"),
            scene_connect.index("stopAccessingSecurityScopedResource"),
        )

        installer = function_body(
            "static BOOL amproj_installColdLaunchHook",
            "static BOOL amproj_installDeclaredURLHooks",
        )
        self.assertIn(
            "application:configurationForConnectingSceneSession:options:",
            installer,
        )
        self.assertIn("amproj_configurationHooks", installer)

    def test_export_hooks_use_exact_controller_and_semantic_share_action(self):
        navigation = function_body(
            "static void hooked_navigationPush",
            "static BOOL amproj_isNativeImportFailureAlert",
        )
        self.assertIn("orig_navigationPush", navigation)
        self.assertIn("amproj_isSharePackageController(viewController)", navigation)
        self.assertIn("amproj_isShareExportHostController(viewController)", navigation)
        self.assertIn("amproj_installShareExportHook", navigation)

        installer = function_body(
            "static void amproj_installShareExportHook",
            "#if AMPROJ_DEBUG",
        )
        self.assertIn('@"AlightMotion.ShareNC"', installer)
        self.assertIn('objc_getClass("_TtC12AlightMotion7ShareNC")', installer)
        self.assertIn('@"onTapExport:"', installer)
        self.assertIn("hooked_shareNCOnTapExport", installer)

        present = function_body(
            "static void hooked_presentVC",
            "#if AMPROJ_DEBUG",
        )
        self.assertIn("amproj_isSharePackageController(controller)", present)
        self.assertIn("amproj_isShareExportHostController(controller)", present)
        self.assertIn("amproj_installShareExportHook", present)

    def test_navigation_fallback_intercepts_project_package_before_native_push(self):
        navigation = function_body(
            "static void hooked_navigationPush",
            "static BOOL amproj_isNativeImportFailureAlert",
        )
        package_check = navigation.index("amproj_isSharePackageController(viewController)")
        direct_export = navigation.index("amproj_startDirectExport", package_check)
        original_push = navigation.index("orig_navigationPush", direct_export)
        self.assertLess(package_check, direct_export)
        self.assertLess(direct_export, original_push)
        self.assertIn('@"direct.native_package_navigation"', navigation)
        self.assertIn('if ([mode isEqualToString:@"observe"])', navigation)
        self.assertIn("return;", navigation[direct_export:original_push])
        self.assertIn("orig_navigationPush(self, _cmd, viewController, animated)", navigation)

    def test_v44_cloud_does_not_scan_or_activate_unrelated_paywall_controls(self):
        scan = function_body(
            "static void amproj_schedulePaywallScan",
            "// MARK: - Startup paywall recovery",
        )
        self.assertIn("#if !AMPROJ_DEBUG", scan)
        self.assertIn("return;", scan)
        self.assertIn("#else", scan)
        self.assertIn("amproj_dismissDetectedPaywallFrom", scan)

    def test_media_browser_demo_preferences_are_reset_without_touching_other_presets(self):
        reset = function_body(
            "static void amproj_restorePhotoAlbumMode",
            "static void amproj_flushDebugEvents",
        )
        for key in ("demo_mode_enabled", "DemoMode", "user_demo_mode"):
            self.assertIn('@"' + key + '"', reset)
        self.assertIn("[defaults setBool:NO forKey:key]", reset)
        self.assertNotIn('@"user_mode"', reset)
        self.assertEqual(SOURCE.count("amproj_restorePhotoAlbumMode();"), 2)

    def test_cold_launch_successful_stage_replaces_prior_failed_candidate(self):
        body = function_body(
            "static void amproj_recordDeferredLaunchCandidate",
            "static NSArray<NSURL *> *amproj_recordLaunchImportCandidates",
        )
        replace = body.index("if (launchStaged && !existingStaged)")
        keep_success = body.index(
            "amproj_deferredLaunchImportCandidates[existingIndex] = newCandidate",
            replace,
        )
        discard_failure = body.index("discardedCandidate = existingCandidate", replace)
        self.assertLess(replace, keep_success)
        self.assertLess(keep_success, discard_failure)

    def test_cold_launch_failed_stage_cannot_replace_prior_success(self):
        body = function_body(
            "static void amproj_recordDeferredLaunchCandidate",
            "static NSArray<NSURL *> *amproj_recordLaunchImportCandidates",
        )
        replace = body.index("if (launchStaged && !existingStaged)")
        keep_existing = body.index("discardedCandidate = newCandidate", replace)
        cleanup = body.index(
            'if ([discardedCandidate[@"launch_staged"] boolValue])',
            keep_existing,
        )
        self.assertLess(replace, keep_existing)
        self.assertLess(keep_existing, cleanup)

    def test_provider_callback_copies_synchronously_while_grant_is_valid(self):
        capture = function_body(
            "static BOOL amproj_captureSystemProjectURL",
            "static BOOL hooked_applicationOpenURL",
        )
        self.assertIn("BOOL copyOffMainThread = stableInboxURL;", capture)
        self.assertNotIn("stableInboxURL || heldSecurityScope", capture)
        worker = capture.index("if (copyOffMainThread)")
        synchronous = capture.index("capture();", worker)
        self.assertLess(worker, synchronous)

    def test_inbox_path_comparison_normalizes_private_var_alias(self):
        normalizer = function_body(
            "static NSString* amproj_normalizedFilePath(NSURL *URL) {",
            "static BOOL amproj_URLIsInDocumentsInbox",
        )
        self.assertIn("URLByResolvingSymlinksInPath", normalizer)
        self.assertIn('@"/private/var/"', normalizer)
        self.assertIn('@"/private".length', normalizer)
        inbox = function_body(
            "static BOOL amproj_URLIsInDocumentsInbox",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
        )
        self.assertEqual(inbox.count("amproj_normalizedFilePath"), 2)

    def test_activation_prioritizes_launch_retry_before_inbox_scan(self):
        marker = SOURCE.index("UIApplicationDidBecomeActiveNotification")
        body = SOURCE[marker : marker + 2400]
        scan = body.index('amproj_scanLocalImportInboxes(@"did_become_active", nil)')
        retry = body.index("amproj_retryDeferredLaunchImportCandidates()")
        self.assertLess(retry, scan)
        deferred = function_body(
            "static void amproj_retryDeferredLaunchImportCandidates",
            "static BOOL amproj_captureSystemProjectURL",
        )
        self.assertIn('candidate[@"launch_staging_failed"]', deferred)
        self.assertIn('candidate[@"launch_retry_count"] unsignedIntegerValue', deferred)
        silent_errors = deferred.index('options[@"AMProjSilentErrors"] =')
        self.assertIn("launchStagingFailed && retryCount < maxLaunchRetryCount", deferred[silent_errors:])
        explicit_retry = deferred.index('options[@"AMProjExplicitRetry"] = @YES')
        handler = deferred.index("amproj_handleIncomingProjectURLSafely")
        self.assertIn(
            "launchStagingFailed && retryCount > 0",
            deferred[silent_errors:explicit_retry],
        )
        self.assertLess(explicit_retry, handler)
        self.assertIn("result == AMProjIncomingURLFailed && launchStagingFailed", deferred)
        self.assertIn('retryCandidate[@"launch_retry_count"]', deferred)
        self.assertIn('import.launch_candidate_requeued', deferred)
        self.assertIn('import.launch_candidate_delayed_retry', deferred)
        self.assertIn('import.launch_candidate_exhausted', deferred)
        self.assertIn('maxLaunchRetryCount', deferred)
        self.assertIn("dispatch_after", deferred)
        self.assertIn('@"_activation_retry"', deferred)
        self.assertNotIn('@"_silent_retry"', deferred)
        self.assertIn('@"launch_staged"', deferred)
        self.assertIn("amproj_importInboxQueue()", deferred)

        incoming = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURL(",
        )
        clear = incoming.index('options[@"AMProjExplicitRetry"]')
        claim = incoming.index("amproj_claimImportTransaction")
        self.assertIn("amproj_clearImportSuppression", incoming[clear:claim])
        self.assertLess(clear, claim)

    def test_native_package_validation_accepts_missing_manifest_for_normalization(self):
        body = function_body(
            "static BOOL amproj_validateIncomingArchive",
            "static NSString* amproj_importCacheFilename",
        )
        self.assertIn("if (manifestCount > 1)", body)
        self.assertNotIn("manifestCount != 1", body)
        self.assertNotIn("manifestCount == 0 ?", body)
        self.assertIn("at most one manifest.txt", body)

    def test_archive_validation_adds_ios_media_signatures_before_queue(self):
        body = function_body(
            "static void amproj_prepareCopiedArchive",
            "static void amproj_activateNextPendingImport",
        )
        worker = body.index("dispatch_async(amproj_importInboxQueue()")
        validate = body.index("amproj_validateIncomingArchive")
        original_route = body.index('if (inputManifestCount == 1)')
        prepare = body.index("AMProjPrepareNativeImport", original_route)
        original_assignment = body.index("preparedURL = archiveSnapshot", original_route)
        project_normalize = body.index('route = @"ios_project_archive_normalized"', original_route)
        legacy_route = body.index('[[@"ios-normalized-"', project_normalize)
        normalize = body.index("AMProjNormalizeProjectArchive", legacy_route)
        queue = body.index("amproj_queuePreparedImport(preparedURL", legacy_route)
        self.assertLess(worker, validate)
        self.assertLess(validate, original_route)
        self.assertLess(original_route, prepare)
        self.assertLess(prepare, original_assignment)
        self.assertLess(original_assignment, project_normalize)
        self.assertLess(original_route, legacy_route)
        self.assertLess(legacy_route, normalize)
        self.assertLess(normalize, queue)
        self.assertIn('route = @"validated_original_package"', body[original_route:legacy_route])
        self.assertIn('AMProjNormalizeProjectArchive', body[original_route:legacy_route])
        self.assertIn('route = @"ios_project_archive_normalized"', body[original_route:legacy_route])
        self.assertIn('preparationMetrics[@"rewritten_project_scene_count"]', body)
        self.assertIn('@"project_scene_count"', body)
        self.assertIn('route = @"legacy_ios_media_normalized"', body[legacy_route:queue])
        self.assertNotIn("A multi-scene package is missing iOS media signatures", body)
        self.assertNotIn("signatureRewrites > 0 && inputXMLCount == 1", body)
        self.assertIn('preparationMetrics[@"missing_reference_count"]', body)
        self.assertIn('import.missing_media_signatures', body)
        self.assertIn("amproj_storeImportProjectTitle", body)
        self.assertNotIn("amproj_captureImportPersistenceSnapshot", body)

    def test_imported_font_uri_is_resolved_through_sandbox_scan(self):
        parser = function_body(
            "static NSString* amproj_importedFontFilename",
            "static NSString* amproj_scannableResourceFilename",
        )
        self.assertIn('isEqualToString:@"imported"', parser)
        self.assertIn("components.queryItems.count != 1", parser)
        self.assertIn('isEqualToString:@"name"', parser)
        self.assertIn('isEqualToString:@"ttf"', parser)
        self.assertIn('isEqualToString:@"otf"', parser)
        resolver = function_body(
            "static NSDictionary<NSString *, NSURL *>* amproj_resolveInternalResources",
            "static NSURL* amproj_resolveResourceReference",
        )
        self.assertIn("NSApplicationSupportDirectory", resolver)
        self.assertIn("NSDocumentDirectory", resolver)
        self.assertIn("NSLibraryDirectory", resolver)
        self.assertIn('amproj_resourceLookupEventName(reference)', resolver)
        self.assertIn('@"direct.font_resource"', SOURCE)
        self.assertNotIn("CoreText", MAKEFILE)

    def test_incomplete_resource_archive_is_rejected_before_native_bridge(self):
        body = function_body(
            "static void amproj_prepareCopiedArchive",
            "static void amproj_activateNextPendingImport",
        )
        missing = body.index("NSUInteger missingReferences")
        queue = body.index("amproj_queuePreparedImport(preparedURL", missing)
        reject = body.index("if (missingReferences)", missing)
        reject_branch = body[reject:queue]
        self.assertIn('amproj_debugEvent(@"import.missing_resources"', reject_branch)
        self.assertIn('action": @"reject_incomplete_package"', reject_branch)
        self.assertIn("missing_reference_names", reject_branch)
        self.assertIn("amproj_releaseImportTransaction(transactionID, NO)", reject_branch)
        self.assertIn("amproj_writeImportBreadcrumb", reject_branch)
        self.assertIn("amproj_presentImportError(missingMessage)", reject_branch)
        self.assertIn("return;", reject_branch)
        self.assertNotIn("forward_to_native_importer", reject_branch)
        self.assertNotIn("amproj_queuePreparedImport", reject_branch)

    def test_prepared_zip_dispatches_only_to_local_package_bridge(self):
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("AMProjNativePackageImportStarter starter", dispatch)
        self.assertIn("started = starter(URL, name", dispatch)
        self.assertIn("amproj_finishNativePackageImport", dispatch)
        self.assertIn('amproj_debugEvent(@"import.local_bridge_start"', dispatch)
        self.assertNotIn("documentPicker", dispatch)
        self.assertNotIn("Templates", dispatch)
        self.assertNotIn("AMProjApplicationOpenURLIMP", dispatch)
        self.assertNotIn("amproj_nativeAppDelegateOpenURLIMP", dispatch)
        self.assertNotIn("amproj_forwardPreparedXMLToNative", SOURCE)

    def test_not_ready_project_screen_retries_without_dropping_the_package(self):
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        retry = dispatch.index("BOOL retryable")
        clear = dispatch.index("amproj_pendingImportURL = nil", retry)
        self.assertLess(retry, clear)
        self.assertIn('startError.userInfo[@"AMProjRetryable"]', dispatch)
        self.assertIn('amproj_debugEvent(@"import.local_bridge_retry"', dispatch)
        self.assertIn("amproj_captureActivatedPackageBaselines", dispatch[retry:clear])
        self.assertNotIn(
            "amproj_tryDispatchPendingImport(generation)", dispatch[retry:clear]
        )
        self.assertIn('@{ @"AMProjRetryable": @YES }', BRIDGE_SOURCE)
        self.assertNotIn("amproj_nativeImportForwardDepth", SOURCE)

    def test_copied_archives_use_application_support_and_expire(self):
        cache = function_body(
            "static NSURL* amproj_importCacheRoot",
            "typedef NS_ENUM(NSInteger, AMProjImportFileError)",
        )
        self.assertIn("NSApplicationSupportDirectory", cache)
        self.assertIn("AMProjImports", cache)
        self.assertIn("-7.0 * 24.0 * 60.0 * 60.0", cache)
        self.assertNotIn('@".persistent-assets"', cache)

    def test_four_of_four_requires_bridge_persistence_completion(self):
        finish = function_body(
            "static void amproj_finishNativePackageImport",
            "static void amproj_tryDispatchPendingImport",
        )
        success_branch = finish.index("if (success)")
        self.assertNotIn('@"AMProj v28 · 4/4', finish[success_branch:])
        self.assertIn("amproj_importVerificationActive = YES", finish[success_branch:])
        self.assertIn("amproj_scheduleImportPersistenceProbe", finish[success_branch:])
        gate = finish.index("amproj_importVerificationActive = YES", success_branch)
        probe = finish.index("amproj_scheduleImportPersistenceProbe", success_branch)
        self.assertLess(gate, probe)
        self.assertIn("verificationGeneration != amproj_importVerificationGeneration", finish)
        self.assertIn('@"verifying_project_row"', finish[success_branch:])
        self.assertIn("amproj_verifyImportedProjectRow", finish[success_branch:])
        self.assertIn("amproj_endNativeImportObservation", finish)
        self.assertIn("amproj_importDispatchCoolingDown = NO", finish)

        verification = function_body(
            "static void amproj_verifyImportedProjectRow",
            "static void amproj_finishNativePackageImport",
        )
        verified_branch = verification[verification.index("if (verified)") :]
        self.assertIn('@"import.project_row_verified"', verification)
        # v40 accepts a verified complete template when this AM build does not
        # create a project row directly.
        self.assertIn("amproj_completePackageTransaction", verified_branch)
        self.assertIn('AMProj · 4/4', SOURCE)
        self.assertIn('amproj_completePackageAsTemplate', verification)
        self.assertNotIn('amproj_beginTemplatePromotion(', verification)
        self.assertNotIn('amproj_beginSwiftUITemplatePromotion(', verification)
        self.assertIn("amproj_failImportedProjectVerification", verification)
        verification_failure = function_body(
            "static void amproj_failImportedProjectVerification",
            "static void amproj_verifyImportedProjectRow",
        )
        self.assertIn('@"import.project_row_missing"', verification_failure)
        self.assertIn(
            'amproj_resumeQueuedImports(@"project_row_missing")',
            verification_failure,
        )
        self.assertNotIn("4/4", function_body(
            "static void hooked_projectsImportAlertViewDidLoad",
            "static void hooked_projectsImportAlertOnPressImport",
        ))
        self.assertIn("AMProj · 4/4", SOURCE)

    def test_project_verifier_uses_real_uikit_lists_and_persistence_evidence(self):
        self.assertNotIn('@"pCollectionView"', SOURCE)
        lists = function_body(
            "static void amproj_collectVisibleProjectLists",
            "static NSArray<UIView *> *amproj_visibleProjectLists",
        )
        self.assertIn("UICollectionView.class", lists)
        self.assertIn("UITableView.class", lists)
        count = function_body(
            "static NSInteger amproj_visibleProjectsRowCount",
            "static BOOL amproj_persistencePathIsPluginOwned",
        )
        self.assertIn("numberOfItemsInSection", count)
        self.assertIn("numberOfRowsInSection", count)
        verifier = function_body(
            "static void amproj_verifyImportedProjectRow",
            "static void amproj_finishNativePackageImport",
        )
        self.assertIn("projectTitlePresentAtBaseline", verifier)
        self.assertIn("projectTitleMatchBaselineCount", verifier)
        self.assertIn("BOOL verified = probeTransaction.persistenceVerified", verifier)
        self.assertIn("amproj_newTemplateCandidateForTransaction", verifier)
        self.assertIn('@"import.project_title_baseline"', SOURCE)
        persistence = function_body(
            "static NSDictionary* amproj_captureImportPersistenceSnapshot",
            "static void amproj_storeImportProjectTitle",
        )
        self.assertIn('@"Documents"', persistence)
        self.assertIn('@"Library"', persistence)
        self.assertIn("NSURLContentModificationDateKey", persistence)
        self.assertIn('@"persistence_delta"', SOURCE)
        self.assertIn('@"persistence_verified"', SOURCE)
        self.assertIn('@"native_temp_consumed"', SOURCE)
        self.assertIn('@"project_ui_refreshed"', SOURCE)
        self.assertIn('@"project_row_verified"', SOURCE)

    def test_native_failure_alert_is_observed_without_replacing_it(self):
        detector = function_body(
            "static BOOL amproj_isNativeImportFailureAlert",
            "static void hooked_presentVC",
        )
        self.assertIn("amproj_nativeImportObservationActive", detector)
        self.assertIn("UIAlertController.class", detector)
        self.assertIn('containsString:@"import failed"', detector)
        self.assertIn('containsString:@"upload failed"', detector)
        self.assertIn('containsString:@"corrupt"', detector)
        self.assertIn('containsString:@"missing media"', detector)
        self.assertIn('containsString:@"\\u5a92\\u4f53\\u7f3a\\u5931"', detector)

        present = function_body(
            "static void hooked_presentVC",
            "#if AMPROJ_DEBUG",
        )
        self.assertIn('amproj_debugEvent(@"import.native_failure_alert"', present)
        self.assertIn("amproj_currentNativeParserSnapshot", present)
        self.assertIn("amproj_visibleNativeParserSummary", present)
        self.assertIn("amproj_endNativeImportObservation", present)
        self.assertIn("amproj_flushDebugEvents", present)
        self.assertIn("AMProj \\u00b7 E40", present)
        self.assertLess(
            present.index('amproj_debugEvent(@"import.native_failure_alert"'),
            present.index("amproj_endNativeImportObservation"),
        )
        self.assertIn(
            "orig_presentVC(self, _cmd, controller, animated, completion)", present
        )

    def test_scene_parser_probe_records_semantic_error_location_safely(self):
        count_reader = function_body(
            "static NSUInteger amproj_nativeSceneParserErrorCount",
            "static NSMutableArray<NSString *>* amproj_nativeParserElementStack",
        )
        self.assertIn('class_getInstanceVariable([delegate class], "errors")', count_reader)
        self.assertIn("class_getInstanceSize", count_reader)
        self.assertGreaterEqual(count_reader.count("vm_read_overwrite"), 1)
        self.assertNotIn("object_getIvar", count_reader)

        recorder = function_body(
            "static void amproj_recordNativeSceneParserError",
            "static void hooked_nativeXMLParserDidStartElement",
        )
        self.assertIn('snapshot[@"semantic_error_count"]', recorder)
        self.assertIn('snapshot[@"element_path"]', recorder)
        self.assertIn('amproj_debugEvent(@"import.native_scene_error"', recorder)

        parser = function_body(
            "static BOOL hooked_nativeXMLParserParse",
            "static void amproj_installNativeXMLDelegateHook",
        )
        self.assertIn('containsString:@"SceneParserDelegate"', parser)
        self.assertIn("parser.parserError", parser)
        self.assertIn("amproj_storeNativeParserSnapshot", parser)

        installer = function_body(
            "static void amproj_installNativeXMLDelegateHook",
            "static void amproj_installNativeXMLParserHook",
        )
        self.assertIn("parser:didStartElement:namespaceURI:qualifiedName:attributes:", installer)
        self.assertIn("parser:didEndElement:namespaceURI:qualifiedName:", installer)
        self.assertNotIn("parser:foundCharacters:", installer)

        parse_installer = function_body(
            "static void amproj_installNativeXMLParserHook",
            "static NSString* amproj_compactNativeDiagnostic",
        )
        self.assertIn("#if AMPROJ_DEBUG", parse_installer)

    def test_native_xml_diagnostics_are_opt_in_during_import_stability_testing(self):
        install = function_body(
            "static void amproj_installImportHook(void)",
            "static void amproj_removeBootstrapObservers",
        )
        self.assertIn("AMPROJ_ENABLE_NATIVE_XML_DIAGNOSTICS", install)
        self.assertIn("disabled_for_native_import_stability", install)

    def test_tracked_hook_refuses_to_swizzle_when_original_storage_is_full(self):
        store = function_body(
            "static BOOL amproj_storeOriginalHook",
            "static UIWindow* amproj_importForegroundWindow",
        )
        self.assertIn("return NO;", store)
        installer = function_body(
            "static BOOL amproj_installTrackedHook",
            "static NSDictionary* amproj_nativeParserElementSnapshot",
        )
        self.assertGreaterEqual(
            installer.count("if (!amproj_storeOriginalHook"), 2
        )

    def test_native_bridge_blocks_queue_until_completion(self):
        queue = function_body(
            "static void amproj_queuePreparedImport",
            "static void amproj_resumeQueuedImports",
        )
        resume = function_body(
            "static void amproj_resumeQueuedImports",
            "static BOOL amproj_handleImportCommandURL",
        )
        self.assertIn("!amproj_nativeImportObservationActive", queue)
        self.assertIn("amproj_nativeImportObservationActive", resume)
        finish = function_body(
            "static void amproj_finishNativePackageImport",
            "static void amproj_tryDispatchPendingImport",
        )
        self.assertIn("amproj_endNativeImportObservation", finish)
        self.assertIn("amproj_importDispatchCoolingDown = NO", finish)
        self.assertIn("amproj_resumeQueuedImports", finish)

    def test_alert_hook_install_retries_until_swift_class_exists(self):
        install = function_body(
            "static void amproj_installProjectsImportAlertHook",
            "static void amproj_installImportHook",
        )
        lookup = install.index('NSClassFromString(@"AlightMotion.ProjectsImportAlert")')
        missing_return = install.index("if (!cls) return;")
        once = install.index("dispatch_once(&onceToken")
        self.assertLess(lookup, missing_return)
        self.assertLess(missing_return, once)

    def test_unavailable_bridge_times_out_without_template_fallback(self):
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("CFAbsoluteTimeGetCurrent() >= amproj_pendingImportDeadline", dispatch)
        self.assertIn('amproj_debugEvent(@"import.local_bridge_timeout"', dispatch)
        self.assertIn('AMProjNativePackageImportStarter starter', dispatch)
        self.assertNotIn("TemplatesListVC", dispatch)
        self.assertNotIn("documentPicker", dispatch)

    def test_inactive_queue_waits_without_expiring(self):
        body = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        inactive = body.index("application.applicationState != UIApplicationStateActive")
        deadline = body.index("CFAbsoluteTimeGetCurrent() >= amproj_pendingImportDeadline")
        self.assertLess(inactive, deadline)

    def test_inbox_skip_continues_to_later_files(self):
        body = function_body(
            "static BOOL amproj_scanDocumentsInboxNow",
            "static NSDictionary* amproj_shareRequestDescriptor",
        )
        self.assertIn("AMProjIncomingURLResult result", body)
        failure = body.index("if (result == AMProjIncomingURLFailed)")
        failure_continue = body.index("continue;", failure)
        self.assertIn('@"import.inbox_failed"', body[failure:failure_continue])
        self.assertNotIn("if (!prepared) break;", body)

    def test_share_scan_continues_after_automatic_duplicate_or_failure(self):
        share = function_body(
            "static BOOL amproj_scanShareInboxNow",
            "static void amproj_scanLocalImportInboxes",
        )
        self.assertIn("if (prepared || requestedID.length) return YES;", share)
        self.assertNotIn(
            "prepared || result == AMProjIncomingURLAccepted || requestedID.length",
            share,
        )
        worker = function_body(
            "static void amproj_scanLocalImportInboxes",
            "static void amproj_retryDeferredLaunchImportCandidates",
        )
        requested = worker.index("if (currentRequest.length)")
        documents = worker.index("amproj_scanDocumentsInboxNow", requested)
        share_first = worker.index(
            "amproj_scanShareInboxNow(currentSource, currentRequest)", requested
        )
        self.assertLess(share_first, documents)

    def test_duplicate_owner_failure_preserves_waiter_cache(self):
        release = function_body(
            "static void amproj_releaseImportTransaction(",
            "static void amproj_releaseImportTransactionForURL",
        )
        self.assertIn('if (![cleanup[@"success"] boolValue]) continue;', release)
        self.assertIn("removeObjectForKey:dependent.transactionID", release)

    def test_late_transaction_cannot_roll_visible_status_back_to_one_of_four(self):
        status = function_body(
            "static void amproj_showImportStatusForTransaction",
            "static void amproj_showImportStatus(",
        )
        self.assertIn(
            "amproj_importTransactionForID(amproj_visibleStatusTransactionID)",
            status,
        )
        self.assertIn("if (visibleTransaction)", status)
        self.assertIn('reason": @"stale_transaction"', status)
        handler = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURL(",
        )
        capture = handler[handler.index("dispatch_async(dispatch_get_main_queue()") :]
        self.assertIn("AMProjImportTransaction *visibleTransaction", capture)
        self.assertIn("if (!visibleTransaction ||", capture)

    def test_scan_exception_requeues_current_request(self):
        scan = function_body(
            "static void amproj_scanLocalImportInboxes",
            "static void amproj_retryDeferredLaunchImportCandidates",
        )
        catch = scan[scan.index("@catch (NSException *exception)") :]
        self.assertIn("retrySource = amproj_pendingScanSource.length", catch)
        self.assertIn(" : currentSource", catch)
        self.assertIn("retryRequest = amproj_pendingScanRequestID.length", catch)
        self.assertIn(" : currentRequest", catch)

    def test_deferred_launch_tail_is_restored_when_a_transaction_is_live(self):
        retry = function_body(
            "static void amproj_retryDeferredLaunchImportCandidates",
            "static BOOL amproj_captureSystemProjectURL",
        )
        self.assertIn("subarrayWithRange:NSMakeRange(index", retry)
        self.assertIn("amproj_deferredLaunchImportCandidates", retry)
        self.assertIn("import.launch_candidates_deferred", retry)
        resume = function_body(
            "static void amproj_resumeQueuedImports",
            "static BOOL amproj_handleImportCommandURL",
        )
        self.assertIn("amproj_hasDeferredLaunchImportCandidates()", resume)
        self.assertIn("amproj_retryDeferredLaunchImportCandidates()", resume)

    def test_queue_rejects_active_verifying_and_released_transactions(self):
        queue = function_body(
            "static void amproj_queuePreparedImport",
            "static void amproj_resumeQueuedImports",
        )
        self.assertIn("amproj_activeNativeImportTransactionID", queue)
        self.assertIn("amproj_importVerificationTransactionID", queue)
        self.assertIn('@"native_active" : @"row_verification"', queue)
        activate = function_body(
            "static void amproj_activateNextPendingImport",
            "static AMProjNativePackageImportStarter amproj_nativePackageImportStarter",
        )
        self.assertIn("transaction.state != AMProjImportTransactionQueued", activate)
        self.assertIn('@"transaction_released"', activate)
        stale = activate.index('amproj_debugEvent(@"import.stale_queue_suppressed"')
        pending = activate.index("amproj_pendingImportURL = URL")
        self.assertLess(stale, pending)

    def test_duplicate_fingerprint_waits_for_owner_before_cleanup(self):
        self.assertIn("duplicateOfFingerprint", SOURCE)
        self.assertIn("amproj_importDuplicateOwners", SOURCE)
        self.assertIn('@"duplicate_waiting"', SOURCE)
        duplicate = function_body(
            "if (!amproj_claimImportFingerprint(transactionID, destination, fingerprint,",
            'amproj_debugEvent(@"import.fingerprint_claimed"',
        )
        self.assertIn("waitingForOwner", duplicate)
        self.assertIn("if (!waitingForOwner)", duplicate)
        self.assertIn("kept_for_owner_result", duplicate)

    def test_async_import_entrypoints_use_exception_safe_wrapper(self):
        self.assertGreaterEqual(
            SOURCE.count("amproj_handleIncomingProjectURLSafely("), 5
        )
        self.assertIn("@catch (NSException *exception)", SOURCE)
        self.assertIn('@"import.exception"', SOURCE)

    def test_native_bridge_busy_blocks_queue_progression(self):
        self.assertIn("AMProjNativePackageImportBridgeIsBusy", BRIDGE_HEADER)
        self.assertIn("amproj_nativeBridgePoisoned ||", BRIDGE_SOURCE)
        self.assertIn("native_bridge_busy_or_poisoned", SOURCE)

    def test_poisoned_bridge_pauses_without_retry_loop_and_keeps_cache(self):
        self.assertIn(
            "AMProjNativePackageImportBridgeRequiresRestart", BRIDGE_HEADER
        )
        self.assertIn(
            "static BOOL amproj_pauseForNativeBridgeRestart", SOURCE
        )
        pause = function_body(
            "static BOOL amproj_pauseForNativeBridgeRestart",
            "static void amproj_prepareCopiedArchive",
        )
        self.assertIn("native_bridge_poisoned", pause)
        self.assertIn("amproj_presentImportErrorOfferingPicker(message, NO)", pause)
        self.assertIn("\\u5df2\\u4fdd\\u7559", pause)
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("AMProjNativePackageImportBridgeRequiresRestart()", dispatch)
        self.assertIn("return;", dispatch[dispatch.index(
            "AMProjNativePackageImportBridgeRequiresRestart()"
        ):])

    def test_recognized_copy_failures_are_not_reported_as_accepted(self):
        body = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURL(",
        )
        self.assertGreaterEqual(body.count("return AMProjIncomingURLFailed;"), 2)
        self.assertNotRegex(body, re.compile(r"return\s+(YES|NO);"))
        self.assertIn("amproj_prepareCopiedArchive", body)

    def test_build_865_identity_is_exact_version_and_build_pair(self):
        identity = function_body(
            "static BOOL amproj_runtimeIsBuild865",
            "static BOOL amproj_runtimeUsesLegacyImportHooks",
        )
        self.assertIn('CFBundleShortVersionString', identity)
        self.assertIn('CFBundleVersion', identity)
        self.assertIn('[shortVersion isEqualToString:@"6.2.58"]', identity)
        self.assertIn('[buildVersion isEqualToString:@"865"]', identity)
        self.assertIn('return [shortVersion isEqualToString:@"6.2.58"] &&', identity)

        legacy = function_body(
            "static BOOL amproj_runtimeIsLegacy862",
            "static void amproj_log865LegacyPathDisabled",
        )
        self.assertIn('[shortVersion isEqualToString:@"6.2.55"]', legacy)
        self.assertIn('[buildVersion isEqualToString:@"862"]', legacy)
        uses_legacy = function_body(
            "static BOOL amproj_runtimeUsesLegacyImportHooks",
            "static void amproj_log865LegacyPathDisabled",
        )
        self.assertIn('AMProjNativePackageImportBridgeIsRuntimeSupported()', uses_legacy)

    def test_build_865_does_not_install_legacy_native_import_bridge(self):
        self.assertIn('#define AMPROJ_ENABLE_LEGACY_862 0', BRIDGE_SOURCE)
        self.assertIn('LEGACY_862 ?= 0', MAKEFILE)
        self.assertIn('-DAMPROJ_ENABLE_LEGACY_862=$(LEGACY_862)', MAKEFILE)
        supported = source_body(
            BRIDGE_SOURCE,
            'BOOL AMProjNativePackageImportBridgeIsRuntimeSupported(void)',
            'static void *AMProjMainAddress',
        )
        self.assertIn('[version isEqualToString:@"6.2.58"]', supported)
        self.assertIn('[build isEqualToString:@"865"]', supported)
        self.assertIn('return NO;', supported)

        installer_start = BRIDGE_SOURCE.index(
            'void AMProjInstallNativePackageImportBridge(void)'
        )
        installer = BRIDGE_SOURCE[installer_start:]
        self.assertIn('AMProjNativePackageImportBridgeIsRuntimeSupported()', installer)
        disabled = installer[installer.index('if (!AMProjNativePackageImportBridgeIsRuntimeSupported())'):]
        self.assertIn('AMProjRegisterNativePackageImportStarter(nil);', disabled)
        self.assertLess(
            disabled.index('AMProjRegisterNativePackageImportStarter(nil);'),
            disabled.index('AMProjRegisterNativePackageImportStarter(\n'),
        )

    def test_engine_import_and_picker_hooks_route_and_865_stays_off_private_swizzles(self):
        picker = function_body(
            'static void amproj_installNativeProjectPickerHook(void)',
            'static void amproj_installImportHook(void)',
        )
        import_hook = function_body(
            'static void amproj_installImportHook(void)',
            'static void amproj_installShareExportHook(void)',
        )
        # The document picker hook is build independent: it is installed for
        # every engine build (862 and 865) so a picked .amproj/.xml reaches the
        # local transaction engine instead of Alight Motion's online page.
        for body, marker in (
            (picker, 'amproj_log865LegacyPathDisabled(@"native_document_picker")'),
            (import_hook, 'amproj_log865LegacyPathDisabled(@"import_hooks")'),
        ):
            gate = body.index('if (!amproj_runtimeUsesLocalImportEngine())')
            marker_index = body.index(marker, gate)
            return_index = body.index('return;', marker_index)
            self.assertLess(gate, marker_index)
            self.assertLess(marker_index, return_index)
        self.assertIn('amproj_installNativeProjectPickerHook();', import_hook)
        self.assertGreater(import_hook.index('amproj_installNativeProjectPickerHook();'),
                           import_hook.index('return;'))
        # Build 865 must not install the 862 cold-launch/declared-URL swizzles.
        eight65_guard = import_hook.index('if (!amproj_runtimeUsesLegacyImportHooks())')
        cold_launch = import_hook.index('amproj_installColdLaunchHook();')
        self.assertLess(eight65_guard, cold_launch)
        self.assertIn('return;', import_hook[eight65_guard:cold_launch])
        proxy = function_body(
            'static void amproj_attachNativeXMLPickerProxy',
            'static void amproj_presentImportDocumentPicker',
        )
        gate = proxy.index('if (!amproj_runtimeUsesLocalImportEngine())')
        return_index = proxy.index('return;', gate)
        picker_check = proxy.index('UIDocumentPickerViewController.class')
        delegate_write = proxy.index('picker.delegate = proxy')
        self.assertLess(gate, return_index)
        self.assertLess(return_index, picker_check)
        self.assertLess(return_index, delegate_write)

    def test_build_865_public_callbacks_stage_without_rewriting_native_inputs(self):
        self.assertNotIn('amproj_rejectLikelyEncryptedXMLSelection865', SOURCE)
        self.assertNotIn('amproj_install865ValidationURLHooks', SOURCE)
        picker = function_body(
            "- (void)documentPicker:(UIDocumentPickerViewController *)controller\n    didPickDocumentsAtURLs:",
            "- (void)documentPicker:(UIDocumentPickerViewController *)controller\n    didPickDocumentAtURL:",
        )
        self.assertNotIn('amproj_rejectLikelyEncryptedXMLSelection865(', picker)
        single = function_body(
            "- (void)documentPicker:(UIDocumentPickerViewController *)controller\n    didPickDocumentAtURL:",
            "- (void)documentPickerWasCancelled:",
        )
        self.assertNotIn('amproj_rejectLikelyEncryptedXMLSelection865(', single)

        open_url = function_body(
            'static BOOL hooked_applicationOpenURL',
            'static NSURL* amproj_projectURLFromUserActivity',
        )
        self.assertIn('amproj_stagePublic865ProjectURL(', open_url)
        self.assertIn('self, _cmd, application, URL, options', open_url)
        self.assertIn('AMProjV865ProjectFlowRecordNativeRouteDispatched(', open_url)
        self.assertNotIn('amproj_public865NativeURL', open_url)

        activity = function_body(
            'static BOOL hooked_applicationContinueActivity',
            'static BOOL hooked_applicationHandleOpenURL',
        )
        self.assertIn('amproj_stagePublic865ProjectURL(', activity)
        self.assertIn(
            'self, _cmd, application, activity, restorationHandler', activity
        )
        self.assertIn('AMProjV865ProjectFlowRecordNativeRouteDispatched(', activity)

        handle = function_body(
            'static BOOL hooked_applicationHandleOpenURL',
            'static BOOL hooked_applicationLegacyOpenURL',
        )
        self.assertIn('self, _cmd, application, URL', handle)
        self.assertNotIn('amproj_public865NativeURL', handle)

        legacy = function_body(
            'static BOOL hooked_applicationLegacyOpenURL',
            'static NSArray<NSURL *> *amproj_recordSceneConnectionCandidates',
        )
        self.assertIn(
            'self, _cmd, application, URL, sourceApplication, annotation', legacy
        )
        self.assertNotIn('amproj_public865NativeURL', legacy)

    def test_managed_staged_url_reentry_does_not_create_a_second_notice(self):
        open_url = function_body(
            'static BOOL hooked_applicationOpenURL',
            'static NSURL* amproj_projectURLFromUserActivity',
        )
        notice_call = open_url.index(
            'AMProjV865ProjectFlowPresentPendingNotice('
        )
        managed_guard = open_url.index(
            'AMProjV865ProjectFlowIsManagedStagedURL(URL)'
        )
        self.assertLess(managed_guard, notice_call)
        self.assertIn(
            '!AMProjV865ProjectFlowIsManagedStagedURL(URL)',
            open_url[notice_call - 180:notice_call + 120],
        )

        flow_notice = (
            ROOT / 'AMProjExport' / 'AMProjV865ProjectFlow.m'
        ).read_text(encoding='utf-8')
        self.assertIn('objc_getAssociatedObject(', flow_notice)
        self.assertIn('BOOL sameStagedURL', flow_notice)
        self.assertIn('existing.nativeRouteInFlight', flow_notice)
        self.assertIn('existing.fallbackPresented', flow_notice)
        self.assertIn('Do not replace it when the URL re-enters', flow_notice)

    def test_build_865_scene_callback_consumes_projects_and_forwards_the_rest(self):
        scene = function_body(
            'static void hooked_sceneOpenURLContexts',
            'static void (*orig_projectsImportAlertViewDidLoad)',
        )
        public_start = scene.index('if (amproj_runtimeUsesPublic865ImportHooks())')
        legacy_start = scene.index('NSMutableSet *passthroughContexts', public_start)
        public = scene[public_start:legacy_start]
        # The 865 lane runs the local engine: command URLs and project documents
        # are consumed; only the remaining contexts reach Alight Motion.
        self.assertIn('amproj_handleImportCommandURL(', public)
        self.assertIn('amproj_captureSystemProjectURL(', public)
        self.assertIn('[forwardContexts copy]', public)
        self.assertIn('@"engine": @"local_transaction"', public)
        # No handoff staging and no native-route bookkeeping any more: the file
        # never travels through the openURL handoff directory on 865.
        self.assertNotIn('amproj_stagePublic865ProjectURL(', public)
        self.assertNotIn('AMProjV865ProjectFlowRecordNativeRouteDispatched(', public)
        self.assertNotIn('@"consumed": @0', public)
        forward = public.index('((AMProjSceneOpenURLContextsIMP)original)(\n')
        self.assertIn('[forwardContexts copy]', public[forward:forward + 120])

    def test_build_865_scene_cold_launch_stages_without_deferred_replay(self):
        recorder = function_body(
            'static NSArray<NSURL *> *amproj_recordSceneConnectionCandidates',
            'static void amproj_recordPublic865SceneConnectionRoutes',
        )
        gate = recorder.index('BOOL public865 = amproj_runtimeUsesPublic865ImportHooks()')
        first_public = recorder.index('if (public865)', gate)
        first_continue = recorder.index('continue;', first_public)
        first_deferred = recorder.index('amproj_recordDeferredLaunchCandidate', first_public)
        self.assertLess(first_continue, first_deferred)
        self.assertIn('AMProjV865ProjectFlowStageIncomingDocument', SOURCE)
        self.assertIn('@"deferred_queue": @(!public865)', recorder)

        configuration = function_body(
            'static UISceneConfiguration *hooked_applicationConfigurationForConnecting',
            'static void hooked_sceneWillConnectToSession',
        )
        native_call = configuration.index(
            'configuration = ((AMProjApplicationConfigurationForConnectingIMP)original)'
        )
        public_before_native = configuration.index(
            'amproj_recordSceneConnectionCandidates'
        )
        scope_release = configuration.index('stopAccessingSecurityScopedResource')
        self.assertLess(public_before_native, native_call)
        self.assertLess(native_call, scope_release)
        self.assertIn(
            'amproj_installPublic865SceneHooksForClass(configuration.delegateClass)',
            configuration,
        )

    def test_build_865_has_an_independent_public_lifecycle_installer(self):
        installer = function_body(
            'static void amproj_installPublic865ImportHooks(void)',
            'static void amproj_installProjectsImportAlertHook',
        )
        self.assertIn('amproj_runtimeUsesPublic865ImportHooks()', installer)
        self.assertIn('amproj_installPublic865ApplicationDelegateHook()', installer)
        self.assertIn('amproj_installPublic865AppDelegateHooksForClass', installer)
        self.assertIn('application.connectedScenes', installer)
        self.assertIn('amproj_installPublic865SceneHooksForClass', installer)
        self.assertNotIn('UIApplication.sharedApplication', installer)
        for forbidden in (
            'AMProjInstallNativePackageImportBridge',
            'amproj_installNativeProjectPickerHook',
            'amproj_installNativeXMLParserHook',
            'amproj_scanLocalImportInboxes',
        ):
            self.assertNotIn(forbidden, installer)

        app_hooks = function_body(
            'static BOOL amproj_installPublic865AppDelegateHooksForClass',
            'static void amproj_installPublic865ApplicationDelegateHook',
        )
        for selector in (
            'application:willFinishLaunchingWithOptions:',
            'application:didFinishLaunchingWithOptions:',
            'application:configurationForConnectingSceneSession:options:',
            'application:openURL:options:',
            'application:continueUserActivity:restorationHandler:',
            'application:handleOpenURL:',
            'application:openURL:sourceApplication:annotation:',
        ):
            self.assertIn(selector, app_hooks)

        constructor = SOURCE[SOURCE.index('__attribute__((constructor))') :]
        public_gate = constructor.index('if (amproj_runtimeUsesPublic865ImportHooks())')
        legacy_gate = constructor.index(
            '} else if (amproj_runtimeUsesLegacyImportHooks())', public_gate
        )
        self.assertIn(
            'amproj_installPublic865ImportHooks();',
            constructor[public_gate:legacy_gate],
        )
        setter = function_body(
            'static void hooked_applicationSetDelegate',
            'static void amproj_installApplicationDelegateHook',
        )
        self.assertIn('amproj_public865RuntimeDelegate = delegate', setter)
        self.assertGreaterEqual(setter.count('amproj_installPublic865ImportHooks();'), 2)

    def test_build_865_present_hook_keeps_account_replacement_and_forwards_other_presentations(self):
        present = function_body(
            'static void hooked_presentVC',
            '#if AMPROJ_DEBUG',
        )
        account = present.index('AMCloudSyncReplacementForNativeAccountPresentation')
        gate = present.index('if (!amproj_runtimeUsesLegacyImportHooks())')
        forwarding = present.index(
            'orig_presentVC(self, _cmd, controller, animated, completion)', gate
        )
        self.assertLess(account, gate)
        self.assertLess(gate, forwarding)
        self.assertIn('AMCloudSyncInstallPluginHooksEarly();', SOURCE)
        self.assertIn('AMCloudSyncReplacementForNativeAccountPush', SOURCE)

    def test_build_865_suppresses_signed_welcome_screen_without_touching_account_page(self):
        detector = source_body(
            SOURCE,
            'static BOOL amproj_IPAFireTextMatches',
            'static BOOL amproj_IPAFireViewContainsMarker',
        )
        welcome_detector = function_body(
            'static BOOL amproj_isIPAFireWelcome',
            'static void amproj_dismissIPAFireWelcomeIfPresented',
        )
        self.assertIn('instant certificates', detector)
        self.assertIn('more apps', detector)
        self.assertIn('cracked by blatant', detector)
        self.assertIn('amproj_IPAFireAppendViewText', SOURCE)
        self.assertIn('amproj_IPAFireFindOverlayView', SOURCE)
        self.assertIn('viewIfLoaded', welcome_detector)
        dismiss = function_body(
            'static void amproj_dismissIPAFireWelcomeIfPresented',
            '// A self-signed build can leave StoreKit',
        )
        self.assertIn('dismissViewControllerAnimated:NO', dismiss)
        present = function_body(
            'static void hooked_presentVC',
            '#if AMPROJ_DEBUG',
        )
        account = present.index('AMCloudSyncReplacementForNativeAccountPresentation')
        welcome = present.index('amproj_isIPAFireWelcome')
        forward = present.index(
            'orig_presentVC(self, _cmd, controller, animated, completion)'
        )
        self.assertLess(account, welcome)
        self.assertLess(welcome, forward)
        self.assertNotIn('wrappedCompletion', present)
        self.assertIn('amproj_scheduleIPAFireWelcomeSuppression(@"did_become_active")', SOURCE)
        self.assertIn('amproj_IPAFireHideRootViewTemporarily', SOURCE)
        self.assertIn('for (NSNumber *delay in @[@0.05, @0.25, @0.60, @0.75,', SOURCE)
        self.assertIn('@1.25, @1.75, @2.50, @3.50])', SOURCE)
        self.assertIn('UIWindowDidBecomeKeyNotification', SOURCE)
        self.assertIn('UIWindowDidBecomeVisibleNotification', SOURCE)
        self.assertIn('UIApplicationWillEnterForegroundNotification', SOURCE)
        self.assertIn('hide_window_without_root', SOURCE)
        self.assertIn('amproj_IPAFireAppendLayerText', SOURCE)
        self.assertIn('CATextLayer.class', SOURCE)
        self.assertIn('hooked_windowMakeKeyAndVisible', SOURCE)
        self.assertIn('window_make_key_and_visible', SOURCE)
        self.assertIn('amproj_installIPAFireWindowHook();', SOURCE)
        scan = function_body(
            'static void amproj_suppressIPAFireWelcomeWindows',
            'static void amproj_scheduleIPAFireWelcomeSuppression',
        )
        self.assertIn('BOOL hasWindowFingerprint = amproj_IPAFireViewContainsMarker(window, 0);', scan)
        self.assertIn('if (!window.rootViewController)', scan)
        self.assertIn('window.hidden = YES;', scan)

    def test_engine_builds_scan_inboxes_and_replay_deferred_urls(self):
        # 865 joined the local import engine: Inbox files and deferred launch
        # candidates replay through the plugin's own transaction chain instead
        # of being left to Alight Motion's original handlers.
        for signature, marker in (
            (
                'static void amproj_scanLocalImportInboxes',
                'amproj_log865LegacyPathDisabled(@"local_import_inbox_scan")',
            ),
            (
                'static void amproj_retryDeferredLaunchImportCandidates',
                'amproj_log865LegacyPathDisabled(@"deferred_launch_import")',
            ),
        ):
            body = function_body(
                signature,
                'static void amproj_retryDeferredLaunchImportCandidates'
                if signature.startswith('static void amproj_scanLocalImportInboxes')
                else 'static BOOL amproj_captureSystemProjectURL',
            )
            gate = body.index('if (!amproj_runtimeUsesLocalImportEngine())')
            marker_index = body.index(marker, gate)
            self.assertLess(marker_index, body.index('return;', marker_index))
        bootstrap = function_body(
            'static void amproj_bootstrapAfterLaunch',
            '__attribute__((constructor))',
        )
        self.assertIn('if (amproj_runtimeUsesLocalImportEngine())', bootstrap)
        self.assertIn('amproj_log865LegacyPathDisabled(@"bootstrap_import_scan")', bootstrap)
        self.assertLess(
            bootstrap.index('amproj_log865LegacyPathDisabled(@"bootstrap_import_scan")'),
            bootstrap.index('amproj_debugEvent(@"bootstrap.ready"'),
        )
        # The did-become-active replay must run for engine builds: the gate is
        # checked directly in SOURCE (the observer is registered outside the
        # bootstrap function body).
        active_gate = SOURCE.index(
            'if (amproj_runtimeUsesLocalImportEngine()) {\n'
            '                // The launch URL is the current user action.'
        )
        replay = SOURCE[active_gate:active_gate + 900]
        self.assertIn('amproj_retryDeferredLaunchImportCandidates();', replay)
        self.assertIn(
            'amproj_scanLocalImportInboxes(@"did_become_active", nil);', replay
        )

    def test_build_865_cloud_project_callback_enters_local_engine(self):
        bootstrap = function_body(
            'static void amproj_bootstrapAfterLaunch',
            '__attribute__((constructor))',
        )
        async_gate = bootstrap.index('if (amproj_runtimeIsBuild865())')
        legacy_gate = bootstrap.index(
            '} else if (amproj_runtimeUsesLegacyImportHooks())', async_gate
        )
        unknown_gate = bootstrap.index(
            '} else {\n            amproj_log865LegacyPathDisabled(@"cloud_import_handler")',
            legacy_gate,
        )
        async_branch = bootstrap[async_gate:legacy_gate]
        legacy_branch = bootstrap[legacy_gate:unknown_gate]
        unknown_branch = bootstrap[unknown_gate:]

        self.assertIn('AMCloudSyncInstallAsync(^(NSURL *URL, NSString *filename,', async_branch)
        self.assertIn(
            'amproj_importCloudPackage(URL, filename, cleanupURL, completion);',
            async_branch,
        )
        self.assertNotIn('AMCloudSyncInstall(', async_branch)
        self.assertIn('AMCloudSyncInstall(^(NSURL *URL, NSString *filename,', legacy_branch)
        self.assertIn('__block BOOL accepted = NO', legacy_branch)
        self.assertIn('accepted = staged', legacy_branch)
        self.assertNotIn('AMCloudSyncInstallAsync(', legacy_branch)
        self.assertIn('AMCloudSyncInstall(nil);', unknown_branch)
        cloud = SOURCE[SOURCE.index('static void amproj_importCloudPackage') :]
        # The 865 branch feeds the verified download straight into the local
        # transaction engine; the openURL handoff is gone for this build.
        self.assertIn('if (amproj_runtimeIsBuild865())', cloud)
        self.assertIn('amproj_handleIncomingProjectURLSafely(', cloud)
        self.assertIn('@"cloud_download_865"', cloud)
        self.assertIn('@"engine": @"local_transaction"', cloud)
        self.assertIn('@"import_completed": @NO', cloud)
        self.assertNotIn('AMProjV865ProjectFlowStageDocumentAsync', cloud)
        self.assertNotIn('AMProjV865ProjectFlowQueueDownloadedProject', cloud)
        self.assertIn('amproj_runtimeUsesLegacyImportHooks()', cloud)

    def test_encrypted_xml_is_rejected_before_packaging_and_queueing(self):
        body = function_body(
            'static void amproj_prepareCopiedXML',
            'static void amproj_prepareCopiedArchive',
        )
        probe = body.index('probe = data.length ? amproj_probeXML(data) : nil;')
        valid = body.index('BOOL valid = probe != nil;', probe)
        encrypted = body.index('BOOL likelyEncrypted = !valid', valid)
        reject = body.index('if (likelyEncrypted)', encrypted)
        zip_create = body.index('AMProjZIPWriteProjectArchive(', reject)
        queue = body.index('amproj_queuePreparedImport(', zip_create)
        self.assertLess(probe, valid)
        self.assertLess(valid, encrypted)
        self.assertLess(encrypted, reject)
        self.assertLess(reject, zip_create)
        self.assertLess(zip_create, queue)
        self.assertIn('XML 导入失败', body)
        self.assertIn('加密 XML 无法导入', body)

    def test_encrypted_xml_telemetry_contains_only_bounded_metadata(self):
        body = function_body(
            'static void amproj_prepareCopiedXML',
            'static void amproj_prepareCopiedArchive',
        )
        start = body.index('amproj_debugEvent(@"import.xml_encrypted_rejected"')
        end = body.index('amproj_releaseImportTransaction(transactionID, NO);', start)
        telemetry = body[start:end]
        for forbidden in ('data', 'UTF8', 'prefix', 'preview', 'base64', 'hex'):
            self.assertNotIn(forbidden, telemetry)
        for allowed in ('transaction_id', 'source', 'filename', 'bytes', 'category', 'signal'):
            self.assertIn(allowed, telemetry)

    def test_encrypted_xml_classifier_excludes_archives_and_valid_text_probe(self):
        classifier = function_body(
            'static BOOL amproj_isLikelyEncryptedXML',
            'static NSString* amproj_normalizedProjectTitle',
        )
        for signature in (
            'zipLocal', 'gzip', 'sevenZip', 'rar', 'xz', 'bplist',
            'png', 'jpeg', 'gif', 'pdf',
        ):
            self.assertIn(signature, classifier)
        self.assertIn('if (first == \'<\' || first == \'{\' || first == \'[\') return NO;', classifier)
        self.assertIn('if (nulCount > sampleLength / 4) return NO;', classifier)
        body = function_body(
            'static void amproj_prepareCopiedXML',
            'static void amproj_prepareCopiedArchive',
        )
        self.assertLess(
            body.index('probe = data.length ? amproj_probeXML(data) : nil;'),
            body.index('BOOL likelyEncrypted = !valid'),
        )


if __name__ == "__main__":
    unittest.main()
