"""法务同意弹窗自动确认（r136）源码契约。

背景：865 的 BSPLegal 模块在拿不到服务端 lastAcceptedVersion 时，
每次启动都会弹一次「使用猫鹤 AM-Meow 之前，您必须确认…隐私政策」，
用户每次都得点「继续」。r136 在呈现层把「继续」的动作执行掉，
弹窗不上屏——等价于用户每次都点了继续。

这些约束任何一条被改坏，都会退回到「每次启动都弹」或误吞业务弹窗。
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")


class LegalConsentSourceTests(unittest.TestCase):
    def test_matcher_is_narrow(self):
        block = SOURCE.split("static BOOL amproj_isLegalConsentAlert", 1)[1]
        block = block.split("static UIAlertAction *amproj_legalContinueAction", 1)[0]
        self.assertIn("隐私政策", block)
        self.assertIn("privacy policy", block)
        # 只认法务文案，且按钮数受限，避免把付费墙/登录墙一起吞掉。
        self.assertIn("alert.actions.count > 2", block)

    def test_continue_action_is_matched_by_title(self):
        block = SOURCE.split("amproj_legalContinueAction", 1)[1]
        block = block.split("amproj_autoAcceptLegalAlert", 1)[0]
        for keyword in ("继续", "同意", "Continue"):
            self.assertIn(keyword, block)

    def test_handler_lookup_degrades_instead_of_crashing(self):
        block = SOURCE.split("static BOOL amproj_autoAcceptLegalAlert", 1)[1]
        block = block.split("static void hooked_presentVC", 1)[0]
        self.assertIn("@try", block)
        self.assertIn("@catch", block)
        self.assertIn("valueForKey:@\"handler\"", block)
        # 拿不到 handler 必须退出接管，让调用方走原生呈现。
        self.assertIn("if (!handler) return NO;", block)

    def test_first_time_is_shown_then_never_again(self):
        # r145：用户要的是"第一次正常弹一次、点过继续之后永远不弹"。
        self.assertIn("kAMProjLegalAcceptedKey", SOURCE)
        self.assertIn("amproj_legalAlreadyAccepted()", SOURCE)
        self.assertIn("amproj_watchLegalConsentDismissal", SOURCE)
        self.assertIn("legal.first_time_presented", SOURCE)
        self.assertIn("legal.accepted_once", SOURCE)
        # 没点过之前绝不允许替用户放行：自动确认必须出现在 alreadyAccepted 分支里。
        hook = SOURCE.split("static void hooked_presentVC", 1)[1]
        gate = hook.index("if (amproj_legalAlreadyAccepted())")
        auto = hook.index("amproj_autoAcceptLegalAlert((UIAlertController *)controller)")
        self.assertLess(gate, auto)

    def test_fallback_dismisses_when_handler_is_unavailable(self):
        # r144：有些版本的隐私弹窗不是 UIAlertController / handler 拿不到，
        # 必须有一条"先显示再立刻收掉"的兜底。
        self.assertIn("amproj_scheduleLegalAutoDismiss", SOURCE)
        self.assertIn("_dismissAnimated:triggeringAction:", SOURCE)
        self.assertIn("legal.auto_accept_fallback", SOURCE)
        self.assertIn("amproj_controllerLooksLegal", SOURCE)

    def test_hook_runs_before_other_presentation_work(self):
        hook = SOURCE.split("static void hooked_presentVC", 1)[1]
        hook = hook.split("amproj_forwardPresentation(self, _cmd, controller, animated, completion);", 1)[1]
        # 在面包屑之后、其它接管之前就处理法务弹窗。
        self.assertLess(hook.index("amproj_isLegalConsentAlert"),
                        hook.index("AMProjStartSelfCloudUpload"))


if __name__ == "__main__":
    unittest.main()
