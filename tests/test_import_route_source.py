import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
ARCHIVE_SOURCE = (ROOT / "AMProjExport" / "AMProjImportArchive.m").read_text(
    encoding="utf-8"
)


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

    def test_template_xml_picker_is_not_used_as_project_importer(self):
        self.assertNotIn("TemplatesListVC", SOURCE)
        self.assertNotIn(
            'NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:")',
            SOURCE,
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

    def test_manifest_is_optional_but_may_not_be_duplicated(self):
        self.assertIn("if (manifestCount > 1)", ARCHIVE_SOURCE)
        self.assertNotIn("manifestCount != 1", ARCHIVE_SOURCE)
        self.assertNotIn("manifestCount == 0 ?", ARCHIVE_SOURCE)

    def test_archive_preparation_runs_on_worker_and_queues_xml(self):
        body = function_body(
            "static void amproj_prepareCopiedArchive",
            "static BOOL amproj_forwardPreparedXMLToNative",
        )
        worker = body.index("dispatch_async(amproj_importInboxQueue()")
        prepare = body.index("AMProjPrepareNativeImport")
        queue = body.index("amproj_queuePreparedImport(nativeXMLURL")
        self.assertLess(worker, prepare)
        self.assertLess(prepare, queue)
        self.assertNotIn("amproj_validateIncomingArchive", body)
        self.assertNotIn("amproj_queuePreparedImport(archiveSnapshot", body)

    def test_prepared_xml_uses_saved_app_delegate_implementation(self):
        body = function_body(
            "static BOOL amproj_forwardPreparedXMLToNative",
            "static void amproj_activateNextPendingImport",
        )
        self.assertIn('isEqualToString:@"xml"', body)
        self.assertIn('@"/AMProjImports/"', body)
        self.assertIn("amproj_nativeAppDelegateOpenURLIMP", body)
        self.assertIn("amproj_originalHookForClass", body)
        self.assertIn("AMProjApplicationOpenURLIMP", body)
        self.assertNotIn("objc_msgSend", body)
        self.assertEqual(body.count("UIApplicationOpenURLOptionsOpenInPlaceKey"), 1)

        dispatch = function_body(
            "static void amproj_tryDispatchPendingImport",
            "static void amproj_queuePreparedImport",
        )
        self.assertIn("amproj_forwardPreparedXMLToNative", dispatch)
        self.assertNotIn("amproj_forwardPreparedImportToNative", dispatch)
        self.assertIn("amproj_markPreparedImportPersistent(URL);", dispatch)

    def test_imported_assets_use_persistent_application_support_storage(self):
        cache = function_body(
            "static NSURL* amproj_importCacheRoot",
            "typedef NS_ENUM(NSInteger, AMProjImportFileError)",
        )
        self.assertIn("NSApplicationSupportDirectory", cache)
        self.assertIn('@".persistent-assets"', cache)
        self.assertIn("if ([manager fileExistsAtPath:persistentMarker.path]) continue;", cache)

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
