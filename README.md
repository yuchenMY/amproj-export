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
└── media/font/...   # XML 引用的可选资源
```

插件自己导出的规范包有一个场景 XML 和一个 `manifest.txt`。导入时同时接受 Android 官方的多个场景 XML，只要有一个根 `manifest.txt` 就保留原 ZIP 交给 AM；没有 manifest 的单 XML 旧包才会重建为规范包。多个 manifest、损坏 CRC 或不安全路径仍会被拒绝。

完整格式见 `format_spec.md`。

## v21 离线导入

### v21 稳定性修复

- 原生导入开始前强制切换到底部“项目”页；项目页尚未完成挂载时会等待，不再把“主页”控制器当作导入上下文。
- Debug 版默认不安装全局 `NSXMLParser` 诊断 swizzle，避免它干扰 Alight Motion 的 Swift 项目解析。
- XML 引用的媒体只要有一项不在 `.amproj` ZIP 中，就在 `2/4` 阶段停止并显示缺失数量，不再把不完整包交给原生 `PackageImporter`。

因此，`3/4` 后仍闪退的旧 v20 包不要继续重复安装；请使用 v21 构建。v21 同时兼容 Android 官方的多 XML + `manifest.txt` 项目包，并将缺失媒体交给 AM 原生警告流程；仍建议确保 ZIP 内包含 XML 引用的全部图片、音频、视频和字体。

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。系统 URL 回调收到 `.amproj` 后，插件会在 File Provider 授权仍有效的同一个回调内同步复制到主 App 的 `Library/Application Support/AMProjImports/<UUID>/`；只有主 App 自己的 `Documents/Inbox` 文件才转入后台串行处理。冷启动的 `didFinishLaunching` 只记录候选 URL，并把原始 launch options 完整交给 AM，避免在系统授权尚未激活时制造 `EPERM` 伪失败。App 激活后先扫描 `Documents/Inbox`，再对候选 URL 做一次不弹错误框的兜底读取。

复制完成后的处理全部在本地执行：插件逐项解压验证 ZIP32、local header、CRC、XML 和路径安全。带 manifest 的官方包保持完整 ZIP（包括所有 XML、媒体和字体）交给本地 `PackageImporter`；缺 manifest 的单 XML 旧包才重算 manifest。缺少的 `amproj:` 素材引用会保留，交给 AM 原生的缺素材处理；代码不再查找 `TemplatesListVC`，也不会调用模板页的 XML 文档选择器回调。

正常状态顺序为：`1/4 收到文件 -> 2/4 完整校验并规范化 -> 3/4 正在解包并写入项目 -> 4/4 已导入到底部“项目”`。只有适配器确认项目和包内资源已经持久化后才显示 `4/4`，原生确认框出现本身不再算成功。

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

## 从干净 IPA 生成 v21

必须以未注入的 `AM_v1.ipa` 为输入，不要用旧测试包继续叠加。主 App Bundle ID 保持 `com.amayaka.meow`。

v21 原生导入桥只支持这份已核验的主程序：

```text
AM_v1.ipa SHA-256: B135D99E81E0F3F976CBF4C30BCC491B4B770BD9D0A6841D48083B7A7EA29413
Mach-O UUID:       4b22d43f-09fc-3bde-859b-78a5d573a503
```

先将 Actions artifact 解压到仓库根目录。不要使用仓库根目录残留的旧 `AMProjExport.dylib`。

稳定离线版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExport.dylib .\AM_v1_direct_v21.ipa `
  --expected-main-uuid $uuid
```

带本地后端诊断的 Debug 版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = python -c "import secrets; print(secrets.token_urlsafe(32))"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v21_debug.ipa `
  --debug-mode full --debug-token $token --expected-main-uuid $uuid
python .\debug_backend\server.py --token $token
```

实验分享版：

```powershell
$uuid = "4b22d43f-09fc-3bde-859b-78a5d573a503"
$token = python -c "import secrets; print(secrets.token_urlsafe(32))"
python .\inject_dylib.py .\AM_v1.ipa .\AMProjExport\AMProjExportDebug.dylib .\AM_v1_direct_v21_share_exp.ipa `
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
