# Ghidra 静态分析发现 — AM iOS 导出代码路径

## 导出 UI 流程

```
ShareVC / ShareTableViewCell
  ↓
onTapExport:  →  FUN_10094a8b4 (导出处理器)
  ↓
presentChooseExportedInfoFormatAlertController:  →  格式选择弹窗
  ├── "Screenshot" (截图)
  ├── "TextFile"   (文本/XML)   ← 这就是 XML 导出!
  └── "Cancel"     (取消)
```

## 关键 Swift 类型

| 类型 | 地址 | 说明 |
|------|------|------|
| `ExportXMLFile` | 0x10210dbac | **XML 导出类** (v19 仅字符串引用, 可能 v27b 才有实现) |
| `Exporter` | 0x1020f3150 | 主导出器类 |
| `ExporterDelegate` | 0x1020f3050 | 导出器代理协议 |
| `SceneComp` | 0x1020bfd40 | 场景组合类 |
| `ProjectExportTrackingInfo` | 0x1021c0b80 | 导出追踪信息 |

## 包(.amproj)相关函数

| 函数 | 地址 | 调用者 |
|------|------|--------|
| `makeAMProjectPackageId` | 0x1023a8050 | **无调用者** (v19) |
| `registerAMProjectPackage` | 0x1023a8070 | **无调用者** (v19) |

> **结论**: v19 中 .amproj 包功能**已定义但未被调用**。
> v27b 可能已激活或仍处于未使用状态。这正是我们的注入点!

## shareProjectXML 方法

Swift mangled name:
```
_TtCFC12AlightMotion7ShareVC15shareProjectXMLFTGSaVS_9SceneInfo_
6holderGSqCS_13ProjectHolder_12trackingInfoGSaV20ShareVideoAndPackage
25ProjectExportTrackingInfo__T_L_28PortalActivityViewController
```

签名: `ShareVC.shareProjectXML([SceneInfo], ProjectHolder?, [ProjectExportTrackingInfo]) -> PortalActivityViewController`

## 导出相关 ObjC 方法

- `resetExportVideo` / `resetExportGif` / `resetExportImg` / `resetExportWebp` — 各格式导出重置
- `exportFileSizeTitle` / `exportFileSizeLabel` — 文件大小估算 UI
- `exportEstimationView` / `exportEstimationViewHeight` — 导出预估视图
- `exportCurrentFrameButton` — 导出当前帧按钮
- `onMemoryWarningForExport:` — 导出时内存警告处理

## 注入策略 (已确定)

### 从 `executePendingSaveProjectSync` 反编译确认

```
ProjectHolder.executePendingSaveProjectSync()
  → 检查 pendingSave && allowSaving
  → 读取 _rootScene 字段
  → FUN_1003b59a8(rootScene)          ← XML 序列化
  → String.write(to:atomically:encoding:.utf8)  ← 写文件
```

**关键结论:**
- `ProjectHolder.rootScene` 通过 KVC 可访问
- 场景对象 tree: scene → layers[] → transform/effects/properties/fillColor/...
- XML 序列化由 `FUN_1003b59a8` 完成 (内部 Swift, ObjC 不可直接调用)
- 我们通过递归 KVC 反射遍历对象 tree, 按 `format_spec.md` schema 构建 XML

### 注入点 (已实现)
1. **不 hook 任何导出方法** — 保持原有 XML/视频导出不变
2. **仅在 viewDidAppear 添加独立按钮** — 不修改原有 UI 布局
3. **通过 KVC + runtime 反射获取场景数据** — 不依赖 @import Swift types
4. **递归遍历构建 XML** — `buildXMLRecursive:` 方法

### 需要验证 (v27b)
- `ExportXMLFile` 在 v27b 中是否已完整实现
- `makeAMProjectPackageId` 在 v27b 中是否已被调用
- 格式选择弹窗在 v27b 中是否多了 "Package" 选项
