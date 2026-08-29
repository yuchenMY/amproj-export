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


def synthetic_main(extra_commands=(), *, filetype=inject_dylib.MH_EXECUTE):
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
    commands = (
        segment
        + section
        + struct.pack("<II16s", inject_dylib.LC_UUID, 24, uuid)
        + b"".join(extra_commands)
    )
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        inject_dylib.CPU_TYPE_ARM64,
        0,
        filetype,
        2 + len(extra_commands),
        len(commands),
        0,
        0,
    )
    return header + commands + bytes(section_offset - 32 - len(commands)) + b"textdata"


def synthetic_cloud(*install_names):
    return synthetic_main(
        tuple(
            dylib_command(inject_dylib.LC_ID_DYLIB, install_name)
            for install_name in install_names
        ),
        filetype=inject_dylib.MH_DYLIB,
    )


def windows_zip_info(name):
    info = zipfile.ZipInfo(name)
    info.create_system = 0
    info.external_attr = 0
    return info


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

    def test_prepare_main_injects_strong_export_without_changing_uuid(self):
        result = migration.prepare_main(synthetic_main())
        info = inject_dylib.parse_macho_data(result)
        self.assertEqual(info["uuid"], "c8d53b88593d3a4082a11805d1835cd0")
        loads = [
            item for item in info["dylib_load_commands"]
            if item["name"] == migration.CLOUD_LOAD
        ]
        self.assertEqual(len(loads), 1)
        self.assertEqual(loads[0]["cmd"], inject_dylib.LC_LOAD_DYLIB)
        self.assertFalse(migration._dylib_loads(info, migration.LEGACY_CLOUD_LOAD))

    def test_prepare_main_rewrites_legacy_cloud_load_in_place(self):
        legacy = dylib_command(
            inject_dylib.LC_LOAD_DYLIB, migration.LEGACY_CLOUD_LOAD, size=96
        )
        source = synthetic_main((legacy,))
        result = migration.prepare_main(source)
        info = inject_dylib.parse_macho_data(result)
        self.assertEqual(len(migration._dylib_loads(info, migration.CLOUD_LOAD)), 1)
        self.assertFalse(migration._dylib_loads(info, migration.LEGACY_CLOUD_LOAD))
        self.assertEqual(info["ncmds"], inject_dylib.parse_macho_data(source)["ncmds"])
        self.assertEqual(result[:32], source[:32])

    def test_prepare_main_rejects_noncanonical_legacy_cloud_load_paths(self):
        for legacy_path in (
            "@rpath/AMProjExportCloud.dylib",
            "@loader_path/Frameworks/AMProjExportCloud.dylib",
        ):
            with self.subTest(legacy_path=legacy_path):
                source = synthetic_main(
                    (dylib_command(inject_dylib.LC_LOAD_DYLIB, legacy_path),)
                )
                with self.assertRaisesRegex(RuntimeError, "unsupported dylib load path"):
                    migration.prepare_main(source)

    def test_prepare_main_rejects_new_and_legacy_cloud_loads_together(self):
        source = synthetic_main(
            (
                dylib_command(inject_dylib.LC_LOAD_DYLIB, migration.CLOUD_LOAD),
                dylib_command(inject_dylib.LC_LOAD_DYLIB, migration.LEGACY_CLOUD_LOAD),
            )
        )
        with self.assertRaisesRegex(RuntimeError, "both current and legacy"):
            migration.prepare_main(source)

    def test_prepare_main_rejects_legacy_loader_to_prevent_double_loading(self):
        source = synthetic_main(
            (
                dylib_command(
                    inject_dylib.LC_LOAD_DYLIB,
                    "@executable_path/Frameworks/AMMeowLoader.dylib",
                ),
            )
        )
        with self.assertRaisesRegex(RuntimeError, "AMMeowLoader"):
            migration.prepare_main(source)

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

    def test_verify_cloud_requires_exactly_one_canonical_install_name(self):
        with tempfile.TemporaryDirectory() as directory:
            cloud_path = Path(directory) / "AMProjExport.dylib"
            cloud_path.write_bytes(
                synthetic_cloud("@rpath/AMProjExport.dylib")
            )
            with (
                mock.patch.object(migration.cloud_contract, "verify_cloud_runtime_version"),
                mock.patch.object(migration.cloud_contract, "verify_cloud_stability_contract"),
                mock.patch.object(migration.homeui, "verify_cloud_payload"),
            ):
                self.assertEqual(
                    migration.verify_cloud(cloud_path), cloud_path.read_bytes()
                )

    def test_verify_cloud_rejects_legacy_or_duplicate_install_name(self):
        fixtures = {
            "legacy": synthetic_cloud("@rpath/AMProjExportCloud.dylib"),
            "duplicate": synthetic_cloud(
                "@rpath/AMProjExport.dylib",
                "@rpath/AMProjExport.dylib",
            ),
        }
        with tempfile.TemporaryDirectory() as directory:
            for label, payload in fixtures.items():
                with self.subTest(label=label):
                    cloud_path = Path(directory) / (label + ".dylib")
                    cloud_path.write_bytes(payload)
                    with self.assertRaisesRegex(RuntimeError, "LC_ID_DYLIB|install name"):
                        migration.verify_cloud(cloud_path)

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
                archive.writestr(
                    migration.MAIN_PATH,
                    synthetic_main(
                        (
                            dylib_command(
                                inject_dylib.LC_LOAD_DYLIB,
                                migration.LEGACY_CLOUD_LOAD,
                            ),
                        )
                    ),
                )
                archive.writestr(migration.INFO_PATH, info)
                archive.writestr(migration.LEGACY_CLOUD_PATH, b"legacy cloud")
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
                self.assertNotIn(migration.LEGACY_CLOUD_PATH, names)
                self.assertEqual(names.count(migration.CLOUD_PATH), 1)
                self.assertEqual(archive.read(migration.CLOUD_PATH), cloud)
                self.assertEqual(
                    archive.getinfo(migration.MAIN_PATH).external_attr >> 16,
                    0o100755,
                )
                self.assertEqual(archive.getinfo(migration.MAIN_PATH).create_system, 3)
                self.assertEqual(
                    archive.getinfo(migration.CLOUD_PATH).external_attr >> 16,
                    0o100755,
                )
                self.assertEqual(archive.getinfo(migration.CLOUD_PATH).create_system, 3)
                output_info = inject_dylib.parse_macho_data(
                    archive.read(migration.MAIN_PATH)
                )
                self.assertEqual(
                    len(migration._dylib_loads(output_info, migration.CLOUD_LOAD)), 1
                )
                self.assertFalse(
                    migration._dylib_loads(output_info, migration.LEGACY_CLOUD_LOAD)
                )
                self.assertEqual(archive.read(migration.BUTTON_PATH), b"button")
                for name in migration.CATEGORY_NAMES:
                    self.assertEqual(archive.read(migration.category_path(name)), b"\x89PNG\r\n\x1a\n" + name.encode())
                self.assertEqual(archive.read("Payload/AlightMotion.app/keep.txt"), b"keep")

    def test_package_rejects_loader_framework_member(self):
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
                archive.writestr(migration.LOADER_PATH, b"legacy loader")
            cloud_path = root / "cloud.dylib"
            cloud_path.write_bytes(b"cloud")
            with mock.patch.object(migration, "verify_cloud", return_value=b"cloud"):
                with self.assertRaisesRegex(RuntimeError, "AMMeowLoader"):
                    migration.package(source, output, cloud_path, categories, button)
            self.assertFalse(output.exists())

    def test_package_rejects_noncanonical_legacy_cloud_member(self):
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
                archive.writestr(
                    "Payload/AlightMotion.app/Resources/AMProjExportCloud.dylib",
                    b"legacy cloud",
                )
            cloud_path = root / "cloud.dylib"
            cloud_path.write_bytes(b"cloud")
            with mock.patch.object(migration, "verify_cloud", return_value=b"cloud"):
                with self.assertRaisesRegex(RuntimeError, "outside the canonical Frameworks path"):
                    migration.package(source, output, cloud_path, categories, button)
            self.assertFalse(output.exists())

    def test_package_normalizes_windows_zip_metadata_for_loadable_members(self):
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
                archive.writestr(windows_zip_info(migration.MAIN_PATH), synthetic_main())
                archive.writestr(windows_zip_info(migration.INFO_PATH), info)
            cloud_path = root / "cloud.dylib"
            cloud_path.write_bytes(b"cloud")
            with mock.patch.object(migration, "verify_cloud", return_value=b"cloud"):
                migration.package(source, output, cloud_path, categories, button)
            with zipfile.ZipFile(output) as archive:
                for name in (migration.MAIN_PATH, migration.CLOUD_PATH):
                    member = archive.getinfo(name)
                    self.assertEqual(member.create_system, 3)
                    self.assertEqual(member.external_attr >> 16, 0o100755)


if __name__ == "__main__":
    unittest.main()
