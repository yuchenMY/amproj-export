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

    def test_removal_veto_is_installed_and_scoped(self):
        self.assertIn("static BOOL hooked_removeItemAtPath(id self, SEL _cmd,",
                      EXPORT)
        self.assertIn("static BOOL hooked_removeItemAtURL(id self, SEL _cmd,",
                      EXPORT)
        install = EXPORT[
            EXPORT.index("static void amproj_installDependencyProtection(void) {"):
            EXPORT.index("static void amproj_installOpacitySliderClamp(void) {")
        ]
        self.assertIn("removeItemAtPath:error:", install)
        self.assertIn("removeItemAtURL:error:", install)
        self.assertIn('amproj_installDependencyProtection();',
                      EXPORT[EXPORT.index("amproj_installPresentationHook();"):]
                      [:400])
        veto = EXPORT[
            EXPORT.index("static BOOL amproj_shouldVetoDependencyRemoval("):
            EXPORT.index("static void amproj_vetoDependencyRemovalError(")
        ]
        self.assertIn("project-dependencies", EXPORT[
            EXPORT.index("static NSURL *amproj_v865DependencyStoreURL(void) {"):
            EXPORT.index("static NSURL *amproj_v865DependencyBackupURL(void) {")
        ])
        self.assertIn("hasPrefix", veto)
        self.assertIn("hasPrefix:@\".\"", veto)
        self.assertIn("amproj_dependencyNameIsProtected(name)", veto)

    def test_failure_and_share_presentations_use_safe_presenter(self):
        failure = EXPORT[EXPORT.index("void (^showFailure)(void) = ^{"):]
        failure = failure[:failure.index("if (request.progressAlert.presentingViewController)")]
        self.assertIn("amproj_safeDirectPresenter(presenter)", failure)
        self.assertIn("@try", failure)
        self.assertIn("direct.failure_alert_exception", failure)
        share = EXPORT[EXPORT.index("static void amproj_presentDirectShare("):]
        share = share[:share.index("static void amproj_writeDirectArchive(")]
        self.assertIn("amproj_safeDirectPresenter(request.presenter)", share)

    def test_opacity_clamp_is_gated_by_positive_ownership(self):
        # 音量（EditVolumePanelVC 的 volumeSlider，0-200%）与不透明度共用
        # OpacitySlider，且 BlendOpacityPanelCell 会被复用给音量行：按类名
        # 子串识别必误伤。钳制必须由属性标识/标签正向确认不透明度归属后才
        # 生效；音量与识别不了的一律放行（音量 0-200% 不能再被卡在 100）。
        region = EXPORT[EXPORT.index("typedef NS_ENUM(NSUInteger, AMProjSharedSliderRole) {"):]
        region = region[:region.index("static void hooked_opacitySliderSetMaximum(")]
        self.assertIn('valueForKey:@"volumeSlider"', region)
        self.assertIn('valueForKey:@"opacitySlider"', region)
        self.assertIn("AMProjSharedSliderRoleUnknown", region)
        self.assertIn("音量", region)
        self.assertNotIn("containsString:@\"BlendOpacityPanel\"", region)
        hooks = EXPORT[EXPORT.index("static void hooked_opacitySliderSetMaximum("):]
        hooks = hooks[:hooks.index("static void amproj_installOpacitySliderClamp(void) {")]
        self.assertEqual(
            hooks.count(
                "amproj_sharedSliderRole(self) == AMProjSharedSliderRoleBlendOpacity"),
            2, "max/min 两个钩子都必须按正向归属钳制")

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
