"""崩溃日志（r129）源码契约测试。

守住三件事，任一条被改回去都会让「用户闪退 → 下次启动能上传日志」这个
闭环失效，而这类失效在真机上极难发现：

1. 崩溃采集模块必须真的被编进发布 dylib（Makefile 的 all: 目标链）；
2. 信号处理器里只允许 async-signal-safe 的调用（write/close/snprintf），
   不许出现 ObjC/NSLog —— r89 的 %@ 传裸 double 就是这么崩的；
3. 上传走服务端现成的工单接口（/support/tickets + 附件），
   不许另开一套或做离线放行。
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORT_DIR = ROOT / "AMProjExport"

REPORTER = (EXPORT_DIR / "AMProjCrashReporter.m").read_text(encoding="utf-8")
REPORTER_H = (EXPORT_DIR / "AMProjCrashReporter.h").read_text(encoding="utf-8")
MAKEFILE = (EXPORT_DIR / "Makefile").read_text(encoding="utf-8")
EXPORT = (EXPORT_DIR / "AMProjExport.m").read_text(encoding="utf-8")
CLOUD = (EXPORT_DIR / "AMCloudSync.m").read_text(encoding="utf-8")
CLOUD_H = (EXPORT_DIR / "AMCloudSync.h").read_text(encoding="utf-8")


def _target_block(name: str) -> str:
    """取 Makefile 里某个目标到下一个空行为止的块。"""
    lines = MAKEFILE.splitlines()
    collected = []
    active = False
    for line in lines:
        if line.startswith(f"{name}:"):
            active = True
        elif active and line and not line.startswith("\t") and not line.startswith(" "):
            break
        if active:
            collected.append(line)
    return "\n".join(collected)


class CrashReporterBuildTests(unittest.TestCase):
    def test_reporter_is_compiled_into_every_export_target(self):
        for target in ("AMProjExport.dylib", "AMProjExportDebug.dylib",
                       "AMProjExportOffline.dylib"):
            block = _target_block(target)
            self.assertIn("AMProjCrashReporter.m", block, target)
            self.assertIn("AMProjCrashReporter.m", block.split("\n", 1)[1], target)

    def test_reporter_install_runs_before_every_other_installer(self):
        constructor = EXPORT.split("static void AMProjExportInit(void)", 1)[1]
        first = constructor.index("amproj_installCrashReporter();")
        # 崩溃日志必须排在其它 hook 之前，否则 constructor 阶段闪退抓不到。
        self.assertLess(first, constructor.index("amproj_installRatingPromptSuppressor();"))

    def test_lifecycle_observers_keep_sentinel_honest(self):
        self.assertIn("UIApplicationDidEnterBackgroundNotification", EXPORT)
        self.assertIn("UIApplicationDidBecomeActiveNotification", EXPORT)
        self.assertIn("AMProjCrashReporterMarkBackgrounded()", EXPORT)
        self.assertIn("AMProjCrashReporterMarkForegrounded()", EXPORT)

    def test_presentation_hook_leaves_a_breadcrumb(self):
        self.assertIn('AMProjCrashNote(@"present %@"', EXPORT)


class CrashReporterSafetyTests(unittest.TestCase):
    def test_signal_handler_stays_async_signal_safe(self):
        handler = REPORTER.split("static void AMProjCrashSignalHandler", 1)[1]
        handler = handler.split("static void AMProjCrashExceptionHandler", 1)[0]
        self.assertIn("write(fd", handler)
        self.assertIn("close(fd)", handler)
        # 处理器里绝不允许出现 ObjC 对象 / NSLog / 格式化词典。
        for forbidden in ("NSString", "NSLog", "@\"", "appendFormat"):
            self.assertNotIn(forbidden, handler)

    def test_handler_reraises_so_system_still_writes_ips(self):
        handler = REPORTER.split("static void AMProjCrashSignalHandler", 1)[1]
        handler = handler.split("static void AMProjCrashExceptionHandler", 1)[0]
        self.assertIn("signal(signalNumber, SIG_DFL)", handler)
        self.assertIn("raise(signalNumber)", handler)

    def test_all_fatal_signals_are_covered(self):
        for name in ("SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGTRAP"):
            self.assertIn(name, REPORTER)

    def test_backtrace_is_resolved_weakly(self):
        # 链接期不能硬依赖 backtrace 符号，否则 dylib 加载失败。
        self.assertIn('dlsym(handle, "backtrace")', REPORTER)
        self.assertIn('dlsym(handle, "backtrace_symbols_fd")', REPORTER)

    def test_report_is_bounded_and_under_caches(self):
        self.assertIn("AMProjExport.crashreport", REPORTER)
        self.assertIn("NSCachesDirectory", REPORTER)
        self.assertIn("128 * 1024", REPORTER)

    def test_no_raw_double_into_format_string(self):
        # @(x) 装箱纪律：崩溃模块里所有时间戳都必须显式转成整数再进格式串。
        self.assertIn("(long long)time(NULL)", REPORTER)
        self.assertIn("(int)getpid()", REPORTER)

    def test_862_private_abi_never_enters_this_module(self):
        for forbidden in ("PackageImporter", "ShareNC", "UIDocumentPicker",
                          "AMProjExportCloud.dylib"):
            self.assertNotIn(forbidden, REPORTER + REPORTER_H)


class CrashTicketUploadTests(unittest.TestCase):
    def test_header_exposes_the_upload_entrypoint(self):
        self.assertIn("AMCloudSubmitCrashTicket", CLOUD_H)

    def test_upload_reuses_the_support_ticket_api(self):
        self.assertIn('@"/support/tickets"', CLOUD)
        self.assertIn('@"/support/tickets/%@/attachments"', CLOUD)
        self.assertIn("X-AM-Attach-Filename", CLOUD)
        self.assertIn('"text/plain; charset=utf-8"', CLOUD)

    def test_upload_requires_login_and_never_falls_back_offline(self):
        block = CLOUD.split("void AMCloudSubmitCrashTicket", 1)[1]
        block = block.split("\nvoid ", 1)[0]
        self.assertIn("AMCloudReadToken()", block)
        self.assertIn("还没有登录猫鹤账户", block)
        for forbidden in ("cache", "offline", "bypass"):
            self.assertNotIn(forbidden, block)

    def test_prompt_is_a_top_banner_plus_bottom_sheet(self):
        sheet = REPORTER.split("AMProjCrashSheet : UIViewController", 1)[1]
        for label in ("发送日志", "复制日志", "以后再说", "上次崩溃了"):
            self.assertIn(label, sheet)
        self.assertIn("不含你的作品内容", sheet)
        # 顶部细横幅（不挡操作）→ 点开才进抽屉；主按钮是黑色实心，不再用渐变。
        banner = REPORTER.split("AMProjCrashBanner : UIView", 1)[1]
        self.assertIn("上次崩溃了", banner)
        self.assertIn("发送", banner)
        self.assertNotIn("CAGradientLayer", REPORTER)
        self.assertNotIn("UIAlertController", REPORTER)

    def test_card_modal_style_set_before_present(self):
        init = REPORTER.split("AMProjCrashSheet", 1)[1].split("- (instancetype)init {", 1)[1]
        init = init.split("- (void)viewDidLoad", 1)[0]
        self.assertIn("UIModalPresentationOverFullScreen", init)
        # r104 的教训：写进 viewDidLoad 等于没写。
        self.assertNotIn("modalPresentationStyle", REPORTER.split("- (void)viewDidLoad", 1)[1].split("}", 1)[0])


if __name__ == "__main__":
    unittest.main()
