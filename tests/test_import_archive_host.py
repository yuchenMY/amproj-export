import hashlib
import io
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "Objective-C Foundation host test requires macOS")
class ImportArchiveHostTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._temporary = tempfile.TemporaryDirectory()
        cls.temp = pathlib.Path(cls._temporary.name)
        cls.executable = cls.temp / "amproj-import-archive-smoke"
        subprocess.run(
            [
                "clang",
                "-fobjc-arc",
                "-framework",
                "Foundation",
                "-lz",
                f"-I{ROOT / 'AMProjExport'}",
                str(ROOT / "AMProjExport" / "AMProjImportArchive.m"),
                str(ROOT / "AMProjExport" / "AMProjZIPWriter.m"),
                str(ROOT / "tests" / "AMProjImportArchiveSmoke.m"),
                "-o",
                str(cls.executable),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls._temporary.cleanup()

    def run_helper(self, archive, mode="ok", missing=1):
        source_hash = hashlib.sha256(archive.read_bytes()).digest()
        work = self.temp / f"work-{archive.stem}"
        result = subprocess.run(
            [str(self.executable), str(archive), str(work), mode, str(missing)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).digest(), source_hash)
        return work / "normalized.amproj"

    def run_native_helper(self, archive, mode, missing=0):
        """Run the preparation path and return its rewritten primary XML."""
        source_hash = hashlib.sha256(archive.read_bytes()).digest()
        work = self.temp / f"work-{archive.stem}"
        result = subprocess.run(
            [str(self.executable), str(archive), str(work), mode, str(missing)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(hashlib.sha256(archive.read_bytes()).digest(), source_hash)
        candidates = list(work.rglob("*.native-import.xml"))
        self.assertEqual(len(candidates), 1, result.stderr)
        return candidates[0].read_text(encoding="utf-8")

    @staticmethod
    def manifest_bytes(resources, line_ending="\n", trailing=False):
        lines = [
            f"{hashlib.sha1(data).hexdigest().upper()}:{name}"
            for name, data in resources.items()
        ]
        text = line_ending.join(lines)
        if trailing:
            text += line_ending
        return text.encode("utf-8")

    def make_archive(self, name, compression, manifest=False):
        archive = self.temp / name
        asset = bytes(range(256)) * 1024
        xml = (
            '<?xml version="1.0"?><scene asset="amproj:asset%20&amp;%20one.bin" '
            'missing="amproj:missing.mp4"/>'
        )
        with zipfile.ZipFile(archive, "w", compression=compression) as output:
            output.writestr("scene.xml", xml)
            output.writestr("asset & one.bin", asset)
            if manifest:
                output.writestr(
                    "manifest.txt", self.manifest_bytes({"asset & one.bin": asset})
                )
        return archive

    def make_multi_xml_archive(self, name, manifest=True):
        archive = self.temp / name
        asset = bytes(range(256)) * 1024
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "first.xml",
                '<?xml version="1.0"?><scene asset="amproj:asset%20&amp;%20one.bin"/>',
            )
            output.writestr(
                "second.xml",
                '<?xml version="1.0"?><scene asset="amproj:asset%20&amp;%20one.bin"/>',
            )
            output.writestr("asset & one.bin", asset)
            if manifest:
                output.writestr(
                    "manifest.txt", self.manifest_bytes({"asset & one.bin": asset})
                )
        return archive

    def make_media_signature_archive(self, name, signature=None):
        archive = self.temp / name
        asset = b"media-resource"
        digest = hashlib.sha1(asset).hexdigest().upper()
        sig_attribute = f' sig="{signature}"' if signature is not None else ""
        xml = (
            '<?xml version="1.0"?><scene>'
            f'<media uri="amproj:asset.bin" type="video/mp4"{sig_attribute}/>'
            '<shape fillVideo="amproj:missing.mp4"/>'
            '</scene>'
        )
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr("scene.xml", xml)
            output.writestr("asset.bin", asset)
            output.writestr("manifest.txt", f"{digest}:asset.bin".encode("ascii"))
        return archive, digest

    def make_multi_xml_nested_media_archive(self, name):
        archive = self.temp / name
        resources = {
            "fonts/custom/font.ttf": b"font-resource-v31",
            "media/images/picture.png": b"image-resource-v31",
            "media/video/clip.mp4": b"video-resource-v31",
        }
        first_xml = (
            '<?xml version="1.0"?><scene title="First">'
            '<media uri="amproj:media/images/picture.png" type="image/png"/>'
            '<shape fillImage="amproj:media/images/picture.png"/>'
            '<text font="amproj:fonts/custom/font.ttf"/>'
            '</scene>'
        )
        second_xml = (
            '<?xml version="1.0"?><scene title="Second">'
            '<media uri="amproj:media/video/clip.mp4" type="video/mp4"/>'
            '<shape fillVideo="amproj:media/video/clip.mp4"/>'
            '</scene>'
        )
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr("scenes/first.xml", first_xml)
            output.writestr("scenes/second.xml", second_xml)
            for resource_name, data in resources.items():
                output.writestr(resource_name, data)
            output.writestr("manifest.txt", self.manifest_bytes(resources))
        return archive, resources

    def test_deflate_without_manifest_and_stored_with_manifest(self):
        self.run_helper(self.make_archive("deflated.amproj", zipfile.ZIP_DEFLATED))
        self.run_helper(
            self.make_archive("stored.amproj", zipfile.ZIP_STORED, manifest=True)
        )

    def test_normalize_preserves_multi_xml_manifest_package_byte_for_byte(self):
        archive = self.make_multi_xml_archive("multi-xml.amproj")
        source = archive.read_bytes()
        normalized = self.run_helper(archive, mode="normalize", missing=0)
        self.assertEqual(normalized.read_bytes(), source)

    def test_missing_media_sig_is_synthesized_from_manifest(self):
        archive, expected = self.make_media_signature_archive("media-sig-missing.amproj")
        xml = self.run_native_helper(archive, mode="manifest", missing=1)
        self.assertIn(f'sig="{expected}"', xml)
        self.assertEqual(xml.count(f'sig="{expected}"'), 1)
        self.assertIn("file://", xml)

    def test_existing_media_sig_is_preserved(self):
        expected = hashlib.sha1(b"media-resource").hexdigest().upper()
        archive, _ = self.make_media_signature_archive(
            "media-sig-existing.amproj", signature=expected
        )
        xml = self.run_native_helper(archive, mode="manifest", missing=1)
        self.assertIn(f'sig="{expected}"', xml)
        self.assertEqual(xml.count(f'sig="{expected}"'), 1)

    def test_mismatched_media_sig_is_rejected(self):
        archive, _ = self.make_media_signature_archive(
            "media-sig-wrong.amproj", signature="0" * 40
        )
        self.run_helper(archive, mode="fail", missing=0)

    def test_manifest_package_without_media_sig_is_rebuilt_with_all_resources(self):
        archive, expected = self.make_media_signature_archive("manifest-signed.amproj")
        normalized = self.run_helper(archive, mode="normalize", missing=1)
        with zipfile.ZipFile(normalized) as output:
            self.assertIsNone(output.testzip())
            self.assertEqual(output.read("asset.bin"), b"media-resource")
            xml_name = next(name for name in output.namelist() if name.endswith(".xml"))
            xml = output.read(xml_name).decode("utf-8")
            self.assertIn(f'sig="{expected}"', xml)
            self.assertEqual(
                output.read("manifest.txt"),
                f"{expected}:asset.bin".encode("ascii"),
            )

    def test_multi_xml_nested_media_and_font_are_all_preserved_and_signed(self):
        archive, resources = self.make_multi_xml_nested_media_archive(
            "multi-nested-media.amproj"
        )
        normalized = self.run_helper(archive, mode="normalize", missing=0)
        with zipfile.ZipFile(normalized) as output:
            self.assertIsNone(output.testzip())
            names = output.namelist()
            self.assertIn("scenes/first.xml", names)
            self.assertIn("scenes/second.xml", names)
            for resource_name, expected_data in resources.items():
                self.assertEqual(output.read(resource_name), expected_data)
            first = output.read("scenes/first.xml").decode("utf-8")
            second = output.read("scenes/second.xml").decode("utf-8")
            image_hash = hashlib.sha1(
                resources["media/images/picture.png"]
            ).hexdigest().upper()
            video_hash = hashlib.sha1(
                resources["media/video/clip.mp4"]
            ).hexdigest().upper()
            self.assertIn(f'sig="{image_hash}"', first)
            self.assertIn(f'sig="{video_hash}"', second)
            manifest_lines = set(output.read("manifest.txt").decode().splitlines())
            self.assertEqual(
                manifest_lines,
                {
                    f"{hashlib.sha1(data).hexdigest().upper()}:{resource_name}"
                    for resource_name, data in resources.items()
                },
            )

    def test_accepts_strict_manifest_line_endings_and_empty_manifest(self):
        asset = b"resource-one"
        for suffix, line_ending, trailing in (
            ("lf", "\n", False),
            ("lf-trailing", "\n", True),
            ("crlf", "\r\n", False),
            ("crlf-trailing", "\r\n", True),
        ):
            with self.subTest(suffix=suffix):
                archive = self.temp / f"manifest-{suffix}.amproj"
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
                    output.writestr(
                        "scene.xml",
                        '<scene asset="amproj:asset.bin" missing="amproj:missing.mp4"/>',
                    )
                    output.writestr("asset.bin", asset)
                    output.writestr(
                        "manifest.txt",
                        self.manifest_bytes(
                            {"asset.bin": asset}, line_ending=line_ending, trailing=trailing
                        ),
                    )
                self.run_helper(archive, mode="manifest", missing=1)

        empty = self.temp / "manifest-empty.amproj"
        with zipfile.ZipFile(empty, "w", zipfile.ZIP_DEFLATED) as output:
            output.writestr("scene.xml", "<scene/>")
            output.writestr("manifest.txt", b"")
        self.run_helper(empty, mode="manifest-empty", missing=0)

    def test_manifest_uses_unique_case_and_nfc_filename_matching(self):
        archive = self.temp / "manifest-nfc-name.amproj"
        resource_name = "caf\u00e9.bin"
        manifest_name = "CAFE\u0301.BIN"
        asset = b"unicode-resource"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "scene.xml",
                f'<scene asset="amproj:{resource_name}" missing="amproj:missing.mp4"/>',
            )
            output.writestr(resource_name, asset)
            output.writestr(
                "manifest.txt", self.manifest_bytes({manifest_name: asset})
            )
        self.run_helper(archive, mode="manifest", missing=1)

    def test_rejects_invalid_or_incomplete_manifest(self):
        asset = b"resource-one"
        asset_hash = hashlib.sha1(asset).hexdigest().upper()
        other = b"resource-two"
        cases = {
            "lowercase-sha1": f"{asset_hash.lower()}:asset.bin",
            "wrong-sha1": f"{'0' * 40}:asset.bin",
            "malformed": f"{asset_hash} asset.bin",
            "duplicate-name": f"{asset_hash}:asset.bin\n{'1' * 40}:ASSET.BIN",
            "duplicate-sha1": f"{asset_hash}:asset.bin\n{asset_hash}:other.bin",
            "missing-file": f"{asset_hash}:absent.bin",
            "lists-xml": f"{asset_hash}:scene.xml",
            "lists-itself": f"{asset_hash}:manifest.txt",
            "unlisted-resource": "",
            "lone-cr": f"{asset_hash}:asset.bin\r{asset_hash}:other.bin",
            "extra-empty-line": f"{asset_hash}:asset.bin\n\n",
        }
        for suffix, manifest in cases.items():
            with self.subTest(suffix=suffix):
                archive = self.temp / f"bad-manifest-{suffix}.amproj"
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
                    output.writestr("scene.xml", '<scene asset="amproj:asset.bin"/>')
                    output.writestr("asset.bin", asset)
                    if suffix == "duplicate-sha1" or suffix == "lone-cr":
                        output.writestr("other.bin", other)
                    output.writestr("manifest.txt", manifest)
                self.run_helper(archive, mode="fail", missing=0)

    def test_multi_xml_without_manifest_is_rejected(self):
        self.run_helper(
            self.make_multi_xml_archive("multi-xml-no-manifest.amproj", manifest=False),
            mode="fail",
            missing=0,
        )

    def test_normalizes_missing_manifest_and_recalculates_resource_hashes(self):
        archive = self.make_archive("normalize.amproj", zipfile.ZIP_DEFLATED)
        with zipfile.ZipFile(archive) as source:
            source_xml = source.read("scene.xml")
            source_asset = source.read("asset & one.bin")
        normalized = self.run_helper(archive, mode="normalize")
        with zipfile.ZipFile(normalized) as output:
            self.assertIsNone(output.testzip())
            names = output.namelist()
            self.assertEqual(sum(name.endswith(".xml") for name in names), 1)
            self.assertIn("asset & one.bin", names)
            self.assertIn("manifest.txt", names)
            normalized_xml = next(name for name in names if name.endswith(".xml"))
            self.assertEqual(output.read(normalized_xml), source_xml)
            self.assertEqual(output.read("asset & one.bin"), source_asset)
            self.assertEqual(
                output.read("manifest.txt"),
                (
                    f"{hashlib.sha1(output.read('asset & one.bin')).hexdigest().upper()}:"
                    "asset & one.bin"
                ).encode(),
            )

    def test_normalizes_data_descriptor_input(self):
        class NonSeekable(io.BytesIO):
            def seekable(self):
                return False

            def seek(self, *args, **kwargs):
                raise io.UnsupportedOperation("not seekable")

        stream = NonSeekable()
        with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr("scene.xml", '<scene asset="amproj:asset.bin"/>')
            output.writestr("asset.bin", b"fixture" * 4096)
        archive = self.temp / "data-descriptor.amproj"
        archive.write_bytes(stream.getvalue())
        with zipfile.ZipFile(archive) as source:
            self.assertTrue(all(info.flag_bits & 0x08 for info in source.infolist()))
        normalized = self.run_helper(archive, mode="normalize", missing=0)
        with zipfile.ZipFile(normalized) as output:
            self.assertIsNone(output.testzip())
            self.assertEqual(output.read("asset.bin"), b"fixture" * 4096)
            self.assertEqual(sum(name.endswith(".xml") for name in output.namelist()), 1)

    def test_counts_each_missing_resource_once(self):
        archive = self.temp / "duplicate-missing-reference.amproj"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "scene.xml",
                '<scene first="amproj:missing.mp4" second="amproj:missing.mp4"/>',
            )
        self.run_helper(archive, mode="normalize", missing=1)

    def test_rejects_traversal_and_multiple_xml_files(self):
        traversal = self.temp / "traversal.amproj"
        with zipfile.ZipFile(traversal, "w") as output:
            output.writestr("scene.xml", "<scene/>")
            output.writestr("../escape.bin", b"escape")
        self.run_helper(traversal, mode="fail", missing=0)

        multiple = self.temp / "multiple.amproj"
        with zipfile.ZipFile(multiple, "w") as output:
            output.writestr("one.xml", "<scene/>")
            output.writestr("two.xml", "<scene/>")
        self.run_helper(multiple, mode="fail", missing=0)

        manifests = self.temp / "multiple-manifests.amproj"
        with zipfile.ZipFile(manifests, "w") as output:
            output.writestr("scene.xml", "<scene/>")
            output.writestr("manifest.txt", "first")
            output.writestr("MANIFEST.TXT", "second")
        self.run_helper(manifests, mode="fail", missing=0)

    def test_rejects_crc_mismatch(self):
        archive = self.make_archive("bad-crc.amproj", zipfile.ZIP_STORED)
        data = bytearray(archive.read_bytes())
        local = data.index(b"PK\x03\x04")
        central = data.index(b"PK\x01\x02")
        wrong_crc = 0x12345678
        struct.pack_into("<I", data, local + 14, wrong_crc)
        struct.pack_into("<I", data, central + 16, wrong_crc)
        archive.write_bytes(data)
        self.run_helper(archive, mode="fail", missing=0)


if __name__ == "__main__":
    unittest.main()
