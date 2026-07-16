# AMProjExport

为 Alight Motion iOS v27b 注入 `.amproj` 导出与本地导入能力。项目包含：

- `AMProjExport.dylib`：离线 Release 版。
- `AMProjExportDebug.dylib`：带 Windows 调试后端遥测的 Debug 版；后端不可达不会阻塞导入或导出。
- `AMProjShareExtension.appex`：实验性“导入到 AM”分享扩展。
- `inject_dylib.py`：Windows IPA 注入、Info.plist 修补和产物验证工具。

## `.amproj` 格式

`.amproj` 是 ZIP32 容器，必须包含：

```text
project.amproj
├── <UUID>.xml       # 恰好一个场景 XML
├── manifest.txt     # 恰好一个资源清单，可以为空
└── media/font/...   # XML 引用的可选资源
```

完整格式见 `format_spec.md`。

## v14 导入入口

稳定入口是 QQ/文件 App 的“用其他应用打开 → Alight Motion”。注入器强制使用 copy-in 文档交付，插件把系统交付到 `Documents/Inbox` 的文件复制到自己的缓存，校验 ZIP 后调用 AM 原生导入器。失败弹窗中的“选择项目包”会用复制模式打开系统文档选择器。

实验入口是 QQ 分享面板中的“导入到 AM”。扩展先把一个 `.amproj` 原子写入 App Group，再尝试用 `alightmotion://amproj-import` 唤起主 App。免费自签不一定能保留 App Group 或允许扩展自动唤起，因此实验包与稳定包分开生成。

导入不依赖 VPN、网络或调试后端。

## GitHub Actions 构建

推送源码后，Actions 会构建并验证：

```text
AMProjExport/AMProjExport.dylib
AMProjExport/AMProjExportDebug.dylib
AMProjShareExtension/build/AMProjShareExtension.appex
AMProjShareExtension/build/AMProjShareExtension.entitlements
```

## 从干净 IPA 生成 v14

必须以未注入的 `AM_v27b.ipa` 为输入，不要用 v12/v13 包继续叠加。

稳定版：

```powershell
python inject_dylib.py AM_v27b.ipa AMProjExportDebug.dylib AM_v27b_direct_v14.ipa
```

实验版：

```powershell
python inject_dylib.py AM_v27b.ipa AMProjExportDebug.dylib AM_v27b_direct_v14_share_exp.ipa `
  --share-extension AMProjShareExtension.appex `
  --app-group-id group.com.amayaka.meow.amprojshare
```

注入器会验证 arm64、Mach-O load command、ZIP CRC、UTI/copy-in 配置以及实验扩展的 Bundle ID、extension point 和 App Group 模板。输出 IPA 仍需使用 Sideloadly 签名安装。

## 本地测试

```powershell
python -m unittest discover -s tests -v
python -m unittest debug_backend.test_server -v
```
