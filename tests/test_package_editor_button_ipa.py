import struct
import tempfile
import unittest
from pathlib import Path

import inject_dylib
import package_editor_button_ipa as packager


class EditorHomePackageTests(unittest.TestCase):
    def test_home_ui_verifier_requires_expected_install_name_and_url(self):
        binary = b"prefixhttps://amhome.meowcr.cn/homesuffix"
        original = inject_dylib.verify_dylib_architecture
        try:
            inject_dylib.verify_dylib_architecture = lambda _: {
                "id_dylibs": ["@rpath/AMHomeUI.dylib"]
            }
            packager.verify_home_ui_binary("AMHomeUI.dylib", binary)

            inject_dylib.verify_dylib_architecture = lambda _: {
                "id_dylibs": ["@rpath/Wrong.dylib"]
            }
            with self.assertRaisesRegex(RuntimeError, "install name"):
                packager.verify_home_ui_binary("AMHomeUI.dylib", binary)

            inject_dylib.verify_dylib_architecture = lambda _: {
                "id_dylibs": ["@rpath/AMHomeUI.dylib"]
            }
            with self.assertRaisesRegex(RuntimeError, "AutFeng home URL"):
                packager.verify_home_ui_binary("AMHomeUI.dylib", b"wrong")
        finally:
            inject_dylib.verify_dylib_architecture = original

    def test_patch_main_adds_one_home_ui_load_and_preserves_payload(self):
        command_end = 32 + 152
        first_section_offset = 0x1000
        section_payload = b"section-payload"
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
        header = struct.pack(
            "<IIIIIIII",
            0xFEEDFACF,
            inject_dylib.CPU_TYPE_ARM64,
            0,
            inject_dylib.MH_EXECUTE,
            1,
            len(segment + section),
            0,
            0,
        )
        main = header + segment + section + bytes(first_section_offset - command_end)
        main += section_payload

        patched = packager.patch_main_with_home_ui(main)
        info = inject_dylib.parse_macho_data(patched)

        self.assertEqual(info["load_dylibs"], [packager.HOME_UI_LOAD])
        self.assertEqual(patched[first_section_offset:], section_payload)

    def test_patch_main_is_not_reapplied_to_an_existing_load(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            main_path = Path(temporary_directory) / "AlightMotion"
            home_ui_path = Path(temporary_directory) / "AMHomeUI.dylib"
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
                0x100001000,
                16,
                0x1000,
                2,
                0,
                0,
                0,
                0,
                0,
                0,
            )
            header = struct.pack(
                "<IIIIIIII",
                0xFEEDFACF,
                inject_dylib.CPU_TYPE_ARM64,
                0,
                inject_dylib.MH_EXECUTE,
                1,
                len(segment + section),
                0,
                0,
            )
            main_path.write_bytes(
                header + segment + section + bytes(0x1000 - 184) + bytes(16)
            )
            home_ui_path.write_bytes(b"")
            inject_dylib.insert_load_dylib(str(main_path), str(home_ui_path))
            already_patched = main_path.read_bytes()

        info = inject_dylib.parse_macho_data(already_patched)
        self.assertEqual(info["load_dylibs"].count(packager.HOME_UI_LOAD), 1)


if __name__ == "__main__":
    unittest.main()
