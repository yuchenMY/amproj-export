# .amproj 格式完整规范

## 1. 容器格式

### 1.1 ZIP 结构

| 属性 | 值 |
|------|---|
| 容器格式 | ZIP (标准 PKZIP) |
| 压缩方式 | deflate |
| 必需文件 | 单项目包恰好 1 个 UUID 命名的 `.xml`；`manifest.txt` |
| 可选文件 | 图片、视频、音频、字体等 XML 引用的资源文件 |

官方包按“资源文件 → XML → `manifest.txt`”排列。`manifest.txt` 不包含 XML，
只列资源文件；每行格式为 `大写 SHA1:文件名`，行间使用 LF，最后一行不加换行。例如：

```text
CF5C7CF10149B91E4A49D6D48DE8AC1740AFCA33:example.png
```

### 1.2 文件发现规则

ZIP 内文件的发现依赖于文件名扩展:
- `name.endsWith(".xml")` → 场景 XML
- `name == "manifest.txt"` → 资源完整性清单
- `name.endsWith(".png")` / `.jpg` / `.jpeg` / `.webp` → 嵌入图片 (URI 格式: `amproj:filename`)
- `name.endsWith(".ttf")` / `.otf` → 嵌入字体

### 1.3 兼容的输入形式

加载器 (`load_project_from_path`) 接受三种形式:
1. `.amproj` 文件 → ZIP archive
2. 目录 → 遍历目录内的 XML + 资源文件 (未打包形式)
3. 单独 `.xml` 文件 → 直接解析 XML,无嵌入资源

---

## 2. XML 根结构: `<scene>`

### 2.1 属性

| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `type` | `project` / `preset` | 平台相关 | 顶层场景在 iOS 导入时必须为 `project` 才会直接进入底部“项目”；缺失时当前 iOS PackageImporter 会按 preset/element 处理 |
| `title` | string | `""` | 项目名称 |
| `width` | u32 | 1280 | 画布宽度 (像素) |
| `height` | u32 | 1280 | 画布高度 (像素) |
| `exportWidth` | u32 | 1280 | 导出宽度 |
| `exportHeight` | u32 | 1280 | 导出高度 |
| `fps` | u32 | 60 | 帧率 |
| `totalTime` | u32 | 0 | 总时长 (毫秒) |
| `bgcolor` | string | `"#ff000000"` | 背景色 #AARRGGBB |
| `amver` | i32 | 0 | AM 版本号 |
| `retime` | string | `""` | 时间重映射 |
| `precompose` | string | `""` | 预合成引用 |

`type="project"` 只约束每个 XML 的文档根 `<scene>`。EmbedScene 等嵌套
`<scene>` 保留自身语义，导入兼容层不得把嵌套类型批量改写为项目。

### 2.2 子元素

```
<scene ...>
    <media ... />            ← 0-N 个媒体声明
    <shape ...>...</shape>         ← 图层 (任意类型, 按 z-order)
    <text ...>...</text>
    <image ...>...</image>
    <video ...>...</video>
    <audio ...>...</audio>
    <camera ...>...</camera>
    <nullobj ...>...</nullobj>
    <embedScene ...>...</embedScene>
    <bookmark ...>...</bookmark>
</scene>
```

---

## 3. 媒体声明: `<media>`

| 属性 | 类型 | 说明 |
|------|------|------|
| `uri` | string | 资源 URI (如 `file:///...`) |
| `filename` | string | 文件名 |
| `type` | string | 类型: `video`, `image`, `audio` |
| `width` | u32 | 原始宽度 |
| `height` | u32 | 原始高度 |
| `size` | u32 | 文件大小 (字节) |
| `sig` | string | 签名/哈希 |

---

## 4. 图层类型

所有图层共享的基础属性:

| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `id` | u64 | 0 | 图层唯一 ID |
| `label` | string | `""` | 图层名称 |
| `startTime` | i32 | 0 | 起始时间 (ms) |
| `endTime` | i32 | 0 | 结束时间 (ms) |
| `parent` | u64 | 0 | 父图层 ID (0=根) |
| `hidden` | bool | false | 是否隐藏 |

### 4.1 Shape (`<shape>`)

形状图层。XML 标签: `shape`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fillType` | string | `""` | 填充类型 |
| `fillImage` | string | `""` | 填充图片 URI |
| `s` | string | `""` | 形状类型 (rect/ellipse/polygon/...) |
| `blending` | string | `""` | 混合模式 |
| `speed` | f32 | 1.0 | 播放速度 |

专属子元素:
| 元素 | 说明 |
|------|------|
| `transform` | 变换 |
| `property` | 自定义属性 (0-N) |
| `effect` | 效果 (0-N) |
| `fillColor` | 填充色 (可选) |
| `path-stroke` | 路径描边 (可选) |
| `border` | 边框 (0-N) |
| `gradient` | 渐变 (可选) |
| `path` | SVG 路径数据 (可选) |

### 4.2 Text (`<text>`)

文本图层。XML 标签: `text`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fillType` | string | `""` | 填充类型 |
| `font` | string | `""` | 字体名 |
| `size` | f32 | 0 | 字号 |
| `wrapWidth` | f32 | 0 | 换行宽度 |
| `align` | string | `""` | 对齐 (left/center/right) |

专属子元素:
| 元素 | 说明 |
|------|------|
| `content` | 文本内容 (字符串) |
| `fillColor` | 填充色 (可选) |

### 4.3 Image (`<image>`)

图片图层。XML 标签: `image`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fillType` | string | `""` | 填充类型 |
| `fillImage` | string | `""` | 图片 URI |

### 4.4 Video (`<video>`)

视频图层 (**iOS 端可能不完全支持**)。XML 标签: `video`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fillType` | string | `""` | 填充类型 |
| `source` | string | `""` | 视频源 URI |

### 4.5 Audio (`<audio>`)

音频图层 (**iOS 端可能不完全支持**)。XML 标签: `audio`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `source` | string | `""` | 音频源 URI |
| `volume` | f32 | 1.0 | 音量 (0-1) |

### 4.6 Camera (`<camera>`)

相机图层。XML 标签: `camera`

专属子元素:
| 元素 | 说明 |
|------|------|
| `fov` | 视场角 (AnimatedFloat) |

### 4.7 NullObj (`<nullobj>`)

空对象/辅助节点。XML 标签: `nullobj`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `type` | string | `""` | 空对象类型 |

### 4.8 EmbedScene (`<embedScene>`)

嵌套场景/预合成。XML 标签: `embedScene`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `fillType` | string | `""` | 填充类型 |
| `inTime` | i32? | None | 嵌套时间起点 (可选) |
| `outTime` | i32? | None | 嵌套时间终点 (可选) |
| `speed` | f32 | 1.0 | 播放速度 |
| `blending` | string | `""` | 混合模式 |

专属子元素:
| 元素 | 说明 |
|------|------|
| `fillColor` | 填充色 (可选) |
| `gradient` | 渐变 (可选) |
| `scene` | **递归嵌套完整的 `<scene>`** |

### 4.9 Bookmark (`<bookmark>`)

书签/标记。XML 标签: `bookmark`

专属属性:
| 属性 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `label` | string | `""` | 书签名称 |
| `startTime` | i32 | 0 | 起始时间 |
| `endTime` | i32 | 0 | 结束时间 |

---

## 5. Transform 变换系统

```xml
<transform lockAspectRatio="false">
    <location value="x,y,z" />
    <pivot value="x,y" />
    <rotation value="degrees" />
    <scale value="x,y" />
    <opacity value="0.5" />
</transform>
```

| 属性 | 类型 | 说明 |
|------|------|------|
| `lockAspectRatio` | bool | 锁定宽高比 |

| 子元素 | 类型 | 值格式 | 说明 |
|--------|------|--------|------|
| `location` | AnimatedVec3 | `"x,y,z"` | 位置 (像素) |
| `pivot` | AnimatedVec2 | `"x,y"` | 锚点 (像素) |
| `rotation` | AnimatedFloat | `"degrees"` | 旋转 (度, 顺时针为正) |
| `scale` | AnimatedVec2 | `"x,y"` | 缩放 (1.0=100%) |
| `opacity` | AnimatedFloat | `"0-1"` | 不透明度 |

每个变换子元素都可以包含关键帧:

```xml
<location value="640,360,0">
    <kf t="0" v="0,0,0" />
    <kf t="1000" v="640,360,0" e="cubicBezier 0.0 0.0 0.58 1.0" />
</location>
```

---

## 6. Keyframe 关键帧系统

### 6.1 结构

```xml
<kf t="time" v="value_string" e="easing_spec" />
```

| 属性 | 类型 | 说明 |
|------|------|------|
| `t` | f32 | 时间点 |
| `v` | string | 值 (逗号分隔的多值) |
| `e` | string? | 缓动规格 (可选, 默认线性) |

> **⚠️ 重要: 关键帧时间单位**
>
> 从 Android AMX 的真实导出数据来看,关键帧的 `t` 值单位是**秒 (seconds)**,
> 而非毫秒! 例如 `t="0.0083661415"` 表示 8.37ms, `t="1.3495373"` 表示 1.35s。
>
> 而图层级别的 `startTime`/`endTime` 和 scene 的 `totalTime` **是毫秒 (ms)**。
>
> `t` 值相对于**图层/属性的局部时间轴**: 在图层内, t=0 对应图层起始,关键帧时间
> 可以超出图层 [startTime, endTime] 范围 (超出部分定义动画曲线的外推)。
>
> **不同 AM 版本可能使用不同单位**。iOS 版需要验证实际使用的时间单位。
> 建议: 如果导出的 .amproj 要在 iOS 上使用,最好在 iOS 端测试确认 t 值单位。

### 6.2 缓动类型

| 缓动 | 格式 | 参数说明 |
|------|------|----------|
| Linear (默认) | (无 e 属性) | 线性插值 |
| Step | `step <step_length> <smoothing>` | 阶梯缓动, smoothing 0=瞬时, 1=完全平滑 |
| CubicBezier | `cubicBezier <x1> <y1> <x2> <y2>` | 三次贝塞尔, 起点(0,0), 终点(1,1) |
| Bounce | `bounce <p1> <p2>` | 弹跳缓出, p1=第一跳周期, p2=弹力衰减 |
| ReverseBounce | `reverse bounce <p1> <p2>` | 弹跳缓入 |
| Cyclic | `cyclic <step> <sharpness> <skew> <decay> <reserved>` | 周期性振荡 |
| Elastic | `elastic <step> <attack> <decay> <magnitude>` | 弹簧弹性 |
| ElasticStep | `elasticStep <step> <magnitude>` | 阶梯弹性 |

### 6.3 值的序列化

| 值类型 | 格式 | 示例 |
|--------|------|------|
| f32 | `"number"` | `"1.5"`, `"0"` |
| Vec2 | `"x,y"` | `"640,360"` |
| Vec3 | `"x,y,z"` | `"640,360,0"` |
| Color | `"#AARRGGBB"` | `"#ffffffff"` (不透明白) |

---

## 7. Animation 动画值类型

所有以下类型都支持静态值 + 关键帧:

```
AnimatedFloat  = { value?: f32, keyframes: Kf[] }
AnimatedVec2   = { value?: [f32;2], keyframes: Kf[] }
AnimatedVec3   = { value?: [f32;3], keyframes: Kf[] }
AnimatedColor  = { value?: Vec4, keyframes: Kf[] }
```

XML 表示:
```xml
<location value="640,360,0">
    <kf t="0" v="0,0,0" />
    <kf t="1000" v="640,360,0" />
</location>
```

---

## 8. Effect 效果系统

### 8.1 效果结构

```xml
<effect id="com.alightcreative.effects.transform2" locallyApplied="false">
    <property name="x" type="float" value="0.5">
        <kf t="0" v="0" />
        <kf t="1000" v="1" />
    </property>
    <property name="y" type="float" value="0.0" />
</effect>
```

| 属性 | 类型 | 说明 |
|------|------|------|
| `id` | string | 效果 ID (反向域名) |
| `locallyApplied` | bool | 是否本地应用 |

### 8.2 Property 属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `name` | string | 属性名 |
| `type` | string | 属性类型 (float/vec2/vec3/color/...) |
| `value` | string | 默认值 |

子元素: `kf` (0-N 个关键帧)

### 8.3 已知效果 ID (来自 Android 版)

常见效果 ID:
- `com.alightcreative.effects.transform2` — 变换
- `com.alightcreative.effects.gaussianblur` — 高斯模糊
- `com.alightcreative.effects.chromakey` — 色度抠图
- `com.alightcreative.effects.rgbsplit` — RGB 分离
- `com.alightcreative.effects.pixelate` — 像素化
- `com.alightcreative.effects.mirror` — 镜像
- `com.alightcreative.effects.fade` — 淡入淡出
- `com.alightcreative.effects.threshold` — 阈值
- ...共 34+ 种

---

## 9. Fill & Stroke 填充与描边

### 9.1 FillColor

```xml
<fillColor value="#ffffffff">
    <kf t="0" v="#ff000000" />
</fillColor>
```

### 9.2 Stroke (path-stroke / border)

```xml
<path-stroke direction="center" cap="round" join="round" end-size="0">
    <color value="#ffffffff" />
    <size value="10.0">
        <kf t="0" v="10" />
        <kf t="500" v="20" />
    </size>
</path-stroke>

<border direction="outside" cap="butt" join="miter" ...>
    ...
</border>
```

属性:
| 属性 | 说明 |
|------|------|
| `direction` | `inside` / `center` / `outside` |
| `cap` | `butt` / `round` / `square` |
| `join` | `miter` / `round` / `bevel` |
| `end-size` | 末端大小 |

### 9.3 Gradient

```xml
<gradient type="linear" startColor="#ff0000ff" endColor="#ffff0000"
          start="0,0" end="1,0" />
```

---

## 10. Coordinate System 坐标系统

AM 原生坐标:
| 属性 | 值 |
|------|---|
| 原点 | 左上角 (0, 0) |
| X 轴方向 | 向右为正 |
| Y 轴方向 | 向下为正 |
| 旋转符号 | -1 (顺时针为正) |
| 旋转零轴 | [1, 0] (右方向为 0°) |
| 锚点 | [0.5, 0.5] (元素中心) |
| 单位 | 像素 (绝对坐标) |
| 矩阵存储 | Column-major |
| Z 间距 | 0.001 |

---

## 11. 颜色格式

统一使用 `#AARRGGBB` (Alpha 在前):
- `#ff000000` = 不透明白
- `#00000000` = 全透明黑
- `#ffffffff` = 不透明白

---

## 12. 序列化顺序

导出时 XML 序列化需注意:

1. **Scene 根属性**按上述 schema 的顺序
2. **Media 声明**在图层之前
3. **图层按 z-order** 从下到上排列
4. **每个图层内部**: 属性 → transform → content/fillColor → effects → properties
5. **EmbedScene 递归**: 嵌套的 scene 也是完整的 `<scene>` 元素
6. **关键帧按时间排序** (t 值从小到大)

---

## 13. 解析容错规则

- 所有缺失属性使用默认值 (永远不会因缺字段 crash)
- 未知效果/图层类型被跳过但不阻止加载
- 数值解析失败 → 使用 0/默认值
- vec2 单值自动填充 `[v, v]`
- vec3 双值自动补充 `z=0`
- vec3 单值自动填充 `[v, v, v]`

## 14. 真实数据观测 (来自 Android AMX 导出)

### 14.1 XML 声明
```xml
<?xml version='1.0' encoding='UTF-8' ?>
<!--
Created by Alight Motion (http://alightmotion.com)
Exported: 2018-05-22 08:56 PM
DEV (0001) DEBUG
-->
```

### 14.2 属性省略
真实导出文件通常省略默认值属性:
- 不写 `exportWidth`/`exportHeight`/`amver`/`retime`/`precompose` (使用默认值)
- transform 的子元素如果值为默认,也常省略 (如只有 location + scale,不写 rotation/pivot/opacity)

### 14.3 `tag` 属性 (Android 特有)
图层可能有 `tag="green"` / `tag="red"` / `tag="blue"` 等属性,这是 Android 版的图层分组标签。iOS 版可能不使用,但解析时应忽略未知属性。

### 14.4 关键帧时间
- 关键帧 `t` 值的单位在 Android 导出中是**秒** (参见 §6.1 注释)
- 关键帧可以不按时间顺序排列在 XML 中,解析器需要排序
- 关键帧时间可以超出图层的 [startTime, endTime]

### 14.5 字体引用
Android 版使用 Google Fonts Provider URI:
```xml
font="Roboto Black:com.google.android.gms.fonts?name=Roboto&amp;weight=900"
```
iOS 版可能使用系统字体名或自定义格式。

### 14.6 科学计数法
关键帧时间可以使用科学计数法: `t="9.980627E-4"` (= 0.000998s)

### 14.7 路径数据
形状的 `<path d="..." />` 使用标准 SVG path 语法,坐标是相对于形状本地的像素坐标。
