"""导出失败的提示必须是中文大白话（r143）。

用户反馈：有人导出失败时看到的是英文（"Unable to resolve required resource: …"
这类）。英文原文只该进日志，弹窗要给用户看得懂、并且知道下一步做什么的中文。
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")


class ExportErrorMessageTests(unittest.TestCase):
    @property
    def mapper(self) -> str:
        start = SOURCE.index("static NSString *amproj_userFacingExportMessage")
        return SOURCE[start:start + 4200]

    def test_failure_alert_uses_the_friendly_message(self):
        block = SOURCE.split("static void amproj_finishDirectFailure", 1)[1]
        block = block.split("// MARK: - Local .amproj import bridge", 1)[0]
        self.assertIn("amproj_userFacingExportMessage(error)", block)
        # 弹窗里不允许再直接甩英文的 localizedDescription。
        alert_block = block.split('alertControllerWithTitle:@"无法生成 .amproj"', 1)[1]
        alert_block = alert_block.split("preferredStyle", 1)[0]
        self.assertNotIn("error.localizedDescription", alert_block)

    def test_missing_media_codes_are_explained(self):
        block = self.mapper
        for code in ("code == 22", "code == 23", "code == 24"):
            self.assertIn(code, block)
        self.assertIn("重新导入", block)

    def test_disk_space_and_timeout_are_explained(self):
        block = self.mapper
        self.assertIn("存储空间", block)
        self.assertIn("code == 55", block)
        self.assertIn("code == 51", block)

    def test_resource_name_is_extracted_from_the_technical_message(self):
        self.assertIn("amproj_exportHintName", SOURCE)
        block = SOURCE.split("static NSString *amproj_exportHintName", 1)[1]
        block = block.split("static NSString *amproj_userFacingExportMessage", 1)[0]
        self.assertIn("lastPathComponent", block)


if __name__ == "__main__":
    unittest.main()
