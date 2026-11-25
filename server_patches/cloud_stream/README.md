# 云工程远端流式下载超时修复

应用端下载 125,383,680 字节工程时，S3 GET 每次约 30 秒被截断。
服务端日志为 `context deadline exceeded (Client.Timeout or context cancellation while reading body)`。
`openRemote` 使用的 `http.Client.Timeout` 同时限制响应头及完整 Body，原值为 30 秒。

补丁针对 `/www/afhub/source/object_storage.go`，原文件 SHA-256：
`498ea1b9e056865f102530e1f56200594dfe2a44ca3f11c831a3f55510fa73cf`。

- GET 用客户端局部副本沿用大文件传输预算，默认 900 秒。
- `upload_timeout_seconds` 现在同时控制远端上传及下载的总传输时长。
- Transport 的响应头等待仍使用 `request_timeout_seconds`；HEAD/DELETE 的短总超时保持。
- 原请求 context 的取消及总传输时限继续有效。

`object_storage.patch` 是相对该原文件的补丁；测试文件放入真实 Go 工程同包执行。
测试不访问用户数据，用本机 HTTP 流验证短预算截断、取消、响应头超时和有限传输时限。
原代码可复现截断；候选补丁通过 `go test -race -run '^TestObjectStorage' -count=1 .` 和真实工程构建。

运行和部署证据保存在工作区 `artifacts/cloud_followup_20261125/`。
