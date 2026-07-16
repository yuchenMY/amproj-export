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
    def test_template_xml_picker_is_not_used_as_project_importer(self):
        self.assertNotIn("TemplatesListVC", SOURCE)
        self.assertNotIn(
            'NSSelectorFromString(@"documentPicker:didPickDocumentsAtURLs:")',
            SOURCE,
        )

    def test_application_open_url_calls_native_before_plugin_fallback(self):
        body = function_body(
            "static BOOL hooked_applicationOpenURL",
            "static NSURL* amproj_projectURLFromUserActivity",
        )
        native_call = body.index("AMProjApplicationOpenURLIMP")
        fallback = body.index("application_open_url_fallback")
        self.assertLess(native_call, fallback)
        self.assertIn("result == AMProjIncomingURLAccepted", body)

    def test_cold_launch_options_are_forwarded_unchanged(self):
        body = function_body(
            "static BOOL hooked_applicationDidFinish",
            "static BOOL hooked_applicationContinueActivity",
        )
        self.assertIn("application, launchOptions);", body)
        self.assertNotIn("removeObjectForKey", SOURCE)
        self.assertNotIn("forwardOptions", body)
        self.assertIn('"forwarded_unchanged": @YES', SOURCE)
        self.assertLess(
            body.index("AMProjApplicationDidFinishIMP"),
            body.index("amproj_stageForwardedProjectURL"),
        )

    def test_scene_forwards_original_contexts_before_staging_fallback(self):
        body = function_body(
            "static void hooked_sceneOpenURLContexts",
            "static void (*orig_projectsImportAlertViewDidLoad)",
        )
        self.assertLess(
            body.index("AMProjSceneOpenURLContextsIMP"),
            body.index("amproj_stageForwardedProjectURL"),
        )
        self.assertIn("amproj_sceneOpenURLForwardDepth", body)

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

    def test_recognized_failures_are_not_reported_as_accepted(self):
        body = function_body(
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURLWithResult",
            "static AMProjIncomingURLResult amproj_handleIncomingProjectURL(",
        )
        self.assertGreaterEqual(body.count("return AMProjIncomingURLFailed;"), 3)
        self.assertNotRegex(body, re.compile(r"return\s+(YES|NO);"))

    def test_cached_package_uses_saved_app_delegate_implementation(self):
        body = function_body(
            "static BOOL amproj_forwardPreparedImportToNative",
            "static void amproj_activateNextPendingImport",
        )
        self.assertIn("amproj_originalHookForClass", body)
        self.assertIn("AMProjApplicationOpenURLIMP", body)
        self.assertNotIn("objc_msgSend", body)
        self.assertEqual(body.count("UIApplicationOpenURLOptionsOpenInPlaceKey"), 1)


if __name__ == "__main__":
    unittest.main()
