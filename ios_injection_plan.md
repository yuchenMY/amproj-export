# iOS 端 .amproj 导出注入方案

## 背景

AM iOS 客户端**原生已支持读取** .amproj 文件 (ZIP → XML → 场景图)。

**重要发现**: iOS 版**已有 XML 导出图标** (`ic_export_xml`)! 这意味着导出功能可能:
- 已经被实现但被 UI 隐藏
- 导出的是纯 XML 而非 .amproj ZIP
- 或者功能未完成

目标: 找到并激活/补全这个导出功能,输出完整的 .amproj ZIP 文件。

## 核心思路

Android 版的导出流程 (从 native lib 逆向):
1. **序列化当前场景** → 生成 XML 字符串 (遵循 `format_spec.md` 的 schema)
2. **收集嵌入资源** → 项目中引用的图片/字体 → 二进制数据
3. **ZIP 打包** → 标准 ZIP (deflate) → 写入 `.amproj` 文件

iOS 端需要实现同样的三步。

## 方案 A: 纯 ObjC/Swift 实现 (推荐)

### 优点
- 无需 native 库依赖
- 可以直接使用 Foundation 的 XML/File/ZIP 能力
- 容易调试和迭代

### 实现要点

#### 1. ZIP 打包
iOS 上 ZIP 创建可使用:
- **Objective-Zip** / **ZipArchive** (SSZipArchive) — 第三方库
- **libcompression** (`compression_encode_buffer`) + 手写 ZIP header — 更轻量
- Foundation 没有原生 ZIP 创建 API,需要第三方或手写

推荐: 使用 **minizip** (zlib 自带) 或简单的 ZIP writer (~200行纯 C)

ZIP 结构很简单: 
```
[local file header 1][file data 1][local file header 2][file data 2]...[central directory][end of central directory]
```

#### 2. XML 序列化

iOS 可以:
- 手写 XML builder (简单字符串拼接,因为 schema 固定)
- 或使用 `NSXMLDocument` / `XMLDocument`

推荐手写,因为:
- Schema 固定,拼接字符串最快
- 可以精确控制属性顺序和格式
- 不依赖 XML 库

#### 3. 关键: 从 AM runtime 提取场景数据

需要找到 AM iOS native 层暴露的接口:
- `-[AMScene currentScene]` 或类似
- 遍历图层树: layers → transform → keyframes → effects → properties
- 这需要 reverse AM iOS binary (已有一部分工作,见 memory)

**可能的注入点:**
- 导出按钮 (UI 层面 hook `UIViewController` 或 `UIAlertAction`)
- 或在 AMDocument 层面添加 save 方法

#### 4. 伪代码结构

```objc
// AMPackageExporter.h
@interface AMPackageExporter : NSObject
+ (NSData *)exportProjectAsAmproj:(AMScene *)scene;
@end

// AMPackageExporter.m
@implementation AMPackageExporter

+ (NSData *)exportProjectAsAmproj:(AMScene *)scene {
    // Step 1: Serialize scene to XML
    NSString *xml = [AMXmlSerializer serializeScene:scene];
    NSData *xmlData = [xml dataUsingEncoding:NSUTF8StringEncoding];
    
    // Step 2: Collect embedded resources
    NSDictionary<NSString*, NSData*> *resources = [self collectResources:scene];
    
    // Step 3: Create ZIP
    NSMutableData *zipData = [NSMutableData data];
    [self addFileToZip:zipData name:@"scene.xml" data:xmlData];
    for (NSString *name in resources) {
        [self addFileToZip:zipData name:name data:resources[name]];
    }
    
    // Step 4: Finalize ZIP (write central directory + EOCD)
    [self finalizeZip:zipData];
    
    return zipData;
}

@end
```

## 方案 B: 移植 Android native 代码

### 思路
1. 从 Android `libalight-native-lib.so` 提取序列化函数
2. 编译为 iOS arm64 `.a` / `.dylib`
3. 从 ObjC 通过 JNI-like bridge 调用

### 缺点
- Android native lib 混淆严重 (360加固)
- JNI 调用风格 vs iOS ObjC 调用,需要大量适配
- 效果参数未知,可能不完整
- 不推荐

## 方案 C: 基于开源 `amproj` Rust crate 构建

### 思路
1. 使用 Rust crate `amproj` (已完整逆向 schema)
2. 扩展其序列化能力 (目前只支持 deserialize)
3. 编译为 iOS universal binary (`.a`)
4. 通过 C-ABI 从 ObjC/Swift 调用

### 优点
- `amproj` crate 已有完整的 schema 定义
- Rust → C-ABI → ObjC bridge 成熟
- 代码可维护

### 实现

Rust 侧:
```rust
// 在 amproj crate 添加 serialize 功能
#[no_mangle]
pub extern "C" fn amproj_export(project_json: *const c_char) -> *mut c_char {
    let scene: AmScene = serde_json::from_str(&json_str).unwrap();
    let xml = serialize_scene_to_xml(&scene);
    let zip_data = create_amproj_zip(&xml, &resources);
    // return base64 encoded zip data or file path
}

// 序列化函数 (需补充到 amproj)
pub fn serialize_scene_to_xml(scene: &AmScene) -> String { ... }
pub fn create_amproj_zip(xml: &str, resources: &HashMap<String, Vec<u8>>) -> Vec<u8> { ... }
```

ObjC 侧:
```objc
// 调用 Rust C-ABI 函数
NSString *json = [self serializeSceneToJSON];
const char *result = amproj_export([json UTF8String]);
NSData *zipData = /* decode base64 or read file */;
```

## 推荐路径

**方案 A (纯 ObjC/Swift) + 方案 C (Rust crate schema 参考)**

1. 用 `amproj` crate 的 schema 作为规范 (已有完整的类型定义)
2. 在 iOS 端用 ObjC/Swift 实现:
   - XML serializer (轻量, 几百行) — 参考 `xml_schema.md`
   - ZIP creator (minizip 或手写)
3. 通过 Frida/Cycript 在越狱设备上 hook AM 的 export 方法找到数据源
4. 在 UI 层注入导出按钮,或在现有 `ic_export_xml` 路径上添加 ZIP 打包

## 第一步: 运行时追踪 (Frida)

需要在越狱设备上运行,找到 XML 导出的实际代码路径:

```javascript
// frida -U -l find_export.js AlightMotion

// 1. 搜索所有包含 export/xml/save 的 ObjC 方法
var methods = [];
for (var className in ObjC.classes) {
    try {
        var ownMethods = ObjC.classes[className].$ownMethods;
        for (var i = 0; i < ownMethods.length; i++) {
            var m = ownMethods[i];
            if (m.toLowerCase().indexOf('export') !== -1 ||
                m.toLowerCase().indexOf('xml') !== -1 ||
                m.toLowerCase().indexOf('saveproject') !== -1 ||
                m.toLowerCase().indexOf('package') !== -1) {
                methods.push(className + ' ' + m);
            }
        }
    } catch(e) {}
}
console.log('Export/XML methods:');
methods.forEach(function(m) { console.log('  ' + m); });

// 2. Hook UIDocumentPickerViewController to capture file exports
var UIDocumentPickerViewController = ObjC.classes.UIDocumentPickerViewController;
if (UIDocumentPickerViewController) {
    // Hook init methods to see what file types are used
}

// 3. Hook NSXMLParser to capture XML parsing
var NSXMLParser = ObjC.classes.NSXMLParser;
if (NSXMLParser) {
    var initWithData = NSXMLParser['- initWithData:'];
    Interceptor.attach(initWithData.implementation, {
        onEnter: function(args) {
            var data = new ObjC.Object(args[2]);
            console.log('[NSXMLParser] Parsing XML, length=' + data.length());
            // Save the XML for analysis
            var xml = data.bytes().readUtf8String(data.length());
            console.log('[NSXMLParser] XML start: ' + xml.substring(0, 500));
        }
    });
}
```

## 第二步: 验证现有 XML 导出

检查 `ic_export_xml` 按钮点击后的行为:
1. 是否弹出 UIDocumentPickerViewController?
2. 导出的文件是纯 XML 还是 .amproj?
3. 文件内容是否符合 `format_spec.md` 的 schema?

如果 iOS 已能输出 XML,只需在导出路径上添加 ZIP 打包即可得到 .amproj。

## 第三步: 注入策略

### 策略 A: 包装现有 XML 导出 (如果已有)
```objc
// Hook 现有的 XML 导出方法
// 1. 拦截输出 NSData (XML)
// 2. 收集项目中嵌入的图片/字体
// 3. 创建 ZIP: [scene.xml + resources]
// 4. 输出 .amproj 文件
```

### 策略 B: 从头实现 (如果无导出)
1. 逆向找到 scene 数据模型类
2. 遍历图层树提取数据
3. 按 `xml_schema.md` 序列化为 XML
4. ZIP 打包 → .amproj

## 需要逆向的 AM iOS 接口

| 目标 | 说明 |
|------|------|
| Scene 根对象 | 当前编辑场景的入口点 |
| Layer 列表 | 遍历 z-order 的图层树 |
| Layer properties | id/label/startTime/endTime/parent/hidden |
| Transform | location/pivot/rotation/scale/opacity 当前值 + 关键帧 |
| Fill/Stroke | 填充色、描边参数 |
| Effects | 已应用的效果列表,每个效果的属性+关键帧 |
| Media references | 项目中引用的图片/视频 URI |
| Embedded resources | 项目内嵌的图片/字体二进制数据 |
| Nesting | 预合成/嵌套场景的递归结构 |

## 注入方式

1. **Frida/Cycript 动态注入**: 调试阶段用,验证数据提取逻辑
2. **Theos/Tweak**: 最终分发用,注入到 AlightMotion.app
3. **Mach-O 补丁**: 单字节修改现有导出逻辑 (如果有),参考 `am-mod-patch-style`

## 文件保存位置

导出后 `.amproj` 文件应保存到:
- iOS 文件 App 可见位置: `NSFileManager` → Documents 或 tmp
- 或通过 `UIActivityViewController` 分享
- 或通过 iTunes File Sharing 暴露
