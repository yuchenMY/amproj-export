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
            "static UIViewController* amproj_findTemplatesController(void)",
        )
        self.assertIn('containsString:@"TemplatesListVC"', finder)
        self.assertIn(
            'NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:")',
            finder,
        )
        self.assertIn("respondsToSelector:importSelector", finder)

        search = function_body(
            "static UIViewController* amproj_findTemplatesController(void)",
            "static UIViewController* amproj_topViewController",
        )
        self.assertIn("UISceneActivationStateForegroundActive", search)
        self.assertIn("window.isKeyWindow", search)
        self.assertLess(
            search.index("keyWindow.rootViewController"),
            search.index("window.hidden"),
        )

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

    def test_native_package_validation_requires_exactly_one_manifest(self):
        body = function_body(
            "static BOOL amproj_validateIncomingArchive",
            "static NSString* amproj_importCacheFilename",
        )
        self.assertIn("if (manifestCount != 1)", body)
        self.assertIn("manifestCount == 0 ?", body)
        self.assertIn("contains no manifest.txt", body)
        self.assertIn("exactly one manifest.txt", body)

    def test_archive_validation_runs_on_worker_and_queues_original_zip(self):
        body = function_body(
            "static void amproj_prepareCopiedArchive",
            "static void amproj_activateNextPendingImport",
        )
        worker = body.index("dispatch_async(amproj_importInboxQueue()")
        validate = body.index("amproj_validateIncomingArchive")
        queue = body.index("amproj_queuePreparedImport(archiveSnapshot")
        self.assertLess(worker, validate)
        self.assertLess(validate, queue)
        self.assertNotIn("AMProjPrepareNativeImport", body)
        self.assertNotIn("nativeXMLURL", body)

    def test_prepared_zip_dispatches_to_templates_picker_not_app_delegate(self):
        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("amproj_findTemplatesController()", dispatch)
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
