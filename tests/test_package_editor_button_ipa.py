import struct
import unittest
from pathlib import Path
from unittest import mock

import inject_dylib
import package_editor_button_ipa as packager


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


class EditorHomePackageTests(unittest.TestCase):
    def test_home_ui_verifier_requires_expected_install_name_and_url(self):
        binary = b"prefixhttps://amhome.meowcr.cn/homesuffix"
        with mock.patch.object(
            inject_dylib,
            "verify_dylib_architecture",
            return_value={
                "id_dylibs": ["@rpath/AMHomeUI.dylib"]
            },
        ) as verify:
            packager.verify_home_ui_binary("AMHomeUI.dylib", binary)

            verify.return_value = {
                "id_dylibs": ["@rpath/Wrong.dylib"]
            }
            with self.assertRaisesRegex(RuntimeError, "install name"):
                packager.verify_home_ui_binary("AMHomeUI.dylib", binary)

            verify.return_value = {
                "id_dylibs": ["@rpath/AMHomeUI.dylib"]
            }
            with self.assertRaisesRegex(RuntimeError, "AutFeng home URL"):
                packager.verify_home_ui_binary("AMHomeUI.dylib", b"wrong")

    def test_patch_main_adds_one_home_ui_load_and_preserves_payload(self):
        first_section_offset = 0x1000
        section_payload = b"section-payload"
        main = make_main(section_payload=section_payload)
        source_info = inject_dylib.parse_macho_data(main)

        patched = packager.patch_main_with_home_ui(main)
        info = inject_dylib.parse_macho_data(patched)
        command = next(
            command
            for command in info["dylib_load_commands"]
            if command["name"] == packager.HOME_UI_LOAD
        )

        self.assertEqual(len(patched), len(main))
        self.assertEqual(info["ncmds"], source_info["ncmds"] + 1)
        self.assertEqual(
            info["sizeofcmds"],
            source_info["sizeofcmds"]
            + packager.dylib_command_size(packager.HOME_UI_LOAD),
        )
        self.assertEqual(
            command["cmdsize"], packager.dylib_command_size(packager.HOME_UI_LOAD)
        )
        self.assertEqual(info["load_dylibs"], [packager.HOME_UI_LOAD])
        self.assertEqual(patched[first_section_offset:], section_payload)

    def test_source_validation_accepts_only_one_strong_home_ui_load(self):
        strong = make_dylib_command(
            inject_dylib.LC_LOAD_DYLIB, packager.HOME_UI_LOAD
        )
        empty_info = inject_dylib.parse_macho_data(make_main())
        strong_info = inject_dylib.parse_macho_data(make_main((strong,)))

        self.assertFalse(
            packager.validate_home_ui_loads(
                empty_info, "source main", allow_missing=True
            )
        )
        self.assertTrue(
            packager.validate_home_ui_loads(
                strong_info, "source main", allow_missing=True
            )
        )

    def test_source_validation_rejects_non_strong_and_duplicate_loads(self):
        conflicting_commands = (
            inject_dylib.LC_LOAD_WEAK_DYLIB,
            inject_dylib.LC_REEXPORT_DYLIB,
            inject_dylib.LC_LAZY_LOAD_DYLIB,
            inject_dylib.LC_LOAD_UPWARD_DYLIB,
        )
        for command in conflicting_commands:
            with self.subTest(command=command):
                load = make_dylib_command(command, packager.HOME_UI_LOAD)
                info = inject_dylib.parse_macho_data(make_main((load,)))
                with self.assertRaisesRegex(RuntimeError, "exactly one strong"):
                    packager.validate_home_ui_loads(
                        info, "source main", allow_missing=True
                    )

        strong = make_dylib_command(
            inject_dylib.LC_LOAD_DYLIB, packager.HOME_UI_LOAD
        )
        duplicate_info = inject_dylib.parse_macho_data(make_main((strong, strong)))
        with self.assertRaisesRegex(RuntimeError, "exactly one strong"):
            packager.validate_home_ui_loads(
                duplicate_info, "source main", allow_missing=True
            )

    def test_patch_main_rejects_an_existing_weak_home_ui_load(self):
        weak = make_dylib_command(
            inject_dylib.LC_LOAD_WEAK_DYLIB, packager.HOME_UI_LOAD
        )

        with self.assertRaisesRegex(RuntimeError, "LC_LOAD_WEAK_DYLIB"):
            packager.patch_main_with_home_ui(make_main((weak,)))

    def test_patch_main_rejects_file_length_changes(self):
        real_insert = inject_dylib.insert_load_dylib

        def insert_and_extend(main_path, dylib_path):
            result = real_insert(main_path, dylib_path)
            path = Path(main_path)
            path.write_bytes(path.read_bytes() + b"\0")
            return result

        with mock.patch.object(
            inject_dylib, "insert_load_dylib", side_effect=insert_and_extend
        ), self.assertRaisesRegex(RuntimeError, "executable length"):
            packager.patch_main_with_home_ui(make_main())

    def test_patch_main_rejects_more_than_one_added_command(self):
        real_insert = inject_dylib.insert_load_dylib

        def insert_with_extra_command(main_path, dylib_path):
            result = real_insert(main_path, dylib_path)
            path = Path(main_path)
            data = bytearray(path.read_bytes())
            info = inject_dylib.parse_macho_data(data)
            command = make_dylib_command(
                inject_dylib.LC_LOAD_DYLIB, "@rpath/Unexpected.dylib"
            )
            start = info["load_commands_end"]
            data[start : start + len(command)] = command
            struct.pack_into("<I", data, 16, info["ncmds"] + 1)
            struct.pack_into(
                "<I", data, 20, info["sizeofcmds"] + len(command)
            )
            path.write_bytes(data)
            return result

        with mock.patch.object(
            inject_dylib,
            "insert_load_dylib",
            side_effect=insert_with_extra_command,
        ), self.assertRaisesRegex(RuntimeError, "exactly one load command"):
            packager.patch_main_with_home_ui(make_main())

    def test_patch_main_rejects_an_unexpected_home_ui_command_size(self):
        real_insert = inject_dylib.insert_load_dylib

        def insert_with_oversized_command(main_path, dylib_path):
            result = real_insert(main_path, dylib_path)
            path = Path(main_path)
            data = bytearray(path.read_bytes())
            info = inject_dylib.parse_macho_data(data)
            command = next(
                command
                for command in info["dylib_load_commands"]
                if command["name"] == packager.HOME_UI_LOAD
            )
            struct.pack_into(
                "<I", data, command["offset"] + 4, command["cmdsize"] + 8
            )
            struct.pack_into("<I", data, 20, info["sizeofcmds"] + 8)
            path.write_bytes(data)
            return result

        with mock.patch.object(
            inject_dylib,
            "insert_load_dylib",
            side_effect=insert_with_oversized_command,
        ), self.assertRaisesRegex(RuntimeError, "unexpected size"):
            packager.patch_main_with_home_ui(make_main())


if __name__ == "__main__":
    unittest.main()
