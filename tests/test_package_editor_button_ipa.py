import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import inject_dylib
import package_editor_button_ipa as packager


ROOT = Path(__file__).resolve().parents[1]
PACKAGER_SOURCE = (ROOT / "package_editor_button_ipa.py").read_text(
    encoding="utf-8"
)


def make_dylib_command(command, name):
    encoded_name = name.encode("utf-8") + b"\0"
    command_size = (24 + len(encoded_name) + 7) & ~7
    return struct.pack(
        "<IIIIII",
        command,
        command_size,
        24,
        2,
        0x10000,
        0x10000,
    ) + encoded_name.ljust(command_size - 24, b"\0")


def make_main(load_commands=(), section_payload=b"section-payload"):
    first_section_offset = 0x1000
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
        0x100000000 + first_section_offset,
        len(section_payload),
        first_section_offset,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    commands = segment + section + b"".join(load_commands)
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        inject_dylib.CPU_TYPE_ARM64,
        0,
        inject_dylib.MH_EXECUTE,
        1 + len(load_commands),
        len(commands),
        0,
        0,
    )
    return (
        header
        + commands
        + bytes(first_section_offset - 32 - len(commands))
        + section_payload
    )


def make_cloud_dylib(
    install_name="@rpath/AMProjExportCloud.dylib",
    symbol_name="_AMCloudMarker",
    include_url=False,
    load_commands=(),
):
    section_offset = 0x1000
    section_size = 8
    symbol_offset = 0x1010
    string_table = b"\0" + symbol_name.encode("ascii") + b"\0"
    string_offset = symbol_offset + 16
    home_url = b"https://amhome.meowcr.cn/home\0" if include_url else b""

    segment_size = 152
    segment = struct.pack(
        "<II16sQQQQIIII",
        inject_dylib.LC_SEGMENT_64,
        segment_size,
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
        section_size,
        section_offset,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    identifier = make_dylib_command(inject_dylib.LC_ID_DYLIB, install_name)
    symtab = struct.pack(
        "<IIIIII",
        inject_dylib.LC_SYMTAB,
        24,
        symbol_offset,
        1,
        string_offset,
        len(string_table),
    )
    commands = segment + section + identifier + b"".join(load_commands) + symtab
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        inject_dylib.CPU_TYPE_ARM64,
        0,
        inject_dylib.MH_DYLIB,
        3 + len(load_commands),
        len(commands),
        0,
        0,
    )
    prefix = header + commands
    if len(prefix) > section_offset:
        raise AssertionError("synthetic Cloud load commands exceed section offset")

    total_size = string_offset + len(string_table) + len(home_url)
    data = bytearray(max(total_size, section_offset + section_size))
    data[: len(prefix)] = prefix
    data[symbol_offset : symbol_offset + 16] = struct.pack(
        "<IBBHQ",
        1,
        inject_dylib.N_EXT | inject_dylib.N_SECT,
        1,
        0,
        0x100000000 + section_offset,
    )
    data[string_offset : string_offset + len(string_table)] = string_table
    if home_url:
        url_offset = string_offset + len(string_table)
        data[url_offset : url_offset + len(home_url)] = home_url
    return bytes(data)


def make_home_ui_dylib():
    return make_cloud_dylib(
        install_name="@rpath/AMHomeUI.dylib",
        symbol_name="_AMHomeUIInstall",
        include_url=True,
    )


class EditorHomePackageTests(unittest.TestCase):
    def test_cloud_and_home_ui_verifiers_enforce_the_split_contract(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "AMProjExportCloud.dylib"

            binary = make_cloud_dylib()
            path.write_bytes(binary)
            packager.verify_cloud_standalone_home_ui(path)

            binary = make_cloud_dylib(include_url=True)
            path.write_bytes(binary)
            with self.assertRaisesRegex(RuntimeError, "must not embed the Home UI URL"):
                packager.verify_cloud_standalone_home_ui(path)

            binary = make_cloud_dylib(symbol_name="_AMHomeUIInstall")
            path.write_bytes(binary)
            with self.assertRaisesRegex(RuntimeError, "must not define _AMHomeUIInstall"):
                packager.verify_cloud_standalone_home_ui(path)

            home_path = Path(temporary_directory) / "AMHomeUI.dylib"
            home = make_home_ui_dylib()
            home_path.write_bytes(home)
            packager.verify_home_ui_binary(home_path, home)

    def test_cloud_verifier_rejects_every_home_ui_load_kind_and_path(self):
        cases = (
            (
                inject_dylib.LC_LOAD_DYLIB,
                "@executable_path/Frameworks/AMHomeUI.dylib",
            ),
            (inject_dylib.LC_LOAD_WEAK_DYLIB, "@rpath/AMHomeUI.dylib"),
            (inject_dylib.LC_REEXPORT_DYLIB, "/tmp/AMHomeUI.dylib"),
            (inject_dylib.LC_LAZY_LOAD_DYLIB, "@loader_path/AMHomeUI.dylib"),
            (inject_dylib.LC_LOAD_UPWARD_DYLIB, "AMHomeUI.dylib"),
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "AMProjExportCloud.dylib"
            for command, name in cases:
                with self.subTest(command=command, name=name):
                    binary = make_cloud_dylib(
                        load_commands=(make_dylib_command(command, name),)
                    )
                    path.write_bytes(binary)
                    with self.assertRaisesRegex(
                        RuntimeError, "must not contain an AMHomeUI load command"
                    ):
                        packager.verify_cloud_standalone_home_ui(path)

    def test_main_validation_accepts_no_home_ui_load(self):
        info = inject_dylib.parse_macho_data(make_main())
        packager.ensure_no_home_ui_loads(info, "source main")

    def test_main_validation_rejects_noncanonical_home_ui_load_kind_and_path(self):
        cases = (
            (inject_dylib.LC_LOAD_DYLIB,
             "@executable_path/Frameworks/AMHomeUI.dylib"),
            (inject_dylib.LC_LOAD_WEAK_DYLIB, "@rpath/AMHomeUI.dylib"),
            (inject_dylib.LC_REEXPORT_DYLIB, "/tmp/AMHomeUI.dylib"),
            (inject_dylib.LC_LAZY_LOAD_DYLIB, "@loader_path/AMHomeUI.dylib"),
            (inject_dylib.LC_LOAD_UPWARD_DYLIB, "AMHomeUI.dylib"),
        )
        for command, name in cases:
            with self.subTest(command=command, name=name):
                load = make_dylib_command(command, name)
                info = inject_dylib.parse_macho_data(make_main((load,)))
                if command == inject_dylib.LC_LOAD_DYLIB and name == packager.HOME_UI_LOAD:
                    packager.ensure_home_ui_load_contract(info, "source main")
                else:
                    with self.assertRaisesRegex(RuntimeError, "conflicting AMHomeUI load"):
                        packager.ensure_home_ui_load_contract(info, "source main")

    def test_packager_has_standalone_home_ui_contract(self):
        self.assertIn("patch_main_with_home_ui", PACKAGER_SOURCE)
        self.assertIn('parser.add_argument("home_ui")', PACKAGER_SOURCE)
        self.assertIn("verify_cloud_standalone_home_ui(dylib_path)", PACKAGER_SOURCE)
        self.assertIn("verify_home_ui_binary(home_ui_path, home_ui)", PACKAGER_SOURCE)

    def test_package_injects_and_preserves_standalone_home_ui(self):
        main = make_main()
        cloud = make_cloud_dylib()
        home_ui = make_home_ui_dylib()
        button = b"button-image"

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "AMProjExportCloud.dylib"
            home_ui_path = root / "AMHomeUI.dylib"
            button_path = root / "button.png"
            categories = root / "categories"
            categories.mkdir()
            cloud_path.write_bytes(cloud)
            home_ui_path.write_bytes(home_ui)
            button_path.write_bytes(button)
            for name in packager.CATEGORY_NAMES:
                (categories / name).write_bytes(("category:" + name).encode())

            with zipfile.ZipFile(source_path, "w") as source:
                source.writestr(packager.MAIN_PATH, main)
                source.writestr(packager.CLOUD_PATH, b"old-cloud")
                source.writestr("Payload/AlightMotion.app/Info.plist", b"plist")
                for name in packager.CATEGORY_NAMES:
                    if name == "ic_category_thumbnail_other.png":
                        continue
                    source.writestr(
                        packager.category_path(name),
                        ("old:" + name).encode(),
                    )

            with (
                mock.patch.object(packager.direct, "verify_cloud_runtime_version"),
                mock.patch.object(packager.direct, "verify_cloud_stability_contract"),
                mock.patch.object(packager.direct, "prepare_cloud"),
            ):
                packager.package(
                    source_path,
                    output_path,
                    cloud_path,
                    home_ui_path,
                    button_path,
                    categories,
                )

            with zipfile.ZipFile(output_path) as output:
                self.assertNotEqual(output.read(packager.MAIN_PATH), main)
                self.assertEqual(output.read(packager.CLOUD_PATH), cloud)
                self.assertEqual(output.read(packager.HOME_UI_PATH), home_ui)
                self.assertEqual(output.namelist().count(packager.CLOUD_PATH), 1)
                self.assertEqual(output.namelist().count(packager.HOME_UI_PATH), 1)
                home_ui_mode = (output.getinfo(packager.HOME_UI_PATH).external_attr >> 16) & 0o777
                self.assertEqual(home_ui_mode, 0o755)
                self.assertEqual(
                    output.read(
                        packager.category_path(
                            "ic_category_thumbnail_other.png"
                        )
                    ),
                    b"category:ic_category_thumbnail_other.png",
                )
                info = inject_dylib.parse_macho_data(
                    output.read(packager.MAIN_PATH)
                )
                packager.ensure_home_ui_load_contract(info, "output main")
                packager.verify_cloud_standalone_home_ui(cloud_path)

    def test_package_does_not_inject_duplicate_when_source_already_loads_home_ui(self):
        """A previously packaged IPA must retain one canonical HomeUI load."""
        main = make_main(
            (
                make_dylib_command(
                    inject_dylib.LC_LOAD_DYLIB, packager.HOME_UI_LOAD
                ),
            )
        )
        cloud = make_cloud_dylib()
        home_ui = make_home_ui_dylib()
        button = b"button-image"

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "AMProjExportCloud.dylib"
            home_ui_path = root / "AMHomeUI.dylib"
            button_path = root / "button.png"
            categories = root / "categories"
            categories.mkdir()
            cloud_path.write_bytes(cloud)
            home_ui_path.write_bytes(home_ui)
            button_path.write_bytes(button)
            for name in packager.CATEGORY_NAMES:
                (categories / name).write_bytes(("category:" + name).encode())

            with zipfile.ZipFile(source_path, "w") as source:
                source.writestr(packager.MAIN_PATH, main)
                source.writestr(packager.CLOUD_PATH, b"old-cloud")
                source.writestr(packager.HOME_UI_PATH, home_ui)
                source.writestr("Payload/AlightMotion.app/Info.plist", b"plist")
                for name in packager.CATEGORY_NAMES:
                    source.writestr(
                        packager.category_path(name), ("old:" + name).encode()
                    )

            with (
                mock.patch.object(packager.direct, "verify_cloud_runtime_version"),
                mock.patch.object(packager.direct, "verify_cloud_stability_contract"),
                mock.patch.object(packager.direct, "prepare_cloud"),
            ):
                packager.package(
                    source_path,
                    output_path,
                    cloud_path,
                    home_ui_path,
                    button_path,
                    categories,
                )

            with zipfile.ZipFile(output_path) as output:
                self.assertEqual(output.namelist().count(packager.HOME_UI_PATH), 1)
                self.assertEqual(output.read(packager.HOME_UI_PATH), home_ui)
                self.assertEqual(output.read(packager.MAIN_PATH), main)
                info = inject_dylib.parse_macho_data(output.read(packager.MAIN_PATH))
                loads = [
                    item
                    for item in info["dylib_load_commands"]
                    if item["name"] == packager.HOME_UI_LOAD
                ]
                self.assertEqual(len(loads), 1)
                packager.ensure_home_ui_load_contract(info, "output main")

    def test_package_rejects_cloud_home_ui_symbol_before_writing_output(self):
        """The old Cloud-embedded HomeUI ABI must never reach the handoff IPA."""
        main = make_main()
        cloud = make_cloud_dylib(symbol_name="_AMHomeUIInstall")
        home_ui = make_home_ui_dylib()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_path = root / "source.ipa"
            output_path = root / "output.ipa"
            cloud_path = root / "AMProjExportCloud.dylib"
            home_ui_path = root / "AMHomeUI.dylib"
            button_path = root / "button.png"
            categories = root / "categories"
            categories.mkdir()
            cloud_path.write_bytes(cloud)
            home_ui_path.write_bytes(home_ui)
            button_path.write_bytes(b"button")
            for name in packager.CATEGORY_NAMES:
                (categories / name).write_bytes(b"category")
            with zipfile.ZipFile(source_path, "w") as source:
                source.writestr(packager.MAIN_PATH, main)
                source.writestr(packager.CLOUD_PATH, b"old-cloud")
                source.writestr("Payload/AlightMotion.app/Info.plist", b"plist")

            with (
                mock.patch.object(packager.direct, "verify_cloud_runtime_version"),
                mock.patch.object(packager.direct, "verify_cloud_stability_contract"),
                mock.patch.object(packager.direct, "prepare_cloud"),
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "must not define _AMHomeUIInstall"
                ):
                    packager.package(
                        source_path,
                        output_path,
                        cloud_path,
                        home_ui_path,
                        button_path,
                        categories,
                    )
            self.assertFalse(output_path.exists())


if __name__ == "__main__":
    unittest.main()
