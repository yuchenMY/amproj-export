import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "AMProjExport" / "AMProjImportArchive.m"
HEADER = ROOT / "AMProjExport" / "AMProjImportArchive.h"
MAKEFILE = ROOT / "AMProjExport" / "Makefile"


class ImportArchiveSourceTests(unittest.TestCase):
    def test_public_api_and_build_include_module(self):
        self.assertIn("AMProjPrepareNativeImport", HEADER.read_text(encoding="utf-8"))
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertEqual(makefile.count("AMProjZIPWriter.m AMProjImportArchive.m"), 2)

    def test_zip_safety_and_integrity_checks_are_present(self):
        source = SOURCE.read_text(encoding="utf-8")
        for required in (
            "0x06054b50",
            "0x02014b50",
            "0x04034b50",
            "ZIP64",
            "Split project packages",
            "O_NOFOLLOW",
            "crc32",
            "inflateInit2(&stream, -MAX_WBITS)",
            "ZIP entries overlap",
        ):
            self.assertIn(required, source)

    def test_source_archive_is_never_opened_for_writing(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("open(archiveURL.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW)", source)
        self.assertNotIn("unlink(archiveURL.fileSystemRepresentation)", source)

    def test_xml_rewrite_and_atomic_publish_are_present(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("amproj:", source)
        self.assertIn("AMProjImportEscapeXMLValue(url.absoluteString)", source)
        self.assertIn(".native-import.xml", source)
        self.assertIn("missing_reference_count", source)
        self.assertIn("if (url) {", source)
        self.assertIn("localMissingCount++;", source)
        self.assertNotIn('URLByAppendingPathComponent:@".missing"', source)
        self.assertIn("rename(temporaryURL.fileSystemRepresentation", source)


if __name__ == "__main__":
    unittest.main()
