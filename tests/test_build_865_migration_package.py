import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import build_865_migration_package as migration
import inject_dylib


def dylib_command(command, name, size=88):
    encoded = name.encode("utf-8") + b"\0"
    if 24 + len(encoded) > size:
        size = (24 + len(encoded) + 7) & ~7
    return (
        struct.pack("<IIIIII", command, size, 24, 2, 0x10000, 0x10000)
        + encoded.ljust(size - 24, b"\0")
    )


def synthetic_main():
    section_offset = 0x1000
    uuid = bytes.fromhex("c8d53b88593d3a4082a11805d1835cd0")
    segment = struct.pack(
        "<II16sQQQQIIII",
        inject_dylib.LC_SEGMENT_64,
        152,
        b"__TEXT" + bytes(10),
        0x100000000,
        0x2000,
        0,
        0x2000,
        7,
        5,
        1,
        0,
    )
    section = struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text" + bytes(10),
        b"__TEXT" + bytes(10),
        0x100000000 + section_offset,
        8,
        section_offset,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    commands = segment + section + struct.pack(
        "<II16s", inject_dylib.LC_UUID, 24, uuid
    )
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        inject_dylib.CPU_TYPE_ARM64,
        0,
        inject_dylib.MH_EXECUTE,
        2,
        len(commands),
        0,
        0,
    )
    return header + commands + bytes(section_offset - 32 - len(commands)) + b"textdata"


class Build865MigrationTests(unittest.TestCase):
    def test_prepare_info_preserves_new_keys_and_registers_projects(self):
        original = plistlib.dumps(
            {
                "CFBundleExecutable": "AlightMotion",
                "CFBundleShortVersionString": "6.2.58",
                "CFBundleVersion": "865",
                "CFBundleIdentifier": "com.alightcreative.motion",
                "CFBundleDisplayName": "Alight Motion",
                "CFBundleName": "Alight Motion",
                "UIUserInterfaceStyle": "Dark",
                "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
                "CFBundleURLTypes": [{"CFBundleURLSchemes": ["alightmotion"]}],
            },
            fmt=plistlib.FMT_BINARY,
        )
        prepared = plistlib.loads(
            migration.prepare_info_plist(original, "com.ayakameow.am", "\u732b\u9e64AM-Meow")
        )
        self.assertEqual(prepared["CFBundleShortVersionString"], "6.2.58")
        self.assertEqual(prepared["CFBundleVersion"], "865")
        self.assertEqual(prepared["CFBundleIdentifier"], "com.ayakameow.am")
        self.assertNotIn("UIUserInterfaceStyle", prepared)
        self.assertEqual(prepared["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"], "AppIcon")
        self.assertIsNotNone(migration._document_type(prepared, migration.AMPROJ_UTI))
        self.assertIsNotNone(migration._document_type(prepared, migration.XML_UTI))
        self.assertIsNotNone(migration._exported_type(prepared, migration.AMPROJ_UTI))

    def test_prepare_main_injects_strong_cloud_without_changing_uuid(self):
        result = migration.prepare_main(synthetic_main())
        info = inject_dylib.parse_macho_data(result)
        self.assertEqual(info["uuid"], "c8d53b88593d3a4082a11805d1835cd0")
        loads = [
            item for item in info["dylib_load_commands"]
            if item["name"] == "@executable_path/Frameworks/AMProjExportCloud.dylib"
        ]
        self.assertEqual(len(loads), 1)
        self.assertEqual(loads[0]["cmd"], inject_dylib.LC_LOAD_DYLIB)

    def test_prepare_main_injects_standalone_home_ui_once(self):
        result = migration.prepare_main(synthetic_main(), include_home_ui=True)
        info = inject_dylib.parse_macho_data(result)
        loads = [
            item
            for item in info["dylib_load_commands"]
            if item["name"] == "@executable_path/Frameworks/AMHomeUI.dylib"
        ]
        self.assertEqual(len(loads), 1)
        self.assertEqual(loads[0]["cmd"], inject_dylib.LC_LOAD_DYLIB)
        self.assertEqual(
            migration.prepare_main(result, include_home_ui=True), result
        )

    def test_new_home_ui_zip_member_is_executable(self):
        info = migration.new_zip_info(
            migration.HOME_UI_PATH, executable=True
        )
        self.assertEqual(info.external_attr >> 16, 0o100755)

    def test_package_migrates_assets_and_removes_stale_signatures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.ipa"
            output = root / "output.ipa"
            categories = root / "categories"
            categories.mkdir()
            button = root / "button.png"
            button.write_bytes(b"button")
            for name in migration.CATEGORY_NAMES:
                (categories / name).write_bytes(b"\x89PNG\r\n\x1a\n" + name.encode())
            info = plistlib.dumps(
                {
                    "CFBundleExecutable": "AlightMotion",
                    "CFBundleShortVersionString": "6.2.58",
                    "CFBundleVersion": "865",
                    "CFBundleIdentifier": "com.alightcreative.motion",
                    "CFBundleDisplayName": "Alight Motion",
                    "CFBundleName": "Alight Motion",
                },
                fmt=plistlib.FMT_BINARY,
            )
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(migration.MAIN_PATH, synthetic_main())
                archive.writestr(migration.INFO_PATH, info)
                archive.writestr("Payload/AlightMotion.app/_CodeSignature/CodeResources", b"stale")
                for name in migration.CATEGORY_NAMES[:-1]:
                    archive.writestr(migration.category_path(name), b"old")
                archive.writestr("Payload/AlightMotion.app/keep.txt", b"keep")
            cloud = b"cloud"
            cloud_path = root / "cloud.dylib"
            cloud_path.write_bytes(cloud)
            with mock.patch.object(migration, "verify_cloud", return_value=cloud):
                result = migration.package(source, output, cloud_path, categories, button)
            self.assertEqual(result["category_count"], 12)
            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
                self.assertIsNone(archive.testzip())
                self.assertNotIn("Payload/AlightMotion.app/_CodeSignature/CodeResources", names)
                self.assertEqual(archive.read(migration.CLOUD_PATH), cloud)
                self.assertEqual(
                    archive.getinfo(migration.MAIN_PATH).external_attr >> 16,
                    0o100755,
                )
                self.assertEqual(
                    archive.getinfo(migration.CLOUD_PATH).external_attr >> 16,
                    0o100755,
                )
                self.assertEqual(archive.read(migration.BUTTON_PATH), b"button")
                for name in migration.CATEGORY_NAMES:
                    self.assertEqual(archive.read(migration.category_path(name)), b"\x89PNG\r\n\x1a\n" + name.encode())
                self.assertEqual(archive.read("Payload/AlightMotion.app/keep.txt"), b"keep")


if __name__ == "__main__":
    unittest.main()
