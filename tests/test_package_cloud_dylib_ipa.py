import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import package_cloud_dylib_ipa as packager


class CloudOnlyPackageTests(unittest.TestCase):
    def test_replaces_cloud_and_removes_legacy_standalone_home_ui(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "AMProjExportCloud.dylib"
            cloud_path.write_bytes(b"new-cloud")
            with zipfile.ZipFile(source_path, "w") as source:
                source.writestr(packager.CLOUD_PATH, b"old-cloud")
                source.writestr(packager.HOME_UI_PATH, b"old-home-ui")
                source.writestr("Payload/AlightMotion.app/Info.plist", b"plist")

            with (
                mock.patch.object(packager.direct, "verify_cloud_runtime_version"),
                mock.patch.object(packager.direct, "verify_cloud_stability_contract"),
                mock.patch.object(packager.direct, "prepare_cloud"),
            ):
                packager.package(source_path, output_path, cloud_path)

            with zipfile.ZipFile(output_path) as output:
                self.assertEqual(output.read(packager.CLOUD_PATH), b"new-cloud")
                self.assertNotIn(packager.HOME_UI_PATH, output.namelist())
                self.assertEqual(
                    output.read("Payload/AlightMotion.app/Info.plist"), b"plist"
                )


if __name__ == "__main__":
    unittest.main()
