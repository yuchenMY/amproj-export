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
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


AMPROJ_UTI = "com.alightcreative.motion.amproj"
DEBUG_CONFIG_NAME = "AMProjDebugConfig.plist"
DEFAULT_SERVER_PORT = 8765
DEFAULT_DEBUG_MODE = "observe"
DEBUG_MODES = ("observe", "placeholder", "full")
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


def parse_macho(path):
    """Parse the fields needed from a thin 64-bit Mach-O header."""
    with open(path, "rb") as file:
        magic_data = file.read(4)
        if len(magic_data) != 4:
            raise ValueError("Mach-O header is truncated")
        magic = struct.unpack("<I", magic_data)[0]
        if magic != 0xFEEDFACF:
            raise ValueError(f"Not a thin arm64 Mach-O: 0x{magic:x}")

        header = file.read(28)
        if len(header) != 28:
            raise ValueError("Mach-O header is truncated")
        _, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack(
            "<IIIIIII", header
        )

    return {
        "path": path,
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "filetype": filetype,
    }


def insert_load_dylib(macho_path, dylib_path):
    """Append an LC_LOAD_DYLIB command in existing Mach-O header padding."""
    info = parse_macho(macho_path)

    with open(macho_path, "rb") as file:
        data = bytearray(file.read())

    dylib_name = f"@executable_path/Frameworks/{os.path.basename(dylib_path)}"
    if (dylib_name.encode("utf-8") + b"\x00") in data:
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
    load_commands_end = 32 + info["sizeofcmds"]
    first_section_offset = len(data)
    offset = 32
    for index in range(info["ncmds"]):
        if offset + 8 > load_commands_end:
            raise ValueError(f"Invalid load command {index} at 0x{offset:x}")
        cmd, cmdsize = struct.unpack_from("<II", data, offset)
        if cmdsize < 8 or offset + cmdsize > load_commands_end:
            raise ValueError(f"Invalid load command {index} at 0x{offset:x}")

        if cmd == 0x19:  # LC_SEGMENT_64
            if cmdsize < 72:
                raise ValueError(f"Invalid LC_SEGMENT_64 at 0x{offset:x}")
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            section_offset = offset + 72
            if section_offset + (nsects * 80) > offset + cmdsize:
                raise ValueError(f"Invalid section table at 0x{offset:x}")
            for _ in range(nsects):
                file_offset = struct.unpack_from(
                    "<I", data, section_offset + 48
                )[0]
                if file_offset:
                    first_section_offset = min(first_section_offset, file_offset)
                section_offset += 80

        offset += cmdsize

    if offset != load_commands_end:
        raise ValueError("Mach-O load command size does not match header")

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
    return any(
        AMPROJ_UTI in document_type.get("LSItemContentTypes", [])
        for document_type in plist.get("CFBundleDocumentTypes", [])
        if isinstance(document_type, dict)
    )


def _has_amproj_uti(plist):
    return any(
        declaration.get("UTTypeIdentifier") == AMPROJ_UTI
        for declaration in plist.get("UTExportedTypeDeclarations", [])
        if isinstance(declaration, dict)
    )


def patch_info_plist(app_dir, enable_debug_network=False):
    """Patch the .amproj UTI and, for debug builds, local-network settings."""
    info_path = os.path.join(app_dir, "Info.plist")
    if not os.path.exists(info_path):
        print("[!] Info.plist not found")
        return False

    with open(info_path, "rb") as file:
        plist = plistlib.load(file)
    if not isinstance(plist, dict):
        raise ValueError("Info.plist root must be a dictionary")

    changed = False
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

    if not _has_amproj_uti(plist):
        declarations.append(
            {
                "UTTypeIdentifier": AMPROJ_UTI,
                "UTTypeDescription": "Alight Motion Project",
                "UTTypeConformsTo": ["public.data", "public.archive"],
                "UTTypeTagSpecification": {
                    "public.filename-extension": ["amproj"],
                    "public.mime-type": ["application/x-amproj"],
                },
            }
        )
        changed = True

    if not _has_amproj_document_type(plist):
        document_types.append(
            {
                "CFBundleTypeName": "Alight Motion Project",
                "CFBundleTypeRole": "Editor",
                "LSHandlerRank": "Owner",
                "LSItemContentTypes": [AMPROJ_UTI],
            }
        )
        changed = True

    if "UISupportsDocumentBrowser" not in plist:
        plist["UISupportsDocumentBrowser"] = False
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


def make_debug_config(server_ip, server_port, token, mode):
    if mode not in DEBUG_MODES:
        raise ValueError(f"Invalid debug mode: {mode}")
    if not 1 <= server_port <= 65535:
        raise ValueError(f"Invalid server port: {server_port}")
    if len(token) < 16:
        raise ValueError("Debug token must contain at least 16 characters")
    return {
        "BaseURL": f"http://{server_ip}:{server_port}",
        "Token": token,
        "ProtocolVersion": 1,
        "DefaultMode": mode,
    }


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
        if not isinstance(config, dict):
            raise ValueError("Debug config root must be a dictionary")
        shutil.copy2(source, destination)
        print(f"[+] Copied debug config to {destination}")
        return config

    server_ip = choose_server_ip(settings.server_ip, adapter_records)
    token = settings.token or secrets.token_urlsafe(32)
    config = make_debug_config(
        server_ip, settings.server_port, token, settings.mode
    )
    with destination.open("wb") as file:
        plistlib.dump(config, file, fmt=plistlib.FMT_BINARY)
    print(f"[+] Generated debug config at {destination}")
    print(f"[+] Debug server: {config['BaseURL']}")
    print(f"[+] Debug token: {config['Token']}")
    return config


def _debug_settings_from_args(args, parser):
    generation_values = (
        args.server_ip,
        args.server_port,
        args.debug_token,
        args.debug_mode,
    )
    if args.debug_config is not None and any(
        value is not None for value in generation_values
    ):
        parser.error(
            "--debug-config cannot be combined with generated-config options"
        )

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
    )


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


def inject_ipa(ipa_path, dylib_path, output_path, debug_settings=None):
    """Inject one dylib and return the generated/copied debug config, if any."""
    ipa_path = Path(ipa_path)
    dylib_path = Path(dylib_path)
    output_path = Path(output_path)
    settings = debug_settings or DebugSettings()

    if not ipa_path.is_file():
        raise FileNotFoundError(f"IPA not found: {ipa_path}")
    if not dylib_path.is_file():
        raise FileNotFoundError(f"Dylib not found: {dylib_path}")

    with tempfile.TemporaryDirectory(prefix="amproj_inject_") as temp_dir:
        print(f"[*] Temp dir: {temp_dir}")
        print(f"[*] Extracting {ipa_path}...")
        shutil.unpack_archive(str(ipa_path), temp_dir, "zip")
        app_dir = _find_app_bundle(temp_dir)

        frameworks = app_dir / "Frameworks"
        frameworks.mkdir(parents=True, exist_ok=True)
        dylib_destination = frameworks / dylib_path.name
        shutil.copy2(dylib_path, dylib_destination)
        print(f"[+] Copied dylib to {dylib_destination}")

        executable = _bundle_executable(app_dir)
        patched = insert_load_dylib(str(executable), str(dylib_destination))
        if not patched:
            print("[*] Binary already patched, continuing...")

        config = install_debug_config(app_dir, settings)
        patch_info_plist(app_dir, enable_debug_network=settings.enabled)

        signature = app_dir / "_CodeSignature"
        if signature.exists():
            shutil.rmtree(signature)
        print("[+] Removed old code signature")
        _try_resign(app_dir)

        print(f"[*] Repacking to {output_path}...")
        _repack_ipa(temp_dir, output_path)
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


def _token(value):
    if len(value) < 16:
        raise argparse.ArgumentTypeError("token must contain at least 16 characters")
    return value


def build_argument_parser():
    parser = argparse.ArgumentParser(
        description="Inject an AMProjExport dylib into an iOS IPA."
    )
    parser.add_argument("ipa", help="input IPA")
    parser.add_argument("dylib", help="AMProjExport or AMProjExportDebug dylib")
    parser.add_argument("output", nargs="?", help="output IPA")
    parser.add_argument(
        "--debug-config",
        help=f"copy an existing plist into the app as {DEBUG_CONFIG_NAME}",
    )
    parser.add_argument(
        "--server-ip",
        help="debug backend IPv4 address; otherwise auto-detect RFC 1918 WLAN",
    )
    parser.add_argument("--server-port", type=_port, help="debug backend port")
    parser.add_argument(
        "--debug-token", type=_token, help="debug backend bearer token"
    )
    parser.add_argument("--debug-mode", choices=DEBUG_MODES, help="initial mode")
    return parser


def main(argv=None):
    parser = build_argument_parser()
    args = parser.parse_args(argv)
    settings = _debug_settings_from_args(args, parser)
    input_path = Path(args.ipa)
    output = args.output or str(
        input_path.with_name(f"{input_path.stem}_amproj.ipa")
    )
    try:
        inject_ipa(args.ipa, args.dylib, output, settings)
    except (OSError, ValueError, RuntimeError, shutil.ReadError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
