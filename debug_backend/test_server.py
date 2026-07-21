from __future__ import annotations

import http.client
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

try:
    from .server import (
        BackendState,
        create_discovery_server,
        create_server,
        discovery_proof,
        parse_discovery_probe,
    )
except ImportError:
    from server import (
        BackendState,
        create_discovery_server,
        create_server,
        discovery_proof,
        parse_discovery_probe,
    )


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
            },
            method="POST",
        )
        with urlopen(request, timeout=3) as response:
            artifact = json.loads(response.read())
            self.assertEqual(response.status, 201)
        self.assertEqual(Path(artifact["stored_path"]).read_bytes(), content)
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
        content = b"x" * 48
        status, artifact = self.request(
            "/api/v1/artifacts",
            "POST",
            {
                "session_id": "s-json",
                "filename": "scene.xml",
                "kind": "xml",
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


if __name__ == "__main__":
    unittest.main()
