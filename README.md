# AMProjExport

为 Alight Motion iOS v27b 注入 `.amproj` 导出与本地导入能力。项目包含：

- `AMProjExport.dylib`：离线 Release 版。
- `AMProjExportCloud.dylib`：日常使用的云端统一版；导入/导出逻辑与 Release 相同，只异步上报核心诊断事件，不安装完整 Debug hook。
- `AMProjExportDebug.dylib`：带 Windows 调试后端遥测的 Debug 版；后端不可达不会阻塞导入或导出。
- `AMProjShareExtension.appex`：实验性“导入到 AM”分享扩展。
- `inject_dylib.py`：Windows IPA 注入、Info.plist 修补和产物验证工具。

Cloud IPA 直接连接注入时配置的 HTTPS 后端，不显示 Debug 状态条、不轮询远程控制命令、不上传项目文件，也不安装全局 UI、网络或解析诊断 hook。完整 Debug IPA 仍支持本地发现、模式控制和按需产物捕获。两者的后端都不参与文件解析、项目保存或导入控制；连接失败只会缺少日志，不会阻塞导入、导出。

## `.amproj` 格式

`.amproj` 是 ZIP32 容器。插件导出的规范包包含：

```text
project.amproj
├── <UUID>.xml       # 一个或多个场景 XML（Android 官方包可能包含多个）
├── manifest.txt     # 规范资源清单，可以为空
└── media/font/...   # XML 引用时必须随包提供的资源
```

插件自己导出的规范包有一个场景 XML 和一个 `manifest.txt`。导入时先验证 XML、manifest 和全部资源；若 Android 包缺少 iOS PackageImporter 所需的 `<media sig>`，只在私有工作副本中逐个 XML 按 manifest SHA-1 补齐并重建完整 ZIP。多个 manifest、损坏 CRC 或不安全路径仍会被拒绝。

完整格式见 `format_spec.md`。

## v40 XML/AMProj 本地双路由导入

Alight Motion 6.2.6 的 `TemplatesListVC` 使用 SwiftUI 承载内容，模板页的“上传”按钮
不能可靠地从 UIKit/accessibility 树中调用。更重要的是，已确认
`TemplatesListVC documentPicker:didPickDocumentsAtURLs:` 会进入 AM 的在线 XML 上传流程，
网络不可用时会一直等待。v40 不再调用该 delegate。

对于单独的 `.xml`，插件只验证 UTF-8、XML 语法和 `<scene>` 根节点，然后以**原始字节**
在私有工作目录封装为本地最小项目包：`<UUID>.xml` 加一个空的 `manifest.txt`。这个临时
`.amproj` 直接走已验证的本地 `PackageImporter`，不请求上传接口，不依赖加速器、VPN、
Wi-Fi 或调试后端。XML 路由不扫描素材，也不提示缺少媒体。

XML 成功必须具备 `storage status 4` 与原生成功证据。正常路径要求 completion 和本次标题的
精确模板 UI 增量；若 AM 对“原始 XML + 空 manifest”显示 `Missing Media` 但同时明确说明
包已导入，v40 仅在当前事务确认为单独 XML 时隐藏该提示，并把它作为原生
成功证据继续确认模板结果。Documents/Library 元数据、SQLite/WAL、HTTP storage 或诊断
JSON 的变化均不能单独或组合冒充 XML 导入成功；失败、超时或无法归因时保留缓存供重试。
完整 `.amproj` 不使用该豁免，任何 `Missing Media` 仍按真实导入失败处理。

完整 `.amproj` 路径不变：继续通过本地 `PackageImporter`，保留 ZIP、manifest、全部资源和
原有的项目/模板终态验证。若 AM 直接生成底部项目则保留项目结果；若能观察到 UIKit 身份或
SwiftUI 标题增量则确认模板结果。若 UI 暂时不可枚举，但完整包预检、storage status 4、原生
completion、持久化变化和临时包消费全部成功，则只报告导入已完成、目标位置待用户查看，
不再把尚未观察到的项目误报为模板，也不执行不稳定的 UI 自动晋升或删除。

### XML 文件

- QQ/文件 App 的“用其他应用打开 → Alight Motion”可以直接接收 `.xml`。
- XML 只包含项目结构和 Alight Motion 内置对象，因此只验证 UTF-8、XML 语法和 `<scene>` 根节点，不检查也不提示媒体缺失。
- XML 的原始字节会封装为 `<UUID>.xml + 空 manifest.txt`，再由本地 `PackageImporter` 离线导入；不调用 `TemplatesListVC` 的联网上传 delegate，最终出现在“您的模板”，不会自动创建底部“项目”。

### 完整 `.amproj` 文件

- `.amproj` 继续执行 ZIP32、CRC、manifest SHA-1、媒体 `sig`、XML 和全部图片/视频/音频/字体校验。
- iOS 原生 PackageImporter 若直接产生底部项目，插件会连续确认项目标题、项目列表变化、持久化变化及模板基线，然后显示项目成功。
- 若原生流程只产生模板，必须使用 UIKit 身份或 SwiftUI 标题增量正向确认，随后显示 `4/4 完整项目包已导入“您的模板”`。
- 页面暂时不可枚举时，只有“完整包预检 + status 4 + completion + 持久化变化 + 临时包已消费”五项原生终态证据同时成立，才显示中性结果 `4/4 项目包已完成导入，请在项目或“您的模板”中查看`；该结果不声明目标类型，也不强制切换页面。
- 模板终态不再自动打开、晋升或删除，避免误选同名模板、重复生成项目或因 SwiftUI UI 自动化失败而显示假错误。
- ZIP、manifest、媒体或原生导入真实失败时仍会停止并保留缓存；不会通过隐藏错误把不完整包冒充成功。
- 云端事件用 `import.package_template_verified` 记录正向模板证据；目标仍不可枚举但五项强终态成立时记录 `import.package_destination_unresolved`。

## v31 iOS 媒体映射与完整导入（v40 保留）

### v31 启动套餐页恢复

- 自签包的 StoreKit 商品身份可能与 App Store 商品不一致，套餐页会停在加载遮罩且左上角关闭按钮不可用；VPN/加速器不会改变这一结果。
- v31 在 `WillFinishLaunching` 阶段捕获 `NodeHostingControllerWithCustomStatusbarContent` 展示的 `PaywallLoadingScreenView` 及其 `CloudCardsTiersPaywallView` 子页，避免漏掉启动完成前的首次 presentation。
- 卡住 1.5 秒后，会在套餐页所在的现有前台窗口显示左上角 `×` 和底部“继续进入”。两者直接退出套餐页；不会新建窗口、隐藏主窗口或替换 root view controller。
- 普通系统弹窗、导入错误、导出分享面板和用户主动打开的其他购买页面不受影响。Debug 版记录 `presentation_seen → outer_presented → dismiss_requested → dismiss_verified → main_visible`。

### v31 Android 包的 iOS 媒体兼容

- 云端日志已确认失败包有 1 个 XML、51 个资源和有效 manifest，125 个 `amproj:` 引用全部存在；iOS 仍报 `Missing Media` 的差异是 XML 中缺少媒体 SHA-1 标识。
- Android 可直接从 manifest 映射资源；当前 iOS PackageImporter 还要求每个 `<media uri="amproj:...">` 的 `sig` 等于 manifest 中对应资源的 uppercase SHA-1。
- 已签名且完全匹配的包继续按原 ZIP 字节导入；缺签名时会在私有工作副本中逐个 XML 只补 `sig`，随后把全部 XML、图片、视频、音频、字体及其安全相对路径和重算后的 manifest 一起写入完整 ZIP。用户原始文件不被修改。
- 已有 `sig` 与资源 SHA-1 不一致、XML 引用缺文件或 manifest 哈希错误时会在进入 AM 前拒绝，避免生成只有 XML 的不完整项目；多 XML 无 manifest 仍拒绝。
- 项目列表验证不再依赖私有 `pCollectionView` getter，而是递归发现真实 `UICollectionView`/`UITableView`，并结合 XML 场景标题确认项目行。
- 原生导入前、status 4、completion 和验证重试期间记录 Documents/Library 元数据差异；只有底部“项目”中实际出现项目时才显示 `4/4`。

### v31 已导入字体导出

- AM XML 中的 `imported?name=字体.ttf`/`.otf` 是字体 URI，不是相对路径。v31 会安全解析 `name`，在 XML 目录、Application Support、Documents 和 Library 中按文件名递归查找。
- 字体查找大小写不敏感，命中后按真实文件计算 SHA-1、写入 `.amproj`，并将 XML URI 改写为 `amproj:<实际归档文件名>`。
- 找不到字体仍会明确停止导出，不会生成缺素材的假项目包。

### v25 稳定性修复（v31 保留）

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

因此，`2/4` 或 `3/4` 停住、闪退的旧 v20-v30 包不要继续重复安装；请使用 v40 构建。v40 会在私有工作副本中补齐完整 `.amproj` 所需的 iOS 媒体 SHA-1，再把 XML 与全部图片、音频、视频和字体作为一个完整项目包交给 AM；原生直接生成项目时保留项目结果，观察到模板增量时保留已验证的完整模板，目标暂不可见时只报告中性完成结果，不再强制自动转换。

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。系统 URL 回调收到 `.xml` 或 `.amproj` 后，插件会在 File Provider 授权仍有效的同一个回调内同步复制到主 App 的 `Library/Application Support/AMProjImports/<UUID>/`；只有主 App 自己的 `Documents/Inbox` 文件才转入后台串行处理。v40 对冷启动执行二阶段接管：先在原 AppDelegate 启动前尝试同步暂存到 `Launch-<UUID>`，仅当私有副本已经生成时才从转发参数中移除对应 URL；若暂存失败则原样转发，让 UIKit/File Provider 在初始化完成后继续投递，并在原 AppDelegate 返回后补一次暂存。后续 `openURL` 一旦成功接管，会清除旧的失败候选，避免激活时重复报错。校验、解包和原生导入仍延后到 App 激活；其他启动参数保持不变，原始字典不会被就地修改。App 激活后优先消费已暂存的冷启动候选，再扫描 `Documents/Inbox`；导入成功后会清理对应 `Launch-<UUID>` 目录，失败时保留副本供重试。

复制完成后的处理全部在本地执行：XML 仅做结构校验，并将原始字节封装为 `<UUID>.xml + 空 manifest.txt` 后交给本地 `PackageImporter`；不会调用 `TemplatesListVC` 的联网文档回调。XML 正常以 `storage status 4`、原生 completion 和精确模板 UI 增量确认成功；当且仅当 AM 自己显示 `Missing Media` 且明确写出 `has been imported anyway` 时，v40 会静默该非致命提示，并以这条原生确认作为 SwiftUI 列表不可枚举时的回退证据。数据库/WAL 或其他通用持久化文件变化不参与 XML 判定。`.amproj` 逐项解压验证 ZIP32、local header、CRC、XML、manifest SHA-1 和路径安全，再核对所有 `amproj:` 素材引用。缺少任一图片、音频、视频或字体时，会在进入原生 `PackageImporter` 前停止并保留缓存包；资源齐全但缺 iOS 媒体 `sig` 时，重建包含全部资源的兼容工作包。原生导入直接产生项目时确认项目落库；若只产生模板，则以模板 UI 增量确认。五项强终态成立但目标 UI 暂不可见时，以不声明项目或模板的中性终态完成，不再依赖模板卡片自动转换。

正常状态顺序为：`1/4 收到文件 -> 2/4 完整校验并保持原包 -> 3/4 正在解包并写入项目或模板 -> 原生回调完成后验证落库 -> 4/4`。项目行证据优先；模板成功必须有模板 UI 增量。完整包预检、status 4、原生 completion、临时包消费和持久化证据同时成立只能证明原生导入已完成，不能单独证明目标是模板。五项强终态成立后保留 3 次 UI 刷新探测，仍不可枚举时以中性终态立即完成当前事务并恢复下一包，不再等待 30 次探测或要求重启 App。

实验入口是 QQ 分享面板中的“导入到 AM”。扩展先把一个 `.amproj` 原子写入 App Group，再尝试用 `alightmotion://amproj-import` 唤起主 App。免费自签不一定能保留 App Group 或允许扩展自动唤起，因此实验包与稳定包分开生成。

整个导入链不依赖 Wi-Fi、5G、VPN、网络或调试后端。Cloud/Debug 后端不可达时只会缺少诊断日志。

## GitHub Actions 构建

推送源码后，Actions 会构建并验证：

```text
AMProjExport/AMProjExport.dylib
AMProjExport/AMProjExportCloud.dylib
AMProjExport/AMProjExportDebug.dylib
AMProjShareExtension/build/AMProjShareExtension.appex
AMProjShareExtension/build/AMProjShareExtension.entitlements
```

下载名为 `AMProjExport-v40-dylibs` 的 artifact。其中的 `build-metadata.json`
记录插件版本、commit、Actions run ID 以及每个二进制文件的 SHA-256，注入前可用它确认没有混入旧版本产物。

## 从干净 IPA 生成 v40

必须以未注入的 `AM_v1.ipa` 为输入，不要用旧测试包继续叠加。主 App Bundle ID 保持 `com.amayaka.meow`。

v40 原生导入桥只支持这份已核验的主程序：

```text
AM_v1.ipa SHA-256: B135D99E81E0F3F976CBF4C30BCC491B4B770BD9D0A6841D48083B7A7EA29413
Mach-O UUID:       4b22d43f-09fc-3bde-859b-78a5d573a503
```

先将 Actions artifact 解压到仓库根目录。不要使用仓库根目录残留的旧 `AMProjExport.dylib`。

稳定离线版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExport.dylib .\AM_v1_direct_v40.ipa `
  --expected-main-uuid $uuid
```

日常使用的云端统一版（稳定逻辑 + 核心云端日志）：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = "<与云端后端一致的 Bearer token>"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportCloud.dylib .\AM_v1_direct_v40_cloud.ipa `
  --server-url https://bug.meowcr.cn --no-discovery --debug-mode full `
  --debug-token $token --build-id v40-cloud-<commit> --expected-main-uuid $uuid
```

带本地后端完整诊断的 Debug 版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = python -c "import secrets; print(secrets.token_urlsafe(32))"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v40_debug.ipa `
  --debug-mode full --debug-token $token --expected-main-uuid $uuid
python .\debug_backend\server.py --token $token
```

需要完整 hook 和按需 artifact 的云端 HTTPS Debug 版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = "<与云端后端一致的 Bearer token>"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v40_cloud_debug.ipa `
  --server-url https://bug.meowcr.cn --no-discovery --debug-mode full `
  --debug-token $token --build-id v40-debug-<commit> --expected-main-uuid $uuid
```

实验分享版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = python -c "import secrets; print(secrets.token_urlsafe(32))"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v40_share_exp.ipa `
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
