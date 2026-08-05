#!/usr/bin/env python3
"""Build the single Alight Motion 6.2.55 (862) stable IPA hotfix.

This is a constrained Windows fallback for the already-verified v43 cloud
dylib. It preserves the 862 native-import bridge, keeps the exact ShareNC
project-package action on the custom .amproj exporter, and disables the broad
ShareProjectPackageVC interception and original image fallback.
"""

import argparse
import hashlib
import os
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path


EXPECTED_INPUT_SHA256 = (
    "c2b362d2b20b1c6283144ece8c5b125b1b4e1734b396506a8599e6bce1d0bf6c"
)
EXPECTED_DYLIB_SHA256 = (
    "6fe177938f4b472b9636d0191c041b5bfe0eb37b280df0ceccde7fd3e4297bf3"
)
EXPECTED_PATCHED_DYLIB_SHA256 = (
    "c35e6ecbca2aeed4ba01e1afa9fa130347c98f0249dc1c6c5c6c91ef64939718"
)
EXPECTED_ZSIGN_SHA256 = (
    "6661659b492699d17f3add8d1a3974538d2f87c072927deace6d71ad61b32efc"
)
EXPECTED_ZSIGN_ZIP_SHA256 = (
    "1b0eed7a64a3ee28bedd941072b546520c20c5e4a6983b0743e8a7c1b42b1bff"
)
APP_ROOT = "Payload/AlightMotion.app/"
INFO_PLIST = APP_ROOT + "Info.plist"
MAIN_EXECUTABLE = APP_ROOT + "AlightMotion"
DYLIB_PATH = APP_ROOT + "Frameworks/AMProjExportCloud.dylib"
CODE_RESOURCES = APP_ROOT + "_CodeSignature/CodeResources"

EXPECTED_MACHO_PATHS = frozenset(
    {
        MAIN_EXECUTABLE,
        APP_ROOT + "Frameworks/AmEnhancer.dylib",
        DYLIB_PATH,
        APP_ROOT
        + "Frameworks/AppLovinQualityService.framework/AppLovinQualityService",
        APP_ROOT + "Frameworks/AppLovinSDK.framework/AppLovinSDK",
        APP_ROOT + "Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        APP_ROOT + "Frameworks/Lottie.framework/Lottie",
    }
)
EXPECTED_SIGNATURE_ADDITIONS = frozenset(
    path
    for bundle in (
        APP_ROOT,
        APP_ROOT + "Frameworks/AppLovinQualityService.framework/",
        APP_ROOT + "Frameworks/AppLovinSDK.framework/",
        APP_ROOT + "Frameworks/CydiaSubstrate.framework/",
        APP_ROOT + "Frameworks/Lottie.framework/",
    )
    for path in (
        bundle + "_CodeSignature/",
        bundle + "_CodeSignature/CodeResources",
    )
)
EXPECTED_MAIN_UUID = bytes.fromhex("01b730171a6e3b178f59c27462dea563")
EXPECTED_AMPROJ_LOAD = "@executable_path/Frameworks/AMProjExportCloud.dylib"

LC_CODE_SIGNATURE = 0x1D
LC_UUID = 0x1B
LC_LOAD_WEAK_DYLIB = 0x80000018
CS_ADHOC = 0x2
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSSLOT_CODEDIRECTORY = 0
CSSLOT_ALTERNATE_CODEDIRECTORIES = range(0x1000, 0x1006)
CSSLOT_INFOSLOT = 1
CSSLOT_RESOURCEDIR = 3

EXPECTED_DOCUMENT_TYPES = [
    {
        "CFBundleTypeName": "Alight Motion Project",
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "Owner",
        "LSItemContentTypes": ["com.alightcreative.motion.amproj"],
    },
    {
        "CFBundleTypeName": "Alight Motion XML Project",
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["public.xml"],
    },
]
EXPECTED_EXPORTED_TYPES = [
    {
        "UTTypeConformsTo": [
            "public.data",
            "public.archive",
            "public.zip-archive",
        ],
        "UTTypeDescription": "Alight Motion Project",
        "UTTypeIdentifier": "com.alightcreative.motion.amproj",
        "UTTypeTagSpecification": {
            "public.filename-extension": ["amproj"],
            "public.mime-type": ["application/x-amproj"],
        },
    }
]

# Exact offsets in the verified v43 cloud dylib after its 862 importer patch.
PRESENTATION_DIRECT_BRANCH_OFFSET = 0x1E1C0
PACKAGE_PREDICATE_OFFSET = 0x1FEC0
DIRECT_FAILURE_ADD_ORIGINAL_ACTION_OFFSET = 0x2C228
SHARE_ACTION_HOOK_OFFSET = 0x315A4
SHARE_OPTION_ID_LOAD_OFFSET = 0x3171C
SHARE_OPTION_ID_COMPARE_OFFSET = 0x3173C
SWIFT_STRING_FALLBACK_BRANCH_OFFSET = 0x5B39C
SWIFT_RELEASE_FALLBACK_BRANCH_OFFSET = 0x5B3D8
PRESENTATION_DIRECT_BRANCH_ORIGINAL = bytes.fromhex(
    "40200036"  # tbz w0, #0, #0x1e5c8
)
PRESENTATION_DIRECT_BRANCH_DISABLED = bytes.fromhex(
    "1f2003d5"  # nop
)
PACKAGE_PREDICATE_ORIGINAL = bytes.fromhex(
    "f657bda9f44f01a9"
)
PACKAGE_PREDICATE_DISABLED = bytes.fromhex(
    "00008052c0035fd6"  # mov w0, #0; ret
)
SHARE_ACTION_HOOK_ORIGINAL = bytes.fromhex(
    "ff4304d1fc6f0ba9fa670ca9f85f0da9f6570ea9"
)
DIRECT_FAILURE_ADD_ORIGINAL_ACTION_ORIGINAL = bytes.fromhex(
    "f6e40094"  # bl objc_msgSend$addAction:
)
DIRECT_FAILURE_ADD_ORIGINAL_ACTION_DISABLED = bytes.fromhex(
    "1f2003d5"  # nop; keep block retain/release balancing intact
)
SHARE_OPTION_ID_LOAD_ORIGINAL = bytes.fromhex(
    "f96a60f8"  # ldr x25, [x23, x0] (selectedRow)
)
SHARE_OPTION_ID_LOAD_SEMANTIC = bytes.fromhex(
    "f9824439"  # ldrb w25, [x23, #0x120] (selectedExportOptID)
)
SHARE_OPTION_ID_COMPARE_ORIGINAL = bytes.fromhex(
    "3f0700f1"  # cmp x25, #1 (dynamic row)
)
SHARE_OPTION_ID_COMPARE_PROJECT_PACKAGE = bytes.fromhex(
    "3f1f00f1"  # cmp x25, #7 (ExportOptionID.projectPackage)
)
SWIFT_STRING_FALLBACK_BRANCH_ORIGINAL = bytes.fromhex(
    "da0100b5"  # cbnz x26, #0x5b3d4
)
SWIFT_STRING_FALLBACK_BRANCH_DISABLED = bytes.fromhex(
    "0e000014"  # b #0x5b3d4
)
SWIFT_RELEASE_FALLBACK_BRANCH_ORIGINAL = bytes.fromhex(
    "e80100b5"  # cbnz x8, #0x5b414
)
SWIFT_RELEASE_FALLBACK_BRANCH_DISABLED = bytes.fromhex(
    "0f000014"  # b #0x5b414
)

STABILITY_PATCHES = (
    (
        PRESENTATION_DIRECT_BRANCH_OFFSET,
        PRESENTATION_DIRECT_BRANCH_ORIGINAL,
        PRESENTATION_DIRECT_BRANCH_DISABLED,
        "ShareProjectPackageVC direct-export branch",
    ),
    (
        PACKAGE_PREDICATE_OFFSET,
        PACKAGE_PREDICATE_ORIGINAL,
        PACKAGE_PREDICATE_DISABLED,
        "ShareProjectPackageVC predicate",
    ),
    (
        DIRECT_FAILURE_ADD_ORIGINAL_ACTION_OFFSET,
        DIRECT_FAILURE_ADD_ORIGINAL_ACTION_ORIGINAL,
        DIRECT_FAILURE_ADD_ORIGINAL_ACTION_DISABLED,
        "original image fallback action",
    ),
    (
        SHARE_OPTION_ID_LOAD_OFFSET,
        SHARE_OPTION_ID_LOAD_ORIGINAL,
        SHARE_OPTION_ID_LOAD_SEMANTIC,
        "ShareVC selectedExportOptID load",
    ),
    (
        SHARE_OPTION_ID_COMPARE_OFFSET,
        SHARE_OPTION_ID_COMPARE_ORIGINAL,
        SHARE_OPTION_ID_COMPARE_PROJECT_PACKAGE,
        "ShareVC project-package semantic comparison",
    ),
    (
        SWIFT_STRING_FALLBACK_BRANCH_OFFSET,
        SWIFT_STRING_FALLBACK_BRANCH_ORIGINAL,
        SWIFT_STRING_FALLBACK_BRANCH_DISABLED,
        "NSString-to-Swift fallback branch",
    ),
    (
        SWIFT_RELEASE_FALLBACK_BRANCH_OFFSET,
        SWIFT_RELEASE_FALLBACK_BRANCH_ORIGINAL,
        SWIFT_RELEASE_FALLBACK_BRANCH_DISABLED,
        "Swift bridge release fallback branch",
    ),
)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def patch_stability_hotfixes(data):
    patched = bytearray(data)
    share_hook = bytes(
        patched[
            SHARE_ACTION_HOOK_OFFSET : SHARE_ACTION_HOOK_OFFSET
            + len(SHARE_ACTION_HOOK_ORIGINAL)
        ]
    )
    if share_hook != SHARE_ACTION_HOOK_ORIGINAL:
        raise RuntimeError(
            "ShareNC.onTapExport hook preimage mismatch at "
            f"0x{SHARE_ACTION_HOOK_OFFSET:x}: {share_hook.hex()}"
        )
    for offset, expected, replacement, label in STABILITY_PATCHES:
        current = bytes(patched[offset : offset + len(expected)])
        if current != expected:
            raise RuntimeError(
                f"{label} preimage mismatch at 0x{offset:x}: {current.hex()}"
            )
        patched[offset : offset + len(expected)] = replacement
    return bytes(patched)


def verify_stability_hotfixes(data):
    for offset, _expected, replacement, label in STABILITY_PATCHES:
        current = data[offset : offset + len(replacement)]
        if current != replacement:
            raise RuntimeError(
                f"signed {label} mismatch at 0x{offset:x}: {current.hex()}"
            )
    hook = data[
        SHARE_ACTION_HOOK_OFFSET : SHARE_ACTION_HOOK_OFFSET
        + len(SHARE_ACTION_HOOK_ORIGINAL)
    ]
    if hook != SHARE_ACTION_HOOK_ORIGINAL:
        raise RuntimeError(
            "signed ShareNC.onTapExport hook mismatch at "
            f"0x{SHARE_ACTION_HOOK_OFFSET:x}: {hook.hex()}"
        )


def patch_info_plist(data):
    plist = plistlib.loads(data)
    if plist.get("CFBundleShortVersionString") != "6.2.55":
        raise RuntimeError("input app is not Alight Motion 6.2.55")
    if plist.get("CFBundleVersion") != "862":
        raise RuntimeError("input app is not build 862")
    if plist.get("CFBundleIdentifier") != "com.alightcreative.motion":
        raise RuntimeError("input app bundle identifier is unexpected")
    plist["LSSupportsOpeningDocumentsInPlace"] = True
    plist["UISupportsDocumentBrowser"] = False
    result = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False)
    verify_info_plist_contract(result)
    return result


def verify_info_plist_contract(data):
    plist = plistlib.loads(data)
    expected_scalars = {
        "CFBundleDisplayName": "Alight Motion",
        "CFBundleName": "Alight Motion",
        "CFBundleExecutable": "AlightMotion",
        "CFBundleIdentifier": "com.alightcreative.motion",
        "CFBundleShortVersionString": "6.2.55",
        "CFBundleVersion": "862",
        "LSSupportsOpeningDocumentsInPlace": True,
        "UISupportsDocumentBrowser": False,
    }
    for key, expected in expected_scalars.items():
        if plist.get(key) != expected:
            raise RuntimeError(
                f"signed Info.plist {key} mismatch: "
                f"expected {expected!r}, found {plist.get(key)!r}"
            )
    if plist.get("CFBundleDocumentTypes") != EXPECTED_DOCUMENT_TYPES:
        raise RuntimeError("signed Info.plist document type contract mismatch")
    if plist.get("UTExportedTypeDeclarations") != EXPECTED_EXPORTED_TYPES:
        raise RuntimeError("signed Info.plist exported UTI contract mismatch")
    return plist


def _macho_format(data):
    formats = {
        b"\xcf\xfa\xed\xfe": ("<", 32),
        b"\xfe\xed\xfa\xcf": (">", 32),
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xfe\xed\xfa\xce": (">", 28),
    }
    try:
        return formats[data[:4]]
    except KeyError as error:
        raise RuntimeError(f"unsupported Mach-O magic: {data[:4].hex()}") from error


def _macho_slices(data):
    if data[:4] in {
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xce",
    }:
        return [(0, data)]
    fat_formats = {
        b"\xca\xfe\xba\xbe": (">", False),
        b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True),
        b"\xbf\xba\xfe\xca": ("<", True),
    }
    try:
        endian, is_64 = fat_formats[data[:4]]
    except KeyError as error:
        raise RuntimeError(f"unsupported Mach-O magic: {data[:4].hex()}") from error
    if len(data) < 8:
        raise RuntimeError("truncated fat Mach-O header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    entry_size = 32 if is_64 else 20
    if count == 0 or 8 + count * entry_size > len(data):
        raise RuntimeError("invalid fat Mach-O architecture table")
    slices = []
    for index in range(count):
        offset = 8 + index * entry_size
        if is_64:
            _cpu, _subtype, slice_offset, size, _align, _reserved = (
                struct.unpack_from(endian + "IIQQII", data, offset)
            )
        else:
            _cpu, _subtype, slice_offset, size, _align = struct.unpack_from(
                endian + "IIIII", data, offset
            )
        if size == 0 or slice_offset + size > len(data):
            raise RuntimeError("fat Mach-O slice is out of bounds")
        slices.append((slice_offset, data[slice_offset : slice_offset + size]))
    ordered = sorted((offset, offset + len(item)) for offset, item in slices)
    if any(left[1] > right[0] for left, right in zip(ordered, ordered[1:])):
        raise RuntimeError("fat Mach-O slices overlap")
    return slices


def _macho_load_commands(data):
    endian, header_size = _macho_format(data)
    if len(data) < header_size:
        raise RuntimeError("truncated Mach-O header")
    command_count, command_bytes = struct.unpack_from(endian + "II", data, 16)
    command_end = header_size + command_bytes
    if command_end > len(data):
        raise RuntimeError("Mach-O load commands exceed file bounds")
    commands = []
    offset = header_size
    for _index in range(command_count):
        if offset + 8 > command_end:
            raise RuntimeError("truncated Mach-O load command")
        command, size = struct.unpack_from(endian + "II", data, offset)
        if size < 8 or size % 4 or offset + size > command_end:
            raise RuntimeError("invalid Mach-O load command size")
        commands.append((command, offset, size))
        offset += size
    if offset != command_end:
        raise RuntimeError("Mach-O load command byte count mismatch")
    return endian, commands


def _code_signature_command(data, required=True):
    endian, commands = _macho_load_commands(data)
    matches = [item for item in commands if item[0] == LC_CODE_SIGNATURE]
    if not matches:
        if required:
            raise RuntimeError("Mach-O is missing LC_CODE_SIGNATURE")
        return None
    if len(matches) != 1:
        raise RuntimeError("Mach-O has duplicate LC_CODE_SIGNATURE commands")
    _command, offset, size = matches[0]
    if size != 16:
        raise RuntimeError("LC_CODE_SIGNATURE has an invalid size")
    data_offset, data_size = struct.unpack_from(endian + "II", data, offset + 8)
    if data_size == 0 or data_offset + data_size > len(data):
        raise RuntimeError("LC_CODE_SIGNATURE points outside the Mach-O")
    return offset, data_offset, data_size


def _digest_for_code_directory(data, hash_type, hash_size):
    algorithms = {
        1: "sha1",
        2: "sha256",
        3: "sha256",
        4: "sha384",
    }
    try:
        digest = hashlib.new(algorithms[hash_type], data).digest()
    except KeyError as error:
        raise RuntimeError(f"unsupported CodeDirectory hash type: {hash_type}") from error
    if hash_size == 0 or hash_size > len(digest):
        raise RuntimeError("invalid CodeDirectory hash size")
    return digest[:hash_size]


def _special_slot_hash(code_directory, hash_offset, hash_size, slot):
    start = hash_offset - slot * hash_size
    end = start + hash_size
    if start < 0 or end > len(code_directory):
        raise RuntimeError("CodeDirectory special slot is out of bounds")
    return code_directory[start:end]


def _validate_code_directory(
    macho,
    code_directory,
    signature_offset,
    info_plist=None,
    code_resources=None,
):
    if len(code_directory) < 44:
        raise RuntimeError("truncated CodeDirectory")
    (
        magic,
        length,
        version,
        flags,
        hash_offset,
        _identifier_offset,
        special_slots,
        code_slots,
        code_limit,
    ) = struct.unpack_from(">9I", code_directory, 0)
    if magic != CSMAGIC_CODEDIRECTORY:
        raise RuntimeError("invalid CodeDirectory magic")
    if length < 44 or length > len(code_directory):
        raise RuntimeError("CodeDirectory length is out of bounds")
    code_directory = code_directory[:length]
    hash_size, hash_type, _platform, page_shift = struct.unpack_from(
        ">4B", code_directory, 36
    )
    if code_limit == 0 and version >= 0x20300:
        if length < 64:
            raise RuntimeError("CodeDirectory is missing codeLimit64")
        code_limit = struct.unpack_from(">Q", code_directory, 56)[0]
    if not flags & CS_ADHOC:
        raise RuntimeError("CodeDirectory is not ad-hoc signed")
    if code_limit != signature_offset:
        raise RuntimeError("CodeDirectory does not cover all pre-signature bytes")
    if page_shift == 0 or page_shift > 30:
        raise RuntimeError("invalid CodeDirectory page size")
    page_size = 1 << page_shift
    expected_slots = (code_limit + page_size - 1) // page_size
    if code_slots != expected_slots:
        raise RuntimeError("CodeDirectory code slot count mismatch")
    if hash_offset < special_slots * hash_size:
        raise RuntimeError("CodeDirectory special hashes are out of bounds")
    if hash_offset + code_slots * hash_size > length:
        raise RuntimeError("CodeDirectory code hashes are out of bounds")

    for index in range(code_slots):
        start = index * page_size
        end = min(start + page_size, code_limit)
        expected = _digest_for_code_directory(macho[start:end], hash_type, hash_size)
        actual_start = hash_offset + index * hash_size
        actual = code_directory[actual_start : actual_start + hash_size]
        if actual != expected:
            raise RuntimeError(f"CodeDirectory code slot {index} hash mismatch")

    for slot, label, payload in (
        (CSSLOT_INFOSLOT, "Info.plist", info_plist),
        (CSSLOT_RESOURCEDIR, "CodeResources", code_resources),
    ):
        if payload is None:
            continue
        if special_slots < slot:
            raise RuntimeError(f"CodeDirectory is missing the {label} special slot")
        expected = _digest_for_code_directory(payload, hash_type, hash_size)
        actual = _special_slot_hash(code_directory, hash_offset, hash_size, slot)
        if actual != expected:
            raise RuntimeError(f"CodeDirectory {label} special slot mismatch")
    return {
        "flags": flags,
        "hash_type": hash_type,
        "hash_size": hash_size,
        "page_size": page_size,
        "code_slots": code_slots,
    }


def _validate_macho_signature(macho, info_plist=None, code_resources=None):
    _command_offset, signature_offset, signature_size = _code_signature_command(macho)
    signature = macho[signature_offset : signature_offset + signature_size]
    if len(signature) < 12:
        raise RuntimeError("truncated embedded signature")
    magic, length, count = struct.unpack_from(">III", signature, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        raise RuntimeError("invalid embedded signature magic")
    if length < 12 or length > len(signature) or 12 + count * 8 > length:
        raise RuntimeError("embedded signature index is out of bounds")
    entries = [
        struct.unpack_from(">II", signature, 12 + index * 8)
        for index in range(count)
    ]
    entry_types = [entry_type for entry_type, _offset in entries]
    if len(entry_types) != len(set(entry_types)):
        raise RuntimeError("embedded signature contains duplicate slot types")
    if 0x10000 in entry_types:
        raise RuntimeError("ad-hoc signature unexpectedly contains a CMS blob")
    code_directory_entries = [
        (entry_type, offset)
        for entry_type, offset in entries
        if entry_type == CSSLOT_CODEDIRECTORY
        or entry_type in CSSLOT_ALTERNATE_CODEDIRECTORIES
    ]
    if entry_types.count(CSSLOT_CODEDIRECTORY) != 1:
        raise RuntimeError("embedded signature must contain one primary CodeDirectory")
    if not code_directory_entries:
        raise RuntimeError("embedded signature has no CodeDirectory")
    results = []
    index_end = 12 + count * 8
    for _entry_type, offset in code_directory_entries:
        if offset < index_end or offset + 8 > length:
            raise RuntimeError("CodeDirectory index offset is out of bounds")
        code_directory_length = struct.unpack_from(">I", signature, offset + 4)[0]
        if code_directory_length < 44 or offset + code_directory_length > length:
            raise RuntimeError("CodeDirectory blob is out of bounds")
        results.append(
            _validate_code_directory(
                macho,
                signature[offset : offset + code_directory_length],
                signature_offset,
                info_plist=info_plist,
                code_resources=code_resources,
            )
        )
    return {
        "signature_offset": signature_offset,
        "signature_size": signature_size,
        "code_directories": results,
    }


def _macho_paths(archive):
    magics = {
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xce",
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf",
        b"\xbf\xba\xfe\xca",
    }
    paths = set()
    for info in archive.infolist():
        if info.is_dir() or info.file_size < 4:
            continue
        with archive.open(info, "r") as member:
            if member.read(4) in magics:
                paths.add(info.filename)
    return paths


def _zip_member_sha256(archive, path):
    digest = hashlib.sha256()
    with archive.open(path, "r") as member:
        while True:
            chunk = member.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.digest()


def _verify_main_identity(data):
    slices = _macho_slices(data)
    if len(slices) != 1:
        raise RuntimeError("main executable must be a thin Mach-O")
    _slice_offset, macho = slices[0]
    endian, commands = _macho_load_commands(macho)
    uuids = []
    amproj_loads = []
    dylib_commands = {0xC, 0xD, 0x18, 0x1F, 0x20, 0x23}
    for command, offset, size in commands:
        if command == LC_UUID:
            if size != 24:
                raise RuntimeError("main executable has an invalid LC_UUID")
            uuids.append(macho[offset + 8 : offset + 24])
        if command & 0x7FFFFFFF not in dylib_commands:
            continue
        if size < 24:
            raise RuntimeError("main executable has a truncated dylib command")
        name_offset = struct.unpack_from(endian + "I", macho, offset + 8)[0]
        if name_offset >= size:
            raise RuntimeError("main executable dylib name is out of bounds")
        raw_name = macho[offset + name_offset : offset + size]
        name = raw_name.split(b"\0", 1)[0].decode("utf-8", errors="strict")
        if name == EXPECTED_AMPROJ_LOAD:
            amproj_loads.append((command, name))
    if uuids != [EXPECTED_MAIN_UUID]:
        raise RuntimeError("main executable UUID changed")
    if amproj_loads != [(LC_LOAD_WEAK_DYLIB, EXPECTED_AMPROJ_LOAD)]:
        raise RuntimeError("AMProjExportCloud must have one weak main-executable load")


def _mask_signature_ranges(data):
    masked = bytearray(data)
    ranges = []
    for slice_offset, macho in _macho_slices(data):
        _command_offset, signature_offset, signature_size = _code_signature_command(macho)
        start = slice_offset + signature_offset
        end = start + signature_size
        masked[start:end] = b"\0" * signature_size
        ranges.append((start, end))
    return bytes(masked), ranges


def _verify_resigned_macho_preservation(unsigned, signed):
    if len(unsigned) != len(signed):
        raise RuntimeError("zsign changed an existing Mach-O file size")
    unsigned_masked, unsigned_ranges = _mask_signature_ranges(unsigned)
    signed_masked, signed_ranges = _mask_signature_ranges(signed)
    if unsigned_ranges != signed_ranges or unsigned_masked != signed_masked:
        raise RuntimeError("zsign changed bytes outside an existing signature blob")


def _verify_new_dylib_signature(unsigned, signed):
    if _code_signature_command(unsigned, required=False) is not None:
        raise RuntimeError("unsigned staging dylib unexpectedly has a signature")
    signed_slices = _macho_slices(signed)
    if len(signed_slices) != 1:
        raise RuntimeError("AMProjExportCloud must remain a thin Mach-O")
    _slice_offset, signed_macho = signed_slices[0]
    _command_offset, signature_offset, signature_size = _code_signature_command(
        signed_macho
    )
    if signature_offset != len(unsigned):
        raise RuntimeError("AMProjExportCloud signature was not appended at EOF")
    if len(signed_macho) != signature_offset + signature_size:
        raise RuntimeError("AMProjExportCloud contains trailing bytes after its signature")
    if signed_macho[0x4000:signature_offset] != unsigned[0x4000:]:
        raise RuntimeError("zsign changed AMProjExportCloud code or data bytes")


def verify_signed_stable_ipa(unsigned_path, signed_path, expected_info, expected_dylib):
    with zipfile.ZipFile(unsigned_path, "r") as unsigned, zipfile.ZipFile(
        signed_path, "r"
    ) as signed:
        if signed.testzip() is not None:
            raise RuntimeError("signed IPA failed ZIP CRC validation")
        unsigned_names = unsigned.namelist()
        signed_names = signed.namelist()
        if len(signed_names) != len(set(signed_names)):
            raise RuntimeError("signed IPA contains duplicate ZIP entries")
        unsigned_set = set(unsigned_names)
        signed_set = set(signed_names)
        if not unsigned_set <= signed_set:
            raise RuntimeError("zsign removed entries from the stable IPA")
        additions = signed_set - unsigned_set
        if additions != EXPECTED_SIGNATURE_ADDITIONS:
            raise RuntimeError(
                "zsign added unexpected IPA entries: "
                + ", ".join(sorted(additions ^ EXPECTED_SIGNATURE_ADDITIONS))
            )

        unsigned_machos = _macho_paths(unsigned)
        signed_machos = _macho_paths(signed)
        if unsigned_machos != EXPECTED_MACHO_PATHS:
            raise RuntimeError("unsigned staging IPA Mach-O set changed")
        if signed_machos != EXPECTED_MACHO_PATHS:
            raise RuntimeError("signed IPA Mach-O set changed")

        signed_info = signed.read(INFO_PLIST)
        if unsigned.read(INFO_PLIST) != expected_info or signed_info != expected_info:
            raise RuntimeError("zsign changed the final Info.plist bytes")
        verify_info_plist_contract(signed_info)
        if unsigned.read(DYLIB_PATH) != expected_dylib:
            raise RuntimeError("unsigned staging dylib changed before signing")

        for path in unsigned_names:
            if path in EXPECTED_MACHO_PATHS:
                continue
            if _zip_member_sha256(unsigned, path) != _zip_member_sha256(signed, path):
                raise RuntimeError(f"zsign changed resource bytes: {path}")

        code_resources = signed.read(CODE_RESOURCES)
        signature_summary = {}
        for path in sorted(EXPECTED_MACHO_PATHS):
            unsigned_macho = unsigned.read(path)
            signed_macho = signed.read(path)
            if path == DYLIB_PATH:
                _verify_new_dylib_signature(unsigned_macho, signed_macho)
            else:
                _verify_resigned_macho_preservation(unsigned_macho, signed_macho)
            slice_summaries = []
            for _offset, macho in _macho_slices(signed_macho):
                if path == MAIN_EXECUTABLE:
                    summary = _validate_macho_signature(
                        macho,
                        info_plist=signed_info,
                        code_resources=code_resources,
                    )
                else:
                    summary = _validate_macho_signature(macho)
                slice_summaries.append(summary)
            signature_summary[path] = slice_summaries

        signed_main = signed.read(MAIN_EXECUTABLE)
        signed_dylib = signed.read(DYLIB_PATH)
        _verify_main_identity(signed_main)
        verify_stability_hotfixes(signed_dylib)
        return {
            "signed_dylib_sha256": sha256_bytes(signed_dylib),
            "signed_macho_count": len(signature_summary),
            "signed_slice_count": sum(len(items) for items in signature_summary.values()),
        }


def resolve_zsign(explicit_path=None):
    if explicit_path:
        candidates = [Path(explicit_path)]
    else:
        candidates = [Path(__file__).resolve().with_name("zsign.exe")]
        discovered = shutil.which("zsign.exe") or shutil.which("zsign")
        if discovered:
            candidates.append(Path(discovered))
    for candidate in candidates:
        candidate = candidate.expanduser().resolve()
        if not candidate.is_file():
            continue
        actual_hash = sha256_bytes(candidate.read_bytes())
        if actual_hash != EXPECTED_ZSIGN_SHA256:
            raise RuntimeError(
                "zsign.exe does not match official v1.1.1: "
                f"expected {EXPECTED_ZSIGN_SHA256}, found {actual_hash}"
            )
        return candidate
    raise RuntimeError(
        "official zsign v1.1.1 was not found; pass --zsign with zsign.exe "
        f"(expected SHA-256 {EXPECTED_ZSIGN_SHA256})"
    )


def run_zsign(zsign_path, unsigned_path, signed_path):
    if signed_path.exists():
        raise RuntimeError("refusing to reuse an existing zsign output path")
    command = [
        str(zsign_path),
        "-a",
        "-f",
        "-z",
        "6",
        "-o",
        str(signed_path),
        str(unsigned_path),
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"zsign execution failed: {error}") from error
    if result.returncode != 0:
        tail = "\n".join(result.stdout.splitlines()[-20:])
        raise RuntimeError(f"zsign failed with exit {result.returncode}:\n{tail}")
    if not signed_path.is_file() or signed_path.stat().st_size == 0:
        raise RuntimeError("zsign did not produce a signed IPA")


def copy_zip_info(info):
    clone = zipfile.ZipInfo(info.filename, date_time=info.date_time)
    clone.compress_type = info.compress_type
    clone.comment = info.comment
    clone.extra = info.extra
    clone.create_system = info.create_system
    clone.create_version = info.create_version
    clone.extract_version = info.extract_version
    clone.flag_bits = info.flag_bits
    clone.volume = info.volume
    clone.internal_attr = info.internal_attr
    clone.external_attr = info.external_attr
    return clone


def build_stable_package(input_path, output_path, zsign_path=None):
    input_path = Path(input_path).resolve()
    output_path = Path(output_path).resolve()
    if input_path == output_path:
        raise RuntimeError("input and output IPA paths must differ")
    zsign_path = resolve_zsign(zsign_path)
    input_bytes = input_path.read_bytes()
    actual_input_hash = sha256_bytes(input_bytes)
    if actual_input_hash != EXPECTED_INPUT_SHA256:
        raise RuntimeError(
            "input IPA does not match the verified 862 import package: "
            f"expected {EXPECTED_INPUT_SHA256}, found {actual_input_hash}"
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".build-", dir=output_path.parent
    ) as temporary_directory:
        temporary_root = Path(temporary_directory)
        unsigned_path = temporary_root / "unsigned.ipa"
        signed_path = temporary_root / "signed.ipa"
        with zipfile.ZipFile(input_path, "r") as source:
            names = source.namelist()
            if len(names) != len(set(names)):
                raise RuntimeError("input IPA contains duplicate ZIP entries")
            if source.testzip() is not None:
                raise RuntimeError("input IPA failed ZIP CRC validation")
            if any("/_CodeSignature/" in name for name in names):
                raise RuntimeError("input IPA unexpectedly contains stale signatures")
            if names.count(INFO_PLIST) != 1 or names.count(DYLIB_PATH) != 1:
                raise RuntimeError("input IPA does not contain the expected app layout")
            dylib = source.read(DYLIB_PATH)
            actual_dylib_hash = sha256_bytes(dylib)
            if actual_dylib_hash != EXPECTED_DYLIB_SHA256:
                raise RuntimeError(
                    "input dylib is not the verified 862 importer: "
                    f"expected {EXPECTED_DYLIB_SHA256}, found {actual_dylib_hash}"
                )
            patched_dylib = patch_stability_hotfixes(dylib)
            patched_dylib_hash = sha256_bytes(patched_dylib)
            if patched_dylib_hash != EXPECTED_PATCHED_DYLIB_SHA256:
                raise RuntimeError(
                    "patched dylib hash verification failed: "
                    f"expected {EXPECTED_PATCHED_DYLIB_SHA256}, "
                    f"found {patched_dylib_hash}"
                )
            patched_plist = patch_info_plist(source.read(INFO_PLIST))

            with zipfile.ZipFile(unsigned_path, "w", allowZip64=True) as target:
                for info in source.infolist():
                    data = source.read(info.filename)
                    if info.filename == DYLIB_PATH:
                        data = patched_dylib
                    elif info.filename == INFO_PLIST:
                        data = patched_plist
                    target.writestr(copy_zip_info(info), data)

        with zipfile.ZipFile(unsigned_path, "r") as result:
            if result.testzip() is not None:
                raise RuntimeError("unsigned staging IPA failed ZIP CRC validation")
            if len(result.namelist()) != len(set(result.namelist())):
                raise RuntimeError("unsigned staging IPA contains duplicate ZIP entries")
            if any("/_CodeSignature/" in name for name in result.namelist()):
                raise RuntimeError("unsigned staging IPA contains stale signatures")
            if result.read(DYLIB_PATH) != patched_dylib:
                raise RuntimeError("unsigned staging dylib verification failed")
            if result.read(INFO_PLIST) != patched_plist:
                raise RuntimeError("unsigned staging Info.plist verification failed")

        run_zsign(zsign_path, unsigned_path, signed_path)
        signature_result = verify_signed_stable_ipa(
            unsigned_path,
            signed_path,
            expected_info=patched_plist,
            expected_dylib=patched_dylib,
        )
        os.replace(signed_path, output_path)
        return {
            "input_sha256": actual_input_hash,
            "dylib_sha256": patched_dylib_hash,
            **signature_result,
            "zsign_sha256": EXPECTED_ZSIGN_SHA256,
            "output_sha256": sha256_bytes(output_path.read_bytes()),
            "output": str(output_path),
        }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the single Alight Motion 6.2.55 (862) stable IPA"
    )
    parser.add_argument("input", help="verified am_patched_v72_amproj_import.ipa")
    parser.add_argument("output", help="output am_6.2.55_862_stable.ipa")
    parser.add_argument(
        "--zsign",
        help="official zsign v1.1.1 executable; otherwise use ./zsign.exe or PATH",
    )
    args = parser.parse_args(argv)
    result = build_stable_package(args.input, args.output, zsign_path=args.zsign)
    for key, value in result.items():
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
