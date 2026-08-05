import hashlib
import plistlib
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import build_862_stable_package as stable


class Stable862PackageTests(unittest.TestCase):
    def fixture_info_plist(self, **overrides):
        plist = {
            "CFBundleDisplayName": "Alight Motion",
            "CFBundleName": "Alight Motion",
            "CFBundleExecutable": "AlightMotion",
            "CFBundleIdentifier": "com.alightcreative.motion",
            "CFBundleShortVersionString": "6.2.55",
            "CFBundleVersion": "862",
            "LSSupportsOpeningDocumentsInPlace": False,
            "UISupportsDocumentBrowser": True,
            "CFBundleDocumentTypes": stable.EXPECTED_DOCUMENT_TYPES,
            "UTExportedTypeDeclarations": stable.EXPECTED_EXPORTED_TYPES,
        }
        plist.update(overrides)
        return plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False)

    def fixture_signed_macho(self, info_plist=None, code_resources=None):
        code_limit = 4096
        hash_size = 32
        identifier = b"fixture\0"
        special_payloads = {
            stable.CSSLOT_INFOSLOT: info_plist,
            stable.CSSLOT_RESOURCEDIR: code_resources,
        }
        special_slots = max(
            (slot for slot, payload in special_payloads.items() if payload is not None),
            default=0,
        )
        hash_offset = 44 + len(identifier) + special_slots * hash_size
        code_directory_length = hash_offset + hash_size
        signature_length = 20 + code_directory_length

        macho = bytearray(code_limit)
        struct.pack_into("<I", macho, 0, 0xFEEDFACF)
        struct.pack_into("<I", macho, 16, 1)
        struct.pack_into("<I", macho, 20, 16)
        struct.pack_into(
            "<IIII",
            macho,
            32,
            stable.LC_CODE_SIGNATURE,
            16,
            code_limit,
            signature_length,
        )

        code_directory = bytearray(code_directory_length)
        struct.pack_into(
            ">9I",
            code_directory,
            0,
            stable.CSMAGIC_CODEDIRECTORY,
            code_directory_length,
            0x20001,
            stable.CS_ADHOC,
            hash_offset,
            44,
            special_slots,
            1,
            code_limit,
        )
        struct.pack_into(">4B", code_directory, 36, hash_size, 2, 0, 12)
        struct.pack_into(">I", code_directory, 40, 0)
        code_directory[44 : 44 + len(identifier)] = identifier
        for slot in range(special_slots, 0, -1):
            payload = special_payloads.get(slot)
            digest = hashlib.sha256(payload).digest() if payload is not None else bytes(32)
            start = hash_offset - slot * hash_size
            code_directory[start : start + hash_size] = digest
        code_directory[hash_offset : hash_offset + hash_size] = hashlib.sha256(
            macho
        ).digest()

        signature = bytearray(signature_length)
        struct.pack_into(
            ">III",
            signature,
            0,
            stable.CSMAGIC_EMBEDDED_SIGNATURE,
            signature_length,
            1,
        )
        struct.pack_into(">II", signature, 12, stable.CSSLOT_CODEDIRECTORY, 20)
        signature[20:] = code_directory
        return bytes(macho + signature)

    def fixture_dylib(self):
        size = stable.SWIFT_RELEASE_FALLBACK_BRANCH_OFFSET + 0x100
        data = bytearray(size)
        start = stable.PRESENTATION_DIRECT_BRANCH_OFFSET
        data[
            start : start + len(stable.PRESENTATION_DIRECT_BRANCH_ORIGINAL)
        ] = stable.PRESENTATION_DIRECT_BRANCH_ORIGINAL
        start = stable.PACKAGE_PREDICATE_OFFSET
        data[start : start + len(stable.PACKAGE_PREDICATE_ORIGINAL)] = (
            stable.PACKAGE_PREDICATE_ORIGINAL
        )
        start = stable.SHARE_ACTION_HOOK_OFFSET
        data[start : start + len(stable.SHARE_ACTION_HOOK_ORIGINAL)] = (
            stable.SHARE_ACTION_HOOK_ORIGINAL
        )
        start = stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_OFFSET
        data[
            start : start
            + len(stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_ORIGINAL)
        ] = stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_ORIGINAL
        start = stable.SHARE_OPTION_ID_LOAD_OFFSET
        data[start : start + len(stable.SHARE_OPTION_ID_LOAD_ORIGINAL)] = (
            stable.SHARE_OPTION_ID_LOAD_ORIGINAL
        )
        start = stable.SHARE_OPTION_ID_COMPARE_OFFSET
        data[start : start + len(stable.SHARE_OPTION_ID_COMPARE_ORIGINAL)] = (
            stable.SHARE_OPTION_ID_COMPARE_ORIGINAL
        )
        start = stable.SWIFT_STRING_FALLBACK_BRANCH_OFFSET
        data[
            start : start + len(stable.SWIFT_STRING_FALLBACK_BRANCH_ORIGINAL)
        ] = stable.SWIFT_STRING_FALLBACK_BRANCH_ORIGINAL
        start = stable.SWIFT_RELEASE_FALLBACK_BRANCH_OFFSET
        data[
            start : start + len(stable.SWIFT_RELEASE_FALLBACK_BRANCH_ORIGINAL)
        ] = stable.SWIFT_RELEASE_FALLBACK_BRANCH_ORIGINAL
        return bytes(data)

    def test_stability_hotfixes_are_exact_and_preserve_other_bytes(self):
        original = self.fixture_dylib()
        patched = stable.patch_stability_hotfixes(original)
        presentation = stable.PRESENTATION_DIRECT_BRANCH_OFFSET
        predicate = stable.PACKAGE_PREDICATE_OFFSET
        original_action = stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_OFFSET
        share = stable.SHARE_ACTION_HOOK_OFFSET
        option_load = stable.SHARE_OPTION_ID_LOAD_OFFSET
        option_compare = stable.SHARE_OPTION_ID_COMPARE_OFFSET
        string_fallback = stable.SWIFT_STRING_FALLBACK_BRANCH_OFFSET
        release_fallback = stable.SWIFT_RELEASE_FALLBACK_BRANCH_OFFSET
        self.assertEqual(
            patched[
                presentation : presentation
                + len(stable.PRESENTATION_DIRECT_BRANCH_DISABLED)
            ],
            stable.PRESENTATION_DIRECT_BRANCH_DISABLED,
        )
        self.assertEqual(
            patched[
                predicate : predicate + len(stable.PACKAGE_PREDICATE_DISABLED)
            ],
            stable.PACKAGE_PREDICATE_DISABLED,
        )
        self.assertEqual(
            patched[share : share + len(stable.SHARE_ACTION_HOOK_ORIGINAL)],
            stable.SHARE_ACTION_HOOK_ORIGINAL,
        )
        self.assertEqual(
            patched[
                original_action : original_action
                + len(stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_DISABLED)
            ],
            stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_DISABLED,
        )
        self.assertEqual(
            patched[
                option_load : option_load + len(stable.SHARE_OPTION_ID_LOAD_SEMANTIC)
            ],
            stable.SHARE_OPTION_ID_LOAD_SEMANTIC,
        )
        self.assertEqual(
            patched[
                option_compare : option_compare
                + len(stable.SHARE_OPTION_ID_COMPARE_PROJECT_PACKAGE)
            ],
            stable.SHARE_OPTION_ID_COMPARE_PROJECT_PACKAGE,
        )
        self.assertEqual(
            patched[
                string_fallback : string_fallback
                + len(stable.SWIFT_STRING_FALLBACK_BRANCH_DISABLED)
            ],
            stable.SWIFT_STRING_FALLBACK_BRANCH_DISABLED,
        )
        self.assertEqual(
            patched[
                release_fallback : release_fallback
                + len(stable.SWIFT_RELEASE_FALLBACK_BRANCH_DISABLED)
            ],
            stable.SWIFT_RELEASE_FALLBACK_BRANCH_DISABLED,
        )
        changed = {
            index
            for index, (before, after) in enumerate(zip(original, patched))
            if before != after
        }
        allowed = (
            set(
                range(
                    presentation,
                    presentation + len(stable.PRESENTATION_DIRECT_BRANCH_ORIGINAL),
                )
            )
            | set(range(predicate, predicate + len(stable.PACKAGE_PREDICATE_ORIGINAL)))
            | set(
                range(
                    original_action,
                    original_action
                    + len(stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_ORIGINAL),
                )
            )
            | set(
                range(
                    option_load,
                    option_load + len(stable.SHARE_OPTION_ID_LOAD_ORIGINAL),
                )
            )
            | set(
                range(
                    option_compare,
                    option_compare + len(stable.SHARE_OPTION_ID_COMPARE_ORIGINAL),
                )
            )
            | set(
                range(
                    string_fallback,
                    string_fallback
                    + len(stable.SWIFT_STRING_FALLBACK_BRANCH_ORIGINAL),
                )
            )
            | set(
                range(
                    release_fallback,
                    release_fallback
                    + len(stable.SWIFT_RELEASE_FALLBACK_BRANCH_ORIGINAL),
                )
            )
        )
        self.assertTrue(changed)
        self.assertLessEqual(changed, allowed)

    def test_stability_hotfixes_reject_unknown_binary(self):
        offsets = (
            stable.PRESENTATION_DIRECT_BRANCH_OFFSET,
            stable.PACKAGE_PREDICATE_OFFSET,
            stable.DIRECT_FAILURE_ADD_ORIGINAL_ACTION_OFFSET,
            stable.SHARE_ACTION_HOOK_OFFSET,
            stable.SHARE_OPTION_ID_LOAD_OFFSET,
            stable.SHARE_OPTION_ID_COMPARE_OFFSET,
            stable.SWIFT_STRING_FALLBACK_BRANCH_OFFSET,
            stable.SWIFT_RELEASE_FALLBACK_BRANCH_OFFSET,
        )
        for offset in offsets:
            with self.subTest(offset=hex(offset)):
                data = bytearray(self.fixture_dylib())
                data[offset] ^= 1
                with self.assertRaisesRegex(RuntimeError, "preimage mismatch"):
                    stable.patch_stability_hotfixes(bytes(data))

    def test_info_plist_is_locked_to_6255_and_uses_provider_scope(self):
        source = self.fixture_info_plist()
        result = plistlib.loads(stable.patch_info_plist(source))
        self.assertIs(result["LSSupportsOpeningDocumentsInPlace"], True)
        self.assertIs(result["UISupportsDocumentBrowser"], False)

    def test_info_plist_rejects_another_build(self):
        source = plistlib.dumps(
            {
                "CFBundleShortVersionString": "6.2.55",
                "CFBundleVersion": "861",
                "CFBundleIdentifier": "com.alightcreative.motion",
            }
        )
        with self.assertRaisesRegex(RuntimeError, "not build 862"):
            stable.patch_info_plist(source)

    def test_info_plist_contract_locks_import_registration_and_display_name(self):
        stable.verify_info_plist_contract(stable.patch_info_plist(self.fixture_info_plist()))
        for key, value in (
            ("CFBundleDisplayName", "broken"),
            ("CFBundleDocumentTypes", []),
            ("UTExportedTypeDeclarations", []),
        ):
            with self.subTest(key=key):
                data = self.fixture_info_plist(
                    LSSupportsOpeningDocumentsInPlace=True,
                    UISupportsDocumentBrowser=False,
                    **{key: value},
                )
                with self.assertRaisesRegex(RuntimeError, "Info.plist"):
                    stable.verify_info_plist_contract(data)

    def test_signed_hotfix_verifier_rejects_every_contract_byte(self):
        patched = stable.patch_stability_hotfixes(self.fixture_dylib())
        stable.verify_stability_hotfixes(patched)
        offsets = [item[0] for item in stable.STABILITY_PATCHES] + [
            stable.SHARE_ACTION_HOOK_OFFSET
        ]
        for offset in offsets:
            with self.subTest(offset=hex(offset)):
                corrupted = bytearray(patched)
                corrupted[offset] ^= 1
                with self.assertRaisesRegex(RuntimeError, "signed"):
                    stable.verify_stability_hotfixes(bytes(corrupted))

    def test_signature_validator_checks_code_info_and_resources(self):
        info = b"final Info.plist"
        resources = b"final CodeResources"
        macho = self.fixture_signed_macho(info, resources)
        summary = stable._validate_macho_signature(
            macho, info_plist=info, code_resources=resources
        )
        self.assertEqual(len(summary["code_directories"]), 1)
        self.assertEqual(summary["code_directories"][0]["code_slots"], 1)

    def test_signature_validator_rejects_tampered_code_page(self):
        macho = bytearray(self.fixture_signed_macho())
        macho[128] ^= 1
        with self.assertRaisesRegex(RuntimeError, "code slot 0"):
            stable._validate_macho_signature(bytes(macho))

    def test_signature_validator_rejects_stale_special_slots(self):
        info = b"final Info.plist"
        resources = b"final CodeResources"
        macho = self.fixture_signed_macho(info, resources)
        for label, kwargs in (
            ("Info.plist", {"info_plist": b"changed", "code_resources": resources}),
            ("CodeResources", {"info_plist": info, "code_resources": b"changed"}),
        ):
            with self.subTest(slot=label):
                with self.assertRaisesRegex(RuntimeError, label):
                    stable._validate_macho_signature(macho, **kwargs)

    def test_signature_validator_rejects_missing_or_duplicate_load_command(self):
        valid = bytearray(self.fixture_signed_macho())
        missing = bytearray(valid)
        struct.pack_into("<II", missing, 16, 0, 0)
        with self.assertRaisesRegex(RuntimeError, "missing LC_CODE_SIGNATURE"):
            stable._validate_macho_signature(bytes(missing))

        duplicate = bytearray(valid)
        duplicate[48:64] = duplicate[32:48]
        struct.pack_into("<II", duplicate, 16, 2, 32)
        with self.assertRaisesRegex(RuntimeError, "duplicate LC_CODE_SIGNATURE"):
            stable._validate_macho_signature(bytes(duplicate))

    def test_resolve_zsign_pins_official_executable_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "zsign.exe"
            executable.write_bytes(b"official fixture")
            expected = hashlib.sha256(executable.read_bytes()).hexdigest()
            with mock.patch.object(stable, "EXPECTED_ZSIGN_SHA256", expected):
                self.assertEqual(stable.resolve_zsign(executable), executable.resolve())
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                stable.resolve_zsign(executable)

    def test_run_zsign_uses_only_pinned_adhoc_packaging_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unsigned = root / "unsigned.ipa"
            signed = root / "signed.ipa"
            unsigned.write_bytes(b"unsigned")

            def fake_run(command, **_kwargs):
                signed.write_bytes(b"signed")
                return subprocess.CompletedProcess(command, 0, stdout="Signed OK")

            with mock.patch.object(stable.subprocess, "run", side_effect=fake_run) as run:
                stable.run_zsign(root / "zsign.exe", unsigned, signed)
            command = run.call_args.args[0]
            self.assertEqual(command[1:6], ["-a", "-f", "-z", "6", "-o"])
            self.assertEqual(command[-2:], [str(signed), str(unsigned)])
            for forbidden in ("-b", "-n", "-I", "-S", "-l"):
                self.assertNotIn(forbidden, command)

    def test_run_zsign_rejects_failure_and_missing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unsigned = root / "unsigned.ipa"
            signed = root / "signed.ipa"
            unsigned.write_bytes(b"unsigned")
            failed = subprocess.CompletedProcess([], 9, stdout="sign failed")
            with mock.patch.object(stable.subprocess, "run", return_value=failed):
                with self.assertRaisesRegex(RuntimeError, "exit 9"):
                    stable.run_zsign(root / "zsign.exe", unsigned, signed)
            succeeded = subprocess.CompletedProcess([], 0, stdout="Signed OK")
            with mock.patch.object(stable.subprocess, "run", return_value=succeeded):
                with self.assertRaisesRegex(RuntimeError, "did not produce"):
                    stable.run_zsign(root / "zsign.exe", unsigned, signed)

    def test_build_does_not_replace_output_when_signer_resolution_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "input.ipa"
            output = root / "stable.ipa"
            source.write_bytes(b"input")
            output.write_bytes(b"existing stable")
            with mock.patch.object(
                stable, "resolve_zsign", side_effect=RuntimeError("missing signer")
            ):
                with self.assertRaisesRegex(RuntimeError, "missing signer"):
                    stable.build_stable_package(source, output)
            self.assertEqual(output.read_bytes(), b"existing stable")


if __name__ == "__main__":
    unittest.main()
