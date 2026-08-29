"""Shared contract for the standalone AMHomeUI runtime.

The Home UI is deliberately a separate Mach-O image.  Keeping the identity
and main-executable load checks in one small module prevents the several IPA
packagers from drifting back to the historical Cloud-embedded layout.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import inject_dylib


HOME_UI_BASENAME = "AMHomeUI.dylib"
HOME_UI_LOAD = "@executable_path/Frameworks/AMHomeUI.dylib"
HOME_UI_INSTALL_NAME = "@rpath/AMHomeUI.dylib"
HOME_UI_URL = b"https://amhome.meowcr.cn/home"
HOME_UI_INSTALL_SYMBOL = "_AMHomeUIInstall"


def _payload_and_label(path_or_payload, payload=None):
    if payload is not None:
        return bytes(payload), str(path_or_payload)
    if isinstance(path_or_payload, (str, Path)):
        path = Path(path_or_payload)
        return path.read_bytes(), str(path)
    return bytes(path_or_payload), "<memory>"


def _parse(payload: bytes, label: str):
    try:
        return inject_dylib.parse_macho_data(payload, label)
    except (ValueError, OSError) as error:
        raise RuntimeError(f"{label} is not a valid thin Mach-O image") from error


def home_ui_loads(info):
    """Return every load command whose basename is AMHomeUI.dylib."""
    return [
        command
        for command in info.get("dylib_load_commands", ())
        if command.get("name", "").rsplit("/", 1)[-1] == HOME_UI_BASENAME
    ]


def ensure_no_home_ui_loads(info, context="Cloud dylib"):
    loads = home_ui_loads(info)
    if loads:
        found = ", ".join(
            f"{item.get('command', item.get('cmd'))} {item.get('name', '')}"
            for item in loads
        )
        raise RuntimeError(f"{context} must not contain an AMHomeUI load command; found {found}")


def ensure_home_ui_load_contract(info, context="main executable"):
    """Require one strong load at the executable-relative Frameworks path."""
    loads = home_ui_loads(info)
    if len(loads) != 1:
        raise RuntimeError(
            f"{context} must strongly load AMHomeUI exactly once; found {len(loads)}"
        )
    command = loads[0]
    if command.get("name") != HOME_UI_LOAD or command.get("cmd") != inject_dylib.LC_LOAD_DYLIB:
        raise RuntimeError(
            f"{context} has a conflicting AMHomeUI load: "
            f"{command.get('command', command.get('cmd'))} {command.get('name')}"
        )
    return command


def verify_home_ui_payload(path_or_payload, payload=None):
    """Validate the standalone HomeUI ABI, identity, export, and URL."""
    data, label = _payload_and_label(path_or_payload, payload)
    info = _parse(data, label)
    if info.get("cputype") != inject_dylib.CPU_TYPE_ARM64:
        raise RuntimeError(f"{label} must be a thin arm64 dylib")
    if info.get("filetype") != inject_dylib.MH_DYLIB:
        raise RuntimeError(f"{label} must be MH_DYLIB")
    if info.get("id_dylibs") != [HOME_UI_INSTALL_NAME]:
        raise RuntimeError(
            f"{label} install name must be {HOME_UI_INSTALL_NAME}"
        )
    if HOME_UI_INSTALL_SYMBOL not in info.get("external_defined_symbols", ()):
        raise RuntimeError(f"{label} must export {HOME_UI_INSTALL_SYMBOL}")
    if HOME_UI_URL not in data:
        raise RuntimeError(f"{label} is missing the AutFeng home URL")
    return info


def verify_cloud_payload(path_or_payload, context="Cloud dylib"):
    """Reject the old Cloud-embedded HomeUI implementation."""
    data, label = _payload_and_label(path_or_payload)
    # A malformed fixture should still receive the caller's normal Mach-O
    # error from the Cloud verifier.  For real binaries, enforce all split
    # runtime invariants here.
    try:
        info = _parse(data, label)
    except RuntimeError:
        return True
    ensure_no_home_ui_loads(info, context)
    if HOME_UI_INSTALL_SYMBOL in info.get("external_defined_symbols", ()):
        raise RuntimeError(f"{context} must not define {HOME_UI_INSTALL_SYMBOL}")
    if HOME_UI_URL in data:
        raise RuntimeError(f"{context} must not embed the Home UI URL")
    return True


def patch_main_with_home_ui(main: bytes, label="AlightMotion") -> bytes:
    """Inject one strong HomeUI load without moving Mach-O sections."""
    with tempfile.TemporaryDirectory(prefix="am-home-ui-main-") as directory:
        main_path = Path(directory) / Path(label).name
        placeholder = Path(directory) / HOME_UI_BASENAME
        main_path.write_bytes(main)
        # inject_dylib derives the load name from the basename only.
        placeholder.write_bytes(b"")
        inject_dylib.insert_load_dylib(str(main_path), str(placeholder))
        patched = main_path.read_bytes()
    info = _parse(patched, label)
    ensure_home_ui_load_contract(info, label)
    return patched
