import hashlib
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import build_862_loadcontrol_package as loadcontrol


class OwnBaseLoadControl862Tests(unittest.TestCase):
    def fixture_info_plist(self):
        return plistlib.dumps(
            {
                "CFBundleDisplayName": "Alight Motion",
                "CFBundleName": "Alight Motion",
                "CFBundleExecutable": "AlightMotion",
                "CFBundleIdentifier": "com.alightcreative.motion",
                "CFBundleShortVersionString": "6.2.55",
                "CFBundleVersion": "862",
                "LSSupportsOpeningDocumentsInPlace": True,
                "UISupportsDocumentBrowser": False,
                "CFBundleDocumentTypes": loadcontrol.stable.EXPECTED_DOCUMENT_TYPES,
                "UTExportedTypeDeclarations": loadcontrol.stable.EXPECTED_EXPORTED_TYPES,
            },
            fmt=plistlib.FMT_BINARY,
            sort_keys=False,
        )

    def dylib_command(self, command, name, size=None):
        encoded = name.encode("utf-8") + b"\0"
        minimum = (24 + len(encoded) + 7) & ~7
        size = size or minimum
        if size < minimum:
            raise ValueError("fixture command is too small")
        return (
            struct.pack("<IIIIII", command, size, 24, 0, 0, 0)
            + encoded
            + bytes(size - 24 - len(encoded))
        )

    def fixture_main(self, cloud_command=None, cloud_name=None):
        cloud_command = (
            loadcontrol.LC_LOAD_WEAK_DYLIB
            if cloud_command is None
            else cloud_command
        )
        cloud_name = loadcontrol.CLOUD_LOAD if cloud_name is None else cloud_name
        commands = [
            struct.pack(
                "<II16s",
                loadcontrol.LC_UUID,
                24,
                loadcontrol.EXPECTED_MAIN_UUID,
            ),
            self.dylib_command(
                loadcontrol.LC_LOAD_WEAK_DYLIB,
                loadcontrol.AMENHANCER_LOAD,
                72,
            ),
            self.dylib_command(cloud_command, cloud_name, 80),
        ]
        signature_offset = 32 + sum(len(command) for command in commands) + 16 + 256
        commands.append(
            struct.pack(
                "<IIII",
                loadcontrol.LC_CODE_SIGNATURE,
                16,
                signature_offset,
                0,
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

    def test_main_patch_replaces_only_direct_cloud_load(self):
        source = self.fixture_main()
        with mock.patch.multiple(
            loadcontrol,
            EXPECTED_BASE_MAIN_SHA256=hashlib.sha256(source).hexdigest(),
            EXPECTED_OUTPUT_MAIN_SHA256=mock.DEFAULT,
        ) as patched_constants:
            target = loadcontrol.verify_base_main(source)
            raw = bytearray(source)
            replacement = loadcontrol.LOADCONTROL_LOAD.encode() + b"\0"
            struct.pack_into("<I", raw, target["offset"], loadcontrol.LC_LOAD_DYLIB)
            start = target["offset"] + target["name_offset"]
            end = target["offset"] + target["size"]
            raw[start:end] = replacement + bytes(end - start - len(replacement))
            loadcontrol.EXPECTED_OUTPUT_MAIN_SHA256 = hashlib.sha256(raw).hexdigest()
            try:
                result = loadcontrol.patch_main_loader(source)
            finally:
                loadcontrol.EXPECTED_OUTPUT_MAIN_SHA256 = patched_constants[
                    "EXPECTED_OUTPUT_MAIN_SHA256"
                ]

        self.assertEqual(len(result), len(source))
        load_offset = target["offset"]
        allowed = set(range(load_offset, load_offset + target["size"]))
        changed = {
            index
            for index, (before, after) in enumerate(zip(source, result))
            if before != after
        }
        self.assertTrue(changed)
        self.assertLessEqual(changed, allowed)

    def test_base_rejects_strong_cloud_or_existing_loadcontrol(self):
        for label, source in (
            ("direct AMProj weak load", self.fixture_main(cloud_command=loadcontrol.LC_LOAD_DYLIB)),
            ("already loads LoadControl", self.fixture_main(cloud_name=loadcontrol.LOADCONTROL_LOAD)),
        ):
            with self.subTest(label=label), mock.patch.object(
                loadcontrol,
                "EXPECTED_BASE_MAIN_SHA256",
                hashlib.sha256(source).hexdigest(),
            ):
                with self.assertRaises(RuntimeError):
                    loadcontrol.verify_base_main(source)

    def test_info_contract_preserves_user_identity_and_import_registration(self):
        result = loadcontrol.verify_info_plist(
            loadcontrol._prepare_output_info_plist(self.fixture_info_plist())
        )
        self.assertEqual(
            result["CFBundleIdentifier"], loadcontrol.EXPECTED_OUTPUT_BUNDLE_IDENTIFIER
        )
        self.assertEqual(
            result["CFBundleDisplayName"], loadcontrol.EXPECTED_OUTPUT_DISPLAY_NAME
        )
        self.assertEqual(
            result["CFBundleDocumentTypes"],
            loadcontrol.stable.EXPECTED_DOCUMENT_TYPES,
        )
        self.assertIs(result["LSSupportsOpeningDocumentsInPlace"], True)

    def test_signing_filter_handles_nested_and_case_variants(self):
        self.assertTrue(
            loadcontrol._is_stale_signing_entry(
                loadcontrol.APP_ROOT + "embedded.mobileprovision"
            )
        )
        self.assertTrue(
            loadcontrol._is_stale_signing_entry(
                loadcontrol.APP_ROOT
                + "PlugIns/Foo.appex/EMBEDDED.MOBILEPROVISION"
            )
        )
        self.assertTrue(
            loadcontrol._is_stale_signing_entry(
                loadcontrol.APP_ROOT + "Frameworks/Foo.framework/_CODESIGNATURE/CodeResources"
            )
        )
        self.assertFalse(loadcontrol._is_stale_signing_entry(loadcontrol.LOADCONTROL_PATH))

    def test_profile_app_id_is_locked_to_output_bundle_identifier(self):
        profile = plistlib.dumps(
            {
                "Entitlements": {
                    "application-identifier": "TEAM.com.ayakameow.am",
                    "com.apple.developer.team-identifier": "TEAM",
                },
                "TeamIdentifier": ["TEAM"],
                "ProvisionedDevices": ["device-a"],
            },
            fmt=plistlib.FMT_XML,
        )
        self.assertEqual(
            loadcontrol._verify_signed_profile(
                profile, {"TEAM"}, loadcontrol.EXPECTED_OUTPUT_BUNDLE_IDENTIFIER
            )["provisioned_device_count"],
            1,
        )
        bad = profile.replace(b"com.ayakameow.am", b"com.other.app")
        with self.assertRaisesRegex(RuntimeError, "App ID"):
            loadcontrol._verify_signed_profile(
                bad, {"TEAM"}, loadcontrol.EXPECTED_OUTPUT_BUNDLE_IDENTIFIER
            )

    def test_build_uses_user_base_and_preserves_unrelated_members(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "am_v73.ipa"
            cloud_source = root / "cloud-source.ipa"
            loader_path = root / "LoadControl.dylib"
            output = root / "am_v74.ipa"
            info = self.fixture_info_plist()
            output_info = loadcontrol._prepare_output_info_plist(info)
            base_main = self.fixture_main()
            target = loadcontrol.verify_base_main
            cloud_signed = b"signed cloud fixture"
            cloud_unsigned = b"unsigned cloud fixture"
            enhancer = b"user enhancer"
            substrate = b"user substrate"
            loader = b"loadcontrol fixture"
            loader_path.write_bytes(loader)

            with zipfile.ZipFile(base, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(loadcontrol.INFO_PLIST, info)
                archive.writestr(loadcontrol.MAIN_EXECUTABLE, base_main)
                archive.writestr(loadcontrol.CLOUD_PATH, cloud_signed)
                archive.writestr(loadcontrol.AMENHANCER_PATH, enhancer)
                archive.writestr(loadcontrol.CYDIA_SUBSTRATE_PATH, substrate)
                archive.writestr(
                    loadcontrol.APP_ROOT + "_CodeSignature/CodeResources", b"stale"
                )
                archive.writestr(loadcontrol.EMBEDDED_PROFILE, b"old profile")
                archive.writestr(loadcontrol.APP_ROOT + "asset.dat", b"preserved")
            with zipfile.ZipFile(cloud_source, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr(loadcontrol.CLOUD_PATH, cloud_unsigned)

            cloud_target = loadcontrol._uuid_and_dylib_commands(base_main, "fixture")[1][1]
            patched_main = bytearray(base_main)
            replacement = loadcontrol.LOADCONTROL_LOAD.encode() + b"\0"
            struct.pack_into(
                "<I", patched_main, cloud_target["offset"], loadcontrol.LC_LOAD_DYLIB
            )
            start = cloud_target["offset"] + cloud_target["name_offset"]
            end = cloud_target["offset"] + cloud_target["size"]
            patched_main[start:end] = replacement + bytes(end - start - len(replacement))
            patched_main = bytes(patched_main)

            constants = {
                "EXPECTED_BASE_SHA256": hashlib.sha256(base.read_bytes()).hexdigest(),
                "EXPECTED_BASE_MAIN_SHA256": hashlib.sha256(base_main).hexdigest(),
                "EXPECTED_OUTPUT_MAIN_SHA256": hashlib.sha256(patched_main).hexdigest(),
                "EXPECTED_BASE_CLOUD_SHA256": hashlib.sha256(cloud_signed).hexdigest(),
                "EXPECTED_CLOUD_SOURCE_IPA_SHA256": hashlib.sha256(
                    cloud_source.read_bytes()
                ).hexdigest(),
                "EXPECTED_CLOUD_SOURCE_SHA256": hashlib.sha256(
                    cloud_unsigned
                ).hexdigest(),
                "EXPECTED_OUTPUT_CLOUD_SHA256": hashlib.sha256(
                    cloud_unsigned
                ).hexdigest(),
                "EXPECTED_LOADCONTROL_SHA256": hashlib.sha256(loader).hexdigest(),
                "EXPECTED_AMENHANCER_SHA256": hashlib.sha256(enhancer).hexdigest(),
                "EXPECTED_CYDIA_SUBSTRATE_SHA256": hashlib.sha256(substrate).hexdigest(),
            }
            with mock.patch.multiple(loadcontrol, **constants), mock.patch.object(
                loadcontrol.stable,
                "patch_stability_hotfixes",
                side_effect=lambda value: value,
            ), mock.patch.object(
                loadcontrol.stable, "verify_stability_hotfixes"
            ), mock.patch.object(
                loadcontrol.stable, "_code_signature_command", return_value=None
            ), mock.patch.object(
                loadcontrol, "_load_loadcontrol", return_value=loader
            ):
                result = loadcontrol.build_loadcontrol_package(
                    base, cloud_source, loader_path, output
                )

            self.assertTrue(result["requires_recursive_real_signing"])
            with zipfile.ZipFile(output, "r") as archive:
                names = archive.namelist()
                self.assertEqual(archive.read(loadcontrol.INFO_PLIST), output_info)
                self.assertEqual(archive.read(loadcontrol.MAIN_EXECUTABLE), patched_main)
                self.assertEqual(archive.read(loadcontrol.CLOUD_PATH), cloud_unsigned)
                self.assertEqual(archive.read(loadcontrol.LOADCONTROL_PATH), loader)
                self.assertEqual(archive.read(loadcontrol.AMENHANCER_PATH), enhancer)
                self.assertEqual(
                    archive.read(loadcontrol.CYDIA_SUBSTRATE_PATH), substrate
                )
                self.assertEqual(
                    archive.read(loadcontrol.APP_ROOT + "asset.dat"), b"preserved"
                )
                self.assertFalse(
                    any(loadcontrol._is_stale_signing_entry(name) for name in names)
                )


if __name__ == "__main__":
    unittest.main()
