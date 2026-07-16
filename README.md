# AMProjExport

为 Alight Motion iOS v27b 注入 `.amproj` 导出与本地导入能力。项目包含：

- `AMProjExport.dylib`：离线 Release 版。
- `AMProjExportDebug.dylib`：带 Windows 调试后端遥测的 Debug 版；后端不可达不会阻塞导入或导出。
- `AMProjShareExtension.appex`：实验性“导入到 AM”分享扩展。
- `inject_dylib.py`：Windows IPA 注入、Info.plist 修补和产物验证工具。

Debug IPA 会优先连接注入时记录的 Windows 地址；地址变化或连接失败时，会在后台通过带 token 认证的 UDP 单播自动发现同一 Wi-Fi 内的后端。默认 TCP/UDP 均使用端口 `8765`，Windows 防火墙需要同时允许这两个协议。发现失败只影响调试日志，不参与也不阻塞导入、导出。

## `.amproj` 格式

`.amproj` 是 ZIP32 容器，必须包含：

```text
project.amproj
├── <UUID>.xml       # 恰好一个场景 XML
├── manifest.txt     # 恰好一个资源清单，可以为空
└── media/font/...   # XML 引用的可选资源
```

完整格式见 `format_spec.md`。

## v15 导入入口

稳定入口是 QQ/文件 App 的“用其他应用打开 → Alight Motion”。系统交付的文件 URL 会先原样传给 AM 自己的项目包路由；AM 明确拒绝时，插件才在授权仍有效的回调内复制、校验，并把主沙盒缓存 URL 重新交给同一个原生入口。插件不再调用模板页的 XML 文档选择器。失败弹窗中的“选择项目包”仍使用复制模式作为兜底。

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

## 从干净 IPA 生成 v15

必须以未注入的 `AM_v1.ipa` 为输入，不要用旧测试包继续叠加。主 App Bundle ID 保持 `com.amayaka.meow`。

稳定版：

```powershell
python inject_dylib.py AM_v1.ipa AMProjExportDebug.dylib AM_v1_direct_v15.ipa
```

实验版：

```powershell
python inject_dylib.py AM_v1.ipa AMProjExportDebug.dylib AM_v1_direct_v15_share_exp.ipa `
  --share-extension AMProjShareExtension.appex `
  --app-group-id group.com.amayaka.meow.amprojshare
```

注入器会验证 arm64、Mach-O load command、ZIP CRC、UTI/copy-in 配置以及实验扩展的 Bundle ID、extension point 和 App Group 模板。输出 IPA 仍需使用 Sideloadly 签名安装。

## 本地测试

```powershell
python -m unittest discover -s tests -v
python -m unittest debug_backend.test_server -v
```
