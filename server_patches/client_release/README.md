# iOS 发布版本策略

服务端新增 `client_release.go`，三个集成差异在 `integration.patch`。
基于 2026-11-26 正在运行的 `/www/afhub/source`，不是历史快照。

基线 SHA-256：

- main.go: `00ddfac7657f2d1fba219b6656e7251b4b05db66aac46e9d2dea26a476571fac`
- admin_system_template.go: `080ad61db060eda5703f5ae0d44579f23f8e24bb1ab301046c8bbba874b3dd4f`
- support.go: `b7d952e656bf1be0d0042ee1c69782ed11aca9f351f66fb542fc1f757c90dd9e`

管理入口 `/admin/client-releases`，位于系统管理导航。沿用管理员登录、system 权限和 CSRF；修改仅限 super。
策略持久化到现有 `system_config` 的 `ios_client_release_policy_v1`，无需建表。
没有配置行时所有限制关闭。部署不创建或启用策略。保存使用事务行锁和 revision 检查，支持影响预览和撤回全部限制。

正式版和 Beta 独立设置最新编号、最低编号、北京时间生效时间、HTTPS 安装入口和说明。
编号对应客户端实际编译的 r 编号，不使用宿主固定的 6.2.58 / 865。
Beta 还可选择结束全部测试。迁移顺序为：导出工程、安装正式版、逐个导入检查、最后删除 Beta。
更新页保留备份入口，每个工程生成独立可恢复的 AMPROJ；找不到本地素材时明确失败，不提示完整备份成功。
外部链接资源不包含在本地备份中。应用和本机工程不会被自动删除。

`GET /api/ios/client-release` 无需登录，独立于维护和会员授权。
客户端异步检查，已知有效策略缓存供离线重启使用；首次读取失败不产生新限制。页面只在已确认的浏览页展示，编辑、导出和分享期间不覆盖操作。
撤回后联网检查更新策略；离线设备要恢复联网才能取得撤回。

服务端仅对 iOS 授权、插件和云端接口返回 HTTP 426；登录、工单、策略读取仍可访问。
现有未接入策略的旧包无法远程增加更新页面或禁用其离线功能。
“限制没有版本信息的旧客户端”默认关闭，只限制旧包的已有联网功能，并可能同时影响无法区分渠道的旧 Beta。
工单与用户回复自动追加客户端 r 编号、渠道和提交标识；未上报的 iOS 请求明确标注旧包可能性。

客户端元数据由打包器读取 dylib 的 `AMCLIENT_RELEASE` 标记后写入 Info.plist，网页请求也使用该实际元数据。
每次发布须递增 Makefile 的 `RELEASE_CODE`，无需为提示更新和最低版本使用相同编号。

验证：将模块、测试和集成补丁放入真实 Go 源码，运行 `go test -race -run '^TestClientRelease' -count=1 -v .` 和 `go build .`。
可设置 `AM_RELEASE_TEST_CONFIG` 为服务端配置路径，运行真实 SQL 保存/并发冲突/撤回测试。测试只在专用连接创建同名 TEMPORARY TABLE，遮蔽真实表，绝不写入线上策略。
客户端 `tests/test_client_release.py` 在 macOS 执行真实缓存文件往返及两个工程独立打包、导入、素材字节验证；Windows 执行元数据和实际网页脚本测试。

部署前须核对基线哈希，备份原二进制与三份源文件，候选目录完成验证后原子替换并重启 afhub。公共接口应返回 enabled=false，后台入口应要求登录。失败立即还原二进制和源文件。
