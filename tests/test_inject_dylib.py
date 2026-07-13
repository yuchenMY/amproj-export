import plistlib
import shutil
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import inject_dylib


def make_macho(path, section_offset=0x400):
    segment_size = 72 + 80
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        0x0100000C,
        0,
        2,
        1,
        segment_size,
        0,
        0,
    )
    segment = struct.pack(
        "<II16sQQQQIIII",
        0x19,
        segment_size,
        b"__TEXT".ljust(16, b"\0"),
        0,
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
        b"__text".ljust(16, b"\0"),
        b"__TEXT".ljust(16, b"\0"),
        0,
        16,
        section_offset,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    data = bytearray(header + segment + section)
    data.extend(b"\0" * (section_offset - len(data)))
    data.extend(b"PAYLOAD-MUST-NOT-MOVE")
    path.write_bytes(data)
    return bytes(data)


class MachOTests(unittest.TestCase):
    def test_insert_uses_padding_without_moving_payload(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "App"
            dylib = Path(temp_dir) / "AMProjExportDebug.dylib"
            original = make_macho(binary)
            dylib.write_bytes(b"dylib")

            self.assertTrue(inject_dylib.insert_load_dylib(binary, dylib))
            patched = binary.read_bytes()

            self.assertEqual(len(patched), len(original))
            self.assertEqual(patched[0x400:], original[0x400:])
            info = inject_dylib.parse_macho(binary)
            self.assertEqual(info["ncmds"], 2)
            self.assertGreater(info["sizeofcmds"], 152)
            self.assertIn(
                b"@executable_path/Frameworks/AMProjExportDebug.dylib\0",
                patched,
            )

    def test_insert_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "App"
            dylib = Path(temp_dir) / "AMProjExport.dylib"
            make_macho(binary)
            dylib.write_bytes(b"dylib")
            inject_dylib.insert_load_dylib(binary, dylib)

            self.assertFalse(inject_dylib.insert_load_dylib(binary, dylib))
            self.assertEqual(inject_dylib.parse_macho(binary)["ncmds"], 2)


class PlistTests(unittest.TestCase):
    def test_network_keys_are_patched_when_uti_already_exists(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            plist = {
                "CFBundleDocumentTypes": [
                    {"LSItemContentTypes": [inject_dylib.AMPROJ_UTI]}
                ],
                "UTExportedTypeDeclarations": [
                    {"UTTypeIdentifier": inject_dylib.AMPROJ_UTI}
                ],
                "NSAppTransportSecurity": {
                    "NSAllowsArbitraryLoads": "YES"
                },
            }
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump(plist, file)

            self.assertTrue(
                inject_dylib.patch_info_plist(app, enable_debug_network=True)
            )
            with (app / "Info.plist").open("rb") as file:
                result = plistlib.load(file)

            self.assertIn("NSLocalNetworkUsageDescription", result)
            ats = result["NSAppTransportSecurity"]
            self.assertIs(ats["NSAllowsLocalNetworking"], True)
            self.assertIs(ats["NSAllowsArbitraryLoads"], True)
            self.assertEqual(len(result["CFBundleDocumentTypes"]), 1)
            self.assertEqual(len(result["UTExportedTypeDeclarations"]), 1)


class AddressSelectionTests(unittest.TestCase):
    def test_wlan_wins_and_radmin_vpn_is_excluded(self):
        records = [
            {
                "InterfaceAlias": "Radmin VPN",
                "InterfaceDescription": "Radmin VPN",
                "IPAddress": "192.168.1.8",
            },
            {
                "InterfaceAlias": "Ethernet",
                "InterfaceDescription": "PCIe adapter",
                "IPAddress": "10.0.0.2",
            },
            {
                "InterfaceAlias": "Wi-Fi",
                "InterfaceDescription": "802.11ax adapter",
                "IPAddress": "192.168.1.5",
            },
        ]
        self.assertEqual(
            inject_dylib.choose_server_ip(adapter_records=records),
            "192.168.1.5",
        )

    def test_explicit_address_overrides_adapter_selection(self):
        self.assertEqual(
            inject_dylib.choose_server_ip("203.0.113.10", []),
            "203.0.113.10",
        )


class ConfigTests(unittest.TestCase):
    def test_generates_debug_config_with_expected_schema(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings = inject_dylib.DebugSettings(
                enabled=True,
                server_ip="192.168.1.5",
                server_port=8765,
                token="test-token-123456",
                mode="placeholder",
            )
            config = inject_dylib.install_debug_config(temp_dir, settings)

            self.assertEqual(
                config,
                {
                    "BaseURL": "http://192.168.1.5:8765",
                    "Token": "test-token-123456",
                    "ProtocolVersion": 1,
                    "DefaultMode": "placeholder",
                },
            )
            with (Path(temp_dir) / inject_dylib.DEBUG_CONFIG_NAME).open(
                "rb"
            ) as file:
                self.assertEqual(plistlib.load(file), config)

    def test_copies_existing_debug_config_unchanged(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = root / "App"
            app.mkdir()
            source = root / "source.plist"
            expected = {"BaseURL": "http://10.0.0.2:9000", "Token": "x"}
            with source.open("wb") as file:
                plistlib.dump(expected, file, fmt=plistlib.FMT_XML)
            original = source.read_bytes()

            settings = inject_dylib.DebugSettings(
                enabled=True, config_path=source
            )
            self.assertEqual(
                inject_dylib.install_debug_config(app, settings), expected
            )
            self.assertEqual(
                (app / inject_dylib.DEBUG_CONFIG_NAME).read_bytes(), original
            )


class InjectionTests(unittest.TestCase):
    def test_fake_ipa_debug_injection_end_to_end(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            app = source / "Payload" / "Fixture.app"
            app.mkdir(parents=True)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "Fixture",
                        "CFBundleIdentifier": "com.example.fixture",
                    },
                    file,
                )
            make_macho(app / "Fixture")
            (app / "_CodeSignature").mkdir()
            (app / "_CodeSignature" / "CodeResources").write_bytes(b"old")

            ipa = root / "input.ipa"
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
                for path in source.rglob("*"):
                    archive.write(path, path.relative_to(source))
            dylib = root / "AMProjExportDebug.dylib"
            dylib.write_bytes(b"debug-dylib")
            output = root / "output.ipa"
            settings = inject_dylib.DebugSettings(
                enabled=True,
                server_ip="192.168.1.5",
                token="fixture-token-1234",
            )

            with mock.patch.object(inject_dylib, "_try_resign"):
                inject_dylib.inject_ipa(ipa, dylib, output, settings)

            extracted = root / "result"
            shutil.unpack_archive(output, extracted, "zip")
            result_app = extracted / "Payload" / "Fixture.app"
            self.assertEqual(
                (result_app / "Frameworks" / dylib.name).read_bytes(),
                b"debug-dylib",
            )
            self.assertFalse((result_app / "_CodeSignature").exists())
            with (result_app / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info["CFBundleIdentifier"], "com.example.fixture")
            self.assertIs(
                info["NSAppTransportSecurity"]["NSAllowsLocalNetworking"],
                True,
            )
            with (result_app / inject_dylib.DEBUG_CONFIG_NAME).open(
                "rb"
            ) as file:
                config = plistlib.load(file)
            self.assertEqual(config["DefaultMode"], "observe")


class ArgumentTests(unittest.TestCase):
    def test_legacy_positional_arguments_remain_compatible(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(["input.ipa", "lib.dylib", "output.ipa"])
        settings = inject_dylib._debug_settings_from_args(args, parser)
        self.assertEqual(args.output, "output.ipa")
        self.assertFalse(settings.enabled)

    def test_debug_dylib_enables_generated_config(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(["input.ipa", "AMProjExportDebug.dylib"])
        settings = inject_dylib._debug_settings_from_args(args, parser)
        self.assertTrue(settings.enabled)
        self.assertEqual(settings.mode, "observe")
        self.assertEqual(settings.server_port, 8765)

    def test_debug_token_must_match_backend_minimum_length(self):
        parser = inject_dylib.build_argument_parser()
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            parser.parse_args(
                [
                    "input.ipa",
                    "AMProjExportDebug.dylib",
                    "--debug-token",
                    "short",
                ]
            )


if __name__ == "__main__":
    unittest.main()
