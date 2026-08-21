import tempfile
import unittest
import zipfile
from pathlib import Path

import package_official_builtin_effects_ipa as packager


def effect_xml(
    effect_id,
    thumbnail=None,
    afx2=False,
    legacy=False,
    commented_afx2=False,
):
    attributes = [f'id="{effect_id}"']
    if thumbnail:
        attributes.append(f'thumb="{thumbnail}"')
    if afx2:
        attributes.append('afxver="2"')
        body = "<shader>vec4 shadeFragment(){ return vec4(0.0); }</shader>"
    elif legacy:
        body = "<shader>void main(){}</shader>"
    elif commented_afx2:
        body = "<shader>/* void shadeFragment(){} */ void main(){}</shader>"
    else:
        body = ""
    return (
        "<?xml version='1.0'?>\n<effect "
        + " ".join(attributes)
        + ">"
        + body
        + "</effect>\n"
    ).encode()


class OfficialBuiltinEffectsPackageTests(unittest.TestCase):
    def write_source_effect(
        self,
        root,
        relative_path,
        effect_id,
        thumbnail=None,
        afx2=False,
        legacy=False,
        commented_afx2=False,
    ):
        path = root / Path(*relative_path.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            effect_xml(
                effect_id,
                thumbnail,
                afx2=afx2,
                legacy=legacy,
                commented_afx2=commented_afx2,
            )
        )

    def write_base_ipa(self, path):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(
                packager.BUILTIN_EFFECTS_PREFIX + "lift.xml",
                effect_xml("com.alightcreative.effects.lift"),
            )
            archive.writestr(
                packager.BUILTIN_EFFECTS_PREFIX + "vortexblur.xml",
                effect_xml("com.alightcreative.effects.vortexblur"),
            )
            archive.writestr(
                packager.BUILTIN_EFFECTS_PREFIX + "echo-keyframe.xml",
                effect_xml("com.alightcreative.effects.repeat.echokf"),
            )
            archive.writestr(
                packager.BUILTIN_EFFECTS_PREFIX + "brightness-contrast-2.xml",
                effect_xml(
                    "com.alightcreative.effects.brightcont2", afx2=True
                ),
            )
            archive.writestr(
                packager.BUILTIN_EFFECTS_PREFIX + "community.xml",
                effect_xml("com.autfeng.effects.community"),
            )
            archive.writestr(
                packager.BUILTIN_EFFECTS_PREFIX + "thumb/lift.png", b"old-thumb"
            )
            archive.writestr("Payload/AlightMotion.app/Info.plist", b"plist")
            archive.writestr("Payload/AlightMotion.app/custom.bin", b"untouched")

    def test_only_baseline_official_ids_are_repaired(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_ipa = root / "source.ipa"
            output_ipa = root / "output.ipa"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            self.write_base_ipa(source_ipa)

            self.write_source_effect(
                effects,
                "lift.xml",
                "com.alightcreative.effects.lift",
                "thumb/lift.png",
            )
            self.write_source_effect(
                effects,
                "renamed-vortex.xml",
                "com.alightcreative.effects.vortexblur",
            )
            self.write_source_effect(
                effects,
                "echo-keyframe.xml",
                "com.autsheng.effects.repeat.echokf",
            )
            self.write_source_effect(
                effects,
                "community.xml",
                "com.autfeng.effects.community",
            )
            self.write_source_effect(
                effects,
                "extra-official.xml",
                "com.alightcreative.effects.community_extra",
            )
            self.write_source_effect(
                effects,
                "brightness-contrast-2.xml",
                "com.alightcreative.effects.brightcont2",
                legacy=True,
            )
            thumb = effects / "thumb" / "lift.png"
            thumb.parent.mkdir()
            thumb.write_bytes(b"\x89PNG\r\n\x1a\nfixture")

            result = packager.package(source_ipa, output_ipa, effects)

            self.assertEqual(result["replaced_official_effects"], 2)
            self.assertEqual(result["matched_by_original_path"], 1)
            self.assertEqual(result["matched_by_effect_id"], 1)
            self.assertEqual(
                result["added_official_effects"], []
            )
            self.assertEqual(
                result["skipped_legacy_downgrades"], ["brightness-contrast-2.xml"]
            )
            self.assertEqual(
                result["updated_assets"],
                [packager.BUILTIN_EFFECTS_PREFIX + "thumb/lift.png"],
            )
            self.assertEqual(
                result["preserved_nonofficial_baseline_effects"], ["community.xml"]
            )
            with zipfile.ZipFile(output_ipa) as output:
                self.assertEqual(
                    output.read(packager.BUILTIN_EFFECTS_PREFIX + "lift.xml"),
                    effect_xml("com.alightcreative.effects.lift", "thumb/lift.png"),
                )
                self.assertEqual(
                    output.read(packager.BUILTIN_EFFECTS_PREFIX + "vortexblur.xml"),
                    effect_xml("com.alightcreative.effects.vortexblur"),
                )
                self.assertEqual(
                    output.read(packager.BUILTIN_EFFECTS_PREFIX + "echo-keyframe.xml"),
                    effect_xml("com.alightcreative.effects.repeat.echokf"),
                )
                self.assertNotIn(
                    packager.BUILTIN_EFFECTS_PREFIX + "extra-official.xml",
                    output.namelist(),
                )
                self.assertEqual(
                    output.read(
                        packager.BUILTIN_EFFECTS_PREFIX
                        + "brightness-contrast-2.xml"
                    ),
                    effect_xml("com.alightcreative.effects.brightcont2", afx2=True),
                )
                self.assertEqual(
                    output.read(
                        packager.BUILTIN_EFFECTS_PREFIX + "thumb/lift.png"
                    ),
                    b"\x89PNG\r\n\x1a\nfixture",
                )
                self.assertEqual(
                    output.read(packager.BUILTIN_EFFECTS_PREFIX + "community.xml"),
                    effect_xml("com.autfeng.effects.community"),
                )
                self.assertEqual(
                    output.read("Payload/AlightMotion.app/custom.bin"), b"untouched"
                )

    def test_source_path_with_wrong_id_cannot_replace_a_builtin_effect(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_ipa = root / "source.ipa"
            output_ipa = root / "output.ipa"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            self.write_base_ipa(source_ipa)
            self.write_source_effect(
                effects,
                "lift.xml",
                "com.autfeng.effects.lift",
            )
            with self.assertRaisesRegex(RuntimeError, "no verified official"):
                packager.package(source_ipa, output_ipa, effects)

    def test_comment_cannot_fake_an_afx2_shader_entrypoint(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_ipa = root / "source.ipa"
            output_ipa = root / "output.ipa"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            self.write_base_ipa(source_ipa)
            self.write_source_effect(
                effects,
                "brightness-contrast-2.xml",
                "com.alightcreative.effects.brightcont2",
                commented_afx2=True,
            )
            self.write_source_effect(
                effects,
                "lift.xml",
                "com.alightcreative.effects.lift",
            )

            result = packager.package(source_ipa, output_ipa, effects)

            self.assertEqual(
                result["skipped_legacy_downgrades"], ["brightness-contrast-2.xml"]
            )
            with zipfile.ZipFile(output_ipa) as output:
                self.assertEqual(
                    output.read(
                        packager.BUILTIN_EFFECTS_PREFIX
                        + "brightness-contrast-2.xml"
                    ),
                    effect_xml("com.alightcreative.effects.brightcont2", afx2=True),
                )

    def test_afx2_requires_a_compatible_function_definition(self):
        self.assertFalse(
            packager.uses_afx2_shader(
                b"<effect><shader>bool shadeFragment(){ return true; }</shader></effect>"
            )
        )
        self.assertFalse(
            packager.uses_afx2_shader(
                b"<effect><shader>vec4 shadeFragment(AC_Input value);</shader></effect>"
            )
        )
        self.assertTrue(
            packager.uses_afx2_shader(
                b"<effect><shader>vec4 shadeFragment(AC_Input value) { return vec4(0.0); }</shader></effect>"
            )
        )

    def test_comment_between_legacy_main_tokens_cannot_bypass_afx2_guard(self):
        self.assertFalse(
            packager.uses_afx2_shader(
                b"<effect><shader>vec4 shadeFragment(){ return vec4(0.0); } "
                b"void/**/main(){}</shader></effect>"
            )
        )

    def test_duplicate_zip_members_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_ipa = root / "source.ipa"
            output_ipa = root / "output.ipa"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            self.write_base_ipa(source_ipa)
            with zipfile.ZipFile(source_ipa, "a") as archive:
                archive.writestr(
                    packager.BUILTIN_EFFECTS_PREFIX + "lift.xml",
                    effect_xml("com.alightcreative.effects.lift"),
                )
            self.write_source_effect(
                effects,
                "lift.xml",
                "com.alightcreative.effects.lift",
            )

            with self.assertRaisesRegex(RuntimeError, "ZIP validation failed"):
                packager.package(source_ipa, output_ipa, effects)

    def test_baseline_root_metadata_is_preserved_with_source_shader_body(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_ipa = root / "source.ipa"
            output_ipa = root / "output.ipa"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            base = (
                b'<effect id="com.alightcreative.effects.lift" '
                b'compat="acScreenNorm-y" maxOverdraw="0.1" '
                b'thumb="thumb/base.webp"><shader>base()</shader></effect>'
            )
            source = (
                b'<effect id="com.alightcreative.effects.lift" experimental="true">'
                b'<shader>source()</shader></effect>'
            )
            with zipfile.ZipFile(source_ipa, "w") as archive:
                archive.writestr(packager.BUILTIN_EFFECTS_PREFIX + "lift.xml", base)
            effects.joinpath("lift.xml").write_bytes(source)

            packager.package(source_ipa, output_ipa, effects)

            with zipfile.ZipFile(output_ipa) as output:
                merged = output.read(packager.BUILTIN_EFFECTS_PREFIX + "lift.xml")
            self.assertIn(b'compat="acScreenNorm-y"', merged)
            self.assertIn(b'maxOverdraw="0.1"', merged)
            self.assertIn(b'thumb="thumb/base.webp"', merged)
            self.assertIn(b'experimental="true"', merged)
            self.assertIn(b"<shader>source()</shader>", merged)

    def test_new_missing_resource_dependency_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_ipa = root / "source.ipa"
            output_ipa = root / "output.ipa"
            effects = root / "BuiltinEffects"
            effects.mkdir()
            with zipfile.ZipFile(source_ipa, "w") as archive:
                archive.writestr(
                    packager.BUILTIN_EFFECTS_PREFIX + "lift.xml",
                    effect_xml("com.alightcreative.effects.lift"),
                )
            for prefix in ("resource", "textures"):
                with self.subTest(prefix=prefix):
                    effects.joinpath("lift.xml").write_bytes(
                        b'<effect id="com.alightcreative.effects.lift">'
                        + f'<texture src="{prefix}/new.png" /></effect>'.encode()
                    )
                    with self.assertRaisesRegex(RuntimeError, "introduces missing"):
                        packager.package(source_ipa, output_ipa, effects)


if __name__ == "__main__":
    unittest.main()
