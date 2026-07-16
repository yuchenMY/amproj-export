import hashlib
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
