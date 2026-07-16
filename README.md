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

导入时必须有且只能有一个场景 XML；`manifest.txt` 可以不存在，也可以存在一个，多个 manifest 会被拒绝。插件导出时始终生成一个规范的 `manifest.txt`。

完整格式见 `format_spec.md`。

## v16 离线导入

稳定入口是 QQ/文件 App 的“用其他应用打开 -> Alight Motion”。系统 URL 回调收到 `.amproj` 后，插件会在 File Provider 授权仍有效时，先复制到主 App 的 `Library/Application Support/AMProjImports/<UUID>/`。Inbox 或已取得 security scope 的文件在后台复制；只有无法延续授权的 Provider URL 才在回调内同步复制。它不会把 `.amproj` 原样交给 AppDelegate 的文件入口，因为该入口使用的 `AMFileImporter` 主要处理 XML/SVG，并可能在没有实际导入项目时返回成功。

复制完成后的处理全部在本地执行：后台校验 ZIP32、CRC、条目路径、压缩方式以及 XML/manifest 数量，解压 XML 和资源，再把 XML 中的 `amproj:` 资源 URI 改写为解压目录中的 `file://` URL。准备完成后，插件只把改写后的 XML URL 交给 AM 原生 `AMFileImporter`，由 AM 自己的场景解析和项目保存逻辑完成导入。AM 接受 XML 后，解压资源会被标记为持久数据且排除 iCloud 备份，避免系统清缓存或 7 天临时清理导致项目丢失媒体；原始 ZIP 会删除。失败弹窗中的“选择项目包”仍使用文档选择器复制模式作为兜底，并进入同一条处理链。

实验入口是 QQ 分享面板中的“导入到 AM”。扩展先把一个 `.amproj` 原子写入 App Group，再尝试用 `alightmotion://amproj-import` 唤起主 App。免费自签不一定能保留 App Group 或允许扩展自动唤起，因此实验包与稳定包分开生成。

整个导入链不依赖 VPN、网络或调试后端。Debug 后端不可达时只会缺少诊断日志。

## GitHub Actions 构建

推送源码后，Actions 会构建并验证：

```text
AMProjExport/AMProjExport.dylib
AMProjExport/AMProjExportDebug.dylib
AMProjShareExtension/build/AMProjShareExtension.appex
AMProjShareExtension/build/AMProjShareExtension.entitlements
```

## 从干净 IPA 生成 v16

必须以未注入的 `AM_v1.ipa` 为输入，不要用旧测试包继续叠加。主 App Bundle ID 保持 `com.amayaka.meow`。

稳定版：

```powershell
python inject_dylib.py AM_v1.ipa AMProjExportDebug.dylib AM_v1_direct_v16.ipa
```

实验版：

```powershell
python inject_dylib.py AM_v1.ipa AMProjExportDebug.dylib AM_v1_direct_v16_share_exp.ipa `
  --share-extension AMProjShareExtension.appex `
  --app-group-id group.com.amayaka.meow.amprojshare
```

注入器会验证 arm64、Mach-O load command、ZIP CRC、UTI/copy-in 配置以及实验扩展的 Bundle ID、extension point 和 App Group 模板。输出 IPA 仍需使用 Sideloadly 签名安装。

## 本地测试

```powershell
python -m unittest discover -s tests -v
python -m unittest debug_backend.test_server -v
```
