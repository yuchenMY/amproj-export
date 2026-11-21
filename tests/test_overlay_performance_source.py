"""编辑器/工作台卡顿回归（r138）。

用户实测：不闪退之后，工作台（编辑器）里操作"卡卡的"。成因是云贴片的
后台巡检：每秒一次，在**主线程**上做

  1. 整窗 drawViewHierarchyInRect 截图判色（GPU→CPU 回读，最贵）；
  2. 两次全视图树遍历（找云内容、找分段控件）；
  3. 追加写 bannerlog + NSLog（每秒一次磁盘写与日志刷屏）；
  4. 另外每 5 秒还把整棵视图树 dump 成文件。

编辑器恰好是视图树最大、渲染最忙的页面。r138 的纪律：
  * 编辑器/新建工程/效果选择器里整段跳过，并把贴片收起；
  * 截图只在"贴片正显示"或"刚点过 tab 3 秒内"才做；
  * bannerlog 只在状态变化或 15 秒一次；
  * 视图树 dump 从巡检里移除。
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")


class OverlayPerformanceTests(unittest.TestCase):
    @property
    def tick_block(self) -> str:
        start = SOURCE.index("- (void)startCloudOverlayWatchdog {")
        return SOURCE[start:start + 4000]

    def test_watchdog_is_gated_by_screen(self):
        block = self.tick_block
        self.assertIn("AMCloudOverlayWorkAllowed()", block)
        self.assertIn("AMCloudHideWindowOverlayIfNeeded()", block)

    def test_editor_screens_are_excluded(self):
        block = SOURCE.split("static BOOL AMCloudOverlayWorkAllowed(void)", 1)[1]
        block = block.split("static void AMCloudHideWindowOverlayIfNeeded", 1)[0]
        for keyword in ("@\"Editor\"", "@\"Workbench\"", "@\"CreateVC\"", "@\"EffectPicker\""):
            self.assertIn(keyword, block)

    def test_view_tree_dump_is_not_in_the_periodic_path(self):
        self.assertNotIn("AMCloudDumpViewTree();", self.tick_block)

    def test_screenshot_only_when_visible_or_recent_tap(self):
        block = SOURCE.split(
            "- (void)refreshWindowCloudOverlayVisibility {", 1
        )[1].split("- (void)installCloudTabTapWatcher", 1)[0]
        self.assertIn("if (!overlay.view.hidden || recentTap)", block)
        self.assertIn("AMCloudDetectCloudPillSelected()", block)

    def test_low_frequency_loop_is_gated_too(self):
        # r144：0.8 秒那条兜底轮询以前没有门禁，工程页被编辑器盖住时照样扫全树。
        block = SOURCE.split("cloudBannerVisibilityTickLoop", 1)[1]
        block = block.split("// 评估横幅可见性", 1)[0]
        self.assertIn("AMCloudOverlayWorkAllowed()", block)

    def test_banner_log_is_throttled(self):
        block = SOURCE.split(
            "- (void)refreshWindowCloudOverlayVisibility {", 1
        )[1].split("- (void)installCloudTabTapWatcher", 1)[0]
        self.assertIn("lastSignature", block)
        self.assertIn("< 15.0", block)


if __name__ == "__main__":
    unittest.main()
