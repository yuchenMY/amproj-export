# AMProjExport

为 Alight Motion iOS v27b 注入 `.amproj` 导出与本地导入能力。项目包含：

- `AMProjExport.dylib`：离线 Release 版。
- `AMProjExportDebug.dylib`：带 Windows 调试后端遥测的 Debug 版；后端不可达不会阻塞导入或导出。
- `AMProjShareExtension.appex`：实验性“导入到 AM”分享扩展。
- `inject_dylib.py`：Windows IPA 注入、Info.plist 修补和产物验证工具。

Debug IPA 会优先连接注入时记录的 Windows 地址；地址变化或连接失败时，会在后台通过带 token 认证的 UDP 单播自动发现同一 Wi-Fi 内的后端。默认 TCP/UDP 均使用端口 `8765`，Windows 防火墙需要同时允许这两个协议。后端只接收诊断事件和用户明确请求的调试产物，不参与文件解析、项目保存或导入控制；发现失败只会缺少调试日志，不会阻塞导入、导出。

## `.amproj` 格式

`.amproj` 是 ZIP32 容器。插件导出的规范包包含：

```text
project.amproj
├── <UUID>.xml       # 一个或多个场景 XML（Android 官方包可能包含多个）
├── manifest.txt     # 规范资源清单，可以为空
└── media/font/...   # XML 引用时必须随包提供的资源
```

插件自己导出的规范包有一个场景 XML 和一个 `manifest.txt`。导入时同时接受 Android 官方的多个场景 XML，只要有一个根 `manifest.txt` 就保留原 ZIP 交给 AM；没有 manifest 的单 XML 旧包才会重建为规范包。多个 manifest、损坏 CRC 或不安全路径仍会被拒绝。

完整格式见 `format_spec.md`。

## v29 离线导入

### v29 启动套餐页恢复

- 自签包的 StoreKit 商品身份可能与 App Store 商品不一致，套餐页会停在加载遮罩且左上角关闭按钮不可用；VPN/加速器不会改变这一结果。
- v29 在 `WillFinishLaunching` 阶段捕获 `NodeHostingControllerWithCustomStatusbarContent` 展示的 `PaywallLoadingScreenView` 及其 `CloudCardsTiersPaywallView` 子页，避免漏掉启动完成前的首次 presentation。
- 卡住 1.5 秒后，会在套餐页所在的现有前台窗口显示左上角 `×` 和底部“继续进入”。两者直接退出套餐页；不会新建窗口、隐藏主窗口或替换 root view controller。
- 普通系统弹窗、导入错误、导出分享面板和用户主动打开的其他购买页面不受影响。Debug 版记录 `presentation_seen → outer_presented → dismiss_requested → dismiss_verified → main_visible`。

### v29 媒体签名修复

- Android 官方项目包可能在 `manifest.txt` 中提供媒体 SHA-1，却省略 XML `<media>` 的 `sig` 属性。v29 会按资源字节计算并补写大写 SHA-1，避免 iOS 原生 importer 报 `Missing Media`。
- 已有非空 `sig` 必须与 `manifest.txt` 一致；哈希不匹配、缺少被 XML 引用的媒体或 ZIP 校验失败时会在原生导入前拒绝，不生成假项目。
- 单 XML 的 manifest 包会在需要时重新生成 ZIP，仅改写 XML 签名并保留 `amproj:` URI、所有 XML 和媒体字节；已有完整签名的多 XML 包保持原 ZIP 不变。

### v25 稳定性修复（v29 保留）

- 修复 v24 在 `storage_status_4_returned` 后的确定性闪退：AM 会无条件关闭原生 `AMProgressAlert`，v24 传入 `nil` 后命中主程序的主动崩溃指令；v25 从 App 自带 storyboard 创建真实控制器并强持有到原生 completion。
- 保留 v24 的观察器句柄修复：`observeStatus:handler:` 返回 `NSString` 对象句柄，不再把整数 `1/2/3` 当对象地址 retain。
- 原生 completion 不再直接重载项目列表；列表刷新和“项目行已出现”验证统一由导入事务层执行。
- native/storage 最后阶段会写入本地 breadcrumb，后端离线时重启 App 也能看到精确中断点。
- 原生导入开始前强制切换到底部“项目”页；项目页尚未完成挂载时会等待，不再把“主页”控制器当作导入上下文。
- Debug 版默认不安装全局 `NSXMLParser` 诊断 swizzle，避免它干扰 Alight Motion 的 Swift 项目解析。
- XML 引用的媒体缺失时立即拒绝导入并保留缓存包，避免 AM 原生 importer 生成不完整的假项目。

本轮 ABI 修复还原了干净 `AM_v1` 的真实调用约定：原生入口的显式 `x2` 是
`StorageReference`（入口会对它调用 `writeToFile:`），显式 `x3` 是
`AMProgressAlert`，隐藏 Swift `x20` 是弱持有的项目页控制器。v25 从主包
`AMProgressAlert.storyboardc` 创建真实的进度控制器并在事务期间强持有；它不主动展示，
但必须作为非空 `x3` 传入，因为 AM 在 status 4 后会无条件向它发送 dismiss。
复制任务完成时同时发出 Firebase 的进度终态 `2` 和成功终态 `4`，失败仍发出 `5`。

因此，`2/4` 或 `3/4` 停住、闪退的旧 v20-v25 包不要继续重复安装；请使用 v29 构建。v29 保留 Android 官方多 XML + `manifest.txt` 包的完整资源校验，并为缺失 XML `sig` 的单 XML 包自动补齐签名；请确保 ZIP 内包含 XML 引用的全部图片、音频、视频和字体。

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。系统 URL 回调收到 `.amproj` 后，插件会在 File Provider 授权仍有效的同一个回调内同步复制到主 App 的 `Library/Application Support/AMProjImports/<UUID>/`；只有主 App 自己的 `Documents/Inbox` 文件才转入后台串行处理。冷启动的 `didFinishLaunching` 先记录候选 URL，再复制一份 launch options，仅从转发给原 AppDelegate 的副本中移除 `.amproj` URL 或对应的 user activity，其他启动参数保持不变；原始字典不会被就地修改。这样可避免 AM 的原生 URL 路径同时处理同一个包。App 激活后先扫描 `Documents/Inbox`，再对候选 URL 做一次不弹错误框的兜底读取。

复制完成后的处理全部在本地执行：插件逐项解压验证 ZIP32、local header、CRC、XML 和路径安全。带 manifest 的官方包保持完整 ZIP（包括所有 XML、媒体和字体）；缺 manifest 的单 XML 旧包才重算 manifest。随后会核对所有 `amproj:` 素材引用：缺少任一被引用的图片、音频、视频或字体时，会在进入原生 `PackageImporter` 前停止导入、显示缺失名称并保留缓存包供重试；完整包才会进入原生桥。代码不再查找 `TemplatesListVC`，也不会调用模板页的 XML 文档选择器回调。

正常状态顺序为：`1/4 收到文件 -> 2/4 完整校验并规范化 -> 3/4 正在解包并写入项目 -> 原生回调完成后验证项目列表 -> 4/4`。只有在底部“项目”页实际找到新项目行后才显示 `4/4`；原生回调、确认框或文件复制完成本身都不算成功。

实验入口是 QQ 分享面板中的“导入到 AM”。扩展先把一个 `.amproj` 原子写入 App Group，再尝试用 `alightmotion://amproj-import` 唤起主 App。免费自签不一定能保留 App Group 或允许扩展自动唤起，因此实验包与稳定包分开生成。

整个导入链不依赖 Wi-Fi、5G、VPN、网络或调试后端。Debug 后端不可达时只会缺少诊断日志。

## GitHub Actions 构建

推送源码后，Actions 会构建并验证：

```text
AMProjExport/AMProjExport.dylib
AMProjExport/AMProjExportDebug.dylib
AMProjShareExtension/build/AMProjShareExtension.appex
AMProjShareExtension/build/AMProjShareExtension.entitlements
```

下载名为 `AMProjExport-v29-dylibs` 的 artifact。其中的 `build-metadata.json`
记录插件版本、commit、Actions run ID 以及每个二进制文件的 SHA-256，注入前可用它确认没有混入旧版本产物。

## 从干净 IPA 生成 v29

必须以未注入的 `AM_v1.ipa` 为输入，不要用旧测试包继续叠加。主 App Bundle ID 保持 `com.amayaka.meow`。

v29 原生导入桥只支持这份已核验的主程序：

```text
AM_v1.ipa SHA-256: B135D99E81E0F3F976CBF4C30BCC491B4B770BD9D0A6841D48083B7A7EA29413
Mach-O UUID:       4b22d43f-09fc-3bde-859b-78a5d573a503
```

先将 Actions artifact 解压到仓库根目录。不要使用仓库根目录残留的旧 `AMProjExport.dylib`。

稳定离线版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExport.dylib .\AM_v1_direct_v29.ipa `
  --expected-main-uuid $uuid
```

带本地后端诊断的 Debug 版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = python -c "import secrets; print(secrets.token_urlsafe(32))"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v29_debug.ipa `
  --debug-mode full --debug-token $token --expected-main-uuid $uuid
python .\debug_backend\server.py --token $token
```

云端 HTTPS Debug 版不使用局域网发现，也不需要 iOS 本地网络权限：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = "<与云端后端一致的 Bearer token>"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v29_cloud_debug.ipa `
  --server-url https://bug.meowcr.cn --no-discovery --debug-mode full `
  --debug-token $token --build-id v29-cloud-<commit> --expected-main-uuid $uuid
```

实验分享版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = python -c "import secrets; print(secrets.token_urlsafe(32))"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v29_share_exp.ipa `
  --debug-mode full --debug-token $token --expected-main-uuid $uuid `
  --share-extension .\AMProjShareExtension\build\AMProjShareExtension.appex `
  --app-group-id group.com.amayaka.meow.amprojshare
```

注入器会验证主程序 UUID、arm64、Mach-O load command、ZIP CRC、UTI/copy-in 配置以及实验扩展的 Bundle ID、extension point 和 App Group 模板。输出 IPA 仍需使用 Sideloadly 签名安装。

## 本地测试

```powershell
python -m unittest discover -s tests -v
python -m unittest debug_backend.test_server -v
```
