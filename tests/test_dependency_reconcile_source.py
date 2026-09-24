import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORT = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")


def _reconcile_region() -> str:
    start = EXPORT.index("static void amproj_reconcileDependencies(void) {")
    end = EXPORT.index("static void amproj_scheduleDependencyReconcile(void) {", start)
    return EXPORT[start:end]


class DependencyReconcileSourceTests(unittest.TestCase):
    def test_reconcile_never_runs_on_the_main_queue(self):
        region = _reconcile_region()
        self.assertNotIn("dispatch_get_main_queue", region)
        scheduler = EXPORT[
            EXPORT.index("static void amproj_scheduleDependencyReconcile(void) {"):
            EXPORT.index("// NSTimer 的 target 会被强持有",)
        ]
        self.assertIn("dispatch_async(amproj_dependencyQueue()", scheduler)
        self.assertIn("DISPATCH_QUEUE_SERIAL", EXPORT)

    def test_activation_and_timer_route_through_scheduler(self):
        activation = EXPORT[EXPORT.index("static NSDate *lastDependencyReconcile"):]
        self.assertIn("amproj_scheduleDependencyReconcile();", activation)
        self.assertNotIn("amproj_restoreDependencies", EXPORT)
        proxy = EXPORT[EXPORT.index("@implementation AMProjRestoreTimerProxy"):]
        proxy = proxy[:proxy.index("@end")]
        self.assertIn("amproj_scheduleDependencyReconcile();", proxy)

    def test_loose_reference_pattern_covers_format_drift(self):
        region = _reconcile_region()
        self.assertIn(r'@"am-internal:///([^\"]+)\""', region)
        self.assertNotIn("[A-Fa-f0-9]{40}", region)

    def test_protected_set_publishes_before_restore(self):
        region = _reconcile_region()
        publish = region.index("[amproj_protectedDependencyNames() setSet:referenced];")
        early_return = region.index("if (!needed.count) return;")
        restore_loop = region.index("missingBackup++;")
        self.assertLess(publish, early_return)
        self.assertLess(early_return, restore_loop)

    def test_rebackup_pass_persists_app_written_dependencies(self):
        region = _reconcile_region()
        self.assertIn(".%@.%@.backup", region)
        self.assertIn("reBackedUp++", region)
        self.assertIn("rebacked=%lu", region)

    def test_removal_heals_instead_of_refusing(self):
        # 拒绝删除会打断 app 自身的保存/替换/清理流程（实测连音量写回都被
        # 回滚），改为删除放行后从留底立刻还原；只对被引用的依赖文件自愈。
        region = EXPORT[
            EXPORT.index("static NSString *amproj_protectedDependencyNameForPath("):
            EXPORT.index("static void amproj_installDependencyProtection(void) {")
        ]
        self.assertIn("amproj_restoreDependencyFromBackup", region)
        self.assertIn("healed:", region)
        self.assertIn("orig_removeItemAtPath(self, _cmd, path, error)", region)
        self.assertIn("orig_removeItemAtURL(self, _cmd, URL, error)", region)
        self.assertNotIn("NSFileWriteNoPermissionError", region)
        self.assertIn("hasPrefix:@\".\"", region)
        self.assertIn("amproj_dependencyNameIsProtected(name)", region)
        install = EXPORT[
            EXPORT.index("static void amproj_installDependencyProtection(void) {"):
            EXPORT.index("static void amproj_installPresentationHook(void) {")
        ]
        self.assertIn("removeItemAtPath:error:", install)
        self.assertIn("removeItemAtURL:error:", install)
        self.assertIn('amproj_installDependencyProtection();',
                      EXPORT[EXPORT.index("amproj_installPresentationHook();"):]
                      [:400])

    def test_volume_writeback_rescue_uses_native_channel(self):
        # 音量 widget 的写回（onVolumeValueChange:forEvent: ->
        # setVolume:userInitiated:）接线丢失时数值钉死 100、播放后跳回默认。
        # 救援只走 app 自己的通道与单位：接线补齐 + 写后校验补写。
        region = EXPORT[EXPORT.index("// ── 音量写回救援"):]
        region = region[:region.index("// ── 依赖文件删除自愈")]
        self.assertIn("onVolumeValueChange:forEvent:", region)
        self.assertIn("setVolume:userInitiated:", region)
        self.assertIn("amproj_forceVolumeWrite", region)
        self.assertIn("amproj_attachVolumeRescueAction", region)
        self.assertIn("amproj_writeVolumeIvarDirect", region)
        self.assertIn("amproj_collectVolumeWriteTargets", region)
        self.assertIn("amproj_classRespondingTo(handlerSel)", region)
        self.assertIn("amproj_classRespondingTo(outletSel)", region)
        self.assertIn("ivar_getOffset", region)
        self.assertIn("UIAction", region)
        self.assertIn("NSInvocation", region)
        self.assertIn("amproj_installVolumeWritebackRescue();", EXPORT)

    def test_reconcile_scan_is_memoized_by_stat(self):
        region = _reconcile_region()
        self.assertIn("scanCache", region)
        self.assertIn("NSFileModificationDate", region)
        self.assertIn("cachedNames", region)

    def test_failure_and_share_presentations_use_safe_presenter(self):
        failure = EXPORT[EXPORT.index("void (^showFailure)(void) = ^{"):]
        failure = failure[:failure.index("if (request.progressAlert.presentingViewController)")]
        self.assertIn("amproj_safeDirectPresenter(presenter)", failure)
        self.assertIn("@try", failure)
        self.assertIn("direct.failure_alert_exception", failure)
        share = EXPORT[EXPORT.index("static void amproj_presentDirectShare("):]
        share = share[:share.index("static void amproj_writeDirectArchive(")]
        self.assertIn("amproj_safeDirectPresenter(request.presenter)", share)

    def test_shared_slider_range_is_never_clamped(self):
        # OpacitySlider 被不透明度、音量（0-200%）等参数行共用，且通用属性行
        # 会把任意参数的滑条挂在 opacitySlider 命名的 outlet 上——面板/标签/
        # 属性标识都不可靠。历史上 r48 一刀切、r49 值窗、r52 归属识别三版钳制
        # 都在真实 UI 上把音量钉死在 100%。禁止再对这个共享类挂钩
        # setMaximumValue:/setMinimumValue:；100.3% 的显示漂移是可接受代价。
        self.assertNotIn("hooked_opacitySliderSetMaximum", EXPORT)
        self.assertNotIn("hooked_opacitySliderSetMinimum", EXPORT)
        self.assertNotIn("amproj_installOpacitySliderClamp", EXPORT)
        self.assertNotIn("AMProjSharedSliderRole", EXPORT)

    def test_gate_takeover_dismiss_is_exception_guarded(self):
        # 分发设备的登录墙接管是独有路径：dismiss 撞上进行中的过渡会同步抛
        # 异常，接管后的导出呈现也必须走安全 presenter。
        takeover = EXPORT[EXPORT.index("static void AMProjScheduleGateTakeover("):]
        takeover = takeover[:takeover.index("static void hooked_alertAddAction(")]
        self.assertIn("@try", takeover)
        self.assertIn("direct.865_takeover_dismiss_exception", takeover)
        self.assertIn("amproj_safeDirectPresenter(presenter)", takeover)


if __name__ == "__main__":
    unittest.main()
