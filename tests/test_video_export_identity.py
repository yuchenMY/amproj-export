"""Export completion must not substitute historical videos for current output."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport/AMProjExport.m").read_text(encoding="utf-8")


def function(signature):
    start = SOURCE.index(signature)
    return SOURCE[start:SOURCE.index("\n}\n", start) + 3]


class VideoExportIdentityTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Requires Objective-C/Foundation")
    def test_actual_resolver_rejects_old_assets_and_accepts_small_current_output(self):
        implementation = "\n".join([
            function("static NSURL *AMProjReplicaVerifiedVideoURL(id value) {"),
            function("static NSURL *AMProjReplicaVideoURLFromController(UIViewController *controller) {"),
        ])
        fixture = (ROOT / "tests/video_export_identity_smoke.m").read_text(encoding="utf-8")
        fixture = fixture.replace("// AMPROJ_PRODUCTION_VIDEO_IDENTITY", implementation)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "video_identity.m"
            binary = directory / "video_identity"
            source.write_text(fixture, encoding="utf-8")
            compiled = subprocess.run([
                "clang", "-fobjc-arc", "-framework", "Foundation", str(source), "-o", str(binary)
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            tested = subprocess.run([str(binary), str(directory)], capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(tested.returncode, 0, tested.stdout + tested.stderr)
            self.assertIn("VIDEO_EXPORT_IDENTITY_PASS", tested.stdout)


if __name__ == "__main__":
    unittest.main()
