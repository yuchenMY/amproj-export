#!/usr/bin/env python3
"""Build one LCSign-ready IPA with verified official effect repairs.

This is the delivery entry point for the 6.2.55 official-effect repair.  It
first replaces only official BuiltinEffects members, then invokes the direct
Cloud packager so an obsolete standalone AMHomeUI.dylib cannot survive into
the IPA that is handed to LCSign.
"""

import argparse
import hashlib
import json
import tempfile
import zipfile
from pathlib import Path

import build_862_direct_package as direct
import home_ui_contract as homeui
import package_editor_button_ipa as editor_package
import package_official_builtin_effects_ipa as official_effects


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_final_builtin_effects(
    repaired_path,
    output_path,
    cloud_member,
    cloud_check_path,
    home_ui_member=None,
    home_ui_check_path=None,
):
    """Ensure the direct-Cloud handoff did not alter the repaired effects."""
    repaired_path = Path(repaired_path)
    output_path = Path(output_path)
    with zipfile.ZipFile(repaired_path, "r") as repaired, zipfile.ZipFile(
        output_path, "r"
    ) as output:
        repaired_names = repaired.namelist()
        output_names = output.namelist()
        if len(repaired_names) != len(set(repaired_names)):
            raise RuntimeError("intermediate IPA contains duplicate ZIP entries")
        if len(output_names) != len(set(output_names)):
            raise RuntimeError("final IPA contains duplicate ZIP entries")
        if output.testzip() is not None:
            raise RuntimeError("final IPA ZIP validation failed")
        if cloud_member not in output_names:
            raise RuntimeError(f"final IPA is missing its Cloud dylib: {cloud_member}")
        if home_ui_member is not None:
            if home_ui_member not in output_names:
                raise RuntimeError("final IPA is missing standalone AMHomeUI.dylib")
            if home_ui_check_path is None:
                raise RuntimeError("Home UI verification path is missing")
            home_ui_check_path.write_bytes(output.read(home_ui_member))

        for name in repaired_names:
            if not name.startswith(official_effects.BUILTIN_EFFECTS_PREFIX):
                continue
            if name not in output_names:
                raise RuntimeError(f"final IPA lost repaired builtin member: {name}")
            if repaired.getinfo(name).is_dir():
                continue
            if repaired.read(name) != output.read(name):
                raise RuntimeError(f"final IPA changed repaired builtin member: {name}")
        cloud_check_path.write_bytes(output.read(cloud_member))
    editor_package.verify_cloud_standalone_home_ui(cloud_check_path)
    if home_ui_member is not None:
        editor_package.verify_home_ui_binary(
            home_ui_check_path, home_ui_check_path.read_bytes()
        )


def build(
    source_path,
    output_path,
    builtin_effects_directory,
    cloud_path,
    home_ui_path=None,
):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    builtin_effects_directory = Path(builtin_effects_directory).resolve()
    cloud_path = Path(cloud_path).resolve()
    home_ui_path = Path(home_ui_path).resolve() if home_ui_path else None
    if source_path == output_path:
        raise RuntimeError("output IPA must differ from the source IPA")
    # Reject an old split runtime before its companion dylib is removed from the
    # final archive.  This protects the LCSign handoff from a missing loader.
    editor_package.verify_cloud_standalone_home_ui(cloud_path)
    if home_ui_path is not None:
        homeui.verify_home_ui_payload(home_ui_path)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".official-effects-", dir=output_path.parent
    ) as temporary_directory:
        repaired_path = Path(temporary_directory) / "official-effects.ipa"
        repair = official_effects.package(
            source_path, repaired_path, builtin_effects_directory
        )
        direct_kwargs = {"cloud_path": cloud_path}
        if home_ui_path is not None:
            direct_kwargs["home_ui_path"] = home_ui_path
        direct_result = direct.build_direct_package(
            repaired_path, output_path, **direct_kwargs
        )
        cloud_member = direct_result.get("cloud_member")
        if not isinstance(cloud_member, str):
            raise RuntimeError("direct Cloud packager did not report its Cloud member")
        home_ui_member = direct_result.get("home_ui_member")
        home_ui_check_path = (
            Path(temporary_directory) / "final-home-ui.dylib"
            if home_ui_member
            else None
        )
        verify_final_builtin_effects(
            repaired_path,
            output_path,
            cloud_member,
            Path(temporary_directory) / "final-cloud.dylib",
            home_ui_member=home_ui_member,
            home_ui_check_path=home_ui_check_path,
        )

    return {
        "input_sha256": sha256_file(source_path),
        "output_sha256": sha256_file(output_path),
        "official_effect_repair": repair,
        "direct_cloud": direct_result,
        "home_ui_member": home_ui_member,
        "output": str(output_path),
        "requires_recursive_real_signing": True,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Build the final 6.2.55 official-effect repair IPA for LCSign"
    )
    parser.add_argument("source", help="stable own-base IPA")
    parser.add_argument("output", help="LCSign-ready output IPA")
    parser.add_argument("builtin_effects", help="official BuiltinEffects source")
    parser.add_argument("cloud", help="fresh standalone AMProjExportCloud.dylib")
    parser.add_argument(
        "--home-ui", dest="home_ui", help="standalone AMHomeUI.dylib from the macOS build"
    )
    args = parser.parse_args()
    print(
        json.dumps(
            build(
                args.source,
                args.output,
                args.builtin_effects,
                args.cloud,
                args.home_ui,
            ),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
