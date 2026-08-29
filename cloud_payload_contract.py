"""Version-neutral contract checks for an AMProjExport Cloud dylib.

This module intentionally contains no app-version, IPA UUID, or packaging
rules.  The 6.2.58/865 migration packager imports it directly so its build
path cannot accidentally inherit the historical 6.2.55/862 packager.
"""

from __future__ import annotations

import struct


EXPECTED_CLOUD_RUNTIME_MARKER = b"[AMProjExport] ===== Loading v44-cloud ====="
EXPECTED_CLOUD_STABILITY_MARKER = (
    b"[AMProjExport] v44-stable:semantic-option-7,no-native-activity-fallback"
)
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
N_TYPE = 0x0E
N_SECT = 0x0E


def verify_cloud_runtime_version(data: bytes) -> bool:
    """Reject a stale or non-Cloud dylib before packaging starts."""
    if EXPECTED_CLOUD_RUNTIME_MARKER not in data:
        if b"[AMProjExport] ===== Loading v43-cloud =====" in data:
            raise RuntimeError(
                "source Cloud is v43; rebuild AMProjExport.dylib from the v44 source"
            )
        raise RuntimeError(
            "source Cloud does not contain the v44-cloud constructor marker"
        )
    return True


def _macho_symbol_code(data: bytes, symbol_name: str, expected_size: int) -> bytes:
    """Return code at one exact arm64 Mach-O symbol, rejecting malformed tables."""
    if len(data) < 32:
        raise RuntimeError("Cloud stability contract requires a Mach-O image")
    (
        magic,
        cpu_type,
        _subtype,
        filetype,
        command_count,
        command_bytes,
        _flags,
        _reserved,
    ) = struct.unpack_from("<IIIIIIII", data, 0)
    if magic != 0xFEEDFACF or cpu_type != 0x0100000C or filetype != 0x6:
        raise RuntimeError("Cloud stability contract requires a thin arm64 MH_DYLIB")
    if command_bytes > len(data) - 32:
        raise RuntimeError("Cloud stability contract has invalid load commands")

    sections = []
    symtab = None
    offset = 32
    command_limit = 32 + command_bytes
    for _ in range(command_count):
        if offset + 8 > command_limit:
            raise RuntimeError("Cloud stability contract has truncated load commands")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > command_limit:
            raise RuntimeError("Cloud stability contract has invalid load command size")
        if command == LC_SEGMENT_64:
            if size < 72:
                raise RuntimeError("Cloud stability contract has a short segment command")
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            if 72 + section_count * 80 > size:
                raise RuntimeError("Cloud stability contract has truncated sections")
            section_offset = offset + 72
            for _section_index in range(section_count):
                section_name = data[section_offset : section_offset + 16].split(
                    b"\0", 1
                )[0]
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


def verify_cloud_stability_contract(data: bytes) -> bool:
    """Verify the marker and the two exported arm64 semantic guards."""
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
