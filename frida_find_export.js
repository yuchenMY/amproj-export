/**
 * Frida 脚本 — 追踪 AM iOS 的项目导出功能
 *
 * 用法: frida -U -l frida_find_export.js AlightMotion
 *
 * 目标:
 * 1. 找到 XML 导出代码路径
 * 2. 捕获导出数据
 * 3. 理解 scene 数据模型
 */

// ========== Part 1: 搜索导出相关方法 ==========
console.log('\n=== Part 1: Scanning for export/xml/save methods ===');
var exportMethods = [];

for (var className in ObjC.classes) {
    try {
        var cls = ObjC.classes[className];
        var methods = cls.$ownMethods;
        for (var i = 0; i < methods.length; i++) {
            var m = methods[i];
            var lower = m.toLowerCase();
            if (lower.indexOf('export') !== -1 ||
                lower.indexOf('saveproject') !== -1 ||
                lower.indexOf('writescene') !== -1 ||
                lower.indexOf('packagescene') !== -1 ||
                lower.indexOf('serialize') !== -1 ||
                lower.indexOf('xmlstring') !== -1 ||
                lower.indexOf('amproj') !== -1) {
                exportMethods.push({cls: className, method: m});
            }
        }
    } catch(e) {}
}

exportMethods.forEach(function(e) {
    console.log('  [' + e.cls + ' ' + e.method + ']');
});
console.log('Found ' + exportMethods.length + ' potential export methods\n');

// ========== Part 2: 搜索 Scene/Layer 数据模型 ==========
console.log('=== Part 2: Scanning for Scene/Layer/Project model classes ===');
var modelClasses = [];

for (var className in ObjC.classes) {
    var lower = className.toLowerCase();
    if (lower.indexOf('amscene') !== -1 ||
        lower.indexOf('amlayer') !== -1 ||
        lower.indexOf('amproject') !== -1 ||
        lower.indexOf('amdocument') !== -1 ||
        lower.indexOf('amcomposition') !== -1 ||
        lower.indexOf('ameffect') !== -1 ||
        lower.indexOf('amkeyframe') !== -1 ||
        lower.indexOf('amtransform') !== -1 ||
        (lower.indexOf('scene') !== -1 && lower.indexOf('kit') === -1) ||
        (lower.indexOf('layer') !== -1 && lower.indexOf('av') === -1 &&
         lower.indexOf('ca') === -1 && lower.indexOf('ui') === -1)) {
        modelClasses.push(className);
    }
}

modelClasses.forEach(function(c) {
    console.log('  ' + c);
    try {
        var props = ObjC.classes[c].$ownMethods;
        for (var i = 0; i < Math.min(props.length, 10); i++) {
            console.log('    ' + props[i]);
        }
    } catch(e) {}
});
console.log('Found ' + modelClasses.length + ' potential model classes\n');

// ========== Part 3: Hook NSXMLParser 捕获 XML 读写 ==========
console.log('=== Part 3: Hooking NSXMLParser for .amproj XML capture ===');

if (ObjC.classes.NSXMLParser) {
    var NSXMLParser = ObjC.classes.NSXMLParser;

    // Hook initWithData (reading .amproj)
    var initMethods = ['- initWithData:', '- initWithContentsOfURL:'];
    initMethods.forEach(function(methodName) {
        var method = NSXMLParser[methodName];
        if (method) {
            Interceptor.attach(method.implementation, {
                onEnter: function(args) {
                    this.parser = new ObjC.Object(args[0]);
                    if (methodName.indexOf('Data') !== -1) {
                        var data = new ObjC.Object(args[2]);
                        console.log('[NSXMLParser ' + methodName + '] size=' + data.length());
                    }
                },
                onLeave: function(retval) {
                    console.log('[NSXMLParser] parser created: ' + this.parser);
                }
            });
        }
    });
}

// ========== Part 4: Hook NSData writeToFile 捕获文件写入 ==========
console.log('=== Part 4: Hooking file writes to capture export ===');

if (ObjC.classes.NSData) {
    var writeToFile = ObjC.classes.NSData['- writeToFile:atomically:'];
    if (writeToFile) {
        Interceptor.attach(writeToFile.implementation, {
            onEnter: function(args) {
                var path = new ObjC.Object(args[2]).toString();
                var data = new ObjC.Object(args[0]);
                if (path.indexOf('.xml') !== -1 ||
                    path.indexOf('.amproj') !== -1 ||
                    path.indexOf('scene') !== -1 ||
                    path.indexOf('export') !== -1 ||
                    path.indexOf('project') !== -1) {
                    console.log('[NSData writeToFile] path=' + path + ' size=' + data.length());
                    // Print first 500 bytes of XML
                    try {
                        var str = data.bytes().readUtf8String(Math.min(data.length(), 500));
                        console.log('[EXPORT DATA] ' + str);
                    } catch(e) {}
                }
            }
        });
    }
}

// ========== Part 5: Hook UIDocumentPickerViewController ==========
console.log('=== Part 5: Hooking document picker for export ===');

if (ObjC.classes.UIDocumentPickerViewController) {
    // Try to find export-related init methods
    var methods = ObjC.classes.UIDocumentPickerViewController.$ownMethods;
    console.log('UIDocumentPickerViewController methods:');
    methods.forEach(function(m) { console.log('  ' + m); });
}

// ========== Part 6: Hook NSFileManager for file creation ==========
console.log('=== Part 6: Hooking file manager for .amproj creation ===');

if (ObjC.classes.NSFileManager) {
    var createFile = ObjC.classes.NSFileManager['- createFileAtPath:contents:attributes:'];
    if (createFile) {
        Interceptor.attach(createFile.implementation, {
            onEnter: function(args) {
                var path = new ObjC.Object(args[2]).toString();
                if (path.indexOf('.xml') !== -1 ||
                    path.indexOf('.amproj') !== -1 ||
                    path.indexOf('scene') !== -1) {
                    var data = new ObjC.Object(args[3]);
                    console.log('[NSFileManager createFile] path=' + path + ' size=' + (data ? data.length() : 0));
                }
            }
        });
    }
}

console.log('\n=== All hooks installed. Interact with the app to trigger exports ===');
