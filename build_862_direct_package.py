#!/usr/bin/env python3
"""Build the single 6.2.55 (862) direct-Cloud LCSign handoff IPA.

The input Cloud must be compiled from the current source tree.  In particular,
the older v43 Cloud is rejected even if its Mach-O layout and signing shape
are otherwise valid; using it silently produces an IPA where the v44 cold
launch and export fixes are absent.
"""

import argparse
import hashlib
import os
import plistlib
import struct
import tempfile
import zipfile
from pathlib import Path

import build_862_loadcontrol_package as handoff
import build_862_stable_package as stable
import home_ui_contract as homeui
import inject_dylib


# Hashes are intentionally optional.  LCSign changes the executable and the
# input IPA may already be a signed direct-Cloud derivative, so the stable
# contract is checked structurally below (UUID, load commands, document UTI,
# and the v44 Cloud constructor marker).
EXPECTED_INPUT_SHA256 = ""
EXPECTED_INPUT_MAIN_SHA256 = ""
EXPECTED_OUTPUT_MAIN_SHA256 = ""
EXPECTED_INPUT_CLOUD_SHA256 = ""
EXPECTED_OUTPUT_CLOUD_SHA256 = ""
EXPECTED_AMENHANCER_SHA256 = ""
EXPECTED_CYDIA_SUBSTRATE_SHA256 = ""

EXPECTED_DISPLAY_NAME = "猫鹤AM"
EXPECTED_BUNDLE_IDENTIFIER = "com.ayakameow.am"

EXPECTED_CLOUD_RUNTIME_MARKER = b"[AMProjExport] ===== Loading v44-cloud ====="
EXPECTED_CLOUD_STABILITY_MARKER = (
    b"[AMProjExport] v44-stable:semantic-option-7,no-native-activity-fallback"
)
AMENHANCER_STATUS_LABEL = b"AM v59 OK"
AMENHANCER_STATUS_LABEL_CONTEXT = (
    b"nil\0" + AMENHANCER_STATUS_LABEL + b"\0[AmEnhancer] marker added\n\0"
)
AMENHANCER_PATCHED_STATUS_LABEL_CONTEXT = (
    b"nil\0"
    + bytes(len(AMENHANCER_STATUS_LABEL))
    + b"\0[AmEnhancer] marker added\n\0"
)
AMENHANCER_MARKER_FUNCTION_OFFSET = 0x9C54
AMENHANCER_MARKER_FUNCTION_PREIMAGE = bytes.fromhex(
    "fc6fbea9fd7b01a9fd430091ffc30cd1"
)
ARM64_RET = bytes.fromhex("c0035fd6")
AMENHANCER_UI_HOOK_INSTALL_PATCHES = (
    (
        "UIAlertController factory",
        0x4E08,
        bytes.fromhex("400000b0"),
        bytes.fromhex("1d000014"),
    ),
    (
        "UIView didMoveToWindow",
        0x4E7C,
        bytes.fromhex("400000b0"),
        bytes.fromhex("1d000014"),
    ),
    (
        "UIViewController presentation",
        0x4EF0,
        bytes.fromhex("400000b0"),
        bytes.fromhex("1d000014"),
    ),
)
CLOUD_LOAD_LCSIGN = "@executable_path/Frameworks/AMProjExport.dylib"
CLOUD_LOAD_COMPACT = "@rpath/AMProjExportCloud.dylib"
EXPECTED_CLOUD_CONTRACT_FUNCTIONS = {
    "_AMProjV44ReleaseNativeActivityFallbackEnabled": bytes.fromhex(
        "00008052c0035fd6"
    ),
    "_AMProjV44IsDirectProjectPackageOption": bytes.fromhex(
        "1f1c0071e0179f1ac0035fd6"
    ),
}

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_RPATH = 0x8000001C
N_TYPE = 0x0E
N_SECT = 0x0E
FRAMEWORKS_RPATH = "@executable_path/Frameworks"

APP_ROOT = handoff.APP_ROOT
INFO_PLIST = handoff.INFO_PLIST
MAIN_EXECUTABLE = handoff.MAIN_EXECUTABLE
CLOUD_PATH = handoff.CLOUD_PATH
CLOUD_PATH_LCSIGN = f"{APP_ROOT}Frameworks/AMProjExport.dylib"
CLOUD_MEMBER_PATHS = frozenset({CLOUD_PATH, CLOUD_PATH_LCSIGN})
HOME_UI_PATH = f"{APP_ROOT}Frameworks/AMHomeUI.dylib"
LOADCONTROL_PATH = handoff.LOADCONTROL_PATH
AMENHANCER_PATH = handoff.AMENHANCER_PATH
CYDIA_SUBSTRATE_PATH = handoff.CYDIA_SUBSTRATE_PATH
EMBEDDED_PROFILE = handoff.EMBEDDED_PROFILE


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def prepare_amenhancer(data):
    """Disable the v59 marker and prevent its global UIKit hooks."""
    marker_start = AMENHANCER_MARKER_FUNCTION_OFFSET
    marker_end = marker_start + len(AMENHANCER_MARKER_FUNCTION_PREIMAGE)
    patched_marker = (
        ARM64_RET
        + AMENHANCER_MARKER_FUNCTION_PREIMAGE[len(ARM64_RET) :]
    )
    result = bytearray(data)
    allowed = set()

    # A prior resign-ready package is the preferred input for a Cloud-only
    # update. Accept its marker patch, then still prevent the UIKit hook
    # registrations added after that package was produced.
    if data.count(AMENHANCER_PATCHED_STATUS_LABEL_CONTEXT) == 1:
        if marker_end > len(data):
            raise RuntimeError("AmEnhancer v59 marker function is missing")
        if AMENHANCER_STATUS_LABEL in data:
            raise RuntimeError("AmEnhancer v59 status label patch is inconsistent")
        if data[marker_start:marker_end] != patched_marker:
            raise RuntimeError("AmEnhancer v59 marker function patch changed")
        if data.count(patched_marker) != 1:
            raise RuntimeError("AmEnhancer patched marker function is not unique")
    else:
        if data.count(AMENHANCER_STATUS_LABEL_CONTEXT) != 1:
            raise RuntimeError("AmEnhancer v59 status label context changed")
        if data.count(AMENHANCER_STATUS_LABEL) != 1:
            raise RuntimeError("AmEnhancer must contain exactly one v59 status label")
        if marker_end > len(data):
            raise RuntimeError("AmEnhancer v59 marker function is missing")
        if data[marker_start:marker_end] != AMENHANCER_MARKER_FUNCTION_PREIMAGE:
            raise RuntimeError("AmEnhancer v59 marker function changed")
        if data.count(AMENHANCER_MARKER_FUNCTION_PREIMAGE) != 1:
            raise RuntimeError("AmEnhancer v59 marker function is not unique")

        context_start = data.index(AMENHANCER_STATUS_LABEL_CONTEXT)
        label_start = context_start + len(b"nil\0")
        result[label_start : label_start + len(AMENHANCER_STATUS_LABEL)] = bytes(
            len(AMENHANCER_STATUS_LABEL)
        )
        result[marker_start : marker_start + len(ARM64_RET)] = ARM64_RET
        allowed.update(
            range(label_start, label_start + len(AMENHANCER_STATUS_LABEL))
        )
        allowed.update(range(marker_start, marker_start + len(ARM64_RET)))

    for hook_name, offset, preimage, replacement in AMENHANCER_UI_HOOK_INSTALL_PATCHES:
        end = offset + len(preimage)
        if end > len(data):
            raise RuntimeError(f"AmEnhancer {hook_name} registration is missing")
        current = data[offset:end]
        if current == preimage:
            result[offset:end] = replacement
        elif current != replacement:
            raise RuntimeError(f"AmEnhancer {hook_name} registration changed")
        allowed.update(range(offset, end))

    changed = {
        index
        for index, (before, after) in enumerate(zip(data, result))
        if before != after
    }
    if not changed <= allowed:
        raise RuntimeError("AmEnhancer patch changed unexpected bytes")
    if AMENHANCER_STATUS_LABEL in result:
        raise RuntimeError("AmEnhancer v59 status label remains after patch")
    if result[marker_start : marker_start + len(ARM64_RET)] != ARM64_RET:
        raise RuntimeError("AmEnhancer v59 marker function remains active")
    for hook_name, offset, _preimage, replacement in AMENHANCER_UI_HOOK_INSTALL_PATCHES:
        if result[offset : offset + len(replacement)] != replacement:
            raise RuntimeError(f"AmEnhancer {hook_name} registration remains active")
    return bytes(result)


def verify_cloud_runtime_version(data):
    """Reject a stale dylib before any IPA member is written."""
    if EXPECTED_CLOUD_RUNTIME_MARKER not in data:
        if b"[AMProjExport] ===== Loading v43-cloud =====" in data:
            raise RuntimeError(
                "source Cloud is v43; rebuild AMProjExportCloud from the v44 source"
            )
        raise RuntimeError(
            "source Cloud does not contain the v44-cloud constructor marker"
        )
    return True


def _macho_symbol_code(data, symbol_name, expected_size):
    """Return code at an exact arm64 Mach-O symbol, rejecting malformed tables."""
    if len(data) < 32:
        raise RuntimeError("Cloud stability contract requires a Mach-O image")
    magic, cpu_type, _subtype, filetype, command_count, command_bytes, _flags, _reserved = (
        struct.unpack_from("<IIIIIIII", data, 0)
    )
    if magic != 0xFEEDFACF or cpu_type != 0x0100000C or filetype != 0x6:
        raise RuntimeError("Cloud stability contract requires a thin arm64 MH_DYLIB")
    if command_bytes > len(data) - 32:
        raise RuntimeError("Cloud stability contract has invalid load commands")

    sections = []
    symtab = None
    offset = 32
    for _ in range(command_count):
        if offset + 8 > 32 + command_bytes:
            raise RuntimeError("Cloud stability contract has truncated load commands")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > 32 + command_bytes:
            raise RuntimeError("Cloud stability contract has invalid load command size")
        if command == LC_SEGMENT_64:
            if size < 72:
                raise RuntimeError("Cloud stability contract has a short segment command")
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + section_count * 80 > size:
                raise RuntimeError("Cloud stability contract has truncated sections")
            section_offset = offset + 72
            for _section_index in range(section_count):
                section_name = data[section_offset : section_offset + 16].split(b"\0", 1)[0]
                segment_name = data[section_offset + 16 : section_offset + 32].split(
                    b"\0", 1
                )[0]
                address, section_size = struct.unpack_from(
                    "<QQ", data, section_offset + 32
                )
                file_offset = struct.unpack_from("<I", data, section_offset + 48)[0]
                sections.append(
                    (section_name, segment_name, address, section_size, file_offset)
                )
                section_offset += 80
        elif command == LC_SYMTAB:
            if size != 24 or symtab is not None:
                raise RuntimeError("Cloud stability contract has invalid LC_SYMTAB")
            symtab = struct.unpack_from("<IIII", data, offset + 8)
        offset += size

    if symtab is None:
        raise RuntimeError("Cloud stability contract is missing LC_SYMTAB")
    symbol_offset, symbol_count, string_offset, string_size = symtab
    if (
        symbol_offset + symbol_count * 16 > len(data)
        or string_offset + string_size > len(data)
    ):
        raise RuntimeError("Cloud stability contract has an out-of-range symbol table")

    wanted = symbol_name.encode("ascii")
    matches = []
    for index in range(symbol_count):
        entry_offset = symbol_offset + index * 16
        string_index, symbol_type, section_index, _description, value = struct.unpack_from(
            "<IBBHQ", data, entry_offset
        )
        if string_index >= string_size:
            raise RuntimeError("Cloud stability contract has an invalid symbol name")
        name_start = string_offset + string_index
        name_end = data.find(b"\0", name_start, string_offset + string_size)
        if name_end < 0:
            raise RuntimeError("Cloud stability contract has an unterminated symbol name")
        if data[name_start:name_end] != wanted:
            continue
        if symbol_type & N_TYPE != N_SECT or not 1 <= section_index <= len(sections):
            raise RuntimeError(f"Cloud contract symbol {symbol_name} is not section-defined")
        section_name, segment_name, address, section_size, file_offset = sections[
            section_index - 1
        ]
        relative = value - address
        if (
            section_name != b"__text"
            or segment_name != b"__TEXT"
            or relative < 0
            or relative + expected_size > section_size
            or file_offset + relative + expected_size > len(data)
        ):
            raise RuntimeError(f"Cloud contract symbol {symbol_name} is outside __TEXT,__text")
        start = file_offset + relative
        matches.append(data[start : start + expected_size])
    if len(matches) != 1:
        raise RuntimeError(
            f"Cloud stability contract requires one {symbol_name} symbol, found {len(matches)}"
        )
    return matches[0]


def verify_cloud_stability_contract(data):
    """Verify the marker and executable arm64 semantics used by both hook paths."""
    if EXPECTED_CLOUD_STABILITY_MARKER not in data:
        raise RuntimeError(
            "source Cloud does not contain the v44 stability contract marker"
        )
    for symbol_name, expected_code in EXPECTED_CLOUD_CONTRACT_FUNCTIONS.items():
        actual_code = _macho_symbol_code(data, symbol_name, len(expected_code))
        if actual_code != expected_code:
            raise RuntimeError(
                f"Cloud contract function {symbol_name} has unexpected arm64 semantics"
            )
    return True


def _verify_source_info(data):
    plist = plistlib.loads(data)
    expected = {
        "CFBundleExecutable": "AlightMotion",
        "CFBundleIdentifier": {
            "com.alightcreative.motion",
            EXPECTED_BUNDLE_IDENTIFIER,
        },
        "CFBundleShortVersionString": "6.2.55",
        "CFBundleVersion": "862",
        "UISupportsDocumentBrowser": False,
    }
    for key, value in expected.items():
        actual = plist.get(key)
        matches = actual in value if isinstance(value, set) else actual == value
        if not matches:
            raise RuntimeError(
                f"source Info.plist {key} mismatch: "
                f"expected {value!r}, found {actual!r}"
            )
    if not isinstance(plist.get("LSSupportsOpeningDocumentsInPlace"), bool):
        raise RuntimeError(
            "source Info.plist LSSupportsOpeningDocumentsInPlace must be boolean"
        )
    if plist.get("CFBundleDocumentTypes") != stable.EXPECTED_DOCUMENT_TYPES:
        raise RuntimeError("source document registration changed")
    if plist.get("UTExportedTypeDeclarations") != stable.EXPECTED_EXPORTED_TYPES:
        raise RuntimeError("source exported UTI registration changed")
    return plist


def verify_output_info(data):
    plist = plistlib.loads(data)
    expected = {
        "CFBundleDisplayName": EXPECTED_DISPLAY_NAME,
        "CFBundleName": EXPECTED_DISPLAY_NAME,
        "CFBundleExecutable": "AlightMotion",
        "CFBundleIdentifier": EXPECTED_BUNDLE_IDENTIFIER,
        "CFBundleShortVersionString": "6.2.55",
        "CFBundleVersion": "862",
        "LSSupportsOpeningDocumentsInPlace": False,
        "UISupportsDocumentBrowser": False,
    }
    for key, value in expected.items():
        if plist.get(key) != value:
            raise RuntimeError(
                f"output Info.plist {key} mismatch: "
                f"expected {value!r}, found {plist.get(key)!r}"
            )
    if plist.get("CFBundleDocumentTypes") != stable.EXPECTED_DOCUMENT_TYPES:
        raise RuntimeError("output document registration changed")
    if plist.get("UTExportedTypeDeclarations") != stable.EXPECTED_EXPORTED_TYPES:
        raise RuntimeError("output exported UTI registration changed")
    return plist


def prepare_output_info(data):
    plist = _verify_source_info(data)
    plist["CFBundleDisplayName"] = EXPECTED_DISPLAY_NAME
    plist["CFBundleName"] = EXPECTED_DISPLAY_NAME
    plist["CFBundleIdentifier"] = EXPECTED_BUNDLE_IDENTIFIER
    # Match the proven v40/v42 delivery contract.  Copy-in gives QQ/Files a
    # stable Documents/Inbox URL instead of a short-lived provider grant.
    plist["LSSupportsOpeningDocumentsInPlace"] = False
    result = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False)
    verify_output_info(result)
    return result


def _custom_loads(data, label):
    uuids, dylibs = handoff._uuid_and_dylib_commands(data, label)
    enhancer = [item for item in dylibs if item["name"] == handoff.AMENHANCER_LOAD]
    cloud = [
        item
        for item in dylibs
        if item["name"] in {
            handoff.CLOUD_LOAD,
            CLOUD_LOAD_LCSIGN,
            CLOUD_LOAD_COMPACT,
        }
    ]
    loader = [item for item in dylibs if item["name"] == handoff.LOADCONTROL_LOAD]
    return uuids, enhancer, cloud, loader


def _rpaths(data, label):
    macho = handoff._thin_macho(data, label)
    endian, commands = stable._macho_load_commands(macho)
    result = []
    for command, offset, size in commands:
        if command != LC_RPATH:
            continue
        if size < 12:
            raise RuntimeError(f"{label} has a truncated LC_RPATH command")
        path_offset = struct.unpack_from(endian + "I", macho, offset + 8)[0]
        if path_offset < 12 or path_offset >= size:
            raise RuntimeError(f"{label} LC_RPATH path is out of bounds")
        raw_path = macho[offset + path_offset : offset + size]
        terminator = raw_path.find(b"\0")
        if terminator < 0:
            raise RuntimeError(f"{label} LC_RPATH path is not terminated")
        result.append(raw_path[:terminator].decode("utf-8", errors="strict"))
    return result


def _require_frameworks_rpath(data, label):
    if FRAMEWORKS_RPATH not in _rpaths(data, label):
        raise RuntimeError(
            f"{label} compact Cloud load requires LC_RPATH {FRAMEWORKS_RPATH}"
        )


def _cloud_member_path(load_name):
    if load_name == CLOUD_LOAD_LCSIGN:
        return CLOUD_PATH_LCSIGN
    if load_name in {handoff.CLOUD_LOAD, CLOUD_LOAD_COMPACT}:
        return CLOUD_PATH
    raise RuntimeError(f"unsupported Cloud load path: {load_name}")


def verify_input_main(data):
    actual_hash = sha256_bytes(data)
    if EXPECTED_INPUT_MAIN_SHA256 and actual_hash != EXPECTED_INPUT_MAIN_SHA256:
        raise RuntimeError(
            "source main executable changed: "
            f"expected {EXPECTED_INPUT_MAIN_SHA256}, found {actual_hash}"
        )
    uuids, enhancer, cloud, loader = _custom_loads(data, "source main executable")
    if uuids != [handoff.EXPECTED_MAIN_UUID]:
        raise RuntimeError("source main UUID changed")
    if len(enhancer) != 1 or enhancer[0]["command"] != handoff.LC_LOAD_WEAK_DYLIB:
        raise RuntimeError("source main changed the AmEnhancer load")
    if cloud:
        raise RuntimeError("source main unexpectedly already loads Cloud")
    if len(loader) != 1 or loader[0]["command"] not in {
        handoff.LC_LOAD_DYLIB,
        handoff.LC_LOAD_WEAK_DYLIB,
    }:
        raise RuntimeError("source main must load one LoadControl dylib")
    full_replacement = handoff.CLOUD_LOAD.encode("utf-8") + b"\0"
    lcsign_replacement = CLOUD_LOAD_LCSIGN.encode("utf-8") + b"\0"
    capacity = loader[0]["size"] - loader[0]["name_offset"]
    if len(full_replacement) > capacity and len(lcsign_replacement) > capacity:
        _require_frameworks_rpath(data, "source main executable")
    return loader[0]


def _verify_output_main_structure(data, require_home_ui=False):
    uuids, enhancer, cloud, loader = _custom_loads(data, "direct-Cloud main")
    if uuids != [handoff.EXPECTED_MAIN_UUID]:
        raise RuntimeError("direct-Cloud main UUID changed")
    if len(enhancer) != 1 or enhancer[0]["command"] != handoff.LC_LOAD_WEAK_DYLIB:
        raise RuntimeError("direct-Cloud main changed the AmEnhancer load")
    if len(cloud) != 1 or cloud[0]["command"] != handoff.LC_LOAD_DYLIB:
        raise RuntimeError("main must strongly load one AMProjExportCloud dylib")
    if loader:
        raise RuntimeError("direct-Cloud main must not load LoadControl")
    if cloud[0]["name"] == CLOUD_LOAD_COMPACT:
        _require_frameworks_rpath(data, "direct-Cloud main")
    info = inject_dylib.parse_macho_data(data, "direct-Cloud main")
    home_loads = homeui.home_ui_loads(info)
    if len(home_loads) > 1:
        raise RuntimeError("main executable contains duplicate AMHomeUI loads")
    if home_loads:
        homeui.ensure_home_ui_load_contract(info, "direct-Cloud main")
    elif require_home_ui:
        raise RuntimeError("direct-Cloud main must strongly load AMHomeUI")
    return cloud[0]


def verify_resign_ready_main(data, require_home_ui=False):
    actual_hash = sha256_bytes(data)
    if EXPECTED_OUTPUT_MAIN_SHA256 and actual_hash != EXPECTED_OUTPUT_MAIN_SHA256:
        raise RuntimeError(
            "direct-Cloud main mismatch: "
            f"expected {EXPECTED_OUTPUT_MAIN_SHA256}, found {actual_hash}"
        )
    result = _verify_output_main_structure(data, require_home_ui=require_home_ui)
    _verify_nonempty_signature_container(data, "AlightMotion")
    return result


def _verify_nonempty_signature_container(data, label):
    _endian, _command, data_offset, data_size = handoff._code_signature_fields(
        data, label
    )
    if data_size <= 0 or data_offset + data_size != len(data):
        raise RuntimeError(
            f"{label} must retain a non-empty signature region for LCSign"
        )


def patch_main_direct_cloud(data, require_home_ui=False):
    try:
        target = verify_input_main(data)
    except RuntimeError as input_error:
        # A previously generated direct-Cloud IPA is a valid source too.  It
        # already has the desired load command, so only the Cloud member needs
        # replacement and re-signing.
        try:
            _verify_output_main_structure(data, require_home_ui=False)
            _verify_nonempty_signature_container(data, "AlightMotion")
        except RuntimeError:
            raise input_error
        result = data
        if require_home_ui:
            info = inject_dylib.parse_macho_data(result, "AlightMotion")
            if not homeui.home_ui_loads(info):
                result = homeui.patch_main_with_home_ui(result, "AlightMotion")
        verify_resign_ready_main(result, require_home_ui=require_home_ui)
        return result
    capacity = target["size"] - target["name_offset"]
    full_replacement = handoff.CLOUD_LOAD.encode("utf-8") + b"\0"
    lcsign_replacement = CLOUD_LOAD_LCSIGN.encode("utf-8") + b"\0"
    compact_replacement = CLOUD_LOAD_COMPACT.encode("utf-8") + b"\0"
    replacement = (
        full_replacement if len(full_replacement) <= capacity
        else lcsign_replacement if len(lcsign_replacement) <= capacity
        else compact_replacement
    )
    if len(replacement) > capacity:
        raise RuntimeError("Cloud path does not fit the existing loader command")

    patched = bytearray(data)
    command_start = target["offset"]
    struct.pack_into("<I", patched, command_start, handoff.LC_LOAD_DYLIB)
    name_start = target["offset"] + target["name_offset"]
    name_end = target["offset"] + target["size"]
    patched[name_start:name_end] = replacement + bytes(capacity - len(replacement))
    changed = {
        index
        for index, (before, after) in enumerate(zip(data, patched))
        if before != after
    }
    allowed = set(range(command_start, command_start + 4)) | set(
        range(name_start, name_end)
    )
    if not changed or not changed <= allowed:
        raise RuntimeError(
            "direct-Cloud patch changed bytes outside the command type and dylib path"
        )

    # LCSign recognizes the existing non-empty signature command and replaces
    # its blob.  A zero-sized placeholder is silently skipped by LCSign.
    result = bytes(patched)
    if require_home_ui:
        result = homeui.patch_main_with_home_ui(result, "AlightMotion")
    verify_resign_ready_main(result, require_home_ui=require_home_ui)
    return result


def prepare_cloud(data):
    verify_cloud_runtime_version(data)
    verify_cloud_stability_contract(data)
    # The Cloud image is intentionally independent from the Home UI image.
    # Keep this check in the common direct packager so legacy entry points
    # cannot accidentally reintroduce the old linked/embedded runtime.
    homeui.verify_cloud_payload(data, "AMProjExportCloud.dylib")
    actual_hash = sha256_bytes(data)
    if EXPECTED_INPUT_CLOUD_SHA256 and actual_hash != EXPECTED_INPUT_CLOUD_SHA256:
        raise RuntimeError(
            "source Cloud changed: "
            f"expected {EXPECTED_INPUT_CLOUD_SHA256}, found {actual_hash}"
        )
    # Cloud has no signature command in the verified source.  LCSign adds and
    # fills it during the recursive pass; pre-seeding an empty command makes it
    # skip this dylib.
    result = data
    actual_output_hash = sha256_bytes(result)
    if EXPECTED_OUTPUT_CLOUD_SHA256 and actual_output_hash != EXPECTED_OUTPUT_CLOUD_SHA256:
        raise RuntimeError(
            "resign-ready Cloud mismatch: "
            f"expected {EXPECTED_OUTPUT_CLOUD_SHA256}, found {actual_output_hash}"
        )
    try:
        handoff._code_signature_fields(result, "AMProjExportCloud.dylib")
    except RuntimeError as error:
        if "must contain one LC_CODE_SIGNATURE" not in str(error):
            raise
    else:
        raise RuntimeError("resign-ready Cloud must not contain an empty signature command")
    return result


def _copy_zip_info(info, *, executable=None):
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
    if executable is None:
        clone.external_attr = info.external_attr
    else:
        clone.external_attr = (0o100755 if executable else 0o100644) << 16
    return clone


def verify_resign_ready_ipa(
    source_path,
    output_path,
    info,
    main,
    cloud,
    enhancer,
    home_ui=None,
):
    verify_cloud_runtime_version(cloud)
    require_home_ui = home_ui is not None
    cloud_load = _verify_output_main_structure(main, require_home_ui=require_home_ui)
    output_cloud_path = _cloud_member_path(cloud_load["name"])
    with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
        output_path, "r"
    ) as output:
        source_names = source.namelist()
        output_names = output.namelist()
        if len(output_names) != len(set(output_names)):
            raise RuntimeError("output IPA contains duplicate ZIP entries")
        bad_entry = handoff._first_bad_file_crc(output)
        if bad_entry is not None:
            raise RuntimeError(f"output IPA CRC failed for {bad_entry}")
        expected_names = {
            name
            for name in source_names
            if not handoff._is_stale_signing_entry(name)
            and name != LOADCONTROL_PATH
            and name not in CLOUD_MEMBER_PATHS
        }
        expected_names.add(output_cloud_path)
        if home_ui is not None:
            expected_names.add(HOME_UI_PATH)
        if set(output_names) != expected_names:
            raise RuntimeError("output IPA member set changed unexpectedly")
        if LOADCONTROL_PATH in output_names:
            raise RuntimeError("output IPA still contains LoadControl")
        if home_ui is not None:
            if output_names.count(HOME_UI_PATH) != 1:
                raise RuntimeError("output IPA must contain one standalone AMHomeUI")
            if output.read(HOME_UI_PATH) != home_ui:
                raise RuntimeError("output Home UI differs from prepared Home UI")
        elif HOME_UI_PATH in output_names:
            raise RuntimeError(
                "output IPA contains AMHomeUI but no standalone Home UI payload was supplied"
            )
        if output.read(INFO_PLIST) != info:
            raise RuntimeError("output Info.plist differs from prepared identity")
        verify_output_info(info)
        if output.read(MAIN_EXECUTABLE) != main:
            raise RuntimeError("output main differs from direct-Cloud main")
        verify_resign_ready_main(main)
        if output.read(AMENHANCER_PATH) != enhancer:
            raise RuntimeError("output AmEnhancer differs from the label-only patch")
        if AMENHANCER_STATUS_LABEL in enhancer:
            raise RuntimeError("output AmEnhancer still contains the v59 status label")
        if output_names.count(output_cloud_path) != 1:
            raise RuntimeError("output IPA must contain one active Cloud member")
        if any(
            path in output_names
            for path in CLOUD_MEMBER_PATHS
            if path != output_cloud_path
        ):
            raise RuntimeError("output IPA contains a stale Cloud member")
        if output.read(output_cloud_path) != cloud:
            raise RuntimeError("output Cloud differs from prepared Cloud")
        try:
            handoff._code_signature_fields(cloud, "AMProjExportCloud.dylib")
        except RuntimeError as error:
            if "must contain one LC_CODE_SIGNATURE" not in str(error):
                raise
        else:
            raise RuntimeError(
                "resign-ready Cloud must not contain an empty signature command"
            )

        changed = {
            INFO_PLIST,
            MAIN_EXECUTABLE,
            AMENHANCER_PATH,
            LOADCONTROL_PATH,
            *CLOUD_MEMBER_PATHS,
        }
        if home_ui is not None:
            changed.add(HOME_UI_PATH)
        for name in expected_names - changed:
            source_info = source.getinfo(name)
            if source_info.is_dir():
                continue
            if stable._zip_member_sha256(source, name) != stable._zip_member_sha256(
                output, name
            ):
                raise RuntimeError(f"output changed an unrelated member: {name}")
    return {
        "entry_count": len(output_names),
        "main_sha256": sha256_bytes(main),
        "cloud_sha256": sha256_bytes(cloud),
        "amenhancer_sha256": sha256_bytes(enhancer),
        "cloud_member": output_cloud_path,
        "v59_status_label_removed": True,
        "loadcontrol_removed": True,
    }


def build_direct_package(source_path, output_path, cloud_path=None, home_ui_path=None):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    if source_path == output_path:
        raise RuntimeError("output must differ from the source IPA")
    source_bytes = source_path.read_bytes()
    actual_input_hash = sha256_bytes(source_bytes)
    if EXPECTED_INPUT_SHA256 and actual_input_hash != EXPECTED_INPUT_SHA256:
        raise RuntimeError(
            "user-base IPA mismatch: "
            f"expected {EXPECTED_INPUT_SHA256}, found {actual_input_hash}"
        )

    with zipfile.ZipFile(source_path, "r") as source:
        names = source.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError("source IPA contains duplicate ZIP entries")
        bad_entry = handoff._first_bad_file_crc(source)
        if bad_entry is not None:
            raise RuntimeError(f"source IPA CRC failed for {bad_entry}")
        required = (
            INFO_PLIST,
            MAIN_EXECUTABLE,
            AMENHANCER_PATH,
            CYDIA_SUBSTRATE_PATH,
        )
        if any(names.count(path) != 1 for path in required):
            raise RuntimeError("source IPA has an unexpected app layout")
        source_cloud_paths = [
            path for path in CLOUD_MEMBER_PATHS if names.count(path) == 1
        ]
        has_cloud = len(source_cloud_paths) == 1
        has_loadcontrol = names.count(LOADCONTROL_PATH) == 1
        if not has_cloud and not has_loadcontrol:
            raise RuntimeError("source IPA must contain Cloud or LoadControl")
        if (
            len(source_cloud_paths) > 1
            or any(names.count(path) > 1 for path in CLOUD_MEMBER_PATHS)
            or names.count(LOADCONTROL_PATH) > 1
            or names.count(HOME_UI_PATH) > 1
        ):
            raise RuntimeError("source IPA contains duplicate loader members")
        source_home_ui_present = names.count(HOME_UI_PATH) == 1
        supplied_home_ui = (
            Path(home_ui_path).resolve().read_bytes() if home_ui_path else None
        )
        if supplied_home_ui is not None:
            homeui.verify_home_ui_payload(home_ui_path, supplied_home_ui)
        elif source_home_ui_present:
            supplied_home_ui = source.read(HOME_UI_PATH)
            homeui.verify_home_ui_payload(HOME_UI_PATH, supplied_home_ui)
        info = prepare_output_info(source.read(INFO_PLIST))
        source_main = source.read(MAIN_EXECUTABLE)
        source_main_info = inject_dylib.parse_macho_data(
            source_main, "source AlightMotion executable"
        )
        if homeui.home_ui_loads(source_main_info) and supplied_home_ui is None:
            raise RuntimeError(
                "source main loads AMHomeUI but the standalone Home UI member is missing"
            )
        main = patch_main_direct_cloud(
            source_main, require_home_ui=supplied_home_ui is not None
        )
        cloud_source = Path(cloud_path).resolve().read_bytes() if cloud_path else (
            source.read(source_cloud_paths[0]) if has_cloud else None
        )
        if cloud_source is None:
            raise RuntimeError(
                "a freshly built v44 AMProjExportCloud.dylib is required when the source has only LoadControl"
            )
        cloud = prepare_cloud(cloud_source)
        cloud_load = _verify_output_main_structure(
            main, require_home_ui=supplied_home_ui is not None
        )
        output_cloud_path = _cloud_member_path(cloud_load["name"])
        source_amenhancer = source.read(AMENHANCER_PATH)
        if EXPECTED_AMENHANCER_SHA256 and sha256_bytes(source_amenhancer) != EXPECTED_AMENHANCER_SHA256:
            raise RuntimeError("source AmEnhancer changed")
        enhancer = prepare_amenhancer(source_amenhancer)
        if (
            EXPECTED_CYDIA_SUBSTRATE_SHA256
            and
            sha256_bytes(source.read(CYDIA_SUBSTRATE_PATH))
            != EXPECTED_CYDIA_SUBSTRATE_SHA256
        ):
            raise RuntimeError("source CydiaSubstrate changed")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".build-", dir=output_path.parent
    ) as temporary_directory:
        candidate = Path(temporary_directory) / "resign-ready.ipa"
        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "w", allowZip64=True
        ) as output:
            for zip_info in source.infolist():
                name = zip_info.filename
                if handoff._is_stale_signing_entry(name) or name == LOADCONTROL_PATH:
                    continue
                payload = b"" if zip_info.is_dir() else source.read(zip_info)
                if name == INFO_PLIST:
                    payload = info
                elif name == MAIN_EXECUTABLE:
                    payload = main
                elif name == AMENHANCER_PATH:
                    payload = enhancer
                elif name in CLOUD_MEMBER_PATHS:
                    continue
                elif name == HOME_UI_PATH and supplied_home_ui is not None:
                    payload = supplied_home_ui
                output.writestr(
                    _copy_zip_info(
                        zip_info,
                        executable=(name == HOME_UI_PATH)
                        if supplied_home_ui is not None
                        else None,
                    ),
                    payload,
                )
            output.writestr(
                _copy_zip_info(
                    zipfile.ZipInfo(
                        output_cloud_path, date_time=(1980, 1, 1, 0, 0, 0)
                    )
                ),
                cloud,
            )
            if supplied_home_ui is not None and HOME_UI_PATH not in names:
                home_ui_info = zipfile.ZipInfo(
                    HOME_UI_PATH, date_time=(1980, 1, 1, 0, 0, 0)
                )
                home_ui_info.compress_type = zipfile.ZIP_DEFLATED
                home_ui_info.create_system = 3
                home_ui_info.external_attr = 0o100755 << 16
                output.writestr(
                    home_ui_info,
                    supplied_home_ui,
                )

        verification = verify_resign_ready_ipa(
            source_path,
            candidate,
            info=info,
            main=main,
            cloud=cloud,
            enhancer=enhancer,
            home_ui=supplied_home_ui,
        )
        os.replace(candidate, output_path)

    return {
        "input_sha256": actual_input_hash,
        **verification,
        "output_sha256": sha256_bytes(output_path.read_bytes()),
        "output": str(output_path),
        "home_ui_sha256": (
            sha256_bytes(supplied_home_ui) if supplied_home_ui is not None else None
        ),
        "home_ui_member": HOME_UI_PATH if supplied_home_ui is not None else None,
        "requires_recursive_real_signing": True,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the single direct-Cloud 6.2.55 LCSign handoff IPA"
    )
    parser.add_argument("source", help="verified own-base v74 IPA")
    parser.add_argument("output", help="single resign-ready output IPA")
    parser.add_argument(
        "--cloud",
        dest="cloud",
        help="fresh v44 AMProjExportCloud.dylib from the macOS build",
    )
    parser.add_argument(
        "--home-ui",
        dest="home_ui",
        help="standalone AMHomeUI.dylib from the macOS build",
    )
    args = parser.parse_args(argv)
    result = build_direct_package(
        args.source,
        args.output,
        cloud_path=args.cloud,
        home_ui_path=args.home_ui,
    )
    for key, value in result.items():
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
