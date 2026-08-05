#!/usr/bin/env python3
"""Inject AMProjExport dylibs into an iOS IPA for later re-signing."""

import argparse
import ipaddress
import json
import os
import plistlib
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import urlsplit, urlunsplit


AMPROJ_UTI = "com.alightcreative.motion.amproj"
AMPROJ_UTI_CONFORMANCES = ("public.data", "public.archive", "public.zip-archive")
XML_UTI = "public.xml"
DEBUG_CONFIG_NAME = "AMProjDebugConfig.plist"
DEFAULT_SERVER_PORT = 8765
DEFAULT_DEBUG_MODE = "full"
DEBUG_MODES = ("observe", "placeholder", "full")
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 0x2
MH_DYLIB = 0x6
LC_LOAD_DYLIB = 0x0C
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
SHARE_EXTENSION_POINT = "com.apple.share-services"
SHARE_EXTENSION_BUNDLE_SUFFIX = ".amprojshare"
SHARE_EXTENSION_BUNDLE_NAME = "AMProjShareExtension.appex"
APPLICATION_GROUPS_ENTITLEMENT = "com.apple.security.application-groups"
SHARE_APP_GROUP_INFO_KEY = "AMProjShareAppGroupIdentifier"
AMPROJ_URL_SCHEME = "alightmotion"
RFC1918_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)


@dataclass(frozen=True)
class DebugSettings:
    enabled: bool = False
    config_path: Optional[Path] = None
    server_ip: Optional[str] = None
    server_port: int = DEFAULT_SERVER_PORT
    token: Optional[str] = None
    mode: str = DEFAULT_DEBUG_MODE
    server_url: Optional[str] = None
    discovery_enabled: Optional[bool] = None
    build_identifier: Optional[str] = None


def parse_macho_data(data, label="<memory>"):
    """Validate and inspect a thin 64-bit little-endian Mach-O image."""
    if len(data) < 32:
        raise ValueError(f"Mach-O header is truncated: {label}")

    (
        magic,
        cputype,
        cpusubtype,
        filetype,
        ncmds,
        sizeofcmds,
        flags,
        reserved,
    ) = struct.unpack_from("<IIIIIIII", data, 0)
    if magic != 0xFEEDFACF:
        raise ValueError(f"Not a thin 64-bit Mach-O: 0x{magic:x} ({label})")

    commands_end = 32 + sizeofcmds
    if commands_end > len(data):
        raise ValueError(f"Mach-O load commands are truncated: {label}")

    offset = 32
    first_section_offset = len(data)
    load_dylibs = []
    macho_uuid = None
    for index in range(ncmds):
        if offset + 8 > commands_end:
            raise ValueError(f"Invalid load command {index} at 0x{offset:x}: {label}")
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or cmdsize % 8 or offset + cmdsize > commands_end:
            raise ValueError(f"Invalid load command {index} at 0x{offset:x}: {label}")

        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                raise ValueError(f"Invalid LC_SEGMENT_64 at 0x{offset:x}: {label}")
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            section_offset = offset + 72
            if section_offset + (nsects * 80) > offset + cmdsize:
                raise ValueError(f"Invalid section table at 0x{offset:x}: {label}")
            for _ in range(nsects):
                file_offset = struct.unpack_from("<I", data, section_offset + 48)[0]
                if file_offset:
                    if file_offset > len(data):
                        raise ValueError(
                            f"Mach-O section starts beyond EOF at 0x{file_offset:x}: {label}"
                        )
                    first_section_offset = min(first_section_offset, file_offset)
                section_offset += 80

        if cmd == LC_LOAD_DYLIB:
            if cmdsize < 24:
                raise ValueError(f"Invalid LC_LOAD_DYLIB at 0x{offset:x}: {label}")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if name_offset < 24 or name_offset >= cmdsize:
                raise ValueError(
                    f"Invalid LC_LOAD_DYLIB name offset at 0x{offset:x}: {label}"
                )
            name_start = offset + name_offset
            name_end = data.find(b"\x00", name_start, offset + cmdsize)
            if name_end < 0:
                raise ValueError(
                    f"Unterminated LC_LOAD_DYLIB name at 0x{offset:x}: {label}"
                )
            try:
                load_dylibs.append(data[name_start:name_end].decode("utf-8"))
            except UnicodeDecodeError as error:
                raise ValueError(
                    f"Invalid LC_LOAD_DYLIB UTF-8 at 0x{offset:x}: {label}"
                ) from error

        if cmd == LC_UUID:
            if cmdsize != 24:
                raise ValueError(f"Invalid LC_UUID at 0x{offset:x}: {label}")
            if macho_uuid is not None:
                raise ValueError(f"Duplicate LC_UUID at 0x{offset:x}: {label}")
            macho_uuid = data[offset + 8 : offset + 24].hex()

        offset += cmdsize

    if offset != commands_end:
        raise ValueError(f"Mach-O load command size does not match header: {label}")
    if first_section_offset < commands_end:
        raise ValueError(f"Mach-O load commands overlap the first section: {label}")

    return {
        "path": label,
        "cputype": cputype,
        "cpusubtype": cpusubtype,
        "filetype": filetype,
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "flags": flags,
        "reserved": reserved,
        "load_commands_end": commands_end,
        "first_section_offset": first_section_offset,
        "load_dylibs": load_dylibs,
        "uuid": macho_uuid,
    }


def parse_macho(path):
    """Validate and inspect a thin 64-bit little-endian Mach-O file."""
    with open(path, "rb") as file:
        return parse_macho_data(file.read(), str(path))


def verify_dylib_architecture(path):
    """Require a thin arm64 MH_DYLIB, matching the target application ABI."""
    info = parse_macho(path)
    if info["cputype"] != CPU_TYPE_ARM64:
        raise ValueError(
            f"Dylib is not arm64 (cputype=0x{info['cputype']:x}): {path}"
        )
    if info["filetype"] != MH_DYLIB:
        raise ValueError(
            f"Injected file is not an MH_DYLIB (filetype={info['filetype']}): {path}"
        )
    return info


def insert_load_dylib(macho_path, dylib_path):
    """Append an LC_LOAD_DYLIB command in existing Mach-O header padding."""
    info = parse_macho(macho_path)

    with open(macho_path, "rb") as file:
        data = bytearray(file.read())

    dylib_name = f"@executable_path/Frameworks/{os.path.basename(dylib_path)}"
    if dylib_name in info["load_dylibs"]:
        print(f"[!] {dylib_name} already injected, skipping")
        return False

    name_offset = 24
    name_bytes = dylib_name.encode("utf-8") + b"\x00"
    cmd_size = (name_offset + len(name_bytes) + 7) & ~7
    name_bytes += b"\x00" * (cmd_size - name_offset - len(name_bytes))

    dylib_cmd = struct.pack("<II", 0x0C, cmd_size)
    dylib_cmd += struct.pack("<I", name_offset)
    dylib_cmd += struct.pack("<I", 2)
    dylib_cmd += struct.pack("<I", 0x10000)
    dylib_cmd += struct.pack("<I", 0x10000)
    dylib_cmd += name_bytes

    print(f"[+] New LC_LOAD_DYLIB: {dylib_name}")
    print(f"[+] Command size: {cmd_size} bytes")

    # Moving bytes here invalidates every section and LINKEDIT file offset.
    # The command must fit entirely in the existing zero-filled header padding.
    load_commands_end = info["load_commands_end"]
    first_section_offset = info["first_section_offset"]

    available_padding = first_section_offset - load_commands_end
    if available_padding < cmd_size:
        raise RuntimeError(
            f"Not enough Mach-O header padding: need {cmd_size}, "
            f"have {available_padding} bytes"
        )

    padding = data[load_commands_end : load_commands_end + cmd_size]
    if any(padding):
        raise RuntimeError("Mach-O header padding is not empty")

    data[load_commands_end : load_commands_end + cmd_size] = dylib_cmd

    new_ncmds = info["ncmds"] + 1
    new_sizeofcmds = info["sizeofcmds"] + cmd_size
    struct.pack_into("<I", data, 16, new_ncmds)
    struct.pack_into("<I", data, 20, new_sizeofcmds)

    with open(macho_path, "wb") as file:
        file.write(data)

    print(f"[+] Header padding: {available_padding} bytes available")
    print(
        f"[+] Patched {macho_path}: ncmds {info['ncmds']} -> {new_ncmds}"
    )
    return True


def _has_amproj_document_type(plist):
    return _amproj_document_type(plist) is not None


def _amproj_document_type(plist):
    return next(
        (
            document_type
            for document_type in plist.get("CFBundleDocumentTypes", [])
            if isinstance(document_type, dict)
            and AMPROJ_UTI in document_type.get("LSItemContentTypes", [])
        ),
        None,
    )


def _has_xml_document_type(plist):
    return _xml_document_type(plist) is not None


def _xml_document_type(plist):
    candidates = [
        document_type
        for document_type in plist.get("CFBundleDocumentTypes", [])
        if isinstance(document_type, dict)
        and XML_UTI in document_type.get("LSItemContentTypes", [])
    ]
    return next(
        (
            document_type
            for document_type in candidates
            if document_type.get("LSItemContentTypes") == [XML_UTI]
        ),
        candidates[0] if candidates else None,
    )


def _has_amproj_uti(plist):
    return any(
        declaration.get("UTTypeIdentifier") == AMPROJ_UTI
        for declaration in plist.get("UTExportedTypeDeclarations", [])
        if isinstance(declaration, dict)
    )


def _amproj_uti_declaration(plist):
    return next(
        (
            declaration
            for declaration in plist.get("UTExportedTypeDeclarations", [])
            if isinstance(declaration, dict)
            and declaration.get("UTTypeIdentifier") == AMPROJ_UTI
        ),
        None,
    )


def patch_info_plist(
    app_dir,
    enable_debug_network=False,
    bundle_version=None,
):
    """Patch project document types and optional debug-network settings."""
    info_path = os.path.join(app_dir, "Info.plist")
    if not os.path.exists(info_path):
        print("[!] Info.plist not found")
        return False

    with open(info_path, "rb") as file:
        plist = plistlib.load(file)
    if not isinstance(plist, dict):
        raise ValueError("Info.plist root must be a dictionary")
    if bundle_version is not None:
        bundle_version = _normalize_bundle_version(bundle_version)

    changed = False
    if (
        bundle_version is not None
        and plist.get("CFBundleVersion") != bundle_version
    ):
        plist["CFBundleVersion"] = bundle_version
        changed = True
    declarations = plist.get("UTExportedTypeDeclarations")
    if not isinstance(declarations, list):
        declarations = []
        plist["UTExportedTypeDeclarations"] = declarations
        changed = True
    document_types = plist.get("CFBundleDocumentTypes")
    if not isinstance(document_types, list):
        document_types = []
        plist["CFBundleDocumentTypes"] = document_types
        changed = True

    amproj_declaration = _amproj_uti_declaration(plist)
    if amproj_declaration is None:
        amproj_declaration = {
            "UTTypeIdentifier": AMPROJ_UTI,
            "UTTypeDescription": "Alight Motion Project",
            "UTTypeConformsTo": list(AMPROJ_UTI_CONFORMANCES),
            "UTTypeTagSpecification": {
                "public.filename-extension": ["amproj"],
                "public.mime-type": ["application/x-amproj"],
            },
        }
        declarations.append(amproj_declaration)
        changed = True
    else:
        conformances = amproj_declaration.get("UTTypeConformsTo")
        if not isinstance(conformances, list):
            conformances = []
        normalized = list(conformances)
        for conformance in AMPROJ_UTI_CONFORMANCES:
            if conformance not in normalized:
                normalized.append(conformance)
        if normalized != amproj_declaration.get("UTTypeConformsTo"):
            amproj_declaration["UTTypeConformsTo"] = normalized
            changed = True

        tags = amproj_declaration.get("UTTypeTagSpecification")
        if not isinstance(tags, dict):
            tags = {}
            amproj_declaration["UTTypeTagSpecification"] = tags
            changed = True
        expected_tags = {
            "public.filename-extension": ["amproj"],
            "public.mime-type": ["application/x-amproj"],
        }
        for key, values in expected_tags.items():
            current = tags.get(key)
            if not isinstance(current, list):
                current = []
            normalized_values = list(current)
            for value in values:
                if value not in normalized_values:
                    normalized_values.append(value)
            if normalized_values != tags.get(key):
                tags[key] = normalized_values
                changed = True

    amproj_document_type = _amproj_document_type(plist)
    if amproj_document_type is None:
        document_types.append(
            {
                "CFBundleTypeName": "Alight Motion Project",
                "CFBundleTypeRole": "Editor",
                "LSHandlerRank": "Owner",
                "LSItemContentTypes": [AMPROJ_UTI],
            }
        )
        changed = True
    else:
        expected_document_values = {
            "CFBundleTypeName": "Alight Motion Project",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Owner",
        }
        for key, value in expected_document_values.items():
            if amproj_document_type.get(key) != value:
                amproj_document_type[key] = value
                changed = True

    # Collapse malformed/duplicated public.xml registrations to one document
    # type. A system UTI must not be left attached to an unrelated document
    # declaration, otherwise LaunchServices may choose the wrong handler.
    xml_candidates = [
        document_type
        for document_type in document_types
        if isinstance(document_type, dict)
        and XML_UTI in document_type.get("LSItemContentTypes", [])
    ]
    xml_document_type = _xml_document_type(plist)
    if len(xml_candidates) > 1:
        canonical = xml_document_type or xml_candidates[0]
        retained = []
        for document_type in document_types:
            if document_type is canonical:
                retained.append(document_type)
                continue
            if document_type not in xml_candidates:
                retained.append(document_type)
                continue
            content_types = document_type.get("LSItemContentTypes")
            if not isinstance(content_types, list):
                content_types = []
            remaining = [value for value in content_types if value != XML_UTI]
            if remaining:
                document_type["LSItemContentTypes"] = remaining
                retained.append(document_type)
            changed = True
        if retained != document_types:
            plist["CFBundleDocumentTypes"] = document_types = retained
            changed = True
        xml_document_type = canonical
    if xml_document_type is not None:
        content_types = xml_document_type.get("LSItemContentTypes")
        if content_types != [XML_UTI]:
            remaining_types = [
                content_type
                for content_type in content_types
                if content_type != XML_UTI
            ]
            if remaining_types:
                xml_document_type["LSItemContentTypes"] = remaining_types
                xml_document_type = None
            else:
                xml_document_type["LSItemContentTypes"] = [XML_UTI]
            changed = True
    if xml_document_type is None:
        xml_document_type = {
            "CFBundleTypeName": "Alight Motion XML Project",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": [XML_UTI],
        }
        document_types.append(xml_document_type)
        changed = True
    else:
        expected_xml_document_values = {
            "CFBundleTypeName": "Alight Motion XML Project",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Alternate",
        }
        for key, value in expected_xml_document_values.items():
            if xml_document_type.get(key) != value:
                xml_document_type[key] = value
                changed = True

    document_flags = {
        # Provider copy-in is unreliable during a cold launch on iOS 26. Allow
        # Files/QQ to hand the original document over with a security scope; the
        # runtime still copies it synchronously into the app-owned import cache.
        "LSSupportsOpeningDocumentsInPlace": True,
        "UISupportsDocumentBrowser": False,
    }
    for key, value in document_flags.items():
        if plist.get(key) is not value or not isinstance(plist.get(key), bool):
            plist[key] = value
            changed = True

    if enable_debug_network:
        description = "Connect to the AMProj debug server on your local network."
        if plist.get("NSLocalNetworkUsageDescription") != description:
            plist["NSLocalNetworkUsageDescription"] = description
            changed = True

        ats = plist.get("NSAppTransportSecurity")
        if not isinstance(ats, dict):
            ats = {}
            plist["NSAppTransportSecurity"] = ats
            changed = True
        for key in ("NSAllowsLocalNetworking", "NSAllowsArbitraryLoads"):
            # plistlib serializes bool as the plist Boolean type, not a string.
            if ats.get(key) is not True or not isinstance(ats.get(key), bool):
                ats[key] = True
                changed = True

    if not changed:
        print("[*] Info.plist already contains the requested settings")
        return False

    with open(info_path, "wb") as file:
        plistlib.dump(plist, file, fmt=plistlib.FMT_BINARY)

    print("[+] Patched Info.plist")
    return True


def _has_url_scheme(plist, scheme):
    return any(
        scheme in url_type.get("CFBundleURLSchemes", [])
        for url_type in plist.get("CFBundleURLTypes", [])
        if isinstance(url_type, dict)
    )


def patch_share_extension_host_info(app_dir, app_group_id):
    """Configure the host-side App Group lookup and import callback scheme."""
    _validate_app_group_id(app_group_id)
    info_path = Path(app_dir) / "Info.plist"
    with info_path.open("rb") as file:
        plist = plistlib.load(file)
    if not isinstance(plist, dict):
        raise ValueError("Info.plist root must be a dictionary")

    plist[SHARE_APP_GROUP_INFO_KEY] = app_group_id
    url_types = plist.get("CFBundleURLTypes")
    if not isinstance(url_types, list):
        url_types = []
        plist["CFBundleURLTypes"] = url_types
    if not _has_url_scheme(plist, AMPROJ_URL_SCHEME):
        url_types.append(
            {
                "CFBundleURLName": "AMProj Import",
                "CFBundleURLSchemes": [AMPROJ_URL_SCHEME],
            }
        )

    with info_path.open("wb") as file:
        plistlib.dump(plist, file, fmt=plistlib.FMT_BINARY)
    print(f"[+] Configured Share Extension App Group {app_group_id}")


def is_rfc1918(address):
    """Return whether address is in one of the three RFC 1918 IPv4 ranges."""
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return False
    return parsed.version == 4 and any(parsed in network for network in RFC1918_NETWORKS)


def _windows_adapter_addresses():
    """Return active Windows IPv4 addresses with enough metadata to rank them."""
    if os.name != "nt":
        return []

    script = r"""
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$items = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
    Where-Object { -not $_.SkipAsSource } |
    ForEach-Object {
        $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            InterfaceAlias = $_.InterfaceAlias
            InterfaceDescription = if ($adapter) { $adapter.InterfaceDescription } else { "" }
            IPAddress = $_.IPAddress
        }
    }
$items | ConvertTo-Json -Compress
"""
    try:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if not result.stdout.strip():
            return []
        records = json.loads(result.stdout.lstrip("\ufeff"))
        if isinstance(records, dict):
            records = [records]
        return records if isinstance(records, list) else []
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
        return []


def _fallback_host_addresses():
    records = []
    try:
        infos = socket.getaddrinfo(
            socket.gethostname(), None, socket.AF_INET, socket.SOCK_DGRAM
        )
    except OSError:
        return records
    seen = set()
    for info in infos:
        address = info[4][0]
        if address not in seen:
            seen.add(address)
            records.append(
                {
                    "InterfaceAlias": "",
                    "InterfaceDescription": "",
                    "IPAddress": address,
                }
            )
    return records


def choose_server_ip(explicit=None, adapter_records=None):
    """Choose an RFC 1918 WLAN address, while allowing an explicit override."""
    if explicit:
        try:
            parsed = ipaddress.ip_address(explicit)
        except ValueError as error:
            raise ValueError(f"Invalid --server-ip value: {explicit}") from error
        if parsed.version != 4 or parsed.is_unspecified or parsed.is_multicast:
            raise ValueError(f"Invalid --server-ip value: {explicit}")
        return str(parsed)

    records = (
        list(adapter_records)
        if adapter_records is not None
        else _windows_adapter_addresses()
    )
    if not records:
        records = _fallback_host_addresses()

    excluded_tokens = ("radmin", "vpn", "wireguard", "tailscale", "zerotier")
    wlan_tokens = ("wi-fi", "wifi", "wlan", "wireless", "802.11")
    candidates = []
    for record in records:
        if not isinstance(record, dict):
            continue
        address = str(record.get("IPAddress", ""))
        if not is_rfc1918(address):
            continue
        identity = " ".join(
            str(record.get(key, ""))
            for key in ("InterfaceAlias", "InterfaceDescription")
        ).lower()
        if any(token in identity for token in excluded_tokens):
            continue

        score = 0
        if any(token in identity for token in wlan_tokens):
            score += 100
        if address.startswith("192.168."):
            score += 30
        elif address.startswith("10."):
            score += 20
        else:
            score += 10
        candidates.append((score, address))

    if not candidates:
        raise RuntimeError(
            "No RFC 1918 LAN address found. Pass --server-ip explicitly."
        )
    candidates.sort(key=lambda candidate: (-candidate[0], candidate[1]))
    return candidates[0][1]


def normalize_debug_server_url(value):
    """Validate a debug endpoint and return a canonical origin URL."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Debug server URL must not be empty")
    try:
        parsed = urlsplit(value.strip())
        port = parsed.port
    except ValueError as error:
        raise ValueError(f"Invalid debug server URL: {value}") from error
    if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname:
        raise ValueError("Debug server URL must use http or https and include a host")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Debug server URL must not include credentials, query, or fragment")
    if parsed.path not in ("", "/"):
        raise ValueError("Debug server URL must not include a path")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("Debug server URL port must be between 1 and 65535")
    host = parsed.hostname
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    netloc = host if port is None else f"{host}:{port}"
    return urlunsplit((parsed.scheme.lower(), netloc, "", "", ""))


def debug_config_needs_local_network_settings(config):
    """Return whether Info.plist needs local-network and relaxed ATS settings."""
    if not isinstance(config, dict):
        return False
    if type(config.get("DiscoveryEnabled")) is bool and config["DiscoveryEnabled"]:
        return True
    base_url = config.get("BaseURL")
    if not isinstance(base_url, str):
        return False
    try:
        return urlsplit(base_url).scheme.lower() == "http"
    except ValueError:
        return False


def validate_debug_config(config):
    """Validate config fields whose plist types affect runtime permissions."""
    if not isinstance(config, dict):
        raise ValueError("Debug config root must be a dictionary")
    if "DiscoveryEnabled" in config and type(config["DiscoveryEnabled"]) is not bool:
        raise ValueError("Debug config DiscoveryEnabled must be a plist Boolean")
    return config


def make_debug_config(
    server_ip,
    server_port,
    token,
    mode,
    *,
    server_url=None,
    discovery_enabled=None,
    build_identifier=None,
):
    if mode not in DEBUG_MODES:
        raise ValueError(f"Invalid debug mode: {mode}")
    if not 1 <= server_port <= 65535:
        raise ValueError(f"Invalid server port: {server_port}")
    if len(token) < 16:
        raise ValueError("Debug token must contain at least 16 characters")

    if server_url is not None:
        base_url = normalize_debug_server_url(server_url)
        parsed = urlsplit(base_url)
        endpoint_port = parsed.port or (443 if parsed.scheme == "https" else 80)
        discovery = False if discovery_enabled is None else discovery_enabled
    else:
        if server_ip is None:
            raise ValueError("Debug server IP is required when --server-url is absent")
        base_url = f"http://{server_ip}:{server_port}"
        endpoint_port = server_port
        discovery = True if discovery_enabled is None else discovery_enabled

    config = {
        "BaseURL": base_url,
        "Token": token,
        "ProtocolVersion": 1,
        "DefaultMode": mode,
        "DiscoveryEnabled": bool(discovery),
        "DiscoveryPort": endpoint_port,
    }
    if build_identifier:
        config["BuildIdentifier"] = str(build_identifier)
    return config


def install_debug_config(app_dir, settings, adapter_records=None):
    """Copy or generate AMProjDebugConfig.plist in the application bundle."""
    if not settings.enabled:
        return None

    destination = Path(app_dir) / DEBUG_CONFIG_NAME
    if settings.config_path is not None:
        source = Path(settings.config_path)
        if not source.is_file():
            raise FileNotFoundError(f"Debug config not found: {source}")
        with source.open("rb") as file:
            config = plistlib.load(file)
        validate_debug_config(config)
        shutil.copy2(source, destination)
        print(f"[+] Copied debug config to {destination}")
        return config

    server_ip = None
    if settings.server_url is None:
        server_ip = choose_server_ip(settings.server_ip, adapter_records)
    token = settings.token or secrets.token_urlsafe(32)
    config = make_debug_config(
        server_ip,
        settings.server_port,
        token,
        settings.mode,
        server_url=settings.server_url,
        discovery_enabled=settings.discovery_enabled,
        build_identifier=settings.build_identifier,
    )
    validate_debug_config(config)
    with destination.open("wb") as file:
        plistlib.dump(config, file, fmt=plistlib.FMT_BINARY)
    print(f"[+] Generated debug config at {destination}")
    print(f"[+] Debug server: {config['BaseURL']}")
    if config["DiscoveryEnabled"]:
        print(f"[+] Debug discovery: UDP {server_ip}:{config['DiscoveryPort']}")
    else:
        print("[+] Debug discovery: disabled")
    print("[+] Debug token configured (value hidden)")
    return config


def _debug_settings_from_args(args, parser):
    generation_values = (
        args.server_ip,
        args.server_url,
        args.server_port,
        args.debug_token,
        args.debug_mode,
        True if args.no_discovery else None,
        args.build_id,
    )
    if args.debug_config is not None and any(
        value is not None for value in generation_values
    ):
        parser.error(
            "--debug-config cannot be combined with generated-config options"
        )
    if args.server_ip is not None and args.server_url is not None:
        parser.error("--server-ip and --server-url are mutually exclusive")
    if args.server_url is not None and args.server_port is not None:
        parser.error("--server-port must be included in --server-url")

    debug_dylib = "debug" in Path(args.dylib).stem.lower()
    enabled = (
        args.debug_config is not None
        or any(value is not None for value in generation_values)
        or debug_dylib
    )
    return DebugSettings(
        enabled=enabled,
        config_path=Path(args.debug_config) if args.debug_config else None,
        server_ip=args.server_ip,
        server_port=args.server_port or DEFAULT_SERVER_PORT,
        token=args.debug_token,
        mode=args.debug_mode or DEFAULT_DEBUG_MODE,
        server_url=args.server_url,
        discovery_enabled=False if args.no_discovery else None,
        build_identifier=args.build_id,
    )


def _normalize_ipa_root(extraction_dir):
    """Move a single wrapper directory's contents to the IPA archive root."""
    root = Path(extraction_dir)
    payload = root / "Payload"
    if payload.is_dir() and not payload.is_symlink():
        return False
    if payload.exists() or payload.is_symlink():
        raise RuntimeError("IPA root Payload exists but is not a directory")

    candidates = []
    for path in root.iterdir():
        wrapped_payload = path / "Payload"
        if (
            path.is_dir()
            and not path.is_symlink()
            and wrapped_payload.is_dir()
            and not wrapped_payload.is_symlink()
        ):
            candidates.append(path)

    if not candidates:
        raise FileNotFoundError("IPA does not contain a Payload directory")
    if len(candidates) != 1:
        raise RuntimeError(
            "IPA contains more than one wrapper directory with Payload"
        )

    wrapper = candidates[0]
    entries = list(wrapper.iterdir())
    conflicts = [
        entry.name
        for entry in entries
        if (root / entry.name).exists() or (root / entry.name).is_symlink()
    ]
    if conflicts:
        raise RuntimeError(
            "Cannot normalize IPA wrapper because archive-root entries conflict: "
            + ", ".join(sorted(conflicts))
        )
    direct_symlinks = [entry.name for entry in entries if entry.is_symlink()]
    if direct_symlinks:
        raise RuntimeError(
            "Cannot normalize IPA wrapper containing top-level symbolic links: "
            + ", ".join(sorted(direct_symlinks))
        )

    for entry in entries:
        shutil.move(str(entry), str(root / entry.name))
    wrapper.rmdir()
    print(f"[+] Normalized wrapped IPA root from {wrapper.name}")
    return True


def _find_app_bundle(extraction_dir):
    payload = Path(extraction_dir) / "Payload"
    if not payload.is_dir():
        raise FileNotFoundError("IPA does not contain a Payload directory")
    apps = sorted(path for path in payload.iterdir() if path.suffix == ".app")
    if not apps:
        raise FileNotFoundError("No .app bundle found in IPA")
    if len(apps) > 1:
        raise RuntimeError("IPA contains more than one top-level .app bundle")
    return apps[0]


def _bundle_executable(app_dir):
    info_path = Path(app_dir) / "Info.plist"
    with info_path.open("rb") as file:
        plist = plistlib.load(file)
    executable = plist.get("CFBundleExecutable") or Path(app_dir).stem
    path = Path(app_dir) / executable
    if not path.is_file():
        raise FileNotFoundError(f"App executable not found: {path}")
    return path


def _validate_app_group_id(app_group_id):
    if not isinstance(app_group_id, str) or not app_group_id.startswith("group."):
        raise ValueError("App Group identifier must start with 'group.'")
    if any(not component for component in app_group_id.split(".")):
        raise ValueError("App Group identifier contains an empty component")
    return app_group_id


def _share_entitlements_candidates(appex_path):
    appex_path = Path(appex_path)
    name = appex_path.stem
    return (
        appex_path / f"{name}.entitlements",
        appex_path / "Entitlements.plist",
        appex_path / "archived-expanded-entitlements.xcent",
        appex_path.parent / f"{name}.entitlements",
        appex_path.parent / "AMProjShareExtension.entitlements",
    )


def _load_share_entitlements(appex_path):
    for candidate in _share_entitlements_candidates(appex_path):
        if not candidate.is_file():
            continue
        try:
            with candidate.open("rb") as file:
                entitlements = plistlib.load(file)
        except plistlib.InvalidFileException as error:
            raise ValueError(
                f"Share Extension entitlements are invalid: {candidate}"
            ) from error
        if not isinstance(entitlements, dict):
            raise ValueError(
                f"Share Extension entitlements root must be a dictionary: {candidate}"
            )
        return candidate, entitlements
    raise FileNotFoundError(
        "Share Extension entitlements not found beside or inside the .appex"
    )


def _validate_share_extension_metadata(
    plist,
    executable_info,
    entitlements,
    expected_bundle_identifier,
    app_group_id,
):
    if not isinstance(plist, dict):
        raise ValueError("Share Extension Info.plist root must be a dictionary")
    bundle_identifier = plist.get("CFBundleIdentifier")
    if bundle_identifier != expected_bundle_identifier:
        raise ValueError(
            "Share Extension bundle identifier must be "
            f"{expected_bundle_identifier}; found {bundle_identifier!r}"
        )
    extension = plist.get("NSExtension")
    if not isinstance(extension, dict) or (
        extension.get("NSExtensionPointIdentifier") != SHARE_EXTENSION_POINT
    ):
        raise ValueError(
            "Share Extension NSExtensionPointIdentifier must be "
            f"{SHARE_EXTENSION_POINT}"
        )
    executable_name = plist.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise ValueError("Share Extension CFBundleExecutable is missing")
    if executable_info["cputype"] != CPU_TYPE_ARM64:
        raise ValueError("Share Extension executable is not arm64")
    if executable_info["filetype"] != MH_EXECUTE:
        raise ValueError(
            "Share Extension executable is not an MH_EXECUTE "
            f"(filetype={executable_info['filetype']})"
        )
    groups = entitlements.get(APPLICATION_GROUPS_ENTITLEMENT)
    if not isinstance(groups, list) or app_group_id not in groups:
        raise ValueError(
            "Share Extension entitlements do not contain App Group "
            f"{app_group_id}"
        )
    return {
        "bundle_identifier": bundle_identifier,
        "executable": executable_name,
        "app_group_id": app_group_id,
    }


def verify_share_extension_bundle(
    appex_path,
    expected_bundle_identifier,
    app_group_id,
):
    """Validate an unsigned/sideload-ready Share Extension bundle."""
    appex_path = Path(appex_path)
    _validate_app_group_id(app_group_id)
    if appex_path.suffix != ".appex" or not appex_path.is_dir():
        raise ValueError(f"Share Extension must be a .appex directory: {appex_path}")

    info_path = appex_path / "Info.plist"
    if not info_path.is_file():
        raise FileNotFoundError(f"Share Extension Info.plist not found: {info_path}")
    try:
        with info_path.open("rb") as file:
            plist = plistlib.load(file)
    except plistlib.InvalidFileException as error:
        raise ValueError(f"Share Extension Info.plist is invalid: {info_path}") from error

    executable_name = plist.get("CFBundleExecutable") if isinstance(plist, dict) else None
    executable_path = appex_path / str(executable_name or "")
    if not executable_name or not executable_path.is_file():
        raise FileNotFoundError(
            f"Share Extension executable not found: {executable_path}"
        )
    executable_info = parse_macho(executable_path)
    entitlements_path, entitlements = _load_share_entitlements(appex_path)
    result = _validate_share_extension_metadata(
        plist,
        executable_info,
        entitlements,
        expected_bundle_identifier,
        app_group_id,
    )
    result["path"] = appex_path
    result["entitlements_path"] = entitlements_path
    return result


def install_share_extension(
    app_dir,
    share_extension_path,
    app_group_id,
    host_bundle_identifier,
):
    """Validate and install one Share Extension under the app PlugIns folder."""
    if not isinstance(host_bundle_identifier, str) or not host_bundle_identifier:
        raise ValueError("Host app CFBundleIdentifier is required for Share Extension")
    expected_bundle_identifier = (
        host_bundle_identifier + SHARE_EXTENSION_BUNDLE_SUFFIX
    )
    source = Path(share_extension_path)
    source_info = verify_share_extension_bundle(
        source,
        expected_bundle_identifier,
        app_group_id,
    )

    plugins_dir = Path(app_dir) / "PlugIns"
    plugins_dir.mkdir(parents=True, exist_ok=True)
    destination = plugins_dir / source.name
    if destination.exists():
        if destination.is_dir():
            shutil.rmtree(destination)
        else:
            destination.unlink()
    shutil.copytree(source, destination)

    # The Actions build emits the signing entitlement template next to the
    # .appex.  Keep a copy in the bundle so the final IPA remains auditable
    # after it is downloaded to Windows and re-signed by Sideloadly.
    destination_entitlements = destination / f"{destination.stem}.entitlements"
    source_entitlements = Path(source_info["entitlements_path"])
    if source_entitlements.resolve() != destination_entitlements.resolve():
        shutil.copy2(source_entitlements, destination_entitlements)

    result = verify_share_extension_bundle(
        destination,
        expected_bundle_identifier,
        app_group_id,
    )
    print(f"[+] Installed Share Extension at {destination}")
    return result


def _remove_stable_share_extension(app_dir):
    """Remove the experimental Share Extension from a stable app bundle."""
    app_dir = Path(app_dir)
    removed = []
    plugins_dir = app_dir / "PlugIns"
    if plugins_dir.is_dir():
        for candidate in sorted(plugins_dir.iterdir()):
            if candidate.name != SHARE_EXTENSION_BUNDLE_NAME and not candidate.name.endswith(
                SHARE_EXTENSION_BUNDLE_SUFFIX + ".appex"
            ):
                continue
            if candidate.is_dir():
                shutil.rmtree(candidate)
            else:
                candidate.unlink()
            removed.append(candidate.name)
        if not any(plugins_dir.iterdir()):
            plugins_dir.rmdir()

    info_path = app_dir / "Info.plist"
    with info_path.open("rb") as file:
        plist = plistlib.load(file)
    if not isinstance(plist, dict):
        raise ValueError("Info.plist root must be a dictionary")
    changed = SHARE_APP_GROUP_INFO_KEY in plist
    plist.pop(SHARE_APP_GROUP_INFO_KEY, None)

    url_types = plist.get("CFBundleURLTypes")
    if isinstance(url_types, list):
        remaining_url_types = []
        for url_type in url_types:
            if not isinstance(url_type, dict):
                remaining_url_types.append(url_type)
                continue
            schemes = url_type.get("CFBundleURLSchemes")
            if (
                url_type.get("CFBundleURLName") == "AMProj Import"
                and isinstance(schemes, list)
                and AMPROJ_URL_SCHEME in schemes
            ):
                kept_schemes = [scheme for scheme in schemes if scheme != AMPROJ_URL_SCHEME]
                if kept_schemes:
                    url_type = dict(url_type)
                    url_type["CFBundleURLSchemes"] = kept_schemes
                    remaining_url_types.append(url_type)
                changed = True
                continue
            remaining_url_types.append(url_type)
        if remaining_url_types:
            if remaining_url_types != url_types:
                changed = True
            plist["CFBundleURLTypes"] = remaining_url_types
        elif url_types:
            plist.pop("CFBundleURLTypes", None)
            changed = True

    if changed:
        with info_path.open("wb") as file:
            plistlib.dump(plist, file, fmt=plistlib.FMT_BINARY)
    print(
        "[+] Stable bundle cleanup: removed "
        f"{len(removed)} Share Extension(s), host metadata={'yes' if changed else 'no'}"
    )
    return removed, changed


def _stable_share_extension_entries(names, app_root):
    """Return experimental Share Extension bundle roots embedded in an IPA."""
    prefix = f"{app_root}/PlugIns/"
    roots = set()
    for name in names:
        if not name.startswith(prefix):
            continue
        remainder = name[len(prefix) :]
        root_name = remainder.split("/", 1)[0]
        if root_name == SHARE_EXTENSION_BUNDLE_NAME or root_name.endswith(
            SHARE_EXTENSION_BUNDLE_SUFFIX + ".appex"
        ):
            roots.add(root_name)
    return sorted(roots)


def _remove_code_signature_directories(bundle_dir):
    """Remove stale CodeResources from the app and all nested bundles."""
    paths = sorted(
        Path(bundle_dir).rglob("_CodeSignature"),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for path in paths:
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    return len(paths)


def _try_resign(app_dir):
    try:
        subprocess.run(
            ["ldid", "-S", str(app_dir)], check=True, capture_output=True
        )
        print("[+] Resigned with ldid")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("[!] ldid not found or failed; re-sign the IPA manually")


def _repack_ipa(extraction_dir, output_path):
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    extraction_path = Path(extraction_dir)
    archive_base = extraction_path.with_name(f"{extraction_path.name}_repacked")
    archive = Path(
        shutil.make_archive(
            str(archive_base), "zip", root_dir=str(extraction_dir)
        )
    )
    if output.exists():
        output.unlink()
    shutil.move(str(archive), str(output))


def _validate_patched_info_plist(
    plist,
    settings,
    expected_bundle_identifier,
    expected_app_group_id=None,
    expected_config=None,
    expected_bundle_version=None,
):
    if not isinstance(plist, dict):
        raise RuntimeError("Info.plist root is not a dictionary")
    if expected_bundle_identifier is not None and (
        plist.get("CFBundleIdentifier") != expected_bundle_identifier
    ):
        raise RuntimeError("Injection changed CFBundleIdentifier")
    if expected_bundle_version is not None and (
        plist.get("CFBundleVersion") != expected_bundle_version
    ):
        raise RuntimeError(
            "Info.plist CFBundleVersion does not match the requested bundle version"
        )
    if not _has_amproj_document_type(plist) or not _has_amproj_uti(plist):
        raise RuntimeError("Info.plist is missing the .amproj document registration")
    document_type = _amproj_document_type(plist)
    if (
        document_type.get("CFBundleTypeRole") != "Editor"
        or document_type.get("LSHandlerRank") != "Owner"
    ):
        raise RuntimeError(
            "Info.plist .amproj document type must be Editor with Owner rank"
        )
    declaration = _amproj_uti_declaration(plist)
    if "public.zip-archive" not in declaration.get("UTTypeConformsTo", []):
        raise RuntimeError("Info.plist .amproj UTI must conform to public.zip-archive")
    tags = declaration.get("UTTypeTagSpecification", {})
    if "amproj" not in tags.get("public.filename-extension", []):
        raise RuntimeError("Info.plist .amproj UTI is missing its filename extension")
    xml_document_types = [
        item
        for item in plist.get("CFBundleDocumentTypes", [])
        if isinstance(item, dict)
        and XML_UTI in item.get("LSItemContentTypes", [])
    ]
    if len(xml_document_types) != 1:
        raise RuntimeError(
            "Info.plist must contain exactly one public.xml document registration"
        )
    xml_document_type = xml_document_types[0]
    if xml_document_type is None:
        raise RuntimeError("Info.plist is missing the public.xml document registration")
    if (
        xml_document_type.get("CFBundleTypeRole") != "Editor"
        or xml_document_type.get("LSHandlerRank") != "Alternate"
    ):
        raise RuntimeError(
            "Info.plist public.xml document type must be Editor with Alternate rank"
        )
    expected_document_flags = {
        "LSSupportsOpeningDocumentsInPlace": True,
        "UISupportsDocumentBrowser": False,
    }
    for key, value in expected_document_flags.items():
        if plist.get(key) is not value or not isinstance(plist.get(key), bool):
            raise RuntimeError(
                f"Info.plist {key} must be a Boolean {str(value).lower()}"
            )
    if expected_app_group_id is not None:
        if plist.get(SHARE_APP_GROUP_INFO_KEY) != expected_app_group_id:
            raise RuntimeError(
                f"Info.plist {SHARE_APP_GROUP_INFO_KEY} does not match the App Group"
            )
        if not _has_url_scheme(plist, AMPROJ_URL_SCHEME):
            raise RuntimeError(
                f"Info.plist is missing the {AMPROJ_URL_SCHEME} URL scheme"
            )
    if settings.enabled and debug_config_needs_local_network_settings(expected_config):
        if not isinstance(plist.get("NSLocalNetworkUsageDescription"), str):
            raise RuntimeError("Info.plist is missing NSLocalNetworkUsageDescription")
        ats = plist.get("NSAppTransportSecurity")
        if not isinstance(ats, dict):
            raise RuntimeError("Info.plist is missing NSAppTransportSecurity")
        for key in ("NSAllowsLocalNetworking", "NSAllowsArbitraryLoads"):
            if ats.get(key) is not True or not isinstance(ats.get(key), bool):
                raise RuntimeError(f"Info.plist {key} must be a Boolean true")


def _verify_share_extension_in_archive(
    archive,
    names,
    app_root,
    share_extension_path,
    app_group_id,
    host_bundle_identifier,
):
    source = Path(share_extension_path)
    extension_root = f"{app_root}/PlugIns/{source.name}"

    def read_unique(relative_path):
        name = f"{extension_root}/{relative_path}"
        if names.count(name) != 1:
            raise RuntimeError(
                f"IPA must contain exactly one Share Extension {relative_path}; "
                f"found {names.count(name)}"
            )
        return archive.read(name)

    try:
        plist = plistlib.loads(read_unique("Info.plist"))
    except (plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError("Embedded Share Extension Info.plist is invalid") from error
    executable_name = (
        plist.get("CFBundleExecutable") if isinstance(plist, dict) else None
    )
    if not isinstance(executable_name, str) or not executable_name:
        raise RuntimeError("Embedded Share Extension CFBundleExecutable is missing")
    executable_data = read_unique(executable_name)
    executable_info = parse_macho_data(
        executable_data,
        f"{extension_root}/{executable_name}",
    )
    entitlements_name = f"{source.stem}.entitlements"
    try:
        entitlements = plistlib.loads(read_unique(entitlements_name))
    except (plistlib.InvalidFileException, ValueError) as error:
        raise RuntimeError("Embedded Share Extension entitlements are invalid") from error

    try:
        result = _validate_share_extension_metadata(
            plist,
            executable_info,
            entitlements,
            host_bundle_identifier + SHARE_EXTENSION_BUNDLE_SUFFIX,
            app_group_id,
        )
    except ValueError as error:
        raise RuntimeError(f"Embedded Share Extension is invalid: {error}") from error

    stale_signatures = [
        name
        for name in names
        if name.startswith(extension_root + "/_CodeSignature/")
    ]
    if stale_signatures:
        raise RuntimeError("Embedded Share Extension still contains an old signature")
    result["path"] = extension_root
    return result


def verify_injected_ipa(
    ipa_path,
    dylib_path,
    settings,
    expected_config=None,
    expected_bundle_identifier=None,
    expected_share_extension=None,
    expected_app_group_id=None,
    expected_main_uuid=None,
    expected_bundle_version=None,
):
    """Verify the final archive, embedded files, Mach-O layout, and config."""
    ipa_path = Path(ipa_path)
    dylib_path = Path(dylib_path)
    expected_dylib = dylib_path.read_bytes()
    if (expected_share_extension is None) != (expected_app_group_id is None):
        raise RuntimeError(
            "Expected Share Extension and App Group must be provided together"
        )

    try:
        with zipfile.ZipFile(ipa_path, "r") as archive:
            bad_entry = archive.testzip()
            if bad_entry is not None:
                raise RuntimeError(f"IPA ZIP CRC failed for {bad_entry}")

            names = [entry.filename for entry in archive.infolist()]
            app_roots = {
                "/".join(name.split("/")[:2])
                for name in names
                if len(name.split("/")) >= 2
                and name.split("/")[0] == "Payload"
                and name.split("/")[1].endswith(".app")
            }
            if len(app_roots) != 1:
                raise RuntimeError(
                    f"IPA must contain exactly one top-level .app; found {len(app_roots)}"
                )
            app_root = next(iter(app_roots))

            def read_unique(relative_path):
                name = f"{app_root}/{relative_path}"
                if names.count(name) != 1:
                    raise RuntimeError(
                        f"IPA must contain exactly one {relative_path}; "
                        f"found {names.count(name)}"
                    )
                return archive.read(name)

            try:
                plist = plistlib.loads(read_unique("Info.plist"))
            except (plistlib.InvalidFileException, ValueError) as error:
                raise RuntimeError("Injected Info.plist is invalid") from error
            if expected_share_extension is None:
                stale_extensions = _stable_share_extension_entries(names, app_root)
                if stale_extensions:
                    raise RuntimeError(
                        "Stable IPA must not contain Share Extension: "
                        + ", ".join(stale_extensions)
                    )
                if SHARE_APP_GROUP_INFO_KEY in plist:
                    raise RuntimeError(
                        "Stable IPA must not contain "
                        f"{SHARE_APP_GROUP_INFO_KEY}"
                    )
            _validate_patched_info_plist(
                plist,
                settings,
                expected_bundle_identifier,
                expected_app_group_id,
                expected_config,
                expected_bundle_version,
            )

            executable_name = plist.get("CFBundleExecutable") or Path(app_root).stem
            executable_data = read_unique(executable_name)
            executable_info = parse_macho_data(
                executable_data, f"{ipa_path}!/{app_root}/{executable_name}"
            )
            if executable_info["cputype"] != CPU_TYPE_ARM64:
                raise RuntimeError("Application executable is not arm64")
            _validate_expected_main_uuid(
                executable_info, expected_main_uuid, "Application executable"
            )

            dylib_relative = f"Frameworks/{dylib_path.name}"
            embedded_dylib = read_unique(dylib_relative)
            if embedded_dylib != expected_dylib:
                raise RuntimeError("Embedded dylib differs from the input dylib")
            dylib_info = parse_macho_data(
                embedded_dylib, f"{ipa_path}!/{app_root}/{dylib_relative}"
            )
            if (
                dylib_info["cputype"] != CPU_TYPE_ARM64
                or dylib_info["filetype"] != MH_DYLIB
            ):
                raise RuntimeError("Embedded dylib is not a thin arm64 MH_DYLIB")

            load_name = f"@executable_path/Frameworks/{dylib_path.name}"
            load_count = executable_info["load_dylibs"].count(load_name)
            if load_count != 1:
                raise RuntimeError(
                    f"Expected exactly one {load_name} load command; found {load_count}"
                )

            if settings.enabled:
                try:
                    embedded_config = plistlib.loads(
                        read_unique(DEBUG_CONFIG_NAME)
                    )
                except (plistlib.InvalidFileException, ValueError) as error:
                    raise RuntimeError("Embedded debug config is invalid") from error
                if embedded_config != expected_config:
                    raise RuntimeError("Embedded debug config differs from generated config")

            share_extension_info = None
            if expected_share_extension is not None:
                if expected_app_group_id is None:
                    raise RuntimeError(
                        "Expected App Group identifier is required for Share Extension"
                    )
                share_extension_info = _verify_share_extension_in_archive(
                    archive,
                    names,
                    app_root,
                    expected_share_extension,
                    expected_app_group_id,
                    plist.get("CFBundleIdentifier", ""),
                )

    except zipfile.BadZipFile as error:
        raise RuntimeError(f"Invalid IPA ZIP archive: {ipa_path}") from error

    result = {
        "app": app_root,
        "bundle_identifier": plist.get("CFBundleIdentifier", ""),
        "bundle_version": plist.get("CFBundleVersion"),
        "executable": executable_name,
        "main_uuid": executable_info["uuid"],
        "dylib": dylib_path.name,
        "mode": expected_config.get("DefaultMode")
        if isinstance(expected_config, dict)
        else None,
        "share_extension": share_extension_info,
    }
    print(
        "[+] Verified IPA: ZIP CRC, Info.plist, arm64 dylib, "
        "Mach-O layout, and unique load command"
    )
    return result


def inject_ipa(
    ipa_path,
    dylib_path,
    output_path,
    debug_settings=None,
    share_extension_path=None,
    app_group_id=None,
    expected_main_uuid=None,
    bundle_version=None,
):
    """Inject one dylib and return the generated/copied debug config, if any."""
    ipa_path = Path(ipa_path)
    dylib_path = Path(dylib_path)
    output_path = Path(output_path)
    settings = debug_settings or DebugSettings()
    if bundle_version is not None:
        bundle_version = _normalize_bundle_version(bundle_version)

    if (share_extension_path is None) != (app_group_id is None):
        raise ValueError(
            "share_extension_path and app_group_id must be provided together"
        )
    if app_group_id is not None:
        _validate_app_group_id(app_group_id)

    if not ipa_path.is_file():
        raise FileNotFoundError(f"IPA not found: {ipa_path}")
    if not dylib_path.is_file():
        raise FileNotFoundError(f"Dylib not found: {dylib_path}")
    verify_dylib_architecture(dylib_path)

    with tempfile.TemporaryDirectory(prefix="amproj_inject_") as temp_dir:
        print(f"[*] Temp dir: {temp_dir}")
        print(f"[*] Extracting {ipa_path}...")
        shutil.unpack_archive(str(ipa_path), temp_dir, "zip")
        _normalize_ipa_root(temp_dir)
        app_dir = _find_app_bundle(temp_dir)
        with (app_dir / "Info.plist").open("rb") as file:
            original_info = plistlib.load(file)
        if not isinstance(original_info, dict):
            raise ValueError("Info.plist root must be a dictionary")
        original_bundle_identifier = original_info.get("CFBundleIdentifier")

        frameworks = app_dir / "Frameworks"
        frameworks.mkdir(parents=True, exist_ok=True)
        dylib_destination = frameworks / dylib_path.name
        shutil.copy2(dylib_path, dylib_destination)
        print(f"[+] Copied dylib to {dylib_destination}")

        executable = _bundle_executable(app_dir)
        executable_info = parse_macho(executable)
        _validate_expected_main_uuid(
            executable_info, expected_main_uuid, "Input application executable"
        )
        patched = insert_load_dylib(str(executable), str(dylib_destination))
        if not patched:
            print("[*] Binary already patched, continuing...")

        config = install_debug_config(app_dir, settings)
        patch_info_plist(
            app_dir,
            enable_debug_network=debug_config_needs_local_network_settings(config),
            bundle_version=bundle_version,
        )

        if share_extension_path is not None:
            patch_share_extension_host_info(app_dir, app_group_id)
            install_share_extension(
                app_dir,
                share_extension_path,
                app_group_id,
                original_bundle_identifier,
            )
        else:
            _remove_stable_share_extension(app_dir)

        removed_signatures = _remove_code_signature_directories(app_dir)
        print(f"[+] Removed {removed_signatures} old code signature directorie(s)")
        _try_resign(app_dir)

        print(f"[*] Repacking to {output_path}...")
        _repack_ipa(temp_dir, output_path)
        verify_injected_ipa(
            output_path,
            dylib_path,
            settings,
            expected_config=config,
            expected_bundle_identifier=original_bundle_identifier,
            expected_share_extension=share_extension_path,
            expected_app_group_id=app_group_id,
            expected_main_uuid=expected_main_uuid,
            expected_bundle_version=bundle_version,
        )
        print(f"[+] Done: {output_path}")
        return config


def _port(value):
    try:
        port = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("port must be an integer") from error
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return port


def _normalize_bundle_version(value):
    if (
        not isinstance(value, str)
        or not value
        or value[0] == "0"
        or any(character < "0" or character > "9" for character in value)
    ):
        raise ValueError("bundle version must be a positive integer string")
    return value


def _bundle_version(value):
    try:
        return _normalize_bundle_version(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def _token(value):
    if len(value) < 16:
        raise argparse.ArgumentTypeError("token must contain at least 16 characters")
    return value


def _normalize_macho_uuid(value):
    normalized = value.replace("-", "").lower()
    if len(normalized) != 32 or any(
        character not in "0123456789abcdef" for character in normalized
    ):
        raise ValueError("Mach-O UUID must contain exactly 32 hexadecimal digits")
    return normalized


def _macho_uuid(value):
    try:
        return _normalize_macho_uuid(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def _validate_expected_main_uuid(info, expected_uuid, label):
    if expected_uuid is None:
        return
    expected = _normalize_macho_uuid(expected_uuid)
    actual = info.get("uuid")
    if actual != expected:
        found = actual or "missing"
        raise RuntimeError(
            f"{label} UUID does not match the verified AM build: "
            f"expected {expected}, found {found}"
        )


def _app_group_id(value):
    try:
        return _validate_app_group_id(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error


def _share_extension_options_from_args(args, parser):
    if (args.share_extension is None) != (args.app_group_id is None):
        parser.error("--share-extension and --app-group-id must be used together")
    return args.share_extension, args.app_group_id


def build_argument_parser():
    parser = argparse.ArgumentParser(
        description="Inject an AMProjExport dylib into an iOS IPA."
    )
    parser.add_argument("ipa", help="input IPA")
    parser.add_argument(
        "dylib",
        help="AMProjExport, AMProjExportCloud, or AMProjExportDebug dylib",
    )
    parser.add_argument("output", nargs="?", help="output IPA")
    parser.add_argument(
        "--debug-config",
        help=f"copy an existing plist into the app as {DEBUG_CONFIG_NAME}",
    )
    parser.add_argument(
        "--server-ip",
        help="debug backend IPv4 address; otherwise auto-detect RFC 1918 WLAN",
    )
    parser.add_argument(
        "--server-url",
        type=normalize_debug_server_url,
        help="debug backend origin URL, for example https://debug.example.test",
    )
    parser.add_argument("--server-port", type=_port, help="debug backend port")
    parser.add_argument(
        "--no-discovery",
        action="store_true",
        help="disable UDP LAN endpoint discovery",
    )
    parser.add_argument(
        "--debug-token", type=_token, help="debug backend bearer token"
    )
    parser.add_argument("--debug-mode", choices=DEBUG_MODES, help="initial mode")
    parser.add_argument(
        "--build-id",
        help="opaque build identifier embedded in the debug config",
    )
    parser.add_argument(
        "--expected-main-uuid",
        type=_macho_uuid,
        help="reject an IPA whose main executable UUID does not match",
    )
    parser.add_argument(
        "--bundle-version",
        type=_bundle_version,
        help="set CFBundleVersion to a positive integer, for example 862",
    )
    parser.add_argument(
        "--share-extension",
        help="optional AMProjShareExtension.appex bundle to install",
    )
    parser.add_argument(
        "--app-group-id",
        type=_app_group_id,
        help="App Group entitlement required by the Share Extension",
    )
    return parser


def main(argv=None):
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    settings = _debug_settings_from_args(args, parser)
    share_extension, app_group_id = _share_extension_options_from_args(
        args, parser
    )
    input_path = Path(args.ipa)
    output = args.output or str(
        input_path.with_name(f"{input_path.stem}_amproj.ipa")
    )
    try:
        inject_ipa(
            args.ipa,
            args.dylib,
            output,
            settings,
            share_extension_path=share_extension,
            app_group_id=app_group_id,
            expected_main_uuid=args.expected_main_uuid,
            bundle_version=args.bundle_version,
        )
    except (
        OSError,
        ValueError,
        RuntimeError,
        shutil.ReadError,
        zipfile.BadZipFile,
    ) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
