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
├── <UUID>.xml       # 恰好一个场景 XML
├── manifest.txt     # 规范资源清单，可以为空
└── media/font/...   # XML 引用的可选资源
```

导入时必须有且只能有一个场景 XML 和一个 `manifest.txt`。插件导出时始终生成一个规范的 `manifest.txt`。

完整格式见 `format_spec.md`。

## v17 离线导入

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。系统 URL 回调收到 `.amproj` 后，插件会在 File Provider 授权仍有效时，先复制到主 App 的 `Library/Application Support/AMProjImports/<UUID>/`。Inbox 或已取得 security scope 的文件在后台复制；只有无法延续授权的 Provider URL 才在回调内同步复制。AppDelegate 的通用文件入口只处理媒体、字体和 SVG，并且可能在没有创建项目时返回 `YES`，因此不能用于 `.amproj` 导入或作为成功判据。

复制完成后的处理全部在本地执行：插件先校验 ZIP32 中央目录以及 XML/manifest 数量，然后把复制后的原始 `.amproj` ZIP 交给当前 `TemplatesListVC` 的文档选择器回调。AM 随后通过自己的 `Home.Feature.Action.Input.didPickFile`、`ProjectsImportAlert` 和 `PackageImporter` 完成解析及项目保存。插件只有观察到原生 `ProjectsImportAlert` 出现时才显示 `4/4`；selector 返回或 AppDelegate 返回 `YES` 都不再被视为导入成功。失败弹窗中的“选择项目包”使用文档选择器复制模式作为兜底，并进入同一条处理链。

正常状态顺序为：`1/4 收到文件 -> 2/4 已复制 -> 3/4 已交给 AM -> 4/4 AM 已识别项目包`。看到 `4/4` 后仍需在 AM 原生确认框中点击导入；插件不会在项目真正保存前宣称成功。

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

## 从干净 IPA 生成 v17

必须以未注入的 `AM_v1.ipa` 为输入，不要用旧测试包继续叠加。主 App Bundle ID 保持 `com.amayaka.meow`。

稳定版：

```powershell
python inject_dylib.py AM_v1.ipa AMProjExportDebug.dylib AM_v1_direct_v17.ipa
```

实验版：

```powershell
python inject_dylib.py AM_v1.ipa AMProjExportDebug.dylib AM_v1_direct_v17_share_exp.ipa `
  --share-extension AMProjShareExtension.appex `
  --app-group-id group.com.amayaka.meow.amprojshare
```

注入器会验证 arm64、Mach-O load command、ZIP CRC、UTI/copy-in 配置以及实验扩展的 Bundle ID、extension point 和 App Group 模板。输出 IPA 仍需使用 Sideloadly 签名安装。

## 本地测试

```powershell
python -m unittest discover -s tests -v
python -m unittest debug_backend.test_server -v
```
