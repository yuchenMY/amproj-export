# AMProjExport

为 Alight Motion iOS v27b 注入 `.amproj` 导出与本地导入能力。项目包含：

- `AMProjExport.dylib`：离线 Release 版。
- `AMProjExportCloud.dylib`：日常使用的云端统一版；导入/导出逻辑与 Release 相同，只异步上报核心诊断事件，不安装完整 Debug hook。
- `AMProjExportDebug.dylib`：带 Windows 调试后端遥测的 Debug 版；后端不可达不会阻塞导入或导出。
- `AMProjShareExtension.appex`：独立实验组件；稳定 Cloud IPA 不嵌入它，也不依赖 App Group。
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

## v44 XML/AMProj 本地双路由导入

Alight Motion 6.2.55 (862) 的底部“模板”是在线模板商城；本地“您的模板”和“上传 XML”
都属于底部“项目”宿主。导入状态机不得把在线 `TemplatesListVC` 当作本地模板列表，也不得
用它作为启动 `PackageImporter` 的前置条件。v44 的 QQ/文件导入只选择底部“项目”。

对于单独的 `.xml`，插件只验证 UTF-8、XML 语法和 `<scene>` 根节点，然后以**原始字节**
在私有工作目录封装为本地最小项目包：`<UUID>.xml` 加一个空的 `manifest.txt`。这个临时
`.amproj` 直接走已验证的本地 `PackageImporter`，不请求上传接口，不依赖加速器、VPN、
Wi-Fi 或调试后端。XML 路由不扫描素材，也不提示缺少媒体。

AM 内“上传 XML”打开的系统文件选择器也接入同一条离线路由。插件只接管恰好一个
`.xml` 的选择结果，并把原选择器按取消状态正常收口，避免 AM 继续启动在线上传和账号
校验；取消、非 XML、多个文件以及其他 delegate 回调仍原样交回 Alight Motion。插件自己
用于 QQ/文件导入兜底的选择器不会被二次接管。

XML 成功必须同时具备完整包校验、`storage status 4` 返回、原生 completion、临时包已消费，
并确认本事务后的 Documents/Library 持久化变化。若 AM 对“原始 XML + 空 manifest”显示
`Missing Media` 但同时明确说明包已导入，v44 仅在当前事务确认为单独 XML 时隐藏该提示，
并把它作为持久化结果暂不可枚举时的附加原生证据。单独的数据库时间戳、HTTP storage 或
诊断 JSON 不能冒充成功；失败、超时或无法归因时保留缓存供重试。
完整 `.amproj` 不使用该豁免，任何 `Missing Media` 仍按真实导入失败处理。

完整 `.amproj` 继续通过本地 `PackageImporter`，保留 ZIP、manifest 和全部资源。若 AM 直接
生成底部项目，则用项目标题/列表增量与持久化证据确认；否则在完整包预检、status 4、原生
completion、持久化变化和临时包消费全部成立时报告中性完成，请用户到“项目”或“您的模板”
查看。整个活跃路径不访问底部在线模板商城，也不执行 UI 自动晋升或删除。

### XML 文件

- QQ/文件 App 的“用其他应用打开 → Alight Motion”可以直接接收 `.xml`。
- AM 内“上传 XML”选择一个 `.xml` 后直接进入同一条本地导入链，不访问上传服务，也不需要加速器或账号校验。
- XML 只包含项目结构和 Alight Motion 内置对象，因此只验证 UTF-8、XML 语法和 `<scene>` 根节点，不检查也不提示媒体缺失。
- XML 的原始字节会封装为 `<UUID>.xml + 空 manifest.txt`，再由底部“项目”宿主中的本地 `PackageImporter` 离线导入；不访问底部在线模板商城。

### 完整 `.amproj` 文件

- `.amproj` 继续执行 ZIP32、CRC、manifest SHA-1、媒体 `sig`、XML 和全部图片/视频/音频/字体校验。
- iOS 原生 PackageImporter 若直接产生底部项目，插件会确认项目标题、项目列表变化和持久化变化后显示项目成功。
- 页面暂时不可枚举时，只有“完整包预检 + status 4 + completion + 持久化变化 + 临时包已消费”五项原生终态证据同时成立，才显示中性结果 `4/4 项目包已完成导入，请在项目或“您的模板”中查看`；该结果不声明目标类型，也不强制切换页面。
- 模板终态不再自动打开、晋升或删除，避免误选同名模板、重复生成项目或因 SwiftUI UI 自动化失败而显示假错误。
- ZIP、manifest、媒体或原生导入真实失败时仍会停止并保留缓存；不会通过隐藏错误把不完整包冒充成功。
- 目标不可枚举但五项强终态成立时记录 `import.package_destination_unresolved`。

## v31 iOS 媒体映射与完整导入（v44 保留）

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

本轮 ABI 修复还原了 `6.2.55 (862)` 底包的真实本地导入链：旧入口
`0x1002647c0` 的参数是 Swift Firebase `StorageReference`，不能用 Objective-C 对象伪造，
否则会在 `2/4` 后进入 Swift value-witness 调用并直接崩溃。v44 不再调用这个下载入口；
它先把已验证项目包复制到私有临时目录，再把真实的 Swift `Foundation.URL`、
`PackageImporter`、项目页控制器和 `AMProgressAlert` 传给本地 continuation
`0x10026596c`，由底包自己的 `0x100308bc4` 解析并写入项目。进度控制器从主包
`AMProgressAlert.storyboardc` 创建并强持有到原生 completion。兼容状态 `2/4`、`3/4`
和失败状态仍由桥接层按原事务顺序报告，但不再伪装或调用 Firebase 下载任务。

因此，`2/4` 或 `3/4` 停住、闪退的旧 v20-v30 包不要继续重复安装；请使用 v44 构建。v44 会在私有工作副本中补齐完整 `.amproj` 所需的 iOS 媒体 SHA-1，再把 XML 与全部图片、音频、视频和字体作为一个完整项目包交给 AM；原生直接生成项目时保留项目结果，观察到模板增量时保留已验证的完整模板，目标暂不可见时只报告中性完成结果，不再强制自动转换。

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。系统 URL 回调收到 `.xml` 或 `.amproj` 后，插件会在 File Provider 授权仍有效的同一个回调内同步复制到主 App 的 `Library/Application Support/AMProjImports/<UUID>/`；只有主 App 自己的 `Documents/Inbox` 文件才转入后台串行处理。v44 对非 Scene 冷启动执行三窗口接管：构造器先给真实 AppDelegate 安装公开的 `application:willFinishLaunchingWithOptions:` 回调，在 `didFinish` 之前同步暂存到 `Launch-<UUID>`；`didFinish` 保留第二次暂存机会；App 激活后只处理仍未暂存的候选。两个启动回调转发前都会从副本中移除已识别的项目 URL，避免 AM 原生 XML 页面抢先接管，原始字典和其他启动参数不变。冷启动复制失败后的显式重试会先释放本事务的临时去重 tombstone，真实的第二次失败不再被误报为已接受，并会提供文件选择器兜底。校验、解包和原生导入仍延后到 App 激活；导入成功后会清理对应 `Launch-<UUID>` 目录，失败时保留副本供重试。

复制完成后的处理全部在本地执行：XML 仅做结构校验，并将原始字节封装为 `<UUID>.xml + 空 manifest.txt` 后交给本地 `PackageImporter`；不会访问底部在线模板商城。XML 以 `storage status 4`、原生 completion、临时包消费和持久化变化确认成功；当且仅当 AM 自己显示 `Missing Media` 且明确写出 `has been imported anyway` 时，v44 才静默该非致命提示。`.amproj` 逐项解压验证 ZIP32、local header、CRC、XML、manifest SHA-1 和路径安全，再核对所有 `amproj:` 素材引用。缺少任一图片、音频、视频或字体时，会在进入原生 `PackageImporter` 前停止并保留缓存包；资源齐全但缺 iOS 媒体 `sig` 时，重建包含全部资源的兼容工作包。原生导入直接产生项目时确认项目落库；五项强终态成立但目标 UI 暂不可见时，以不声明项目或模板的中性终态完成。

正常状态顺序为：`1/4 收到文件 -> 2/4 完整校验并保持原包 -> 3/4 正在解包并写入项目或模板 -> 原生回调完成后验证落库 -> 4/4`。项目行证据优先；完整包预检、status 4、原生 completion、临时包消费和持久化证据只能证明原生导入已完成，不能单独声明目标是模板。目标暂不可枚举时以中性终态完成当前事务并恢复下一包。

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。本轮稳定包只使用主 App 的文档 URL/文件选择器链路，不嵌入 Share Extension，不读取 App Group。Share Extension 仍保留为独立实验组件，不属于本轮安装包。唯一兼容基线是 Alight Motion `6.2.55 (862)`；注入时保持 `CFBundleVersion=862`，并强制 `LSSupportsOpeningDocumentsInPlace=false`、`UISupportsDocumentBrowser=false`，让系统先 copy-in 到主 App，再由插件同步复制到私有缓存。

整个导入链不依赖 Wi-Fi、5G、VPN、网络或调试后端。Cloud/Debug 后端不可达时只会缺少诊断日志。

`6.2.55 (862)` 稳定包优先在 `_TtC12AlightMotion7ShareNC` 的 `onTapExport:` 精确 hook 中读取 `ShareVC.selectedExportOptID`；仅值为 `7`（项目包）时启动植入的 `.amproj` 直出链。若该 Swift 状态未暴露，代码只在 AM 即将呈现精确的 `ShareProjectPackageVC` 时进行第二道接管，避免回落到会闪退的原生项目包流程。其他视频、图片、GIF、WebP 与 XML 导出仍交回 Alight Motion。系统分享表只收到生成的 `.amproj` 文件 URL；生成失败只提供“重试”或“取消”。

## GitHub Actions 构建

推送源码后，Actions 会构建并验证：

```text
AMProjExport/AMProjExport.dylib
AMProjExport/AMProjExportCloud.dylib
AMProjExport/AMProjExportDebug.dylib
AMProjExport/AMMeowLoader.dylib
AMProjExport/AMHomeUI.dylib
```

下载名为 `AMProjExport-v44-dylibs` 的 artifact。其中的 `build-metadata.json`
记录插件版本、commit、Actions run ID 以及每个二进制文件的 SHA-256，注入前可用它确认没有混入旧版本产物。

主页模块单独编译为 `AMHomeUI.dylib`，由它自己的 constructor 安装到
Alight Motion 的 `HomeVC`/`FeedVC`。最终 IPA 必须同时包含 Cloud 和
`Frameworks/AMHomeUI.dylib`，主程序只保留一条 `@executable_path/Frameworks/AMHomeUI.dylib`
强加载命令。Cloud 不包含主页源码、URL 或 `_AMHomeUIInstall`，LCSign 必须递归签名两个 dylib。

在已有全分类图和编辑器按钮的 IPA 上生成待签包：

```powershell
python .\package_editor_button_ipa.py `
  <source.ipa> <output.ipa> `
  .\AMProjExport\AMProjExportCloud.dylib `
  .\AMProjExport\AMHomeUI.dylib `
  <add_layer_button.png> <category_image_directory>
```

打包器会替换 Cloud、写入独立 `AMHomeUI.dylib`、注入主程序唯一 HomeUI 加载，并替换指定按钮
和 12 张分类图。它会拒绝 Cloud 中的 `_AMHomeUIInstall`/主页 URL，且校验 HomeUI 的 ABI、安装名
和导出符号，防止旧的合并模式再次进入包体。

需要同时修复官方原版效果时，必须使用完整交付入口，而不要单独运行 XML 覆盖工具：

```powershell
python .\build_862_official_effects_package.py `
  <source.ipa> <output.ipa> `
  D:\am\BuiltinEffects `
  .\AMProjExport\AMProjExportCloud.dylib `
  --home-ui .\AMProjExport\AMHomeUI.dylib
```

该入口仅覆盖基线 IPA 中已有、ID 与路径可核对的 `com.alightcreative...` 原版效果，
保留额外插件；随后替换 Cloud、保留独立 HomeUI 与旧签名记录清理。
它会阻止旧 `void main()` shader 覆盖 AFX2 `shadeFragment()` 修复版，并在最终 IPA 中复核
所有 `BuiltinEffects` 资源没有被后续步骤改写。

## 从自有 6.2.55 (862) 底包生成唯一 Direct Cloud 包

唯一输入是自有底包派生的 `am_v74_ownbase_LoadControl_LCSign-LC.ipa`。构建器保留主程序、
全部资源、AmEnhancer、CydiaSubstrate、`.amproj/XML` 注册以及现有导入/自定义 `.amproj`
导出实现；不使用其他包的主程序、Info 或业务框架。

实机结果证明通用 LoadControl 没有注册 `AMProjExportCloud.dylib`：URL 会跳转，但插件构造器
没有运行，因此导入不显示 `1/4`，模板不落库，导出等待链卡死。当前构建只在主程序已有的
80 字节 dylib command 槽内，把强加载路径从 LoadControl 原位改回
`@executable_path/Frameworks/AMProjExportCloud.dylib`。command 数量、大小和所有段偏移
不变；LoadControl 文件从输出移除。为兼容 LCSign，主程序保留原有非空签名区供签名器覆盖，
Cloud 保持无 `LC_CODE_SIGNATURE` 命令，让 LCSign 在递归签名时自动添加。锁定输入如下：

```text
User base v74 IPA SHA-256:                  9913C7E7CD51DFB2CFC70E3715B57156E4D4A182DF1B844CA08BADCB663F99EC
Alight Motion:                              6.2.55 (862)
Output display name:                        猫鹤AM
Output bundle identifier:                   com.ayakameow.am
Main Mach-O UUID:                           01b73017-1a6e-3b17-8f59-c27462dea563
Input main executable SHA-256:              F500E3A92312D0373E7F522705C3FDE96B0863BC9B7E5D9CD023E77AF436164D
Resign-ready direct main SHA-256:            37054D3ED49DEBF44D6534DAA6B266888A41AA5068A4FFD8FA884EF5EC4999D4
AmEnhancer.dylib SHA-256:                   DA014F018D5B9AB59B7D810E93AC9353088D81336C7CD2B2D012622A90CEB12C
CydiaSubstrate SHA-256:                     5D1E2B39F4A0F23FEB6E2F1E82408943B307EA11B4073B33A2B072EC4F69E8BD
Input stable Cloud SHA-256:                 C35E6ECBCA2AEED4BA01E1AFA9FA130347C98F0249DC1C6C5C6C91EF64939718
Resign-ready Cloud SHA-256:                 8A7C5109D8F062EAB91847DBBC06E585850E30C50EB29A771799B863A98F8C2E
```

生成唯一 LCSign 待签包：

```powershell
py .\build_862_direct_package.py `
  D:\Download\am_v74_ownbase_LoadControl_LCSign-LC.ipa `
  C:\Users\XOS\Downloads\am_v77_ownbase_directCloud_LCSign.ipa
```

输出移除 LoadControl、旧 profile 和所有 CodeResources。该文件不能直接安装：LCSign 必须递归
签名所有 Mach-O，最后签主 App。签名时不要替换图标，签名后不得修改 `Info.plist`、名称或
Bundle ID。只测试
`am_v77_ownbase_directCloud_LCSign.ipa` 这一份。

## 本地测试

```powershell
python -m unittest discover -s tests -v
python -m unittest debug_backend.test_server -v
```

## Signed handoff gate

`am_v77_ownbase_directCloud_LCSign.ipa` is the only current staging package.
It is not installable until LCSign recursively signs the main executable,
`AMProjExportCloud.dylib`, AmEnhancer, CydiaSubstrate, and every nested framework
with one identity. The signer must preserve `Info.plist`, app name, icons,
Bundle ID, and all non-signature bytes. A package that leaves Cloud unsigned is
invalid.

## Standalone Home UI runtime

`AMHomeUI.dylib` is an independent arm64 `MH_DYLIB`. `AMProjExportCloud.dylib`
must not contain the Home UI source, `_AMHomeUIInstall`, or the home URL. The
IPA must contain both files under `Payload/AlightMotion.app/Frameworks/`, and
the main executable must have exactly one strong load:
`@executable_path/Frameworks/AMHomeUI.dylib`.

Build the 6.2.55 direct handoff with both binaries:

```powershell
py .\build_862_direct_package.py <source.ipa> <output.ipa> `
  --cloud .\AMProjExport\AMProjExportCloud.dylib `
  --home-ui .\AMProjExport\AMHomeUI.dylib
```

For official effect repair, pass the same `--home-ui` option to
`build_862_official_effects_package.py`. For the 6.2.58 migration entry point,
pass `--home-ui` to `build_865_migration_package.py`. LCSign must recursively
sign the main executable, Cloud, HomeUI, and every nested Mach-O in one pass.
