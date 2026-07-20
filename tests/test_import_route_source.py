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
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
DEBUG_TRANSPORT_SOURCE = (
    ROOT / "AMProjExport" / "AMDebugTransport.m"
).read_text(encoding="utf-8")
README = (ROOT / "README.md").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(
    encoding="utf-8"
)
BUILD_SCRIPT = (ROOT / "build_and_inject.bat").read_text(encoding="utf-8")


def source_body(source: str, signature: str, next_signature: str) -> str:
    start = source.rindex(signature)
    end = source.index(next_signature, start)
    return source[start:end]


def function_body(signature: str, next_signature: str) -> str:
    return source_body(SOURCE, signature, next_signature)


class NativeImportRouteSourceTests(unittest.TestCase):
    def test_release_version_metadata_is_consistent(self):
        self.assertIn('kAMProjPluginVersion = @"27";', SOURCE)
        self.assertIn('kAMDebugPluginVersion = @"27";', DEBUG_TRANSPORT_SOURCE)
        self.assertIn("AMProj v27", SOURCE)
        self.assertNotIn("AMProj v23", SOURCE)
        self.assertIn("AMProjExport-v${{ env.AMPROJ_RELEASE_VERSION }}-dylibs", WORKFLOW)
        self.assertIn("AMPROJ_RELEASE_VERSION: '27'", WORKFLOW)
        self.assertIn('"commit": os.environ["GITHUB_SHA"]', WORKFLOW)
        self.assertIn('"run_id": os.environ["GITHUB_RUN_ID"]', WORKFLOW)
        self.assertIn('"sha256": {', WORKFLOW)
        self.assertIn("build-metadata.json", WORKFLOW)
        self.assertIn("AM_v1_direct_v27.ipa", README)
        self.assertIn("AM_v1_direct_v27_debug.ipa", README)
        self.assertIn("AM_v1_direct_v27.ipa", BUILD_SCRIPT)

    def test_paywall_filter_requires_multiple_subscription_markers(self):
        self.assertIn("paywall.detected", SOURCE)
        self.assertIn("paywall.dismissed", SOURCE)
        self.assertIn("选择一个套餐", SOURCE)
        self.assertIn("已经购买", SOURCE)
        self.assertIn("每周", SOURCE)
        self.assertIn("continue", SOURCE)
        self.assertIn("amproj_schedulePaywallScan", SOURCE)
        self.assertIn("did_become_active", SOURCE)
        # A generic hosting controller must not be dismissed by class name alone.
        self.assertIn("BOOL markerMatch = plan && continueMarker", SOURCE)
        self.assertIn("ShareProjectPackageVC", SOURCE)

    def test_package_flow_predicate_is_narrow(self):
        body = function_body(
            "static BOOL amproj_isPackageControllerName",
            "static BOOL amproj_isSharePackageControllerRecursive",
        )
        self.assertIn("ShareProjectPackageVC", body)
        self.assertNotIn('containsString:@"Package"]', body)

    def assert_capture_short_circuits_original(
        self, signature: str, next_signature: str, native_imp_type: str
    ) -> None:
        body = function_body(signature, next_signature)
        capture = re.search(
            r"if\s*\([^;]*amproj_captureSystemProjectURL\([^;]+?\)\)\s*"
            r"\{\s*return YES;\s*\}",
            body,
            re.DOTALL,
        )
        self.assertIsNotNone(capture, signature)
        self.assertLess(capture.end(), body.index("IMP original"), signature)
        self.assertLess(capture.end(), body.index(native_imp_type), signature)

    def test_template_xml_upload_route_is_completely_absent(self):
        self.assertNotIn("TemplatesListVC", SOURCE)
        self.assertNotIn("amproj_findTemplatesController", SOURCE)
        self.assertNotIn("amproj_installTemplatesLifecycleHook", SOURCE)
        self.assertNotIn(
            'NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:")',
            SOURCE,
        )

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

    def test_native_bridge_uses_complete_package_and_firebase_task_contract(self):
        self.assertIn("AMProjLocalStorageReference", BRIDGE_SOURCE)
        self.assertIn("AMProjLocalStorageTask", BRIDGE_SOURCE)
        self.assertIn("typedef NSString *AMProjLocalStorageHandle", BRIDGE_SOURCE)
        self.assertIn(
            "NSMutableDictionary<AMProjLocalStorageHandle, NSDictionary *> *observers",
            BRIDGE_SOURCE,
        )
        self.assertNotIn("typedef int64_t AMProjLocalStorageHandle", BRIDGE_SOURCE)
        self.assertIn("writeToFile:", BRIDGE_SOURCE)
        self.assertIn("observeStatus:", BRIDGE_SOURCE)
        self.assertIn("removeObserverWithHandle:", BRIDGE_SOURCE)
        self.assertIn("removeAllObserversForStatus:", BRIDGE_SOURCE)
        self.assertIn("copyItemAtURL:sourceURL toURL:destinationURL", BRIDGE_SOURCE)
        self.assertIn("status == 2 || status == 4", BRIDGE_SOURCE)
        self.assertIn("status == 5", BRIDGE_SOURCE)
        self.assertIn("progress.completedUnitCount = 1", BRIDGE_SOURCE)
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
        call_start = BRIDGE_SOURCE.index("AMProjCallNativePackageImport(")
        call_end = BRIDGE_SOURCE.index("releaseBridge(swiftName.word1)", call_start)
        call = BRIDGE_SOURCE[call_start:call_end]
        self.assertIn("reference,", call)
        self.assertIn("progressOwner,", call)
        self.assertIn("NULL,", call)
        self.assertIn("owner);", call)
        self.assertIn('storyboardWithName:@"AMProgressAlert"', BRIDGE_SOURCE)
        self.assertIn('hasSuffix:@"AMProgressAlert"', BRIDGE_SOURCE)
        self.assertIn("amproj_nativeBridgeProgressOwner = progressOwner", BRIDGE_SOURCE)
        self.assertIn("amproj_nativeBridgeProgressOwner = nil", BRIDGE_SOURCE)
        self.assertIn('progress_owner_created', BRIDGE_SOURCE)
        self.assertIn('progress_owner_class', BRIDGE_SOURCE)
        self.assertIn('progress_owner_presented', BRIDGE_SOURCE)
        self.assertNotIn("reference,\n            nil,", call)
        self.assertIn("explicit x2", BRIDGE_SOURCE)
        self.assertIn("x20 context", BRIDGE_SOURCE)
        self.assertIn("writeToFile:", BRIDGE_SOURCE)
        self.assertIn("requires a non-null AMProgressAlert", BRIDGE_ASSEMBLY)
        self.assertIn("id progressOwner", BRIDGE_HEADER)
        self.assertNotIn("id _Nullable progressOwner", BRIDGE_HEADER)

    def test_copy_failure_flows_through_the_native_status_handler(self):
        finish = BRIDGE_SOURCE[BRIDGE_SOURCE.index("- (void)finishTransferWithError") :
                              BRIDGE_SOURCE.index("- (instancetype)initWithSourceURL", BRIDGE_SOURCE.index("- (void)finishTransferWithError"))]
        self.assertIn("if (self.transferFinished) return", finish)
        self.assertIn("self.transferError = error", finish)
        self.assertIn('observer[@"status"]', finish)
        self.assertIn("snapshot])", finish)
        self.assertIn("dispatch_get_main_queue()", finish)
        self.assertIn("error", BRIDGE_SOURCE[BRIDGE_SOURCE.index("if (![manager copyItemAtURL") :])
        self.assertNotIn("AMProjNativePackageImportBridgeFinishFailure", finish)

    def test_native_storage_success_notifies_progress_and_success_observers(self):
        finish_start = BRIDGE_SOURCE.index("- (void)finishTransferWithError")
        finish_end = BRIDGE_SOURCE.index(
            "- (instancetype)initWithSourceURL", finish_start
        )
        finish = BRIDGE_SOURCE[finish_start:finish_end]
        observe_start = BRIDGE_SOURCE.rindex(
            "- (AMProjLocalStorageHandle)observeStatus"
        )
        observe_end = BRIDGE_SOURCE.index(
            "- (void)removeObserverWithHandle", observe_start
        )
        observe = BRIDGE_SOURCE[observe_start:observe_end]
        self.assertIn("@[@5]", finish)
        self.assertIn("@[@2, @4]", finish)
        self.assertIn("terminalStatuses", finish)
        self.assertIn("sortedArrayUsingSelector", finish)
        self.assertIn(
            "self.transferError == nil && (status == 2 || status == 4)",
            observe,
        )
        self.assertIn("self.progress.completedUnitCount = 1", finish)

    def test_native_storage_handles_are_string_objects_and_directly_removable(self):
        observe_start = BRIDGE_SOURCE.rindex("- (AMProjLocalStorageHandle)observeStatus")
        observe = BRIDGE_SOURCE[observe_start :
                               BRIDGE_SOURCE.index("- (void)removeObserverWithHandle", observe_start)]
        self.assertIn("if (!handler) return nil", observe)
        self.assertIn("AMProjLocalStorageHandle handle = nil", observe)
        self.assertIn('[NSString stringWithFormat:@"amproj-%020llu"', observe)
        self.assertIn("self.observers[handle]", observe)
        self.assertIn("return handle", observe)
        self.assertNotIn("@(handle)", observe)
        remove_start = BRIDGE_SOURCE.rindex("- (void)removeObserverWithHandle")
        remove = BRIDGE_SOURCE[remove_start :
                              BRIDGE_SOURCE.index("@end", remove_start)]
        self.assertIn("(AMProjLocalStorageHandle)handle", remove)
        self.assertIn("removeObjectForKey:handle", remove)
        self.assertNotIn("removeObjectForKey:@(handle)", remove)
        self.assertNotIn("int64_t", BRIDGE_SOURCE)

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
            "storage_observer_registered",
            "native_completion",
        ):
            self.assertIn(f'@"{event}"', BRIDGE_SOURCE)
        self.assertIn("AMProjStorageStatusReturnedEventName", BRIDGE_SOURCE)
        self.assertIn('stringByAppendingString:@"_returned"', BRIDGE_SOURCE)

        finish_start = BRIDGE_SOURCE.index("- (void)finishTransferWithError")
        finish_end = BRIDGE_SOURCE.index(
            "- (instancetype)initWithSourceURL", finish_start
        )
        callback = BRIDGE_SOURCE[finish_start:finish_end]
        self.assertLess(
            callback.index("handler([self snapshot])"),
            callback.index("[self emitStatusReturnedEvent:status]"),
        )

        observe_start = BRIDGE_SOURCE.rindex(
            "- (AMProjLocalStorageHandle)observeStatus"
        )
        observe_end = BRIDGE_SOURCE.index(
            "- (void)removeObserverWithHandle", observe_start
        )
        observe = BRIDGE_SOURCE[observe_start:observe_end]
        self.assertLess(
            observe.index("callback(terminalSnapshot ?: [self snapshot])"),
            observe.index("[self emitStatusReturnedEvent:status]"),
        )
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
        self.assertIn("AMProjFinishNativeBridge(YES, nil)", completion)
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

    def test_native_bridge_is_locked_to_verified_am_v1_binary(self):
        self.assertIn("4b, 0x22, 0xd4, 0x3f", BRIDGE_SOURCE)
        self.assertIn("AMProjNativeImportEntry = 0x100266ee8ULL", BRIDGE_SOURCE)
        self.assertIn("expectedPrologue", BRIDGE_SOURCE)
        self.assertIn("LC_UUID", BRIDGE_SOURCE)
        self.assertIn("memcmp(entry, expectedPrologue", BRIDGE_SOURCE)

    def test_arm64_shim_sets_hidden_owner_without_corrupting_callee_saved_state(self):
        self.assertIn("_AMProjCallNativePackageImport", BRIDGE_ASSEMBLY)
        self.assertIn("str x20, [sp, #16]", BRIDGE_ASSEMBLY)
        self.assertIn("presentation owner in hidden Swift x20", BRIDGE_ASSEMBLY)
        self.assertIn("mov x20, x7", BRIDGE_ASSEMBLY)
        self.assertIn("blr x9", BRIDGE_ASSEMBLY)
        self.assertIn("ldr x20, [sp, #16]", BRIDGE_ASSEMBLY)
        self.assertIn(".cfi_startproc", BRIDGE_ASSEMBLY)
        self.assertIn(".cfi_offset x20, -16", BRIDGE_ASSEMBLY)
        self.assertIn(".cfi_endproc", BRIDGE_ASSEMBLY)
        self.assertIn("AMProjNativeImportBridge.S", MAKEFILE)
        self.assertEqual(MAKEFILE.count("AMProjNativeImportBridge.S"), 4)

    def test_bridge_registers_after_launch_and_finishes_only_from_native_result(self):
        bootstrap = function_body(
            "static void amproj_bootstrapAfterLaunch",
            "__attribute__((constructor))",
        )
        self.assertIn("AMProjInstallNativePackageImportBridge()", bootstrap)
        self.assertIn("AMProjRegisterNativePackageImportStarter", BRIDGE_HEADER)
        self.assertIn("AMProjNativeImportCompletionThunk", BRIDGE_SOURCE)
        self.assertIn("AMProjFinishNativeBridge(YES, nil)", BRIDGE_SOURCE)
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

    def test_cold_launch_records_candidates_and_filters_only_project_options(self):
        recorder = function_body(
            "static void amproj_recordLaunchImportCandidates",
            "static NSDictionary *amproj_launchOptionsForNativeAppDelegate",
        )
        self.assertIn("amproj_recordDeferredLaunchCandidate", recorder)
        self.assertNotIn("amproj_captureSystemProjectURL", recorder)
        self.assertNotIn("amproj_handleIncomingProjectURL", recorder)
        self.assertNotIn("removeObjectForKey", recorder)

        filterer = function_body(
            "static NSDictionary *amproj_launchOptionsForNativeAppDelegate",
            "static BOOL hooked_applicationDidFinish",
        )
        self.assertIn("NSMutableDictionary *filtered = [launchOptions mutableCopy]", filterer)
        self.assertIn("amproj_isIncomingProjectURL(launchURL, launchOptions)", filterer)
        self.assertIn(
            "[filtered removeObjectForKey:UIApplicationLaunchOptionsURLKey]",
            filterer,
        )
        self.assertIn("NSMutableDictionary *activities", filterer)
        self.assertIn("amproj_isIncomingProjectURL(activityURL, nil)", filterer)
        self.assertIn("[activities removeObjectForKey:key]", filterer)
        self.assertIn("return filtered", filterer)

        hook = function_body(
            "static BOOL hooked_applicationDidFinish",
            "static BOOL hooked_applicationContinueActivity",
        )
        record = hook.index("amproj_recordLaunchImportCandidates")
        filter_call = hook.index("amproj_launchOptionsForNativeAppDelegate")
        original = hook.index("IMP original")
        self.assertLess(record, filter_call)
        self.assertLess(filter_call, original)
        self.assertIn("self, _cmd, application, forwardedOptions);", hook)
        self.assertIn('@"forwarded_project_url_removed"', hook)

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

    def test_activation_prioritizes_silent_launch_retry_before_inbox_scan(self):
        marker = SOURCE.index("UIApplicationDidBecomeActiveNotification")
        body = SOURCE[marker : marker + 2400]
        scan = body.index('amproj_scanLocalImportInboxes(@"did_become_active", nil)')
        retry = body.index("amproj_retryDeferredLaunchImportCandidates()")
        self.assertLess(retry, scan)
        deferred = function_body(
            "static void amproj_retryDeferredLaunchImportCandidates",
            "static BOOL amproj_captureSystemProjectURL",
        )
        self.assertIn('options[@"AMProjSilentErrors"] = @YES', deferred)
        self.assertIn("amproj_importInboxQueue()", deferred)

    def test_native_package_validation_accepts_missing_manifest_for_normalization(self):
        body = function_body(
            "static BOOL amproj_validateIncomingArchive",
            "static NSString* amproj_importCacheFilename",
        )
        self.assertIn("if (manifestCount > 1)", body)
        self.assertNotIn("manifestCount != 1", body)
        self.assertNotIn("manifestCount == 0 ?", body)
        self.assertIn("at most one manifest.txt", body)

    def test_archive_validation_normalizes_and_queues_canonical_zip(self):
        body = function_body(
            "static void amproj_prepareCopiedArchive",
            "static void amproj_activateNextPendingImport",
        )
        worker = body.index("dispatch_async(amproj_importInboxQueue()")
        validate = body.index("amproj_validateIncomingArchive")
        original_route = body.index('if (inputManifestCount == 1)')
        prepare = body.index("AMProjPrepareNativeImport", original_route)
        original_assignment = body.index("preparedURL = archiveSnapshot", original_route)
        legacy_route = body.index('} else if (inputXMLCount == 1)', original_route)
        normalize = body.index("AMProjNormalizeProjectArchive", legacy_route)
        queue = body.index("amproj_queuePreparedImport(preparedURL", legacy_route)
        self.assertLess(worker, validate)
        self.assertLess(validate, original_route)
        self.assertLess(original_route, prepare)
        self.assertLess(prepare, original_assignment)
        self.assertLess(original_route, legacy_route)
        self.assertLess(legacy_route, normalize)
        self.assertLess(normalize, queue)
        self.assertIn('route = @"validated_original_package"', body[original_route:legacy_route])
        self.assertIn('route = @"normalized_manifest_media_signatures"', body[original_route:queue])
        self.assertIn('rewritten_media_signature_count', body[original_route:queue])
        self.assertIn('route = @"normalized_legacy_package"', body[legacy_route:queue])
        self.assertIn('preparationMetrics[@"missing_reference_count"]', body)
        self.assertIn('import.missing_media_signatures', body)

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
        self.assertIn("amproj_tryDispatchPendingImport(generation)", dispatch[retry:clear])
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
        self.assertNotIn('@"AMProj v27 · 4/4', finish[success_branch:])
        self.assertIn("amproj_importVerificationActive = YES", finish[success_branch:])
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
        self.assertIn("amproj_releaseImportTransaction(transactionID, YES)", verified_branch)
        self.assertIn('AMProj v27 · 4/4', verified_branch)
        self.assertIn('amproj_resumeQueuedImports(@"project_row_verified")', verified_branch)
        self.assertIn('@"import.project_row_missing"', verification)
        self.assertIn("amproj_activateNextPendingImport()", verification)
        self.assertNotIn("4/4", function_body(
            "static void hooked_projectsImportAlertViewDidLoad",
            "static void hooked_projectsImportAlertOnPressImport",
        ))
        self.assertEqual(SOURCE.count("AMProj v27 · 4/4"), 1)

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
        self.assertIn("AMProj v27 \\u00b7 E40", present)
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
        self.assertIn("amproj_activateNextPendingImport", finish)

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


if __name__ == "__main__":
    unittest.main()
