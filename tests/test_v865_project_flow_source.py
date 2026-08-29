import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORT = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
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
        self.assertIn("-install_name @rpath/AMProjExport.dylib", cloud_rule)
        self.assertNotIn("AMHomeUI.m", cloud_rule)

    def test_865_release_does_not_install_a_global_action_observer(self):
        self.assertNotIn('#import "AMProjV865ProjectFlow.h"', EXPORT)
        self.assertNotIn("AMProjV865ProjectFlowInstall", EXPORT)
        self.assertNotIn("sendAction:to:from:forEvent:", EXPORT)

    def test_865_release_does_not_compile_the_diagnostic_project_flow_module(self):
        release_rule = MAKEFILE.split("AMProjExport.dylib:", 1)[1].split(
            "AMProjExportOffline.dylib:", 1
        )[0]
        debug_rule = MAKEFILE.split("AMProjExportDebug.dylib:", 1)[1].split(
            "AMMeowLoader.dylib:", 1
        )[0]
        offline_rule = MAKEFILE.split("AMProjExportOffline.dylib:", 1)[1].split(
            "AMProjExportDebug.dylib:", 1
        )[0]
        for rule in (release_rule, debug_rule, offline_rule):
            self.assertNotIn("AMProjV865ProjectFlow", rule)

    def test_865_release_keeps_native_project_actions_unowned(self):
        self.assertNotIn("amproj_start865ProjectPackageExport", EXPORT)
        self.assertNotIn("amproj_start865CloudProjectUpload", EXPORT)


if __name__ == "__main__":
    unittest.main()
