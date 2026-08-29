import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMMeowLoader.c").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")


class AMMeowLoaderSourceTests(unittest.TestCase):
    def test_loader_is_our_fixed_single_cloud_entrypoint(self):
        self.assertIn("__attribute__((constructor(101)))", SOURCE)
        self.assertIn("@executable_path/Frameworks/AMProjExport.dylib", SOURCE)
        self.assertNotIn("AMProjExportCloud.dylib", SOURCE)
        self.assertIn("dlopen(path, RTLD_NOW | RTLD_LOCAL)", SOURCE)
        self.assertIn("g_attempted", SOURCE)
        self.assertIn("os_log_info", SOURCE)
        self.assertIn("os_log_error", SOURCE)
        self.assertNotIn("LoadControl", SOURCE)
        self.assertNotIn("sideloader", SOURCE)
        self.assertNotIn("getLinkedBundleIDs", SOURCE)

    def test_loader_is_explicit_legacy_target_and_not_shipped_for_865(self):
        self.assertIn("AMMeowLoader.dylib", MAKEFILE)
        self.assertIn("AMMeowLoader.c", MAKEFILE)
        default_targets = MAKEFILE.split("all:", 1)[1].splitlines()[0]
        self.assertNotIn("AMMeowLoader.dylib", default_targets)
        self.assertIn("legacy-loader: AMMeowLoader.dylib", MAKEFILE)
        self.assertNotIn("AMProjExport/AMMeowLoader.dylib", WORKFLOW)
        self.assertIn("AMProjExport/AMProjExport.dylib", WORKFLOW)
        self.assertNotIn("AMProjExportCloud.dylib", WORKFLOW)
        self.assertNotIn("LoadControl.dylib", MAKEFILE)
        self.assertNotIn("LoadControl.dylib", WORKFLOW)


if __name__ == "__main__":
    unittest.main()
