# iOS AM Binary 逆向发现

## 二进制信息

- **文件**: `AlightMotion` (Mach-O 64-bit arm64)
- **大小**: 50MB, 已解密 (FairPlay 已移除)
- **语言**: Swift + ObjC
- **符号**: 5675 个, 主要是系统库导入, 自定义类被 strip
- **已有注入**: `AlightMotionHack.dylib`, `AhmadDev.dylib`, `ipafire1.dylib`, `Firepurchase.dylib`

## 关键发现

### 1. XML 导出功能已存在

在 `__DATA` 段中发现:
```
ic_export_xml      ← XML 导出图标名
ic_export_gif      ← GIF 导出
ic_export_video    ← 视频导出
ic_export_webp     ← WebP 导出
```

**AM iOS 已有 XML 导出功能!** 问题可能是:
- 当前被隐藏/禁用
- 导出的是纯 XML 而非 .amproj (ZIP 包)
- 功能不完整

### 2. iOS 效果命名规范 (与 Android 不同)

iOS 使用: `effects.<name>` (短格式)
Android 使用: `com.alightcreative.effects.<name>` (完整反向域名)

iOS 已知效果:
```
effects.box, effects.bumpmap, effects.clouds, effects.clouds2, effects.clouds3,
effects.cube, effects.cube2, effects.curl, effects.dblur, effects.extrude,
effects.fade, effects.heart, effects.heart2, effects.lift, effects.lumakey,
effects.mirror, effects.mosaic, effects.noise, effects.noise2, effects.noise3,
effects.plus, effects.polar, effects.pyramid, effects.rays, effects.repeat,
effects.ribbon, effects.ridges, effects.ridges2, effects.shake, effects.shake2,
effects.tile, effects.torus, gradientmap
```

共 32 种效果 (Android 有 34+ 种)。

### 3. 技术栈

| 组件 | 技术 |
|------|------|
| UI | SwiftUI (SceneStorage, ShapeView, NavigationLink, etc.) |
| 动画渲染 | CoreAnimation (CALayer, CAShapeLayer, CAKeyframeAnimation) |
| XML 解析 | NSXMLParser (读取 .amproj) |
| 文件导入 | UIDocumentPickerViewController |
| 视频导出 | AVAssetExportSession, AVAssetWriter |
| 特效引擎 | 自定义 native (SceneKit + GL 可能) |

### 4. 现有 Mod 功能

| dylib | 推测功能 |
|-------|----------|
| `AlightMotionHack.dylib` | Hooks `/getAccountStatusAndLicenses` (订阅/许可证绕过) |
| `AhmadDev.dylib` | Theos tweak, 可能需要额外分析 |
| `ipafire1.dylib` | OpenSSL + ldid (代码签名/重签) |
| `Firepurchase.dylib` | IAP 破解 (UIAlertAction hook) |

### 5. 缺少的文档类型注册

Info.plist 中 **没有** CFBundleDocumentTypes / UTImportedTypeDeclarations / UTExportedTypeDeclarations。
这意味着 .amproj 文件关联是在运行时通过 UIDocumentPickerViewController 实现的,而非系统级注册。

### 6. UI 结构推测

从 icon 名称推断的导出界面:
```
导出菜单
├── ic_export_xml    → 导出 XML / .amproj
├── ic_export_video  → 导出视频
├── ic_export_gif    → 导出 GIF
└── ic_export_webp   → 导出 WebP
```

## 待逆向确认的接口

这些需要通过 Frida/Cycript 在越狱设备上运行时追踪:

### Scene 模型
- 场景根对象类名
- 图层列表获取方法
- 图层类型枚举

### Transform 数据
- location/pivot/rotation/scale/opacity 的存储结构
- 关键帧列表访问

### 效果系统
- 效果注册表/工厂
- 效果参数获取

### XML 序列化
- ic_export_xml 对应的实际函数
- XML 序列化器类
- 是否输出完整 .amproj 还是仅 XML

## 建议的运行时追踪脚本 (Frida)

```javascript
// 追踪 XML 导出按钮点击
// 1. 搜索包含 "ic_export_xml" 的类
// 2. Hook 相关方法
// 3. 捕获导出的 XML 数据

// 查找所有方法包含 "export" 的类
ObjC.classes.forEach(cls => {
    const methods = ObjC.classes[cls.name].$ownMethods;
    methods.forEach(method => {
        if (method.toLowerCase().includes('export') || 
            method.toLowerCase().includes('xml') ||
            method.toLowerCase().includes('saveproject')) {
            console.log(`[${cls.name} ${method}]`);
        }
    });
});
```
