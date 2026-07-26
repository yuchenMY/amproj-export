from __future__ import annotations

import base64
import hashlib
import http.client
import io
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

try:
    from . import server as server_module
except ImportError:
    import server as server_module

MAX_JSON_BYTES = server_module.MAX_JSON_BYTES
MAX_DEDUP_KEYS = server_module.MAX_DEDUP_KEYS
MAX_IN_MEMORY_EVENTS = server_module.MAX_IN_MEMORY_EVENTS
MAX_SEQ = server_module.MAX_SEQ
ApiError = server_module.ApiError
JournalWriteError = server_module.JournalWriteError
BackendState = server_module.BackendState
client_is_private = server_module.client_is_private
create_discovery_server = server_module.create_discovery_server
create_server = server_module.create_server
discovery_proof = server_module.discovery_proof
event_dedup_key = server_module.event_dedup_key
normalize_key = server_module.normalize_key
parse_discovery_probe = server_module.parse_discovery_probe
payload_fingerprint = server_module.payload_fingerprint
redact_text = server_module.redact_text
redact_value = server_module.redact_value
safe_component = server_module.safe_component
safe_event_timestamp = server_module.safe_event_timestamp


TOKEN = "test-token-with-adequate-length"


def discovery_probe(nonce: str, token: str = TOKEN) -> bytes:
    return json.dumps(
        {
            "type": "amproj-discover",
            "version": 1,
            "nonce": nonce,
            "proof": discovery_proof(token, "discover", nonce),
        },
        separators=(",", ":"),
    ).encode("ascii")


class DiscoveryTests(unittest.TestCase):
    def test_probe_authentication_and_validation(self) -> None:
        nonce = "0123456789abcdef0123456789abcdef"
        self.assertEqual(
            discovery_proof(TOKEN, "discover", nonce),
            "5eTJQRFl7p_YOUZn5UbopEe-5tMOscncAk7x0BfYUjg",
        )
        self.assertEqual(
            discovery_proof(TOKEN, "offer", nonce, 8765),
            "aniWm4VqmM0ifZF_7AVi9KfeD6EpAArUufAJRR9w_bQ",
        )
        self.assertEqual(parse_discovery_probe(discovery_probe(nonce), TOKEN), nonce)
        self.assertIsNone(parse_discovery_probe(discovery_probe(nonce, "wrong-token"), TOKEN))
        self.assertIsNone(parse_discovery_probe(b"not-json", TOKEN))
        self.assertIsNone(parse_discovery_probe(b"x" * 513, TOKEN))

        wrong_version = json.loads(discovery_probe(nonce))
        wrong_version["version"] = 2
        self.assertIsNone(parse_discovery_probe(json.dumps(wrong_version).encode(), TOKEN))

    def test_udp_offer_uses_configured_http_port(self) -> None:
        server = create_discovery_server("127.0.0.1", 0, TOKEN, 43210)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(1)
        nonce = "fedcba9876543210fedcba9876543210"
        try:
            sock.sendto(discovery_probe(nonce), server.server_address)
            data, source = sock.recvfrom(512)
            offer = json.loads(data)
            self.assertEqual(source[0], "127.0.0.1")
            self.assertEqual(offer["type"], "amproj-offer")
            self.assertEqual(offer["nonce"], nonce)
            self.assertEqual(offer["port"], 43210)
            self.assertEqual(
                offer["proof"], discovery_proof(TOKEN, "offer", nonce, 43210)
            )

            sock.settimeout(0.1)
            sock.sendto(discovery_probe(nonce, "wrong-token"), server.server_address)
            with self.assertRaises(TimeoutError):
                sock.recvfrom(512)
        finally:
            sock.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


class BackendHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=64)
        self.server = create_server("127.0.0.1", 0, self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host, self.port = self.server.server_address
        self.base = f"http://{self.host}:{self.port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp_dir.cleanup()

    def request(self, path: str, method: str = "GET", payload=None, headers=None):
        request_headers = dict(headers or {})
        request_headers.setdefault("Authorization", f"Bearer {TOKEN}")
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/json")
        request = Request(self.base + path, data=data, headers=request_headers, method=method)
        with urlopen(request, timeout=3) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    def test_health_and_bearer_authentication(self) -> None:
        with urlopen(self.base + "/healthz", timeout=3) as response:
            self.assertEqual(response.status, 200)
        request = Request(self.base + "/api/v1/sessions")
        with self.assertRaises(HTTPError) as context:
            urlopen(request, timeout=3)
        self.assertEqual(context.exception.code, 401)
        self.assertEqual(context.exception.headers["WWW-Authenticate"], 'Bearer realm="AMProjDebug"')
        context.exception.close()

    def test_hello_events_sessions_and_ndjson(self) -> None:
        status, hello = self.request(
            "/api/v1/hello",
            "POST",
            {"session_id": "s1", "device_id": "phone", "os_version": "26.1", "app_version": "7.0"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(hello["config"]["mode"], "full")
        status, result = self.request(
            "/api/v1/events",
            "POST",
            {"session_id": "s1", "events": [{"type": "stage", "stage": "zip", "message": "started"}]},
        )
        self.assertEqual(status, 202)
        self.assertEqual(result["accepted"], 1)
        _, sessions = self.request("/api/v1/sessions")
        self.assertEqual(sessions["sessions"][0]["session_id"], "s1")
        _, events = self.request("/api/v1/events?after_id=0&limit=20&type=stage")
        self.assertEqual(events["events"][0]["stage"], "zip")
        records = [json.loads(line) for line in self.state.journal_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([record["record_type"] for record in records], ["hello", "event"])

    def test_transport_event_shape_and_nested_hello(self) -> None:
        _, hello = self.request(
            "/api/v1/hello",
            "POST",
            {
                "protocol_version": 1,
                "session": "transport-session",
                "device": {"id": "ios-device", "model": "iPhone", "os_version": "26.1"},
                "app": {"version": "7.0", "build": "27b"},
                "plugin": {
                    "version": "28",
                    "variant": "debug",
                    "build_id": "v28-cloud-test",
                },
            },
        )
        self.assertEqual(hello["session_id"], "transport-session")
        _, sessions = self.request("/api/v1/sessions")
        session = sessions["sessions"][0]
        self.assertEqual(session["plugin_version"], "28")
        self.assertEqual(session["plugin_variant"], "debug")
        self.assertEqual(session["plugin_build_id"], "v28-cloud-test")
        _, result = self.request(
            "/api/v1/events",
            "POST",
            {
                "protocol_version": 1,
                "session": "transport-session",
                "events": [{
                    "session": "transport-session",
                    "seq": 7,
                    "time_ms": 1783950000000,
                    "uptime": 10.5,
                    "type": "stage",
                    "fields": {"stage": "activity_init", "message": "entered", "level": "debug"},
                    "transaction": "tx-1",
                }],
            },
        )
        event = result["events"][0]
        self.assertEqual(event["session_id"], "transport-session")
        self.assertEqual(event["stage"], "activity_init")
        self.assertEqual(event["message"], "entered")
        self.assertEqual(event["level"], "debug")
        self.assertTrue(event["timestamp"].endswith("Z"))

    def test_commands_validate_modes_and_capture(self) -> None:
        # P1: capture arming binds to a device, so register one first.
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        status, command = self.request(
            "/api/v1/commands", "POST", {"mode": "placeholder"}
        )
        self.assertEqual(status, 200)
        self.assertEqual(command["revision"], 1)
        self.assertEqual(command["commands"][0]["type"], "set_mode")
        _, capture = self.request(
            "/api/v1/commands", "POST", {"type": "capture_next", "enabled": True}
        )
        self.assertEqual(capture["revision"], 2)
        _, result = self.request("/api/v1/commands?session=s1&after=0")
        self.assertEqual(result["config"]["mode"], "placeholder")
        self.assertTrue(result["config"]["capture_next"])
        self.assertEqual([item["type"] for item in result["commands"]], ["set_mode", "capture_next"])
        self.assertEqual(result["next_cursor"], 2)
        _, ack = self.request(
            "/api/v1/commands", "POST", {"session": "s1", "acknowledged": [1, 2, 2]}
        )
        self.assertEqual(ack["acknowledged"], [1, 2])
        self.assertEqual(self.state.command_acks["s1"], {1, 2})
        with self.assertRaises(HTTPError) as context:
            self.request("/api/v1/commands", "POST", {"mode": "invalid"})
        self.assertEqual(context.exception.code, 400)
        context.exception.close()

    def test_raw_artifact_and_one_shot_capture(self) -> None:
        # P1: register the device, arm capture for it, then upload with a
        # matching session + transaction.
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        self.request("/api/v1/commands", "POST", {"capture_next": True})
        content = b"PK\x03\x04amproj"
        request = Request(
            self.base + "/api/v1/artifacts",
            data=content,
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/octet-stream",
                "X-AMProj-Session": "s1",
                "X-AMProj-Filename": "project.amproj",
                "X-AMProj-Kind": "amproj",
                "X-AMProj-Transaction": "tx-1",
            },
            method="POST",
        )
        with urlopen(request, timeout=3) as response:
            artifact = json.loads(response.read())
            self.assertEqual(response.status, 201)
        self.assertFalse(Path(artifact["stored_path"]).is_absolute())
        self.assertEqual((self.state.data_dir / artifact["stored_path"]).read_bytes(), content)
        self.assertEqual(artifact["size"], len(content))
        self.assertFalse(self.state.config["capture_next"])

        oversized = Request(
            self.base + "/api/v1/artifacts",
            data=b"x" * 65,
            headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/octet-stream"},
            method="POST",
        )
        with self.assertRaises(HTTPError) as context:
            urlopen(oversized, timeout=3)
        self.assertEqual(context.exception.code, 413)
        context.exception.close()

    def test_transport_artifact_headers(self) -> None:
        # P1: register the device, then arm capture for it before uploading.
        self.request("/api/v1/hello", "POST", {"session_id": "transport-session", "device_id": "d"})
        self.request("/api/v1/commands", "POST", {"capture_next": True})
        content = b"<scene/>"
        encoded_name = "c2NlbmUueG1s"
        request = Request(
            self.base + "/api/v1/artifacts",
            data=content,
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/xml",
                "X-AMProj-Session": "transport-session",
                "X-AMProj-Artifact-Name-B64": encoded_name,
                "X-AMProj-Transaction": "tx-42",
                "X-AMProj-Artifact-Size": str(len(content)),
                "X-AMProj-Debug-Transport": "1",
            },
            method="POST",
        )
        with urlopen(request, timeout=3) as response:
            artifact = json.loads(response.read())
        self.assertEqual(artifact["filename"], "scene.xml")
        self.assertEqual(artifact["kind"], "xml")
        self.assertEqual(artifact["metadata"]["transaction"], "tx-42")

    def test_json_base64_artifact_uses_artifact_limit(self) -> None:
        # P1: register the device, arm capture, and bind the upload to a
        # transaction via metadata.
        self.request("/api/v1/hello", "POST", {"session_id": "s-json", "device_id": "d"})
        self.request("/api/v1/commands", "POST", {"capture_next": True})
        content = b"x" * 48
        status, artifact = self.request(
            "/api/v1/artifacts",
            "POST",
            {
                "session_id": "s-json",
                "filename": "scene.xml",
                "kind": "xml",
                "metadata": {"transaction": "tx-json"},
                "content_base64": "eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4",
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(artifact["size"], len(content))

    def test_sse_delivers_published_event(self) -> None:
        connection = http.client.HTTPConnection(self.host, self.port, timeout=3)
        connection.request("GET", "/api/v1/stream", headers={"Authorization": f"Bearer {TOKEN}"})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.readline(), b": connected\n")
        self.assertEqual(response.readline(), b"\n")
        self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "heartbeat"})
        self.assertTrue(response.readline().startswith(b"id: "))
        data_line = response.readline()
        self.assertTrue(data_line.startswith(b"data: "))
        update = json.loads(data_line[len(b"data: "):])
        self.assertEqual(update["topic"], "event")
        connection.close()

    def test_dashboard_is_served_with_runtime_token(self) -> None:
        with urlopen(self.base + "/", timeout=3) as response:
            html = response.read().decode("utf-8")
        self.assertIn(f'const TOKEN = "{TOKEN}";', html)
        self.assertNotIn("__AMPROJ_DEBUG_TOKEN_JSON__", html)


# ---------------------------------------------------------------------------
# Characterization / contract tests (P0 freeze).
#
# The classes below LOCK the current observable behavior of the v1 API so a
# later refactor (P1: persistence, auth split, etc.) cannot silently change the
# wire contract the shipped iOS dylib (AMProjExport/AMDebugTransport.m) depends
# on. They only exercise public helpers and the HTTP surface; no production
# code is modified. All fixtures are synthetic — no real tokens, IFVs, paths,
# cookies, or project content.
# ---------------------------------------------------------------------------


class PureHelperContractTests(unittest.TestCase):
    """Pure functions with no server; they define sanitization + timestamp rules."""

    def test_safe_component_neutralizes_path_traversal_and_caps_length(self) -> None:
        # Every char outside [A-Za-z0-9._-] collapses to "_"; leading/trailing
        # "." and "_" are stripped, so directory traversal cannot survive.
        self.assertEqual(safe_component("../../evil", "fallback"), "evil")
        self.assertEqual(safe_component("../../../x.txt", "fallback"), "x.txt")
        self.assertEqual(safe_component("a/b\\c:d", "fallback"), "a_b_c_d")
        # Empty / None / all-punctuation collapse to the caller's fallback.
        self.assertEqual(safe_component("", "fallback"), "fallback")
        self.assertEqual(safe_component(None, "fallback"), "fallback")
        self.assertEqual(safe_component("...___", "fallback"), "fallback")
        # 120-character cap.
        self.assertEqual(len(safe_component("a" * 500, "fallback")), 120)

    def test_client_is_private_classification(self) -> None:
        for address in ("127.0.0.1", "10.1.2.3", "192.168.0.5", "172.16.9.9", "169.254.1.1", "::1"):
            self.assertTrue(client_is_private(address), address)
        # Genuinely global unicast addresses and malformed input are non-private.
        for address in ("8.8.8.8", "1.2.3.4", "172.32.0.1", "not-an-ip", ""):
            self.assertFalse(client_is_private(address), address)

    def test_safe_event_timestamp_validates_and_never_bypasses_sanitizer(self) -> None:
        # P1: the timestamp is read from the REDACTED payload and validated.
        received = "2026-01-02T03:04:05.000Z"
        # A well-formed ISO-8601 client timestamp is trusted.
        self.assertEqual(
            safe_event_timestamp({"timestamp": "2026-05-06T07:08:09.123Z"}, received),
            "2026-05-06T07:08:09.123Z",
        )
        # A non-ISO / injected string is NOT trusted; it falls through.
        self.assertEqual(safe_event_timestamp({"timestamp": "not a date"}, received), received)
        self.assertEqual(
            safe_event_timestamp({"timestamp": "'; DROP TABLE"}, received), received
        )
        # time_ms is converted to an ISO-8601 Z string when no valid timestamp.
        converted = safe_event_timestamp({"time_ms": 1_783_950_000_000}, received)
        self.assertTrue(converted.endswith("Z"))
        self.assertTrue(converted.startswith("2026-"))
        # Non-positive / non-numeric / bool / overflow time_ms -> received_at.
        self.assertEqual(safe_event_timestamp({"time_ms": 0}, received), received)
        self.assertEqual(safe_event_timestamp({"time_ms": "nope"}, received), received)
        self.assertEqual(safe_event_timestamp({"time_ms": True}, received), received)
        self.assertEqual(safe_event_timestamp({"time_ms": 10**30}, received), received)
        self.assertEqual(safe_event_timestamp({}, received), received)

    def test_redaction_safely_replaces_unknown_and_non_finite_values(self) -> None:
        class Unknown:
            pass

        result = redact_value({
            "unknown": Unknown(),
            "nan": float("nan"),
            "transaction": float("inf"),
            "type": float("-inf"),
        })
        self.assertEqual(result, {
            "unknown": "<unsupported>",
            "nan": "<unsupported>",
            "transaction": "<unsupported>",
            "type": "<unsupported>",
        })
        json.dumps(result, allow_nan=False)


class ContractServerTestCase(unittest.TestCase):
    """Shared HTTP harness mirroring BackendHTTPTests, with raw-request helpers."""

    max_artifact_bytes = 64

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.temp_dir.name)
        self.state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)
        self.server = create_server("127.0.0.1", 0, self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host, self.port = self.server.server_address
        self.base = f"http://{self.host}:{self.port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp_dir.cleanup()

    def request(self, path: str, method: str = "GET", payload=None, headers=None):
        request_headers = dict(headers or {})
        request_headers.setdefault("Authorization", f"Bearer {TOKEN}")
        data = None
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            request_headers.setdefault("Content-Type", "application/json")
        request = Request(self.base + path, data=data, headers=request_headers, method=method)
        with urlopen(request, timeout=3) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    def expect_error(self, path: str, method: str = "GET", payload=None, headers=None) -> int:
        with self.assertRaises(HTTPError) as context:
            self.request(path, method, payload, headers)
        code = context.exception.code
        context.exception.close()
        return code

    def raw(self, method: str, path: str, body: bytes = b"", headers=None):
        """Send a fully-controlled request; return (status, headers, body_bytes)."""
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()


class AuthAndRoutingContractTests(ContractServerTestCase):
    def test_healthz_needs_no_auth_and_reports_protocol(self) -> None:
        status, headers, body = self.raw("GET", "/healthz")
        self.assertEqual(status, 200)
        health = json.loads(body)
        self.assertTrue(health["ok"])
        self.assertEqual(health["protocol_version"], 1)
        self.assertTrue(health["persistence_ready"])

        self.state._journal_poisoned = True
        status, _, body = self.raw("GET", "/healthz")
        self.assertEqual(status, 200)  # old liveness probes remain compatible
        degraded = json.loads(body)
        self.assertTrue(degraded["ok"])
        self.assertFalse(degraded["persistence_ready"])

    def test_state_reads_and_stream_fail_closed_when_persistence_is_unavailable(self) -> None:
        self.state._journal_poisoned = True
        for path in (
            "/api/v1/events",
            "/api/v1/sessions",
            "/api/v1/commands?session_id=device-1",
            "/api/v1/stream",
        ):
            self.assertEqual(self.expect_error(path), 503, path)

    def test_poll_heartbeat_poison_race_fails_closed(self) -> None:
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        self.state._last_touch_persist["s1"] = 0.0
        real_append = self.state._append_journal_line

        def poison(_record):
            self.state._journal_poisoned = True
            raise JournalWriteError("simulated uncertain heartbeat", commit_uncertain=True)

        self.state._append_journal_line = poison  # type: ignore[assignment]
        try:
            self.assertEqual(self.expect_error("/api/v1/commands?session=s1"), 503)
        finally:
            self.state._append_journal_line = real_append  # type: ignore[assignment]

    def test_rejected_unread_body_is_not_reparsed_or_logged(self) -> None:
        secret = "PASSWORD=RAW-SECRET-SENTINEL"
        captured = io.StringIO()
        connection = http.client.HTTPConnection(self.host, self.port, timeout=3)
        try:
            with redirect_stderr(captured):
                connection.request(
                    "POST", "/api/v1/events", body=secret.encode("ascii"),
                    headers={
                        "Authorization": f"Bearer {TOKEN}",
                        "Content-Type": "text/plain",
                    },
                )
                response = connection.getresponse()
                self.assertEqual(response.status, 415)
                self.assertEqual(response.getheader("Connection"), "close")
                response.read()
                time.sleep(0.05)
        finally:
            connection.close()
        self.assertNotIn("RAW-SECRET-SENTINEL", captured.getvalue())

    def test_request_log_omits_query_values(self) -> None:
        secret = "QUERY-SECRET-SENTINEL"
        captured = io.StringIO()
        with redirect_stderr(captured):
            status, _, _ = self.raw(
                "GET", f"/api/v1/events?token={secret}",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
        self.assertEqual(status, 200)
        self.assertNotIn(secret, captured.getvalue())

    def test_missing_wrong_and_invalid_bearer_is_401(self) -> None:
        # No Authorization header.
        status, headers, _ = self.raw("GET", "/api/v1/sessions")
        self.assertEqual(status, 401)
        self.assertEqual(headers.get("WWW-Authenticate"), 'Bearer realm="AMProjDebug"')
        # Wrong scheme.
        self.assertEqual(
            self.raw("GET", "/api/v1/sessions", headers={"Authorization": "Basic abc"})[0], 401
        )
        # Bearer with the wrong token.
        self.assertEqual(
            self.raw("GET", "/api/v1/sessions", headers={"Authorization": "Bearer nope"})[0], 401
        )
        # Empty credential.
        self.assertEqual(
            self.raw("GET", "/api/v1/sessions", headers={"Authorization": "Bearer "})[0], 401
        )

    def test_unknown_route_and_method_mapping(self) -> None:
        auth = {"Authorization": f"Bearer {TOKEN}"}
        # Unknown /api/v1 path -> 404.
        self.assertEqual(self.raw("GET", "/api/v1/does-not-exist", headers=auth)[0], 404)
        # Non-API, non-static path -> 404.
        self.assertEqual(self.raw("GET", "/random", headers=auth)[0], 404)
        # Known path, wrong-but-handled method (GET/POST) -> 405.
        self.assertEqual(self.raw("GET", "/api/v1/hello", headers=auth)[0], 405)
        self.assertEqual(self.raw("POST", "/api/v1/sessions", headers=auth)[0], 405)
        # A verb with no do_<VERB> handler (e.g. PUT) is 501 from the base
        # handler and never reaches dispatch — the server only implements
        # GET and POST.
        self.assertEqual(self.raw("PUT", "/api/v1/events", headers=auth)[0], 501)

    def test_events_requires_json_content_type(self) -> None:
        status, _, _ = self.raw(
            "POST",
            "/api/v1/events",
            body=b"{}",
            headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "text/plain"},
        )
        self.assertEqual(status, 415)

    def test_oversized_json_body_is_413_from_content_length(self) -> None:
        # _read_body rejects on the DECLARED Content-Length before reading the
        # body. Sending a spoofed oversized Content-Length with a tiny body
        # exercises that guard deterministically (streaming the full oversized
        # body instead races the server's early close).
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            connection.putrequest("POST", "/api/v1/events", skip_host=False, skip_accept_encoding=True)
            connection.putheader("Authorization", f"Bearer {TOKEN}")
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(MAX_JSON_BYTES + 16))
            connection.endheaders()
            connection.send(b"{}")  # deliberately shorter than the declared length
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
        finally:
            connection.close()

    def test_stream_requires_bearer(self) -> None:
        # Loopback is satisfied by the test client; the bearer check still applies.
        self.assertEqual(self.raw("GET", "/api/v1/stream")[0], 401)


class HelloContractTests(ContractServerTestCase):
    def test_hello_with_all_fields_missing_still_registers(self) -> None:
        status, hello = self.request("/api/v1/hello", "POST", {})
        self.assertEqual(status, 200)
        # Response envelope shape is frozen.
        self.assertEqual(set(hello), {"session_id", "protocol_version", "config", "server_time"})
        self.assertEqual(hello["protocol_version"], 1)
        self.assertTrue(hello["session_id"])  # generated when none supplied
        self.assertEqual(
            set(hello["config"]), {"mode", "capture_next", "revision", "updated_at"}
        )
        self.assertEqual(hello["config"]["mode"], "full")
        self.assertFalse(hello["config"]["capture_next"])
        self.assertEqual(hello["config"]["revision"], 0)
        self.assertTrue(hello["server_time"].endswith("Z"))
        # A session row exists with the unknown-device fallback.
        _, sessions = self.request("/api/v1/sessions")
        self.assertEqual(sessions["sessions"][0]["device_id"], "unknown-device")

    def test_hello_legacy_flat_fields_and_session_dict(self) -> None:
        # Legacy flat keys (session_id, device_id, top-level versions).
        _, hello = self.request(
            "/api/v1/hello",
            "POST",
            {
                "session_id": "flat-session",
                "device_id": "flat-device",
                "app_version": "7.0",
                "os_version": "26.1",
                "device_model": "iPhone",
            },
        )
        self.assertEqual(hello["session_id"], "flat-session")
        # session supplied as a nested object with an id.
        _, hello2 = self.request(
            "/api/v1/hello", "POST", {"session": {"id": "obj-session"}, "device_id": "d"}
        )
        self.assertEqual(hello2["session_id"], "obj-session")
        _, sessions = self.request("/api/v1/sessions")
        by_id = {item["session_id"]: item for item in sessions["sessions"]}
        self.assertEqual(by_id["flat-session"]["app_version"], "7.0")
        self.assertEqual(by_id["flat-session"]["device_model"], "iPhone")

    def test_hello_is_idempotent_on_session_id_and_preserves_connected_at(self) -> None:
        _, first = self.request("/api/v1/hello", "POST", {"session_id": "dup"})
        _, sessions_after_first = self.request("/api/v1/sessions")
        connected_at = sessions_after_first["sessions"][0]["connected_at"]
        self.request("/api/v1/hello", "POST", {"session_id": "dup"})
        _, sessions = self.request("/api/v1/sessions")
        matches = [s for s in sessions["sessions"] if s["session_id"] == "dup"]
        self.assertEqual(len(matches), 1)  # same session_id does not duplicate
        self.assertEqual(matches[0]["connected_at"], connected_at)

    def test_session_identifier_cannot_smuggle_a_secret(self) -> None:
        _, hello = self.request(
            "/api/v1/hello", "POST", {"session_id": "Bearer LEAK-TOKEN", "device_id": "d"}
        )
        self.assertNotIn("LEAK-TOKEN", hello["session_id"])
        journal = self.state.journal_path.read_text(encoding="utf-8")
        self.assertNotIn("LEAK-TOKEN", journal)


class EventsContractTests(ContractServerTestCase):
    def test_empty_batch_and_empty_array_are_rejected(self) -> None:
        self.assertEqual(self.expect_error("/api/v1/events", "POST", {"events": []}), 400)
        self.assertEqual(self.expect_error("/api/v1/events", "POST", []), 400)

    def test_bare_object_bare_array_and_wrapped_shapes_all_accepted(self) -> None:
        status, result = self.request("/api/v1/events", "POST", {"type": "log", "message": "hi"})
        self.assertEqual((status, result["accepted"]), (202, 1))
        status, result = self.request(
            "/api/v1/events", "POST", [{"type": "a"}, {"type": "b"}]
        )
        self.assertEqual((status, result["accepted"]), (202, 2))
        status, result = self.request(
            "/api/v1/events", "POST", {"session_id": "s", "events": [{"type": "c"}]}
        )
        self.assertEqual((status, result["accepted"]), (202, 1))

    def test_non_object_event_and_batch_overflow_are_rejected(self) -> None:
        self.assertEqual(
            self.expect_error("/api/v1/events", "POST", {"events": ["not-an-object"]}), 400
        )
        self.assertEqual(
            self.expect_error("/api/v1/events", "POST", {"events": [{} for _ in range(501)]}), 400
        )

    def test_extreme_json_number_is_400_not_500(self) -> None:
        body = b'{"seq":' + (b"9" * 5000) + b'}'
        status, _, response = self.raw(
            "POST", "/api/v1/events", body=body,
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )
        self.assertEqual(status, 400)
        self.assertIn(b"invalid JSON", response)

    def test_overflow_float_is_safely_normalized(self) -> None:
        body = b'{"session_id":"s1","type":"metric","value":1e400}'
        status, _, response = self.raw(
            "POST", "/api/v1/events", body=body,
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )
        self.assertEqual(status, 202)
        parsed = json.loads(response)
        self.assertEqual(parsed["events"][0]["payload"]["value"], "<unsupported>")
        journal = self.state.journal_path.read_text(encoding="utf-8")
        self.assertNotIn("Infinity", journal)
        self.assertNotIn("NaN", journal)

    def test_missing_type_and_level_get_defaults(self) -> None:
        _, result = self.request("/api/v1/events", "POST", {"message": "no type"})
        event = result["events"][0]
        self.assertEqual(event["type"], "log")
        self.assertEqual(event["level"], "info")

    def test_duplicate_session_seq_is_idempotent(self) -> None:
        # P1: a retried (session, seq) is de-duplicated. The repeat is accepted
        # (still 202, preserving the client contract) but returns the ORIGINAL
        # event id and does not create a second row.
        duplicate = {"session": "s1", "seq": 7, "type": "stage", "fields": {"stage": "zip"}}
        status1, first = self.request("/api/v1/events", "POST", {"events": [duplicate]})
        status2, second = self.request("/api/v1/events", "POST", {"events": [duplicate]})
        self.assertEqual((status1, status2), (202, 202))
        self.assertEqual(first["events"][0]["id"], second["events"][0]["id"])
        _, events = self.request("/api/v1/events?session=s1")
        seq7 = [e for e in events["events"] if e["payload"].get("seq") == 7]
        self.assertEqual(len(seq7), 1)  # stored exactly once
        self.assertEqual(events["retained"], 1)
        # A different seq on the same session is a distinct event.
        self.request(
            "/api/v1/events", "POST", {"events": [{"session": "s1", "seq": 8, "type": "stage"}]}
        )
        _, events2 = self.request("/api/v1/events?session=s1")
        self.assertEqual(events2["retained"], 2)

    def test_duplicate_event_after_journal_poison_is_not_reported_as_success(self) -> None:
        payload = {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        self.request("/api/v1/events", "POST", payload)
        self.state._journal_poisoned = True
        self.assertEqual(self.expect_error("/api/v1/events", "POST", payload), 503)

    def test_events_without_seq_are_never_deduped(self) -> None:
        # Events with no numeric seq keep the pre-P1 behavior: each is stored.
        self.request("/api/v1/events", "POST", {"events": [{"session": "s2", "type": "log"}]})
        self.request("/api/v1/events", "POST", {"events": [{"session": "s2", "type": "log"}]})
        _, events = self.request("/api/v1/events?session=s2")
        self.assertEqual(events["retained"], 2)

    def test_get_query_aliases_are_equivalent(self) -> None:
        self.request(
            "/api/v1/events", "POST", {"events": [{"session": "A", "type": "stage"}]}
        )
        _, by_id = self.request("/api/v1/events?session_id=A")
        _, by_alias = self.request("/api/v1/events?session=A")
        self.assertEqual([e["id"] for e in by_id["events"]], [e["id"] for e in by_alias["events"]])
        # after == after_id.
        first_id = by_id["events"][0]["id"]
        _, after_id = self.request(f"/api/v1/events?after_id={first_id}")
        _, after = self.request(f"/api/v1/events?after={first_id}")
        self.assertEqual(after_id["events"], after["events"])

    def test_get_filters_bounds_and_empty_result(self) -> None:
        self.request(
            "/api/v1/events",
            "POST",
            {"events": [{"type": "stage", "level": "error", "fields": {"stage": "zip"}}]},
        )
        _, filtered = self.request("/api/v1/events?type=stage&level=error")
        self.assertEqual(len(filtered["events"]), 1)
        # Non-matching filter -> empty events; last_id echoes the requested after_id.
        _, empty = self.request("/api/v1/events?type=nonexistent&after_id=5")
        self.assertEqual(empty["events"], [])
        self.assertEqual(empty["last_id"], 5)
        # limit / after_id range validation.
        self.assertEqual(self.expect_error("/api/v1/events?limit=0"), 400)
        self.assertEqual(self.expect_error("/api/v1/events?limit=1001"), 400)
        self.assertEqual(self.expect_error("/api/v1/events?after_id=-1"), 400)
        self.assertEqual(self.expect_error("/api/v1/events?after_id=abc"), 400)


class CommandsContractTests(ContractServerTestCase):
    def test_set_mode_validation_and_alias(self) -> None:
        # set_mode without a mode is rejected.
        self.assertEqual(
            self.expect_error("/api/v1/commands", "POST", {"type": "set_mode"}), 400
        )
        # Invalid mode is rejected.
        self.assertEqual(self.expect_error("/api/v1/commands", "POST", {"mode": "invalid"}), 400)
        # set_export_mode is an accepted alias for set_mode.
        _, result = self.request(
            "/api/v1/commands", "POST", {"type": "set_export_mode", "mode": "observe"}
        )
        self.assertEqual(result["mode"], "observe")
        self.assertEqual(result["commands"][0]["type"], "set_mode")

    def test_empty_command_is_rejected(self) -> None:
        self.assertEqual(self.expect_error("/api/v1/commands", "POST", {}), 400)

    def test_revision_is_monotonic_and_cursor_alias(self) -> None:
        # capture arming binds to a device, so register one first.
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        _, one = self.request("/api/v1/commands", "POST", {"mode": "placeholder"})
        _, two = self.request("/api/v1/commands", "POST", {"capture_next": True})
        _, three = self.request("/api/v1/commands", "POST", {"type": "flush"})
        self.assertEqual([one["revision"], two["revision"], three["revision"]], [1, 2, 3])
        # after == after_revision alias; next_cursor is the last command id.
        _, by_after = self.request("/api/v1/commands?after=0")
        _, by_rev = self.request("/api/v1/commands?after_revision=0")
        self.assertEqual(
            [c["id"] for c in by_after["commands"]], [c["id"] for c in by_rev["commands"]]
        )
        self.assertEqual(by_after["next_cursor"], 3)
        self.assertEqual(by_after["config"]["mode"], "placeholder")
        self.assertTrue(by_after["config"]["capture_next"])

    def test_capture_next_disable_command(self) -> None:
        _, result = self.request(
            "/api/v1/commands", "POST", {"type": "capture_next", "enabled": False}
        )
        self.assertFalse(result["capture_next"])
        self.assertEqual(result["commands"][0]["type"], "capture_next")
        self.assertFalse(result["commands"][0]["capture_next"])

    def test_acknowledge_dedupes_sorts_and_validates(self) -> None:
        _, ack = self.request(
            "/api/v1/commands", "POST", {"session": "s1", "acknowledged": [3, 1, 2, 2]}
        )
        self.assertEqual(ack["acknowledged"], [1, 2, 3])
        self.assertEqual(ack["next_cursor"], 3)
        self.assertEqual(ack["session"], "s1")
        # Validation failures.
        self.assertEqual(
            self.expect_error("/api/v1/commands", "POST", {"acknowledged": "nope"}), 400
        )
        self.assertEqual(
            self.expect_error(
                "/api/v1/commands", "POST", {"acknowledged": [i for i in range(1001)]}
            ),
            400,
        )
        self.assertEqual(
            self.expect_error("/api/v1/commands", "POST", {"acknowledged": [-1]}), 400
        )
        self.assertEqual(
            self.expect_error("/api/v1/commands", "POST", {"acknowledged": ["x"]}), 400
        )
        self.assertEqual(
            self.expect_error(
                "/api/v1/commands", "POST", {"acknowledged": [MAX_SEQ + 1]}
            ),
            400,
        )
        status, _, _ = self.raw(
            "POST", "/api/v1/commands", body=b'{"acknowledged":[1e400]}',
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )
        self.assertEqual(status, 400)


class ArtifactContractTests(ContractServerTestCase):
    max_artifact_bytes = 4096

    def _register(self, session_id: str = "s1") -> None:
        self.request("/api/v1/hello", "POST", {"session_id": session_id, "device_id": "d"})

    def _arm(self, session_id: str | None = None) -> None:
        """Register (if needed) a device and arm a capture grant for it."""
        payload = {"capture_next": True}
        if session_id is not None:
            payload["session_id"] = session_id
        self.request("/api/v1/commands", "POST", payload)

    def _upload_raw(self, content: bytes, extra_headers=None):
        headers = {
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/octet-stream",
        }
        headers.update(extra_headers or {})
        return self.raw("POST", "/api/v1/artifacts", body=content, headers=headers)

    def test_unauthorized_artifact_is_rejected_when_capture_next_is_false(self) -> None:
        # P1 SECURITY CONTRACT (replaces the pre-P1 known gap): with no armed
        # capture grant, the server rejects the upload with 403 and stores
        # nothing. Intentional inversion of the P0 characterization test.
        self._register("s1")
        self.assertFalse(self.state.config["capture_next"])
        status, _, body = self._upload_raw(
            b"PK\x03\x04synthetic",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "project.amproj",
             "X-AMProj-Transaction": "tx-unarmed"},
        )
        self.assertEqual(status, 403)
        self.assertIn(b"not authorized", body)
        self.assertFalse((self.state.artifact_dir / "s1").exists())

    def test_artifact_requires_non_empty_session_and_transaction(self) -> None:
        self._register("s1")
        self._arm("s1")
        # Missing transaction -> 400.
        self.assertEqual(
            self._upload_raw(b"x", {"X-AMProj-Session": "s1"})[0], 400
        )
        # Missing session -> 400 (falls back to empty, rejected).
        self.assertEqual(
            self._upload_raw(b"x", {"X-AMProj-Transaction": "tx-1"})[0], 400
        )

    def test_armed_capture_authorizes_one_transaction_then_rejects_next(self) -> None:
        self._register("s1")
        self._arm("s1")
        first = self._upload_raw(
            b"PK\x03\x04synthetic",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "project.amproj",
             "X-AMProj-Transaction": "tx-1"},
        )
        self.assertEqual(first[0], 201)
        artifact = json.loads(first[2])
        self.assertEqual(artifact["kind"], "amproj")
        self.assertEqual(artifact["transaction"], "tx-1")
        self.assertFalse(Path(artifact["stored_path"]).is_absolute())
        self.assertEqual((self.data_dir / artifact["stored_path"]).read_bytes(), b"PK\x03\x04synthetic")
        # A DIFFERENT transaction with no fresh arming is rejected.
        second = self._upload_raw(
            b"other.amproj", {"X-AMProj-Session": "s1", "X-AMProj-Filename": "b.amproj",
                              "X-AMProj-Transaction": "tx-2"}
        )
        self.assertEqual(second[0], 403)

    def test_duplicate_artifact_after_journal_poison_is_not_reported_as_success(self) -> None:
        self._register("s1")
        self._arm("s1")
        headers = {
            "X-AMProj-Session": "s1", "X-AMProj-Filename": "project.amproj",
            "X-AMProj-Transaction": "tx-poison",
        }
        self.assertEqual(self._upload_raw(b"same", headers)[0], 201)
        self.state._journal_poisoned = True
        self.assertEqual(self._upload_raw(b"same", headers)[0], 503)

    def test_same_transaction_two_files_ok_third_file_rejected(self) -> None:
        # An export emits scene.xml AND the .amproj under ONE transaction (2
        # files allowed); a THIRD file under the same grant must be rejected.
        self._register("s1")
        self._arm("s1")
        xml = self._upload_raw(
            b"<scene/>",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "scene.xml",
             "X-AMProj-Transaction": "tx-multi"},
        )
        self.assertEqual(xml[0], 201)
        archive = self._upload_raw(
            b"PK\x03\x04archive",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "project.amproj",
             "X-AMProj-Transaction": "tx-multi"},
        )
        self.assertEqual(archive[0], 201)
        self.assertEqual(json.loads(xml[2])["grant_id"], json.loads(archive[2])["grant_id"])
        # An idempotent RETRY of file 1 (identical bytes) is fine and does not
        # count against the file limit — returns the original artifact_id.
        retry = self._upload_raw(
            b"<scene/>",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "scene.xml",
             "X-AMProj-Transaction": "tx-multi"},
        )
        self.assertEqual(retry[0], 201)
        self.assertEqual(json.loads(retry[2])["artifact_id"], json.loads(xml[2])["artifact_id"])
        # A different payload for an already-filled kind is a conflict.
        third = self._upload_raw(
            b"<scene>distinct third</scene>",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "extra.xml",
             "X-AMProj-Transaction": "tx-multi"},
        )
        self.assertEqual(third[0], 409)

    def test_same_kind_conflict_does_not_consume_xml_slot(self) -> None:
        self._register("s1")
        self._arm("s1")
        headers = {
            "X-AMProj-Session": "s1",
            "X-AMProj-Filename": "project.amproj",
            "X-AMProj-Transaction": "tx-one-per-kind",
        }
        self.assertEqual(self._upload_raw(b"first-amproj", headers)[0], 201)
        self.assertEqual(self._upload_raw(b"different-amproj", headers)[0], 409)
        xml = self._upload_raw(
            b"<scene/>",
            {
                "X-AMProj-Session": "s1",
                "X-AMProj-Filename": "scene.xml",
                "X-AMProj-Transaction": "tx-one-per-kind",
            },
        )
        self.assertEqual(xml[0], 201)

    def test_late_file_from_old_transaction_does_not_cancel_new_capture(self) -> None:
        self._register("s1")
        self._arm("s1")
        first = self._upload_raw(
            b"first-amproj",
            {
                "X-AMProj-Session": "s1", "X-AMProj-Filename": "project.amproj",
                "X-AMProj-Transaction": "tx-old",
            },
        )
        self.assertEqual(first[0], 201)
        self.assertFalse(self.state.config["capture_next"])

        self._arm("s1")  # pending grant for the next export
        self.assertTrue(self.state.config["capture_next"])
        late_xml = self._upload_raw(
            b"<late-old-scene/>",
            {
                "X-AMProj-Session": "s1", "X-AMProj-Filename": "scene.xml",
                "X-AMProj-Transaction": "tx-old",
            },
        )
        self.assertEqual(late_xml[0], 201)
        self.assertTrue(self.state.config["capture_next"])

        next_export = self._upload_raw(
            b"next-amproj",
            {
                "X-AMProj-Session": "s1", "X-AMProj-Filename": "project.amproj",
                "X-AMProj-Transaction": "tx-new",
            },
        )
        self.assertEqual(next_export[0], 201)
        self.assertFalse(self.state.config["capture_next"])

    def test_disallowed_kind_is_rejected(self) -> None:
        # Only xml/amproj are permitted by the default grant.
        self._register("s1")
        self._arm("s1")
        status, _, _ = self._upload_raw(
            b"garbage",
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "evil.exe",
             "X-AMProj-Kind": "exe", "X-AMProj-Transaction": "tx-1"},
        )
        self.assertEqual(status, 403)

    def test_grant_byte_budget_is_enforced(self) -> None:
        # A single grant's total byte budget caps the sum across its files.
        self.state.capture_grant_max_bytes = 16
        self._register("s1")
        self._arm("s1")
        first = self._upload_raw(
            b"0123456789",  # 10 bytes, under budget
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "a.xml",
             "X-AMProj-Transaction": "tx-1"},
        )
        self.assertEqual(first[0], 201)
        second = self._upload_raw(
            b"0123456789",  # +10 = 20 > 16 budget
            {"X-AMProj-Session": "s1", "X-AMProj-Filename": "b.amproj",
             "X-AMProj-Transaction": "tx-1"},
        )
        self.assertEqual(second[0], 403)

    def test_concurrent_transactions_only_one_binds(self) -> None:
        # One arming = one grant for the device. Two different transactions
        # racing for it: exactly one binds and succeeds, the other is rejected.
        self._register("s1")
        self._arm("s1")
        results = {}
        barrier = threading.Barrier(2)

        def attempt(tx: str) -> None:
            barrier.wait()
            status, _, _ = self._upload_raw(
                b"<scene/>",
                {"X-AMProj-Session": "s1", "X-AMProj-Filename": "scene.xml",
                 "X-AMProj-Transaction": tx},
            )
            results[tx] = status

        threads = [threading.Thread(target=attempt, args=(f"tx-{i}",)) for i in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)
        statuses = sorted(results.values())
        self.assertEqual(statuses, [201, 403])  # exactly one bound

    def test_expired_grant_is_rejected(self) -> None:
        self.state.capture_grant_ttl = -1.0  # every new grant is already expired
        self._register("s1")
        self._arm("s1")
        status, _, _ = self._upload_raw(
            b"late", {"X-AMProj-Session": "s1", "X-AMProj-Filename": "a.xml",
                      "X-AMProj-Transaction": "tx-late"}
        )
        self.assertEqual(status, 403)
        self.assertFalse(self.state.config["capture_next"])
        self.assertTrue(all(grant["revoked"] for grant in self.state.capture_grants.values()))
        expiry_commands = [
            command for command in self.state.commands
            if command.get("source") == "capture-grant-expiry"
        ]
        self.assertEqual(len(expiry_commands), 1)
        self.assertFalse(expiry_commands[0]["enabled"])

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=4096)
        self.assertFalse(restarted.config["capture_next"])
        self.assertTrue(all(grant["revoked"] for grant in restarted.capture_grants.values()))

    def test_partial_expiry_disarms_only_the_expired_session(self) -> None:
        self._register("s1")
        self._register("s2")
        self.state.capture_grant_ttl = -1.0
        self._arm("s1")
        self.state.capture_grant_ttl = 300.0
        self._arm("s2")
        cursor = self.state.config["revision"]

        s1_view = self.state.get_commands(cursor, "s1")
        self.assertTrue(s1_view["config"]["capture_next"])
        self.assertEqual(len(s1_view["commands"]), 1)
        self.assertEqual(s1_view["commands"][0]["target_session"], "s1")
        self.assertFalse(s1_view["commands"][0]["enabled"])

        s2_view = self.state.get_commands(cursor, "s2")
        self.assertEqual(s2_view["commands"], [])
        self.assertEqual(s2_view["next_cursor"], s1_view["next_cursor"])
        self.assertTrue(s2_view["config"]["capture_next"])
        grants = list(self.state.capture_grants.values())
        self.assertTrue(next(g for g in grants if g["session_id"] == "s1")["revoked"])
        self.assertFalse(next(g for g in grants if g["session_id"] == "s2")["revoked"])

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=4096)
        self.assertTrue(restarted.config["capture_next"])
        restarted_grants = list(restarted.capture_grants.values())
        self.assertTrue(next(
            g for g in restarted_grants if g["session_id"] == "s1"
        )["revoked"])
        self.assertFalse(next(
            g for g in restarted_grants if g["session_id"] == "s2"
        )["revoked"])
        accepted = restarted.store_artifact(
            b"data", session_id="s2", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-s2"},
        )
        self.assertEqual(accepted["session_id"], "s2")

    def test_first_device_upload_does_not_cancel_another_pending_device(self) -> None:
        self._register("s1")
        self._register("s2")
        self._arm("s1")
        self._arm("s2")
        cursor = self.state.config["revision"]

        first = self.state.store_artifact(
            b"first", session_id="s1", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-s1"},
        )
        self.assertEqual(first["session_id"], "s1")
        self.assertTrue(self.state.config["capture_next"])

        s1_view = self.state.get_commands(cursor, "s1")
        self.assertEqual(len(s1_view["commands"]), 1)
        self.assertFalse(s1_view["commands"][0]["enabled"])
        self.assertEqual(s1_view["commands"][0]["target_session"], "s1")
        self.assertTrue(s1_view["commands"][0]["capture_next"])

        s2_view = self.state.get_commands(cursor, "s2")
        self.assertEqual(s2_view["commands"], [])
        self.assertEqual(s2_view["next_cursor"], s1_view["next_cursor"])
        self.assertTrue(s2_view["config"]["capture_next"])
        self.assertTrue(any(
            not grant["revoked"] and not grant["bound"]
            and grant["session_id"] == "s2"
            for grant in self.state.capture_grants.values()
        ))

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=4096)
        self.assertTrue(restarted.config["capture_next"])
        second = restarted.store_artifact(
            b"second", session_id="s2", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-s2"},
        )
        self.assertEqual(second["session_id"], "s2")
        self.assertFalse(restarted.config["capture_next"])

    def test_disarming_revokes_pending_and_bound_grants(self) -> None:
        # Disarm revokes a PENDING grant.
        self._register("s1")
        self._arm("s1")
        self.request("/api/v1/commands", "POST", {"capture_next": False})
        self.assertEqual(
            self._upload_raw(
                b"data", {"X-AMProj-Session": "s1", "X-AMProj-Filename": "a.xml",
                          "X-AMProj-Transaction": "tx-x"}
            )[0],
            403,
        )
        # Disarm also revokes an already-BOUND grant mid-transaction.
        self._arm("s1")
        first = self._upload_raw(
            b"<scene/>", {"X-AMProj-Session": "s1", "X-AMProj-Filename": "scene.xml",
                          "X-AMProj-Transaction": "tx-bound"}
        )
        self.assertEqual(first[0], 201)  # binds tx-bound
        # The first upload already reset capture_next; re-arm was consumed, so
        # explicitly disarm to revoke the bound grant, then the .amproj is
        # rejected even though it is the same transaction.
        self.request("/api/v1/commands", "POST", {"capture_next": False})
        second = self._upload_raw(
            b"PK\x03\x04", {"X-AMProj-Session": "s1", "X-AMProj-Filename": "b.amproj",
                            "X-AMProj-Transaction": "tx-bound"}
        )
        self.assertEqual(second[0], 403)

    def test_one_shot_capture_reset_after_first_artifact(self) -> None:
        self._register("s1")
        self._arm("s1")
        self.assertTrue(self.state.config["capture_next"])
        status, _, _ = self._upload_raw(
            b"data", {"X-AMProj-Session": "s1", "X-AMProj-Filename": "a.xml",
                      "X-AMProj-Transaction": "tx-1"}
        )
        self.assertEqual(status, 201)
        self.assertFalse(self.state.config["capture_next"])
        reset = [c for c in self.state.commands if c["type"] == "capture_next" and not c["capture_next"]]
        self.assertTrue(reset)
        self.assertEqual(reset[-1]["source"], "artifact-upload")

    def test_size_header_mismatch_and_bad_name_are_rejected(self) -> None:
        # Handler-level validations fire before authorization -> 400 regardless.
        self.assertEqual(
            self._upload_raw(b"1234", {"X-AMProj-Artifact-Size": "999"})[0], 400
        )
        self.assertEqual(
            self._upload_raw(b"1234", {"X-AMProj-Artifact-Name-B64": "!!!not-base64!!!"})[0], 400
        )

    def test_metadata_header_parsing_and_transaction_default(self) -> None:
        self._register("transport-session")
        self._arm("transport-session")
        status, _, body = self._upload_raw(
            b"<scene/>",
            {
                "X-AMProj-Session": "transport-session",
                "X-AMProj-Artifact-Name-B64": base64.b64encode(b"scene.xml").decode(),
                "X-AMProj-Transaction": "tx-9",
                "X-AMProj-Metadata": json.dumps({"stage": "zip"}),
            },
        )
        self.assertEqual(status, 201)
        artifact = json.loads(body)
        self.assertEqual(artifact["filename"], "scene.xml")
        self.assertEqual(artifact["metadata"]["stage"], "zip")
        self.assertEqual(artifact["metadata"]["transaction"], "tx-9")
        # Invalid metadata JSON / non-object metadata -> 400 (handler-level).
        self.assertEqual(self._upload_raw(b"x", {"X-AMProj-Metadata": "{bad"})[0], 400)
        self.assertEqual(self._upload_raw(b"x", {"X-AMProj-Metadata": "[1,2]"})[0], 400)

    def test_session_and_filename_path_traversal_is_neutralized(self) -> None:
        # Arm for the sanitized session id the upload will resolve to.
        self._register("evil")
        self._arm("evil")
        status, _, body = self._upload_raw(
            b"payload",
            {"X-AMProj-Session": "../../evil", "X-AMProj-Filename": "../../../x.xml",
             "X-AMProj-Transaction": "tx-1"},
        )
        self.assertEqual(status, 201)
        artifact = json.loads(body)
        self.assertEqual(artifact["session_id"], "evil")
        self.assertEqual(artifact["filename"], "scene.xml")
        self.assertNotEqual(artifact["filename"], "x.xml")
        self.assertFalse(Path(artifact["stored_path"]).is_absolute())
        stored = (self.data_dir / artifact["stored_path"]).resolve()
        stored.relative_to(self.state.artifact_dir.resolve())  # raises if it escaped
        self.assertEqual(stored.parent.name, "evil")

    def test_project_title_and_absolute_storage_path_are_not_exposed(self) -> None:
        self._register("s1")
        self._arm("s1")
        title = "My Secret Project"
        status, _, body = self._upload_raw(
            b"payload",
            {
                "X-AMProj-Session": "s1",
                "X-AMProj-Filename": title + ".amproj",
                "X-AMProj-Transaction": "tx-private-name",
            },
        )
        self.assertEqual(status, 201)
        artifact = json.loads(body)
        self.assertFalse(Path(artifact["stored_path"]).is_absolute())
        serialized = json.dumps(artifact)
        self.assertNotIn(title, serialized)
        journal = self.state.journal_path.read_text(encoding="utf-8")
        self.assertNotIn(title, journal)
        self.assertNotIn(str(self.data_dir.resolve()), journal)
        artifact_update = next(
            item for item in self.state.stream_updates if item["topic"] == "artifact"
        )
        streamed = json.dumps(artifact_update)
        self.assertNotIn(title, streamed)
        self.assertNotIn(str(self.data_dir.resolve()), streamed)

    def test_sha256_and_size_are_reported(self) -> None:
        import hashlib

        self._register("s1")
        self._arm("s1")
        content = b"reproducible-bytes"
        status, _, body = self._upload_raw(
            content, {"X-AMProj-Session": "s1", "X-AMProj-Filename": "a.xml",
                      "X-AMProj-Transaction": "tx-1"}
        )
        self.assertEqual(status, 201)
        artifact = json.loads(body)
        self.assertEqual(artifact["size"], len(content))
        self.assertEqual(artifact["sha256"], hashlib.sha256(content).hexdigest())

    def test_oversized_artifact_is_413_before_authorization(self) -> None:
        # Size is checked before authorization -> 413 even with no armed grant.
        status, _, _ = self._upload_raw(b"x" * (self.max_artifact_bytes + 1))
        self.assertEqual(status, 413)

    def test_json_base64_artifact_requires_valid_content(self) -> None:
        # Body validation (handler-level) precedes authorization.
        self.assertEqual(
            self.expect_error("/api/v1/artifacts", "POST", {"filename": "a.bin"}), 400
        )
        self.assertEqual(
            self.expect_error(
                "/api/v1/artifacts", "POST", {"content_base64": "!!!not-base64!!!"}
            ),
            400,
        )

    def test_capture_arming_requires_resolvable_device(self) -> None:
        # No active device -> arming is a clean 400.
        self.assertEqual(
            self.expect_error("/api/v1/commands", "POST", {"capture_next": True}), 400
        )
        # Unknown explicit session -> 400.
        self.assertEqual(
            self.expect_error(
                "/api/v1/commands", "POST", {"capture_next": True, "session_id": "ghost"}
            ),
            400,
        )
        # Two active devices, no explicit session -> ambiguous -> 400.
        self._register("s1")
        self._register("s2")
        self.assertEqual(
            self.expect_error("/api/v1/commands", "POST", {"capture_next": True}), 400
        )
        # Explicit session disambiguates -> 200.
        status, _ = self.request(
            "/api/v1/commands", "POST", {"capture_next": True, "session_id": "s1"}
        )
        self.assertEqual(status, 200)


class StreamCursorContractTests(ContractServerTestCase):
    def test_stream_id_is_monotonic_and_cursor_filters_old_updates(self) -> None:
        self.state.add_events({"type": "a"})
        first = self.state.stream_id
        self.assertGreaterEqual(first, 1)
        # Nothing newer than the current cursor.
        self.assertEqual(self.state.wait_for_updates(first, timeout=0.1), [])
        # A newer update is delivered, and only that one.
        self.state.add_events({"type": "b"})
        newer = self.state.wait_for_updates(first, timeout=0.5)
        self.assertEqual(len(newer), 1)
        self.assertEqual(newer[0]["stream_id"], first + 1)
        self.assertEqual(newer[0]["topic"], "event")

    def test_sse_after_cursor_skips_already_seen_updates(self) -> None:
        # Publish one event so there is history to skip.
        self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "seed"})
        cursor = self.state.stream_id
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            connection.request(
                "GET",
                f"/api/v1/stream?after={cursor}",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.readline(), b": connected\n")
            self.assertEqual(response.readline(), b"\n")
            # A brand-new event must arrive with stream_id == cursor + 1, proving
            # the seeded (already-seen) update was not replayed.
            self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "fresh"})
            id_line = response.readline()
            self.assertEqual(id_line, f"id: {cursor + 1}\n".encode("ascii"))
            data_line = response.readline()
            self.assertTrue(data_line.startswith(b"data: "))
            update = json.loads(data_line[len(b"data: "):])
            self.assertEqual(update["topic"], "event")
            self.assertEqual(update["data"]["type"], "fresh")
        finally:
            connection.close()


class RestartAndJournalContractTests(unittest.TestCase):
    """P1: the append-only journal is replayed on restart to recover state."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    @staticmethod
    def _legacy_capture_command(
        revision: int, enabled: bool, capture_next: bool, session_id: str = "",
    ) -> dict:
        command = {
            "record_type": "command", "id": revision, "revision": revision,
            "type": "capture_next", "enabled": enabled, "mode": "full",
            "capture_next": capture_next, "source": "legacy-dashboard",
            "created_at": "2026-01-01T00:00:00.000Z",
        }
        if session_id:
            command["session_id"] = session_id
        return command

    @staticmethod
    def _legacy_pending_grant(grant_id: str, session_id: str) -> dict:
        return {
            "grant_id": grant_id, "armed_at": "2026-01-01T00:00:00.000Z",
            "expires_at": time.time() + 300, "session_id": session_id,
            "transaction": None, "bound": False, "consumed": False,
            "revoked": False, "files": 0, "bytes": 0, "max_files": 2,
            "max_bytes": 1024, "allowed_kinds": ["amproj", "xml"],
        }

    def test_legacy_replay_sanitizes_memory_without_mutating_source(self) -> None:
        raw_event = {
            "type": "stage", "seq": 1, "token": "EVENT-SECRET",
            "message": "/Users/alice/Private Project.amproj",
            "detail": "Cookie: benign=1; session=COOKIE-SECRET",
            "device_id": "RAW-EVENT-DEVICE",
        }
        records = [
            {
                "record_type": "hello",
                "session": {
                    "session_id": "s1", "last_seen": "2026-01-01T00:00:00.000Z",
                    "connected_at": "2026-01-01T00:00:00.000Z",
                    "device_id": "RAW-SESSION-DEVICE",
                    "app_version": "Authorization: Basic SESSION-SECRET",
                },
            },
            {
                "record_type": "event", "id": 1, "session_id": "s1",
                "type": "stage", "level": "info",
                "message": raw_event["message"],
                "timestamp": "2026-01-01T00:00:00.000Z",
                "received_at": "2026-01-01T00:00:00.000Z",
                "payload": raw_event,
            },
        ]
        journal = self.data_dir / "events.ndjson"
        journal.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )
        before = hashlib.sha256(journal.read_bytes()).hexdigest()
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual(hashlib.sha256(journal.read_bytes()).hexdigest(), before)
        visible = json.dumps({
            "sessions": state.list_sessions(),
            "events": state.list_events(),
            "updates": list(state.stream_updates),
        })
        for secret in (
            "EVENT-SECRET", "COOKIE-SECRET", "SESSION-SECRET",
            "RAW-EVENT-DEVICE", "RAW-SESSION-DEVICE", "/Users/alice",
            "Private Project.amproj",
        ):
            self.assertNotIn(secret, visible)
        self.assertTrue(state.sessions["s1"]["device_id"].startswith("ifv:"))
        retry = state.add_events({"session_id": "s1", "events": [raw_event]})
        self.assertTrue(retry[0]["duplicate"])
        self.assertEqual(retry[0]["id"], 1)

    def test_replayed_config_exposes_only_sanitized_allowlisted_fields(self) -> None:
        secret = "CONFIG-SECRET-SENTINEL"
        private_path = "/Users/alice/Private Config.amproj"
        record = {
            "record_type": "command_batch",
            "commands": [{
                "record_type": "command", "id": 1, "revision": 1,
                "type": "set_mode", "mode": "observe", "capture_next": False,
                "created_at": "2026-01-01T00:00:00.000Z", "target_session": "",
            }],
            "grants": [],
            "config": {
                "revision": 1, "mode": "observe", "capture_next": False,
                "updated_at": f"Bearer {secret} {private_path}",
                "private_note": secret,
            },
            "stream_id": 1,
        }
        self.data_dir.joinpath("events.ndjson").write_text(
            json.dumps(record) + "\n", encoding="utf-8"
        )

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        command_view = state.get_commands(0)
        stream_view = list(state.stream_updates)
        visible = json.dumps({"get": command_view, "sse": stream_view})
        self.assertNotIn(secret, visible)
        self.assertNotIn(private_path, visible)
        self.assertNotIn("private_note", visible)
        self.assertEqual(
            set(command_view["config"]),
            {"mode", "capture_next", "revision", "updated_at"},
        )
        self.assertEqual(
            set(stream_view[0]["data"]),
            {"mode", "capture_next", "revision", "updated_at"},
        )

    def test_bad_seq_in_replayed_event_batch_skips_the_whole_record(self) -> None:
        def event(identifier: int, seq: int) -> dict:
            return {
                "record_type": "event", "id": identifier, "stream_id": identifier,
                "session_id": "s1", "type": "stage", "level": "info",
                "received_at": "2026-01-01T00:00:00.000Z",
                "payload": {"type": "stage", "seq": seq},
            }

        record = {
            "record_type": "event_batch",
            "events": [event(1, 1), event(2, -1)],
        }
        self.data_dir.joinpath("events.ndjson").write_text(
            json.dumps(record) + "\n", encoding="utf-8"
        )
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual(state.replay_stats, {"replayed": 0, "skipped": 1})
        self.assertEqual(list(state.events), [])
        self.assertEqual(state.event_id, 0)
        self.assertEqual(state.stream_id, 0)

    def test_replay_sanitizes_event_received_at_before_memory_and_stream(self) -> None:
        secret = "EVENT_RECEIVED_SECRET"
        record = {
            "record_type": "event", "id": 1, "stream_id": 1,
            "session_id": "s1", "type": "stage", "level": "info",
            "received_at": f"Bearer {secret} C:\\Private\\leak.amproj",
            "payload": {"type": "stage", "seq": 1},
        }
        self.data_dir.joinpath("events.ndjson").write_text(
            json.dumps(record) + "\n", encoding="utf-8"
        )
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        visible = json.dumps({"events": state.list_events(), "stream": list(state.stream_updates)})
        self.assertNotIn(secret, visible)
        self.assertNotIn("Private", visible)
        self.assertNotIn("leak.amproj", visible)

    def test_replay_sanitizes_artifact_received_at_before_session_update(self) -> None:
        secret = "ARTIFACT_RECEIVED_SECRET"
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.hello({"session_id": "s1", "device_id": "d"})
        state.set_command({"capture_next": True, "session_id": "s1"})
        state.store_artifact(
            b"data", session_id="s1", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-received"},
        )
        lines = [json.loads(line) for line in state.journal_path.read_text(encoding="utf-8").splitlines()]
        artifact = next(record for record in lines if record.get("record_type") == "artifact")
        artifact["received_at"] = f"Bearer {secret} C:\\Private\\leak.amproj"
        state.journal_path.write_text(
            "".join(json.dumps(record) + "\n" for record in lines), encoding="utf-8"
        )
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        visible = json.dumps({"sessions": restarted.list_sessions(), "stream": list(restarted.stream_updates)})
        self.assertNotIn(secret, visible)
        self.assertNotIn("Private", visible)
        self.assertNotIn("leak.amproj", visible)

    def test_journal_records_are_written_one_object_per_line(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        pre = len(state.journal_path.read_text(encoding="utf-8").splitlines()) if state.journal_path.exists() else 0
        state.hello({"session_id": "s1", "device_id": "d"})
        state.add_events({"session_id": "s1", "events": [{"type": "stage", "seq": 1}]})
        state.set_command({"mode": "placeholder"})  # arms nothing
        state.set_command({"capture_next": True, "session_id": "s1"})  # arms a grant
        state.store_artifact(
            b"bytes", session_id="s1", filename="a.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        state.acknowledge_commands({"session": "s1", "acknowledged": [1]})

        # ONE line per logical operation: hello, event, two command_batches
        # (mode; capture arm — the grant snapshot is bundled INSIDE the batch,
        # not a separate line), artifact (grant consume + reset bundled), ack.
        lines = state.journal_path.read_text(encoding="utf-8").splitlines()
        # Every line is exactly one JSON object.
        records = [json.loads(line) for line in lines]
        record_types = [r["record_type"] for r in records]
        self.assertEqual(record_types[pre:], [
            "hello", "event", "command_batch", "command_batch", "artifact", "command_ack",
        ])
        # The capture arm batch carries its grant snapshot inline.
        arm = [r for r in records if r["record_type"] == "command_batch" and r.get("grants")]
        self.assertTrue(arm)
        self.assertEqual(arm[0]["grants"][-1]["session_id"], "s1")
        # The artifact record bundles the consumed grant and the reset command.
        art = [r for r in records if r["record_type"] == "artifact"][0]
        self.assertEqual(art["artifact"]["transaction"], "tx-1")
        self.assertIn("grant", art)
        self.assertIn("reset_command", art)

    def test_multi_event_batch_is_one_record_and_replays_atomically(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        accepted = state.add_events({
            "session_id": "s1",
            "events": [
                {"type": "stage", "seq": 1},
                {"type": "stage", "seq": 2},
            ],
        })
        self.assertEqual([event["id"] for event in accepted], [1, 2])
        records = [
            json.loads(line)
            for line in state.journal_path.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["record_type"], "event_batch")
        self.assertEqual(len(records[0]["events"]), 2)

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual([event["id"] for event in restarted.events], [1, 2])
        duplicate = restarted.add_events({
            "session_id": "s1",
            "events": [{"type": "stage", "seq": 1}],
        })
        self.assertTrue(duplicate[0]["duplicate"])
        self.assertEqual(duplicate[0]["id"], 1)

    def test_restart_recovers_state_and_cursor_keeps_increasing(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.hello({"session_id": "s1", "device_id": "raw-udid"})
        state.add_events({"session_id": "s1", "events": [{"type": "stage", "seq": 1}]})
        state.add_events({"session_id": "s1", "events": [{"type": "stage", "seq": 2}]})
        state.set_command({"mode": "placeholder"})
        state.acknowledge_commands({"session": "s1", "acknowledged": [1]})
        stream_before = state.stream_id
        event_id_before = state.event_id
        revision_before = state.config["revision"]
        self.assertGreater(stream_before, 0)

        # "Restart": a fresh state over the same directory REPLAYS the journal.
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual(len(restarted.events), 2)
        self.assertIn("s1", restarted.sessions)
        self.assertEqual(restarted.config["mode"], "placeholder")
        self.assertEqual(restarted.config["revision"], revision_before)
        self.assertEqual(restarted.command_acks.get("s1"), {1})
        # High-water marks are preserved and monotonic across restart.
        self.assertEqual(restarted.event_id, event_id_before)
        self.assertEqual(restarted.stream_id, stream_before)
        # A new event after restart advances the SSE cursor beyond the old max.
        restarted.add_events({"session_id": "s1", "events": [{"type": "post", "seq": 9}]})
        self.assertEqual(restarted.event_id, event_id_before + 1)
        self.assertEqual(restarted.stream_id, stream_before + 1)
        restarted.set_command({"mode": "observe"})
        self.assertEqual(restarted.config["revision"], revision_before + 1)

    def test_restart_preserves_seq_dedup(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.add_events({"session_id": "s1", "events": [{"type": "stage", "seq": 5}]})
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        # The same (session, seq) after restart is recognized as a duplicate.
        restarted.add_events({"session_id": "s1", "events": [{"type": "stage", "seq": 5}]})
        self.assertEqual(len(restarted.events), 1)

    def test_restart_recovers_capture_grant_authorization(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.hello({"session_id": "s1", "device_id": "d"})
        state.set_command({"capture_next": True, "session_id": "s1"})  # arm before restart
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        # The pending grant (bound to s1) survives restart and authorizes one
        # upload for that session + transaction.
        artifact = restarted.store_artifact(
            b"data", session_id="s1", filename="a.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        self.assertEqual(artifact["transaction"], "tx-1")
        # A second, different transaction is then rejected (grant consumed).
        with self.assertRaises(ApiError) as ctx:
            restarted.store_artifact(
                b"more", session_id="s1", filename="b.amproj", kind="amproj",
                metadata={"transaction": "tx-2"},
            )
        self.assertEqual(ctx.exception.status, 403)

    def test_legacy_broadcast_disarm_revokes_standalone_pending_grant(self) -> None:
        now = "2026-01-01T00:00:00.000Z"
        grant = self._legacy_pending_grant("g-s1", "s1")
        records = [
            {"record_type": "hello", "session": {
                "session_id": "s1", "last_seen": now, "connected_at": now,
            }},
            self._legacy_capture_command(1, True, True, "s1"),
            {"record_type": "capture_grant", "grant": grant},
            self._legacy_capture_command(2, False, False),
        ]
        journal = self.data_dir / "events.ndjson"
        journal.write_text(
            "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8",
        )
        before = hashlib.sha256(journal.read_bytes()).hexdigest()

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertEqual(state.replay_stats, {"replayed": 4, "skipped": 0})
        self.assertEqual(hashlib.sha256(journal.read_bytes()).hexdigest(), before)
        self.assertFalse(state.config["capture_next"])
        self.assertTrue(state.capture_grants["g-s1"]["revoked"])
        with self.assertRaises(ApiError) as context:
            state.store_artifact(
                b"data", session_id="s1", filename="project.amproj", kind="amproj",
                metadata={"transaction": "tx-after-disarm"},
            )
        self.assertEqual(context.exception.status, 403)

    def test_legacy_targeted_disarm_only_revokes_target_pending_grant(self) -> None:
        now = "2026-01-01T00:00:00.000Z"
        records = [
            {"record_type": "hello", "session": {
                "session_id": "s1", "last_seen": now, "connected_at": now,
            }},
            {"record_type": "hello", "session": {
                "session_id": "s2", "last_seen": now, "connected_at": now,
            }},
            self._legacy_capture_command(1, True, True, "s1"),
            {"record_type": "capture_grant", "grant": self._legacy_pending_grant("g-s1", "s1")},
            self._legacy_capture_command(2, True, True, "s2"),
            {"record_type": "capture_grant", "grant": self._legacy_pending_grant("g-s2", "s2")},
            # Some legacy writers persisted the targeted device's local false
            # state here instead of the aggregate state. Replay must derive the
            # aggregate from the other device's still-live pending grant.
            self._legacy_capture_command(3, False, False, "s1"),
        ]
        journal = self.data_dir / "events.ndjson"
        journal.write_text(
            "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8",
        )
        before = hashlib.sha256(journal.read_bytes()).hexdigest()

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertEqual(state.replay_stats, {"replayed": 7, "skipped": 0})
        self.assertEqual(hashlib.sha256(journal.read_bytes()).hexdigest(), before)
        self.assertTrue(state.config["capture_next"])
        self.assertTrue(state.commands[-1]["capture_next"])
        self.assertTrue(state.capture_grants["g-s1"]["revoked"])
        self.assertFalse(state.capture_grants["g-s2"]["revoked"])
        with self.assertRaises(ApiError) as context:
            state.store_artifact(
                b"s1", session_id="s1", filename="s1.amproj", kind="amproj",
                metadata={"transaction": "tx-s1"},
            )
        self.assertEqual(context.exception.status, 403)
        accepted = state.store_artifact(
            b"s2", session_id="s2", filename="s2.amproj", kind="amproj",
            metadata={"transaction": "tx-s2"},
        )
        self.assertEqual(accepted["session_id"], "s2")

    def test_replayed_artifact_reset_keeps_bound_grant_for_second_file(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.hello({"session_id": "s1", "device_id": "d"})
        state.set_command({"capture_next": True, "session_id": "s1"})
        first = state.store_artifact(
            b"<scene/>", session_id="s1", filename="scene.xml", kind="xml",
            metadata={"transaction": "tx-two-files"},
        )
        journal = state.journal_path
        before = hashlib.sha256(journal.read_bytes()).hexdigest()

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertEqual(hashlib.sha256(journal.read_bytes()).hexdigest(), before)
        grant = restarted.capture_grants[first["grant_id"]]
        self.assertTrue(grant["bound"])
        self.assertFalse(grant["revoked"])
        second = restarted.store_artifact(
            b"archive", session_id="s1", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-two-files"},
        )
        self.assertEqual(second["grant_id"], first["grant_id"])

    def test_restart_normalizes_expired_pending_grant_without_rewriting_journal(self) -> None:
        state = BackendState(
            self.data_dir, TOKEN, max_artifact_bytes=1024, capture_grant_ttl=-1.0,
        )
        state.hello({"session_id": "s1", "device_id": "d"})
        state.set_command({"capture_next": True, "session_id": "s1"})
        journal = state.journal_path
        before = hashlib.sha256(journal.read_bytes()).hexdigest()

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertEqual(hashlib.sha256(journal.read_bytes()).hexdigest(), before)
        self.assertFalse(restarted.config["capture_next"])
        view = restarted.get_commands(0, "s1")
        self.assertFalse(view["config"]["capture_next"])
        self.assertFalse(view["commands"][-1]["enabled"])
        self.assertEqual(view["commands"][-1]["source"], "replay-capture-normalization")
        with self.assertRaises(ApiError) as context:
            restarted.store_artifact(
                b"late", session_id="s1", filename="project.amproj", kind="amproj",
                metadata={"transaction": "tx-expired"},
            )
        self.assertEqual(context.exception.status, 403)

        restarted.set_command({"capture_next": True, "session_id": "s1"})
        armed_again = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertTrue(armed_again.config["capture_next"])
        self.assertTrue(any(
            not grant["revoked"] and not grant["bound"]
            for grant in armed_again.capture_grants.values()
        ))

    def test_corrupt_journal_line_is_isolated_and_valid_records_recover(self) -> None:
        # A good hello, a garbage line, then a good event. Replay must skip the
        # bad line and still recover both valid records — one bad line never
        # blocks the records after it.
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.hello({"session_id": "s1", "device_id": "d"})
        state.add_events({"session_id": "s1", "events": [{"type": "ok", "seq": 1}]})
        # Inject a corrupt line into the middle of the journal.
        with state.journal_path.open("a", encoding="utf-8") as handle:
            handle.write("not json at all\n")
        state.add_events({"session_id": "s1", "events": [{"type": "ok2", "seq": 2}]})

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertGreaterEqual(restarted.replay_stats["skipped"], 1)
        self.assertEqual(len(restarted.events), 2)  # both valid events recovered
        self.assertIn("s1", restarted.sessions)
        # It can still append and serve after replaying a damaged journal.
        accepted = restarted.add_events({"events": [{"type": "post"}]})
        self.assertEqual(len(accepted), 1)

    def test_replay_is_idempotent_across_multiple_restarts(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.add_events({"session_id": "s1", "events": [{"type": "a", "seq": 1}]})
        first = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        second = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        # Replaying the same journal twice yields the same event count and
        # cursor — no duplication from re-reading persisted records.
        self.assertEqual(len(first.events), len(second.events))
        self.assertEqual(first.stream_id, second.stream_id)
        self.assertEqual(first.event_id, second.event_id)

    def test_replay_skips_cross_record_cursor_regression(self) -> None:
        newer = {
            "record_type": "command", "id": 2, "revision": 2,
            "type": "set_mode", "mode": "full", "capture_next": False,
            "stream_id": 2,
        }
        stale = {
            "record_type": "command", "id": 1, "revision": 1,
            "type": "set_mode", "mode": "observe", "capture_next": False,
            "stream_id": 1,
        }
        (self.data_dir / "events.ndjson").write_text(
            json.dumps(newer) + "\n" + json.dumps(stale) + "\n", encoding="utf-8"
        )
        state = BackendState(self.data_dir, TOKEN)
        self.assertEqual(state.replay_stats, {"replayed": 1, "skipped": 1})
        self.assertEqual(state.config["mode"], "full")
        self.assertEqual([command["revision"] for command in state.commands], [2])
        self.assertEqual([item["stream_id"] for item in state.stream_updates], [2])

    def test_capture_command_without_enabled_is_skipped(self) -> None:
        record = {
            "record_type": "command",
            "id": 1,
            "revision": 1,
            "type": "capture_next",
            "mode": "full",
            "capture_next": False,
            "stream_id": 1,
            "target_session": "",
        }
        self.data_dir.joinpath("events.ndjson").write_text(
            json.dumps(record) + "\n", encoding="utf-8",
        )

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertEqual(state.replay_stats, {"replayed": 0, "skipped": 1})
        self.assertEqual(list(state.commands), [])
        self.assertFalse(state.config["capture_next"])

    def test_targeted_disarm_cannot_smuggle_a_pending_grant(self) -> None:
        grant = {
            "grant_id": "g-smuggled",
            "expires_at": time.time() + 300,
            "session_id": "s1",
            "transaction": None,
            "bound": False,
            "consumed": False,
            "revoked": False,
            "files": 0,
            "bytes": 0,
            "max_files": 2,
            "max_bytes": 2048,
            "allowed_kinds": ["amproj"],
        }
        record = {
            "record_type": "command_batch",
            "commands": [{
                "record_type": "command",
                "id": 1,
                "revision": 1,
                "type": "capture_next",
                "enabled": False,
                "mode": "full",
                "capture_next": True,
                "target_session": "s1",
            }],
            "grants": [grant],
            "config": {"revision": 1, "mode": "full", "capture_next": True},
            "stream_id": 1,
        }

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertFalse(state._record_is_valid(record))

    def test_legacy_revision_reset_is_rebased_monotonically(self) -> None:
        commands = [
            {
                "record_type": "command", "id": 2, "revision": 2,
                "type": "set_mode", "mode": "full", "capture_next": False,
            },
            {
                "record_type": "command", "id": 1, "revision": 1,
                "type": "set_mode", "mode": "observe", "capture_next": False,
            },
        ]
        (self.data_dir / "events.ndjson").write_text(
            "\n".join(json.dumps(command) for command in commands) + "\n",
            encoding="utf-8",
        )
        state = BackendState(self.data_dir, TOKEN)
        self.assertEqual(state.replay_stats, {"replayed": 2, "skipped": 0})
        self.assertEqual([command["revision"] for command in state.commands], [2, 3])
        self.assertEqual(state.config["revision"], 3)
        self.assertEqual(state.config["mode"], "observe")

    def test_legacy_armed_flag_without_grant_is_migrated_to_disarmed(self) -> None:
        now = server_module.utc_now()
        records = [
            {
                "record_type": "hello",
                "session": {
                    "session_id": "s1", "last_seen": now, "connected_at": now,
                },
            },
            {
                "record_type": "command", "id": 1, "revision": 1,
                "type": "capture_next", "enabled": True,
                "mode": "full", "capture_next": True,
                "source": "legacy-dashboard", "created_at": now,
            },
        ]
        journal = self.data_dir / "events.ndjson"
        journal.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )
        before = hashlib.sha256(journal.read_bytes()).hexdigest()

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertEqual(state.replay_stats, {"replayed": 2, "skipped": 0})
        self.assertEqual(hashlib.sha256(journal.read_bytes()).hexdigest(), before)
        self.assertFalse(state.config["capture_next"])
        self.assertEqual(state.capture_grants, {})
        view = state.get_commands(0, "s1")
        self.assertEqual([command["revision"] for command in view["commands"]], [1, 2])
        self.assertTrue(view["commands"][0]["capture_next"])
        self.assertFalse(view["commands"][-1]["capture_next"])
        self.assertFalse(view["commands"][-1]["enabled"])
        self.assertEqual(view["next_cursor"], 2)
        self.assertFalse(state.stream_updates[-1]["data"]["capture_next"])

        # A later mode-only record must not make the legacy arm reappear on the
        # next restart just because the first migration was memory-only.
        state.set_command({"mode": "observe"})
        mode_restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertFalse(mode_restarted.config["capture_next"])
        mode_view = mode_restarted.get_commands(0, "s1")
        self.assertEqual(
            [command["revision"] for command in mode_view["commands"]],
            [1, 3, 4],
        )
        self.assertFalse(mode_view["commands"][-1]["enabled"])

        # The migration still leaves a clean path to a real, durable P1 arm.
        mode_restarted.set_command({"capture_next": True, "session_id": "s1"})
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertTrue(restarted.config["capture_next"])
        self.assertTrue(any(
            not grant["revoked"] and not grant["bound"]
            for grant in restarted.capture_grants.values()
        ))

    def test_stale_grant_snapshot_cannot_undo_revocation(self) -> None:
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state.hello({"session_id": "s1", "device_id": "d"})
        state.set_command({"capture_next": True, "session_id": "s1"})
        pending = dict(list(state.capture_grants.values())[-1])
        state.set_command({"capture_next": False})
        with state.journal_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"record_type": "capture_grant", "grant": pending}) + "\n")

        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        grant = restarted.capture_grants[pending["grant_id"]]
        self.assertTrue(grant["revoked"])
        self.assertFalse(restarted.config["capture_next"])
        self.assertGreaterEqual(restarted.replay_stats["skipped"], 1)
        with self.assertRaises(ApiError) as context:
            restarted.store_artifact(
                b"data", session_id="s1", filename="project.amproj", kind="amproj",
                metadata={"transaction": "tx-stale"},
            )
        self.assertEqual(context.exception.status, 403)


class RedactionContractTests(ContractServerTestCase):
    """Device-supplied text is scrubbed before it is stored or journaled."""

    def test_secrets_and_identifiers_are_redacted_in_stored_events(self) -> None:
        self.request(
            "/api/v1/events",
            "POST",
            {
                "session_id": "s1",
                "events": [
                    {
                        "type": "net",
                        "seq": 1,
                        "fields": {
                            "Authorization": "Bearer super-secret",
                            "cookie": "sid=abc",
                            "identifierForVendor": "AAAA-BBBB-CCCC",
                            "message": "GET https://api.example.com/v1?token=zzz&id=5 failed",
                            "path": "/Users/alice/Library/proj.amproj",
                        },
                    }
                ],
            },
        )
        _, events = self.request("/api/v1/events?session=s1")
        fields = events["events"][0]["payload"]["fields"]
        self.assertEqual(fields["Authorization"], "[redacted]")
        self.assertEqual(fields["cookie"], "[redacted]")
        self.assertTrue(fields["identifierForVendor"].startswith("ifv:"))
        self.assertNotIn("AAAA-BBBB-CCCC", json.dumps(fields))
        self.assertNotIn("token=zzz", fields["message"])
        self.assertIn("[redacted]", fields["message"])
        self.assertNotIn("/Users/alice", fields["path"])
        # And nothing sensitive leaked into the on-disk journal either.
        journal = self.state.journal_path.read_text(encoding="utf-8")
        self.assertNotIn("super-secret", journal)
        self.assertNotIn("AAAA-BBBB-CCCC", journal)
        self.assertNotIn("token=zzz", journal)

    def test_structural_keys_are_not_redacted(self) -> None:
        # session/seq/type must survive so dedup and filtering keep working.
        self.request(
            "/api/v1/events",
            "POST",
            {"session_id": "keepme", "events": [{"type": "stage", "seq": 3}]},
        )
        _, events = self.request("/api/v1/events?session=keepme")
        self.assertEqual(events["events"][0]["session_id"], "keepme")
        self.assertEqual(events["events"][0]["payload"]["seq"], 3)

    def test_hello_device_id_is_hashed_not_stored_raw(self) -> None:
        self.request(
            "/api/v1/hello", "POST", {"session_id": "s1", "device_id": "RAW-VENDOR-ID"}
        )
        _, sessions = self.request("/api/v1/sessions")
        session = sessions["sessions"][0]
        self.assertTrue(session["device_id"].startswith("ifv:"))
        self.assertNotIn("RAW-VENDOR-ID", json.dumps(session))
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)
        self.assertEqual(restarted.sessions["s1"]["device_id"], session["device_id"])

    def test_quoted_secret_edges_never_reach_journal_get_or_stream(self) -> None:
        cases = [
            (r'{"token":"prefix\"AAA,LEAK_MARKER_0"}', "LEAK_MARKER_0", None),
            ('token="prefix\nLEAK_MARKER_1" tail', "LEAK_MARKER_1", None),
            (r'{\"token\":\"prefix\\\"AAA,LEAK_MARKER_2', "LEAK_MARKER_2", None),
            ('{\\"token\\":\\"prefix\r\nLEAK_MARKER_3\\"}', "LEAK_MARKER_3", None),
            (
                '{"token":\n"CROSS_LINE_SECRET_4"} SAFE_TAIL_PLAIN',
                "CROSS_LINE_SECRET_4",
                "SAFE_TAIL_PLAIN",
            ),
        ]
        for depth in (1, 2, 3, 8):
            escape = "\\" * depth
            marker = f"CROSS_LINE_SECRET_ESCAPED_{depth}"
            safe_tail = f"SAFE_TAIL_ESCAPED_{depth}"
            cases.append((
                f'{{{escape}"token{escape}":\r\n{escape}"{marker}{escape}"}} {safe_tail}',
                marker,
                safe_tail,
            ))
        for seq, (raw, marker, safe_tail) in enumerate(cases, start=1):
            status, response = self.request(
                "/api/v1/events", "POST",
                {"session_id": "s1", "type": "log", "seq": seq, "message": raw},
            )
            self.assertEqual(status, 202)
            _, listed = self.request("/api/v1/events?session_id=s1")
            surfaces = {
                "post": json.dumps(response),
                "journal": self.state.journal_path.read_text(encoding="utf-8"),
                "get": json.dumps(listed),
                "stream": json.dumps(list(self.state.stream_updates)),
            }
            for name, surface in surfaces.items():
                self.assertNotIn(marker, surface, name)
                self.assertIn("[redacted]", surface, name)
                if safe_tail is not None:
                    self.assertIn(safe_tail, surface, name)


class RedactionCoverageTests(unittest.TestCase):
    """Pure redaction coverage for the full key set and inline-text patterns."""

    def test_all_required_secret_keys_are_redacted(self) -> None:
        # Every key the reviewer enumerated, in assorted casings/separators, is
        # redacted after normalization.
        payload = {
            "authToken": "a", "auth_token": "a", "accessToken": "b",
            "access-token": "b", "refreshToken": "c", "refresh_token": "c",
            "apiKey": "d", "api_key": "d", "Authorization": "e",
            "Cookie": "f", "Set-Cookie": "f", "bearer": "g",
            "password": "h", "passwd": "h", "secret": "i", "sessionToken": "j",
            "license_key": "k", "cardKey": "l", "private_key": "m",
        }
        result = redact_value(payload)
        for key in payload:
            self.assertEqual(result[key], "[redacted]", key)

    def test_all_required_identifier_keys_are_hashed(self) -> None:
        for key in ("IFV", "idfa", "UDID", "identifierForVendor", "deviceId",
                    "device_id", "vendor_id", "advertisingId", "idfv"):
            result = redact_value({key: "RAW-VALUE-1234"})
            self.assertTrue(
                str(result[key]).startswith("ifv:"), f"{key} -> {result[key]}"
            )
            self.assertNotIn("RAW-VALUE-1234", json.dumps(result))

    def test_inline_secrets_in_free_text_are_scrubbed(self) -> None:
        # (text, the exact secret substring that MUST be gone afterward)
        cases = [
            ("Authorization: Bearer eyJhbGciOi.J9.abc", "eyJhbGciOi.J9.abc"),
            ("Cookie: session=deadbeef; other=1", "deadbeef"),
            ("failed with token=SUPERSECRET99", "SUPERSECRET99"),
            ("x-access-token=abc.def.ghi returned 401", "abc.def.ghi"),
            ("access_token=zzz refresh_token=yyy", "zzz"),
            ("license_key=LIC-SECRET-1 card_key=CARD-SECRET-2", "LIC-SECRET-1"),
            ("license_key=LIC-SECRET-1 card_key=CARD-SECRET-2", "CARD-SECRET-2"),
            ("private_key=PRIVATE-SECRET-3", "PRIVATE-SECRET-3"),
            ('token="QUOTED-SECRET-4"', "QUOTED-SECRET-4"),
            ("password='QUOTED-SECRET-5'", "QUOTED-SECRET-5"),
            ('{"token":"JSON-SECRET-6"}', "JSON-SECRET-6"),
        ]
        for text, secret in cases:
            scrubbed = redact_text(text)
            self.assertIn("[redacted]", scrubbed, text)
            self.assertNotIn(secret, scrubbed, text)  # original value fully gone
        # A bare bearer token anywhere in the string is removed entirely.
        bearer = redact_text("prefix Bearer AbC123.dEf-456 suffix")
        self.assertIn("[redacted]", bearer)
        self.assertNotIn("AbC123.dEf-456", bearer)

    def test_escaped_json_and_secret_suffixes_are_scrubbed(self) -> None:
        escaped_cases = (
            r'{\"token\":\"ESCAPED_JSON_SECRET\"}',
            r'{\\"token\\":\\"DOUBLE_ESCAPED_JSON_SECRET\\"}',
            r'{\\\"token\\\":\\\"TRIPLE_ESCAPED_JSON_SECRET\\\"}',
        )
        for escaped in escaped_cases:
            scrubbed = redact_text(escaped)
            self.assertNotIn("JSON_SECRET", scrubbed)
            self.assertIn("[redacted]", scrubbed)

        for depth in (1, 2, 3, 16):
            escape = "\\" * depth
            unterminated = (
                f'{{{escape}"token{escape}":{escape}"'
                f'UNTERMINATED_{depth}_JSON_SECRET'
            )
            scrubbed = redact_text(unterminated)
            self.assertNotIn("JSON_SECRET", scrubbed, unterminated)
            self.assertIn("[redacted]", scrubbed, unterminated)

        plain_unterminated = '{"token":"PLAIN_UNTERMINATED_JSON_SECRET'
        plain_scrubbed = redact_text(plain_unterminated)
        self.assertNotIn("JSON_SECRET", plain_scrubbed)
        self.assertIn("[redacted]", plain_scrubbed)

        escaped_quote = r'{"token":"prefix\"AAA,LEAK_MARKER"}'
        self.assertEqual(json.loads(escaped_quote)["token"], 'prefix"AAA,LEAK_MARKER')
        escaped_quote_scrubbed = redact_text(escaped_quote)
        self.assertIn("[redacted]", escaped_quote_scrubbed)
        self.assertNotIn("LEAK_MARKER", escaped_quote_scrubbed)

        unterminated_escaped_quote = r'{"token":"prefix\"AAA,LEAK_MARKER'
        unterminated_scrubbed = redact_text(unterminated_escaped_quote)
        self.assertIn("[redacted]", unterminated_scrubbed)
        self.assertNotIn("LEAK_MARKER", unterminated_scrubbed)

        edge_cases = (
            'token="prefix\nMULTILINE_SECRET" tail',
            "password='prefix\r\nMULTILINE_SECRET' tail",
            'Authorization: "prefix\nMULTILINE_SECRET" tail',
            'Cookie: "prefix\r\nMULTILINE_SECRET" tail',
            '{\\"token\\":\\"prefix\rMULTILINE_SECRET\\"}',
            r'{\"token\":\"prefix\\\"AAA,ESCAPED_UNTERMINATED_SECRET',
        )
        for raw in edge_cases:
            scrubbed = redact_text(raw)
            self.assertIn("[redacted]", scrubbed, raw)
            self.assertNotIn("MULTILINE_SECRET", scrubbed, raw)
            self.assertNotIn("ESCAPED_UNTERMINATED_SECRET", scrubbed, raw)
            self.assertEqual(redact_text(scrubbed), scrubbed, raw)

        for line_break in ("\n", "\r\n", "\r"):
            for placement, before_colon, after_colon in (
                ("after", "", line_break),
                ("before", line_break, ""),
                ("both", line_break, line_break),
            ):
                for depth in (0, 1, 2, 3, 8):
                    escape = "\\" * depth
                    marker = (
                        f"CROSS_LINE_SECRET_{len(line_break)}_{placement}_{depth}"
                    )
                    raw = (
                        f'{{{escape}"token{escape}"{before_colon}:'
                        f'{after_colon}{escape}"{marker}{escape}"}} tail'
                    )
                    scrubbed = redact_text(raw)
                    self.assertIn("[redacted]", scrubbed, raw)
                    self.assertNotIn(marker, scrubbed, raw)
                    self.assertTrue(scrubbed.endswith(" tail"), raw)
                    self.assertEqual(redact_text(scrubbed), scrubbed, raw)

        long_key = "a" * 256 + "token"
        result = redact_value({long_key: "LONG_KEY_SECRET"})
        self.assertNotIn("LONG_KEY_SECRET", json.dumps(result))
        self.assertEqual(next(iter(result.values())), "[redacted]")

    def test_full_authorization_and_cookie_headers_are_scrubbed(self) -> None:
        cases = [
            ("Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
            ("Cookie: benign=1; session=SECOND-SECRET", "SECOND-SECRET"),
            ("Set-Cookie: benign=1; token=LATER-SECRET", "LATER-SECRET"),
        ]
        for raw, secret in cases:
            scrubbed = redact_text(raw)
            self.assertIn("[redacted]", scrubbed)
            self.assertNotIn(secret, scrubbed)

    def test_sensitive_text_inside_dynamic_keys_is_scrubbed(self) -> None:
        result = redact_value({
            "token=KEY-SECRET": 1,
            "Authorization: Basic KEY-CREDENTIAL": 2,
            "https://example.invalid/x?secret=QUERY-SECRET": 3,
        })
        serialized = json.dumps(result)
        for secret in ("KEY-SECRET", "KEY-CREDENTIAL", "QUERY-SECRET"):
            self.assertNotIn(secret, serialized)

    def test_reviewer_reported_inputs_fully_redacted(self) -> None:
        # Exact reproductions from the review, asserting the ORIGINAL sensitive
        # value is completely absent (not merely that [redacted] appears).
        # (2) Authorization + Bearer JWT with a trailing clause.
        t2 = redact_text("Authorization: Bearer eyJ.SECRET.SIG; failed")
        self.assertNotIn("eyJ.SECRET.SIG", t2)
        self.assertNotIn("SECRET", t2)
        # (3) Spaced project-title paths, POSIX and Windows: basename gone too.
        for path in ("/Users/alice/Movies/My Secret Project.amproj",
                     r"C:\Users\alice\My Secret Project.amproj"):
            scrubbed = redact_text(path)
            self.assertNotIn("Secret Project", scrubbed)
            self.assertNotIn(".amproj", scrubbed)
            self.assertNotIn("alice", scrubbed)

    def test_relational_ids_are_kept_verbatim(self) -> None:
        # (1) transaction / session / trace / span / request ids that look like
        # UUIDs must survive intact so dedup and correlation keep working.
        uuid_val = "123e4567-e89b-12d3-a456-426614174000"
        for key in ("transaction", "session", "trace_id", "span_id",
                    "request_id", "correlation_id", "seq"):
            result = redact_value({key: uuid_val})
            self.assertEqual(result[key], uuid_val, key)
        # But a UUID in FREE text (a plain key) is still scrubbed.
        self.assertEqual(redact_value({"note": uuid_val})["note"], "[redacted-id]")

    def test_relational_ids_scrub_secrets_and_paths(self) -> None:
        result = redact_value({
            "session": "Bearer LEAK-TOKEN",
            "transaction": "/Users/alice/Secret Project.amproj",
            "trace_id": "Cookie: sid=TRACE-SECRET",
        })
        serialized = json.dumps(result)
        for secret in ("LEAK-TOKEN", "alice", "Secret Project", "TRACE-SECRET"):
            self.assertNotIn(secret, serialized)
        self.assertIn("[redacted]", serialized)
        self.assertIn("[redacted-path]", serialized)

    def test_relational_id_is_length_capped(self) -> None:
        # Kept verbatim, but a hostile oversized id is still bounded.
        result = redact_value({"transaction": "t" * 10_000})
        self.assertLessEqual(len(result["transaction"]), 256)

    def test_session_token_key_is_secret_not_relational(self) -> None:
        # "session_token" contains "session" but must be treated as a SECRET.
        result = redact_value({"session_token": "abc123", "session": "keep-me"})
        self.assertEqual(result["session_token"], "[redacted]")
        self.assertEqual(result["session"], "keep-me")

    def test_enum_structural_fields_are_scrubbed_not_kept_verbatim(self) -> None:
        # (1) type/kind/level/stage/mode/timestamp are STRUCTURAL enums but their
        # TEXT is still scrubbed — a hostile value must not ride through them.
        result = redact_value({
            "type": "Authorization: Bearer eyJ.SECRET.SIG",
            "stage": "/Users/alice/My Secret Project.amproj",
            "kind": "token=LEAK99",
            "level": "info",   # a normal enum survives (scrubbed no-op)
            "mode": "full",
        })
        blob = json.dumps(result)
        for secret in ("eyJ.SECRET.SIG", "SECRET", "My Secret Project",
                       "/Users/alice", ".amproj", "LEAK99"):
            self.assertNotIn(secret, blob, secret)
        self.assertEqual(result["level"], "info")
        self.assertEqual(result["mode"], "full")

    def test_enum_field_is_length_capped(self) -> None:
        result = redact_value({"type": "t" * 500})
        self.assertLessEqual(len(result["type"]), 128)

    def test_nested_device_id_and_bare_id_are_hashed(self) -> None:
        # (1) nested device.id / a bare id / IFV / IDFA / UDID must be HASHED,
        # never kept verbatim.
        result = redact_value({
            "device": {"id": "RAW-VENDOR-UUID", "model": "iPhone"},
            "id": "ENTITY-RAW-ID",
            "ifv": "IFV-RAW", "idfa": "IDFA-RAW", "udid": "UDID-RAW",
        })
        self.assertTrue(result["device"]["id"].startswith("ifv:"))
        self.assertTrue(result["id"].startswith("ifv:"))
        for key in ("ifv", "idfa", "udid"):
            self.assertTrue(result[key].startswith("ifv:"), key)
        blob = json.dumps(result)
        for raw in ("RAW-VENDOR-UUID", "ENTITY-RAW-ID", "IFV-RAW", "IDFA-RAW", "UDID-RAW"):
            self.assertNotIn(raw, blob, raw)
        # A non-identifier sibling in the same nested dict is preserved.
        self.assertEqual(result["device"]["model"], "iPhone")

    def test_ifv_uuid_in_free_text_is_scrubbed(self) -> None:
        text = "device 12345678-1234-1234-1234-1234567890ab connected"
        scrubbed = redact_text(text)
        self.assertNotIn("12345678-1234-1234-1234-1234567890ab", scrubbed)
        self.assertIn("[redacted-id]", scrubbed)

    def test_local_paths_lose_full_path_and_basename(self) -> None:
        # Neither the directory NOR the basename (which could be a project
        # title) may survive.
        posix = redact_text("wrote /Users/alice/Movies/My Secret Project.amproj ok")
        self.assertNotIn("/Users/alice", posix)
        self.assertNotIn("My Secret Project", posix)
        self.assertIn("[redacted-path]", posix)
        windows = redact_text(r"saved C:\Users\bob\Desktop\Confidential.amproj done")
        self.assertNotIn(r"C:\Users\bob", windows)
        self.assertNotIn("Confidential", windows)
        self.assertIn("[redacted-path]", windows)

    def test_url_query_is_dropped_but_host_kept(self) -> None:
        scrubbed = redact_text("GET https://user:pw@api.example.com/v1/x?token=zzz&a=1")
        self.assertIn("api.example.com/v1/x", scrubbed)
        self.assertNotIn("token=zzz", scrubbed)
        self.assertNotIn("user:pw", scrubbed)

    def test_recursion_and_size_bounds(self) -> None:
        # Deeply nested dict is truncated at MAX_REDACT_DEPTH, not a stack blow.
        deep: dict = {}
        node = deep
        for _ in range(50):
            node["n"] = {}
            node = node["n"]
        node["authToken"] = "x"
        redacted = redact_value(deep)  # must not raise
        self.assertIn("max-depth", json.dumps(redacted))
        # Oversized string is capped.
        big = redact_value({"msg": "a" * (MAX_JSON_BYTES)})
        self.assertLess(len(big["msg"]), MAX_JSON_BYTES)
        self.assertIn("<truncated>", big["msg"])
        # Huge array is capped.
        arr = redact_value({"items": list(range(5000))})
        self.assertIn("<truncated>", arr["items"])
        self.assertLessEqual(len(arr["items"]), 513)
        # Huge key count is capped.
        wide = redact_value({f"k{i}": i for i in range(1000)})
        self.assertTrue(wide.get("_truncated"))

    # -- Redaction idempotency (guards the dedup fingerprint invariant) -------
    #
    # add_events fingerprints a ONCE-redacted payload, but the hot cache
    # (_apply_record re-redacts record.payload) and the cold journal scan
    # (_lookup_committed_event_locked re-redacts the stored payload) fingerprint
    # a TWICE-redacted payload. Dedup correctness therefore REQUIRES
    #   redact(redact(x)) == redact(x)   and   fingerprint stability across it.
    # These inputs deliberately contain secrets/paths/UUIDs that redaction
    # actually REWRITES, so a non-idempotent regression is caught here (the
    # secret-free dedup tests would pass trivially and miss it).

    IDEMPOTENCY_TEXT_CASES = [
        "Authorization: Bearer eyJhbGciOi.J9.payload.sig; retry",
        "Cookie: sid=deadbeefcafe; theme=dark",
        "token=SUPERSECRET99 refresh_token=OTHER-SECRET",
        "opened /Users/alice/Movies/My Secret Project.amproj then failed",
        r"saved C:\Users\bob\Desktop\Confidential Client.amproj ok",
        "device 12345678-1234-1234-1234-1234567890ab connected",
        "GET https://user:pw@api.example.com/v1/x?token=zzz&a=1 -> 500",
        # multiline: a distinct secret shape on every line
        "line1 Authorization: Bearer AAA.BBB.CCC\n"
        "line2 Cookie: k=v\n"
        "line3 /var/mobile/Containers/Secret.amproj\n"
        "line4 token=LEAK plain tail",
        # already-redacted markers must survive a second pass unchanged
        "prefix [redacted] mid [redacted-path] end [redacted-id]",
        "Bearer [redacted] and token: [redacted]",
    ]

    def test_redact_text_is_idempotent(self) -> None:
        for text in self.IDEMPOTENCY_TEXT_CASES:
            once = redact_text(text)
            twice = redact_text(once)
            self.assertEqual(once, twice, f"redact_text not idempotent for: {text!r}")

    def test_redact_value_and_fingerprint_are_idempotent(self) -> None:
        # A realistic device event payload carrying secrets under several key
        # classes (secret / identifier / enum / relational / plain free text).
        payload = {
            "type": "stage",
            "seq": 42,
            "session": "sess-abc",
            "transaction": "123e4567-e89b-12d3-a456-426614174000",
            "device_id": "RAW-VENDOR-UUID-1234",
            "fields": {
                "Authorization": "Bearer eyJ.SECRET.SIG",
                "cookie": "sid=deadbeef",
                "message": "wrote /Users/alice/My Secret Project.amproj\n"
                           "with token=INLINELEAK on line two",
                "note": "device 12345678-1234-1234-1234-1234567890ab",
                "nested": [{"password": "p"}, {"detail": "Bearer QQQ.WWW.EEE"}],
            },
        }
        once = redact_value(payload)
        twice = redact_value(once)
        # Structural equality across a second pass.
        self.assertEqual(once, twice)
        # The exact invariant add_events vs the hot/cold dedup paths rely on.
        self.assertEqual(payload_fingerprint(once), payload_fingerprint(twice))
        # And the original secrets are genuinely gone (not merely marked).
        blob = json.dumps(once)
        for secret in ("eyJ.SECRET.SIG", "SECRET", "deadbeef", "INLINELEAK",
                       "My Secret Project", "/Users/alice", "RAW-VENDOR-UUID-1234",
                       "QQQ.WWW.EEE", "12345678-1234-1234-1234-1234567890ab"):
            self.assertNotIn(secret, blob, secret)
        # The relational transaction UUID is preserved verbatim (dedup/join key).
        self.assertEqual(once["transaction"], "123e4567-e89b-12d3-a456-426614174000")

    def test_fingerprint_stable_under_triple_redaction(self) -> None:
        # Three passes (first commit, hot re-apply, cold journal scan) all agree.
        payload = {"type": "log", "seq": 7,
                   "fields": {"msg": "Bearer AAA.BBB.CCC at /var/mobile/x.amproj"}}
        f1 = payload_fingerprint(redact_value(payload))
        f2 = payload_fingerprint(redact_value(redact_value(payload)))
        f3 = payload_fingerprint(redact_value(redact_value(redact_value(payload))))
        self.assertEqual(f1, f2)
        self.assertEqual(f2, f3)


class DedupDurabilityTests(unittest.TestCase):
    """(session, seq) idempotency is independent of the display ring buffer."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_dedup_key_survives_ring_buffer_eviction(self) -> None:
        # The dedup index must NOT be evicted alongside the display ring. Shrink
        # the visible window, overflow it, then retry the very first seq: it must
        # still return the original id and add no new event.
        self.assertGreater(MAX_DEDUP_KEYS, MAX_IN_MEMORY_EVENTS)
        original = self.state.events.maxlen
        # Rebind events to a tiny ring to force eviction cheaply.
        self.state.events = type(self.state.events)(maxlen=5)
        first = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        first_id = first[0]["id"]
        # Push far more than the visible ring capacity.
        for seq in range(2, 40):
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": seq}]})
        self.assertEqual(len(self.state.events), 5)  # ring overflowed
        # Retry seq=1, long gone from the ring but retained in the dedup index.
        retry = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        self.assertEqual(retry[0]["id"], first_id)
        self.assertTrue(retry[0].get("duplicate"))
        # No new event was appended by the retry.
        self.assertEqual(self.state.event_id, 39)

    def test_same_seq_different_payload_is_a_logged_conflict(self) -> None:
        self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1, "fields": {"v": 1}}]}
        )
        # Same (session, seq), different content -> deterministic conflict, not
        # a silent overwrite.
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events(
                {"session_id": "s1", "events": [{"type": "e", "seq": 1, "fields": {"v": 2}}]}
            )
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(self.state.dedup_conflicts, 1)
        # The original is intact and unchanged.
        self.assertEqual(self.state.events[0]["payload"]["fields"]["v"], 1)

    def test_identical_retry_is_not_a_conflict(self) -> None:
        self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1, "fields": {"v": 1}}]}
        )
        # Byte-identical retry: idempotent, no conflict counted.
        self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1, "fields": {"v": 1}}]}
        )
        self.assertEqual(self.state.dedup_conflicts, 0)
        self.assertEqual(len(self.state.events), 1)

    # A payload whose fields redaction actually REWRITES (Bearer token, local
    # path, IFV UUID). These exercise the fingerprint-idempotency dependency
    # end-to-end — the secret-free tests above cannot, because redact(x)≈x there.
    SECRET_EVENT = {
        "type": "net", "seq": 1,
        "fields": {
            "Authorization": "Bearer eyJ.SECRET.SIG",
            "message": "wrote /Users/alice/My Secret Project.amproj",
            "device": "12345678-1234-1234-1234-1234567890ab",
        },
    }

    def test_secret_bearing_retry_is_deduped_hot_cache(self) -> None:
        first = self.state.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        first_id = first[0]["id"]
        # Identical retry while the key is still in the hot cache. The stored
        # fingerprint is twice-redacted; the retry recomputes once-redacted — they
        # must agree, so this is a duplicate, NOT a spurious 409.
        retry = self.state.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        self.assertTrue(retry[0].get("duplicate"), "secret-bearing hot retry misclassified")
        self.assertEqual(retry[0]["id"], first_id)
        self.assertEqual(self.state.dedup_conflicts, 0)
        self.assertEqual(len([e for e in self.state.events if e["payload"].get("seq") == 1]), 1)

    def test_secret_bearing_retry_is_deduped_cold_journal_after_eviction(self) -> None:
        # Force the cold-journal lookup path (hot cache evicted).
        self.state.max_dedup_keys = 3
        first = self.state.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        first_id = first[0]["id"]
        for seq in range(2, 12):
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": seq}]})
        self.assertNotIn(("s1", 1), self.state.event_keys)  # evicted
        # Retry resolves via _lookup_committed_event_locked (twice-redacted
        # stored payload vs once-redacted retry) — must dedupe, not 409.
        retry = self.state.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        self.assertTrue(retry[0].get("duplicate"), "secret-bearing cold retry misclassified")
        self.assertEqual(retry[0]["id"], first_id)
        self.assertEqual(self.state.dedup_conflicts, 0)

    def test_secret_bearing_retry_is_deduped_after_restart(self) -> None:
        self.state.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        first_id = self.state.events[0]["id"]
        # Restart: the fingerprint is rebuilt from the (once-redacted, journaled)
        # payload during replay; a retry must still be recognized as a duplicate.
        restarted = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        retry = restarted.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        self.assertTrue(retry[0].get("duplicate"), "secret-bearing retry after restart misclassified")
        self.assertEqual(retry[0]["id"], first_id)
        self.assertEqual(restarted.dedup_conflicts, 0)

    def test_secret_bearing_genuine_conflict_still_detected(self) -> None:
        # Same (session, seq) but a DIFFERENT secret-bearing payload is still a
        # real 409 — idempotency must not mask genuine conflicts.
        self.state.add_events({"session_id": "s1", "events": [dict(self.SECRET_EVENT)]})
        conflicting = {"type": "net", "seq": 1,
                       "fields": {"Authorization": "Bearer eyJ.DIFFERENT.SIG"}}
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events({"session_id": "s1", "events": [conflicting]})
        self.assertEqual(ctx.exception.status, 409)

    def test_seq_after_redaction_key_limit_remains_dedupable(self) -> None:
        event = {"type": "wide"}
        event.update({f"field_{index}": index for index in range(300)})
        event["seq"] = "42"  # deliberately after the 256-key sanitizer limit
        first = self.state.add_events({"session_id": "s1", "events": [event]})
        self.assertEqual(self.state.events[0]["payload"]["seq"], 42)
        retry = self.state.add_events({"session_id": "s1", "events": [event]})
        self.assertTrue(retry[0]["duplicate"])
        self.assertEqual(retry[0]["id"], first[0]["id"])
        restarted = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        after_restart = restarted.add_events({"session_id": "s1", "events": [event]})
        self.assertTrue(after_restart[0]["duplicate"])
        self.assertEqual(len(restarted.events), 1)

    def test_journal_dedup_scan_ignores_non_objects_and_invalid_events(self) -> None:
        invalid_event = {
            "record_type": "event", "id": 77, "session_id": "s1",
            "received_at": "2026-01-01T00:00:00.000Z",
            "payload": {"type": "e", "seq": 7},
        }
        self.state.journal_path.write_text(
            json.dumps(["event"]) + "\n" + json.dumps(invalid_event) + "\n",
            encoding="utf-8",
        )
        restarted = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        self.assertEqual(restarted.replay_stats, {"replayed": 0, "skipped": 2})
        accepted = restarted.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 7}]}
        )
        self.assertFalse(accepted[0].get("duplicate", False))
        self.assertEqual(accepted[0]["id"], 1)
        self.assertEqual(len(restarted.events), 1)

    def test_mid_batch_conflict_writes_nothing_from_the_batch(self) -> None:
        # (4) new + conflicting + new in one batch: the conflict aborts the WHOLE
        # batch (409) and NONE of the batch's events are written — no half-batch.
        self.state.add_events(
            {"session_id": "s1", "events": [{"type": "a", "seq": 1, "fields": {"v": 1}}]}
        )
        before_events = len(self.state.events)
        before_stream = self.state.stream_id
        before_id = self.state.event_id
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events({"session_id": "s1", "events": [
                {"type": "new", "seq": 10},
                {"type": "conflict", "seq": 1, "fields": {"v": 999}},  # conflicts committed seq 1
                {"type": "new2", "seq": 11},
            ]})
        self.assertEqual(ctx.exception.status, 409)
        # Nothing from the batch was committed: counts, cursor, id all unchanged.
        self.assertEqual(len(self.state.events), before_events)
        self.assertEqual(self.state.stream_id, before_stream)
        self.assertEqual(self.state.event_id, before_id)
        # seq 10 and 11 were NOT stored (would-be-new events rolled back).
        self.assertNotIn(("s1", 10), self.state.event_keys)
        self.assertNotIn(("s1", 11), self.state.event_keys)

    def test_in_batch_duplicate_resolves_to_first_committed_id(self) -> None:
        # Two identical (session, seq) in ONE batch: the first commits, the
        # second is a duplicate reporting the first's id — one event stored.
        result = self.state.add_events({"session_id": "s1", "events": [
            {"type": "e", "seq": 5, "fields": {"v": 1}},
            {"type": "e", "seq": 5, "fields": {"v": 1}},
        ]})
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["id"], result[1]["id"])
        self.assertTrue(result[1].get("duplicate"))
        self.assertEqual(len([e for e in self.state.events if e["payload"].get("seq") == 5]), 1)

    def test_in_batch_conflict_is_rejected(self) -> None:
        # Same seq twice in one batch with DIFFERENT payloads -> 409, no writes.
        before = len(self.state.events)
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events({"session_id": "s1", "events": [
                {"type": "e", "seq": 7, "fields": {"v": 1}},
                {"type": "e", "seq": 7, "fields": {"v": 2}},
            ]})
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(len(self.state.events), before)


class JournalAtomicityTests(unittest.TestCase):
    """A journal write failure must yield a retryable error and no side effect."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _break_journal(self) -> None:
        def boom(record):
            raise JournalWriteError("disk full (simulated)")

        self.state._append_journal_line = boom  # type: ignore[assignment]

    def test_event_write_failure_leaves_no_phantom_and_is_retryable(self) -> None:
        events_before = len(self.state.events)
        stream_before = self.state.stream_id
        event_id_before = self.state.event_id
        self._break_journal()
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 1}]})
        self.assertEqual(ctx.exception.status, 503)  # retryable
        # No in-memory side effect: no event, no id burn, no cursor bump.
        self.assertEqual(len(self.state.events), events_before)
        self.assertEqual(self.state.stream_id, stream_before)
        self.assertEqual(self.state.event_id, event_id_before)
        self.assertNotIn(("s1", 1), self.state.event_keys)

    def test_same_seq_can_succeed_after_a_failed_write(self) -> None:
        self._break_journal()
        with self.assertRaises(ApiError):
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 1}]})
        # Repair the journal; the SAME (session, seq) must now save (the failed
        # attempt did not poison the dedup index).
        self.state._append_journal_line = server_module.BackendState._append_journal_line.__get__(
            self.state, server_module.BackendState
        )
        accepted = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        self.assertEqual(len(accepted), 1)
        self.assertFalse(accepted[0].get("duplicate"))
        self.assertEqual(len(self.state.events), 1)

    def test_artifact_write_failure_removes_orphan_file(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        session_dir = self.state.artifact_dir / "s1"
        self._break_journal()
        with self.assertRaises(ApiError) as ctx:
            self.state.store_artifact(
                b"data", session_id="s1", filename="a.amproj", kind="amproj",
                metadata={"transaction": "tx-1"},
            )
        self.assertEqual(ctx.exception.status, 503)
        # No orphaned blob left behind.
        leftover = list(session_dir.glob("*")) if session_dir.exists() else []
        self.assertEqual(leftover, [])


class SSEContinuityTests(ContractServerTestCase):
    def test_cursor_too_old_emits_reset(self) -> None:
        # Force a tiny stream buffer so an old cursor falls out of the window.
        self.state.stream_updates = type(self.state.stream_updates)(maxlen=3)
        for i in range(6):
            self.request("/api/v1/events", "POST", {"session_id": "s1", "type": f"e{i}"})
        # Cursor 1 is now far behind the oldest buffered update.
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            connection.request(
                "GET", "/api/v1/stream?after=1",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.readline(), b": connected\n")
            self.assertEqual(response.readline(), b"\n")
            self.assertEqual(response.readline(), b"event: reset\n")
            data_line = response.readline()
            self.assertTrue(data_line.startswith(b"data: "))
            reset = json.loads(data_line[len(b"data: "):])
            self.assertEqual(reset["reason"], "cursor_too_old")
            self.assertIn("current_stream_id", reset)
        finally:
            connection.close()

    def test_recoverable_cursor_does_not_reset(self) -> None:
        self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "seed"})
        cursor = self.state.stream_id
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            connection.request(
                "GET", f"/api/v1/stream?after={cursor}",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
            response = connection.getresponse()
            self.assertEqual(response.readline(), b": connected\n")
            self.assertEqual(response.readline(), b"\n")
            # A fresh event should arrive normally (no reset frame first).
            self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "fresh"})
            self.assertEqual(response.readline(), f"id: {cursor + 1}\n".encode("ascii"))
        finally:
            connection.close()

    def test_cursor_survives_restart_and_keeps_increasing(self) -> None:
        # Same directory, new state: the cursor continues beyond the old max.
        self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "a"})
        before = self.state.stream_id
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)
        self.assertEqual(restarted.stream_id, before)
        restarted.add_events({"session_id": "s1", "events": [{"type": "b", "seq": 1}]})
        self.assertEqual(restarted.stream_id, before + 1)


class SessionRecoveryTests(unittest.TestCase):
    """last_seen driven by events/polls/acks/artifacts survives a restart."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _fresh(self):
        # A zero-interval touch policy so every activity persists immediately.
        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        state_touch_zero(state)
        return state

    def test_event_activity_last_seen_recovers(self) -> None:
        state = self._fresh()
        state.hello({"session_id": "s1", "device_id": "d"})
        hello_seen = state.sessions["s1"]["last_seen"]
        state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 1}]})
        after_event = state.sessions["s1"]["last_seen"]
        self.assertGreaterEqual(after_event, hello_seen)
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual(restarted.sessions["s1"]["last_seen"], after_event)

    def test_command_poll_and_ack_last_seen_recovers(self) -> None:
        state = self._fresh()
        state.hello({"session_id": "s1", "device_id": "d"})
        state.get_commands(after_revision=0, session_id="s1")
        state.acknowledge_commands({"session": "s1", "acknowledged": [1]})
        after_ack = state.sessions["s1"]["last_seen"]
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual(restarted.sessions["s1"]["last_seen"], after_ack)

    def test_artifact_last_seen_recovers(self) -> None:
        state = self._fresh()
        state.hello({"session_id": "s1", "device_id": "d"})
        state.set_command({"capture_next": True, "session_id": "s1"})
        state.store_artifact(
            b"data", session_id="s1", filename="a.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        after_artifact = state.sessions["s1"]["last_seen"]
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertEqual(restarted.sessions["s1"]["last_seen"], after_artifact)


def state_touch_zero(state) -> None:
    """Force the rate-limited poll heartbeat to persist on every call, so a
    poll's last_seen update is journaled (and thus recoverable) in tests."""
    real = server_module.BackendState._persist_poll_touch_locked

    def persist(session_id: str) -> None:
        state._last_touch_persist[session_id] = 0.0  # reset the rate-limit window
        real(state, session_id)

    state._persist_poll_touch_locked = persist  # type: ignore[assignment]


class FaultInjectionTests(unittest.TestCase):
    """Per-append fault injection for every record type, plus restart checks.

    Each test breaks the single journal-append boundary of one operation and
    asserts: (a) the call fails retryably (503/JournalWriteError), (b) in-memory
    state is byte-for-byte unchanged, and (c) a fresh BackendState over the same
    directory shows the operation as NOT committed."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.data_dir = Path(self.temp_dir.name)
        self.state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _break(self) -> None:
        def boom(record):
            raise JournalWriteError("simulated disk failure")
        self.state._append_journal_line = boom  # type: ignore[assignment]

    def _snapshot(self) -> dict:
        return {
            "events": len(self.state.events),
            "event_id": self.state.event_id,
            "stream_id": self.state.stream_id,
            "revision": self.state.config["revision"],
            "mode": self.state.config["mode"],
            "capture_next": self.state.config["capture_next"],
            "sessions": len(self.state.sessions),
            "commands": len(self.state.commands),
            "grants": [dict(g) for g in self.state.capture_grants.values()],
            "acks": {k: set(v) for k, v in self.state.command_acks.items()},
        }

    def _assert_unchanged(self, before: dict) -> None:
        self.assertEqual(self._snapshot(), before)

    def _restart(self) -> "BackendState":
        return BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

    # (1) + (2): per-record-type append failure -> memory + restart state clean.

    def test_hello_append_failure(self) -> None:
        before = self._snapshot()
        self._break()
        with self.assertRaises(ApiError) as ctx:
            self.state.hello({"session_id": "s1", "device_id": "d"})
        self.assertEqual(ctx.exception.status, 503)
        self._assert_unchanged(before)
        self.assertEqual(len(self._restart().sessions), 0)

    def test_event_append_failure(self) -> None:
        before = self._snapshot()
        self._break()
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 1}]})
        self.assertEqual(ctx.exception.status, 503)
        self._assert_unchanged(before)
        self.assertEqual(len(self._restart().events), 0)

    def test_capture_expiry_append_failure_has_no_partial_memory_state(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.capture_grant_ttl = -1.0
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        before = self._snapshot()
        journal_before = self.state.journal_path.read_bytes()
        cursor = self.state.config["revision"]
        self._break()

        with self.assertRaises(ApiError) as context:
            self.state.get_commands(cursor, "s1")

        self.assertEqual(context.exception.status, 503)
        self._assert_unchanged(before)
        self.assertEqual(self.state.journal_path.read_bytes(), journal_before)

    def test_fsync_error_after_full_event_write_is_rolled_back(self) -> None:
        real_fsync = os.fsync
        calls = 0

        def fsync_then_report_failure(fd):
            nonlocal calls
            calls += 1
            real_fsync(fd)  # bytes really reached the filesystem first
            if calls == 1:
                raise OSError("simulated post-fsync error")

        server_module.os.fsync = fsync_then_report_failure
        try:
            with self.assertRaises(ApiError) as ctx:
                self.state.add_events(
                    {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
                )
            self.assertEqual(ctx.exception.status, 503)
        finally:
            server_module.os.fsync = real_fsync

        self.assertFalse(self.state._journal_poisoned)
        self.assertEqual(self.state.journal_path.read_bytes(), b"")
        first = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        second = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 2}]}
        )
        self.assertEqual([first[0]["id"], second[0]["id"]], [1, 2])
        self.assertEqual([event["id"] for event in self._restart().events], [1, 2])

    def test_artifact_post_fsync_error_rolls_back_record_and_temp(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        real_fsync = os.fsync
        calls = 0

        def fail_journal_fsync_after_real_write(fd):
            nonlocal calls
            calls += 1
            real_fsync(fd)
            if calls == 2:  # temp fsync succeeds; journal fsync reports failure
                raise OSError("simulated post-fsync error")

        server_module.os.fsync = fail_journal_fsync_after_real_write
        try:
            with self.assertRaises(ApiError) as ctx:
                self.state.store_artifact(
                    b"data", session_id="s1", filename="a.amproj", kind="amproj",
                    metadata={"transaction": "tx-1"},
                )
            self.assertEqual(ctx.exception.status, 503)
        finally:
            server_module.os.fsync = real_fsync

        blobs = [p for p in self.state.artifact_dir.rglob("*") if p.is_file()]
        self.assertEqual(blobs, [])
        restarted = self._restart()
        self.assertEqual(len(restarted.artifact_keys), 0)
        pending = [grant for grant in restarted.capture_grants.values() if not grant["bound"]]
        self.assertEqual(len(pending), 1)

    def test_unencodable_journal_record_is_wrapped_and_cleans_artifact_temp(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        before = self.state.journal_path.read_bytes()
        real_dumps = server_module.json.dumps
        server_module.json.dumps = lambda *args, **kwargs: "\ud800"
        try:
            with self.assertRaises(ApiError) as context:
                self.state.store_artifact(
                    b"data", session_id="s1", filename="project.amproj", kind="amproj",
                    metadata={"transaction": "tx-1"},
                )
            self.assertEqual(context.exception.status, 503)
        finally:
            server_module.json.dumps = real_dumps
        self.assertEqual(self.state.journal_path.read_bytes(), before)
        self.assertEqual(list(self.state.artifact_dir.rglob("*.tmp-*")), [])
        self.assertEqual(len(self.state.artifact_keys), 0)

    def test_unreadable_journal_fails_closed_without_sweeping_temps(self) -> None:
        journal = self.data_dir / "events.ndjson"
        journal.mkdir()
        pending_dir = self.data_dir / "artifacts" / "s1"
        pending_dir.mkdir(parents=True, exist_ok=True)
        pending = pending_dir / "blob.amproj.tmp-deadbeef"
        pending.write_bytes(b"possibly committed")

        state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
        self.assertFalse(state.persistence_ready())
        self.assertTrue(pending.exists())
        with self.assertRaises(ApiError) as context:
            state.add_events({"type": "blocked"})
        self.assertEqual(context.exception.status, 503)

    def test_journal_stat_error_is_not_treated_as_missing(self) -> None:
        journal = self.data_dir / "events.ndjson"
        journal.write_bytes(b"{}\n")
        pending_dir = self.data_dir / "artifacts" / "s1"
        pending_dir.mkdir(parents=True, exist_ok=True)
        pending = pending_dir / "blob.amproj.tmp-deadbeef"
        pending.write_bytes(b"possibly committed")
        real_stat = Path.stat

        def interrupted_stat(path, *args, **kwargs):
            if path == journal:
                raise PermissionError("simulated journal metadata failure")
            return real_stat(path, *args, **kwargs)

        with patch.object(Path, "stat", new=interrupted_stat):
            state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertFalse(state.persistence_ready())
        self.assertEqual(state.replay_stats, {"replayed": 0, "skipped": 0})
        self.assertTrue(pending.exists())
        with self.assertRaises(ApiError) as context:
            state.get_commands(0, "s1")
        self.assertEqual(context.exception.status, 503)

    def test_journal_read_error_after_open_fails_closed_without_startup_crash(self) -> None:
        journal = self.data_dir / "events.ndjson"
        journal.write_bytes(b"{}\n")
        pending_dir = self.data_dir / "artifacts" / "s1"
        pending_dir.mkdir(parents=True, exist_ok=True)
        pending = pending_dir / "blob.amproj.tmp-deadbeef"
        pending.write_bytes(b"possibly committed")

        class InterruptedReader(io.BytesIO):
            def __iter__(self):
                raise OSError("simulated journal read failure")

        real_open = Path.open

        def interrupted_open(path, mode="r", *args, **kwargs):
            if path == journal and mode == "rb":
                return InterruptedReader()
            return real_open(path, mode, *args, **kwargs)

        with patch.object(Path, "open", new=interrupted_open):
            state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertFalse(state.persistence_ready())
        self.assertTrue(pending.exists())
        self.assertEqual(state.replay_stats, {"replayed": 0, "skipped": 0})
        with self.assertRaises(ApiError) as context:
            state.add_events({"type": "blocked"})
        self.assertEqual(context.exception.status, 503)

    def test_artifact_reconcile_enumeration_error_fails_closed_without_sweep(self) -> None:
        journal = self.data_dir / "events.ndjson"
        journal.write_bytes(b"")
        artifact_dir = self.data_dir / "artifacts"
        pending_dir = artifact_dir / "s1"
        pending_dir.mkdir(parents=True, exist_ok=True)
        pending = pending_dir / "blob.amproj.tmp-deadbeef"
        pending.write_bytes(b"possibly committed")

        real_rglob = Path.rglob

        def interrupted_rglob(path, pattern):
            if path == artifact_dir and pattern == "*.tmp-*":
                raise OSError("simulated artifact directory read failure")
            return real_rglob(path, pattern)

        with patch.object(Path, "rglob", new=interrupted_rglob):
            state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertFalse(state.persistence_ready())
        self.assertTrue(pending.exists())
        with self.assertRaises(ApiError) as context:
            state.add_events({"type": "blocked"})
        self.assertEqual(context.exception.status, 503)

    def test_artifact_directory_stat_error_fails_closed_without_sweep(self) -> None:
        journal = self.data_dir / "events.ndjson"
        journal.write_bytes(b"")
        artifact_dir = self.data_dir / "artifacts"
        pending_dir = artifact_dir / "s1"
        pending_dir.mkdir(parents=True, exist_ok=True)
        pending = pending_dir / "blob.amproj.tmp-deadbeef"
        pending.write_bytes(b"possibly committed")
        real_stat = Path.stat

        def interrupted_stat(path, *args, **kwargs):
            if path == artifact_dir:
                raise PermissionError("simulated artifact directory metadata failure")
            return real_stat(path, *args, **kwargs)

        with patch.object(Path, "stat", new=interrupted_stat):
            state = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)

        self.assertFalse(state.persistence_ready())
        self.assertTrue(pending.exists())
        with self.assertRaises(ApiError) as context:
            state.add_events({"type": "blocked"})
        self.assertEqual(context.exception.status, 503)

    def test_artifact_validation_io_error_preserves_committed_temp(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        real_replace = server_module.os.replace
        server_module.os.replace = lambda *args, **kwargs: (
            (_ for _ in ()).throw(OSError("simulated rename interruption"))
        )
        try:
            artifact = self.state.store_artifact(
                b"data", session_id="s1", filename="project.amproj", kind="amproj",
                metadata={"transaction": "tx-committed-temp"},
            )
        finally:
            server_module.os.replace = real_replace

        final = self.data_dir / artifact["stored_path"]
        temp = next(self.state.artifact_dir.rglob("*.tmp-*"))
        self.assertFalse(final.exists())
        self.assertTrue(temp.exists())

        real_resolve = Path.resolve
        real_stat = Path.stat

        def interrupted_resolve(path, *args, **kwargs):
            if path == final:
                raise OSError("simulated final path resolution failure")
            return real_resolve(path, *args, **kwargs)

        def interrupted_stat(path, *args, **kwargs):
            if path == final:
                raise OSError("simulated final path stat failure")
            return real_stat(path, *args, **kwargs)

        for method, replacement in (
            ("resolve", interrupted_resolve),
            ("stat", interrupted_stat),
        ):
            with self.subTest(method=method), patch.object(Path, method, new=replacement):
                restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=1024)
            self.assertFalse(restarted.persistence_ready())
            self.assertEqual(restarted.replay_stats, {"replayed": 2, "skipped": 1})
            self.assertTrue(temp.exists())

    def test_duplicate_artifact_blob_read_error_fails_closed(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        artifact = self.state.store_artifact(
            b"data", session_id="s1", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-read-error"},
        )
        final = self.data_dir / artifact["stored_path"]
        real_open = Path.open

        def interrupted_open(path, mode="r", *args, **kwargs):
            if path == final and mode == "rb":
                raise OSError("simulated committed blob read failure")
            return real_open(path, mode, *args, **kwargs)

        with patch.object(Path, "open", new=interrupted_open):
            with self.assertRaises(ApiError) as context:
                self.state.store_artifact(
                    b"data", session_id="s1", filename="project.amproj", kind="amproj",
                    metadata={"transaction": "tx-read-error"},
                )
        self.assertEqual(context.exception.status, 503)
        self.assertFalse(self.state.persistence_ready())
        self.assertTrue(final.exists())

    def test_unconfirmed_rollback_blocks_later_writes_until_restart(self) -> None:
        real_fsync = os.fsync

        def always_report_failure(fd):
            real_fsync(fd)
            raise OSError("simulated uncertain durability")

        server_module.os.fsync = always_report_failure
        try:
            with self.assertRaises(ApiError):
                self.state.add_events(
                    {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
                )
        finally:
            server_module.os.fsync = real_fsync

        self.assertTrue(self.state._journal_poisoned)
        with self.assertRaises(ApiError) as blocked:
            self.state.add_events(
                {"session_id": "s1", "events": [{"type": "e", "seq": 2}]}
            )
        self.assertEqual(blocked.exception.status, 503)
        self.assertEqual(len(self.state.events), 0)
        restarted = self._restart()
        accepted = restarted.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        self.assertEqual(accepted[0]["id"], 1)

    def test_uncertain_artifact_commit_preserves_temp_for_reconciliation(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        real_fsync = os.fsync
        calls = 0

        def fail_journal_and_rollback_fsync(fd):
            nonlocal calls
            calls += 1
            real_fsync(fd)
            if calls >= 2:  # journal commit and rollback durability are uncertain
                raise OSError("simulated uncertain durability")

        server_module.os.fsync = fail_journal_and_rollback_fsync
        try:
            with self.assertRaises(ApiError):
                self.state.store_artifact(
                    b"data", session_id="s1", filename="a.amproj", kind="amproj",
                    metadata={"transaction": "tx-1"},
                )
        finally:
            server_module.os.fsync = real_fsync

        self.assertTrue(self.state._journal_poisoned)
        temps = list(self.state.artifact_dir.rglob("*.tmp-*"))
        self.assertEqual(len(temps), 1)
        # In this probe truncate physically succeeded before its fsync reported
        # failure, so restart sees no record and correctly sweeps the orphan.
        restarted = self._restart()
        self.assertEqual(len(restarted.artifact_keys), 0)
        self.assertEqual(list(restarted.artifact_dir.rglob("*.tmp-*")), [])

    def test_append_isolates_complete_or_torn_non_newline_tail(self) -> None:
        valid = {
            "record_type": "event", "id": 1, "session_id": "s1",
            "type": "seed", "level": "info", "received_at": "2026-01-01T00:00:00.000Z",
            "payload": {"type": "seed", "seq": 1}, "stream_id": 1,
        }
        self.state.journal_path.write_bytes(json.dumps(valid).encode("utf-8"))
        complete_tail = self._restart()
        self.assertEqual(complete_tail.replay_stats, {"replayed": 1, "skipped": 0})
        complete_tail.add_events(
            {"session_id": "s1", "events": [{"type": "next", "seq": 2}]}
        )
        replayed = self._restart()
        self.assertEqual(replayed.replay_stats, {"replayed": 2, "skipped": 0})
        self.assertEqual([event["id"] for event in replayed.events], [1, 2])

        self.state.journal_path.write_bytes(b'{"record_type":"event","id":')
        torn_tail = self._restart()
        self.assertEqual(torn_tail.replay_stats, {"replayed": 0, "skipped": 1})
        torn_tail.add_events(
            {"session_id": "s1", "events": [{"type": "recovered", "seq": 3}]}
        )
        recovered = self._restart()
        self.assertEqual(recovered.replay_stats, {"replayed": 1, "skipped": 1})
        self.assertEqual(len(recovered.events), 1)

    def test_multi_event_batch_failure_cannot_commit_a_prefix(self) -> None:
        before = self._snapshot()
        original = self.state._append_journal_line
        calls: list[str] = []

        def fail_atomic_batch(record):
            calls.append(record.get("record_type", ""))
            # The atomic implementation fails its single event_batch append.
            # A per-event implementation instead commits event 1, then fails on
            # event 2; the state assertions below catch that partial prefix.
            if record.get("record_type") == "event_batch" or len(calls) == 2:
                raise JournalWriteError("simulated batch failure")
            return original(record)

        self.state._append_journal_line = fail_atomic_batch  # type: ignore[assignment]
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events({
                "session_id": "s1",
                "events": [
                    {"type": "one", "seq": 1},
                    {"type": "two", "seq": 2},
                ],
            })
        self.assertEqual(ctx.exception.status, 503)
        self.assertEqual(calls, ["event_batch"])
        self._assert_unchanged(before)
        self.assertEqual(len(self._restart().events), 0)

    def test_command_append_failure(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        before = self._snapshot()
        self._break()
        with self.assertRaises(ApiError) as ctx:
            self.state.set_command({"mode": "placeholder"})
        self.assertEqual(ctx.exception.status, 503)
        self._assert_unchanged(before)
        self.assertEqual(self._restart().config["mode"], "full")

    def test_command_with_mode_and_capture_is_all_or_nothing(self) -> None:
        # (6) A batch carrying BOTH mode and capture: the single append fails,
        # so neither mode nor capture nor any grant partially applies.
        self.state.hello({"session_id": "s1", "device_id": "d"})
        before = self._snapshot()
        self._break()
        with self.assertRaises(ApiError) as ctx:
            self.state.set_command({"mode": "observe", "capture_next": True, "session_id": "s1"})
        self.assertEqual(ctx.exception.status, 503)
        self._assert_unchanged(before)
        restarted = self._restart()
        self.assertEqual(restarted.config["mode"], "full")
        self.assertFalse(restarted.config["capture_next"])
        self.assertEqual(len(restarted.capture_grants), 0)

    def test_ack_append_failure(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        before = self._snapshot()
        self._break()
        with self.assertRaises(ApiError) as ctx:
            self.state.acknowledge_commands({"session": "s1", "acknowledged": [1]})
        self.assertEqual(ctx.exception.status, 503)
        self._assert_unchanged(before)
        self.assertEqual(self._restart().command_acks, {})

    def test_artifact_append_failure_leaves_no_file_or_grant_change(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        before = self._snapshot()
        self._break()
        with self.assertRaises(ApiError) as ctx:
            self.state.store_artifact(
                b"data", session_id="s1", filename="a.amproj", kind="amproj",
                metadata={"transaction": "tx-1"},
            )
        self.assertEqual(ctx.exception.status, 503)
        self._assert_unchanged(before)  # grant counters untouched
        # No orphan blob on disk.
        blobs = [p for p in (self.data_dir / "artifacts").rglob("*") if p.is_file()]
        self.assertEqual(blobs, [])
        # Restart: grant still pending (files=0), artifact absent.
        restarted = self._restart()
        pending = [g for g in restarted.capture_grants.values() if not g["bound"]]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["files"], 0)

    # (5) Artifact retry after each stage: exactly one file, one artifact_id.

    def test_artifact_retry_after_failure_yields_exactly_one_file(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        self._break()
        with self.assertRaises(ApiError):
            self.state.store_artifact(
                b"data", session_id="s1", filename="a.amproj", kind="amproj",
                metadata={"transaction": "tx-1"},
            )
        # Repair and retry the SAME upload.
        self.state._append_journal_line = server_module.BackendState._append_journal_line.__get__(
            self.state, server_module.BackendState
        )
        first = self.state.store_artifact(
            b"data", session_id="s1", filename="a.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        # A second identical retry is idempotent (same id, no second file).
        second = self.state.store_artifact(
            b"data", session_id="s1", filename="a.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        self.assertEqual(first["artifact_id"], second["artifact_id"])
        blobs = [p for p in (self.data_dir / "artifacts").rglob("*") if p.is_file()]
        self.assertEqual(len(blobs), 1)  # exactly one file
        restarted = self._restart()
        # Restart sees exactly one committed artifact for the dedup key.
        self.assertEqual(len(restarted.artifact_keys), 1)

    # (3) Repeated replay on the same instance is identical.

    def test_double_replay_is_identical(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 1}]})
        self.state.set_command({"mode": "placeholder"})
        snap = self._snapshot()
        self.state._replay_journal_locked()
        self.state._replay_journal_locked()
        self._assert_unchanged(snap)

    # (4) Each record type: valid JSON but broken schema -> safely skipped.

    def test_schema_invalid_records_are_skipped(self) -> None:
        bad_lines = [
            '{"record_type":"hello","session":{"session_id":"x"}}',   # missing last_seen
            '{"record_type":"hello","session":{"last_seen":"t"}}',    # missing session_id
            '{"record_type":"event","session_id":"s"}',               # missing id/payload
            '{"record_type":"event","id":"notint","session_id":"s","received_at":"t","payload":{}}',
            '{"record_type":"event","id":1,"session_id":"s","received_at":"t","payload":{}}',  # missing type/level
            '{"record_type":"event","id":9223372036854775808,"session_id":"s","received_at":"t","type":"e","level":"info","payload":{}}',  # id outside query domain
            '{"record_type":"event","id":1,"session_id":"s","received_at":"t","type":"e","level":"info","payload":{},"stream_id":9223372036854775808}',  # cursor outside query domain
            '{"record_type":"command_batch","commands":[]}',          # missing config
            '{"record_type":"command_batch","commands":[{}],"config":{"revision":1,"mode":"full","capture_next":false}}',  # command missing revision/id/type
            '{"record_type":"command_batch","commands":[],"grants":[],"config":{"revision":1,"mode":"bogus","capture_next":false}}',  # invalid config mode
            '{"record_type":"command","revision":1,"type":"set_mode"}',  # legacy command missing id/mode/capture_next
            '{"record_type":"command","id":5,"revision":6,"type":"set_mode","mode":"full","capture_next":false}',  # id != revision
            '{"record_type":"command","id":2,"revision":2,"type":"set_mode","mode":"bogus","capture_next":false}',  # invalid mode enum
            '{"record_type":"command","id":-1,"revision":-1,"type":"set_mode","mode":"full","capture_next":false}',  # negative revision
            '{"record_type":"command_ack","acknowledged":[1]}',       # missing session_id
            '{"record_type":"command_ack","session_id":"s","acknowledged":["x"]}',  # non-int ack id
            '{"record_type":"command_ack","session_id":"s","acknowledged":[9223372036854775808]}',  # cursor outside API domain
            '{"record_type":"artifact","artifact":{"session_id":"s"}}',  # missing artifact_id/sha256
            '{"record_type":"artifact","artifact":{"artifact_id":"a","session_id":"s","transaction":"tx","kind":"amproj","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},"grant":{"grant_id":"g","bound":true,"consumed":true,"revoked":false,"files":1,"bytes":1,"max_files":2,"max_bytes":2,"allowed_kinds":["amproj"],"session_id":"s","transaction":"tx","expires_at":9999999999.0},"expiry_snapshots":null}',  # nested container has wrong type
            '{"record_type":"session_touch","session_id":"s"}',       # missing last_seen
            '{"record_type":"capture_grant","grant":{"grant_id":"g1"}}',  # missing revoked/bound/... fields
            # grant present-but-invalid: negative files
            '{"record_type":"capture_grant","grant":{"grant_id":"g2","bound":false,"consumed":false,"revoked":false,"files":-1,"bytes":0,"max_files":2,"max_bytes":10,"allowed_kinds":["amproj"],"session_id":"s1","expires_at":0}}',
            # grant present-but-invalid: files exceed max_files
            '{"record_type":"capture_grant","grant":{"grant_id":"g3","bound":false,"consumed":false,"revoked":false,"files":5,"bytes":0,"max_files":2,"max_bytes":10,"allowed_kinds":["amproj"],"session_id":"s1","expires_at":0}}',
            # grant present-but-invalid: empty session_id
            '{"record_type":"capture_grant","grant":{"grant_id":"g4","bound":false,"consumed":false,"revoked":false,"files":0,"bytes":0,"max_files":2,"max_bytes":10,"allowed_kinds":["amproj"],"session_id":"","expires_at":0}}',
            '{"record_type":"capture_grant","grant":{"grant_id":"g5","bound":false,"consumed":false,"revoked":false,"files":0,"bytes":0,"max_files":2,"max_bytes":10,"allowed_kinds":["amproj"],"session_id":"s1","expires_at":9999999999.0}}',  # missing transaction
            '{"record_type":"totally_unknown","x":1}',                # unknown type
        ]
        journal = self.data_dir / "events.ndjson"
        journal.write_text("\n".join(bad_lines) + "\n", encoding="utf-8")
        restarted = self._restart()
        # Every line skipped, nothing applied.
        self.assertEqual(restarted.replay_stats["replayed"], 0)
        self.assertEqual(restarted.replay_stats["skipped"], len(bad_lines))
        self.assertEqual(len(restarted.sessions), 0)
        self.assertEqual(len(restarted.events), 0)
        self.assertEqual(len(restarted.commands), 0)
        self.assertEqual(len(restarted.capture_grants), 0)
        # Subsequent reads that would have hit the missing fields do NOT raise.
        restarted.list_sessions()
        restarted.get_commands(0, "s1")  # would KeyError on a partial command
        # Authorization over a partial grant would KeyError revoked/bound — but
        # since the partial grant was skipped, there is simply nothing to match.
        with self.assertRaises(ApiError) as ctx:
            restarted.store_artifact(
                b"x", session_id="s", filename="a.amproj", kind="amproj",
                metadata={"transaction": "tx"},
            )
        self.assertIn(ctx.exception.status, (400, 403))

    def test_valid_records_of_each_type_replay(self) -> None:
        # A positive counterpart: one well-formed record of each type applies.
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 1}]})
        self.state.set_command({"mode": "placeholder"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        self.state.store_artifact(
            b"data", session_id="s1", filename="a.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        self.state.acknowledge_commands({"session": "s1", "acknowledged": [1]})
        restarted = self._restart()
        self.assertEqual(restarted.replay_stats["skipped"], 0)
        self.assertIn("s1", restarted.sessions)
        self.assertEqual(len(restarted.events), 1)
        self.assertEqual(restarted.config["mode"], "placeholder")
        self.assertEqual(len(restarted.artifact_keys), 1)
        self.assertEqual(restarted.command_acks.get("s1"), {1})

    def test_complete_grant_snapshot_passes_validation(self) -> None:
        # (2) Positive counterpart: a grant carrying EVERY required field with
        # sane ranges is accepted and applied.
        grant = {
            "grant_id": "g-ok", "bound": True, "consumed": True, "revoked": False,
            "files": 1, "bytes": 5, "max_files": 2, "max_bytes": 100,
            "allowed_kinds": ["amproj", "xml"], "session_id": "s1",
            "transaction": "tx-1", "expires_at": 9999999999.0,
        }
        self.assertTrue(self.state._grant_is_valid(grant))
        line = json.dumps({"record_type": "capture_grant", "grant": grant})
        (self.data_dir / "events.ndjson").write_text(line + "\n", encoding="utf-8")
        restarted = self._restart()
        self.assertEqual(restarted.replay_stats["replayed"], 1)
        self.assertIn("g-ok", restarted.capture_grants)

    def test_impossible_grant_state_hybrids_are_rejected(self) -> None:
        base = {
            "grant_id": "g-invalid", "bound": False, "consumed": False,
            "revoked": False, "files": 0, "bytes": 0, "max_files": 2,
            "max_bytes": 100, "allowed_kinds": ["amproj"], "session_id": "s1",
            "transaction": None, "expires_at": 9999999999.0,
        }
        variants = [
            {**base, "consumed": True},
            {**base, "bound": True, "transaction": "tx-1"},
            {**base, "files": 1},
            {**base, "bytes": 1},
            {**base, "transaction": "tx-1"},
            {**base, "max_files": 3},
            {**base, "allowed_kinds": ["exe"]},
            {**base, "bound": True, "consumed": True, "files": 0, "bytes": 0,
             "transaction": "tx-1"},
        ]
        for variant in variants:
            self.assertFalse(self.state._grant_is_valid(variant), variant)

    def test_same_batch_grant_snapshot_cannot_unrevoke_itself(self) -> None:
        grant = {
            "grant_id": "g-batch", "bound": False, "consumed": False,
            "revoked": False, "files": 0, "bytes": 0, "max_files": 2,
            "max_bytes": 100, "allowed_kinds": ["amproj"], "session_id": "s1",
            "transaction": None, "expires_at": 9999999999.0,
        }
        revoked = {**grant, "revoked": True}
        record = {
            "record_type": "command_batch",
            "commands": [{
                "record_type": "command", "id": 1, "revision": 1,
                "type": "capture_next", "mode": "full", "capture_next": False,
                "target_session": "",
            }],
            "grants": [revoked, grant],
            "config": {"revision": 1, "mode": "full", "capture_next": False},
            "stream_id": 1,
        }
        self.data_dir.joinpath("events.ndjson").write_text(
            json.dumps(record) + "\n", encoding="utf-8"
        )
        restarted = self._restart()
        self.assertEqual(restarted.replay_stats, {"replayed": 0, "skipped": 1})
        self.assertEqual(restarted.capture_grants, {})


class ArtifactAtomicWriteTests(ContractServerTestCase):
    """(5) Artifact blobs are written temp+fsync then atomically renamed; a
    crash between journal-commit and rename is reconciled from the temp, and
    orphan temps from never-committed writes are swept."""

    def _arm(self) -> None:
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        self.request("/api/v1/commands", "POST", {"capture_next": True, "session_id": "s1"})

    def test_successful_upload_leaves_final_file_no_temp(self) -> None:
        self._arm()
        status, _ = self.request("/api/v1/artifacts", "POST", {
            "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
            "metadata": {"transaction": "tx-1"},
            "content_base64": base64.b64encode(b"data").decode(),
        })
        self.assertEqual(status, 201)
        art_dir = self.data_dir / "artifacts"
        finals = [p for p in art_dir.rglob("*") if p.is_file() and ".tmp-" not in p.name]
        temps = [p for p in art_dir.rglob("*.tmp-*")]
        self.assertEqual(len(finals), 1)
        self.assertEqual(temps, [])  # no leftover temp after atomic rename

    def test_incomplete_bundled_artifact_cannot_poison_idempotency(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        pending = dict(list(self.state.capture_grants.values())[-1])
        consumed = {
            **pending, "bound": True, "consumed": True, "files": 1,
            "bytes": 4, "transaction": "tx-1",
        }
        malformed = {
            "record_type": "artifact",
            "artifact": {
                "artifact_id": "bad", "session_id": "s1", "transaction": "tx-1",
                "kind": "amproj", "sha256": hashlib.sha256(b"data").hexdigest(),
            },
            "grant": consumed, "expiry_snapshots": [],
            "received_at": "2026-01-01T00:00:00.000Z",
            "stream_id": self.state.stream_id + 1,
        }
        with self.state.journal_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(malformed) + "\n")
        restarted = self._restart()
        self.assertEqual(restarted.replay_stats, {"replayed": 2, "skipped": 1})
        self.assertEqual(len(restarted.artifact_keys), 0)
        stored = restarted.store_artifact(
            b"data", session_id="s1", filename="scene.amproj", kind="amproj",
            metadata={"transaction": "tx-1"},
        )
        self.assertTrue((self.data_dir / stored["stored_path"]).is_file())
        self.assertFalse(stored.get("duplicate", False))

    def test_legacy_artifact_outside_storage_root_is_skipped(self) -> None:
        legacy = {
            "record_type": "artifact", "artifact_id": "legacy-1",
            "session_id": "s1", "filename": "Private Project.amproj",
            "kind": "amproj", "size": 4,
            "sha256": hashlib.sha256(b"data").hexdigest(),
            "stored_path": str((self.data_dir.parent / "outside.amproj").resolve()),
            "received_at": "2026-01-01T00:00:00.000Z", "metadata": {},
            "stream_id": 1,
        }
        self.state.journal_path.write_text(json.dumps(legacy) + "\n", encoding="utf-8")
        restarted = self._restart()
        self.assertEqual(restarted.replay_stats, {"replayed": 0, "skipped": 1})
        self.assertEqual(len(restarted.artifact_keys), 0)
        self.assertEqual(len(restarted.stream_updates), 0)

    def test_artifact_reset_snapshot_must_match_reset_command(self) -> None:
        self._arm()
        self.request("/api/v1/artifacts", "POST", {
            "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
            "metadata": {"transaction": "tx-1"},
            "content_base64": base64.b64encode(b"data").decode(),
        })
        records = [json.loads(line) for line in self.state.journal_path.read_text(
            encoding="utf-8"
        ).splitlines()]
        artifact = next(record for record in records if record["record_type"] == "artifact")
        artifact["reset_config"]["revision"] += 1
        self.assertFalse(self.state._record_is_valid(artifact))

    def test_transaction_is_canonical_and_length_capped_everywhere(self) -> None:
        self._arm()
        long_transaction = "t" * 10_000
        _, artifact = self.request("/api/v1/artifacts", "POST", {
            "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
            "metadata": {"transaction": long_transaction},
            "content_base64": base64.b64encode(b"data").decode(),
        })
        self.assertEqual(len(artifact["transaction"]), 256)
        self.assertEqual(artifact["metadata"]["transaction"], artifact["transaction"])
        grant = self.state.capture_grants[artifact["grant_id"]]
        self.assertEqual(grant["transaction"], artifact["transaction"])
        self.assertNotIn(long_transaction, self.state.journal_path.read_text(encoding="utf-8"))

    def test_identical_retry_repairs_missing_committed_blob(self) -> None:
        self._arm()
        payload = {
            "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
            "metadata": {"transaction": "tx-1"},
            "content_base64": base64.b64encode(b"payload").decode(),
        }
        _, first = self.request("/api/v1/artifacts", "POST", payload)
        final = self.data_dir / first["stored_path"]
        final.unlink()
        self.assertFalse(final.exists())
        _, retry = self.request("/api/v1/artifacts", "POST", payload)
        self.assertTrue(retry["duplicate"])
        self.assertEqual(retry["artifact_id"], first["artifact_id"])
        self.assertEqual(final.read_bytes(), b"payload")

    def test_identical_retry_repairs_corrupt_committed_blob(self) -> None:
        self._arm()
        payload = {
            "session_id": "s1", "kind": "amproj", "filename": "project.amproj",
            "metadata": {"transaction": "tx-corrupt"},
            "content_base64": base64.b64encode(b"expected-payload").decode(),
        }
        _, first = self.request("/api/v1/artifacts", "POST", payload)
        final = self.data_dir / first["stored_path"]
        final.write_bytes(b"CORRUPT")

        _, retry = self.request("/api/v1/artifacts", "POST", payload)
        self.assertTrue(retry["duplicate"])
        self.assertEqual(retry["artifact_id"], first["artifact_id"])
        self.assertEqual(final.read_bytes(), b"expected-payload")

    def test_crash_after_commit_before_rename_is_reconciled(self) -> None:
        # Simulate the crash window: patch os.replace so the rename never runs,
        # leaving a committed record + a .tmp- blob. A restart must promote it.
        self._arm()
        import os as _os
        real_replace = _os.replace
        server_module.os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("simulated crash"))
        try:
            status, _ = self.request("/api/v1/artifacts", "POST", {
                "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
                "metadata": {"transaction": "tx-1"},
                "content_base64": base64.b64encode(b"payload").decode(),
            })
            self.assertEqual(status, 201)  # record is durable, request succeeds
        finally:
            server_module.os.replace = real_replace
        art_dir = self.data_dir / "artifacts"
        # Before restart: final missing, a temp exists.
        finals = [p for p in art_dir.rglob("*") if p.is_file() and ".tmp-" not in p.name]
        temps = [p for p in art_dir.rglob("*.tmp-*")]
        self.assertEqual(finals, [])
        self.assertEqual(len(temps), 1)
        # Restart reconciles: temp promoted to the committed final path, no temp.
        restarted = self._restart()
        finals2 = [p for p in art_dir.rglob("*") if p.is_file() and ".tmp-" not in p.name]
        temps2 = [p for p in art_dir.rglob("*.tmp-*")]
        self.assertEqual(len(finals2), 1)
        self.assertEqual(temps2, [])
        self.assertEqual(finals2[0].read_bytes(), b"payload")
        self.assertEqual(len(restarted.artifact_keys), 1)

    def test_corrupt_committed_temp_is_not_promoted_and_retry_repairs_it(self) -> None:
        self._arm()
        real_replace = server_module.os.replace
        server_module.os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("locked"))
        try:
            _, artifact = self.request("/api/v1/artifacts", "POST", {
                "session_id": "s1", "kind": "amproj", "filename": "project.amproj",
                "metadata": {"transaction": "tx-corrupt-temp"},
                "content_base64": base64.b64encode(b"expected").decode(),
            })
        finally:
            server_module.os.replace = real_replace

        temp = next(self.state.artifact_dir.rglob("*.tmp-*"))
        temp.write_bytes(b"CORRUPT")
        restarted = self._restart()
        final = self.data_dir / artifact["stored_path"]
        self.assertFalse(final.exists())
        self.assertEqual(list(self.state.artifact_dir.rglob("*.tmp-*")), [])

        repaired = restarted.store_artifact(
            b"expected", session_id="s1", filename="project.amproj", kind="amproj",
            metadata={"transaction": "tx-corrupt-temp"},
        )
        self.assertTrue(repaired["duplicate"])
        self.assertEqual(final.read_bytes(), b"expected")

    def test_committed_temp_survives_repeated_promotion_failure(self) -> None:
        self._arm()
        import os as _os
        real_replace = _os.replace
        server_module.os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("locked"))
        try:
            status, _ = self.request("/api/v1/artifacts", "POST", {
                "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
                "metadata": {"transaction": "tx-1"},
                "content_base64": base64.b64encode(b"payload").decode(),
            })
            self.assertEqual(status, 201)
            restarted = self._restart()
        finally:
            server_module.os.replace = real_replace

        art_dir = self.data_dir / "artifacts"
        self.assertEqual(len(restarted.artifact_keys), 1)
        self.assertEqual(len(list(art_dir.rglob("*.tmp-*"))), 1)
        self.assertEqual(
            [p for p in art_dir.rglob("*") if p.is_file() and ".tmp-" not in p.name],
            [],
        )

        recovered = self._restart()
        finals = [p for p in art_dir.rglob("*") if p.is_file() and ".tmp-" not in p.name]
        self.assertEqual(len(finals), 1)
        self.assertEqual(finals[0].read_bytes(), b"payload")
        self.assertEqual(list(art_dir.rglob("*.tmp-*")), [])
        self.assertEqual(len(recovered.artifact_keys), 1)

    def test_idempotent_retry_promotes_committed_temp_without_restart(self) -> None:
        self._arm()
        payload = {
            "session_id": "s1", "kind": "amproj", "filename": "scene.amproj",
            "metadata": {"transaction": "tx-1"},
            "content_base64": base64.b64encode(b"payload").decode(),
        }
        import os as _os
        real_replace = _os.replace
        server_module.os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("locked"))
        try:
            status, first = self.request("/api/v1/artifacts", "POST", payload)
            self.assertEqual(status, 201)
        finally:
            server_module.os.replace = real_replace

        status, second = self.request("/api/v1/artifacts", "POST", payload)
        self.assertEqual(status, 201)
        self.assertTrue(second["duplicate"])
        self.assertEqual(second["artifact_id"], first["artifact_id"])
        art_dir = self.data_dir / "artifacts"
        finals = [p for p in art_dir.rglob("*") if p.is_file() and ".tmp-" not in p.name]
        self.assertEqual(len(finals), 1)
        self.assertEqual(finals[0].read_bytes(), b"payload")
        self.assertEqual(list(art_dir.rglob("*.tmp-*")), [])

    def test_orphan_temp_without_record_is_swept(self) -> None:
        # A .tmp- blob with no committed record (a write that never committed)
        # is removed on restart, never left as a permanent orphan.
        art_dir = self.data_dir / "artifacts" / "s1"
        art_dir.mkdir(parents=True, exist_ok=True)
        orphan = art_dir / "999_deadbeef_ghost.amproj.tmp-deadbeef"
        orphan.write_bytes(b"orphan")
        restarted = self._restart()
        self.assertFalse(orphan.exists())
        self.assertEqual(len(restarted.artifact_keys), 0)

    def _restart(self) -> "BackendState":
        return BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)


class DedupOverflowTests(unittest.TestCase):
    """(7) Dedup is permanent: retrying the oldest seq after cache overflow
    still returns the original id via a journal-backed lookup."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        # Tiny cache so it overflows immediately; the journal is the source of truth.
        self.state.max_dedup_keys = 3

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_oldest_seq_still_deduped_after_cache_overflow(self) -> None:
        first = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        first_id = first[0]["id"]
        # Overflow the cache well past its cap so (s1, 1) is evicted.
        for seq in range(2, 12):
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": seq}]})
        self.assertNotIn(("s1", 1), self.state.event_keys)  # evicted from hot cache
        self.assertLessEqual(len(self.state.event_keys), 3)
        # Retrying the oldest seq is recognized via the journal-backed lookup.
        retry = self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        self.assertEqual(retry[0]["id"], first_id)
        self.assertTrue(retry[0].get("duplicate"))
        self.assertEqual(self.state.event_id, 11)  # no new event created

    def test_evicted_seq_conflict_still_detected(self) -> None:
        self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1, "fields": {"v": 1}}]}
        )
        for seq in range(2, 12):
            self.state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": seq}]})
        # Different payload under the evicted key -> still a conflict via journal.
        with self.assertRaises(ApiError) as ctx:
            self.state.add_events(
                {"session_id": "s1", "events": [{"type": "e", "seq": 1, "fields": {"v": 999}}]}
            )
        self.assertEqual(ctx.exception.status, 409)

    def test_dedup_journal_stat_error_is_503_not_cache_miss(self) -> None:
        self.state.add_events(
            {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
        )
        for seq in range(2, 12):
            self.state.add_events(
                {"session_id": "s1", "events": [{"type": "e", "seq": seq}]}
            )
        self.assertNotIn(("s1", 1), self.state.event_keys)
        journal = self.state.journal_path
        real_stat = Path.stat

        def interrupted_stat(path, *args, **kwargs):
            if path == journal:
                raise PermissionError("simulated dedup journal metadata failure")
            return real_stat(path, *args, **kwargs)

        with patch.object(Path, "stat", new=interrupted_stat):
            with self.assertRaises(ApiError) as context:
                self.state.add_events(
                    {"session_id": "s1", "events": [{"type": "e", "seq": 1}]}
                )

        self.assertEqual(context.exception.status, 503)
        self.assertFalse(self.state.persistence_ready())
        self.assertEqual(self.state.event_id, 11)

    @staticmethod
    def _journal_event(identifier: int, stream_id: int, seq: int, value: int) -> dict:
        return {
            "record_type": "event", "id": identifier, "stream_id": stream_id,
            "session_id": "s1", "type": "e", "level": "info",
            "received_at": "2026-01-01T00:00:00.000Z",
            "payload": {"type": "e", "seq": seq, "fields": {"v": value}},
        }

    def test_stale_same_key_cannot_create_false_conflict_after_cache_eviction(self) -> None:
        valid = self._journal_event(2, 1, 7, 1)
        stale = self._journal_event(1, 2, 7, 999)
        self.state.journal_path.write_text(
            json.dumps(valid) + "\n" + json.dumps(stale) + "\n", encoding="utf-8"
        )
        state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        self.assertEqual(state.replay_stats, {"replayed": 1, "skipped": 1})
        state.max_dedup_keys = 1
        state.add_events({"session_id": "s1", "events": [{"type": "e", "seq": 8}]})
        self.assertNotIn(("s1", 7), state.event_keys)

        retry = state.add_events({
            "session_id": "s1",
            "events": [{"type": "e", "seq": 7, "fields": {"v": 1}}],
        })
        self.assertTrue(retry[0]["duplicate"])
        self.assertEqual(retry[0]["id"], 2)

    def test_stale_unique_key_is_not_a_permanent_duplicate(self) -> None:
        valid = self._journal_event(2, 1, 7, 1)
        stale = self._journal_event(1, 2, 99, 999)
        self.state.journal_path.write_text(
            json.dumps(valid) + "\n" + json.dumps(stale) + "\n", encoding="utf-8"
        )
        state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        accepted = state.add_events({
            "session_id": "s1",
            "events": [{"type": "e", "seq": 99, "fields": {"v": 999}}],
        })
        self.assertFalse(accepted[0].get("duplicate", False))
        self.assertEqual(accepted[0]["id"], 3)

    def test_stream_regressed_event_after_non_event_record_is_not_deduped(self) -> None:
        hello = {
            "record_type": "hello", "stream_id": 10,
            "session": {
                "session_id": "s1",
                "last_seen": "2026-01-01T00:00:00.000Z",
                "connected_at": "2026-01-01T00:00:00.000Z",
            },
        }
        regressed = self._journal_event(1, 9, 55, 1)
        self.state.journal_path.write_text(
            json.dumps(hello) + "\n" + json.dumps(regressed) + "\n", encoding="utf-8"
        )
        state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        self.assertEqual(state.replay_stats, {"replayed": 1, "skipped": 1})
        accepted = state.add_events({
            "session_id": "s1",
            "events": [{"type": "e", "seq": 55, "fields": {"v": 1}}],
        })
        self.assertFalse(accepted[0].get("duplicate", False))
        self.assertEqual(accepted[0]["id"], 1)

    def test_grant_record_does_not_desynchronize_dedup_shadow_replay(self) -> None:
        self.state.hello({"session_id": "s1", "device_id": "d"})
        self.state.set_command({"capture_next": True, "session_id": "s1"})
        regressed = self._journal_event(1, self.state.stream_id, 55, 1)
        with self.state.journal_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(regressed) + "\n")

        state = BackendState(Path(self.temp_dir.name), TOKEN, max_artifact_bytes=1024)
        self.assertEqual(state.replay_stats, {"replayed": 2, "skipped": 1})
        self.assertEqual(list(state.events), [])

        accepted = state.add_events({
            "session_id": "s1",
            "events": [{"type": "e", "seq": 55, "fields": {"v": 1}}],
        })
        self.assertFalse(accepted[0].get("duplicate", False))
        self.assertEqual(accepted[0]["id"], 1)


class FutureCursorTests(ContractServerTestCase):
    """(8) An SSE cursor greater than the current stream id resets rather than
    blocking forever on an id that will never be produced."""

    def test_future_cursor_emits_reset(self) -> None:
        self.request("/api/v1/events", "POST", {"session_id": "s1", "type": "seed"})
        future = self.state.stream_id + 1000
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            connection.request(
                "GET", f"/api/v1/stream?after={future}",
                headers={"Authorization": f"Bearer {TOKEN}"},
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.readline(), b": connected\n")
            self.assertEqual(response.readline(), b"\n")
            self.assertEqual(response.readline(), b"event: reset\n")
            data_line = response.readline()
            reset = json.loads(data_line[len(b"data: "):])
            self.assertEqual(reset["reason"], "cursor_too_old")
        finally:
            connection.close()


class HelloFieldSanitizationTests(ContractServerTestCase):
    """(4) Every descriptive hello field is sanitized before it enters the
    session, the journal, or the SSE stream."""

    def test_bearer_and_paths_in_hello_fields_are_scrubbed(self) -> None:
        self.request("/api/v1/hello", "POST", {
            "session_id": "s1",
            "app_version": "Authorization: Bearer eyJ.SECRET.SIG",
            "build": "/Users/alice/My Secret Project.amproj",
            "os_version": "26.1",
            "device_model": r"C:\Users\bob\Confidential.amproj",
            "device": {"id": "RAW-VENDOR-UUID-1234"},
            "plugin": {"version": "token=PLUGINSECRET", "variant": "debug"},
        })
        _, sessions = self.request("/api/v1/sessions")
        session = sessions["sessions"][0]
        blob = json.dumps(session)
        for secret in ("eyJ.SECRET.SIG", "SECRET", "My Secret Project",
                       "Confidential", "/Users/alice", "RAW-VENDOR-UUID-1234",
                       "PLUGINSECRET"):
            self.assertNotIn(secret, blob, secret)
        # device id was hashed, not stored raw.
        self.assertTrue(session["device_id"].startswith("ifv:"))
        # And nothing leaked to the on-disk journal either.
        journal = self.state.journal_path.read_text(encoding="utf-8")
        for secret in ("eyJ.SECRET.SIG", "My Secret Project", "RAW-VENDOR-UUID-1234", "PLUGINSECRET"):
            self.assertNotIn(secret, journal, secret)


class SeqValidationTests(ContractServerTestCase):
    """(5) An out-of-range seq is a clean 400, never a 500."""

    def test_overlong_numeric_seq_is_400(self) -> None:
        status = self.expect_error(
            "/api/v1/events", "POST",
            {"session_id": "s1", "events": [{"type": "e", "seq": "9" * 5000}]},
        )
        self.assertEqual(status, 400)

    def test_out_of_range_and_negative_seq_are_400(self) -> None:
        self.assertEqual(
            self.expect_error("/api/v1/events", "POST",
                              {"session_id": "s1", "events": [{"type": "e", "seq": 2**63}]}),
            400,
        )
        self.assertEqual(
            self.expect_error("/api/v1/events", "POST",
                              {"session_id": "s1", "events": [{"type": "e", "seq": -5}]}),
            400,
        )

    def test_a_bad_seq_rejects_the_whole_batch_before_any_write(self) -> None:
        # A good event followed by a bad-seq event: nothing is stored (400).
        status = self.expect_error(
            "/api/v1/events", "POST",
            {"session_id": "s1", "events": [
                {"type": "ok", "seq": 1},
                {"type": "bad", "seq": "9" * 5000},
            ]},
        )
        self.assertEqual(status, 400)
        _, events = self.request("/api/v1/events?session=s1")
        self.assertEqual(events["events"], [])

    def test_valid_short_seq_string_still_works(self) -> None:
        status, result = self.request(
            "/api/v1/events", "POST", {"session_id": "s1", "events": [{"type": "e", "seq": "42"}]}
        )
        self.assertEqual(status, 202)
        # A retry of the same string seq is deduped.
        _, dup = self.request(
            "/api/v1/events", "POST", {"session_id": "s1", "events": [{"type": "e", "seq": "42"}]}
        )
        self.assertTrue(dup["events"][0].get("duplicate"))


class TargetedCommandDeliveryTests(ContractServerTestCase):
    """(7) A capture command bound to a session is delivered only to it, and an
    unmatched poller still advances its cursor."""

    def test_capture_command_only_reaches_target_session(self) -> None:
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d1"})
        self.request("/api/v1/hello", "POST", {"session_id": "s2", "device_id": "d2"})
        self.request("/api/v1/commands", "POST", {"capture_next": True, "session_id": "s1"})
        # s1 receives the capture_next command.
        _, s1_view = self.request("/api/v1/commands?session=s1&after=0")
        self.assertTrue(any(c["type"] == "capture_next" for c in s1_view["commands"]))
        # s2 does NOT receive it, but its cursor still advances past it so it
        # will not re-poll the same command forever.
        _, s2_view = self.request("/api/v1/commands?session=s2&after=0")
        self.assertFalse(any(c["type"] == "capture_next" for c in s2_view["commands"]))
        self.assertEqual(s2_view["next_cursor"], s1_view["next_cursor"])
        # Polling again from the advanced cursor yields nothing new for s2.
        _, s2_again = self.request(f"/api/v1/commands?session=s2&after={s2_view['next_cursor']}")
        self.assertEqual(s2_again["commands"], [])

    def test_broadcast_mode_command_reaches_all_sessions(self) -> None:
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d1"})
        self.request("/api/v1/hello", "POST", {"session_id": "s2", "device_id": "d2"})
        self.request("/api/v1/commands", "POST", {"mode": "observe"})  # no target
        for sid in ("s1", "s2"):
            _, view = self.request(f"/api/v1/commands?session={sid}&after=0")
            self.assertTrue(any(c["type"] == "set_mode" for c in view["commands"]), sid)


class CommandCursorMonotonicTests(ContractServerTestCase):
    """(3) The poll cursor advances monotonically and drains; filter and cursor
    key off the same field, so it can never stall."""

    def test_cursor_advances_and_drains_across_repeated_polls(self) -> None:
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        self.request("/api/v1/commands", "POST", {"mode": "placeholder"})
        self.request("/api/v1/commands", "POST", {"mode": "observe"})
        cursor, seen = 0, 0
        # Poll until drained; cursor must be non-decreasing and eventually empty.
        for _ in range(5):
            _, view = self.request(f"/api/v1/commands?session=s1&after={cursor}")
            self.assertGreaterEqual(view["next_cursor"], cursor)  # monotonic
            seen += len(view["commands"])
            cursor = view["next_cursor"]
        self.assertEqual(seen, 2)  # both commands delivered exactly once total
        _, drained = self.request(f"/api/v1/commands?session=s1&after={cursor}")
        self.assertEqual(drained["commands"], [])
        self.assertEqual(drained["next_cursor"], cursor)  # stable when drained

    def test_every_command_has_id_equal_to_revision(self) -> None:
        self.request("/api/v1/hello", "POST", {"session_id": "s1", "device_id": "d"})
        self.request("/api/v1/commands", "POST", {"mode": "placeholder"})
        self.request("/api/v1/commands", "POST", {"capture_next": True, "session_id": "s1"})
        _, view = self.request("/api/v1/commands?session=s1&after=0")
        for command in view["commands"]:
            self.assertEqual(command["id"], command["revision"], command)

    def test_replayed_command_with_id_revision_mismatch_is_skipped(self) -> None:
        # A corrupt legacy command (id != revision) is rejected on replay, so it
        # never enters the ring and can never stall the cursor at a stale id.
        with self.state.journal_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({
                "record_type": "command", "id": 1, "revision": 100,
                "type": "set_mode", "mode": "full", "capture_next": False,
            }) + "\n")
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)
        self.assertEqual(len(restarted.commands), 0)
        self.assertGreaterEqual(restarted.replay_stats["skipped"], 1)

    def test_replayed_batch_revision_mismatch_cannot_poison_cursor(self) -> None:
        bad_batch = {
            "record_type": "command_batch",
            "commands": [{
                "record_type": "command", "id": 100, "revision": 100,
                "type": "set_mode", "mode": "full", "capture_next": False,
                "target_session": "",
            }],
            "grants": [],
            "config": {"revision": 1, "mode": "full", "capture_next": False},
            "stream_id": 1,
        }
        self.state.journal_path.write_text(json.dumps(bad_batch) + "\n", encoding="utf-8")
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)
        self.assertEqual(restarted.replay_stats, {"replayed": 0, "skipped": 1})
        restarted.set_command({"mode": "observe"})
        view = restarted.get_commands(0)
        self.assertEqual(view["next_cursor"], 1)
        self.assertEqual([command["revision"] for command in view["commands"]], [1])

    def test_revision_outside_query_domain_is_skipped(self) -> None:
        too_large = {
            "record_type": "command", "id": 2**63, "revision": 2**63,
            "type": "set_mode", "mode": "full", "capture_next": False,
        }
        self.state.journal_path.write_text(json.dumps(too_large) + "\n", encoding="utf-8")
        restarted = BackendState(self.data_dir, TOKEN, max_artifact_bytes=self.max_artifact_bytes)
        self.assertEqual(restarted.replay_stats, {"replayed": 0, "skipped": 1})
        self.assertEqual(len(restarted.commands), 0)

    def test_future_command_cursor_resets_to_current_revision(self) -> None:
        _, future = self.request("/api/v1/commands?session=s1&after=1000")
        self.assertEqual(future["commands"], [])
        self.assertEqual(future["next_cursor"], 0)
        self.request("/api/v1/commands", "POST", {"mode": "placeholder"})
        _, recovered = self.request(
            f"/api/v1/commands?session=s1&after={future['next_cursor']}"
        )
        self.assertEqual(recovered["next_cursor"], 1)
        self.assertEqual([command["revision"] for command in recovered["commands"]], [1])


class DashboardResetResyncTests(ContractServerTestCase):
    """(8) The dashboard HTML listens for the reset frame and re-syncs.

    Windows cannot run the browser, so this asserts the static asset contains
    the reset-handling logic (topic === "reset" -> adopt current_stream_id and
    refresh) that a browser would execute. The server-side reset frame itself
    is covered by SSEContinuityTests / FutureCursorTests."""

    def test_dashboard_html_handles_reset_frame(self) -> None:
        with urlopen(self.base + "/", timeout=3) as response:
            html = response.read().decode("utf-8")
        self.assertIn('update.topic === "reset"', html)
        self.assertIn("current_stream_id", html)
        # It re-syncs (refresh) and reconnects rather than silently continuing.
        reset_index = html.index('update.topic === "reset"')
        window = html[reset_index:reset_index + 400]
        self.assertIn("refresh()", window)
        self.assertIn("streamAfter", window)


if __name__ == "__main__":
    unittest.main()
