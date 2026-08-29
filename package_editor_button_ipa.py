#!/usr/bin/env python3
"""Legacy 6.2.55/862-only Cloud and editor asset packager."""

import argparse
import hashlib
import os
import plistlib
import tempfile
import zipfile
from pathlib import Path

import build_862_direct_package as direct
import inject_dylib


CLOUD_PATH = "Payload/AlightMotion.app/Frameworks/AMProjExportCloud.dylib"
HOME_UI_PATH = "Payload/AlightMotion.app/Frameworks/AMHomeUI.dylib"
MAIN_PATH = "Payload/AlightMotion.app/AlightMotion"
INFO_PATH = "Payload/AlightMotion.app/Info.plist"
HOME_UI_BASENAME = "AMHomeUI.dylib"
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


def category_path(name):
    return CATEGORY_PREFIX + name


def new_zip_info(name, executable=False):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (0o100755 if executable else 0o100644) << 16
    return info


def reject_v865_source(source_path):
    """Keep this legacy Cloud-name packager away from the 865 baseline."""
    with zipfile.ZipFile(source_path, "r") as source:
        if source.namelist().count(INFO_PATH) != 1:
            raise RuntimeError("source IPA must contain exactly one Info.plist")
        try:
            info = plistlib.loads(source.read(INFO_PATH))
        except (plistlib.InvalidFileException, ValueError, TypeError) as error:
            raise RuntimeError("source IPA Info.plist is invalid") from error
    inject_dylib.reject_v865_legacy_entry(info, "package_editor_button_ipa.py")


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


def ensure_home_ui_load_contract(info, context):
    """Require exactly one strong load at the standalone HomeUI path."""
    commands = [
        command
        for command in info["dylib_load_commands"]
        if command["name"].rsplit("/", 1)[-1] == HOME_UI_BASENAME
    ]
    if len(commands) != 1:
        raise RuntimeError(
            f"{context} must strongly load AMHomeUI exactly once; found {len(commands)}"
        )
    command = commands[0]
    if command["name"] != HOME_UI_LOAD or command["cmd"] != inject_dylib.LC_LOAD_DYLIB:
        raise RuntimeError(
            f"{context} has a conflicting AMHomeUI load: "
            f"{command['command']} {command['name']}"
        )


def verify_cloud_standalone_home_ui(dylib_path):
    """Verify that Cloud is independent from the standalone Home UI image."""
    info = inject_dylib.verify_dylib_architecture(dylib_path)
    ensure_no_home_ui_loads(info, "Cloud dylib")
    if "_AMHomeUIInstall" in info["external_defined_symbols"]:
        raise RuntimeError("Cloud dylib must not define _AMHomeUIInstall")
    cloud = Path(dylib_path).read_bytes()
    if b"https://amhome.meowcr.cn/home" in cloud:
        raise RuntimeError("Cloud dylib must not embed the Home UI URL")


# Keep the old import name usable while changing its contract to the split
# runtime. Callers should migrate to verify_cloud_standalone_home_ui.
verify_cloud_embedded_home_ui = verify_cloud_standalone_home_ui


def patch_main_with_home_ui(main, home_ui_name=HOME_UI_BASENAME):
    """Add one strong HomeUI load command using existing Mach-O padding."""
    with tempfile.TemporaryDirectory(prefix="am-home-ui-main-") as directory:
        main_path = Path(directory) / "AlightMotion"
        home_ui_path = Path(directory) / home_ui_name
        main_path.write_bytes(main)
        # insert_load_dylib only uses the basename to construct the load name;
        # the placeholder does not need to contain a valid Mach-O image.
        home_ui_path.write_bytes(b"")
        inject_dylib.insert_load_dylib(str(main_path), str(home_ui_path))
        patched = main_path.read_bytes()
    info = inject_dylib.parse_macho_data(patched, MAIN_PATH)
    loads = [
        command for command in info["dylib_load_commands"]
        if command["name"] == HOME_UI_LOAD
    ]
    if len(loads) != 1 or loads[0]["cmd"] != inject_dylib.LC_LOAD_DYLIB:
        raise RuntimeError("main executable must strongly load AMHomeUI exactly once")
    return patched


def verify_home_ui_binary(home_ui_path, home_ui):
    """Verify the standalone HomeUI dylib's ABI, identity, symbol, and URL."""
    info = inject_dylib.verify_dylib_architecture(home_ui_path)
    install_names = info.get("id_dylibs", [])
    if install_names != ["@rpath/AMHomeUI.dylib"]:
        raise RuntimeError(
            "Home UI dylib install name must be @rpath/AMHomeUI.dylib"
        )
    if "_AMHomeUIInstall" not in info["external_defined_symbols"]:
        raise RuntimeError("Home UI dylib must export _AMHomeUIInstall")
    if b"https://amhome.meowcr.cn/home" not in home_ui:
        raise RuntimeError("Home UI dylib is missing the AutFeng home URL")


def package(
    source_path,
    output_path,
    dylib_path,
    home_ui_path,
    image_path,
    category_directory,
):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    dylib_path = Path(dylib_path).resolve()
    home_ui_path = Path(home_ui_path).resolve()
    reject_v865_source(source_path)
    dylib = dylib_path.read_bytes()
    home_ui = home_ui_path.read_bytes()
    image = Path(image_path).resolve().read_bytes()
    category_directory = Path(category_directory).resolve()
    category_images = {
        category_path(name): (category_directory / name).read_bytes()
        for name in CATEGORY_NAMES
    }
    direct.verify_cloud_runtime_version(dylib)
    direct.verify_cloud_stability_contract(dylib)
    direct.prepare_cloud(dylib)
    verify_cloud_standalone_home_ui(dylib_path)
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
        source_home_ui_loads = [
            command
            for command in source_main_info["dylib_load_commands"]
            if command["name"].rsplit("/", 1)[-1] == HOME_UI_BASENAME
        ]
        if source_home_ui_loads:
            ensure_home_ui_load_contract(source_main_info, "source main")
            main = source_main
        else:
            main = patch_main_with_home_ui(source_main)
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
                output_info = copy_zip_info(info)
                if info.filename == HOME_UI_PATH:
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
            ensure_home_ui_load_contract(output_main_info, "output main")
            if not source_home_ui_loads:
                expected_command_growth = (
                    output_main_info["sizeofcmds"] - source_main_info["sizeofcmds"]
                )
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
    parser = argparse.ArgumentParser(
        description="Legacy 6.2.55/862-only Cloud and editor asset packager"
    )
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
