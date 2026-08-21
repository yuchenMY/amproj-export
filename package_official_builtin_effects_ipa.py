#!/usr/bin/env python3
"""Repair only verified Alight Motion builtin effects in an IPA.

The IPA itself is the authority for the official 6.2.55 effect roster.  A
source directory can contain community effects as well, so files are selected
only when their official ID matches an existing builtin effect.  A legacy
shader is never allowed to replace an AFX2 builtin implementation.
"""

import argparse
import hashlib
import json
import os
import re
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


APP_ROOT = "Payload/AlightMotion.app/"
BUILTIN_EFFECTS_PREFIX = APP_ROOT + "BuiltinEffects/"
OFFICIAL_ID_PREFIX = "com.alightcreative."

EFFECT_TAG_RE = re.compile(r"<effect\b(?P<attributes>[^>]*)>", re.I | re.S)
ATTRIBUTE_RE = re.compile(
    r"\b(?P<name>id|thumb|deprecated)\s*=\s*"
    r"(?P<quote>['\"])(?P<value>.*?)(?P=quote)",
    re.I | re.S,
)
ALL_ATTRIBUTE_RE = re.compile(
    r"\b(?P<name>[A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*"
    r"(?P<quote>['\"])(?P<value>.*?)(?P=quote)",
    re.S,
)
SHADER_RE = re.compile(r"<shader\b[^>]*>(?P<body>.*?)</shader\s*>", re.I | re.S)
XML_COMMENT_RE = re.compile(r"<!--.*?-->", re.S)
C_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
C_LINE_COMMENT_RE = re.compile(r"//[^\r\n]*")
SHADE_FRAGMENT_FUNCTION_RE = re.compile(
    r"\b(?:void|vec4)\s+shadeFragment\s*\([^{}]*\)\s*\{", re.S
)
LEGACY_MAIN_FUNCTION_RE = re.compile(r"\bvoid\s+main\s*\(")
ASSET_PREFIXES = ("thumb/",)
DEPENDENCY_PREFIXES = ("thumb/", "resource/", "resources/", "textures/")
STANDALONE_DEPENDENCY_NAMES = frozenset({"testimg.png"})


@dataclass(frozen=True)
class EffectMetadata:
    effect_id: str
    thumbnail: str | None
    deprecated: bool


@dataclass(frozen=True)
class SourceEffect:
    relative_path: str
    path: Path
    payload: bytes
    metadata: EffectMetadata


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


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


def new_zip_info(name):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info


def parse_effect_metadata(payload, context):
    text = payload.decode("utf-8", errors="replace")
    tag = EFFECT_TAG_RE.search(text)
    if tag is None:
        raise RuntimeError(f"{context} does not contain an <effect> root tag")
    attributes = {
        match.group("name").lower(): match.group("value")
        for match in ATTRIBUTE_RE.finditer(tag.group("attributes"))
    }
    effect_id = attributes.get("id", "").strip()
    if not effect_id:
        raise RuntimeError(f"{context} does not declare an effect ID")
    thumbnail = attributes.get("thumb")
    if thumbnail is not None:
        thumbnail = thumbnail.strip()
    return EffectMetadata(
        effect_id=effect_id,
        thumbnail=thumbnail or None,
        deprecated=attributes.get("deprecated", "").strip().lower() == "true",
    )


def shader_entrypoints(payload):
    """Return real shader ABI entry points, ignoring XML/C-style comments."""
    # Keep a token boundary when stripping comments: GLSL permits comments
    # between tokens, such as ``void/**/main()``.
    text = XML_COMMENT_RE.sub(" ", payload.decode("utf-8", errors="replace"))
    shade_fragment = False
    legacy_main = False
    for match in SHADER_RE.finditer(text):
        body = XML_COMMENT_RE.sub(" ", match.group("body"))
        body = C_BLOCK_COMMENT_RE.sub(" ", body)
        body = C_LINE_COMMENT_RE.sub(" ", body)
        shade_fragment = shade_fragment or bool(
            SHADE_FRAGMENT_FUNCTION_RE.search(body)
        )
        legacy_main = legacy_main or bool(LEGACY_MAIN_FUNCTION_RE.search(body))
    return shade_fragment, legacy_main


def uses_afx2_shader(payload):
    """Require the AFX2 entry point and reject an obsolete main() fallback."""
    shade_fragment, legacy_main = shader_entrypoints(payload)
    return shade_fragment and not legacy_main


def merge_baseline_root_metadata(base_payload, candidate_payload, context):
    """Keep the IPA's iOS metadata while importing source params/shaders.

    Android-source XML commonly omits compat/max-overdraw attributes that the
    iOS bundle already supplies.  Replacing the whole opening tag silently
    removes those runtime constraints, so retain every baseline attribute and
    append only source attributes that are genuinely new.
    """
    base_match = EFFECT_TAG_RE.search(base_payload.decode("utf-8", errors="replace"))
    candidate_text = candidate_payload.decode("utf-8", errors="replace")
    candidate_match = EFFECT_TAG_RE.search(candidate_text)
    if base_match is None or candidate_match is None:
        raise RuntimeError(f"{context} is missing an <effect> root tag")

    base_attributes = {
        match.group("name").lower()
        for match in ALL_ATTRIBUTE_RE.finditer(base_match.group("attributes"))
    }
    additions = []
    for match in ALL_ATTRIBUTE_RE.finditer(candidate_match.group("attributes")):
        name = match.group("name")
        if name.lower() in base_attributes:
            continue
        additions.append(
            f" {name}={match.group('quote')}{match.group('value')}{match.group('quote')}"
        )
        base_attributes.add(name.lower())
    merged_root = base_match.group(0)
    if additions:
        merged_root = merged_root[:-1] + "".join(additions) + ">"
    return (
        candidate_text[: candidate_match.start()].encode("utf-8")
        + merged_root.encode("utf-8")
        + candidate_text[candidate_match.end() :].encode("utf-8")
    )


def normalized_relative_path(value, context):
    path = PurePosixPath(value.replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts or path == PurePosixPath("."):
        raise RuntimeError(f"{context} has an unsafe relative path: {value!r}")
    return path.as_posix()


def load_source_effects(source_directory):
    source_directory = Path(source_directory).resolve()
    if not source_directory.is_dir():
        raise RuntimeError(f"BuiltinEffects source directory does not exist: {source_directory}")

    by_path = {}
    by_id = {}
    for path in sorted(source_directory.rglob("*.xml")):
        relative_path = path.relative_to(source_directory).as_posix()
        if "presets" in PurePosixPath(relative_path).parts:
            continue
        payload = path.read_bytes()
        metadata = parse_effect_metadata(payload, str(path))
        if not metadata.effect_id.startswith(OFFICIAL_ID_PREFIX):
            continue
        source_effect = SourceEffect(relative_path, path, payload, metadata)
        by_path[relative_path] = source_effect
        by_id.setdefault(metadata.effect_id, []).append(source_effect)
    return by_path, by_id


def load_builtin_effects(archive):
    effects = {}
    ids = set()
    nonofficial_paths = []
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise RuntimeError("base IPA contains duplicate ZIP entries")
    for entry in archive.infolist():
        if not entry.filename.startswith(BUILTIN_EFFECTS_PREFIX):
            continue
        if not entry.filename.endswith(".xml"):
            continue
        relative_path = entry.filename[len(BUILTIN_EFFECTS_PREFIX) :]
        metadata = parse_effect_metadata(archive.read(entry), entry.filename)
        if not metadata.effect_id.startswith(OFFICIAL_ID_PREFIX):
            # Existing community effects are outside this repairer's ownership.
            # Leave them byte-for-byte untouched instead of blocking an official
            # repair on a package that already contains additional effects.
            nonofficial_paths.append(relative_path)
            continue
        if metadata.effect_id in ids:
            raise RuntimeError(
                f"base IPA declares duplicate official effect ID: {metadata.effect_id}"
            )
        ids.add(metadata.effect_id)
        effects[relative_path] = (entry, metadata)
    if not effects:
        raise RuntimeError("base IPA has no BuiltinEffects XML entries")
    return effects, ids, sorted(nonofficial_paths)


def build_repair_plan(archive, source_directory):
    builtin_effects, _builtin_ids, nonofficial_paths = load_builtin_effects(archive)
    source_by_path, source_by_id = load_source_effects(source_directory)
    replacements = {}
    skipped_legacy_downgrades = []
    baseline_dependencies = {}
    path_matches = 0
    id_matches = 0

    for relative_path, (entry, metadata) in builtin_effects.items():
        base_payload = archive.read(entry)
        baseline_dependencies[relative_path] = asset_references(
            base_payload, f"baseline asset reference in {relative_path}"
        )
        candidate = source_by_path.get(relative_path)
        if candidate is not None and candidate.metadata.effect_id == metadata.effect_id:
            if uses_afx2_shader(base_payload) and not uses_afx2_shader(
                candidate.payload
            ):
                skipped_legacy_downgrades.append(relative_path)
            else:
                merged_payload = merge_baseline_root_metadata(
                    base_payload, candidate.payload, relative_path
                )
                replacements[relative_path] = SourceEffect(
                    candidate.relative_path,
                    candidate.path,
                    merged_payload,
                    parse_effect_metadata(merged_payload, relative_path),
                )
                path_matches += 1
            continue

        candidates = source_by_id.get(metadata.effect_id, [])
        if len(candidates) == 1:
            candidate = candidates[0]
            if uses_afx2_shader(base_payload) and not uses_afx2_shader(
                candidate.payload
            ):
                skipped_legacy_downgrades.append(relative_path)
            else:
                merged_payload = merge_baseline_root_metadata(
                    base_payload, candidate.payload, relative_path
                )
                replacements[relative_path] = SourceEffect(
                    candidate.relative_path,
                    candidate.path,
                    merged_payload,
                    parse_effect_metadata(merged_payload, relative_path),
                )
                id_matches += 1

    return {
        "replacements": replacements,
        "additions": {},
        "path_matches": path_matches,
        "id_matches": id_matches,
        "base_effect_count": len(builtin_effects),
        "baseline_dependencies": baseline_dependencies,
        "preserved_nonofficial_baseline_effects": nonofficial_paths,
        "skipped_legacy_downgrades": sorted(skipped_legacy_downgrades),
    }


def asset_references(payload, context):
    """Return relative image assets explicitly referenced by an effect XML."""
    text = payload.decode("utf-8", errors="replace")
    references = set()
    for match in ALL_ATTRIBUTE_RE.finditer(text):
        value = match.group("value").strip().replace("\\", "/")
        if not (
            value.startswith(DEPENDENCY_PREFIXES)
            or value in STANDALONE_DEPENDENCY_NAMES
        ):
            continue
        references.add(normalized_relative_path(value, context))
    return sorted(references)


def asset_updates(plan, source_directory, existing_names):
    source_directory = Path(source_directory).resolve()
    updates = {}
    missing_source = []
    missing_everywhere = []
    invalid = []
    for source_effect in (*plan["replacements"].values(), *plan["additions"].values()):
        for asset in asset_references(
            source_effect.payload, f"asset reference in {source_effect.relative_path}"
        ):
            if not asset.startswith(ASSET_PREFIXES):
                # Runtime textures are part of the known-good IPA baseline.
                # They are not copied from the Android source without a
                # per-effect compatibility decision.
                continue
            target_name = BUILTIN_EFFECTS_PREFIX + asset
            source_path = source_directory / Path(*PurePosixPath(asset).parts)
            if not source_path.is_file():
                missing_source.append(asset)
                if target_name not in existing_names:
                    missing_everywhere.append(asset)
                continue
            payload = source_path.read_bytes()
            if image_payload_matches_extension(asset, payload):
                # Update existing assets too.  Keeping an old thumbnail beside a
                # repaired XML makes the UI look stale and obscures real fixes.
                updates[target_name] = payload
            else:
                invalid.append(asset)
                if target_name not in existing_names:
                    missing_everywhere.append(asset)
    return (
        updates,
        sorted(set(missing_source)),
        sorted(set(missing_everywhere)),
        sorted(set(invalid)),
    )


def unresolved_dependency_report(plan, available_names):
    """Reject only dependencies newly introduced by a replacement XML."""
    available_names = set(available_names)
    baseline_missing = set()
    introduced_missing = []
    for relative_path, source_effect in plan["replacements"].items():
        baseline_dependencies = set(plan["baseline_dependencies"][relative_path])
        for asset in asset_references(
            source_effect.payload, f"asset reference in {source_effect.relative_path}"
        ):
            target_name = BUILTIN_EFFECTS_PREFIX + asset
            if target_name in available_names:
                continue
            if asset in baseline_dependencies:
                baseline_missing.add(asset)
            else:
                introduced_missing.append((relative_path, asset))
    if introduced_missing:
        details = ", ".join(
            f"{relative_path} -> {asset}"
            for relative_path, asset in sorted(introduced_missing)
        )
        raise RuntimeError(
            "replacement XML introduces missing BuiltinEffects dependencies: "
            + details
        )
    return sorted(baseline_missing)


def image_payload_matches_extension(relative_path, payload):
    suffix = PurePosixPath(relative_path).suffix.lower()
    if suffix == ".png":
        return payload.startswith(b"\x89PNG\r\n\x1a\n")
    if suffix in {".jpg", ".jpeg"}:
        return payload.startswith(b"\xff\xd8\xff")
    if suffix == ".webp":
        return len(payload) >= 12 and payload[:4] == b"RIFF" and payload[8:12] == b"WEBP"
    return False


def package(source_path, output_path, source_directory):
    source_path = Path(source_path).resolve()
    output_path = Path(output_path).resolve()
    source_directory = Path(source_directory).resolve()
    if source_path == output_path:
        raise RuntimeError("output IPA must differ from source IPA")

    with zipfile.ZipFile(source_path, "r") as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise RuntimeError("source IPA ZIP validation failed")
        plan = build_repair_plan(archive, source_directory)
        if not plan["replacements"]:
            raise RuntimeError("no verified official effect replacement was found")
        existing_names = set(archive.namelist())
        assets, missing_assets, missing_everywhere, invalid_assets = asset_updates(
            plan, source_directory, existing_names
        )
        unresolved_baseline_assets = unresolved_dependency_report(
            plan, existing_names | set(assets)
        )

    replacement_payloads = {
        BUILTIN_EFFECTS_PREFIX + relative_path: source_effect.payload
        for relative_path, source_effect in plan["replacements"].items()
    }
    added_effect_payloads = {
        BUILTIN_EFFECTS_PREFIX + relative_path: source_effect.payload
        for relative_path, source_effect in plan["additions"].items()
    }
    added_payloads = {**added_effect_payloads, **assets}

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=output_path.stem + ".builtin-effects-", dir=output_path.parent
    ) as temporary_directory:
        candidate_path = Path(temporary_directory) / "candidate.ipa"
        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate_path, "w", allowZip64=True
        ) as output:
            for info in source.infolist():
                payload = b"" if info.is_dir() else source.read(info.filename)
                payload = replacement_payloads.get(info.filename, payload)
                payload = added_payloads.get(info.filename, payload)
                output.writestr(copy_zip_info(info), payload)
            for name, payload in sorted(added_payloads.items()):
                if name in existing_names:
                    continue
                output.writestr(new_zip_info(name), payload)

        with zipfile.ZipFile(source_path, "r") as source, zipfile.ZipFile(
            candidate_path, "r"
        ) as output:
            if output.testzip() is not None:
                raise RuntimeError("output IPA ZIP validation failed")
            expected_names = set(source.namelist()) | set(added_payloads)
            if len(output.namelist()) != len(set(output.namelist())) or set(
                output.namelist()
            ) != expected_names:
                raise RuntimeError("output IPA member set changed unexpectedly")
            for name, payload in replacement_payloads.items():
                if output.read(name) != payload:
                    raise RuntimeError(f"official effect replacement failed: {name}")
            for name, payload in added_payloads.items():
                if output.read(name) != payload:
                    raise RuntimeError(f"official effect addition failed: {name}")
            changed = set(replacement_payloads) | set(added_payloads)
            for info in source.infolist():
                if info.is_dir() or info.filename in changed:
                    continue
                if sha256(source.read(info.filename)) != sha256(output.read(info.filename)):
                    raise RuntimeError(f"unrelated IPA member changed: {info.filename}")
        os.replace(candidate_path, output_path)

    return {
        "input_sha256": sha256(source_path.read_bytes()),
        "output_sha256": sha256(output_path.read_bytes()),
        "base_official_effects": plan["base_effect_count"],
        "replaced_official_effects": len(plan["replacements"]),
        "matched_by_original_path": plan["path_matches"],
        "matched_by_effect_id": plan["id_matches"],
        "added_official_effects": sorted(plan["additions"]),
        "updated_assets": sorted(assets),
        "missing_source_assets": missing_assets,
        "missing_assets_in_both_sources": missing_everywhere,
        "invalid_source_assets": invalid_assets,
        "unresolved_baseline_assets": unresolved_baseline_assets,
        "preserved_nonofficial_baseline_effects": plan[
            "preserved_nonofficial_baseline_effects"
        ],
        "skipped_legacy_downgrades": plan["skipped_legacy_downgrades"],
        "output": str(output_path),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Repair verified official BuiltinEffects in an IPA"
    )
    parser.add_argument("source", help="base IPA")
    parser.add_argument("output", help="repaired IPA")
    parser.add_argument("builtin_effects", help="official BuiltinEffects source directory")
    args = parser.parse_args()
    print(json.dumps(package(args.source, args.output, args.builtin_effects), indent=2))


if __name__ == "__main__":
    main()
