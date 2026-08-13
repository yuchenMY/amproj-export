import plistlib
import shutil
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import inject_dylib


def make_macho(
    path,
    section_offset=0x400,
    filetype=2,
    cputype=inject_dylib.CPU_TYPE_ARM64,
    uuid=None,
    install_name=None,
    dylib_loads=(),
):
    segment_size = 72 + 80
    uuid_command = b""
    if uuid is not None:
        uuid_bytes = bytes.fromhex(uuid.replace("-", ""))
        if len(uuid_bytes) != 16:
            raise ValueError("test Mach-O UUID must contain 16 bytes")
        uuid_command = struct.pack("<II", inject_dylib.LC_UUID, 24) + uuid_bytes
    id_command = b""
    if install_name is not None:
        name = install_name.encode("utf-8") + b"\0"
        command_size = (24 + len(name) + 7) & ~7
        id_command = struct.pack(
            "<IIIIII",
            inject_dylib.LC_ID_DYLIB,
            command_size,
            24,
            2,
            0x10000,
            0x10000,
        ) + name.ljust(command_size - 24, b"\0")
    load_commands = b""
    for command, dylib_name in dylib_loads:
        name = dylib_name.encode("utf-8") + b"\0"
        command_size = (24 + len(name) + 7) & ~7
        load_commands += struct.pack(
            "<IIIIII",
            command,
            command_size,
            24,
            2,
            0x10000,
            0x10000,
        ) + name.ljust(command_size - 24, b"\0")
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        cputype,
        0,
        filetype,
        1 + bool(uuid_command) + bool(id_command) + len(dylib_loads),
        segment_size + len(uuid_command) + len(id_command) + len(load_commands),
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
    data = bytearray(
        header + segment + section + uuid_command + id_command + load_commands
    )
    data.extend(b"\0" * (section_offset - len(data)))
    data.extend(b"PAYLOAD-MUST-NOT-MOVE")
    path.write_bytes(data)
    return bytes(data)


def make_share_extension(
    root,
    host_bundle_identifier="com.example.fixture",
    app_group_id="group.com.example.fixture.amprojshare",
    extension_point=inject_dylib.SHARE_EXTENSION_POINT,
    filetype=inject_dylib.MH_EXECUTE,
    cputype=inject_dylib.CPU_TYPE_ARM64,
):
    build = Path(root) / "share-build"
    appex = build / "FixtureShare.appex"
    appex.mkdir(parents=True)
    with (appex / "Info.plist").open("wb") as file:
        plistlib.dump(
            {
                "CFBundleExecutable": "FixtureShare",
                "CFBundleIdentifier": (
                    host_bundle_identifier
                    + inject_dylib.SHARE_EXTENSION_BUNDLE_SUFFIX
                ),
                "NSExtension": {
                    "NSExtensionPointIdentifier": extension_point,
                },
            },
            file,
        )
    make_macho(
        appex / "FixtureShare",
        filetype=filetype,
        cputype=cputype,
    )
    with (build / "FixtureShare.entitlements").open("wb") as file:
        plistlib.dump(
            {
                inject_dylib.APPLICATION_GROUPS_ENTITLEMENT: [app_group_id],
            },
            file,
        )
    return appex


def make_fake_ipa(
    root,
    bundle_identifier="com.example.fixture",
    wrapper=None,
):
    source = Path(root) / "source"
    archive_root = source / wrapper if wrapper else source
    app = archive_root / "Payload" / "Fixture.app"
    app.mkdir(parents=True)
    with (app / "Info.plist").open("wb") as file:
        plistlib.dump(
            {
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": bundle_identifier,
            },
            file,
        )
    make_macho(app / "Fixture")
    ipa = Path(root) / "input.ipa"
    with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in source.rglob("*"):
            archive.write(path, path.relative_to(source))
    return ipa, archive_root


class MachOTests(unittest.TestCase):
    def test_parse_exposes_all_dylib_load_command_kinds(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "App"
            loads = (
                (inject_dylib.LC_LOAD_DYLIB, "@rpath/Strong.dylib"),
                (inject_dylib.LC_LOAD_WEAK_DYLIB, "@rpath/Weak.dylib"),
                (inject_dylib.LC_REEXPORT_DYLIB, "@rpath/Reexport.dylib"),
                (inject_dylib.LC_LAZY_LOAD_DYLIB, "@rpath/Lazy.dylib"),
                (inject_dylib.LC_LOAD_UPWARD_DYLIB, "@rpath/Upward.dylib"),
            )
            make_macho(binary, dylib_loads=loads)

            info = inject_dylib.parse_macho(binary)

            self.assertEqual(info["load_dylibs"], ["@rpath/Strong.dylib"])
            self.assertEqual(
                info["all_load_dylibs"],
                [name for _, name in loads],
            )
            self.assertEqual(
                [command["cmd"] for command in info["dylib_load_commands"]],
                [command for command, _ in loads],
            )
            self.assertEqual(
                [command["command"] for command in info["dylib_load_commands"]],
                [
                    "LC_LOAD_DYLIB",
                    "LC_LOAD_WEAK_DYLIB",
                    "LC_REEXPORT_DYLIB",
                    "LC_LAZY_LOAD_DYLIB",
                    "LC_LOAD_UPWARD_DYLIB",
                ],
            )

    def test_parse_exposes_dylib_install_name(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "HomeUI.dylib"
            expected = "@rpath/AMHomeUI.dylib"
            make_macho(
                binary,
                filetype=inject_dylib.MH_DYLIB,
                install_name=expected,
            )

            self.assertEqual(
                inject_dylib.parse_macho(binary)["id_dylibs"], [expected]
            )

    def test_parse_exposes_normalized_uuid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "App"
            expected = "4b22d43f09fc3bde859b78a5d573a503"
            make_macho(binary, uuid=expected)

            self.assertEqual(inject_dylib.parse_macho(binary)["uuid"], expected)

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
            self.assertEqual(
                info["load_dylibs"],
                ["@executable_path/Frameworks/AMProjExportDebug.dylib"],
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

    def test_insert_rejects_an_existing_non_strong_load_for_same_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            binary = Path(temp_dir) / "App"
            dylib = Path(temp_dir) / "AMHomeUI.dylib"
            load_name = "@executable_path/Frameworks/AMHomeUI.dylib"
            make_macho(
                binary,
                dylib_loads=((inject_dylib.LC_LOAD_WEAK_DYLIB, load_name),),
            )
            dylib.write_bytes(b"dylib")
            original = binary.read_bytes()

            with self.assertRaisesRegex(RuntimeError, "Conflicting Mach-O loads"):
                inject_dylib.insert_load_dylib(binary, dylib)

            self.assertEqual(binary.read_bytes(), original)

    def test_dylib_architecture_requires_arm64_mh_dylib(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            valid = root / "valid.dylib"
            executable = root / "executable"
            wrong_arch = root / "wrong-arch.dylib"
            make_macho(valid, filetype=inject_dylib.MH_DYLIB)
            make_macho(executable)
            make_macho(
                wrong_arch,
                filetype=inject_dylib.MH_DYLIB,
                cputype=0x01000007,
            )

            self.assertEqual(
                inject_dylib.verify_dylib_architecture(valid)["filetype"],
                inject_dylib.MH_DYLIB,
            )
            with self.assertRaisesRegex(ValueError, "MH_DYLIB"):
                inject_dylib.verify_dylib_architecture(executable)
            with self.assertRaisesRegex(ValueError, "not arm64"):
                inject_dylib.verify_dylib_architecture(wrong_arch)


class PlistTests(unittest.TestCase):
    def test_bundle_version_is_only_changed_when_explicitly_requested(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleVersion": "737"}, file)

            self.assertTrue(inject_dylib.patch_info_plist(app))
            with (app / "Info.plist").open("rb") as file:
                self.assertEqual(plistlib.load(file)["CFBundleVersion"], "737")

            self.assertTrue(
                inject_dylib.patch_info_plist(app, bundle_version="738")
            )
            with (app / "Info.plist").open("rb") as file:
                self.assertEqual(plistlib.load(file)["CFBundleVersion"], "738")
            self.assertFalse(
                inject_dylib.patch_info_plist(app, bundle_version="738")
            )

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
            self.assertEqual(len(result["CFBundleDocumentTypes"]), 2)
            self.assertEqual(
                inject_dylib._amproj_document_type(result)["CFBundleTypeRole"],
                "Editor",
            )
            self.assertEqual(
                inject_dylib._amproj_document_type(result)["LSHandlerRank"],
                "Owner",
            )
            xml_document_type = inject_dylib._xml_document_type(result)
            self.assertEqual(xml_document_type["CFBundleTypeRole"], "Editor")
            self.assertEqual(xml_document_type["LSHandlerRank"], "Alternate")
            self.assertEqual(
                xml_document_type["LSItemContentTypes"],
                [inject_dylib.XML_UTI],
            )
            self.assertEqual(len(result["UTExportedTypeDeclarations"]), 1)
            self.assertNotIn(
                inject_dylib.XML_UTI,
                {
                    declaration.get("UTTypeIdentifier")
                    for declaration in result["UTExportedTypeDeclarations"]
                },
            )
            self.assertIn(
                "public.zip-archive",
                result["UTExportedTypeDeclarations"][0]["UTTypeConformsTo"],
            )
            self.assertIn(
                "amproj",
                result["UTExportedTypeDeclarations"][0]["UTTypeTagSpecification"]
                ["public.filename-extension"],
            )
            self.assertIs(result["LSSupportsOpeningDocumentsInPlace"], False)
            self.assertIs(result["UISupportsDocumentBrowser"], False)

    def test_document_access_flags_are_canonicalized_to_copy_in(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump(
                    {
                        "LSSupportsOpeningDocumentsInPlace": "YES",
                        "UISupportsDocumentBrowser": "YES",
                    },
                    file,
                )

            self.assertTrue(inject_dylib.patch_info_plist(app))
            with (app / "Info.plist").open("rb") as file:
                result = plistlib.load(file)
            self.assertIs(result["LSSupportsOpeningDocumentsInPlace"], False)
            self.assertIs(result["UISupportsDocumentBrowser"], False)

    def test_xml_document_type_is_added_without_exporting_system_uti(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump({}, file)

            self.assertTrue(inject_dylib.patch_info_plist(app))
            with (app / "Info.plist").open("rb") as file:
                result = plistlib.load(file)

            xml_document_type = inject_dylib._xml_document_type(result)
            self.assertEqual(
                xml_document_type,
                {
                    "CFBundleTypeName": "Alight Motion XML Project",
                    "CFBundleTypeRole": "Editor",
                    "LSHandlerRank": "Alternate",
                    "LSItemContentTypes": [inject_dylib.XML_UTI],
                },
            )
            self.assertFalse(
                any(
                    declaration.get("UTTypeIdentifier") == inject_dylib.XML_UTI
                    for declaration in result["UTExportedTypeDeclarations"]
                )
            )

    def test_existing_xml_document_type_is_upgraded_and_patch_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump(
                    {
                        "CFBundleDocumentTypes": [
                            {
                                "CFBundleTypeName": "Old XML",
                                "CFBundleTypeRole": "Viewer",
                                "LSHandlerRank": "Default",
                                "LSItemContentTypes": [inject_dylib.XML_UTI],
                            }
                        ]
                    },
                    file,
                )

            self.assertTrue(inject_dylib.patch_info_plist(app))
            with (app / "Info.plist").open("rb") as file:
                upgraded_bytes = file.read()
            upgraded = plistlib.loads(upgraded_bytes)
            xml_document_type = inject_dylib._xml_document_type(upgraded)
            self.assertEqual(xml_document_type["CFBundleTypeRole"], "Editor")
            self.assertEqual(xml_document_type["LSHandlerRank"], "Alternate")
            self.assertEqual(
                sum(
                    inject_dylib.XML_UTI
                    in document_type.get("LSItemContentTypes", [])
                    for document_type in upgraded["CFBundleDocumentTypes"]
                ),
                1,
            )

            self.assertFalse(inject_dylib.patch_info_plist(app))
            self.assertEqual((app / "Info.plist").read_bytes(), upgraded_bytes)

    def test_duplicate_xml_document_types_are_collapsed_without_losing_other_utis(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump(
                    {
                        "CFBundleDocumentTypes": [
                            {
                                "CFBundleTypeName": "XML One",
                                "LSItemContentTypes": [inject_dylib.XML_UTI],
                            },
                            {
                                "CFBundleTypeName": "Mixed",
                                "LSItemContentTypes": [
                                    "public.text",
                                    inject_dylib.XML_UTI,
                                ],
                            },
                        ]
                    },
                    file,
                )

            self.assertTrue(inject_dylib.patch_info_plist(app))
            with (app / "Info.plist").open("rb") as file:
                result = plistlib.load(file)

            xml_types = [
                item
                for item in result["CFBundleDocumentTypes"]
                if inject_dylib.XML_UTI in item.get("LSItemContentTypes", [])
            ]
            self.assertEqual(len(xml_types), 1)
            self.assertEqual(xml_types[0]["LSItemContentTypes"], [inject_dylib.XML_UTI])
            self.assertTrue(
                any(
                    item.get("LSItemContentTypes") == ["public.text"]
                    for item in result["CFBundleDocumentTypes"]
                )
            )


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
                    "DiscoveryEnabled": True,
                    "DiscoveryPort": 8765,
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

    def test_rejects_integer_discovery_flag_in_custom_plist(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = root / "App"
            app.mkdir()
            source = root / "source.plist"
            with source.open("wb") as file:
                plistlib.dump(
                    {
                        "BaseURL": "https://bug.meowcr.cn",
                        "Token": "cloud-token-123456",
                        "DiscoveryEnabled": 1,
                    },
                    file,
                )
            settings = inject_dylib.DebugSettings(
                enabled=True,
                config_path=source,
            )

            with self.assertRaisesRegex(ValueError, "plist Boolean"):
                inject_dylib.install_debug_config(app, settings)

    def test_generates_https_config_with_discovery_disabled(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            settings = inject_dylib.DebugSettings(
                enabled=True,
                server_url="https://bug.meowcr.cn/",
                token="cloud-token-123456",
                mode="full",
                build_identifier="v28-cloud-test",
            )
            config = inject_dylib.install_debug_config(temp_dir, settings)

            self.assertEqual(config["BaseURL"], "https://bug.meowcr.cn")
            self.assertIs(config["DiscoveryEnabled"], False)
            self.assertEqual(config["DiscoveryPort"], 443)
            self.assertEqual(config["BuildIdentifier"], "v28-cloud-test")
            self.assertFalse(
                inject_dylib.debug_config_needs_local_network_settings(config)
            )

    def test_rejects_debug_server_url_with_path_or_credentials(self):
        for value in (
            "https://bug.meowcr.cn/api",
            "https://admin:secret@bug.meowcr.cn",
            "ftp://bug.meowcr.cn",
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    inject_dylib.normalize_debug_server_url(value)

    def test_cloud_debug_plist_does_not_add_local_network_permissions(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            app = Path(temp_dir)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump({}, file)
            cloud_config = {
                "BaseURL": "https://bug.meowcr.cn",
                "DiscoveryEnabled": False,
            }

            inject_dylib.patch_info_plist(
                app,
                enable_debug_network=(
                    inject_dylib.debug_config_needs_local_network_settings(
                        cloud_config
                    )
                ),
            )
            with (app / "Info.plist").open("rb") as file:
                result = plistlib.load(file)

            self.assertNotIn("NSLocalNetworkUsageDescription", result)
            self.assertNotIn("NSAppTransportSecurity", result)


class InjectionTests(unittest.TestCase):
    def test_bundle_version_is_patched_and_verified_end_to_end(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ipa, _ = make_fake_ipa(root)
            dylib = root / "AMProjExport.dylib"
            make_macho(dylib, filetype=inject_dylib.MH_DYLIB)
            output = root / "versioned.ipa"

            with mock.patch.object(inject_dylib, "_try_resign"):
                inject_dylib.inject_ipa(
                    ipa,
                    dylib,
                    output,
                    bundle_version="738",
                )

            with zipfile.ZipFile(output, "r") as archive:
                info = plistlib.loads(
                    archive.read("Payload/Fixture.app/Info.plist")
                )
            self.assertEqual(info["CFBundleVersion"], "738")

            verification = inject_dylib.verify_injected_ipa(
                output,
                dylib,
                inject_dylib.DebugSettings(),
                expected_bundle_identifier="com.example.fixture",
                expected_bundle_version="738",
            )
            self.assertEqual(verification["bundle_version"], "738")

            with self.assertRaisesRegex(RuntimeError, "CFBundleVersion"):
                inject_dylib.verify_injected_ipa(
                    output,
                    dylib,
                    inject_dylib.DebugSettings(),
                    expected_bundle_identifier="com.example.fixture",
                    expected_bundle_version="739",
                )

    def test_injection_rejects_unverified_main_uuid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ipa, _ = make_fake_ipa(root)
            dylib = root / "AMProjExport.dylib"
            make_macho(dylib, filetype=inject_dylib.MH_DYLIB)

            with self.assertRaisesRegex(RuntimeError, "UUID does not match"):
                inject_dylib.inject_ipa(
                    ipa,
                    dylib,
                    root / "rejected.ipa",
                    expected_main_uuid="4b22d43f-09fc-3bde-859b-78a5d573a503",
                )

    def test_wrapped_ipa_normalization_rejects_multiple_candidates(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "First" / "Payload").mkdir(parents=True)
            (root / "Second" / "Payload").mkdir(parents=True)

            with self.assertRaisesRegex(RuntimeError, "more than one wrapper"):
                inject_dylib._normalize_ipa_root(root)

    def test_wrapped_ipa_normalization_rejects_root_conflicts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "DownloadedIPA" / "Payload").mkdir(parents=True)
            (root / "DownloadedIPA" / "SwiftSupport").mkdir()
            (root / "SwiftSupport").mkdir()

            with self.assertRaisesRegex(RuntimeError, "entries conflict"):
                inject_dylib._normalize_ipa_root(root)

    def test_wrapped_fake_ipa_is_repacked_with_standard_root_layout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ipa, archive_root = make_fake_ipa(root, wrapper="DownloadedIPA")
            swift_support = archive_root / "SwiftSupport"
            swift_support.mkdir()
            (swift_support / "marker.txt").write_text("preserved", encoding="ascii")
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
                source = root / "source"
                for path in source.rglob("*"):
                    archive.write(path, path.relative_to(source))

            dylib = root / "AMProjExport.dylib"
            make_macho(dylib, filetype=inject_dylib.MH_DYLIB)
            output = root / "wrapped-output.ipa"

            with mock.patch.object(inject_dylib, "_try_resign"):
                inject_dylib.inject_ipa(ipa, dylib, output)

            with zipfile.ZipFile(output, "r") as archive:
                names = archive.namelist()
                self.assertIn("Payload/Fixture.app/Info.plist", names)
                self.assertIn("SwiftSupport/marker.txt", names)
                self.assertFalse(
                    any(name.startswith("DownloadedIPA/") for name in names)
                )

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
            dylib_bytes = make_macho(dylib, filetype=inject_dylib.MH_DYLIB)
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
                dylib_bytes,
            )
            self.assertFalse((result_app / "_CodeSignature").exists())
            with (result_app / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(info["CFBundleIdentifier"], "com.example.fixture")
            self.assertIs(info["LSSupportsOpeningDocumentsInPlace"], False)
            self.assertIs(info["UISupportsDocumentBrowser"], False)
            self.assertNotIn(inject_dylib.SHARE_APP_GROUP_INFO_KEY, info)
            self.assertIs(
                info["NSAppTransportSecurity"]["NSAllowsLocalNetworking"],
                True,
            )
            self.assertTrue(inject_dylib._has_xml_document_type(info))
            self.assertEqual(
                inject_dylib._xml_document_type(info)["LSHandlerRank"],
                "Alternate",
            )
            self.assertFalse(
                any(
                    declaration.get("UTTypeIdentifier") == inject_dylib.XML_UTI
                    for declaration in info["UTExportedTypeDeclarations"]
                )
            )
            with (result_app / inject_dylib.DEBUG_CONFIG_NAME).open(
                "rb"
            ) as file:
                config = plistlib.load(file)
            self.assertEqual(config["DefaultMode"], "full")
            self.assertIs(config["DiscoveryEnabled"], True)
            self.assertEqual(config["DiscoveryPort"], 8765)

            verification = inject_dylib.verify_injected_ipa(
                output,
                dylib,
                settings,
                expected_config=config,
                expected_bundle_identifier="com.example.fixture",
            )
            self.assertEqual(verification["mode"], "full")
            self.assertEqual(
                verification["bundle_identifier"], "com.example.fixture"
            )
            self.assertIsNone(verification["share_extension"])

            info["CFBundleDocumentTypes"] = [
                document_type
                for document_type in info["CFBundleDocumentTypes"]
                if inject_dylib.XML_UTI
                not in document_type.get("LSItemContentTypes", [])
            ]
            with (result_app / "Info.plist").open("wb") as file:
                plistlib.dump(info, file)
            missing_xml_ipa = root / "missing-xml-registration.ipa"
            with zipfile.ZipFile(
                missing_xml_ipa, "w", zipfile.ZIP_DEFLATED
            ) as archive:
                for path in extracted.rglob("*"):
                    archive.write(path, path.relative_to(extracted))
            with self.assertRaisesRegex(RuntimeError, "public.xml"):
                inject_dylib.verify_injected_ipa(
                    missing_xml_ipa,
                    dylib,
                    settings,
                    expected_config=config,
                    expected_bundle_identifier="com.example.fixture",
                )

    def test_stable_injection_removes_existing_share_extension_and_host_group(self):
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
                        inject_dylib.SHARE_APP_GROUP_INFO_KEY: (
                            "group.com.example.fixture.amprojshare"
                        ),
                        "CFBundleURLTypes": [
                            {
                                "CFBundleURLName": "AMProj Import",
                                "CFBundleURLSchemes": [
                                    inject_dylib.AMPROJ_URL_SCHEME
                                ],
                            },
                            {
                                "CFBundleURLName": "Keep Me",
                                "CFBundleURLSchemes": ["fixture"],
                            },
                        ],
                    },
                    file,
                )
            make_macho(app / "Fixture")
            plugins = app / "PlugIns"
            plugins.mkdir()
            stale_source = make_share_extension(root)
            shutil.copytree(
                stale_source,
                plugins / inject_dylib.SHARE_EXTENSION_BUNDLE_NAME,
            )
            ipa = root / "input-with-stale-share.ipa"
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
                for path in source.rglob("*"):
                    archive.write(path, path.relative_to(source))

            dylib = root / "AMProjExportCloud.dylib"
            make_macho(dylib, filetype=inject_dylib.MH_DYLIB)
            output = root / "stable-output.ipa"
            with mock.patch.object(inject_dylib, "_try_resign"):
                inject_dylib.inject_ipa(ipa, dylib, output)

            extracted = root / "stable-result"
            shutil.unpack_archive(output, extracted, "zip")
            result_app = extracted / "Payload" / "Fixture.app"
            self.assertFalse(
                (result_app / "PlugIns" / inject_dylib.SHARE_EXTENSION_BUNDLE_NAME).exists()
            )
            self.assertFalse((result_app / "PlugIns").exists())
            with (result_app / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertNotIn(inject_dylib.SHARE_APP_GROUP_INFO_KEY, info)
            self.assertEqual(
                [
                    item.get("CFBundleURLSchemes")
                    for item in info.get("CFBundleURLTypes", [])
                ],
                [["fixture"]],
            )
            inject_dylib.verify_injected_ipa(
                output,
                dylib,
                inject_dylib.DebugSettings(),
                expected_bundle_identifier="com.example.fixture",
            )

    def test_fake_ipa_installs_and_verifies_share_extension(self):
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
            ipa = root / "input.ipa"
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
                for path in source.rglob("*"):
                    archive.write(path, path.relative_to(source))

            dylib = root / "AMProjExportDebug.dylib"
            make_macho(dylib, filetype=inject_dylib.MH_DYLIB)
            app_group_id = "group.com.example.fixture.amprojshare"
            appex = make_share_extension(root, app_group_id=app_group_id)
            (appex / "_CodeSignature").mkdir()
            (appex / "_CodeSignature" / "CodeResources").write_bytes(b"old")
            output = root / "share-output.ipa"
            settings = inject_dylib.DebugSettings(
                enabled=True,
                server_ip="192.168.1.5",
                token="fixture-token-1234",
            )

            with mock.patch.object(inject_dylib, "_try_resign"):
                inject_dylib.inject_ipa(
                    ipa,
                    dylib,
                    output,
                    settings,
                    share_extension_path=appex,
                    app_group_id=app_group_id,
                )

            extracted = root / "share-result"
            shutil.unpack_archive(output, extracted, "zip")
            result_app = extracted / "Payload" / "Fixture.app"
            result_appex = result_app / "PlugIns" / appex.name
            self.assertTrue((result_appex / "FixtureShare").is_file())
            self.assertTrue(
                (result_appex / "FixtureShare.entitlements").is_file()
            )
            self.assertFalse((result_appex / "_CodeSignature").exists())
            with (result_app / "Info.plist").open("rb") as file:
                info = plistlib.load(file)
            self.assertEqual(
                info[inject_dylib.SHARE_APP_GROUP_INFO_KEY], app_group_id
            )
            self.assertTrue(
                inject_dylib._has_url_scheme(
                    info, inject_dylib.AMPROJ_URL_SCHEME
                )
            )

            verification = inject_dylib.verify_injected_ipa(
                output,
                dylib,
                settings,
                expected_config=plistlib.loads(
                    (result_app / inject_dylib.DEBUG_CONFIG_NAME).read_bytes()
                ),
                expected_bundle_identifier="com.example.fixture",
                expected_share_extension=appex,
                expected_app_group_id=app_group_id,
            )
            self.assertEqual(
                verification["share_extension"]["bundle_identifier"],
                "com.example.fixture.amprojshare",
            )

    def test_share_extension_rejects_wrong_metadata_and_entitlements(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            group = "group.com.example.fixture.amprojshare"
            appex = make_share_extension(root, app_group_id=group)
            info_path = appex / "Info.plist"
            with info_path.open("rb") as file:
                info = plistlib.load(file)
            info["NSExtension"]["NSExtensionPointIdentifier"] = (
                "com.apple.invalid-extension"
            )
            with info_path.open("wb") as file:
                plistlib.dump(info, file)

            with self.assertRaisesRegex(ValueError, "NSExtensionPointIdentifier"):
                inject_dylib.verify_share_extension_bundle(
                    appex,
                    "com.example.fixture.amprojshare",
                    group,
                )

            info["NSExtension"]["NSExtensionPointIdentifier"] = (
                inject_dylib.SHARE_EXTENSION_POINT
            )
            with info_path.open("wb") as file:
                plistlib.dump(info, file)
            with self.assertRaisesRegex(ValueError, "App Group"):
                inject_dylib.verify_share_extension_bundle(
                    appex,
                    "com.example.fixture.amprojshare",
                    "group.com.example.other",
                )

    def test_final_verifier_rejects_missing_load_command(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            app = source / "Payload" / "Fixture.app"
            frameworks = app / "Frameworks"
            frameworks.mkdir(parents=True)
            with (app / "Info.plist").open("wb") as file:
                plistlib.dump(
                    {
                        "CFBundleExecutable": "Fixture",
                        "CFBundleIdentifier": "com.example.fixture",
                    },
                    file,
                )
            inject_dylib.patch_info_plist(app)
            make_macho(app / "Fixture")
            dylib = root / "AMProjExport.dylib"
            dylib_bytes = make_macho(dylib, filetype=inject_dylib.MH_DYLIB)
            (frameworks / dylib.name).write_bytes(dylib_bytes)
            ipa = root / "missing-command.ipa"
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
                for path in source.rglob("*"):
                    archive.write(path, path.relative_to(source))

            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                inject_dylib.verify_injected_ipa(
                    ipa,
                    dylib,
                    inject_dylib.DebugSettings(),
                    expected_bundle_identifier="com.example.fixture",
                )

    def test_final_verifier_rejects_bad_zip_crc(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ipa = root / "bad-crc.ipa"
            payload = b"CRC-PAYLOAD-" * 16
            with zipfile.ZipFile(ipa, "w", zipfile.ZIP_STORED) as archive:
                archive.writestr("Payload/Fixture.app/Info.plist", payload)
            archive_data = bytearray(ipa.read_bytes())
            payload_offset = archive_data.find(payload)
            self.assertGreaterEqual(payload_offset, 0)
            archive_data[payload_offset] ^= 0xFF
            ipa.write_bytes(archive_data)
            dylib = root / "AMProjExport.dylib"
            make_macho(dylib, filetype=inject_dylib.MH_DYLIB)

            with self.assertRaisesRegex(RuntimeError, "CRC"):
                inject_dylib.verify_injected_ipa(
                    ipa, dylib, inject_dylib.DebugSettings()
                )


class ArgumentTests(unittest.TestCase):
    def test_bundle_version_accepts_738_and_reaches_injector(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(
            ["input.ipa", "lib.dylib", "--bundle-version", "738"]
        )
        self.assertEqual(args.bundle_version, "738")

        with mock.patch.object(inject_dylib, "inject_ipa") as injector:
            self.assertEqual(
                inject_dylib.main(
                    [
                        "input.ipa",
                        "lib.dylib",
                        "output.ipa",
                        "--bundle-version",
                        "738",
                    ]
                ),
                0,
            )
        self.assertEqual(injector.call_args.kwargs["bundle_version"], "738")

    def test_bundle_version_rejects_non_positive_or_non_canonical_values(self):
        parser = inject_dylib.build_argument_parser()
        for value in ("0", "01", "-1", "+1", "1.0", "abc"):
            with self.subTest(value=value):
                with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                    parser.parse_args(
                        [
                            "input.ipa",
                            "lib.dylib",
                            "--bundle-version",
                            value,
                        ]
                    )

    def test_expected_main_uuid_is_normalized(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(
            [
                "input.ipa",
                "lib.dylib",
                "--expected-main-uuid",
                "4B22D43F-09FC-3BDE-859B-78A5D573A503",
            ]
        )
        self.assertEqual(
            args.expected_main_uuid,
            "4b22d43f09fc3bde859b78a5d573a503",
        )

    def test_legacy_positional_arguments_remain_compatible(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(["input.ipa", "lib.dylib", "output.ipa"])
        settings = inject_dylib._debug_settings_from_args(args, parser)
        self.assertEqual(args.output, "output.ipa")
        self.assertFalse(settings.enabled)
        self.assertIsNone(args.share_extension)
        self.assertIsNone(args.app_group_id)
        self.assertIsNone(args.bundle_version)

    def test_debug_dylib_enables_generated_config(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(["input.ipa", "AMProjExportDebug.dylib"])
        settings = inject_dylib._debug_settings_from_args(args, parser)
        self.assertTrue(settings.enabled)
        self.assertEqual(settings.mode, "full")
        self.assertEqual(settings.server_port, 8765)

    def test_cloud_dylib_accepts_explicit_https_transport_config(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(
            [
                "input.ipa",
                "AMProjExportCloud.dylib",
                "--server-url",
                "https://bug.meowcr.cn",
                "--debug-token",
                "0123456789abcdef",
                "--no-discovery",
                "--build-id",
                "v36-cloud-test",
            ]
        )
        settings = inject_dylib._debug_settings_from_args(args, parser)
        self.assertTrue(settings.enabled)
        self.assertEqual(settings.server_url, "https://bug.meowcr.cn")
        self.assertIs(settings.discovery_enabled, False)
        self.assertEqual(settings.build_identifier, "v36-cloud-test")

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

    def test_share_extension_options_must_be_paired(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(
            [
                "input.ipa",
                "AMProjExportDebug.dylib",
                "--share-extension",
                "AMProjShareExtension.appex",
            ]
        )
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            inject_dylib._share_extension_options_from_args(args, parser)

    def test_share_extension_options_accept_valid_app_group(self):
        parser = inject_dylib.build_argument_parser()
        args = parser.parse_args(
            [
                "input.ipa",
                "AMProjExportDebug.dylib",
                "--share-extension",
                "AMProjShareExtension.appex",
                "--app-group-id",
                "group.com.alightmotion.meow.amprojshare",
            ]
        )
        self.assertEqual(
            inject_dylib._share_extension_options_from_args(args, parser),
            (
                "AMProjShareExtension.appex",
                "group.com.alightmotion.meow.amprojshare",
            ),
        )


if __name__ == "__main__":
    unittest.main()
