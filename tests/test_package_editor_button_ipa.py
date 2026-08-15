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


def make_home_ui_dylib(
    install_name="@rpath/AMHomeUI.dylib",
    section_name="__text",
    section_type=0,
    symbol_name="_AMHomeUIInstall",
    include_url=True,
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
        section_name.encode("ascii").ljust(16, b"\0"),
        b"__TEXT" + bytes(10),
        0x100000000 + section_offset,
        section_size,
        section_offset,
        2,
        0,
        0,
        section_type,
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
    commands = segment + section + identifier + symtab
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        inject_dylib.CPU_TYPE_ARM64,
        0,
        inject_dylib.MH_DYLIB,
        3,
        len(commands),
        0,
        0,
    )
    prefix = header + commands
    if len(prefix) > section_offset:
        raise AssertionError("synthetic Home UI load commands exceed section offset")

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


class EditorHomePackageTests(unittest.TestCase):
    def test_home_ui_verifier_requires_expected_install_name_and_url(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "AMHomeUI.dylib"

            binary = make_home_ui_dylib()
            path.write_bytes(binary)
            packager.verify_home_ui_binary(path, binary)

            binary = make_home_ui_dylib(install_name="@rpath/Wrong.dylib")
            path.write_bytes(binary)
            with self.assertRaisesRegex(RuntimeError, "install name"):
                packager.verify_home_ui_binary(path, binary)

            binary = make_home_ui_dylib(include_url=False)
            path.write_bytes(binary)
            with self.assertRaisesRegex(RuntimeError, "AutFeng home URL"):
                packager.verify_home_ui_binary(path, binary)

            binary = make_home_ui_dylib(symbol_name="_WrongInstall")
            path.write_bytes(binary)
            with self.assertRaisesRegex(RuntimeError, "export _AMHomeUIInstall"):
                packager.verify_home_ui_binary(path, binary)

    def test_home_ui_verifier_rejects_both_initializer_section_formats(self):
        cases = (
            ("__mod_init_func", inject_dylib.S_MOD_INIT_FUNC_POINTERS),
            ("__init_offsets", inject_dylib.S_INIT_FUNC_OFFSETS),
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "AMHomeUI.dylib"
            for section_name, section_type in cases:
                with self.subTest(section_name=section_name):
                    binary = make_home_ui_dylib(
                        section_name=section_name,
                        section_type=section_type,
                    )
                    path.write_bytes(binary)
                    with self.assertRaisesRegex(
                        RuntimeError, "must not contain initializer sections"
                    ):
                        packager.verify_home_ui_binary(path, binary)

    def test_main_validation_accepts_no_home_ui_load(self):
        info = inject_dylib.parse_macho_data(make_main())
        packager.ensure_no_home_ui_loads(info, "source main")

    def test_main_validation_rejects_every_home_ui_load_kind_and_path(self):
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
                with self.assertRaisesRegex(
                    RuntimeError, "must not contain an AMHomeUI load command"
                ):
                    packager.ensure_no_home_ui_loads(info, "source main")

    def test_cloud_must_strongly_link_the_single_home_ui_runtime(self):
        expected = {
            "command": "LC_LOAD_DYLIB",
            "name": "@rpath/AMHomeUI.dylib",
        }
        packager.ensure_cloud_home_ui_dependency(
            {"dylib_load_commands": [expected], "external_defined_symbols": []},
            "Cloud dylib",
        )
        invalid_cases = (
            [],
            [{"command": "LC_LOAD_WEAK_DYLIB", "name": expected["name"]}],
            [{"command": "LC_LOAD_DYLIB", "name": "@rpath/Wrong.dylib"}],
            [expected, expected],
        )
        for commands in invalid_cases:
            with self.subTest(commands=commands), self.assertRaisesRegex(
                RuntimeError, "must strongly link"
            ):
                packager.ensure_cloud_home_ui_dependency(
                    {"dylib_load_commands": commands}, "Cloud dylib"
                )
        with self.assertRaisesRegex(RuntimeError, "must not embed"):
            packager.ensure_cloud_home_ui_dependency(
                {
                    "dylib_load_commands": [expected],
                    "external_defined_symbols": ["_AMHomeUIInstall"],
                },
                "Cloud dylib",
            )

    def test_packager_has_no_main_injection_path(self):
        self.assertNotIn("insert_load_dylib", PACKAGER_SOURCE)
        self.assertNotIn("LC_LOAD_WEAK_DYLIB", PACKAGER_SOURCE)
        self.assertNotIn("patch_main_with_home_ui", PACKAGER_SOURCE)
        self.assertIn('if output_main != source_main:', PACKAGER_SOURCE)

    def test_new_home_ui_zip_member_is_executable(self):
        info = packager.new_zip_info(packager.HOME_UI_PATH, executable=True)
        self.assertEqual((info.external_attr >> 16) & 0xFFFF, 0o100755)

    def test_package_preserves_main_and_adds_runtime_home_ui(self):
        main = make_main()
        cloud = b"cloud-dylib"
        home_ui = b"home-ui-dylib"
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
                mock.patch.object(packager, "verify_cloud_home_ui_dependency"),
                mock.patch.object(packager, "verify_home_ui_binary"),
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
                self.assertEqual(output.read(packager.MAIN_PATH), main)
                self.assertEqual(output.read(packager.CLOUD_PATH), cloud)
                self.assertEqual(output.read(packager.HOME_UI_PATH), home_ui)
                self.assertEqual(
                    output.read(
                        packager.category_path(
                            "ic_category_thumbnail_other.png"
                        )
                    ),
                    b"category:ic_category_thumbnail_other.png",
                )
                home_info = output.getinfo(packager.HOME_UI_PATH)
                self.assertEqual(
                    (home_info.external_attr >> 16) & 0xFFFF,
                    0o100755,
                )
                info = inject_dylib.parse_macho_data(
                    output.read(packager.MAIN_PATH)
                )
                packager.ensure_no_home_ui_loads(info, "output main")


if __name__ == "__main__":
    unittest.main()
