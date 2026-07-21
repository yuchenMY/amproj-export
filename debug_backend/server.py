#!/usr/bin/env python3
"""Local telemetry and control server for AMProjExportDebug.

The HTTP listener is reachable from the private LAN so an iPhone can post
telemetry. Dashboard assets are served only to loopback clients.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import mimetypes
import os
import re
import secrets
import signal
import socketserver
import sys
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


PROTOCOL_VERSION = 1
MODES = frozenset(("observe", "placeholder", "full"))
MAX_JSON_BYTES = 2 * 1024 * 1024
DEFAULT_MAX_ARTIFACT_BYTES = 32 * 1024 * 1024
MAX_IN_MEMORY_EVENTS = 10_000
MAX_STREAM_UPDATES = 2_000
SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._-]+")
DISCOVERY_PROTOCOL_VERSION = 1
MAX_DISCOVERY_PACKET_BYTES = 512
DISCOVERY_NONCE_RE = re.compile(r"[0-9a-f]{32}")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def safe_component(value: Any, fallback: str) -> str:
    cleaned = SAFE_NAME_RE.sub("_", str(value or "")).strip("._")
    return cleaned[:120] or fallback


def discovery_proof(token: str, purpose: str, nonce: str, port: int | None = None) -> str:
    fields = [purpose, str(DISCOVERY_PROTOCOL_VERSION), nonce]
    if port is not None:
        fields.append(str(port))
    digest = hmac.new(token.encode("utf-8"), ":".join(fields).encode("ascii"), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def parse_discovery_probe(data: bytes, token: str) -> str | None:
    if not data or len(data) > MAX_DISCOVERY_PACKET_BYTES:
        return None
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or set(payload) != {"type", "version", "nonce", "proof"}:
        return None
    nonce = payload.get("nonce")
    proof = payload.get("proof")
    if (
        payload.get("type") != "amproj-discover"
        or type(payload.get("version")) is not int
        or payload["version"] != DISCOVERY_PROTOCOL_VERSION
        or not isinstance(nonce, str)
        or DISCOVERY_NONCE_RE.fullmatch(nonce) is None
        or not isinstance(proof, str)
    ):
        return None
    expected = discovery_proof(token, "discover", nonce)
    return nonce if hmac.compare_digest(proof, expected) else None


def build_discovery_offer(nonce: str, token: str, http_port: int) -> bytes:
    payload = {
        "type": "amproj-offer",
        "version": DISCOVERY_PROTOCOL_VERSION,
        "nonce": nonce,
        "port": http_port,
        "proof": discovery_proof(token, "offer", nonce, http_port),
    }
    return json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("ascii")


def client_is_private(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private or ip.is_link_local


def event_timestamp(raw: dict[str, Any], received_at: str) -> Any:
    if raw.get("timestamp") is not None:
        return raw["timestamp"]
    milliseconds = raw.get("time_ms")
    if isinstance(milliseconds, (int, float)) and milliseconds > 0:
        try:
            return datetime.fromtimestamp(milliseconds / 1000, timezone.utc).isoformat(
                timespec="milliseconds"
            ).replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            pass
    return received_at


class ApiError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


class BackendState:
    """Thread-safe in-memory state with an append-only NDJSON journal."""

    def __init__(
        self,
        data_dir: Path,
        token: str,
        max_artifact_bytes: int = DEFAULT_MAX_ARTIFACT_BYTES,
    ) -> None:
        self.data_dir = Path(data_dir)
        self.artifact_dir = self.data_dir / "artifacts"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.artifact_dir.mkdir(parents=True, exist_ok=True)
        self.journal_path = self.data_dir / "events.ndjson"
        self.token = token
        self.max_artifact_bytes = max_artifact_bytes

        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.sessions: dict[str, dict[str, Any]] = {}
        self.events: deque[dict[str, Any]] = deque(maxlen=MAX_IN_MEMORY_EVENTS)
        self.commands: deque[dict[str, Any]] = deque(maxlen=1_000)
        self.command_acks: dict[str, set[int]] = {}
        self.stream_updates: deque[dict[str, Any]] = deque(maxlen=MAX_STREAM_UPDATES)
        self.event_id = 0
        self.stream_id = 0
        self.config: dict[str, Any] = {
            "mode": "full",
            "capture_next": False,
            "revision": 0,
            "updated_at": utc_now(),
        }

    def _append_journal_locked(self, record: dict[str, Any]) -> None:
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        with self.journal_path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(line + "\n")

    def _publish_locked(self, topic: str, data: dict[str, Any]) -> None:
        self.stream_id += 1
        update = {"stream_id": self.stream_id, "topic": topic, "data": data}
        self.stream_updates.append(update)
        self.condition.notify_all()

    def _journal_and_publish_locked(self, topic: str, record: dict[str, Any]) -> None:
        self._append_journal_locked(record)
        self._publish_locked(topic, record)

    def hello(self, payload: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        session_value = payload.get("session_id") or payload.get("session")
        if isinstance(session_value, dict):
            session_value = session_value.get("id") or session_value.get("session_id")
        device = payload.get("device") if isinstance(payload.get("device"), dict) else {}
        app = payload.get("app") if isinstance(payload.get("app"), dict) else {}
        plugin = payload.get("plugin") if isinstance(payload.get("plugin"), dict) else {}
        session_id = safe_component(session_value, uuid.uuid4().hex)
        device_id = safe_component(payload.get("device_id") or device.get("id"), "unknown-device")
        with self.lock:
            previous = self.sessions.get(session_id, {})
            session = {
                "session_id": session_id,
                "device_id": device_id,
                "connected_at": previous.get("connected_at", now),
                "last_seen": now,
                "app_version": payload.get("app_version") or app.get("version"),
                "build": payload.get("build") or app.get("build"),
                "os_version": payload.get("os_version") or device.get("os_version"),
                "device_model": payload.get("device_model") or device.get("model"),
                "plugin_version": payload.get("plugin_version") or plugin.get("version"),
                "plugin_variant": payload.get("plugin_variant") or plugin.get("variant"),
                "plugin_build_id": payload.get("plugin_build_id") or plugin.get("build_id"),
                "protocol_version": payload.get("protocol_version"),
            }
            self.sessions[session_id] = session
            record = {"record_type": "hello", "received_at": now, "session": session}
            self._journal_and_publish_locked("session", record)
            return {
                "session_id": session_id,
                "protocol_version": PROTOCOL_VERSION,
                "config": dict(self.config),
                "server_time": now,
            }

    def _touch_session_locked(self, session_id: str) -> None:
        if session_id and session_id in self.sessions:
            self.sessions[session_id]["last_seen"] = utc_now()

    def add_events(self, payload: Any) -> list[dict[str, Any]]:
        if isinstance(payload, list):
            raw_events = payload
            default_session = ""
        elif isinstance(payload, dict) and isinstance(payload.get("events"), list):
            raw_events = payload["events"]
            default_session = str(payload.get("session_id") or payload.get("session") or "")
        elif isinstance(payload, dict):
            raw_events = [payload]
            default_session = str(payload.get("session_id") or payload.get("session") or "")
        else:
            raise ApiError(HTTPStatus.BAD_REQUEST, "event payload must be an object or array")
        if not raw_events or len(raw_events) > 500:
            raise ApiError(HTTPStatus.BAD_REQUEST, "event batch must contain 1 to 500 objects")

        accepted = []
        with self.lock:
            for raw in raw_events:
                if not isinstance(raw, dict):
                    raise ApiError(HTTPStatus.BAD_REQUEST, "every event must be an object")
                self.event_id += 1
                received_at = utc_now()
                fields = raw.get("fields") if isinstance(raw.get("fields"), dict) else {}
                session_id = safe_component(
                    raw.get("session_id") or raw.get("session") or default_session, "unknown-session"
                )
                event = {
                    "id": self.event_id,
                    "session_id": session_id,
                    "type": str(raw.get("type") or raw.get("kind") or "log")[:80],
                    "level": str(raw.get("level") or fields.get("level") or "info")[:20],
                    "stage": raw.get("stage") or fields.get("stage"),
                    "message": raw.get("message") or fields.get("message") or fields.get("detail"),
                    "timestamp": event_timestamp(raw, received_at),
                    "received_at": received_at,
                    "payload": raw,
                }
                self.events.append(event)
                self._touch_session_locked(session_id)
                record = {"record_type": "event", **event}
                self._journal_and_publish_locked("event", record)
                accepted.append(event)
        return accepted

    def list_events(
        self,
        after_id: int = 0,
        limit: int = 500,
        session_id: str = "",
        event_type: str = "",
        level: str = "",
    ) -> dict[str, Any]:
        with self.lock:
            selected = [
                event
                for event in self.events
                if event["id"] > after_id
                and (not session_id or event["session_id"] == session_id)
                and (not event_type or event["type"] == event_type)
                and (not level or event["level"] == level)
            ][:limit]
            return {
                "events": selected,
                "last_id": selected[-1]["id"] if selected else after_id,
                "retained": len(self.events),
            }

    def list_sessions(self) -> dict[str, Any]:
        with self.lock:
            sessions = sorted(self.sessions.values(), key=lambda item: item["last_seen"], reverse=True)
            return {"sessions": [dict(item) for item in sessions], "server_time": utc_now()}

    def _queue_command_locked(
        self, command_type: str, fields: dict[str, Any], source: str, created_at: str
    ) -> dict[str, Any]:
        self.config["revision"] += 1
        self.config["updated_at"] = created_at
        command = {
            "record_type": "command",
            "id": self.config["revision"],
            "revision": self.config["revision"],
            "type": command_type,
            **fields,
            "mode": self.config["mode"],
            "capture_next": self.config["capture_next"],
            "source": source,
            "created_at": created_at,
        }
        self.commands.append(command)
        self._journal_and_publish_locked("command", command)
        return command

    def set_command(self, payload: dict[str, Any], source: str = "dashboard") -> dict[str, Any]:
        command_type = payload.get("type")
        if command_type == "set_export_mode":
            command_type = "set_mode"
        if command_type not in (None, "set_mode", "capture_next", "flush"):
            raise ApiError(HTTPStatus.BAD_REQUEST, "type must be set_mode, capture_next, or flush")

        requested_mode = payload.get("mode")
        capture_present = "capture_next" in payload or command_type == "capture_next"
        requested_capture = payload.get("capture_next", payload.get("enabled", True))
        if command_type == "set_mode" and requested_mode is None:
            raise ApiError(HTTPStatus.BAD_REQUEST, "set_mode requires mode")
        if requested_mode is not None and requested_mode not in MODES:
            raise ApiError(HTTPStatus.BAD_REQUEST, "mode must be observe, placeholder, or full")
        if capture_present and not isinstance(requested_capture, bool):
            raise ApiError(HTTPStatus.BAD_REQUEST, "capture_next/enabled must be a boolean")
        if command_type is None and requested_mode is None and not capture_present:
            raise ApiError(HTTPStatus.BAD_REQUEST, "command requires mode, capture_next, or type")

        queued = []
        with self.lock:
            now = utc_now()
            if requested_mode is not None:
                self.config["mode"] = requested_mode
                queued.append(self._queue_command_locked("set_mode", {"mode": requested_mode}, source, now))
            if capture_present:
                self.config["capture_next"] = requested_capture
                queued.append(
                    self._queue_command_locked(
                        "capture_next", {"enabled": requested_capture}, source, now
                    )
                )
            if command_type == "flush":
                queued.append(self._queue_command_locked("flush", {}, source, now))
            return {**self.config, "commands": [dict(item) for item in queued]}

    def get_commands(self, after_revision: int = 0, session_id: str = "") -> dict[str, Any]:
        with self.lock:
            self._touch_session_locked(session_id)
            commands = [dict(item) for item in self.commands if item["revision"] > after_revision]
            next_cursor = commands[-1]["id"] if commands else after_revision
            return {"config": dict(self.config), "commands": commands, "next_cursor": next_cursor}

    def acknowledge_commands(self, payload: dict[str, Any]) -> dict[str, Any]:
        session_id = safe_component(payload.get("session") or payload.get("session_id"), "unknown-session")
        raw_ids = payload.get("acknowledged")
        if not isinstance(raw_ids, list) or len(raw_ids) > 1_000:
            raise ApiError(HTTPStatus.BAD_REQUEST, "acknowledged must be an array of command ids")
        acknowledged = []
        for raw_id in raw_ids:
            try:
                command_id = int(raw_id)
            except (TypeError, ValueError):
                raise ApiError(HTTPStatus.BAD_REQUEST, "acknowledged contains an invalid command id")
            if command_id < 0:
                raise ApiError(HTTPStatus.BAD_REQUEST, "command ids must be non-negative")
            acknowledged.append(command_id)
        acknowledged = sorted(set(acknowledged))
        with self.lock:
            self.command_acks.setdefault(session_id, set()).update(acknowledged)
            self._touch_session_locked(session_id)
            record = {
                "record_type": "command_ack",
                "session_id": session_id,
                "acknowledged": acknowledged,
                "received_at": utc_now(),
            }
            self._journal_and_publish_locked("command_ack", record)
        return {
            "session": session_id,
            "acknowledged": acknowledged,
            "next_cursor": max(acknowledged, default=0),
        }

    def store_artifact(
        self,
        content: bytes,
        session_id: str,
        filename: str,
        kind: str,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if len(content) > self.max_artifact_bytes:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "artifact exceeds configured size limit")
        session_id = safe_component(session_id, "unknown-session")
        filename = safe_component(filename, "artifact.bin")
        kind = safe_component(kind, "artifact")
        artifact_id = uuid.uuid4().hex
        session_dir = self.artifact_dir / session_id
        session_dir.mkdir(parents=True, exist_ok=True)
        stored_name = f"{int(time.time() * 1000)}_{artifact_id[:8]}_{filename}"
        destination = session_dir / stored_name
        destination.write_bytes(content)
        now = utc_now()
        artifact = {
            "record_type": "artifact",
            "artifact_id": artifact_id,
            "session_id": session_id,
            "filename": filename,
            "kind": kind,
            "size": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
            "stored_path": str(destination.resolve()),
            "received_at": now,
            "metadata": metadata or {},
        }
        with self.lock:
            self._touch_session_locked(session_id)
            self._journal_and_publish_locked("artifact", artifact)
            if self.config["capture_next"]:
                self.config["capture_next"] = False
                self._queue_command_locked(
                    "capture_next", {"enabled": False}, "artifact-upload", now
                )
        return artifact

    def wait_for_updates(self, after_stream_id: int, timeout: float = 15.0) -> list[dict[str, Any]]:
        with self.condition:
            updates = [item for item in self.stream_updates if item["stream_id"] > after_stream_id]
            if not updates:
                self.condition.wait(timeout)
                updates = [item for item in self.stream_updates if item["stream_id"] > after_stream_id]
            return [dict(item) for item in updates]


class DebugHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], state: BackendState, static_dir: Path) -> None:
        super().__init__(server_address, DebugRequestHandler)
        self.state = state
        self.static_dir = static_dir


class DiscoveryUDPServer(socketserver.UDPServer):
    allow_reuse_address = True

    def __init__(self, server_address: tuple[str, int], token: str, http_port: int) -> None:
        self.token = token
        self.http_port = http_port
        super().__init__(server_address, DiscoveryRequestHandler)


class DiscoveryRequestHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        data, sock = self.request
        server = self.server
        if not isinstance(server, DiscoveryUDPServer) or not client_is_private(self.client_address[0]):
            return
        nonce = parse_discovery_probe(data, server.token)
        if nonce is None:
            return
        sock.sendto(build_discovery_offer(nonce, server.token, server.http_port), self.client_address)


class DebugRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "AMProjDebug/1"

    @property
    def debug_server(self) -> DebugHTTPServer:
        return self.server  # type: ignore[return-value]

    def log_message(self, format_string: str, *args: Any) -> None:
        sys.stderr.write("[%s] %s %s\n" % (self.log_date_time_string(), self.client_address[0], format_string % args))

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        try:
            parsed = urlsplit(self.path)
            path = parsed.path
            query = parse_qs(parsed.query)
            if path == "/healthz" and method == "GET":
                self._send_json(HTTPStatus.OK, {"ok": True, "protocol_version": PROTOCOL_VERSION})
                return
            if path == "/" or path.startswith("/static/"):
                self._serve_static(path, method)
                return
            if not path.startswith("/api/v1/"):
                raise ApiError(HTTPStatus.NOT_FOUND, "route not found")
            self._authorize()

            if path == "/api/v1/hello" and method == "POST":
                result = self.debug_server.state.hello(self._read_json_object())
                self._send_json(HTTPStatus.OK, result)
            elif path == "/api/v1/events" and method == "POST":
                accepted = self.debug_server.state.add_events(self._read_json())
                self._send_json(HTTPStatus.ACCEPTED, {"accepted": len(accepted), "events": accepted})
            elif path == "/api/v1/events" and method == "GET":
                result = self.debug_server.state.list_events(
                    after_id=self._query_int(query, ("after_id", "after"), 0, 0, 2**63 - 1),
                    limit=self._query_int(query, ("limit",), 500, 1, 1_000),
                    session_id=self._query_text_alias(query, ("session_id", "session")),
                    event_type=self._query_text(query, "type"),
                    level=self._query_text(query, "level"),
                )
                self._send_json(HTTPStatus.OK, result)
            elif path == "/api/v1/sessions" and method == "GET":
                self._send_json(HTTPStatus.OK, self.debug_server.state.list_sessions())
            elif path == "/api/v1/commands" and method == "GET":
                result = self.debug_server.state.get_commands(
                    after_revision=self._query_int(query, ("after_revision", "after"), 0, 0, 2**63 - 1),
                    session_id=self._query_text_alias(query, ("session_id", "session")),
                )
                self._send_json(HTTPStatus.OK, result)
            elif path == "/api/v1/commands" and method == "POST":
                payload = self._read_json_object()
                if "acknowledged" in payload:
                    result = self.debug_server.state.acknowledge_commands(payload)
                else:
                    self._require_loopback()
                    result = self.debug_server.state.set_command(payload)
                self._send_json(HTTPStatus.OK, result)
            elif path == "/api/v1/artifacts" and method == "POST":
                self._handle_artifact()
            elif path == "/api/v1/stream" and method == "GET":
                self._require_loopback()
                after = self._query_int(query, ("after",), 0, 0, 2**63 - 1)
                self._serve_sse(after)
            else:
                raise ApiError(HTTPStatus.METHOD_NOT_ALLOWED if path in {
                    "/api/v1/hello", "/api/v1/events", "/api/v1/sessions",
                    "/api/v1/commands", "/api/v1/artifacts", "/api/v1/stream",
                } else HTTPStatus.NOT_FOUND, "method not allowed" if path.startswith("/api/v1/") else "route not found")
        except ApiError as exc:
            self._send_json(exc.status, {"error": exc.message})
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as exc:
            self.log_error("unhandled request error: %r", exc)
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "internal server error"})

    def _authorize(self) -> None:
        if not client_is_private(self.client_address[0]):
            raise ApiError(HTTPStatus.FORBIDDEN, "API is available only to private-network clients")
        value = self.headers.get("Authorization", "")
        scheme, _, credential = value.partition(" ")
        if scheme.lower() != "bearer" or not credential or not hmac.compare_digest(
            credential.encode("utf-8"), self.debug_server.state.token.encode("utf-8")
        ):
            raise ApiError(HTTPStatus.UNAUTHORIZED, "valid Bearer token required")

    def _require_loopback(self) -> None:
        try:
            is_loopback = ipaddress.ip_address(self.client_address[0].split("%", 1)[0]).is_loopback
        except ValueError:
            is_loopback = False
        if not is_loopback:
            raise ApiError(HTTPStatus.FORBIDDEN, "dashboard operation is available only on this computer")

    def _serve_static(self, path: str, method: str) -> None:
        if method != "GET":
            raise ApiError(HTTPStatus.METHOD_NOT_ALLOWED, "method not allowed")
        self._require_loopback()
        relative = "index.html" if path == "/" else path[len("/static/"):]
        if not relative or ".." in Path(relative).parts:
            raise ApiError(HTTPStatus.NOT_FOUND, "asset not found")
        target = (self.debug_server.static_dir / relative).resolve()
        try:
            target.relative_to(self.debug_server.static_dir.resolve())
        except ValueError:
            raise ApiError(HTTPStatus.NOT_FOUND, "asset not found")
        if not target.is_file():
            raise ApiError(HTTPStatus.NOT_FOUND, "asset not found")
        content = target.read_bytes()
        if target.name == "index.html":
            content = content.replace(
                b"__AMPROJ_DEBUG_TOKEN_JSON__",
                json.dumps(self.debug_server.state.token).encode("utf-8"),
            )
        mime = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", f"{mime}; charset=utf-8" if mime.startswith("text/") else mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(content)

    def _read_body(self, max_bytes: int) -> bytes:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ApiError(HTTPStatus.LENGTH_REQUIRED, "Content-Length is required")
        try:
            length = int(raw_length)
        except ValueError:
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid Content-Length")
        if length < 0 or length > max_bytes:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request body exceeds configured size limit")
        body = self.rfile.read(length)
        if len(body) != length:
            raise ApiError(HTTPStatus.BAD_REQUEST, "incomplete request body")
        return body

    def _read_json(self, max_bytes: int = MAX_JSON_BYTES) -> Any:
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            raise ApiError(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "Content-Type must be application/json")
        body = self._read_body(max_bytes)
        try:
            return json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ApiError(HTTPStatus.BAD_REQUEST, "invalid JSON body")

    def _read_json_object(self, max_bytes: int = MAX_JSON_BYTES) -> dict[str, Any]:
        payload = self._read_json(max_bytes)
        if not isinstance(payload, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "JSON body must be an object")
        return payload

    def _handle_artifact(self) -> None:
        content_type = self.headers.get("Content-Type", "application/octet-stream").split(";", 1)[0].lower()
        if content_type == "application/json":
            encoded_limit = ((self.debug_server.state.max_artifact_bytes + 2) // 3) * 4
            payload = self._read_json_object(encoded_limit + MAX_JSON_BYTES)
            encoded = payload.get("content_base64")
            if not isinstance(encoded, str):
                raise ApiError(HTTPStatus.BAD_REQUEST, "content_base64 is required")
            try:
                content = base64.b64decode(encoded, validate=True)
            except (ValueError, TypeError):
                raise ApiError(HTTPStatus.BAD_REQUEST, "content_base64 is invalid")
            session_id = str(payload.get("session_id") or "")
            filename = str(payload.get("filename") or "artifact.bin")
            kind = str(payload.get("kind") or "artifact")
            metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
        else:
            content = self._read_body(self.debug_server.state.max_artifact_bytes)
            session_id = self.headers.get("X-AMProj-Session", "")
            encoded_filename = self.headers.get("X-AMProj-Artifact-Name-B64", "")
            if encoded_filename:
                try:
                    padded = encoded_filename + "=" * (-len(encoded_filename) % 4)
                    filename = base64.b64decode(padded, validate=True).decode("utf-8")
                except (ValueError, UnicodeDecodeError):
                    raise ApiError(HTTPStatus.BAD_REQUEST, "X-AMProj-Artifact-Name-B64 is invalid")
            else:
                filename = self.headers.get("X-AMProj-Filename", "artifact.bin")
            declared_size = self.headers.get("X-AMProj-Artifact-Size")
            if declared_size:
                try:
                    expected_size = int(declared_size)
                except ValueError:
                    raise ApiError(HTTPStatus.BAD_REQUEST, "X-AMProj-Artifact-Size must be an integer")
                if expected_size != len(content):
                    raise ApiError(HTTPStatus.BAD_REQUEST, "artifact size header does not match request body")
            extension = Path(filename).suffix.lower().lstrip(".")
            inferred_kind = "amproj" if extension == "amproj" else (extension or "artifact")
            kind = self.headers.get("X-AMProj-Kind", inferred_kind)
            metadata_text = self.headers.get("X-AMProj-Metadata", "")
            try:
                metadata = json.loads(metadata_text) if metadata_text else {}
            except json.JSONDecodeError:
                raise ApiError(HTTPStatus.BAD_REQUEST, "X-AMProj-Metadata must be JSON")
            if not isinstance(metadata, dict):
                raise ApiError(HTTPStatus.BAD_REQUEST, "X-AMProj-Metadata must be an object")
            transaction = self.headers.get("X-AMProj-Transaction")
            if transaction:
                metadata.setdefault("transaction", transaction)
        artifact = self.debug_server.state.store_artifact(
            content, session_id=session_id, filename=filename, kind=kind, metadata=metadata
        )
        self._send_json(HTTPStatus.CREATED, artifact)

    def _serve_sse(self, after_stream_id: int) -> None:
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.wfile.write(b": connected\n\n")
        self.wfile.flush()
        cursor = after_stream_id
        while True:
            updates = self.debug_server.state.wait_for_updates(cursor, timeout=15.0)
            if not updates:
                self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()
                continue
            for update in updates:
                encoded = json.dumps(update, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                self.wfile.write(f"id: {update['stream_id']}\n".encode("ascii"))
                self.wfile.write(b"data: " + encoded + b"\n\n")
                self.wfile.flush()
                cursor = update["stream_id"]

    @staticmethod
    def _query_text(query: dict[str, list[str]], name: str) -> str:
        values = query.get(name, [])
        return values[0][:200] if values else ""

    @staticmethod
    def _query_text_alias(query: dict[str, list[str]], names: tuple[str, ...]) -> str:
        for name in names:
            values = query.get(name, [])
            if values:
                return values[0][:200]
        return ""

    @staticmethod
    def _query_int(
        query: dict[str, list[str]], names: tuple[str, ...], default: int, minimum: int, maximum: int
    ) -> int:
        raw = next((query[name][0] for name in names if query.get(name)), str(default))
        try:
            value = int(raw)
        except ValueError:
            raise ApiError(HTTPStatus.BAD_REQUEST, f"{names[0]} must be an integer")
        if value < minimum or value > maximum:
            raise ApiError(HTTPStatus.BAD_REQUEST, f"{names[0]} is out of range")
        return value

    def _send_json(self, status: int, payload: Any) -> None:
        content = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            if status == HTTPStatus.UNAUTHORIZED:
                self.send_header("WWW-Authenticate", 'Bearer realm="AMProjDebug"')
            self.end_headers()
            self.wfile.write(content)
        except (BrokenPipeError, ConnectionResetError):
            return


def create_server(host: str, port: int, state: BackendState, static_dir: Path | None = None) -> DebugHTTPServer:
    return DebugHTTPServer(
        (host, port),
        state,
        static_dir or Path(__file__).resolve().parent / "static",
    )


def create_discovery_server(host: str, port: int, token: str, http_port: int) -> DiscoveryUDPServer:
    return DiscoveryUDPServer((host, port), token, http_port)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="AMProjExportDebug local backend")
    parser.add_argument("--host", default="0.0.0.0", help="listener address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8765, help="listener port (default: 8765)")
    parser.add_argument(
        "--discovery-port",
        type=int,
        help="UDP discovery port; defaults to the HTTP port",
    )
    parser.add_argument("--no-discovery", action="store_true", help="disable UDP LAN discovery")
    parser.add_argument("--data-dir", type=Path, default=Path(__file__).resolve().parent / "data")
    parser.add_argument("--token", help="Bearer token; defaults to AMPROJ_DEBUG_TOKEN or a generated token")
    parser.add_argument("--token-file", type=Path, help="read the Bearer token from this UTF-8 file")
    parser.add_argument("--max-artifact-mib", type=int, default=32)
    return parser.parse_args(argv)


def resolve_token(args: argparse.Namespace) -> tuple[str, bool]:
    if args.token and args.token_file:
        raise SystemExit("use only one of --token and --token-file")
    if args.token_file:
        token = args.token_file.read_text(encoding="utf-8").strip()
    else:
        token = args.token or os.environ.get("AMPROJ_DEBUG_TOKEN", "")
    generated = not token
    token = token or secrets.token_urlsafe(32)
    if len(token) < 16:
        raise SystemExit("Bearer token must contain at least 16 characters")
    return token, generated


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    if not 1 <= args.max_artifact_mib <= 512:
        raise SystemExit("max artifact size must be between 1 and 512 MiB")
    discovery_port = args.discovery_port if args.discovery_port is not None else args.port
    if not 1 <= discovery_port <= 65535:
        raise SystemExit("discovery port must be between 1 and 65535")
    token, generated = resolve_token(args)
    state = BackendState(args.data_dir, token, args.max_artifact_mib * 1024 * 1024)
    server = create_server(args.host, args.port, state)
    discovery_server: DiscoveryUDPServer | None = None
    discovery_thread: threading.Thread | None = None
    try:
        if not args.no_discovery:
            try:
                parsed_host = ipaddress.ip_address(args.host)
            except ValueError:
                parsed_host = None
            if args.host.lower() == "localhost" or (parsed_host is not None and parsed_host.is_loopback):
                raise SystemExit(
                    "UDP discovery requires an HTTP host reachable from the LAN, such as 0.0.0.0"
                )
            try:
                discovery_server = create_discovery_server(args.host, discovery_port, token, args.port)
            except OSError as error:
                raise SystemExit(
                    f"cannot bind UDP discovery on {args.host}:{discovery_port}: {error}"
                ) from error
            discovery_thread = threading.Thread(
                target=discovery_server.serve_forever,
                kwargs={"poll_interval": 0.25},
                name="amproj-discovery",
                daemon=True,
            )
            discovery_thread.start()

        def stop_server(_signum: int, _frame: Any) -> None:
            def stop_all() -> None:
                server.shutdown()
                if discovery_server is not None:
                    discovery_server.shutdown()

            threading.Thread(target=stop_all, daemon=True).start()

        if threading.current_thread() is threading.main_thread():
            signal.signal(signal.SIGINT, stop_server)
            if hasattr(signal, "SIGTERM"):
                signal.signal(signal.SIGTERM, stop_server)

        print(f"AMProj Debug backend: http://127.0.0.1:{args.port}")
        print(f"Device API: http://<windows-lan-ip>:{args.port}/api/v1")
        if discovery_server is not None:
            print(f"Device discovery: UDP {args.host}:{discovery_port}")
        else:
            print("Device discovery: disabled")
        print(f"Data directory: {state.data_dir.resolve()}")
        if generated:
            print(f"Generated Bearer token: {token}")
            print("Pass this same token to the IPA injector.")
        else:
            print("Bearer token loaded.")
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()
        if discovery_server is not None:
            if discovery_thread is not None and discovery_thread.is_alive():
                discovery_server.shutdown()
            discovery_server.server_close()
        if discovery_thread is not None:
            discovery_thread.join(timeout=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
