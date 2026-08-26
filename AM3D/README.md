# AM3D — 独立 3D 空对象渲染桥（真 3D 优先）

完全独立的注入 dylib：在**空对象（nullobj）**上实现 3D 父级控制器渲染。
**不依赖、不修改** AMProjExport / AmHomeUI / AmEnhancer 的任何代码。

## 设计（v1）

```
+load 自动启动
  └─ CADisplayLink 每帧 tick（全部 @try/@catch，失败静默降级）
      ├─ 探测场景：keyWindow VC 树 → ProjectHolder → rootScene → layers
      │   （自包含 KVC 反射 am3d_get，独立实现）
      ├─ 探测画布：类名含 Preview/Canvas/Scene/Element 的视图
      ├─ 配对：canvas.layer.sublayers 按 z-order ↔ layers 顺序
      ├─ 计算：每个元素的 3D world 矩阵（父链 TRS 连乘，深度 ≤64）
      │   - 空对象：rotation3d/scale3d（原生有则用，无则 2D 回退规则）
      │   - 普通子层：2D 字段回退（(0,0,rotation2d) / (scale2d,1)）
      ├─ 应用：flat 方式写 CALayer.transform（脏检查，值变才写）
      └─ 透视：canvas.sublayerTransform.m34（焦距默认 1100px）
降级：映射不到真实图层时，窗口叠加半透明占位演示（保证可见效果）
```

## 配置（UserDefaults，全部可选）

| 键 | 类型 | 默认 | 说明 |
|----|------|------|------|
| `AM3DEnabled` | BOOL | YES | 总开关 |
| `AM3DLog` | BOOL | YES | `[AM3D]` 前缀日志 |
| `AM3DPerspective` | float | 1100 | 透视焦距 px；≤0 关闭透视 |
| `AM3DDemoFallback` | BOOL | YES | 映射失败时显示半透明占位演示 |

## 构建

```bash
cd AM3D && make        # 产物 AM3D.dylib（arm64, iOS 14+）
```

GitHub Actions 自动构建 + 运行 `tests/AM3DTransform3DSmoke.m`（数学冒烟：
2D 退化、正交性、TRS 合成、奇异/除零/NaN 安全、parseVec3 严格校验），
成功后在 `am3d-v1-<sha12>` Release 发布 `AM3D-v1.dylib.zip`。

## 注入（追加，不替换其他 dylib）

```powershell
python inject_dylib.py <输入.ipa> AM3D.dylib <输出.ipa> --expected-main-uuid <主程序UUID>
```

已有 AMProjExportCloud.dylib 的包直接追加即可（注入器会新增一条
LC_LOAD_DYLIB；Mach-O 头 padding 不足时会明确报错）。

## 真机迭代项（v2 计划）

1. **图层↔元素映射**：v1 假设 canvas 子层 z-order 与 layers 顺序一致，
   真机日志（`[AM3D] layer map rebuilt` / `canvas probe`）确认；若不一致，
   改用 KVC 层属性（name/id）或递归匹配；
2. **动画合成**：接管层若有自己的 2D 关键帧动画，需在父空间重算合成，
   避免覆盖 AM 动画（脏检查已减少无谓写入）；
3. **数据源**：原生 UI 暂无 3D 面板；v1 读取原生对象上的
   rotation3d/scale3d（meow3d 导入后若原生保留则自动生效），
   未来经云端插件桥（Injet web）提供 3D 参数控制。
