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
HOME_UI_LOAD = "@executable_path/Frameworks/AMHomeUI.dylib"
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


def new_zip_info(name):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info


def dylib_command_size(name):
    return (24 + len(name.encode("utf-8")) + 1 + 7) & ~7


def validate_home_ui_loads(info, context, allow_missing):
    commands = [
        command
        for command in info["dylib_load_commands"]
        if command["name"] == HOME_UI_LOAD
    ]
    if not commands and allow_missing:
        return False
    if len(commands) == 1 and commands[0]["cmd"] == inject_dylib.LC_LOAD_DYLIB:
        return True
    found = ", ".join(command["command"] for command in commands) or "none"
    raise RuntimeError(
        f"{context} must contain exactly one strong AMHomeUI load; found {found}"
    )


def patch_main_with_home_ui(main, home_ui_name="AMHomeUI.dylib"):
    source_info = inject_dylib.parse_macho_data(main, MAIN_PATH)
    if validate_home_ui_loads(source_info, "source main", allow_missing=True):
        raise RuntimeError("source main already strongly loads AMHomeUI")
    with tempfile.TemporaryDirectory(prefix="am-home-ui-main-") as temporary_directory:
        main_path = Path(temporary_directory) / "AlightMotion"
        home_ui_path = Path(temporary_directory) / home_ui_name
        main_path.write_bytes(main)
        home_ui_path.write_bytes(b"")
        inject_dylib.insert_load_dylib(str(main_path), str(home_ui_path))
        patched = main_path.read_bytes()
    info = inject_dylib.parse_macho_data(patched, MAIN_PATH)
    validate_home_ui_loads(info, "patched main", allow_missing=False)
    matching_command = next(
        command
        for command in info["dylib_load_commands"]
        if command["name"] == HOME_UI_LOAD
    )
    expected_command_size = dylib_command_size(HOME_UI_LOAD)
    if len(patched) != len(main):
        raise RuntimeError("Home UI injection changed the main executable length")
    if info["ncmds"] != source_info["ncmds"] + 1:
        raise RuntimeError("Home UI injection must add exactly one load command")
    if matching_command["cmdsize"] != expected_command_size:
        raise RuntimeError("Home UI load command has an unexpected size")
    if info["sizeofcmds"] != source_info["sizeofcmds"] + expected_command_size:
        raise RuntimeError("Home UI injection has an unexpected sizeofcmds delta")
    return patched


def verify_home_ui_binary(home_ui_path, home_ui):
    info = inject_dylib.verify_dylib_architecture(home_ui_path)
    install_names = info.get("id_dylibs", [])
    expected_install_name = "@rpath/AMHomeUI.dylib"
    if install_names != [expected_install_name]:
        raise RuntimeError(
            f"Home UI dylib install name must be {expected_install_name}"
        )
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
        source_has_home_ui = validate_home_ui_loads(
            source_main_info, "source main", allow_missing=True
        )
        main = source_main if source_has_home_ui else (
            patch_main_with_home_ui(source_main)
        )
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
                    payload = main
                elif info.filename == HOME_UI_PATH:
                    payload = home_ui
                elif info.filename == BUTTON_IMAGE_PATH:
                    payload = image
                elif info.filename in category_images:
                    payload = category_images[info.filename]
                output.writestr(copy_zip_info(info), payload)

            if BUTTON_IMAGE_PATH not in source.namelist():
                output.writestr(new_zip_info(BUTTON_IMAGE_PATH), image)
            if HOME_UI_PATH not in source.namelist():
                output.writestr(new_zip_info(HOME_UI_PATH), home_ui)
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
            validate_home_ui_loads(
                output_main_info, "output main", allow_missing=False
            )
            if len(output_main) != len(source_main):
                raise RuntimeError("output main executable length changed")
            if not source_has_home_ui:
                matching_command = next(
                    command
                    for command in output_main_info["dylib_load_commands"]
                    if command["name"] == HOME_UI_LOAD
                )
                expected_command_growth = dylib_command_size(HOME_UI_LOAD)
                if matching_command["cmdsize"] != expected_command_growth:
                    raise RuntimeError("output Home UI load command size is invalid")
                if output_main_info["ncmds"] != source_main_info["ncmds"] + 1:
                    raise RuntimeError("output main did not add exactly one load command")
                if (
                    output_main_info["sizeofcmds"]
                    != source_main_info["sizeofcmds"] + expected_command_growth
                ):
                    raise RuntimeError("output main has an invalid sizeofcmds delta")
                changed = {
                    index
                    for index, (before, after) in enumerate(
                        zip(source_main, output_main)
                    )
                    if before != after
                }
                allowed = set(range(16, 24)) | set(
                    range(
                        source_main_info["load_commands_end"],
                        source_main_info["load_commands_end"]
                        + expected_command_growth,
                    )
                )
                if not changed or not changed <= allowed:
                    raise RuntimeError(
                        "Home UI injection changed bytes outside the Mach-O header"
                    )
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
