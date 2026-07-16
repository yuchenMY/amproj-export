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

    def make_archive(self, name, compression, manifest=False):
        archive = self.temp / name
        xml = (
            '<?xml version="1.0"?><scene asset="amproj:asset%20&amp;%20one.bin" '
            'missing="amproj:missing.mp4"/>'
        )
        with zipfile.ZipFile(archive, "w", compression=compression) as output:
            output.writestr("scene.xml", xml)
            output.writestr("asset & one.bin", bytes(range(256)) * 1024)
            if manifest:
                output.writestr("manifest.txt", "fixture")
        return archive

    def test_deflate_without_manifest_and_stored_with_manifest(self):
        self.run_helper(self.make_archive("deflated.amproj", zipfile.ZIP_DEFLATED))
        self.run_helper(
            self.make_archive("stored.amproj", zipfile.ZIP_STORED, manifest=True)
        )

    def test_normalizes_missing_manifest_and_recalculates_resource_hashes(self):
        archive = self.make_archive("normalize.amproj", zipfile.ZIP_DEFLATED)
        with zipfile.ZipFile(archive) as source:
            source_xml = source.read("scene.xml")
        normalized = self.run_helper(archive, mode="normalize")
        with zipfile.ZipFile(normalized) as output:
            self.assertIsNone(output.testzip())
            names = output.namelist()
            self.assertEqual(names[-1], "manifest.txt")
            self.assertEqual(sum(name.endswith(".xml") for name in names), 1)
            normalized_xml = next(name for name in names if name.endswith(".xml"))
            self.assertEqual(output.read(normalized_xml), source_xml)
            self.assertEqual(
                output.read("manifest.txt"),
                (
                    f"{hashlib.sha1(output.read('asset & one.bin')).hexdigest().upper()}:"
                    "asset & one.bin"
                ).encode(),
            )
            for info in output.infolist():
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))

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
        self.run_helper(archive, mode="normalize", missing=0)

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
