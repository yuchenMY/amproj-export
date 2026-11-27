# 应用内更新与网站设备签名

复用 `am.ayakameow.cn` 的 `devices`、签名材料选择、`sign_jobs`、zsign 和 OTA 下载路由。正常更新限定当前设备、渠道、Bundle ID 和签名 Team；网站给同一设备绑定的 P12/profile 继续用于签名。私钥、P12 密码不下发给 App。

## 客户端流程

- r176 起支持应用内更新。网站签名时，在主应用 Info.plist 写入设备限定的 HMAC 更新授权，并在签名后检查授权仍在安装包中。源 IPA 不修改。
- 网站安装的新版本直接使用授权。手动自签的新版本通过 App 内设备登记页面，沿用网站已有设备授权完成一次关联；本机 Team/Bundle 与网站签名材料不一致时停止覆盖更新。
- 关联网页只用于设备登记，内容规则阻止网页签名、安装页、OTA；原生导航也阻止网页 OTA。下载设备识别描述文件时由系统处理，完成设置后回 App 继续。
- 原生提交更新请求并轮询签名状态，准备成功后调用 `itms-services`。安装确认、随后下载及覆盖由 iOS 处理。openURL 成功仅代表请求已交给系统。
- Beta 退役单独申请正式版安装，限定 `com.ayakameow.am.beta` → `production/com.ayakameow.am`。迁移授权 15 分钟有效，不存入钥匙串；用户仍须备份、导入正式版检查后再删除 Beta。

## 服务端接入

在网站应用目录旁暂存本目录三个代码文件，运行：

```sh
node integrate.cjs /path/to/website-app /path/to/staging
node --check /path/to/staging/server.js
node --check /path/to/staging/signer.js
```

集成脚本只替换唯一、明确的源码锚点；遇到变化或重复接入会中止。应先对线上源码做 hash 记录和备份，在无活动签名任务时部署生成的 `server.js`、`signer.js`、`in-app-update.js` 并重启原服务。无需数据库迁移，不替换网站默认 IPA，不修改设备证书或最低版本策略。

新接口：

- `POST /api/app-update/link`：凭网站已完成的随机设备会话，关联当前安装身份。
- `POST /api/app-update/prepare`：Bearer 更新授权 + 客户端固定 requestId，返回原有签名任务/OTA 地址。请求失败重试可继续原任务。
- `POST /api/app-update/ready`：系统安装前重新核对应用库的当前包、设备授权和签名文件；包被替换或删除就停止旧任务的安装入口。

签名器按 job ID 去重；启动时恢复 queued，已被重启中断的 running 标为失败并明确要求重试。审计暂时失败不阻断入队。

网站默认包必须是带正确 `AMProjReleaseCode`、`AMProjReleaseChannel` 的新版本。正式版和 Beta 分别发布，正常更新不会因为设备拥有 Beta 资格而切换安装渠道。当前没有新包时，App 明确显示未发布或无需更新，不创建任务。

## IPA 应用库同步

`integrate-library.cjs WEBSITE_DIRECTORY STAGING_DIRECTORY` 在已接入更新模块的网站上应用第二阶段小补丁：同渠道上传成功就成为当前版本，原包留在历史列表；删除当前版本不会自动启用旧包。管理员仍可主动把历史包设为当前。客户端每次准备和系统安装前都读取此库，不维护另一份包列表；删除包及其签名文件沿用原有事务和清理逻辑。已有活动签名任务时删除仍返回明确的等待提示。

`fixtures/library-routes-before.js` 由已核验的实际网站源码提取。`library.test.cjs` 对补丁后的真实上传/删除处理器执行 HTTP 行为测试，数据库使用替身，不等价真实 MySQL 并发验收。

## 验证边界

`integrate-registration.cjs SOURCE_APP_JS STAGED_APP_JS` 为现网登记页面增加 Safari 备用复制入口。链接始终复用当前页面已有的 48 位请求 token，安装描述文件后仍由原状态接口确认完成；不通过手填 UDID 跳过授权。剪贴板受限时保留可选中的链接，完成登记后移除备用入口。部署只替换核验和备份后的 `public/app.js`，无需更换 IPA。

`udid-handoff.test.cjs` 验证复制与手动选择、轮询不重复创建、完成后移除及源码锚点；这些不等价 Safari 描述文件下载和实机安装验收。

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

测试执行真实 HTTP 路由、授权校验和 ZIP 元数据处理，数据库和证书资格检查使用替身；不生成真实用户签名任务，也不等价 MySQL 并发、zsign 或实机安装验收。CI 另执行原生 Foundation 策略测试并编译 iOS dylib。

发布前仍需实机确认：首次描述文件登记返回 App、网站签名安装授权自动读取、更新签名完成、系统安装确认、同 Bundle 覆盖后工程保留。不要仅凭 openURL 回调宣称安装成功。
