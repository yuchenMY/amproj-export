#!/usr/bin/env python3
"""Replace the embedded Cloud runtime and update editor assets in an IPA."""

import argparse
import hashlib
import os
import tempfile
import zipfile
from pathlib import Path

import build_862_direct_package as direct
import inject_dylib


CLOUD_PATH = "Payload/AlightMotion.app/Frameworks/AMProjExportCloud.dylib"
HOME_UI_PATH = "Payload/AlightMotion.app/Frameworks/AMHomeUI.dylib"
MAIN_PATH = "Payload/AlightMotion.app/AlightMotion"
HOME_UI_BASENAME = "AMHomeUI.dylib"
BUTTON_IMAGE_PATH = "Payload/AlightMotion.app/autfeng_add_layer_button.png"
CATEGORY_PREFIX = "Payload/AlightMotion.app/BuiltinCategory/thumb/"
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


def category_path(name):
    return CATEGORY_PREFIX + name


def new_zip_info(name, executable=False):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (0o100755 if executable else 0o100644) << 16
    return info


def ensure_no_home_ui_loads(info, context):
    commands = [
        command
        for command in info["dylib_load_commands"]
        if command["name"].rsplit("/", 1)[-1] == HOME_UI_BASENAME
    ]
    if commands:
        found = ", ".join(
            f"{command['command']} {command['name']}" for command in commands
        )
        raise RuntimeError(
            f"{context} must not contain an AMHomeUI load command; found {found}"
        )


def verify_cloud_embedded_home_ui(dylib_path):
    info = inject_dylib.verify_dylib_architecture(dylib_path)
    ensure_no_home_ui_loads(info, "Cloud dylib")
    if "_AMHomeUIInstall" not in info["external_defined_symbols"]:
        raise RuntimeError("Cloud dylib must define _AMHomeUIInstall")
    cloud = Path(dylib_path).read_bytes()
    if b"https://amhome.meowcr.cn/home" not in cloud:
        raise RuntimeError("Cloud dylib is missing the AutFeng home URL")


def package(source_path, output_path, dylib_path, image_path, category_directory):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    dylib = Path(dylib_path).resolve().read_bytes()
    image = Path(image_path).resolve().read_bytes()
    category_directory = Path(category_directory).resolve()
    category_images = {
        category_path(name): (category_directory / name).read_bytes()
        for name in CATEGORY_NAMES
    }
    direct.verify_cloud_runtime_version(dylib)
    direct.verify_cloud_stability_contract(dylib)
    direct.prepare_cloud(dylib)
    verify_cloud_embedded_home_ui(dylib_path)

    with zipfile.ZipFile(source_path, "r") as source:
        names = source.namelist()
        if len(names) != len(set(names)) or source.testzip() is not None:
            raise RuntimeError("source IPA ZIP validation failed")
        if names.count(CLOUD_PATH) != 1:
            raise RuntimeError("source IPA must contain one Cloud dylib")
        if names.count(MAIN_PATH) != 1 or names.count(HOME_UI_PATH) > 1:
            raise RuntimeError("source IPA has an unexpected Home UI layout")
        source_main = source.read(MAIN_PATH)
        source_main_info = inject_dylib.parse_macho_data(source_main, MAIN_PATH)
        ensure_no_home_ui_loads(source_main_info, "source main")
        missing_categories = [
            name
            for name in category_images
            if name not in names
            and not name.endswith("ic_category_thumbnail_other.png")
        ]
        if missing_categories:
            raise RuntimeError(
                f"source IPA is missing effect category images: {missing_categories}"
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
                if info.filename == HOME_UI_PATH:
                    continue
                payload = b"" if info.is_dir() else source.read(info.filename)
                if info.filename == CLOUD_PATH:
                    payload = dylib
                elif info.filename == MAIN_PATH:
                    payload = source_main
                elif info.filename == BUTTON_IMAGE_PATH:
                    payload = image
                elif info.filename in category_images:
                    payload = category_images[info.filename]
                output_info = copy_zip_info(info)
                output.writestr(output_info, payload)

            if BUTTON_IMAGE_PATH not in source.namelist():
                output.writestr(new_zip_info(BUTTON_IMAGE_PATH), image)
            for name, payload in category_images.items():
                if name not in source.namelist():
                    output.writestr(new_zip_info(name), payload)

        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "r"
        ) as output:
            if output.testzip() is not None:
                raise RuntimeError("output IPA CRC validation failed")
            expected_names = (set(source.namelist()) - {HOME_UI_PATH}) | {
                BUTTON_IMAGE_PATH,
                *category_images,
            }
            if set(output.namelist()) != expected_names:
                raise RuntimeError("output IPA member set changed unexpectedly")
            if output.read(CLOUD_PATH) != dylib:
                raise RuntimeError("output Cloud dylib mismatch")
            if HOME_UI_PATH in output.namelist():
                raise RuntimeError("output IPA must not contain AMHomeUI.dylib")
            output_main = output.read(MAIN_PATH)
            output_main_info = inject_dylib.parse_macho_data(output_main, MAIN_PATH)
            ensure_no_home_ui_loads(output_main_info, "output main")
            if output_main != source_main:
                raise RuntimeError("output main executable changed")
            if output.read(BUTTON_IMAGE_PATH) != image:
                raise RuntimeError("output editor button image mismatch")
            for name, payload in category_images.items():
                if output.read(name) != payload:
                    raise RuntimeError(f"output effect category image mismatch: {name}")
            for name in source.namelist():
                if (
                    name == CLOUD_PATH
                    or name == MAIN_PATH
                    or name == HOME_UI_PATH
                    or name == BUTTON_IMAGE_PATH
                    or name in category_images
                    or source.getinfo(name).is_dir()
                ):
                    continue
                if sha256(source.read(name)) != sha256(output.read(name)):
                    raise RuntimeError(f"unrelated IPA member changed: {name}")
        os.replace(candidate, output_path)

    return {
        "input_sha256": sha256(source_path.read_bytes()),
        "output_sha256": sha256(output_path.read_bytes()),
        "dylib_sha256": sha256(dylib),
        "image_sha256": sha256(image),
        "category_image_sha256": {
            Path(name).name: sha256(payload)
            for name, payload in sorted(category_images.items())
        },
        "output": str(output_path),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("dylib")
    parser.add_argument("image")
    parser.add_argument("category_directory")
    args = parser.parse_args()
    print(
        package(
            args.source,
            args.output,
            args.dylib,
            args.image,
            args.category_directory,
        )
    )


if __name__ == "__main__":
    main()
