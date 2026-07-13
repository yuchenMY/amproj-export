# .amproj 项目文件格式 — 逆向分析总结

## 来源

从 Android 版 Alight Motion X (AMX) 提取分析,并结合开源 Rust crate [`amproj`](https://github.com/Bli-AIk/amproj) 的解析代码交叉验证。

## 概要

`.amproj` 是 Alight Motion 的项目导出格式,本质上是一个 **ZIP 压缩包**,内部结构非常简单:

```
project.amproj
├── scene.xml          ← 唯一的 XML 场景描述文件 (必需)
├── image1.png         ← 嵌入图片 (可选, .png/.jpg/.jpeg/.webp)
├── image2.jpg
├── font.ttf           ← 嵌入字体 (可选, .ttf/.otf)
└── ...更多资源...
```

## 核心原理

1. **序列化**: 项目数据 → XML (遵循下方 schema) + 图片/字体资源
2. **打包**: XML + 资源文件 → 标准 ZIP (deflate 压缩)
3. **命名**: 扩展名改为 `.amproj`

AM iOS/Android 客户端**原生支持读取**此格式,所以注入的关键是在 iOS 端实现**写入**(序列化+打包)。

## 本目录文件

| 文件 | 内容 |
|------|------|
| `README.md` | 本文件 |
| `SUMMARY.md` | 总结 |
| `format_spec.md` | **完整格式规范** (497行) |
| `xml_schema.md` | XML 模板速查 |
| `ghidra_findings.md` | Ghidra 静态分析结果 |
| `ios_reverse_findings.md` | iOS 二进制逆向发现 |
| `ios_injection_plan.md` | iOS 注入方案 |
| `easing_reference.md` | 8 种缓动函数 |
| `effects_list.md` | 效果列表 |
| `example_annotated.xml` | 真实项目 XML |
| **`AMProjExport/AMProjExport.m`** | **dylib 源码 (ObjC)** |
| `AMProjExport/Makefile` | macOS 编译 |
| `AMProjExport.xm` | Logos tweak 版本 (需 theos) |
| `.github/workflows/build.yml` | **GitHub Actions 自动编译** |
| `build_and_inject.bat` | **Windows 一键注入脚本** |
| `inject_dylib.py` | Python IPA 注入脚本 |
| `frida_find_export.js` | Frida 追踪脚本 |

## Windows 操作流程 (无需 Mac, 无需越狱)

### 1. 获取 dylib (二选一)

**A. GitHub Actions (推荐, 零成本)**
```
Fork 这个 repo → 推送代码 → Actions 自动编译 → 下载 Artifact
```

**B. 或者用我给的 dylib**
```
(如果已有编译好的 AMProjExport.dylib)
```

### 2. 注入 IPA (Windows)
```bat
build_and_inject.bat AlightMotion_v27b.ipa
```

### 3. 签名 + 侧载 (Windows)
- **AltStore** (altstore.io) — Windows 端侧载工具
- **Sideloadly** (sideloadly.io) — 支持 Windows
- **TrollStore** — 如果设备支持 (iOS 14-16)

### 原理
- dylib 使用纯 ObjC, 通过 `method_exchangeImplementations` hook (不需要 substrate)
- 拦截 `UIAlertController.addAction:` 检测导出弹窗
- 添加 "📦 .amproj Package" 选项
- 选项触发: 获取场景 XML → ZIP 打包 → 系统分享面板
