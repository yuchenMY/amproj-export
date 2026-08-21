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


CLOUD_PATH = "Payload/AlightMotion.app/Frameworks/AMProjExportCloud.dylib"
HOME_UI_PATH = "Payload/AlightMotion.app/Frameworks/AMHomeUI.dylib"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


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


def package(source_path, output_path, dylib_path):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    dylib_path = Path(dylib_path).resolve()
    dylib = dylib_path.read_bytes()

    direct.verify_cloud_runtime_version(dylib)
    direct.verify_cloud_stability_contract(dylib)
    direct.prepare_cloud(dylib)
    with zipfile.ZipFile(source_path, "r") as source:
        names = source.namelist()
        if len(names) != len(set(names)) or source.testzip() is not None:
            raise RuntimeError("source IPA ZIP validation failed")
        if names.count(CLOUD_PATH) != 1:
            raise RuntimeError("source IPA must contain exactly one Cloud dylib")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".build-", dir=output_path.parent
    ) as temporary_directory:
        candidate = Path(temporary_directory) / "candidate.ipa"
        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "w", allowZip64=True
        ) as output:
            for info in source.infolist():
                if info.filename == HOME_UI_PATH:
                    continue
                payload = b"" if info.is_dir() else source.read(info.filename)
                if info.filename == CLOUD_PATH:
                    payload = dylib
                output.writestr(copy_zip_info(info), payload)

        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "r"
        ) as output:
            if output.testzip() is not None:
                raise RuntimeError("output IPA CRC validation failed")
            expected_names = [
                name for name in source.namelist() if name != HOME_UI_PATH
            ]
            if output.namelist() != expected_names:
                raise RuntimeError("output IPA member layout changed unexpectedly")
            if output.read(CLOUD_PATH) != dylib:
                raise RuntimeError("output Cloud dylib mismatch")
            if HOME_UI_PATH in output.namelist():
                raise RuntimeError("output IPA must not contain AMHomeUI.dylib")
            for info in source.infolist():
                if (
                    info.filename == CLOUD_PATH
                    or info.filename == HOME_UI_PATH
                    or info.is_dir()
                ):
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
        "output": str(output_path),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="existing resign-ready IPA")
    parser.add_argument("output", help="new resign-ready IPA")
    parser.add_argument("dylib", help="fresh AMProjExportCloud.dylib")
    args = parser.parse_args()
    print(json.dumps(package(args.source, args.output, args.dylib), indent=2))


if __name__ == "__main__":
    main()
