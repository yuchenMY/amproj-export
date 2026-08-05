import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMMeowLoader.c").read_text(encoding="utf-8")
MAKEFILE = (ROOT / "AMProjExport" / "Makefile").read_text(encoding="utf-8")
WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")


class AMMeowLoaderSourceTests(unittest.TestCase):
    def test_loader_is_our_fixed_single_cloud_entrypoint(self):
        self.assertIn("__attribute__((constructor(101)))", SOURCE)
        self.assertIn("@executable_path/Frameworks/AMProjExportCloud.dylib", SOURCE)
        self.assertIn("dlopen(path, RTLD_NOW | RTLD_LOCAL)", SOURCE)
        self.assertIn("g_attempted", SOURCE)
        self.assertIn("os_log_info", SOURCE)
        self.assertIn("os_log_error", SOURCE)
        self.assertNotIn("LoadControl", SOURCE)
        self.assertNotIn("sideloader", SOURCE)
        self.assertNotIn("getLinkedBundleIDs", SOURCE)

    def test_makefile_and_ci_build_and_ship_only_our_loader(self):
        self.assertIn("AMMeowLoader.dylib", MAKEFILE)
        self.assertIn("AMMeowLoader.c", MAKEFILE)
        self.assertIn("AMProjExport/AMMeowLoader.dylib", WORKFLOW)
        self.assertNotIn("LoadControl.dylib", MAKEFILE)
        self.assertNotIn("LoadControl.dylib", WORKFLOW)


if __name__ == "__main__":
    unittest.main()
