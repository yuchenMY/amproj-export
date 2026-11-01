"""r92：导出完成页 / 云备份选择器 / 插件下载提示 三处体验缺陷的源码回归。

背景（用户 2026-11-01 真机反馈）：
1. 覆盖更新后插件被重新下载，且全程无任何提示，用户不知道要重启才有插件。
2. 云端备份选择器点工程后窗口消失、之后毫无反应。
3. 导出完成页预览放的是相册里最新那条视频（用户的录屏），不是本次导出的成片。
"""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORT = (ROOT / "AMProjExport" / "AMProjExport.m").read_text(encoding="utf-8")
CLOUD = (ROOT / "AMProjExport" / "AMCloudSync.m").read_text(encoding="utf-8")
PLUGINS = (ROOT / "AMProjExport" / "AMCloudPlugins.m").read_text(encoding="utf-8")


def _slice(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class ReplicaVideoSourceR92Tests(unittest.TestCase):
    """导出页必须播"这一次导出"的视频，拿不到就不播，绝不拿相册最新视频顶。"""

    def test_album_lookup_is_bounded_by_creation_time(self):
        region = _slice(
            EXPORT,
            "static NSURL *AMProjReplicaRecentAlbumVideoURL",
            "static NSURL *AMProjReplicaVideoURLFromController",
        )
        self.assertIn("options.predicate", region)
        self.assertIn("creationDate >= %@", region)
        self.assertIn("maxAge", region)

    def test_no_unbounded_latest_album_video_fallback(self):
        start = EXPORT.rindex(
            "static NSURL *AMProjReplicaVideoURLFromController(UIViewController *controller) {"
        )
        share = EXPORT.index(
            "static UIViewController *AMProjReplicaShareVideo", start
        )
        region = EXPORT[start:share]
        self.assertIn(
            "AMProjReplicaRecentAlbumVideoURL(AMProjReplicaVideoMaxAge)", region
        )
        self.assertNotIn("[PHAsset fetchAssetsWithMediaType", region)

    def test_container_scan_only_accepts_fresh_video_files(self):
        region = _slice(
            EXPORT,
            "static NSURL *AMProjReplicaRecentContainerVideoURL",
            "static NSURL *AMProjReplicaRecentAlbumVideoURL",
        )
        self.assertIn("NSURLContentModificationDateKey", region)
        self.assertIn("NSOrderedAscending", region)
        self.assertIn("AMProjReplicaURLIsVideoFile", region)

    def test_missing_source_degrades_to_placeholder(self):
        self.assertIn("已保存到设备\\n可在相册中查看", EXPORT)
        self.assertIn(
            "if (!self.videoURL) {\n        self.playButton.hidden = YES;", EXPORT
        )
        self.assertIn("视频已保存到相册，请在相册中分享", EXPORT)

    def test_resolution_result_is_logged_with_its_source(self):
        self.assertIn("share.replica_video_source", EXPORT)
        self.assertIn('@"source": source', EXPORT)


class ReplicaLayoutR92Tests(unittest.TestCase):
    """P4 参考版式：固定 16:9 信箱式预览、标题在框下、矮胶片条。"""

    def test_preview_is_fixed_16_by_9(self):
        self.assertIn("multiplier:9.0 / 16.0", EXPORT)
        self.assertNotIn("previewHeightConstraint", EXPORT)

    def test_filmstrip_is_a_short_bordered_strip(self):
        self.assertIn("constraintEqualToConstant:40]", EXPORT)
        self.assertIn("self.stripContainer.layer.borderWidth = 1.0;", EXPORT)


class CloudProjectPickerR92Tests(unittest.TestCase):
    """点选工程后要有反馈：回调要等选择器真正消失之后再发。"""

    def test_pick_callback_fires_after_dismissal(self):
        region = _slice(
            EXPORT,
            "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath",
            "@end",
        )
        dismiss = region.index("dismissViewControllerAnimated:YES completion:")
        callback = region.index("callback(title, NO);")
        self.assertLess(
            dismiss,
            callback,
            "onPick 必须在 dismiss 的 completion 里调用，否则上一个 modal "
            "还在消失动画中，媒体方式弹窗会被系统静默丢弃",
        )

    def test_media_choice_goes_through_the_retrying_presenter(self):
        self.assertIn(
            "amproj_presentCloudMediaChoice(mediaChoice, activePresenter);", EXPORT
        )
        helper = _slice(
            EXPORT,
            "static void amproj_presentCloudMediaChoiceAttempt",
            "static void amproj_presentCloudMediaChoice(",
        )
        self.assertIn("host.presentedViewController", helper)
        self.assertIn("attempt < 3", helper)
        self.assertIn("cloud_choice_present_busy", helper)


class PluginDownloadNoticeR92Tests(unittest.TestCase):
    """插件下载必须可见：窗口没出来要重试，进度到了要补弹，重启要明说。"""

    def test_notice_retries_until_a_window_exists(self):
        region = _slice(
            CLOUD,
            "- (void)showPluginDownloadNoticeIfPossible {",
            "- (void)hidePluginDownloadNotice",
        )
        self.assertIn("pluginDownloadNoticeRetryCount < 120", region)
        self.assertIn("showPluginDownloadNoticeIfPossible];", region)

    def test_progress_reschedules_a_missing_overlay(self):
        region = _slice(
            CLOUD,
            "- (void)updatePluginDownloadNoticeCompletedBytes:",
            "- (void)finishPluginDownloadNoticeInstalled:",
        )
        self.assertIn("if (!overlay) {", region)
        self.assertIn("[self showPluginDownloadNoticeIfPossible];", region)

    def test_restart_requirement_is_spelled_out(self):
        region = _slice(
            CLOUD,
            "- (void)beginPluginDownloadNoticeForRelease:",
            "- (void)updatePluginDownloadNoticeCompletedBytes:",
        )
        self.assertIn("重新打开 App 后生效", region)


class PluginRetentionR92Tests(unittest.TestCase):
    """覆盖更新换 IPA 后只作废 catalog，items/ 必须留着，避免全量重下。"""

    def test_catalog_only_invalidation_api_exists(self):
        self.assertIn(
            "AMCloudPluginsInvalidateCatalogPreservingItemsIf", PLUGINS
        )
        region = _slice(
            PLUGINS,
            "BOOL AMCloudPluginsInvalidateCatalogPreservingItemsIf",
            "BOOL AMCloudPluginsRemoveAllIf",
        )
        self.assertIn("AMCloudPluginsInvalidateStaleCatalog", region)
        self.assertNotIn("removeItemAtURL:rootURL", region)

    def test_reactivation_fallback_keeps_items(self):
        self.assertIn(
            "AMCloudPluginsInvalidateCatalogPreservingItemsIf", CLOUD
        )
        sync_start = CLOUD.rindex("- (void)syncPluginCatalog:")
        region = CLOUD[CLOUD.rindex(
            "- (void)activatePersistedCatalogAfterSync:", 0, sync_start
        ):sync_start]
        self.assertIn("AMCloudPluginsInvalidateCatalogPreservingItemsIf", region)
        self.assertNotIn("AMCloudPluginsRemoveAllIf", region)


if __name__ == "__main__":
    unittest.main()
