# 已知 AM 效果列表

从 `amproj` crate 和 Android AMX APK 中提取。

## 效果 ID 命名规则

格式: `com.alightcreative.effects.<name>`

部分效果有版本后缀 (如 `transform2`, `pixelate2`, `oscillate3`)。

## 完全支持的效果

| 效果 ID | 显示名 | 说明 |
|---------|--------|------|
| `chromakey` | 色度抠图 | 根据颜色抠除背景 |
| `counter` | 计数器 | 数字递增动画 |
| `echokf` (repeat.echokf) | 回声关键帧 | 重复+衰减 |
| `exposure` | 曝光 | 曝光/伽马调整 |
| `fade` | 淡入淡出 | 透明度渐变 |
| `gaussianblur` | 高斯模糊 | 模糊效果 |
| `grid2` | 网格 | 网格变形 |
| `jitter` | 抖动 | 随机位置偏移 |
| `lift` | 提亮 | 亮度/对比度 |
| `mirror` | 镜像 | 镜像反射 |
| `oscillate3` | 振荡 | 周期性偏移 |
| `palettemap` | 调色板映射 | 颜色映射 |
| `parenthelper` | 父级辅助 | 父子关系辅助 |
| `pixelate2` | 像素化 | 像素块效果 |
| `radial` (repeat.radial) | 径向重复 | 径向克隆 |
| `randomdisplace` | 随机位移 | Simplex 噪声位移 |
| `rays` | 光线 | 放射光线 |
| `repeat` | 重复 | 线性重复 |
| `repeat.line` | 线性重复 | 线性克隆 |
| `repeat.path` | 路径重复 | 沿路径克隆 |
| `rgbsep` | RGB 分离 | 通道分离/色差 |
| `scaleassist` | 缩放辅助 | 缩放辅助 |
| `solidcolor` | 纯色 | 纯色覆盖 |
| `spin` | 旋转 | 自动旋转 |
| `stretch2` | 拉伸 | 拉伸变形 |
| `stretchsegment` | 段拉伸 | 分段拉伸 |
| `textprogress` | 文本进度 | 逐字显示 |
| `textspacing` | 文本间距 | 字间距动画 |
| `threshold` | 阈值 | 阈值/二值化 |
| `transform2` | 变换 | 位置/旋转/缩放 |
| `transform_v1` | 变换 (旧版) | 旧版变换 |
| `wavewarp2` | 波浪变形 | 波浪扭曲 |
| `wipe2` | 擦除 | 线性擦除 |
| `swing` | 摆动 | 摇摆效果 |

## 部分支持的效果

| 效果 ID | 显示名 | 限制 |
|---------|--------|------|
| `simplex_displace` (randomdisplace) | Simplex 位移 | 部分参数未支持 |

## Android APK 中额外的效果 (在 assets/effects/ 中)

| 效果 ID | 文件 |
|---------|------|
| `3dtext` | 3dtext.xml |
| `360-reorient-sphere` | 360-reorient-sphere.xml |
| `motionblur` | (在 beta_anim.xml 中引用) |
| `starfield` | (在 beta_anim.xml 中引用) |

## iOS 端已知效果

iOS 版本可能使用不同的效果命名或版本。需要从 iOS binary 中提取效果注册表。
常见效果 (从 iOS GLSL shader 文件推断):
- `com.alightcreative.effects.transform` / `transform2`
- `com.alightcreative.effects.gaussianblur`
- `com.alightcreative.effects.chromakey`
- `com.alightcreative.effects.rgbsep` (RGB Split)
- `com.alightcreative.effects.pixelate` / `pixelate2`

## 效果的 XML 结构

```xml
<!-- 无参数效果 -->
<effect id="com.alightcreative.effects.motionblur" />

<!-- 有参数效果 -->
<effect id="com.alightcreative.effects.transform2" locallyApplied="false">
    <property name="posx" type="float" value="0">
        <kf t="0" v="0" />
        <kf t="1" v="100" />
    </property>
    <property name="posy" type="float" value="0" />
    <property name="scale" type="vec2" value="1.0,1.0" />
    <property name="rotation" type="float" value="0" />
    <property name="opacity" type="float" value="1.0" />
</effect>
```

## Property 类型

| type 属性值 | 值格式 | 示例 |
|------------|--------|------|
| `float` | 单值 | `"0.5"` |
| `vec2` | 逗号分隔两值 | `"1.0,1.0"` |
| `vec3` | 逗号分隔三值 | `"0,0,1"` |
| `color` | #AARRGGBB | `"#ffffffff"` |
| `int` | 整数 | `"5"` |
| `bool` | true/false | `"true"` |
| `string` | 字符串 | `"hello"` |
| `enum` | 枚举值 (字符串) | `"linear"` |
