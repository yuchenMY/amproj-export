# .amproj 导出逆向分析 — 最终总结

## 逆向来源

1. **Android AMX APK** (`D:\Download\am X`) — 解包后的 APK,含 native libs 和 assets
   - `classes.dex` 被 360 加固 (Jiagu) 加密,无法直接反编译
   - `assets/hometab/beta_anim.xml` — 真实导出的项目 XML
   - `assets/effects/` — 效果定义 (`.xml`)
   - `assets/shapes/` — 形状定义 (`.xml`)
   - `lib/arm64-v8a/libalight-native-lib.so` — 核心引擎 (被 strip,无有用符号)
   - `assets/libjiagu_a64.so` — 360 加固 runtime

2. **开源 Rust crate `amproj`** (https://github.com/Bli-AIk/amproj) — 完整逆向的 .amproj 解析库
   - 纯数据提取层,完整定义了 XML schema
   - 包含: scene / layer types / animation / keyframe / effect / easing / coord / validation
   - 许可证: MIT / Apache-2.0

## .amproj 格式核心结论

### 容器: ZIP (标准 PKZIP, deflate 压缩)

```
project.amproj
├── *.xml               ← 恰好一个 XML 场景描述文件
├── *.png / *.jpg / *.webp   ← 嵌入图片 (可选)
└── *.ttf / *.otf       ← 嵌入字体 (可选)
```

### 场景 XML: 根元素 `<scene>`

- 项目元数据: title, width, height, fps, totalTime, bgcolor
- 媒体声明: `<media>` 元素
- 图层列表: 9 种图层类型按 z-order 排列

### 图层体系 (9 种)

| 图层 | XML 标签 | 典型用途 |
|------|----------|----------|
| Shape | `<shape>` | 矢量形状, SVG 路径, 渐变, 描边 |
| Text | `<text>` | 文本, 字体, 对齐 |
| Image | `<image>` | 静态图片 |
| Video | `<video>` | 视频素材 |
| Audio | `<audio>` | 音频 |
| Camera | `<camera>` | 相机 (FOV) |
| NullObj | `<nullobj>` | 空对象/控制器 |
| EmbedScene | `<embedScene>` | 预合成/嵌套场景 |
| Bookmark | `<bookmark>` | 时间线书签 |

### 动画系统

- **AnimatedFloat / AnimatedVec2 / AnimatedVec3**: 静态值 + 关键帧列表
- **Keyframe**: `{ t: f32, v: String, e?: String }`
- **8 种缓动**: Linear, Step, CubicBezier, Bounce, ReverseBounce, Cyclic, Elastic, ElasticStep
- **注意**: 关键帧 `t` 单位在 Android 导出中为**秒** (非毫秒)

### 变换系统

```
Transform { location: Vec3, pivot: Vec2, rotation: f32, scale: Vec2, opacity: f32 }
```

所有变换属性都支持关键帧动画。

### 效果系统

```
Effect { id: String, locallyApplied: bool, properties: Property[] }
Property { name, type, value, keyframes }
```

已知 34+ 种内置效果。

## iOS 注入关键路径

### 需要实现的三步

1. **场景序列化** → XML 字符串 (schema 已完全明确)
2. **资源收集** → 项目中引用的图片/字体
3. **ZIP 打包** → 标准 ZIP → .amproj 文件

### 需要逆向的 AM iOS 接口

- Scene 根对象和图层树遍历
- 图层属性 (id/label/time/parent/hidden/fillType/...)
- Transform 数据 (含关键帧)
- 填充/描边/渐变
- 效果列表 (含参数和关键帧)
- 媒体引用和嵌入资源
- 嵌套场景递归

### 注入方式

1. 通过 Theos/Tweak 注入到 AlightMotion.app
2. Hook UI 层添加导出按钮
3. 或通过 Mach-O 补丁 (参考 `am-mod-patch-style`)

### 参考实现

- `amproj` crate: schema 定义 + 反序列化 (反写即可得到序列化)
- `bevy_alight_motion` crate: 完整渲染管线参考
- `alightmotiondecomp` (Java): 完整的 Android 反编译参考

## 最终策略: 拦截现有导出流程

不需要理解 AM 内部数据模型! iOS 已经有完整的 ProjectPackage 系统:

1. `ShareProjectPackageVC` — 分享 UI
2. `ExportProjectPackage` — 导出类
3. `validateProjectPackageXML` — XML 验证
4. `ProjectPackager` — 打包器

**注入点**: Hook 导出格式弹窗,添加 "📦 .amproj Package" 选项
**实现**: 见 `AMProjExport.xm` (Logos tweak 源码)

### 为什么选拦截策略而非重建
- AM 内部 Swift 类型 (SceneInfo, SceneComp, ProjectHolder) 是 internal 的
- Ghidra/IDA 可以看到类型名但无法直接调用 Swift internal API
- 但 AM 已经会生成 XML (TextFile 选项), 我们只需在输出路径上拦截
- 或者通过 ObjC runtime 动态调用现有方法

## 文件清单

| 文件 | 内容 |
|------|------|
| `README.md` | 概述 |
| `SUMMARY.md` | 本文件 (总结) |
| `format_spec.md` | **完整格式规范** (497行, 来源于 Android + amproj crate) |
| `xml_schema.md` | XML 元素/属性速查表 + 完整模板 |
| `ios_injection_plan.md` | iOS 注入方案 (3 种方案对比 + Frida 步骤) |
| `ios_reverse_findings.md` | iOS 二进制逆向发现 |
| `ghidra_findings.md` | Ghidra 静态分析结果 (导出代码路径) |
| `easing_reference.md` | 8 种缓动函数详解 |
| `effects_list.md` | 已知效果列表 (Android+iOS) |
| `example_annotated.xml` | 真实 Android 项目 XML 带注释 |
| `AMProjExport.xm` | **Logos tweak 源码** (注入用) |
| `frida_find_export.js` | Frida 追踪脚本 (需要越狱设备时用) |
| `Makefile` | Theos 编译配置 |
| `inject_dylib.py` | IPA 注入 + 重签脚本 |
