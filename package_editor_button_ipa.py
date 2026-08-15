#!/usr/bin/env python3
"""Replace Cloud, add standalone Home UI, and update editor assets in an IPA."""

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
HOME_UI_INITIALIZER_SECTION_TYPES = frozenset(
    {
        inject_dylib.S_MOD_INIT_FUNC_POINTERS,
        inject_dylib.S_INIT_FUNC_OFFSETS,
    }
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


def ensure_cloud_home_ui_dependency(info, context):
    commands = [
        command
        for command in info["dylib_load_commands"]
        if command["name"].rsplit("/", 1)[-1] == HOME_UI_BASENAME
    ]
    expected_name = "@rpath/AMHomeUI.dylib"
    if len(commands) != 1 or commands[0]["command"] != "LC_LOAD_DYLIB" or (
        commands[0]["name"] != expected_name
    ):
        found = ", ".join(
            f"{command['command']} {command['name']}" for command in commands
        ) or "none"
        raise RuntimeError(
            f"{context} must strongly link {expected_name} exactly once; found {found}"
        )
    forbidden_definitions = {
        "_AMHomeUIInstall",
        "_OBJC_CLASS_$_AMHomeUIController",
        "_OBJC_CLASS_$_AMHomeUIMessageProxy",
    }
    duplicates = forbidden_definitions.intersection(
        info.get("external_defined_symbols", ())
    )
    if duplicates:
        raise RuntimeError(
            f"{context} must not embed Home UI runtime symbols: {sorted(duplicates)}"
        )


def verify_cloud_home_ui_dependency(dylib_path):
    info = inject_dylib.verify_dylib_architecture(dylib_path)
    ensure_cloud_home_ui_dependency(info, "Cloud dylib")


def verify_home_ui_binary(home_ui_path, home_ui):
    info = inject_dylib.verify_dylib_architecture(home_ui_path)
    install_names = info.get("id_dylibs", [])
    expected_install_name = "@rpath/AMHomeUI.dylib"
    if install_names != [expected_install_name]:
        raise RuntimeError(
            f"Home UI dylib install name must be {expected_install_name}"
        )
    initializer_sections = [
        section
        for section in info["sections"]
        if section["type"] in HOME_UI_INITIALIZER_SECTION_TYPES
    ]
    if initializer_sections:
        found = ", ".join(
            f"{section['segment']},{section['section']}"
            for section in initializer_sections
        )
        raise RuntimeError(
            f"Home UI dylib must not contain initializer sections: {found}"
        )
    if "_AMHomeUIInstall" not in info["external_defined_symbols"]:
        raise RuntimeError("Home UI dylib must export _AMHomeUIInstall")
    if b"https://amhome.meowcr.cn/home" not in home_ui:
        raise RuntimeError("Home UI dylib is missing the AutFeng home URL")


def package(source_path, output_path, dylib_path, home_ui_path, image_path,
            category_directory):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    dylib = Path(dylib_path).resolve().read_bytes()
    home_ui = Path(home_ui_path).resolve().read_bytes()
    image = Path(image_path).resolve().read_bytes()
    category_directory = Path(category_directory).resolve()
    category_images = {
        category_path(name): (category_directory / name).read_bytes()
        for name in CATEGORY_NAMES
    }
    direct.verify_cloud_runtime_version(dylib)
    direct.verify_cloud_stability_contract(dylib)
    direct.prepare_cloud(dylib)
    verify_cloud_home_ui_dependency(dylib_path)
    verify_home_ui_binary(home_ui_path, home_ui)

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
                payload = b"" if info.is_dir() else source.read(info.filename)
                if info.filename == CLOUD_PATH:
                    payload = dylib
                elif info.filename == MAIN_PATH:
                    payload = source_main
                elif info.filename == HOME_UI_PATH:
                    payload = home_ui
                elif info.filename == BUTTON_IMAGE_PATH:
                    payload = image
                elif info.filename in category_images:
                    payload = category_images[info.filename]
                output_info = copy_zip_info(info)
                if info.filename == HOME_UI_PATH:
                    output_info.create_system = 3
                    output_info.external_attr = 0o100755 << 16
                output.writestr(output_info, payload)

            if BUTTON_IMAGE_PATH not in source.namelist():
                output.writestr(new_zip_info(BUTTON_IMAGE_PATH), image)
            if HOME_UI_PATH not in source.namelist():
                output.writestr(new_zip_info(HOME_UI_PATH, executable=True), home_ui)
            for name, payload in category_images.items():
                if name not in source.namelist():
                    output.writestr(new_zip_info(name), payload)

        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate, "r"
        ) as output:
            if output.testzip() is not None:
                raise RuntimeError("output IPA CRC validation failed")
            expected_names = set(source.namelist()) | {
                BUTTON_IMAGE_PATH,
                HOME_UI_PATH,
                *category_images,
            }
            if set(output.namelist()) != expected_names:
                raise RuntimeError("output IPA member set changed unexpectedly")
            if output.read(CLOUD_PATH) != dylib:
                raise RuntimeError("output Cloud dylib mismatch")
            if output.read(HOME_UI_PATH) != home_ui:
                raise RuntimeError("output Home UI dylib mismatch")
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
        "home_ui_sha256": sha256(home_ui),
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
    parser.add_argument("home_ui")
    parser.add_argument("image")
    parser.add_argument("category_directory")
    args = parser.parse_args()
    print(
        package(
            args.source,
            args.output,
            args.dylib,
            args.home_ui,
            args.image,
            args.category_directory,
        )
    )


if __name__ == "__main__":
    main()
