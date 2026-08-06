#!/usr/bin/env python3
"""Build the user's 6.2.55 (862) LoadControl handoff package.

The base is the verified am_v73 IPA. Its name, bundle identifier, resources,
AmEnhancer, CydiaSubstrate, and AMProj implementation are retained. The only
main-executable change replaces the direct weak AMProj load command in-place
with a required LoadControl load. LoadControl then discovers the AMProj plugin
in Frameworks. The output contains explicit empty signature markers and must
be recursively signed by LCSign before installation.
"""

import argparse
import hashlib
import os
import plistlib
import struct
import tempfile
import zipfile
from pathlib import Path

import build_862_stable_package as stable


EXPECTED_BASE_SHA256 = (
    "44cb7fbfb7ae17598d96ddfab960f015792d4b4eae277eb3d0807191de810dd6"
)
EXPECTED_BASE_MAIN_SHA256 = (
    "a76efc2bffc8f7e0925fa7c0fbb51c7a78dcce66327074a43e5e3f33667053d9"
)
EXPECTED_OUTPUT_MAIN_SHA256 = (
    "f500e3a92312d0373e7f522705c3fde96b0863bc9b7e5d9cd023e77af436164d"
)
EXPECTED_BASE_CLOUD_SHA256 = (
    "623cc390f736ba90d3c4c69ad1529716142f3b8bda0ea47edc029e0caaad9edb"
)
EXPECTED_CLOUD_SOURCE_IPA_SHA256 = stable.EXPECTED_INPUT_SHA256
EXPECTED_CLOUD_SOURCE_SHA256 = stable.EXPECTED_DYLIB_SHA256
EXPECTED_OUTPUT_CLOUD_SHA256 = stable.EXPECTED_PATCHED_DYLIB_SHA256
EXPECTED_LOADCONTROL_SHA256 = (
    "1227f0dcd777651f5f6595eff1259fe35eca0a2cc5e30e13747163df4c99ed6a"
)
EXPECTED_AMENHANCER_SHA256 = (
    "da014f018d5b9ab59b7d810e93ac9353088d81336c7cd2b2d012622a90ceb12c"
)
EXPECTED_CYDIA_SUBSTRATE_SHA256 = (
    "5d1e2b39f4a0f23feb6e2f1e82408943b307ea11b4073b33a2b072ec4f69e8bd"
)

# The binary base remains the user's verified 6.2.55 build. These are the
# identity values written into the handoff package before recursive signing.
EXPECTED_OUTPUT_DISPLAY_NAME = "猫鹤AM"
EXPECTED_OUTPUT_BUNDLE_IDENTIFIER = "com.ayakameow.am"

APP_ROOT = "Payload/AlightMotion.app/"
INFO_PLIST = APP_ROOT + "Info.plist"
MAIN_EXECUTABLE = APP_ROOT + "AlightMotion"
CLOUD_PATH = APP_ROOT + "Frameworks/AMProjExportCloud.dylib"
LOADCONTROL_PATH = APP_ROOT + "Frameworks/LoadControl.dylib"
AMENHANCER_PATH = APP_ROOT + "Frameworks/AmEnhancer.dylib"
CYDIA_SUBSTRATE_PATH = (
    APP_ROOT + "Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
)
EMBEDDED_PROFILE = APP_ROOT + "embedded.mobileprovision"

EXPECTED_MAIN_UUID = bytes.fromhex("01b730171a6e3b178f59c27462dea563")
AMENHANCER_LOAD = "@executable_path/Frameworks/AmEnhancer.dylib"
CLOUD_LOAD = "@executable_path/Frameworks/AMProjExportCloud.dylib"
LOADCONTROL_LOAD = "@executable_path/Frameworks/LoadControl.dylib"
CYDIA_SUBSTRATE_LOAD = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"

LC_LOAD_DYLIB = 0xC
LC_UUID = 0x1B
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_CODE_SIGNATURE = 0x1D
DYLIB_COMMANDS = frozenset({0xC, 0xD, 0x18, 0x1F, 0x20, 0x23})

THIN_MACHO_MAGICS = frozenset(
    {
        b"\xcf\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf",
        b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xce",
    }
)
FAT_MACHO_MAGICS = frozenset(
    {
        b"\xca\xfe\xba\xbe",
        b"\xbe\xba\xfe\xca",
        b"\xca\xfe\ba\xbf",
        b"\xbf\xba\xfe\xca",
    }
)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def _first_bad_file_crc(archive):
    """Validate file payloads while ignoring malformed directory CRC metadata."""
    current_name = None
    try:
        for info in archive.infolist():
            current_name = info.filename
            if info.is_dir():
                continue
            with archive.open(info, "r") as member:
                while member.read(1024 * 1024):
                    pass
    except (zipfile.BadZipFile, EOFError):
        return current_name or "<ZIP directory>"
    return None


def _thin_macho(data, label):
    slices = stable._macho_slices(data)
    if len(slices) != 1:
        raise RuntimeError(f"{label} must be a thin Mach-O")
    return slices[0][1]


def _uuid_and_dylib_commands(data, label):
    macho = _thin_macho(data, label)
    endian, commands = stable._macho_load_commands(macho)
    uuids = []
    dylibs = []
    for command, offset, size in commands:
        if command == LC_UUID:
            if size != 24:
                raise RuntimeError(f"{label} has an invalid LC_UUID")
            uuids.append(macho[offset + 8 : offset + 24])
        if command & 0x7FFFFFFF not in DYLIB_COMMANDS:
            continue
        if size < 24:
            raise RuntimeError(f"{label} has a truncated dylib command")
        name_offset = struct.unpack_from(endian + "I", macho, offset + 8)[0]
        if name_offset < 24 or name_offset >= size:
            raise RuntimeError(f"{label} dylib name is out of bounds")
        raw_name = macho[offset + name_offset : offset + size]
        name = raw_name.split(b"\0", 1)[0].decode("utf-8", errors="strict")
        dylibs.append(
            {
                "command": command,
                "offset": offset,
                "size": size,
                "name_offset": name_offset,
                "name": name,
            }
        )
    return uuids, dylibs


def _code_signature_fields(macho, label):
    """Read an LC_CODE_SIGNATURE without requiring a non-empty blob.

    LCSign only discovers newly staged Mach-O files reliably when the load
    command already exists.  A zero-sized command is therefore used as the
    explicit handoff marker; the signer must fill it before installation.
    """
    endian, commands = stable._macho_load_commands(macho)
    matches = [
        (offset, size)
        for command, offset, size in commands
        if command == LC_CODE_SIGNATURE
    ]
    if len(matches) != 1:
        raise RuntimeError(f"{label} must contain one LC_CODE_SIGNATURE command")
    offset, size = matches[0]
    if size != 16:
        raise RuntimeError(f"{label} has an invalid LC_CODE_SIGNATURE command")
    data_offset, data_size = struct.unpack_from(endian + "II", macho, offset + 8)
    if data_offset > len(macho) or data_offset + data_size > len(macho):
        raise RuntimeError(f"{label} code signature points outside the Mach-O")
    return endian, offset, data_offset, data_size


def _strip_thin_signature(macho, label):
    """Remove an existing signature blob but retain a zero-sized load command."""
    if macho[:4] not in THIN_MACHO_MAGICS:
        return macho
    endian, _command_offset, data_offset, data_size = _code_signature_fields(
        macho, label
    )
    if data_size == 0:
        if data_offset != len(macho):
            raise RuntimeError(f"{label} has an invalid empty signature tail")
        return macho
    if data_offset + data_size != len(macho):
        raise RuntimeError(f"{label} signature is not the final Mach-O data")
    command_offset = _code_signature_fields(macho, label)[1]
    result = bytearray(macho[:data_offset])
    struct.pack_into(endian + "I", result, command_offset + 12, 0)
    return bytes(result)


def _strip_embedded_signatures(data, label):
    """Prepare thin/fat Mach-O bytes for one recursive signing pass."""
    if data[:4] in THIN_MACHO_MAGICS:
        return _strip_thin_signature(data, label)
    if data[:4] not in FAT_MACHO_MAGICS:
        return data

    endian = ">" if data[:4] in {b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"} else "<"
    is_64 = data[:4] in {b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    count = struct.unpack_from(endian + "I", data, 4)[0]
    entry_size = 32 if is_64 else 20
    header_size = 8 + count * entry_size
    if count == 0 or header_size > len(data):
        raise RuntimeError(f"{label} has an invalid fat Mach-O header")

    records = []
    for index in range(count):
        offset = 8 + index * entry_size
        if is_64:
            cpu, subtype, slice_offset, slice_size, align, reserved = struct.unpack_from(
                endian + "IIQQII", data, offset
            )
        else:
            cpu, subtype, slice_offset, slice_size, align = struct.unpack_from(
                endian + "IIIII", data, offset
            )
            reserved = None
        if slice_size == 0 or slice_offset + slice_size > len(data):
            raise RuntimeError(f"{label} fat slice is out of bounds")
        original = data[slice_offset : slice_offset + slice_size]
        prepared = _strip_thin_signature(original, f"{label} slice {index}")
        records.append(
            (cpu, subtype, slice_offset, slice_size, align, reserved, prepared)
        )

    result = bytearray(data)
    last_end = header_size
    for index, (
        cpu,
        subtype,
        slice_offset,
        slice_size,
        align,
        reserved,
        prepared,
    ) in enumerate(records):
        result[slice_offset : slice_offset + len(prepared)] = prepared
        if len(prepared) < slice_size:
            result[slice_offset + len(prepared) : slice_offset + slice_size] = bytes(
                slice_size - len(prepared)
            )
        record_offset = 8 + index * entry_size
        if is_64:
            struct.pack_into(
                endian + "IIQQII",
                result,
                record_offset,
                cpu,
                subtype,
                slice_offset,
                len(prepared),
                align,
                reserved,
            )
        else:
            struct.pack_into(
                endian + "IIIII",
                result,
                record_offset,
                cpu,
                subtype,
                slice_offset,
                len(prepared),
                align,
            )
        last_end = max(last_end, slice_offset + len(prepared))
    return bytes(result[:last_end])


def _add_signature_placeholder(macho, label):
    """Add a zero-sized LC_CODE_SIGNATURE in existing Mach-O header padding."""
    if macho[:4] not in THIN_MACHO_MAGICS:
        return macho
    try:
        _code_signature_fields(macho, label)
        return macho
    except RuntimeError as error:
        if "must contain one LC_CODE_SIGNATURE" not in str(error):
            raise

    endian, header_size = stable._macho_format(macho)
    command_count, command_bytes = struct.unpack_from(endian + "II", macho, 16)
    command_end = header_size + command_bytes
    first_section_offset = None
    offset = header_size
    for _index in range(command_count):
        command, size = struct.unpack_from(endian + "II", macho, offset)
        if command == 0x19 and size >= 72:
            section_count = struct.unpack_from(endian + "I", macho, offset + 64)[0]
            section_start = offset + 72
            section_size = 80
            if section_start + section_count * section_size > offset + size:
                raise RuntimeError(f"{label} has malformed segment sections")
            for section_index in range(section_count):
                section_offset = struct.unpack_from(
                    endian + "I", macho, section_start + section_index * section_size + 48
                )[0]
                if section_offset:
                    first_section_offset = (
                        section_offset
                        if first_section_offset is None
                        else min(first_section_offset, section_offset)
                    )
        offset += size
    if first_section_offset is None or command_end + 16 > first_section_offset:
        raise RuntimeError(f"{label} has no room for LC_CODE_SIGNATURE")
    if any(macho[command_end : command_end + 16]):
        raise RuntimeError(f"{label} load-command padding is not empty")

    data_offset = (len(macho) + 15) & ~15
    result = bytearray(macho)
    if data_offset > len(result):
        result.extend(bytes(data_offset - len(result)))
    result[command_end : command_end + 16] = struct.pack(
        endian + "IIII", LC_CODE_SIGNATURE, 16, data_offset, 0
    )
    struct.pack_into(endian + "I", result, 16, command_count + 1)
    struct.pack_into(endian + "I", result, 20, command_bytes + 16)
    return bytes(result)


def _prepare_for_recursive_signing(data, label, add_placeholder=False):
    prepared = _strip_embedded_signatures(data, label)
    return _add_signature_placeholder(prepared, label) if add_placeholder else prepared


def _verify_empty_signature_marker(data, label):
    """Require the staging marker on real Mach-O data; tolerate test fixtures."""
    if data[:4] not in THIN_MACHO_MAGICS:
        return
    _endian, _offset, data_offset, data_size = _code_signature_fields(
        data, label
    )
    if data_size != 0 or data_offset != len(data):
        raise RuntimeError(f"{label} must have an empty signature at EOF")


def _verify_signed_code_preservation(unsigned, signed, label):
    """Ensure signing changed only the embedded signature blobs."""
    unsigned_slices = stable._macho_slices(unsigned)
    signed_slices = stable._macho_slices(signed)
    if len(unsigned_slices) != len(signed_slices):
        raise RuntimeError(f"{label} changed its Mach-O slice count")
    for index, ((_u_offset, unsigned_macho), (_s_offset, signed_macho)) in enumerate(
        zip(unsigned_slices, signed_slices)
    ):
        try:
            _u_endian, u_command, u_signature_offset, _u_signature_size = (
                _code_signature_fields(unsigned_macho, f"{label} staging slice {index}")
            )
            _s_endian, s_command, s_signature_offset, _s_signature_size = (
                _code_signature_fields(signed_macho, f"{label} signed slice {index}")
            )
        except RuntimeError as error:
            raise RuntimeError(f"{label} signature command preservation failed") from error
        if u_signature_offset != s_signature_offset or s_signature_offset > len(signed_macho):
            raise RuntimeError(f"{label} changed its pre-signature boundary")
        unsigned_prefix = bytearray(unsigned_macho[:u_signature_offset])
        signed_prefix = bytearray(signed_macho[:s_signature_offset])
        for prefix, command in ((unsigned_prefix, u_command), (signed_prefix, s_command)):
            prefix[command + 12 : command + 16] = bytes(4)
        if unsigned_prefix != signed_prefix:
            raise RuntimeError(f"{label} changed code or load commands outside its signature")


def _signed_code_directory_summary(macho, label):
    """Validate signed code-page hashes and return the signer identity fields."""
    try:
        _command_offset, signature_offset, signature_size = stable._code_signature_command(
            macho
        )
    except (RuntimeError, IndexError) as error:
        raise RuntimeError(f"{label} has no usable code signature") from error
    signature = macho[signature_offset : signature_offset + signature_size]
    if len(signature) < 12:
        raise RuntimeError(f"{label} has a truncated embedded signature")
    magic, length, count = struct.unpack_from(">III", signature, 0)
    if magic != 0xFADE0CC0 or length > len(signature) or 12 + count * 8 > length:
        raise RuntimeError(f"{label} has an invalid embedded signature")
    entries = [
        struct.unpack_from(">II", signature, 12 + index * 8)
        for index in range(count)
    ]
    primary = [offset for entry_type, offset in entries if entry_type == 0]
    if len(primary) != 1:
        raise RuntimeError(f"{label} must contain one primary CodeDirectory")
    cd_offset = primary[0]
    if cd_offset + 44 > length:
        raise RuntimeError(f"{label} CodeDirectory is truncated")
    code_directory = signature[cd_offset:]
    (
        cd_magic,
        cd_length,
        version,
        flags,
        hash_offset,
        identifier_offset,
        special_slots,
        code_slots,
        code_limit,
    ) = struct.unpack_from(">9I", code_directory, 0)
    if cd_magic != 0xFADE0C02 or cd_length < 44 or cd_offset + cd_length > length:
        raise RuntimeError(f"{label} has an invalid CodeDirectory")
    code_directory = code_directory[:cd_length]
    hash_size, hash_type, _platform, page_shift = struct.unpack_from(
        ">4B", code_directory, 36
    )
    if code_limit == 0 and version >= 0x20300:
        if len(code_directory) < 64:
            raise RuntimeError(f"{label} CodeDirectory is missing codeLimit64")
        code_limit = struct.unpack_from(">Q", code_directory, 56)[0]
    if code_limit != signature_offset or hash_size == 0 or page_shift > 30:
        raise RuntimeError(f"{label} CodeDirectory coverage is invalid")
    page_size = 1 << page_shift
    expected_slots = (code_limit + page_size - 1) // page_size
    if code_slots != expected_slots or hash_offset + code_slots * hash_size > cd_length:
        raise RuntimeError(f"{label} CodeDirectory slot count is invalid")
    algorithms = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}
    try:
        algorithm = algorithms[hash_type]
    except KeyError as error:
        raise RuntimeError(f"{label} uses an unsupported CodeDirectory hash") from error
    for index in range(code_slots):
        start = index * page_size
        end = min(start + page_size, code_limit)
        expected = hashlib.new(algorithm, macho[start:end]).digest()[:hash_size]
        actual_start = hash_offset + index * hash_size
        if code_directory[actual_start : actual_start + hash_size] != expected:
            raise RuntimeError(f"{label} CodeDirectory code slot {index} mismatch")
    identifier_end = code_directory.find(b"\0", identifier_offset)
    identifier = code_directory[identifier_offset:identifier_end].decode(
        "utf-8", errors="replace"
    )
    team = ""
    if version >= 0x20200 and len(code_directory) >= 52:
        team_offset = struct.unpack_from(">I", code_directory, 48)[0]
        if team_offset:
            team_end = code_directory.find(b"\0", team_offset)
            team = code_directory[team_offset:team_end].decode("utf-8", errors="replace")
    return {
        "identifier": identifier,
        "team": team,
        "has_cms": 0x10000 in {entry_type for entry_type, _offset in entries},
        "flags": flags,
    }


def _signed_profile_plist(data, label):
    """Extract the XML plist payload from an embedded provisioning profile."""
    start = data.find(b"<?xml")
    end_marker = b"</plist>"
    end = data.find(end_marker, start)
    if start < 0 or end < 0:
        raise RuntimeError(f"{label} has no readable provisioning plist")
    try:
        return plistlib.loads(data[start : end + len(end_marker)])
    except (plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError(f"{label} provisioning plist is invalid") from error


def _verify_signed_profile(data, teams, bundle_identifier):
    """Check that a supplied profile belongs to the signed app identity."""
    profile = _signed_profile_plist(data, "embedded.mobileprovision")
    entitlements = profile.get("Entitlements") or {}
    profile_teams = profile.get("TeamIdentifier") or []
    profile_team = entitlements.get("com.apple.developer.team-identifier")
    if not profile_teams and profile_team:
        profile_teams = [profile_team]
    if teams and not set(profile_teams).intersection(teams):
        raise RuntimeError(
            "embedded.mobileprovision Team ID does not match signed Mach-O"
        )
    application_identifier = entitlements.get("application-identifier")
    if application_identifier and profile_teams:
        expected = f"{profile_teams[0]}.{bundle_identifier}"
        wildcard = f"{profile_teams[0]}.*"
        if application_identifier not in {expected, wildcard}:
            raise RuntimeError(
                "embedded.mobileprovision App ID does not match the output Bundle ID: "
                f"{application_identifier!r}"
            )
    devices = profile.get("ProvisionedDevices")
    return {
        "name": profile.get("Name"),
        "team": profile_teams[0] if profile_teams else "",
        "application_identifier": application_identifier,
        "provisioned_device_count": len(devices) if isinstance(devices, list) else None,
        "expiration": profile.get("ExpirationDate"),
    }


def verify_signed_loadcontrol_ipa(staging_path, signed_path):
    """Reject an IPA whose recursive signing pass skipped any injected code."""
    staging_path = Path(staging_path).resolve()
    signed_path = Path(signed_path).resolve()
    with zipfile.ZipFile(staging_path, "r") as staging, zipfile.ZipFile(
        signed_path, "r"
    ) as signed:
        if signed.testzip() is not None:
            raise RuntimeError("signed IPA failed ZIP CRC validation")
        staging_names = set(staging.namelist())
        signed_names = set(signed.namelist())
        if not staging_names <= signed_names:
            raise RuntimeError("signed IPA removed staging members")
        allowed_additions = {
            name
            for name in signed_names - staging_names
            if _is_stale_signing_entry(name)
        }
        if signed_names - staging_names != allowed_additions:
            unexpected = sorted((signed_names - staging_names) - allowed_additions)
            raise RuntimeError(f"signed IPA added unexpected members: {unexpected}")

        expected_info = staging.read(INFO_PLIST)
        if signed.read(INFO_PLIST) != expected_info:
            raise RuntimeError("signed IPA changed the user's Info.plist")
        verify_info_plist(expected_info)

        staging_macho_paths = stable._macho_paths(staging)
        for name in sorted(staging_names - staging_macho_paths):
            if name == INFO_PLIST or _is_stale_signing_entry(name):
                continue
            if signed.read(name) != staging.read(name):
                raise RuntimeError(f"signed IPA changed an unrelated member: {name}")

        teams = set()
        signature_summary = {}
        for path in sorted(staging_macho_paths):
            if path not in signed_names:
                raise RuntimeError(f"signed IPA removed Mach-O member: {path}")
            _verify_signed_code_preservation(
                staging.read(path), signed.read(path), path
            )
            signed_data = signed.read(path)
            summaries = []
            for index, (_offset, macho) in enumerate(stable._macho_slices(signed_data)):
                summary = _signed_code_directory_summary(
                    macho, f"{path} slice {index}"
                )
                summaries.append(summary)
                if summary["team"]:
                    teams.add(summary["team"])
            signature_summary[path] = summaries

        if "4KQ5JXJ558" in teams:
            raise RuntimeError("signed IPA still contains the old LoadControl Team ID")
        if len(teams) > 1:
            raise RuntimeError(f"signed IPA contains multiple Team IDs: {sorted(teams)}")
        for path in (MAIN_EXECUTABLE, CLOUD_PATH, LOADCONTROL_PATH):
            if path not in signature_summary:
                raise RuntimeError(f"signed IPA is missing required Mach-O: {path}")
        main_identifiers = {
            item["identifier"] for item in signature_summary[MAIN_EXECUTABLE]
        }
        if main_identifiers != {EXPECTED_OUTPUT_BUNDLE_IDENTIFIER}:
            raise RuntimeError(
                "signed main CodeDirectory identifier does not match output Bundle ID: "
                f"{sorted(main_identifiers)}"
            )
        _verify_output_main_structure(signed.read(MAIN_EXECUTABLE))
        stable.verify_stability_hotfixes(signed.read(CLOUD_PATH))
        profile_summary = None
        if EMBEDDED_PROFILE in signed_names:
            profile_summary = _verify_signed_profile(
                signed.read(EMBEDDED_PROFILE),
                teams,
                EXPECTED_OUTPUT_BUNDLE_IDENTIFIER,
            )
        return {
            "teams": sorted(teams),
            "signed_macho_count": len(signature_summary),
            "signed_slice_count": sum(len(items) for items in signature_summary.values()),
            "profile": profile_summary,
            "output": str(signed_path),
        }


def verify_base_main(data):
    actual_hash = sha256_bytes(data)
    if actual_hash != EXPECTED_BASE_MAIN_SHA256:
        raise RuntimeError(
            "am_v73 main executable changed: "
            f"expected {EXPECTED_BASE_MAIN_SHA256}, found {actual_hash}"
        )
    uuids, dylibs = _uuid_and_dylib_commands(data, "am_v73 main executable")
    if uuids != [EXPECTED_MAIN_UUID]:
        raise RuntimeError("am_v73 main UUID changed")
    enhancer = [item for item in dylibs if item["name"] == AMENHANCER_LOAD]
    cloud = [item for item in dylibs if item["name"] == CLOUD_LOAD]
    loader = [item for item in dylibs if item["name"] == LOADCONTROL_LOAD]
    if len(enhancer) != 1 or enhancer[0]["command"] != LC_LOAD_WEAK_DYLIB:
        raise RuntimeError("am_v73 must retain one AmEnhancer weak load")
    if len(cloud) != 1 or cloud[0]["command"] != LC_LOAD_WEAK_DYLIB:
        raise RuntimeError("am_v73 must contain one direct AMProj weak load")
    if loader:
        raise RuntimeError("am_v73 unexpectedly already loads LoadControl")
    return cloud[0]


def verify_output_main(data):
    actual_hash = sha256_bytes(data)
    if actual_hash != EXPECTED_OUTPUT_MAIN_SHA256:
        raise RuntimeError(
            "patched main executable mismatch: "
            f"expected {EXPECTED_OUTPUT_MAIN_SHA256}, found {actual_hash}"
        )
    return _verify_output_main_structure(data)


def _verify_output_main_structure(data):
    uuids, dylibs = _uuid_and_dylib_commands(data, "patched main executable")
    if uuids != [EXPECTED_MAIN_UUID]:
        raise RuntimeError("patched main UUID changed")
    enhancer = [item for item in dylibs if item["name"] == AMENHANCER_LOAD]
    cloud = [item for item in dylibs if item["name"] == CLOUD_LOAD]
    loader = [item for item in dylibs if item["name"] == LOADCONTROL_LOAD]
    if len(enhancer) != 1 or enhancer[0]["command"] != LC_LOAD_WEAK_DYLIB:
        raise RuntimeError("patched main changed the AmEnhancer load")
    if cloud:
        raise RuntimeError("patched main must not directly load AMProjExportCloud")
    if len(loader) != 1 or loader[0]["command"] != LC_LOAD_DYLIB:
        raise RuntimeError("patched main must strongly load one LoadControl dylib")
    return loader[0]


def verify_resign_ready_main(data):
    """Validate the patched main while allowing its empty signing marker."""
    result = _verify_output_main_structure(data)
    _verify_empty_signature_marker(
        _thin_macho(data, "resign-ready main executable"), "AlightMotion"
    )
    return result


def patch_main_loader(data):
    target = verify_base_main(data)
    replacement = LOADCONTROL_LOAD.encode("utf-8") + b"\0"
    capacity = target["size"] - target["name_offset"]
    if len(replacement) > capacity:
        raise RuntimeError("LoadControl path does not fit the existing AMProj command")

    patched = bytearray(data)
    struct.pack_into("<I", patched, target["offset"], LC_LOAD_DYLIB)
    name_start = target["offset"] + target["name_offset"]
    name_end = target["offset"] + target["size"]
    patched[name_start:name_end] = replacement + bytes(capacity - len(replacement))
    result = bytes(patched)

    changed = {
        index
        for index, (before, after) in enumerate(zip(data, result))
        if before != after
    }
    allowed = set(range(target["offset"], target["offset"] + 4)) | set(
        range(name_start, name_end)
    )
    if not changed or not changed <= allowed:
        raise RuntimeError("main loader patch changed bytes outside its load command")
    verify_output_main(result)
    return result


def verify_info_plist(data):
    plist = plistlib.loads(data)
    expected_scalars = {
        "CFBundleDisplayName": EXPECTED_OUTPUT_DISPLAY_NAME,
        "CFBundleName": EXPECTED_OUTPUT_DISPLAY_NAME,
        "CFBundleExecutable": "AlightMotion",
        "CFBundleIdentifier": EXPECTED_OUTPUT_BUNDLE_IDENTIFIER,
        "CFBundleShortVersionString": "6.2.55",
        "CFBundleVersion": "862",
        "LSSupportsOpeningDocumentsInPlace": False,
        "UISupportsDocumentBrowser": False,
    }
    for key, expected in expected_scalars.items():
        if plist.get(key) != expected:
            raise RuntimeError(
                f"output Info.plist {key} mismatch: "
                f"expected {expected!r}, found {plist.get(key)!r}"
            )
    if plist.get("CFBundleDocumentTypes") != stable.EXPECTED_DOCUMENT_TYPES:
        raise RuntimeError("output Info.plist document type contract mismatch")
    if plist.get("UTExportedTypeDeclarations") != stable.EXPECTED_EXPORTED_TYPES:
        raise RuntimeError("output Info.plist exported UTI contract mismatch")
    return plist


def _prepare_output_info_plist(data):
    """Retain the base registration contract while applying the requested identity."""
    plist = plistlib.loads(data)
    plist["LSSupportsOpeningDocumentsInPlace"] = False
    plist["UISupportsDocumentBrowser"] = False
    stable.verify_info_plist_contract(
        plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False)
    )
    plist["CFBundleDisplayName"] = EXPECTED_OUTPUT_DISPLAY_NAME
    plist["CFBundleName"] = EXPECTED_OUTPUT_DISPLAY_NAME
    plist["CFBundleIdentifier"] = EXPECTED_OUTPUT_BUNDLE_IDENTIFIER
    result = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False)
    verify_info_plist(result)
    return result


def _load_patched_cloud(source_ipa):
    source_ipa = Path(source_ipa).resolve()
    source_bytes = source_ipa.read_bytes()
    actual_ipa_hash = sha256_bytes(source_bytes)
    if actual_ipa_hash != EXPECTED_CLOUD_SOURCE_IPA_SHA256:
        raise RuntimeError(
            "Cloud source IPA mismatch: "
            f"expected {EXPECTED_CLOUD_SOURCE_IPA_SHA256}, found {actual_ipa_hash}"
        )
    try:
        with zipfile.ZipFile(source_ipa, "r") as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise RuntimeError("Cloud source IPA contains duplicate ZIP entries")
            bad_entry = _first_bad_file_crc(archive)
            if bad_entry is not None:
                raise RuntimeError(f"Cloud source IPA CRC failed for {bad_entry}")
            if names.count(CLOUD_PATH) != 1:
                raise RuntimeError("Cloud source IPA has an unexpected app layout")
            cloud = archive.read(CLOUD_PATH)
    except zipfile.BadZipFile as error:
        raise RuntimeError("Cloud source IPA is not a valid ZIP archive") from error

    actual_cloud_hash = sha256_bytes(cloud)
    if actual_cloud_hash != EXPECTED_CLOUD_SOURCE_SHA256:
        raise RuntimeError(
            "Cloud source dylib mismatch: "
            f"expected {EXPECTED_CLOUD_SOURCE_SHA256}, found {actual_cloud_hash}"
        )
    patched = stable.patch_stability_hotfixes(cloud)
    stable.verify_stability_hotfixes(patched)
    actual_patched_hash = sha256_bytes(patched)
    if actual_patched_hash != EXPECTED_OUTPUT_CLOUD_SHA256:
        raise RuntimeError(
            "patched Cloud dylib mismatch: "
            f"expected {EXPECTED_OUTPUT_CLOUD_SHA256}, found {actual_patched_hash}"
        )
    return _add_signature_placeholder(patched, "AMProjExportCloud.dylib")


def _load_loadcontrol(path):
    path = Path(path).resolve()
    payload = path.read_bytes()
    actual_hash = sha256_bytes(payload)
    if actual_hash != EXPECTED_LOADCONTROL_SHA256:
        raise RuntimeError(
            "LoadControl dylib mismatch: "
            f"expected {EXPECTED_LOADCONTROL_SHA256}, found {actual_hash}"
        )
    slices = stable._macho_slices(payload)
    if len(slices) != 2:
        raise RuntimeError("LoadControl must contain its verified arm64/arm64e slices")
    for _slice_offset, macho in slices:
        _endian, commands = stable._macho_load_commands(macho)
        dependencies = []
        for command, offset, size in commands:
            if command & 0x7FFFFFFF not in DYLIB_COMMANDS:
                continue
            name_offset = struct.unpack_from("<I", macho, offset + 8)[0]
            name = macho[offset + name_offset : offset + size].split(b"\0", 1)[0]
            dependencies.append(name.decode("utf-8", errors="strict"))
        if CYDIA_SUBSTRATE_LOAD not in dependencies:
            raise RuntimeError("LoadControl no longer depends on CydiaSubstrate")
    return _strip_embedded_signatures(payload, "LoadControl.dylib")


def _is_stale_signing_entry(name):
    lower_name = name.lower()
    return lower_name.endswith("/embedded.mobileprovision") or "/_codesignature/" in lower_name


def _copy_zip_info(info, filename=None):
    clone = zipfile.ZipInfo(filename or info.filename, date_time=info.date_time)
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


def verify_resign_ready_ipa(
    base_path,
    output_path,
    expected_info,
    expected_main,
    expected_cloud,
    expected_loadcontrol,
):
    try:
        with zipfile.ZipFile(base_path, "r") as base, zipfile.ZipFile(
            output_path, "r"
        ) as output:
            base_names = base.namelist()
            base_infos = {info.filename: info for info in base.infolist()}
            output_names = output.namelist()
            if len(output_names) != len(set(output_names)):
                raise RuntimeError("output IPA contains duplicate ZIP entries")
            bad_entry = _first_bad_file_crc(output)
            if bad_entry is not None:
                raise RuntimeError(f"output IPA CRC failed for {bad_entry}")

            expected_names = {
                name for name in base_names if not _is_stale_signing_entry(name)
            }
            expected_names.add(LOADCONTROL_PATH)
            if set(output_names) != expected_names:
                missing = sorted(expected_names - set(output_names))
                added = sorted(set(output_names) - expected_names)
                raise RuntimeError(
                    f"output IPA entry mismatch; missing={missing}, unexpected={added}"
                )
            if any(_is_stale_signing_entry(name) for name in output_names):
                raise RuntimeError("output IPA still contains stale signing metadata")

            info = output.read(INFO_PLIST)
            if info != expected_info:
                raise RuntimeError("output Info.plist differs from the requested identity")
            verify_info_plist(info)

            main = output.read(MAIN_EXECUTABLE)
            if main != expected_main:
                raise RuntimeError("output main differs from the verified loader patch")
            verify_resign_ready_main(main)

            cloud = output.read(CLOUD_PATH)
            if cloud != expected_cloud:
                raise RuntimeError("output Cloud differs from the verified hotfix")
            stable.verify_stability_hotfixes(cloud)
            if cloud[:4] in THIN_MACHO_MAGICS:
                _verify_empty_signature_marker(
                    _thin_macho(cloud, "resign-ready Cloud"), "AMProjExportCloud.dylib"
                )

            loader = output.read(LOADCONTROL_PATH)
            if loader != expected_loadcontrol:
                raise RuntimeError("output LoadControl differs from the verified input")
            if loader[:4] in THIN_MACHO_MAGICS or loader[:4] in FAT_MACHO_MAGICS:
                for index, (_slice_offset, loader_slice) in enumerate(
                    stable._macho_slices(loader)
                ):
                    _verify_empty_signature_marker(
                        loader_slice, f"LoadControl slice {index}"
                    )

            for path, expected_hash in (
                (AMENHANCER_PATH, EXPECTED_AMENHANCER_SHA256),
                (CYDIA_SUBSTRATE_PATH, EXPECTED_CYDIA_SUBSTRATE_SHA256),
            ):
                payload = output.read(path)
                if payload != base.read(path) or sha256_bytes(payload) != expected_hash:
                    raise RuntimeError(f"output changed the user's {path}")

            changed_paths = {INFO_PLIST, MAIN_EXECUTABLE, CLOUD_PATH, LOADCONTROL_PATH}
            for name in expected_names - changed_paths:
                if base_infos[name].is_dir():
                    continue
                if stable._zip_member_sha256(output, name) != stable._zip_member_sha256(
                    base, name
                ):
                    raise RuntimeError(f"output changed an unrelated member: {name}")
    except zipfile.BadZipFile as error:
        raise RuntimeError("base or output IPA is not a valid ZIP archive") from error
    return {
        "main_sha256": sha256_bytes(main),
        "cloud_sha256": sha256_bytes(cloud),
        "loadcontrol_sha256": sha256_bytes(loader),
        "entry_count": len(output_names),
    }


def build_loadcontrol_package(base_path, cloud_source_ipa, loadcontrol_path, output_path):
    base_path = Path(base_path).resolve()
    cloud_source_ipa = Path(cloud_source_ipa).resolve()
    loadcontrol_path = Path(loadcontrol_path).resolve()
    output_path = Path(output_path).resolve()
    if output_path in (base_path, cloud_source_ipa, loadcontrol_path):
        raise RuntimeError("output must differ from every input")

    base_bytes = base_path.read_bytes()
    actual_base_hash = sha256_bytes(base_bytes)
    if actual_base_hash != EXPECTED_BASE_SHA256:
        raise RuntimeError(
            "user base IPA mismatch: "
            f"expected {EXPECTED_BASE_SHA256}, found {actual_base_hash}"
        )
    cloud = _load_patched_cloud(cloud_source_ipa)
    loader = _load_loadcontrol(loadcontrol_path)

    try:
        with zipfile.ZipFile(base_path, "r") as base:
            names = base.namelist()
            if len(names) != len(set(names)):
                raise RuntimeError("user base contains duplicate ZIP entries")
            bad_entry = _first_bad_file_crc(base)
            if bad_entry is not None:
                raise RuntimeError(f"user base CRC failed for {bad_entry}")
            required = (
                INFO_PLIST,
                MAIN_EXECUTABLE,
                CLOUD_PATH,
                AMENHANCER_PATH,
                CYDIA_SUBSTRATE_PATH,
            )
            if any(names.count(path) != 1 for path in required):
                raise RuntimeError("user base has an unexpected app layout")
            if LOADCONTROL_PATH in names:
                raise RuntimeError("user base unexpectedly already contains LoadControl")
            base_info = base.read(INFO_PLIST)
            info = _prepare_output_info_plist(base_info)
            main = _prepare_for_recursive_signing(
                patch_main_loader(base.read(MAIN_EXECUTABLE)),
                "AlightMotion",
            )
            if sha256_bytes(base.read(CLOUD_PATH)) != EXPECTED_BASE_CLOUD_SHA256:
                raise RuntimeError("user base Cloud dylib changed")
            if sha256_bytes(base.read(AMENHANCER_PATH)) != EXPECTED_AMENHANCER_SHA256:
                raise RuntimeError("user base AmEnhancer changed")
            if (
                sha256_bytes(base.read(CYDIA_SUBSTRATE_PATH))
                != EXPECTED_CYDIA_SUBSTRATE_SHA256
            ):
                raise RuntimeError("user base CydiaSubstrate changed")
            loader_metadata = base.getinfo(CLOUD_PATH)
    except zipfile.BadZipFile as error:
        raise RuntimeError("user base IPA is not a valid ZIP archive") from error

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".build-", dir=output_path.parent
    ) as temporary_directory:
        candidate = Path(temporary_directory) / "resign-ready.ipa"
        with zipfile.ZipFile(base_path, "r") as base, zipfile.ZipFile(
            candidate, "w", allowZip64=True
        ) as output:
            for zip_info in base.infolist():
                if _is_stale_signing_entry(zip_info.filename):
                    continue
                payload = b"" if zip_info.is_dir() else base.read(zip_info)
                if zip_info.filename == INFO_PLIST:
                    payload = info
                elif zip_info.filename == MAIN_EXECUTABLE:
                    payload = main
                elif zip_info.filename == CLOUD_PATH:
                    payload = cloud
                output.writestr(_copy_zip_info(zip_info), payload)
            output.writestr(
                _copy_zip_info(loader_metadata, filename=LOADCONTROL_PATH), loader
            )

        verification = verify_resign_ready_ipa(
            base_path,
            candidate,
            expected_info=info,
            expected_main=main,
            expected_cloud=cloud,
            expected_loadcontrol=loader,
        )
        os.replace(candidate, output_path)

    return {
        "base_sha256": actual_base_hash,
        "cloud_source_ipa_sha256": EXPECTED_CLOUD_SOURCE_IPA_SHA256,
        **verification,
        "output_sha256": sha256_bytes(output_path.read_bytes()),
        "output": str(output_path),
        "requires_recursive_real_signing": True,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Build the user's Alight Motion 6.2.55 LoadControl package "
            "for recursive LCSign signing"
        )
    )
    parser.add_argument("base", help="verified user-owned am_v73 IPA")
    parser.add_argument("cloud_source", help="verified 862 AMProj source IPA")
    parser.add_argument("loadcontrol", help="verified LoadControl.dylib")
    parser.add_argument("output", help="single resign-ready output IPA")
    args = parser.parse_args(argv)
    result = build_loadcontrol_package(
        args.base,
        args.cloud_source,
        args.loadcontrol,
        args.output,
    )
    for key, value in result.items():
        print(f"{key}: {value}")


if __name__ == "__main__":
    main()
