# 865 原生导入引擎静态分析证据（2026-08-31）

目标二进制：Alight Motion 6.2.58 (Build 865)，主程序 57,591,104 字节，
arm64 Mach-O（`_inspect865/Payload/AlightMotion.app/AlightMotion`）。
所有地址均为文件内 vmaddr（image base 0x100000000），可复核。

## 结论

**865 的原生项目导入是纯 Swift Concurrency 异步闭包链，其上下文捕获了
AM 云下载流程的十余个内部 Swift 对象；这些对象无法从插件侧构造。
因此 862 验证过的"直调 continuation"桥接方式不能移植到 865。**
本轮已把全部入口改接插件本地导入引擎（校验/封装/暂存/事务 UI），
原生分发一步在 865 上如实报告不可达，不伪造成功。

## 已验证事实链

1. **类存在**（ObjC 类名表）：
   - `_TtC12AlightMotion15PackageImporter`（类 RO @0x10309af28，无任何
     ObjC 方法表，instanceSize 0x28 —— 纯 Swift 类）
   - `_TtC12AlightMotion14AMFileImporter`（字体导入，与项目导入无关；
     `onTapImport:` IMP 0x100612254 属于 `_TtC12AlightMotion13FontBrowserVC`）
   - `_TtC12AlightMotion15ProjectPackager`、`ProjectsVC`、`AMProgressAlert` 同 862。

2. **Metadata accessor（静态推导，非猜测）**：通过 `__TEXT` 相对引用扫描
   定位类型描述符 @0x102c27f68（name=`PackageImporter`，parent=模块上下文），
   其 accessFunction = **0x100318d64**（862 的对应值 0x100310768，同一区域）。
   AMFileImporter 的 accessor = 0x100946688。
   accessor 序言：`a9bf7bfd 910003fd f0017c60 912ba000 9488e954 d2800001 a8c17bfd d65f03c0`。

3. **调用点**（`bl 0x100318d64`）：0x10003b204、0x10005602c、0x10026c1b4。
   0x10026c1b4 所在主函数 **0x10026c068**：
   - `swift_allocObject(metadata, 0x10, 7)` 分配 PackageImporter 实例；
   - 构建 0x50 字节闭包上下文（含 importer、下载 URL 等）；
   - 闭包函数指针 0x1002721a0（转发 thunk → 0x1002734e0）。

4. **async 导入方法 = 0x100312680**：
   - 0x100056048 处调用：x0/x1 = `ldp [x23,#0x28]`（Foundation URL 两字），
     x2 = async frame；0x10005602c 先经 accessor + `swift_initStackObject`。
   - 序言 `mov x23, x21`（保存 async executor 寄存器）、`mov x22, x8`（self/async ctx）、
     `ldr x8, [x20]`（task 头）——标准 Swift async ABI。
   - `Foundation.URL.metadataAccessor = 0x10254a834`（stub 表符号 `_URLVMa`）。

5. **swift_task_create 约定**（来自 Swift 运行时源码 Task.cpp + 51 个调用点比对）：
   `swift_task_create(flags(x0), options(x1), resultType(x2), closureEntry(x3), closureContext(x4))`。
   closureEntry 指向 `__TEXT,__const`（0x102653700..0x1028176af）中的
   AsyncFunctionPointer 结构：`+0x00 rel32→initial function`、`+0x04 u32 contextSize`
   （实测样例 0x102659450：rel→0x100065778，size 0x20，与调用点 allocObject(0x20) 吻合）。

6. **不可构造性证明**：导入任务体 0x100272ee4 是闭包析构函数，
   释放 ctx+0x18..0xe8 共 **13 个捕获对象**；调用 continuation 0x10026dd00 的
   async resume（0x100272370..0x100272400）中 x1..x7 与栈参数全部来自
   闭包 ctx 捕获（`ldp [x20+0x10]`、`ldp [x20+x12]` 等）。
   这些捕获是 AM 云下载会话的内部对象（ProjectHolder 等），无法在 ObjC 侧重建。

7. **候选 continuation 0x10026dd00**：序言与 862 已验证 continuation 逐字节同形
   （`stp x28,x27 … sub sp,#0x140`），同样 8 寄存器 + 栈参数，但 x0 未使用、
   其余参数来源是捕获对象 —— 同形而不同源，禁止直接调用。

## 运行时证据（真机 iPhone14,2 / iOS 26.1，UDID 00008110-001C25D63644801E）

- syslog 通道：`pymobiledevice3 syslog live --process-name AlightMotion`（本文档同目录
  `device_logs/`）。dylib 加载日志 `===== Loading v44-cloud =====`、
  `import.865_public_app_delegate_hooks`、`865 project flow ready (native document handoff)`。
- 沙盒（house_arrest AFC）：`Library/Application Support/` 下**不存在**
  `AMProjV865ProjectHandoff/` —— 865 handoff 暂存从未在真机上发生过；
  `AMProjImports/last-import.plist` 记录的历史失败：
  `source=native_package_picker_local, phase=failed, native_status=5,
  error="This native importer only supports Alight Motion 6.2.55 (862)"`。

## 本轮已落地的路由改造（commit 见 git log）

- `amproj_runtimeUsesLocalImportEngine()` = 862(带桥) 或 865；导入引擎（校验、
  XML 封装、暂存、事务 UI、breadcrumb）对 865 开放。
- `hooked_applicationOpenURL` / `handleOpenURL` / `legacyOpenURL` /
  `continueUserActivity` / Scene 回调：865 的项目文件被
  `amproj_captureSystemProjectURL` 消费进引擎，**不再转发原版链路**。
- 冷启动：`amproj_launchOptionsForNativeAppDelegate` 对 865 同样剔除项目 URL；
  延迟候选统一走 `AMProjImports/Launch-<UUID>` 缓存 + 引擎重放。
- 应用内/AM 自带选择器：`installNativeProjectPickerHook` +
  `attachNativeXMLPickerProxy` + `routeNativeProjectPicker` 对 865 开放。
- 云工程下载（AMCloudSyncInstallAsync → `amproj_importCloudPackage`）：
  865 分支直接进引擎，openURL handoff 移除。
- 865 分发终点：`amproj_nativePackageImportStarter == nil` 时立即诚实终态
  （`import.865_native_importer_unreachable` breadcrumb + 保留缓存包 + 重试/选择文件），
  不再等待 90 秒超时，不伪装导入成功。
- `AMProjV865ProjectFlow` 的 handoff 暂存在引擎构建上被跳过
  （`import.865_public_stage_skipped_for_engine`），避免大文件双拷贝。

## 下一轮可选路径（若必须打通 865 原生写入）

按 `swift_task_create` + AFP 复刻 AM 自己的发射方式，需要先用真机日志钉住
`0x100312680` 所在闭包链的捕获来源（AM 云模板下载完成回调），再决定是否
值得做。静态侧已排除"直调 continuation"捷径。
