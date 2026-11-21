"""项目包完整性（r140）。

用户反馈：iOS 导出的 .amproj 拿到安卓二开版上，**部分叠层消失**。
复盘导出链路（native XML → 收集素材 → 改写引用 → 打 zip）后发现三个
可能"悄悄少件"的口子：

1. 素材引用以前只认固定属性名（uri/source/src/fillImage/fillVideo/font/file），
   挂在别的属性上的素材不会被打包；
2. 文本节点（`<font>xxx.ttf</font>` 这类）完全没看；
3. 引用改写按 XML 出现顺序做，若 A 是 B 的子串，先换短的会把长的改坏。

r140 的纪律：
  * 按"值像不像素材"判断，不再依赖属性名，并扫描文本节点；
  * 改长串优先；
  * 必须解析的引用（am-internal:/amproj:/file:/绝对路径/phasset-）解析失败就失败；
    只是"看起来像"的引用解析失败则跳过并记日志；
  * 改写完再扫一遍，还有 `am-internal:///` 或 `file:///` 就说明必然缺件，
    直接报错，不交付缺图的包。
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")


class ProjectPackageCompletenessTests(unittest.TestCase):
    @property
    def collect_block(self) -> str:
        start = SOURCE.index(
            "static NSDictionary* amproj_collectResourcesAndRewriteXML")
        return SOURCE[start:start + 9000]

    def test_attribute_name_whitelist_is_gone(self):
        probe = SOURCE.split("@implementation AMProjXMLProbe", 1)[1]
        probe = probe.split("@end", 1)[0]
        self.assertNotIn("containsObject:key", probe)
        self.assertIn("amproj_valueLooksLikeResource", probe)

    def test_text_nodes_are_scanned(self):
        self.assertIn("- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string", SOURCE)
        probe = SOURCE.split("@implementation AMProjXMLProbe", 1)[1]
        probe = probe.split("@end", 1)[0]
        self.assertIn("pendingCharacters", probe)

    def test_rewrite_is_longest_first(self):
        block = self.collect_block
        self.assertIn("sortedArrayUsingComparator", block)
        self.assertIn("left.length > right.length", block)

    def test_required_vs_optional_references(self):
        block = self.collect_block
        self.assertIn("amproj_referenceIsRequired(reference)", block)
        self.assertIn("skippedOptional", block)
        self.assertIn("direct.archive_skipped_soft_references", block)

    def test_unresolved_references_fail_the_export(self):
        block = self.collect_block
        self.assertIn("amproj_probeXML", block)
        self.assertIn("direct.archive_unresolved_references", block)
        self.assertIn("amproj_directError(24", block)

    def test_export_writes_native_am_internal_names(self):
        # 真实工程包里素材就是 am-internal:///<HASH>.<EXT>；写成别的 scheme
        # 安卓端的引擎不认识，那些图层就会消失。
        block = self.collect_block
        self.assertIn('@"am-internal:///" stringByAppendingString:archiveName', block)
        self.assertIn("amproj_internalReferenceName", block)
        self.assertNotIn('@"amproj:" stringByAppendingString:archiveName', block)

    def test_xml_extension_is_not_treated_as_a_media_resource(self):
        # 资源条目不允许 .xml（ZIP writer 会拒绝），别把它拉进素材表。
        block = SOURCE.split("static BOOL amproj_valueLooksLikeResource", 1)[1]
        block = block.split("static BOOL amproj_referenceIsRequired", 1)[0]
        self.assertNotIn('@"xml"', block)


if __name__ == "__main__":
    unittest.main()
