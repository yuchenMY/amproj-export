import hashlib
import plistlib
import struct
import unittest
from unittest import mock

import build_862_direct_package as direct


class DirectCloud862Tests(unittest.TestCase):
    def fixture_amenhancer(self):
        marker_offset = direct.AMENHANCER_MARKER_FUNCTION_OFFSET
        size = marker_offset + len(direct.AMENHANCER_MARKER_FUNCTION_PREIMAGE) + 64
        source = bytearray(b"\xa5" * size)
        context_offset = 0x100
        context = direct.AMENHANCER_STATUS_LABEL_CONTEXT
        source[context_offset : context_offset + len(context)] = context
        source[
            marker_offset : marker_offset
            + len(direct.AMENHANCER_MARKER_FUNCTION_PREIMAGE)
        ] = direct.AMENHANCER_MARKER_FUNCTION_PREIMAGE
        return bytes(source), context_offset

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

    def rpath_command(self, path):
        encoded = path.encode("utf-8") + b"\0"
        size = (12 + len(encoded) + 7) & ~7
        return (
            struct.pack("<III", direct.LC_RPATH, size, 12)
            + encoded
            + bytes(size - 12 - len(encoded))
        )

    def fixture_main(
        self,
        loader_command=None,
        loader_command_size=80,
        include_frameworks_rpath=False,
    ):
        loader_command = loader_command or direct.handoff.LC_LOAD_DYLIB
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
                loader_command,
                direct.handoff.LOADCONTROL_LOAD,
                loader_command_size,
            ),
        ]
        if include_frameworks_rpath:
            commands.append(self.rpath_command(direct.FRAMEWORKS_RPATH))
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
        self.assertEqual(cloud["name"], direct.handoff.CLOUD_LOAD)

    def test_main_patch_upgrades_compact_weak_loader_to_lcsign_visible_cloud(self):
        source = self.fixture_main(
            loader_command=direct.handoff.LC_LOAD_WEAK_DYLIB,
            loader_command_size=72,
        )
        target = direct.verify_input_main(source)
        self.assertEqual(target["command"], direct.handoff.LC_LOAD_WEAK_DYLIB)

        result = direct.patch_main_direct_cloud(source)
        cloud = direct._verify_output_main_structure(result)

        self.assertEqual(cloud["command"], direct.handoff.LC_LOAD_DYLIB)
        self.assertEqual(cloud["name"], direct.CLOUD_LOAD_LCSIGN)
        self.assertEqual(
            direct._cloud_member_path(cloud["name"]), direct.CLOUD_PATH_LCSIGN
        )
        self.assertEqual(
            direct.CLOUD_PATH_LCSIGN,
            "Payload/AlightMotion.app/Frameworks/AMProjExport.dylib",
        )
        command_start = target["offset"]
        name_start = command_start + target["name_offset"]
        name_end = command_start + target["size"]
        changed = {
            index
            for index, (before, after) in enumerate(zip(source, result))
            if before != after
        }
        allowed = set(range(command_start, command_start + 4)) | set(
            range(name_start, name_end)
        )
        self.assertTrue(changed)
        self.assertLessEqual(changed, allowed)

    def test_compact_rpath_cloud_rejects_main_without_frameworks_rpath(self):
        source = self.fixture_main(
            loader_command=direct.handoff.LC_LOAD_WEAK_DYLIB,
            loader_command_size=72,
        )
        _uuids, _enhancer, _cloud, loaders = direct._custom_loads(
            source, "fixture main"
        )
        target = loaders[0]
        result = bytearray(source)
        struct.pack_into(
            "<I", result, target["offset"], direct.handoff.LC_LOAD_DYLIB
        )
        replacement = direct.CLOUD_LOAD_COMPACT.encode("utf-8") + b"\0"
        name_start = target["offset"] + target["name_offset"]
        name_end = target["offset"] + target["size"]
        result[name_start:name_end] = replacement + bytes(
            name_end - name_start - len(replacement)
        )
        with self.assertRaisesRegex(RuntimeError, "compact Cloud load requires"):
            direct._verify_output_main_structure(bytes(result))

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

    def test_amenhancer_patch_disables_the_complete_v59_marker_view(self):
        source, context_offset = self.fixture_amenhancer()

        result = direct.prepare_amenhancer(source)

        label_start = context_offset + len(b"nil\0")
        marker_start = direct.AMENHANCER_MARKER_FUNCTION_OFFSET
        changed = {
            index
            for index, (before, after) in enumerate(zip(source, result))
            if before != after
        }
        self.assertTrue(changed)
        allowed = set(
            range(label_start, label_start + len(direct.AMENHANCER_STATUS_LABEL))
        )
        allowed.update(range(marker_start, marker_start + len(direct.ARM64_RET)))
        self.assertLessEqual(changed, allowed)
        self.assertNotIn(direct.AMENHANCER_STATUS_LABEL, result)
        self.assertIn(b"[AmEnhancer] marker added\n", result)
        self.assertEqual(
            result[marker_start : marker_start + len(direct.ARM64_RET)],
            direct.ARM64_RET,
        )

    def test_amenhancer_patch_rejects_unknown_or_duplicate_preimage(self):
        with self.assertRaisesRegex(RuntimeError, "context changed"):
            direct.prepare_amenhancer(b"prefix AM v59 OK suffix")
        source, _context_offset = self.fixture_amenhancer()
        with self.assertRaisesRegex(RuntimeError, "context changed"):
            direct.prepare_amenhancer(
                source + direct.AMENHANCER_STATUS_LABEL_CONTEXT
            )
        marker_offset = direct.AMENHANCER_MARKER_FUNCTION_OFFSET
        changed_marker = bytearray(source)
        changed_marker[marker_offset] ^= 0x01
        with self.assertRaisesRegex(RuntimeError, "marker function changed"):
            direct.prepare_amenhancer(bytes(changed_marker))
        with self.assertRaisesRegex(RuntimeError, "marker function is not unique"):
            direct.prepare_amenhancer(
                source + direct.AMENHANCER_MARKER_FUNCTION_PREIMAGE
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
