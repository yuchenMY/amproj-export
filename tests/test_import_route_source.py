import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")


def function_body(signature: str, next_signature: str) -> str:
    start = SOURCE.rindex(signature)
    end = SOURCE.index(next_signature, start)
    return SOURCE[start:end]


class NativeImportRouteSourceTests(unittest.TestCase):
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

    def test_templates_picker_is_used_as_native_package_importer(self):
        finder = function_body(
            "static UIViewController* amproj_findTemplatesControllerRecursive",
            "static UIViewController* amproj_findTemplatesController(BOOL visibleOnly)",
        )
        self.assertIn('containsString:@"TemplatesListVC"', finder)
        self.assertIn(
            'NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:")',
            finder,
        )
        self.assertIn("respondsToSelector:importSelector", finder)
        self.assertIn("amproj_controllerIsVisible(controller)", finder)
        self.assertIn("controller == amproj_activeTemplatesController", finder)

        search = function_body(
            "static UIViewController* amproj_findTemplatesController(BOOL visibleOnly)",
            "static UIViewController* amproj_topViewController",
        )
        self.assertIn("UISceneActivationStateForegroundActive", search)
        self.assertIn("window.isKeyWindow", search)
        self.assertLess(
            search.index("keyWindow.rootViewController"),
            search.index("window.hidden"),
        )

    def test_native_dispatch_waits_for_templates_view_did_appear(self):
        appeared = function_body(
            "static void hooked_templatesViewDidAppear",
            "static void hooked_templatesViewDidDisappear",
        )
        self.assertIn("amproj_activeTemplatesController = self", appeared)
        self.assertIn('amproj_resumeQueuedImports(@"templates_view_did_appear")', appeared)

        disappeared = function_body(
            "static void hooked_templatesViewDidDisappear",
            "static BOOL amproj_isTrackedProjectsImportAlert",
        )
        self.assertIn("amproj_activeTemplatesController == self", disappeared)
        self.assertIn("amproj_activeTemplatesController = nil", disappeared)

        install = function_body(
            "static void amproj_installTemplatesLifecycleHook",
            "static void amproj_installProjectsImportAlertHook",
        )
        self.assertIn("TemplatesListVC.viewDidAppear", install)
        self.assertIn("TemplatesListVC.viewDidDisappear", install)

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

    def test_cold_launch_captures_and_removes_consumed_project_urls(self):
        sanitizer = function_body(
            "static NSDictionary* amproj_launchOptionsAfterCapturingProjects",
            "static BOOL hooked_applicationDidFinish",
        )
        self.assertLess(
            sanitizer.index("amproj_captureSystemProjectURL"),
            sanitizer.index("[launchOptions mutableCopy]"),
        )
        self.assertIn(
            "[forwardOptions removeObjectForKey:UIApplicationLaunchOptionsURLKey]",
            sanitizer,
        )
        self.assertRegex(
            sanitizer,
            re.compile(
                r"\[forwardOptions\s+removeObjectForKey:\s*"
                r"UIApplicationLaunchOptionsUserActivityDictionaryKey\]",
                re.DOTALL,
            ),
        )
        self.assertIn("return launchOptions;", sanitizer)

        hook = function_body(
            "static BOOL hooked_applicationDidFinish",
            "static BOOL hooked_applicationContinueActivity",
        )
        self.assertLess(
            hook.index("amproj_launchOptionsAfterCapturingProjects"),
            hook.index("IMP original"),
        )
        self.assertIn("application, forwardLaunchOptions);", hook)
        self.assertNotIn("application, launchOptions);", hook)

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
        normalize = body.index("AMProjNormalizeProjectArchive")
        queue = body.index("amproj_queuePreparedImport(normalizedURL")
        self.assertLess(worker, validate)
        self.assertLess(validate, normalize)
        self.assertLess(normalize, queue)
        self.assertNotIn("amproj_queuePreparedImport(archiveSnapshot", body)
        self.assertIn('normalizationMetrics[@"missing_reference_count"]', body)

    def test_prepared_zip_dispatches_to_templates_picker_not_app_delegate(self):
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("amproj_findTemplatesController(YES)", dispatch)
        self.assertIn("amproj_findTemplatesController(NO)", dispatch)
        self.assertIn("amproj_revealTemplatesController(hiddenController)", dispatch)
        self.assertIn(
            'NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:")',
            dispatch,
        )
        self.assertIn("controller, selector, nil, @[URL]", dispatch)
        self.assertIn("amproj_waitingForNativeImportAlert = YES", dispatch)
        self.assertNotIn("AMProjApplicationOpenURLIMP", dispatch)
        self.assertNotIn("amproj_nativeAppDelegateOpenURLIMP", dispatch)
        self.assertNotIn("amproj_forwardPreparedXMLToNative", SOURCE)
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

    def test_four_of_four_requires_native_projects_import_alert(self):
        loaded = function_body(
            "static void hooked_projectsImportAlertViewDidLoad",
            "static void hooked_projectsImportAlertOnPressImport",
        )
        self.assertIn(
            "recognizedQueuedPackage = amproj_waitingForNativeImportAlert", loaded
        )
        self.assertIn("amproj_waitingForNativeImportAlert = NO", loaded)
        self.assertIn("++amproj_nativeImportRecognitionGeneration", loaded)
        self.assertIn("if (recognizedQueuedPackage)", loaded)
        self.assertIn("4/4 AM", loaded)
        self.assertNotIn("amproj_nativeImportObservationActive = NO", loaded)
        self.assertEqual(SOURCE.count("4/4 AM"), 1)

        pressed = function_body(
            "static void hooked_projectsImportAlertOnPressImport",
            "static void hooked_projectsImportAlertOnPressCancel",
        )
        self.assertNotIn("4/4", pressed)
        self.assertNotIn("amproj_resumeQueuedImports", pressed)
        self.assertNotIn("amproj_nativeImportAlertActive = NO", pressed)
        self.assertIn("if (tracked)", pressed)

        disappeared = function_body(
            "static void hooked_projectsImportAlertViewDidDisappear",
            "static UIWindow* amproj_keyWindow",
        )
        self.assertIn("amproj_nativeImportAlertActive = NO", disappeared)
        self.assertIn("amproj_resumeQueuedImports", disappeared)
        self.assertIn('isEqualToString:@"import"', disappeared)
        self.assertIn("180 * NSEC_PER_SEC", disappeared)
        self.assertNotIn("2 * NSEC_PER_SEC", disappeared)

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

        present = function_body(
            "static void hooked_presentVC",
            "#if AMPROJ_DEBUG",
        )
        self.assertIn('amproj_debugEvent(@"import.native_failure_alert"', present)
        self.assertIn("amproj_currentNativeParserSnapshot", present)
        self.assertIn("amproj_visibleNativeParserSummary", present)
        self.assertIn("amproj_endNativeImportObservation", present)
        self.assertIn("amproj_flushDebugEvents", present)
        self.assertIn("AMProj v19 \\u00b7 E40", present)
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

    def test_native_import_observation_blocks_queue_until_terminal_state(self):
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

        disappeared = function_body(
            "static void hooked_projectsImportAlertViewDidDisappear",
            "static UIWindow* amproj_keyWindow",
        )
        self.assertIn("amproj_endNativeImportObservation", disappeared)
        self.assertIn("amproj_importDispatchCoolingDown = NO", disappeared)
        self.assertIn('amproj_resumeQueuedImports(@"native_import_observation_timeout")', disappeared)

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

    def test_recognition_timeout_does_not_automatically_dispatch_next_package(self):
        watchdog = function_body(
            "static void amproj_checkNativeImportRecognition",
            "static void amproj_tryDispatchPendingImport",
        )
        self.assertIn("90 * NSEC_PER_SEC", watchdog)
        self.assertNotIn("amproj_resumeQueuedImports", watchdog)
        self.assertNotIn("amproj_activateNextPendingImport", watchdog)

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
            "static void amproj_scanDocumentsInboxNow",
            "static NSDictionary* amproj_shareRequestDescriptor",
        )
        self.assertIn("AMProjIncomingURLResult result", body)
        self.assertIn("if (result == AMProjIncomingURLFailed) break;", body)
        self.assertNotIn("if (!prepared) break;", body)

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
