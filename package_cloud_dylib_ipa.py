#!/usr/bin/env python3
"""Replace only AMProjExportCloud.dylib in a resign-ready IPA."""

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path

import build_862_direct_package as direct
import home_ui_contract as homeui
import inject_dylib


CLOUD_PATH = "Payload/AlightMotion.app/Frameworks/AMProjExportCloud.dylib"
HOME_UI_PATH = "Payload/AlightMotion.app/Frameworks/AMHomeUI.dylib"
MAIN_PATH = "Payload/AlightMotion.app/AlightMotion"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def copy_zip_info(info, *, executable=None):
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


def _new_zip_info(name, executable=False):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (0o100755 if executable else 0o100644) << 16
    return info


def package(source_path, output_path, dylib_path, home_ui_path=None):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    dylib_path = Path(dylib_path).resolve()
    dylib = dylib_path.read_bytes()
    home_ui_explicit = home_ui_path is not None
    supplied_home_ui = (
        Path(home_ui_path).resolve().read_bytes() if home_ui_path else None
    )

    direct.verify_cloud_runtime_version(dylib)
    direct.verify_cloud_stability_contract(dylib)
    direct.prepare_cloud(dylib)
    homeui.verify_cloud_payload(dylib, "Cloud dylib")
    if supplied_home_ui is not None and home_ui_explicit:
        homeui.verify_home_ui_payload(home_ui_path, supplied_home_ui)
    with zipfile.ZipFile(source_path, "r") as source:
        names = source.namelist()
        if len(names) != len(set(names)) or source.testzip() is not None:
            raise RuntimeError("source IPA ZIP validation failed")
        if names.count(CLOUD_PATH) != 1:
            raise RuntimeError("source IPA must contain exactly one Cloud dylib")
        source_has_home_ui = names.count(HOME_UI_PATH) == 1
        if names.count(HOME_UI_PATH) > 1:
            raise RuntimeError("source IPA contains duplicate AMHomeUI members")
        if supplied_home_ui is None and source_has_home_ui:
            inferred = source.read(HOME_UI_PATH)
            # A HomeUI member is executable code. Never carry a placeholder or
            # an old malformed payload into a new handoff archive.
            homeui.verify_home_ui_payload(HOME_UI_PATH, inferred)
            supplied_home_ui = inferred

        source_main = source.read(MAIN_PATH) if names.count(MAIN_PATH) == 1 else None
        main = source_main
        if supplied_home_ui is not None:
            if main is None:
                raise RuntimeError("standalone Home UI requires the main executable")
            main_info = inject_dylib.parse_macho_data(main, MAIN_PATH)
            loads = homeui.home_ui_loads(main_info)
            if len(loads) > 1:
                raise RuntimeError("source main contains duplicate AMHomeUI loads")
            if loads:
                homeui.ensure_home_ui_load_contract(main_info, "source main")
            else:
                main = homeui.patch_main_with_home_ui(main, MAIN_PATH)
        elif main is not None:
            main_info = inject_dylib.parse_macho_data(main, MAIN_PATH)
            if homeui.home_ui_loads(main_info):
                raise RuntimeError(
                    "source main loads AMHomeUI but no standalone member is available"
                )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".build-", dir=output_path.parent
    ) as temporary_directory:
        candidate = Path(temporary_directory) / "candidate.ipa"
        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "w", allowZip64=True
        ) as output:
            for info in source.infolist():
                payload = b"" if info.is_dir() else source.read(info.filename)
                if info.filename == CLOUD_PATH:
                    payload = dylib
                elif info.filename == MAIN_PATH and main is not None:
                    payload = main
                elif info.filename == HOME_UI_PATH and supplied_home_ui is not None:
                    payload = supplied_home_ui
                output.writestr(
                    copy_zip_info(
                        info,
                        executable=(info.filename == HOME_UI_PATH)
                        if supplied_home_ui is not None
                        else None,
                    ),
                    payload,
                )
            if supplied_home_ui is not None and HOME_UI_PATH not in source.namelist():
                output.writestr(
                    _new_zip_info(HOME_UI_PATH, executable=True), supplied_home_ui
                )

        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "r"
        ) as output:
            if output.testzip() is not None:
                raise RuntimeError("output IPA CRC validation failed")
            expected_names = list(source.namelist())
            if supplied_home_ui is not None and HOME_UI_PATH not in expected_names:
                expected_names.append(HOME_UI_PATH)
            if output.namelist() != expected_names:
                raise RuntimeError("output IPA member layout changed unexpectedly")
            if output.read(CLOUD_PATH) != dylib:
                raise RuntimeError("output Cloud dylib mismatch")
            if supplied_home_ui is not None:
                if output.read(HOME_UI_PATH) != supplied_home_ui:
                    raise RuntimeError("output Home UI dylib mismatch")
                if main is not None:
                    output_info = inject_dylib.parse_macho_data(
                        output.read(MAIN_PATH), MAIN_PATH
                    )
                    homeui.ensure_home_ui_load_contract(output_info, "output main")
            elif HOME_UI_PATH in output.namelist():
                raise RuntimeError(
                    "output IPA contains AMHomeUI without a validated standalone payload"
                )
            for info in source.infolist():
                if info.filename in {CLOUD_PATH, HOME_UI_PATH, MAIN_PATH} or info.is_dir():
                    continue
                if sha256(source.read(info.filename)) != sha256(
                    output.read(info.filename)
                ):
                    raise RuntimeError(
                        f"unrelated IPA member changed: {info.filename}"
                    )
        os.replace(candidate, output_path)

    return {
        "input_sha256": sha256(source_path.read_bytes()),
        "output_sha256": sha256(output_path.read_bytes()),
        "dylib_sha256": sha256(dylib),
        "home_ui_sha256": (
            sha256(supplied_home_ui) if supplied_home_ui is not None else None
        ),
        "home_ui_member": HOME_UI_PATH if supplied_home_ui is not None else None,
        "output": str(output_path),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="existing resign-ready IPA")
    parser.add_argument("output", help="new resign-ready IPA")
    parser.add_argument("dylib", help="fresh AMProjExportCloud.dylib")
    parser.add_argument(
        "--home-ui", dest="home_ui", help="standalone AMHomeUI.dylib (optional)"
    )
    args = parser.parse_args()
    print(
        json.dumps(
            package(args.source, args.output, args.dylib, args.home_ui), indent=2
        )
    )


if __name__ == "__main__":
    main()
