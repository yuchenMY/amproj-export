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

    def test_dark_appearance_enforced_on_all_windows(self):
        # 资源面板（形状/媒体/对象元素）用系统语义色渲染：手机浅色模式下
        # 面板背景=白、图标=白，白上白即"泛白"；重装后观设置重置为跟随
        # 系统所以必现。全局压深色 trait，新窗口出现时同样套用。
        region = EXPORT[EXPORT.index("// ── 资源库泛白修复"):]
        region = region[:region.index("// ── 资源库权限救援")]
        self.assertIn("UIUserInterfaceStyleDark", region)
        self.assertIn("overrideUserInterfaceStyle", region)
        self.assertIn("UIWindowDidBecomeVisibleNotification", region)
        self.assertIn("amproj_installDarkAppearanceEnforcement();", EXPORT)

    def test_media_permission_probe_and_nudge(self):
        # 权限被拒/未决定也会让媒体/音频页空白：主动申请 + 被拒时提示跳设置。
        region = EXPORT[EXPORT.index("// ── 资源库权限救援"):]
        region = region[:region.index("// ── 音量写回救援")]
        self.assertIn("PHPhotoLibrary", region)
        self.assertIn("MPMediaLibrary", region)
        self.assertIn("requestAuthorization", region)
        self.assertIn("UIApplicationOpenSettingsURLString", region)
        self.assertIn("amproj_probeMediaLibraryAccess();", EXPORT)

    def test_bootstrap_banner_removed_and_auth_deadlined(self):
        # 启动红字已按用户要求移除；导入授权必须有死线（挂死曾把事务永远
        # 留在 creating_project）。
        bootstrap = EXPORT[EXPORT.index('(void)interruptedStage;'):]
        self.assertNotIn("上次导入在", bootstrap)
        store = EXPORT[EXPORT.index('__block BOOL authSettled = NO;'):]
        store = store[:store.index("#else")]
        self.assertIn("20.0 * NSEC_PER_SEC", store)
        self.assertIn("settleStoreDenied", store)

    def test_welcome_defense_visual_only(self):
        # welcome 每次启动冒出 = 防御被 a5c027e 关死。重开视觉压制，但合成
        # 点击（fireGateSkipControl）永久禁用：代按 continue/close 会丢会员
        # 权益；Blatant 欢迎页自带倒计时自关，无需代按。
        flags = EXPORT[EXPORT.index("static BOOL amproj_gateDefenseActive"):]
        flags = flags[:flags.index("static BOOL amproj_introAutocloseEnabled")]
        self.assertIn("amproj_gateDefenseActive = YES;", flags)
        self.assertIn("amproj_gateSkipControlEnabled = NO;", flags)
        self.assertIn("amproj_funnelSweepEnabled = NO;", flags)
        skip = EXPORT[EXPORT.index("static BOOL amproj_fireGateSkipControl("):]
        skip = skip[:skip.index("static void amproj_gateCycleEnd")]
        self.assertIn("if (!amproj_gateSkipControlEnabled) return NO;", skip)

    def test_false_import_failure_suppressed_after_success(self):
        # QQ 双投递：一条读取成功导入，另一条读取竞态失败——曾成功之后还弹
        # "无法导入 XML"。源读取失败统一静默等重投递；成功记忆（90s）拦住
        # 误报，10 秒无重投递且无成功才弹一次过期提示。
        region = EXPORT[EXPORT.index("static NSMutableDictionary<NSString *, NSNumber *> *amproj_recentImportSuccessMap("):]
        region = region[:region.index("static void amproj_clearIncomingGrantLoss(")]
        self.assertIn("amproj_recentlyImportedSuccessfully(name)", region)
        self.assertIn("import.grant_loss_suppressed_by_success", region)
        copy_fail = EXPORT[EXPORT.index("BOOL cocoaSourceReadFailure ="):]
        copy_fail = copy_fail[:copy_fail.index("return AMProjIncomingURLFailed;")]
        self.assertIn("NSPOSIXErrorDomain", copy_fail)
        self.assertIn("AMProjImportFileErrorOpenSource", copy_fail)
        self.assertIn("amproj_noteIncomingGrantLoss(originalName", copy_fail)
        success = EXPORT[EXPORT.index("if (success) {"):]
        success = success[:success.index("amproj_clearIncomingGrantLoss(transaction.name);")]
        self.assertIn("amproj_recordIncomingImportSuccess(transaction.name);", success)

    def test_offline_takeover_spares_meowcr_and_replays_config(self):
        # 官方服务器全死不影响使用：配置缓存回放、授权压超时、广告快断；
        # am.meowcr.cn 授权门是刻意保留的杀伤开关，一根毫毛都不能碰。
        region = EXPORT[EXPORT.index("// ── 官方服务器接管"):]
        region = region[:region.index("// ── 资源库泛白修复")]
        self.assertIn('containsString:@"meowcr"', region)
        self.assertIn("amproj_storeOfflineConfig", region)
        self.assertIn("amproj_loadOfflineConfig", region)
        self.assertIn("offline.config_replayed", region)
        self.assertIn("amproj_installOfflineTakeover();", EXPORT)

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
