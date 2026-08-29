import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import package_cloud_dylib_ipa as packager
from tests.test_package_editor_button_ipa import make_home_ui_dylib, make_main


class CloudOnlyPackageTests(unittest.TestCase):
    def test_replaces_cloud_and_preserves_standalone_home_ui(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "AMProjExportCloud.dylib"
            cloud_path.write_bytes(b"new-cloud")
            home_ui = make_home_ui_dylib()
            with zipfile.ZipFile(source_path, "w") as source:
                source.writestr(packager.CLOUD_PATH, b"old-cloud")
                source.writestr(packager.HOME_UI_PATH, home_ui)
                source.writestr(packager.MAIN_PATH, make_main())
                source.writestr("Payload/AlightMotion.app/Info.plist", b"plist")

            with (
                mock.patch.object(packager.direct, "verify_cloud_runtime_version"),
                mock.patch.object(packager.direct, "verify_cloud_stability_contract"),
                mock.patch.object(packager.direct, "prepare_cloud"),
            ):
                packager.package(source_path, output_path, cloud_path)

            with zipfile.ZipFile(output_path) as output:
                self.assertEqual(output.read(packager.CLOUD_PATH), b"new-cloud")
                self.assertEqual(output.read(packager.HOME_UI_PATH), home_ui)
                self.assertEqual(output.namelist().count(packager.HOME_UI_PATH), 1)
                self.assertEqual(
                    output.getinfo(packager.HOME_UI_PATH).external_attr >> 16,
                    0o100755,
                )
                info = packager.inject_dylib.parse_macho_data(
                    output.read(packager.MAIN_PATH), packager.MAIN_PATH
                )
                packager.homeui.ensure_home_ui_load_contract(info, "output main")
                self.assertEqual(
                    output.read("Payload/AlightMotion.app/Info.plist"), b"plist"
                )


if __name__ == "__main__":
    unittest.main()
