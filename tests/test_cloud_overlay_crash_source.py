"""云端贴片挂载路径的崩溃回归（r137）。

真机 .ips 证据（工单 17 / 18，signal=11）栈顶：

    AMCloudScanAccessibilityForSelectedTab + 372 / + 680 (递归)
    -[AMCloudManager updateCloudBackupBannerVisibilityForController:]
    -[AMCloudManager attachCloudBackupBannerToController:]
    -[AMCloudManager attachAccountEntryToController:]
    AMCloudAttachProjectsInControllerTree
    AMCloudAttachVisibleProjectsControllers
    -[AMCloudManager startCloudOverlayWatchdog]  ← 每秒一次的定时器

即：每秒一次的后台看门狗在「新建工程 / 页面切换」时遍历视图与 a11y 树，
踩到正在重建的 SwiftUI 视图 → SIGSEGV。

r137 的两条纪律：
1. a11y 通道整条删除（从未在任何真机日志里返回过 1，却能炸 App）；
2. 有模态在其上时不再往背后的工程页挂贴片。
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")


class CloudOverlayCrashTests(unittest.TestCase):
    @property
    def visibility_block(self) -> str:
        marker = ("- (void)updateCloudBackupBannerVisibilityForController:"
                  "(UIViewController *)controller {")
        self.assertIn(marker, SOURCE)
        block = SOURCE.split(marker, 1)[1]
        return block.split("\n- (void)showCloudBackupManager:", 1)[0]

    def test_accessibility_scan_is_gone(self):
        # 定义与调用都不能留：留着就可能被再次接回定时器。
        self.assertNotIn("AMCloudScanAccessibilityForSelectedTab", SOURCE)

    def test_visibility_path_does_not_touch_accessibility_elements(self):
        self.assertNotIn("accessibilityElements", self.visibility_block)

    def test_empty_state_scan_no_longer_enumerates_accessibility_elements(self):
        block = SOURCE.split("static BOOL AMCloudOfficialCloudContentOnScreen", 1)[1]
        block = block.split("static NSString *AMCloudLabelAtPoint", 1)[0]
        self.assertNotIn("accessibilityElements", block)

    def test_attach_skips_while_a_modal_is_up(self):
        block = SOURCE.split(
            "static void AMCloudAttachProjectsInControllerTree", 1
        )[1].split("static void AMCloudAttachVisibleProjectsControllers", 1)[0]
        self.assertIn("controller.presentedViewController == nil", block)

    def test_watchdog_is_still_the_only_periodic_caller(self):
        # 保留其它三条通道（文案 / 分段控件 / 埋点窗口），只拿掉 a11y。
        block = SOURCE.split(
            "- (void)updateCloudBackupBannerVisibilityForController:", 1
        )[1].split("- (void)showCloudBackupManager:", 1)[0]
        for channel in ("textSignal", "segSignal", "signalRecent"):
            self.assertIn(channel, block)


if __name__ == "__main__":
    unittest.main()
