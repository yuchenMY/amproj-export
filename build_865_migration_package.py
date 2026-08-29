#!/usr/bin/env python3
"""Build an LCSign handoff by migrating the verified Cloud feature set to 6.2.58.

The historical 6.2.55 packager intentionally pins a different app UUID, version,
and native import offsets. This entry point keeps the 6.2.58 application
executable and resources as the authority, then applies only the portable Cloud
load, plist, and editor-asset changes. Cloud payload validation lives in the
version-neutral ``cloud_payload_contract`` module so this lane has no import-time
dependency on the 6.2.55 packager.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import tempfile
import zipfile
from pathlib import Path

import cloud_payload_contract as cloud_contract
import home_ui_contract as homeui
import inject_dylib


APP_ROOT = "Payload/AlightMotion.app/"
MAIN_PATH = APP_ROOT + "AlightMotion"
INFO_PATH = APP_ROOT + "Info.plist"
CLOUD_PATH = APP_ROOT + "Frameworks/AMProjExport.dylib"
LEGACY_CLOUD_PATH = APP_ROOT + "Frameworks/AMProjExportCloud.dylib"
CLOUD_BASENAME = "AMProjExport.dylib"
LEGACY_CLOUD_BASENAME = "AMProjExportCloud.dylib"
CLOUD_LOAD = "@executable_path/Frameworks/AMProjExport.dylib"
LEGACY_CLOUD_LOAD = "@executable_path/Frameworks/AMProjExportCloud.dylib"
# The 865 package loads the Cloud dylib directly.  A previously injected
# AMMeowLoader would dlopen the same library a second way during startup.
LOADER_BASENAME = "AMMeowLoader.dylib"
LOADER_PATH = APP_ROOT + "Frameworks/" + LOADER_BASENAME
HOME_UI_PATH = APP_ROOT + "Frameworks/AMHomeUI.dylib"
BUTTON_PATH = APP_ROOT + "autfeng_add_layer_button.png"
CATEGORY_PREFIX = APP_ROOT + "BuiltinCategory/thumb/"

CATEGORY_NAMES = (
    "ic_category_thumbnail_3d.png",
    "ic_category_thumbnail_blur.png",
    "ic_category_thumbnail_colorlight.png",
    "ic_category_thumbnail_drawingedge.png",
    "ic_category_thumbnail_mask.png",
    "ic_category_thumbnail_movetransform.png",
    "ic_category_thumbnail_opacity.png",
    "ic_category_thumbnail_other.png",
    "ic_category_thumbnail_procedural.png",
    "ic_category_thumbnail_repeat.png",
    "ic_category_thumbnail_text.png",
    "ic_category_thumbnail_warp.png",
)

AMPROJ_UTI = "com.alightcreative.motion.amproj"
AMPROJ_UTI_CONFORMANCES = ["public.data", "public.archive", "public.zip-archive"]
XML_UTI = "public.xml"
EXPECTED_VERSION = "6.2.58"
EXPECTED_BUILD = "865"
DEFAULT_BUNDLE_ID = "com.ayakameow.am"
DEFAULT_DISPLAY_NAME = "\u732b\u9e64AM-Meow"
DEFAULT_BUNDLE_NAME = "\u732b\u9e64AM"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def copy_zip_info(
    info: zipfile.ZipInfo, *, executable: bool | None = None
) -> zipfile.ZipInfo:
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
        # LCSign extracts the IPA on Darwin. A Windows-created ZIP entry with
        # a Unix-looking mode is still not reliable for a loadable Mach-O.
        clone.create_system = 3
        clone.external_attr = (0o100755 if executable else 0o100644) << 16
    return clone


def new_zip_info(name: str, *, executable: bool = False) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (0o100755 if executable else 0o100644) << 16
    return info


def category_path(name: str) -> str:
    return CATEGORY_PREFIX + name


def _is_signature_entry(name: str) -> bool:
    return "/_CodeSignature/" in name or name.endswith("/_CodeSignature")


def _dylib_loads(info: dict, path: str) -> list[dict]:
    return [
        command
        for command in info["dylib_load_commands"]
        if command["name"] == path
    ]


def _member_basename(name: str) -> str:
    return name.rstrip("/").rsplit("/", 1)[-1]


def _dylib_loads_by_basename(info: dict, basename: str) -> list[dict]:
    return [
        command
        for command in info["dylib_load_commands"]
        if _member_basename(command["name"]) == basename
    ]


def _require_canonical_load_path(
    commands: list[dict], expected_path: str, label: str
) -> None:
    unexpected = [command["name"] for command in commands if command["name"] != expected_path]
    if unexpected:
        raise RuntimeError(
            f"{label} contains an unsupported dylib load path: "
            + ", ".join(sorted(unexpected))
        )


def _loader_loads(info: dict) -> list[dict]:
    return _dylib_loads_by_basename(info, LOADER_BASENAME)


def _reject_loader_loads(info: dict, label: str) -> None:
    if _loader_loads(info):
        raise RuntimeError(
            f"{label} loads {LOADER_BASENAME}; 6.2.58 must load "
            "AMProjExport.dylib directly"
        )


def _rewrite_legacy_cloud_load(data: bytes, command: dict) -> bytes:
    """Rename the legacy load inside its existing LC_LOAD_DYLIB storage."""
    if command["cmd"] != inject_dylib.LC_LOAD_DYLIB:
        raise RuntimeError("6.2.58 legacy Cloud load is not LC_LOAD_DYLIB")
    command_offset = command["offset"]
    command_size = command["cmdsize"]
    name_offset = int.from_bytes(
        data[command_offset + 8 : command_offset + 12], "little"
    )
    name_start = command_offset + name_offset
    name_limit = command_offset + command_size
    expected = LEGACY_CLOUD_LOAD.encode("utf-8") + b"\0"
    if (
        name_offset < 24
        or name_start + len(expected) > name_limit
        or data[name_start : name_start + len(expected)] != expected
    ):
        raise RuntimeError("legacy Cloud load command payload is invalid")
    replacement = CLOUD_LOAD.encode("utf-8") + b"\0"
    if len(replacement) > name_limit - name_start:
        raise RuntimeError("new Cloud load path does not fit legacy command storage")
    result = bytearray(data)
    result[name_start:name_limit] = replacement.ljust(name_limit - name_start, b"\0")
    return bytes(result)


def _document_type(plist: dict, uti: str) -> dict | None:
    for item in plist.get("CFBundleDocumentTypes", []):
        if isinstance(item, dict) and uti in item.get("LSItemContentTypes", []):
            return item
    return None


def _exported_type(plist: dict, uti: str) -> dict | None:
    for item in plist.get("UTExportedTypeDeclarations", []):
        if isinstance(item, dict) and item.get("UTTypeIdentifier") == uti:
            return item
    return None


def prepare_info_plist(data: bytes, bundle_id: str, display_name: str) -> bytes:
    plist = plistlib.loads(data)
    if not isinstance(plist, dict):
        raise RuntimeError("6.2.58 Info.plist root is not a dictionary")
    if plist.get("CFBundleExecutable") != "AlightMotion":
        raise RuntimeError("unexpected Alight Motion executable name")
    if plist.get("CFBundleShortVersionString") != EXPECTED_VERSION:
        raise RuntimeError("input IPA is not Alight Motion 6.2.58")
    if plist.get("CFBundleVersion") != EXPECTED_BUILD:
        raise RuntimeError("input IPA is not Build 865")

    plist["CFBundleDisplayName"] = display_name
    plist["CFBundleName"] = DEFAULT_BUNDLE_NAME
    plist["CFBundleIdentifier"] = bundle_id
    # Match the previously verified document-import contract while retaining
    # every 6.2.58 URL, icon, privacy, and feature key.
    plist["LSSupportsOpeningDocumentsInPlace"] = False
    plist["UISupportsDocumentBrowser"] = False
    plist.pop("UIUserInterfaceStyle", None)

    declarations = plist.get("UTExportedTypeDeclarations")
    if not isinstance(declarations, list):
        declarations = []
        plist["UTExportedTypeDeclarations"] = declarations
    if _exported_type(plist, AMPROJ_UTI) is None:
        declarations.append(
            {
                "UTTypeIdentifier": AMPROJ_UTI,
                "UTTypeDescription": "Alight Motion Project",
                "UTTypeConformsTo": list(AMPROJ_UTI_CONFORMANCES),
                "UTTypeTagSpecification": {
                    "public.filename-extension": ["amproj"],
                    "public.mime-type": ["application/x-amproj"],
                },
            }
        )

    document_types = plist.get("CFBundleDocumentTypes")
    if not isinstance(document_types, list):
        document_types = []
        plist["CFBundleDocumentTypes"] = document_types
    if _document_type(plist, AMPROJ_UTI) is None:
        document_types.append(
            {
                "CFBundleTypeName": "Alight Motion Project",
                "CFBundleTypeRole": "Editor",
                "LSHandlerRank": "Owner",
                "LSItemContentTypes": [AMPROJ_UTI],
            }
        )
    if _document_type(plist, XML_UTI) is None:
        document_types.append(
            {
                "CFBundleTypeName": "Alight Motion XML Project",
                "CFBundleTypeRole": "Editor",
                "LSHandlerRank": "Alternate",
                "LSItemContentTypes": [XML_UTI],
            }
        )

    result = plistlib.dumps(plist, fmt=plistlib.FMT_BINARY, sort_keys=False)
    verified = plistlib.loads(result)
    expected = {
        "CFBundleDisplayName": display_name,
        "CFBundleName": DEFAULT_BUNDLE_NAME,
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": EXPECTED_VERSION,
        "CFBundleVersion": EXPECTED_BUILD,
        "LSSupportsOpeningDocumentsInPlace": False,
        "UISupportsDocumentBrowser": False,
    }
    for key, value in expected.items():
        if verified.get(key) != value:
            raise RuntimeError(f"prepared Info.plist {key} mismatch")
    if _document_type(verified, AMPROJ_UTI) is None or _document_type(verified, XML_UTI) is None:
        raise RuntimeError("prepared Info.plist is missing project/XML registration")
    return result


def prepare_main(data: bytes, include_home_ui: bool = False) -> bytes:
    info = inject_dylib.parse_macho_data(data, "6.2.58 AlightMotion")
    if info["cputype"] != inject_dylib.CPU_TYPE_ARM64 or info["filetype"] != inject_dylib.MH_EXECUTE:
        raise RuntimeError("6.2.58 main executable is not thin arm64 MH_EXECUTE")
    if info["uuid"] != "c8d53b88593d3a4082a11805d1835cd0":
        raise RuntimeError(f"unexpected 6.2.58 main UUID: {info['uuid']}")
    _reject_loader_loads(info, "6.2.58 main")
    existing_home_ui = homeui.home_ui_loads(info)
    if len(existing_home_ui) > 1:
        raise RuntimeError("6.2.58 main contains duplicate AMHomeUI loads")
    if existing_home_ui:
        homeui.ensure_home_ui_load_contract(info, "6.2.58 main")
    cloud_loads = _dylib_loads_by_basename(info, CLOUD_BASENAME)
    legacy_cloud_loads = _dylib_loads_by_basename(info, LEGACY_CLOUD_BASENAME)
    _require_canonical_load_path(cloud_loads, CLOUD_LOAD, "6.2.58 main")
    _require_canonical_load_path(
        legacy_cloud_loads, LEGACY_CLOUD_LOAD, "6.2.58 main"
    )
    if len(cloud_loads) > 1 or len(legacy_cloud_loads) > 1:
        raise RuntimeError("6.2.58 contains duplicate Cloud load commands")
    if cloud_loads and legacy_cloud_loads:
        raise RuntimeError("6.2.58 contains both current and legacy Cloud loads")
    if cloud_loads:
        if cloud_loads[0]["cmd"] != inject_dylib.LC_LOAD_DYLIB:
            raise RuntimeError("6.2.58 contains a conflicting Cloud load command")
        result = data
    elif legacy_cloud_loads:
        result = _rewrite_legacy_cloud_load(data, legacy_cloud_loads[0])
    else:
        with tempfile.TemporaryDirectory(prefix="amproj-865-main-") as directory:
            path = Path(directory) / "AlightMotion"
            path.write_bytes(data)
            inject_dylib.insert_load_dylib(str(path), "AMProjExport.dylib")
            result = path.read_bytes()

    if include_home_ui:
        patched_info = inject_dylib.parse_macho_data(result, "patched 6.2.58 AlightMotion")
        if not homeui.home_ui_loads(patched_info):
            with tempfile.TemporaryDirectory(prefix="amproj-865-home-ui-") as directory:
                path = Path(directory) / "AlightMotion"
                path.write_bytes(result)
                inject_dylib.insert_load_dylib(str(path), homeui.HOME_UI_BASENAME)
                result = path.read_bytes()

    patched = inject_dylib.parse_macho_data(result, "patched 6.2.58 AlightMotion")
    _reject_loader_loads(patched, "patched 6.2.58 main")
    cloud_loads = _dylib_loads_by_basename(patched, CLOUD_BASENAME)
    legacy_cloud_loads = _dylib_loads_by_basename(
        patched, LEGACY_CLOUD_BASENAME
    )
    _require_canonical_load_path(cloud_loads, CLOUD_LOAD, "patched 6.2.58 main")
    _require_canonical_load_path(
        legacy_cloud_loads, LEGACY_CLOUD_LOAD, "patched 6.2.58 main"
    )
    if len(cloud_loads) != 1 or cloud_loads[0]["cmd"] != inject_dylib.LC_LOAD_DYLIB:
        raise RuntimeError("patched 6.2.58 main does not strongly load Cloud")
    if legacy_cloud_loads:
        raise RuntimeError("patched 6.2.58 main still loads legacy Cloud")
    if include_home_ui:
        homeui.ensure_home_ui_load_contract(patched, "patched 6.2.58 main")
    if patched["uuid"] != info["uuid"]:
        raise RuntimeError("Cloud/Home UI load injection changed the main UUID")
    return result


def verify_cloud(cloud_path: Path) -> bytes:
    data = cloud_path.read_bytes()
    info = inject_dylib.parse_macho_data(data, str(cloud_path))
    if info["cputype"] != inject_dylib.CPU_TYPE_ARM64 or info["filetype"] != inject_dylib.MH_DYLIB:
        raise RuntimeError("Cloud dylib must be a thin arm64 MH_DYLIB")
    expected_install_name = "@rpath/" + CLOUD_BASENAME
    if len(info["id_dylibs"]) != 1:
        raise RuntimeError(
            "Cloud dylib must contain exactly one LC_ID_DYLIB install name"
        )
    if info["id_dylibs"][0] != expected_install_name:
        raise RuntimeError(
            "Cloud dylib install name must be " + expected_install_name
        )
    cloud_contract.verify_cloud_runtime_version(data)
    cloud_contract.verify_cloud_stability_contract(data)
    homeui.verify_cloud_payload(data, str(cloud_path))
    return data


def package(
    source_path: str | Path,
    output_path: str | Path,
    cloud_path: str | Path,
    category_directory: str | Path,
    button_path: str | Path,
    home_ui_path: str | Path | None = None,
    *,
    bundle_id: str = DEFAULT_BUNDLE_ID,
    display_name: str = DEFAULT_DISPLAY_NAME,
) -> dict:
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    cloud_path = Path(cloud_path).resolve()
    category_directory = Path(category_directory).resolve()
    button_path = Path(button_path).resolve()
    home_ui_path = Path(home_ui_path).resolve() if home_ui_path else None
    if source_path == output_path:
        raise RuntimeError("output IPA must differ from source IPA")
    if not source_path.is_file():
        raise FileNotFoundError(source_path)
    if not cloud_path.is_file():
        raise FileNotFoundError(cloud_path)
    if not category_directory.is_dir():
        raise FileNotFoundError(category_directory)
    if not button_path.is_file():
        raise FileNotFoundError(button_path)
    if home_ui_path is not None and not home_ui_path.is_file():
        raise FileNotFoundError(home_ui_path)
    cloud = verify_cloud(cloud_path)
    supplied_home_ui = (
        home_ui_path.read_bytes() if home_ui_path is not None else None
    )
    if supplied_home_ui is not None:
        homeui.verify_home_ui_payload(home_ui_path, supplied_home_ui)
    button = button_path.read_bytes()
    categories = {}
    for name in CATEGORY_NAMES:
        path = category_directory / name
        if not path.is_file():
            raise FileNotFoundError(path)
        payload = path.read_bytes()
        if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError(f"category asset is not PNG: {path}")
        categories[category_path(name)] = payload

    with zipfile.ZipFile(source_path, "r") as source:
        names = source.namelist()
        if len(names) != len(set(names)) or source.testzip() is not None:
            raise RuntimeError("source IPA ZIP validation failed")
        if any(name.rsplit("/", 1)[-1] == LOADER_BASENAME for name in names):
            raise RuntimeError(
                "source IPA contains AMMeowLoader; use a clean 6.2.58 baseline "
                "instead of loading AMProjExport.dylib twice"
            )
        legacy_members = [
            name for name in names if _member_basename(name) == LEGACY_CLOUD_BASENAME
        ]
        noncanonical_legacy_members = [
            name for name in legacy_members if name != LEGACY_CLOUD_PATH
        ]
        if noncanonical_legacy_members:
            raise RuntimeError(
                "source IPA contains AMProjExportCloud.dylib outside the canonical "
                "Frameworks path: " + ", ".join(sorted(noncanonical_legacy_members))
            )
        cloud_members = [
            name for name in names if _member_basename(name) == CLOUD_BASENAME
        ]
        noncanonical_cloud_members = [
            name for name in cloud_members if name != CLOUD_PATH
        ]
        if noncanonical_cloud_members:
            raise RuntimeError(
                "source IPA contains AMProjExport.dylib outside the canonical "
                "Frameworks path: " + ", ".join(sorted(noncanonical_cloud_members))
            )
        if names.count(MAIN_PATH) != 1 or names.count(INFO_PATH) != 1:
            raise RuntimeError("source IPA has an unexpected app layout")
        source_main = source.read(MAIN_PATH)
        source_info = source.read(INFO_PATH)
        source_home_ui_present = names.count(HOME_UI_PATH) == 1
        if names.count(HOME_UI_PATH) > 1:
            raise RuntimeError("source IPA contains duplicate standalone Home UI members")
        if supplied_home_ui is None and source_home_ui_present:
            inferred_home_ui = source.read(HOME_UI_PATH)
            homeui.verify_home_ui_payload(HOME_UI_PATH, inferred_home_ui)
            supplied_home_ui = inferred_home_ui
        source_main_info = inject_dylib.parse_macho_data(source_main, MAIN_PATH)
        if homeui.home_ui_loads(source_main_info) and supplied_home_ui is None:
            raise RuntimeError(
                "source main loads AMHomeUI but the standalone Home UI member is missing"
            )
        prepared_main = prepare_main(
            source_main, include_home_ui=supplied_home_ui is not None
        )
        prepared_info = prepare_info_plist(source_info, bundle_id, display_name)

        intended = {MAIN_PATH, INFO_PATH, CLOUD_PATH, BUTTON_PATH, *categories}
        stale = {name for name in names if _is_signature_entry(name)}
        legacy = set(legacy_members)
        if supplied_home_ui is not None:
            intended.add(HOME_UI_PATH)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=output_path.stem + ".build-", dir=output_path.parent
        ) as temporary_directory:
            candidate = Path(temporary_directory) / "migration-resign-ready.ipa"
            with zipfile.ZipFile(candidate, "w", allowZip64=True) as output:
                for info in source.infolist():
                    name = info.filename
                    if name in stale or name in legacy:
                        continue
                    if name == MAIN_PATH:
                        payload = prepared_main
                    elif name == INFO_PATH:
                        payload = prepared_info
                    elif name == CLOUD_PATH:
                        payload = cloud
                    elif name == BUTTON_PATH:
                        payload = button
                    elif name in categories:
                        payload = categories[name]
                    elif name == HOME_UI_PATH and supplied_home_ui is not None:
                        payload = supplied_home_ui
                    else:
                        payload = b"" if info.is_dir() else source.read(info)
                    output.writestr(
                        copy_zip_info(
                            info,
                            # IPA executables and injected dynamic libraries
                            # must retain their executable mode after the ZIP
                            # is extracted by LCSign. Some source archives
                            # carry all members as 0644, so do not inherit
                            # that metadata for these four loadable members.
                            executable=True
                            if name in {MAIN_PATH, CLOUD_PATH, HOME_UI_PATH}
                            else None,
                        ),
                        payload,
                    )
                present = set(names)
                if CLOUD_PATH not in present:
                    output.writestr(
                        new_zip_info(CLOUD_PATH, executable=True), cloud
                    )
                if BUTTON_PATH not in present:
                    output.writestr(new_zip_info(BUTTON_PATH), button)
                if supplied_home_ui is not None and HOME_UI_PATH not in present:
                    output.writestr(
                        new_zip_info(HOME_UI_PATH, executable=True), supplied_home_ui
                    )
                for name, payload in categories.items():
                    if name not in present:
                        output.writestr(new_zip_info(name), payload)

            with zipfile.ZipFile(candidate, "r") as output:
                output_names = output.namelist()
                if len(output_names) != len(set(output_names)) or output.testzip() is not None:
                    raise RuntimeError("output IPA ZIP validation failed")
                if output_names.count(CLOUD_PATH) != 1:
                    raise RuntimeError("AMProjExport.dylib member missing after migration")
                if any(
                    _member_basename(name) == LEGACY_CLOUD_BASENAME
                    for name in output_names
                ):
                    raise RuntimeError("legacy AMProjExportCloud.dylib survived migration")
                if any(
                    _member_basename(name) == CLOUD_BASENAME and name != CLOUD_PATH
                    for name in output_names
                ):
                    raise RuntimeError(
                        "AMProjExport.dylib survived outside the canonical Frameworks path"
                    )
                if any(
                    name.rsplit("/", 1)[-1] == LOADER_BASENAME
                    for name in output_names
                ):
                    raise RuntimeError("AMMeowLoader survived the 6.2.58 migration")
                if output.read(MAIN_PATH) != prepared_main:
                    raise RuntimeError("main executable migration failed")
                if output.read(INFO_PATH) != prepared_info:
                    raise RuntimeError("Info.plist migration failed")
                if output.read(CLOUD_PATH) != cloud:
                    raise RuntimeError("Cloud dylib migration failed")
                output_main_info = inject_dylib.parse_macho_data(
                    output.read(MAIN_PATH), MAIN_PATH
                )
                if len(_dylib_loads(output_main_info, CLOUD_LOAD)) != 1:
                    raise RuntimeError("output main does not load AMProjExport.dylib once")
                if _dylib_loads(output_main_info, LEGACY_CLOUD_LOAD):
                    raise RuntimeError("output main still loads AMProjExportCloud.dylib")
                _reject_loader_loads(output_main_info, "output 6.2.58 main")
                executable_members = {MAIN_PATH, CLOUD_PATH}
                if supplied_home_ui is not None:
                    if output_names.count(HOME_UI_PATH) != 1:
                        raise RuntimeError("standalone AMHomeUI.dylib missing after migration")
                    if output.read(HOME_UI_PATH) != supplied_home_ui:
                        raise RuntimeError("standalone Home UI migration failed")
                    homeui.ensure_home_ui_load_contract(output_main_info, "output main")
                    executable_members.add(HOME_UI_PATH)
                for name in executable_members:
                    member_info = output.getinfo(name)
                    if member_info.create_system != 3:
                        raise RuntimeError(
                            f"loadable IPA member lacks Unix ZIP metadata: {name}"
                        )
                    if member_info.external_attr >> 16 != 0o100755:
                        raise RuntimeError(f"loadable IPA member is not 0755: {name}")
                if output.read(BUTTON_PATH) != button:
                    raise RuntimeError("editor button migration failed")
                for name, payload in categories.items():
                    if output.read(name) != payload:
                        raise RuntimeError(f"category image migration failed: {name}")
                if any(_is_signature_entry(name) for name in output_names):
                    raise RuntimeError("stale CodeResources survived migration")

                changed = intended | stale | legacy
                for name in set(names) - changed:
                    if source.getinfo(name).is_dir():
                        continue
                    if sha256(source.read(name)) != sha256(output.read(name)):
                        raise RuntimeError(f"unrelated IPA member changed: {name}")
            os.replace(candidate, output_path)

    return {
        "input": str(source_path),
        "output": str(output_path),
        "input_sha256": sha256(source_path.read_bytes()),
        "output_sha256": sha256(output_path.read_bytes()),
        "cloud_sha256": sha256(cloud),
        "home_ui_sha256": (
            sha256(supplied_home_ui) if supplied_home_ui is not None else None
        ),
        "home_ui_member": HOME_UI_PATH if supplied_home_ui is not None else None,
        "main_uuid": inject_dylib.parse_macho_data(prepared_main, MAIN_PATH)["uuid"],
        "version": EXPECTED_VERSION,
        "build": EXPECTED_BUILD,
        "bundle_id": bundle_id,
        "category_count": len(categories),
        "removed_stale_signature_entries": len(stale),
        "requires_recursive_lcsign": True,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Migrate AutFeng Cloud features to Alight Motion 6.2.58")
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("cloud")
    parser.add_argument("category_directory")
    parser.add_argument("button")
    parser.add_argument(
        "--home-ui", dest="home_ui", help="standalone AMHomeUI.dylib from the macOS build"
    )
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--display-name", default=DEFAULT_DISPLAY_NAME)
    args = parser.parse_args(argv)
    print(json.dumps(package(
        args.source,
        args.output,
        args.cloud,
        args.category_directory,
        args.button,
        args.home_ui,
        bundle_id=args.bundle_id,
        display_name=args.display_name,
    ), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
