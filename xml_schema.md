# XML Schema 速查表

## 完整 XML 模板

```xml
<?xml version="1.0" encoding="UTF-8"?>
<scene title="My Project" width="1280" height="720"
       exportWidth="1280" exportHeight="720"
       fps="60" totalTime="5000" bgcolor="#ff000000"
       amver="0" retime="" precompose="">

    <!-- Media declarations -->
    <media uri="file:///storage/emulated/0/video.mp4"
           filename="video.mp4" type="video"
           width="1920" height="1080" size="1048576" sig="abc123" />
    <media uri="amproj:embedded.png"
           filename="embedded.png" type="image"
           width="512" height="512" size="65536" sig="" />

    <!-- ===== 图层 ===== -->

    <!-- 形状图层 -->
    <shape id="1" label="Rectangle" startTime="0" endTime="5000"
           parent="0" fillType="color" fillImage=""
           s="rect" blending="normal" hidden="false" speed="1.0">
        <transform lockAspectRatio="false">
            <location value="640,360,0" />
            <pivot value="100,50" />
            <rotation value="0" />
            <scale value="1.0,1.0" />
            <opacity value="1.0" />
        </transform>
        <fillColor value="#ffffffff" />
        <path-stroke direction="center" cap="round" join="round" end-size="0">
            <color value="#ff000000" />
            <size value="5.0" />
        </path-stroke>
        <effect id="com.alightcreative.effects.transform2" locallyApplied="false">
            <property name="x" type="float" value="0">
                <kf t="0" v="0" />
                <kf t="2500" v="100" e="cubicBezier 0.0 0.0 0.58 1.0" />
                <kf t="5000" v="0" />
            </property>
        </effect>
        <property name="customParam" type="float" value="1.0">
            <kf t="0" v="1.0" />
            <kf t="5000" v="0.5" />
        </property>
    </shape>

    <!-- 文本图层 -->
    <text id="2" label="Title" startTime="0" endTime="5000"
          parent="0" hidden="false" fillType="color"
          font="Arial" size="48" wrapWidth="800" align="center">
        <transform lockAspectRatio="false">
            <location value="640,100,1" />
            <pivot value="200,24" />
            <rotation value="0" />
            <scale value="1.0,1.0" />
            <opacity value="1.0" />
        </transform>
        <content>Hello World</content>
        <fillColor value="#ffffffff" />
    </text>

    <!-- 图片图层 -->
    <image id="3" label="Photo" startTime="0" endTime="5000"
           parent="0" hidden="false" fillType="fit"
           fillImage="amproj:photo.png">
        <transform>
            <location value="640,360,2" />
            <pivot value="256,256" />
            <rotation value="0" />
            <scale value="1.0,1.0" />
            <opacity value="1.0" />
        </transform>
    </image>

    <!-- 空对象 -->
    <nullobj id="4" label="Controller" startTime="0" endTime="5000"
             parent="0" hidden="false" type="null">
        <transform>
            <location value="0,0,3" />
            <pivot value="0,0" />
            <rotation value="0" />
            <scale value="1.0,1.0" />
            <opacity value="1.0" />
        </transform>
    </nullobj>

    <!-- 嵌套场景 -->
    <embedScene id="5" label="Precomp" startTime="0" endTime="5000"
                parent="0" hidden="false" fillType="color"
                inTime="0" outTime="5000" speed="1.0" blending="normal">
        <transform>
            <location value="640,360,4" />
            <pivot value="640,360" />
            <rotation value="0" />
            <scale value="1.0,1.0" />
            <opacity value="1.0" />
        </transform>
        <scene title="Nested" width="1280" height="720" bgcolor="#00000000">
            <shape id="101" label="Nested Shape" ... />
        </scene>
    </embedScene>

    <!-- 书签 -->
    <bookmark id="6" label="Beat Drop" startTime="2000" endTime="2000" />

</scene>
```

## 元素标签速查

| Rust 枚举 | XML 标签 | 说明 |
|-----------|----------|------|
| `Shape` | `<shape>` | 形状图层 |
| `Text` | `<text>` | 文本图层 |
| `Image` | `<image>` | 图片图层 |
| `Video` | `<video>` | 视频图层 |
| `Audio` | `<audio>` | 音频图层 |
| `Camera` | `<camera>` | 相机图层 |
| `NullObj` | `<nullobj>` | 空对象 |
| `EmbedScene` | `<embedScene>` | 嵌套场景 |
| `Bookmark` | `<bookmark>` | 书签 |

## 常用子元素标签

| 标签 | 所属图层 | 说明 |
|------|----------|------|
| `<transform>` | 所有图层 (除 bookmark) | 变换 |
| `<location>` | transform | 位置 |
| `<pivot>` | transform | 锚点 |
| `<rotation>` | transform | 旋转 |
| `<scale>` | transform | 缩放 |
| `<opacity>` | transform | 不透明度 |
| `<fillColor>` | shape, text, embedScene | 填充色 |
| `<path-stroke>` | shape | 路径描边 |
| `<border>` | shape | 边框 |
| `<gradient>` | shape, embedScene | 渐变 |
| `<path>` | shape | SVG 路径 |
| `<content>` | text | 文本内容 |
| `<effect>` | shape, text, image, nullobj, video, embedScene | 效果 |
| `<property>` | effect, layer | 属性/参数 |
| `<kf>` | animated 元素 | 关键帧 |
| `<fov>` | camera | 视场角 |
| `<media>` | scene | 媒体声明 |
| `<scene>` | scene, embedScene | 场景 |

## 属性名序列化规则

XML 属性名使用 camelCase:
- Rust `start_time` → XML `startTime`
- Rust `lock_aspect_ratio` → XML `lockAspectRatio`
- Rust `fill_type` → XML `fillType`
- Rust `start_color` → XML `startColor`
- Rust `end_size` → XML `end-size` (连字符, 非 camelCase!)

## 枚举值

### fillType
- `color` — 纯色填充
- `image` — 图片填充
- `video` — 视频填充
- `fit` / `fill` / `stretch` — 填充模式

### blending
- `normal` — 正常
- `multiply` — 正片叠底
- `screen` — 滤色
- `overlay` — 叠加
- ...

### 形状类型 (s 属性)
- `rect` — 矩形
- `ellipse` — 椭圆
- `polygon` — 多边形
- `star` — 星形
- `path` — 自定义路径

### 描边属性
- direction: `inside`, `center`, `outside`
- cap: `butt`, `round`, `square`
- join: `miter`, `round`, `bevel`

### 文本对齐 (align)
- `left`, `center`, `right`
