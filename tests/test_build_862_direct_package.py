import hashlib
import plistlib
import struct
import unittest
from unittest import mock

import build_862_direct_package as direct


class DirectCloud862Tests(unittest.TestCase):
    def fixture_cloud(self, fallback_code=None, option_code=None):
        functions = direct.EXPECTED_CLOUD_CONTRACT_FUNCTIONS
        fallback_name = "_AMProjV44ReleaseNativeActivityFallbackEnabled"
        option_name = "_AMProjV44IsDirectProjectPackageOption"
        fallback_code = fallback_code or functions[fallback_name]
        option_code = option_code or functions[option_name]
        text = fallback_code + option_code
        text_offset = 32 + 152 + 24
        text_address = 0x100000000 + text_offset
        strings = b"\0" + fallback_name.encode() + b"\0" + option_name.encode() + b"\0"
        fallback_string = 1
        option_string = fallback_string + len(fallback_name) + 1
        symbol_offset = text_offset + len(text)
        string_offset = symbol_offset + 32
        segment = struct.pack(
            "<II16sQQQQIIII",
            direct.LC_SEGMENT_64,
            152,
            b"__TEXT" + bytes(10),
            0x100000000,
            string_offset + len(strings),
            0,
            string_offset + len(strings),
            7,
            5,
            1,
            0,
        )
        section = struct.pack(
            "<16s16sQQIIIIIIII",
            b"__text" + bytes(10),
            b"__TEXT" + bytes(10),
            text_address,
            len(text),
            text_offset,
            2,
            0,
            0,
            0,
            0,
            0,
            0,
        )
        symtab = struct.pack(
            "<IIIIII",
            direct.LC_SYMTAB,
            24,
            symbol_offset,
            2,
            string_offset,
            len(strings),
        )
        header = struct.pack(
            "<IIIIIIII",
            0xFEEDFACF,
            0x0100000C,
            0,
            0x6,
            2,
            len(segment + section + symtab),
            0,
            0,
        )
        symbols = b"".join(
            (
                struct.pack("<IBBHQ", fallback_string, 0x0F, 1, 0, text_address),
                struct.pack(
                    "<IBBHQ",
                    option_string,
                    0x0F,
                    1,
                    0,
                    text_address + len(fallback_code),
                ),
            )
        )
        return (
            header
            + segment
            + section
            + symtab
            + text
            + symbols
            + strings
            + direct.EXPECTED_CLOUD_RUNTIME_MARKER
            + b"\0"
            + direct.EXPECTED_CLOUD_STABILITY_MARKER
        )

    def dylib_command(self, command, name, size):
        encoded = name.encode("utf-8") + b"\0"
        if 24 + len(encoded) > size:
            raise ValueError("fixture command is too small")
        return (
            struct.pack("<IIIIII", command, size, 24, 0, 0, 0)
            + encoded
            + bytes(size - 24 - len(encoded))
        )

    def fixture_main(self):
        commands = [
            struct.pack(
                "<II16s",
                direct.handoff.LC_UUID,
                24,
                direct.handoff.EXPECTED_MAIN_UUID,
            ),
            self.dylib_command(
                direct.handoff.LC_LOAD_WEAK_DYLIB,
                direct.handoff.AMENHANCER_LOAD,
                72,
            ),
            self.dylib_command(
                direct.handoff.LC_LOAD_DYLIB,
                direct.handoff.LOADCONTROL_LOAD,
                80,
            ),
        ]
        signature_offset = 32 + sum(map(len, commands)) + 16
        commands.append(
            struct.pack(
                "<IIII",
                direct.handoff.LC_CODE_SIGNATURE,
                16,
                signature_offset,
                256,
            )
        )
        payload = b"".join(commands)
        header = struct.pack(
            "<IIIIIIII",
            0xFEEDFACF,
            0x0100000C,
            0,
            2,
            len(commands),
            len(payload),
            0,
            0,
        )
        return header + payload + bytes(256)

    def fixture_info(self):
        return plistlib.dumps(
            {
                "CFBundleDisplayName": "old",
                "CFBundleName": "Alight Motion",
                "CFBundleExecutable": "AlightMotion",
                "CFBundleIdentifier": "com.alightcreative.motion",
                "CFBundleShortVersionString": "6.2.55",
                "CFBundleVersion": "862",
                "LSSupportsOpeningDocumentsInPlace": True,
                "UISupportsDocumentBrowser": False,
                "CFBundleDocumentTypes": direct.stable.EXPECTED_DOCUMENT_TYPES,
                "UTExportedTypeDeclarations": direct.stable.EXPECTED_EXPORTED_TYPES,
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=False,
        )

    def test_main_patch_replaces_only_loader_path_and_keeps_strong_load(self):
        source = self.fixture_main()
        with mock.patch.multiple(
            direct,
            EXPECTED_INPUT_MAIN_SHA256=hashlib.sha256(source).hexdigest(),
            EXPECTED_OUTPUT_MAIN_SHA256=mock.DEFAULT,
        ) as old:
            target = direct.verify_input_main(source)
            raw = bytearray(source)
            replacement = direct.handoff.CLOUD_LOAD.encode() + b"\0"
            start = target["offset"] + target["name_offset"]
            end = target["offset"] + target["size"]
            raw[start:end] = replacement + bytes(end - start - len(replacement))
            direct.EXPECTED_OUTPUT_MAIN_SHA256 = hashlib.sha256(raw).hexdigest()
            try:
                result = direct.patch_main_direct_cloud(source)
            finally:
                direct.EXPECTED_OUTPUT_MAIN_SHA256 = old[
                    "EXPECTED_OUTPUT_MAIN_SHA256"
                ]

        self.assertEqual(result, bytes(raw))
        cloud = direct._verify_output_main_structure(result)
        self.assertEqual(cloud["command"], direct.handoff.LC_LOAD_DYLIB)

    def test_output_info_changes_identity_and_restores_copy_in_contract(self):
        source = plistlib.loads(self.fixture_info())
        result = plistlib.loads(direct.prepare_output_info(self.fixture_info()))
        self.assertEqual(result["CFBundleDisplayName"], "猫鹤AM")
        self.assertEqual(result["CFBundleName"], "猫鹤AM")
        self.assertEqual(result["CFBundleIdentifier"], "com.ayakameow.am")
        self.assertIs(result["LSSupportsOpeningDocumentsInPlace"], False)
        for key in (
            "CFBundleDocumentTypes",
            "UTExportedTypeDeclarations",
            "UISupportsDocumentBrowser",
        ):
            self.assertEqual(result[key], source[key])

    def test_output_structure_rejects_loadcontrol_or_weak_cloud(self):
        source = self.fixture_main()
        with self.assertRaisesRegex(RuntimeError, "must strongly load"):
            direct._verify_output_main_structure(source)

    def test_cloud_runtime_marker_rejects_stale_v43(self):
        with self.assertRaisesRegex(RuntimeError, "source Cloud is v43"):
            direct.verify_cloud_runtime_version(
                b"[AMProjExport] ===== Loading v43-cloud ====="
            )

    def test_cloud_runtime_marker_accepts_v44(self):
        self.assertTrue(
            direct.verify_cloud_runtime_version(
                b"prefix [AMProjExport] ===== Loading v44-cloud ===== suffix"
            )
        )

    def test_cloud_stability_contract_rejects_marker_only_v44(self):
        marker_only = (
            direct.EXPECTED_CLOUD_RUNTIME_MARKER
            + b"\0"
            + direct.EXPECTED_CLOUD_STABILITY_MARKER
        )
        with self.assertRaisesRegex(RuntimeError, "thin arm64 MH_DYLIB"):
            direct.prepare_cloud(marker_only)

    def test_cloud_stability_contract_rejects_old_code_with_both_markers(self):
        old_fallback = bytes.fromhex("20008052c0035fd6")
        cloud = self.fixture_cloud(fallback_code=old_fallback)
        with self.assertRaisesRegex(RuntimeError, "unexpected arm64 semantics"):
            direct.verify_cloud_stability_contract(cloud)

    def test_cloud_stability_contract_accepts_current_cloud(self):
        cloud = self.fixture_cloud()
        self.assertTrue(direct.verify_cloud_stability_contract(cloud))


if __name__ == "__main__":
    unittest.main()
