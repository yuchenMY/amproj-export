import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import build_862_official_effects_package as final_package
import package_official_builtin_effects_ipa as official_effects


def effect_xml(effect_id):
    return f'<effect id="{effect_id}" />'.encode()


class OfficialEffectsFinalPackageTests(unittest.TestCase):
    def test_final_package_keeps_repaired_effects_and_removes_home_ui(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "AMProjExportCloud.dylib"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            cloud_path.write_bytes(b"new-cloud")
            effects.joinpath("lift.xml").write_bytes(
                effect_xml("com.alightcreative.effects.lift.fixed")
            )
            with zipfile.ZipFile(source_path, "w") as source:
                source.writestr(
                    official_effects.BUILTIN_EFFECTS_PREFIX + "lift.xml",
                    effect_xml("com.alightcreative.effects.lift.fixed"),
                )
                source.writestr(final_package.direct.CLOUD_PATH, b"old-cloud")
                source.writestr(final_package.direct.HOME_UI_PATH, b"old-home-ui")
                source.writestr("Payload/AlightMotion.app/custom.bin", b"custom")

            def fake_direct(repaired_path, final_path, cloud_path=None):
                with zipfile.ZipFile(repaired_path, "r") as repaired, zipfile.ZipFile(
                    final_path, "w"
                ) as output:
                    for info in repaired.infolist():
                        if info.filename == final_package.direct.HOME_UI_PATH:
                            continue
                        payload = repaired.read(info.filename)
                        if info.filename == final_package.direct.CLOUD_PATH:
                            payload = Path(cloud_path).read_bytes()
                        output.writestr(info, payload)
                return {
                    "output": str(final_path),
                    "cloud_member": final_package.direct.CLOUD_PATH,
                }

            with (
                mock.patch.object(
                    final_package.direct, "build_direct_package", side_effect=fake_direct
                ),
                mock.patch.object(final_package.editor_package, "verify_cloud_embedded_home_ui") as verify_cloud,
            ):
                result = final_package.build(
                    source_path, output_path, effects, cloud_path
                )

            self.assertTrue(result["requires_recursive_real_signing"])
            self.assertEqual(verify_cloud.call_count, 2)
            with zipfile.ZipFile(output_path) as output:
                self.assertNotIn(
                    final_package.direct.HOME_UI_PATH, output.namelist()
                )
                self.assertEqual(
                    output.read(official_effects.BUILTIN_EFFECTS_PREFIX + "lift.xml"),
                    effect_xml("com.alightcreative.effects.lift.fixed"),
                )
                self.assertEqual(
                    output.read(final_package.direct.CLOUD_PATH), b"new-cloud")
                self.assertEqual(
                    output.read("Payload/AlightMotion.app/custom.bin"), b"custom"
                )

    def test_rejects_cloud_that_fails_the_embedded_home_ui_contract(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "old-cloud.dylib"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            source_path.write_bytes(b"source")
            cloud_path.write_bytes(b"old-cloud")

            with (
                mock.patch.object(
                    final_package.editor_package,
                    "verify_cloud_embedded_home_ui",
                    side_effect=RuntimeError("split HomeUI dependency"),
                ),
                mock.patch.object(final_package.direct, "build_direct_package") as direct_build,
            ):
                with self.assertRaisesRegex(RuntimeError, "split HomeUI dependency"):
                    final_package.build(source_path, output_path, effects, cloud_path)

            direct_build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
