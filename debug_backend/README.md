# AMProj Debug Backend

## Dynamic LAN discovery

Debug IPA keeps the injected `BaseURL` as the fast path. If the Windows WLAN
address changes, the iOS transport discovers the backend over authenticated
UDP and then verifies it through the normal `POST /api/v1/hello` request.
Discovery uses the same numeric port as HTTP by default (`8765`), but UDP and
TCP are separate listeners. The Bearer token is used only as an HMAC key and is
never sent in a discovery packet.

Windows Firewall must allow Python on the private network for both TCP and UDP
port `8765`. Start the backend with the exact token embedded by the injector:

```powershell
python .\debug_backend\server.py --token "<injector-generated-token>"
```

Use `--discovery-port <port>` only when the IPA was injected with the matching
port. `--no-discovery` disables the UDP listener. Discovery failure never
blocks export or import; telemetry remains queued in memory for a later retry.

Windows 本地调试后端，仅依赖 Python 标准库。HTTP API 对回环和私有局域网开放；Dashboard 和控制写入仅允许本机访问。

## 启动

后端与调试 IPA 必须使用同一个 Bearer token：

```powershell
python .\debug_backend\server.py --token "<injector-generated-token>"
```

然后打开 `http://127.0.0.1:8765`。iPhone 使用 `http://<Windows-WLAN-IP>:8765`，Windows 防火墙需要允许 Python 接收专用网络连接。

不传 `--token` 时后端会生成临时 token 并输出到终端，适合独立测试。事件保存在 `debug_backend/data/events.ndjson`，artifact 保存在 `debug_backend/data/artifacts/<session>/`。

## Device API

除 `GET /healthz` 外，请求必须携带 `Authorization: Bearer <token>`。

- `POST /api/v1/hello`：注册会话并取得当前模式。
- `POST /api/v1/events`：提交单个事件、事件数组，或 `{ "session_id": "...", "events": [...] }`。
- `GET /api/v1/events`：支持 `after_id`、`limit`、`session_id`、`type`、`level` 查询参数。
- `GET /api/v1/sessions`：列出设备会话。
- `GET /api/v1/commands?session=<id>&after=N`：设备拉取 `{commands,next_cursor}`；命令类型为 `set_mode`、`capture_next`、`flush`。
- `POST /api/v1/commands`：设备用 `{session,acknowledged:[id...]}` ACK；本机 Dashboard 可设置 `mode` 和 `capture_next`。
- `POST /api/v1/artifacts`：上传原始文件或 JSON base64，最大 32 MiB。
- `GET /api/v1/stream`：本机 Dashboard 使用的 SSE 流。

原始 artifact 上传头：

```text
Content-Type: application/octet-stream
X-AMProj-Session: <session-id>
X-AMProj-Filename: project.amproj
X-AMProj-Kind: amproj
X-AMProj-Metadata: {"stage":"zip"}
```

iOS transport 也可用 `X-AMProj-Artifact-Name-B64`（UTF-8 文件名的 Base64）、`X-AMProj-Transaction` 和 `X-AMProj-Artifact-Size`；这些头优先于旧文件名头。所有内部 transport 请求均可附加 `X-AMProj-Debug-Transport: 1`，便于 dylib 的网络观察器排除自身流量。

`capture_next` 是一次性开关：首个 artifact 成功保存后，后端自动将其复位为 `false` 并发布新配置版本。

## 测试

```powershell
python -m unittest discover -s .\debug_backend -p "test_*.py" -v
```
