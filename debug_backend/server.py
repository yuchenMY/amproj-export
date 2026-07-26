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
import math
import mimetypes
import os
import re
import secrets
import signal
import socketserver
import stat as stat_module
import sys
import threading
import time
import uuid
from collections import OrderedDict, deque
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

# One arming of capture_next authorizes exactly one export transaction; the
# grant expires after this many seconds even if the device never uploads.
DEFAULT_CAPTURE_GRANT_TTL_SECONDS = 300.0
# An export emits at most scene.xml + the .amproj archive under one transaction.
DEFAULT_CAPTURE_GRANT_MAX_FILES = 2
DEFAULT_CAPTURE_GRANT_MAX_BYTES = DEFAULT_MAX_ARTIFACT_BYTES * 2
# Artifact kinds an export is allowed to upload; anything else is rejected.
DEFAULT_CAPTURE_ALLOWED_KINDS = frozenset(("xml", "amproj"))
# Persist a session heartbeat (last_seen) at most this often, per session, so a
# restart can recover activity driven by events/polls/acks/artifacts.
SESSION_TOUCH_PERSIST_SECONDS = 5.0
# A device counts as "active" for capture-target resolution if seen this recently.
ACTIVE_SESSION_WINDOW_SECONDS = 60.0
# Dedup index is decoupled from the display ring buffer and retains far more
# keys so a retried (session, seq) stays idempotent long after the event has
# scrolled out of the in-memory event window.
MAX_DEDUP_KEYS = 200_000

REDACTED = "[redacted]"
REDACTED_PATH = "[redacted-path]"
REDACTED_ID = "[redacted-id]"
MAX_REDACT_DEPTH = 16
MAX_REDACT_KEYS = 256
MAX_REDACT_ARRAY = 512
MAX_REDACT_STRING = 8192
# A relational/structural id is scrubbed for secrets/paths and length-capped so
# a hostile device cannot smuggle a blob through "transaction"/"session".
MAX_STRUCTURAL_LEN = 256
# uint64 upper bound for a device event seq; anything beyond is rejected (400).
MAX_SEQ = 2**63 - 1

# Relational/join id keys preserve ordinary IDs (including UUIDs) after targeted
# secret/path scrubbing. NOTE: bare "id" is NOT here — a device-supplied "id"
# (e.g. device.id) is an identifier and is hashed.
RELATIONAL_ID_KEYS = frozenset((
    "session", "sessionid", "seq", "transaction", "transactionid", "trace",
    "traceid", "spanid", "requestid", "correlationid",
))
# Enum/flag structural keys: kept as strings but their TEXT is still scrubbed
# (a hostile 'type': 'Bearer xyz' must not survive) and short-capped. They are
# never kept as arbitrary verbatim text.
ENUM_STRUCTURAL_KEYS = frozenset((
    "type", "kind", "level", "stage", "mode", "timems", "uptime", "timestamp",
    "receivedat", "protocolversion", "recordtype", "streamid", "topic", "revision",
))
# Enum values are short; anything longer is truncated (defense in depth).
MAX_ENUM_LEN = 128
# Normalized key substrings whose value is a secret -> redact outright.
SENSITIVE_KEY_SUBSTRINGS = (
    "authorization", "token", "cookie", "secret", "password", "passwd",
    "bearer", "apikey", "accesskey", "credential", "proof", "privatekey",
    "sessiontoken", "authtoken", "accesstoken", "refreshtoken", "license",
    "cardkey",
)
# Normalized keys that carry a device identifier -> replace with a stable hash.
# Bare "id" is included so a nested device.id / entity id is hashed, never kept.
IDENTIFIER_KEY_EXACT = frozenset(("ifv", "idfa", "udid", "idfv", "id", "eventid", "grantid"))
IDENTIFIER_KEY_SUBSTRINGS = (
    "identifierforvendor", "idforvendor", "deviceid", "vendorid", "advertisingid",
)

# Free-text scrubbing patterns.
URL_RE = re.compile(r"[a-z][a-z0-9+.\-]*://[^\s\"'<>]+", re.IGNORECASE)
# A bearer credential anywhere in free text, including dotted JWTs. Scrubbed
# FIRST so the two-token "Authorization: Bearer <tok>" form loses the token.
BEARER_RE = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]+=*")
# Header-shaped secrets consume the rest of their line. Treating only the first
# whitespace/semicolon-delimited token as secret would leak Basic credentials
# and later Cookie pairs.
AUTHORIZATION_HEADER_RE = re.compile(
    r"(?i)\bauthorization\s*[:=]\s*[^\r\n]+"
)
COOKIE_HEADER_RE = re.compile(r"(?i)\b(?:set-cookie|cookie)\s*[:=]\s*[^\r\n]+")
# Match only the key/assignment prefix. Value boundaries are scanned below so
# escaped quotes and embedded newlines cannot be mistaken for a closing quote.
INLINE_SECRET_PREFIX_RE = re.compile(
    r"(?i)(?:\\*[\"'])?\b(authorization|set-cookie|cookie|x-[a-z0-9-]*token|"
    r"access[_-]?token|refresh[_-]?token|auth[_-]?token|session[_-]?token|"
    r"api[_-]?key|access[_-]?key|license[_-]?key|card[_-]?key|private[_-]?key|"
    r"token|password|passwd|secret)\b(?:\\*[\"'])?[ \t\r\n]*[:=][ \t\r\n]*"
)
UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
# Absolute paths that END in a file extension, allowing spaces in the middle so
# a filename like "My Secret Project.amproj" is dropped WHOLE (basename too).
# Non-greedy up to the first extension so trailing prose is not consumed.
PATH_WITH_EXT_RE = re.compile(
    r"(?:/(?:private/)?(?:var|Users|home|mobile|Applications|Library|tmp|opt|etc)"
    r"|[A-Za-z]:\\)[^\n\r\"'<>;|]*?\.[A-Za-z0-9]{1,12}\b"
)
# Extensionless absolute paths (directories): terminate at whitespace/delimiter.
POSIX_PATH_RE = re.compile(
    r"/(?:private/)?(?:var|Users|home|mobile|Applications|Library|tmp|opt|etc)/[^\s\"'<>,;:]+"
)
WINDOWS_PATH_RE = re.compile(r"[A-Za-z]:\\[^\s\"'<>,;]+")
ISO_TIMESTAMP_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:?\d{2})?$"
)


def normalize_key(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(name).lower())


def hash_identifier(value: Any) -> str:
    text = str(value or "")
    if not text:
        return ""
    if text == "unknown-device":
        return text
    if re.fullmatch(r"ifv:[0-9a-f]{12}", text):
        return text  # sanitizer replay must not hash an already-anonymized id
    return "ifv:" + hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:12]


def _redact_url(match: "re.Match[str]") -> str:
    url = match.group(0)
    base = url.split("?", 1)[0].split("#", 1)[0]
    base = re.sub(r"//[^/@\s]*@", "//", base)  # strip userinfo (user:pass@)
    return base + "?" + REDACTED if ("?" in url or "#" in url) else base


def utf8_safe_text(text: str) -> str:
    """Replace unpaired surrogates so logs, JSON, and NDJSON stay encodable."""
    return str(text).encode("utf-8", "replace").decode("utf-8")


def _redact_inline_secrets(text: str) -> str:
    """Redact quoted secret assignments without trusting regex quote balance.

    Plain quotes use JSON-style odd/even backslash escaping. Escaped log JSON
    uses a run of backslashes before each syntax quote; only a quote with the
    same run length closes that value. If no unambiguous close exists, redact
    through end-of-input so truncated or multiline logs fail closed.
    """
    parts: list[str] = []
    cursor = 0
    while True:
        match = INLINE_SECRET_PREFIX_RE.search(text, cursor)
        if match is None:
            parts.append(text[cursor:])
            break

        value_start = match.end()
        parts.append(text[cursor:value_start])
        slash_end = value_start
        while slash_end < len(text) and text[slash_end] == "\\":
            slash_end += 1
        slash_count = slash_end - value_start

        if slash_end < len(text) and text[slash_end] in ('"', "'"):
            quote = text[slash_end]
            parts.append(text[value_start:slash_end + 1])
            scan = slash_end + 1
            close_quote = -1
            close_start = -1
            while True:
                candidate = text.find(quote, scan)
                if candidate < 0:
                    break
                backslash_start = candidate
                while backslash_start > slash_end + 1 \
                        and text[backslash_start - 1] == "\\":
                    backslash_start -= 1
                preceding = candidate - backslash_start
                is_close = (
                    preceding % 2 == 0 if slash_count == 0
                    else preceding == slash_count
                )
                if is_close:
                    close_quote = candidate
                    close_start = candidate if slash_count == 0 else backslash_start
                    break
                scan = candidate + 1

            parts.append(REDACTED)
            if close_quote < 0:
                cursor = len(text)
                break
            parts.append(text[close_start:close_quote + 1])
            cursor = close_quote + 1
            continue

        value_end = value_start
        while value_end < len(text) and text[value_end] not in " \t\r\n,;\"'":
            value_end += 1
        parts.append(REDACTED)
        cursor = value_end

    return "".join(parts)


def _scrub_text(text: str, *, redact_identifiers: bool) -> str:
    text = utf8_safe_text(text)
    if len(text) > MAX_REDACT_STRING:
        text = text[:MAX_REDACT_STRING] + "<truncated>"
    scrubbed = URL_RE.sub(_redact_url, text)
    scrubbed = _redact_inline_secrets(scrubbed)
    scrubbed = AUTHORIZATION_HEADER_RE.sub("Authorization: " + REDACTED, scrubbed)
    scrubbed = COOKIE_HEADER_RE.sub("Cookie: " + REDACTED, scrubbed)
    scrubbed = BEARER_RE.sub("Bearer " + REDACTED, scrubbed)
    if redact_identifiers:
        scrubbed = UUID_RE.sub(REDACTED_ID, scrubbed)
    scrubbed = PATH_WITH_EXT_RE.sub(REDACTED_PATH, scrubbed)
    scrubbed = POSIX_PATH_RE.sub(REDACTED_PATH, scrubbed)
    scrubbed = WINDOWS_PATH_RE.sub(REDACTED_PATH, scrubbed)
    return scrubbed


def redact_text(text: str) -> str:
    """Scrub secrets, device ids, URL query strings, and local paths from text.

    Order matters: whole bearer credentials are scrubbed BEFORE key:value pairs
    (so 'Authorization: Bearer <jwt>' loses the jwt, not just the word Bearer),
    then key:value secrets, then bare IFV/IDFA UUIDs, then absolute paths —
    extension-terminated first so a spaced 'My Secret Project.amproj' is removed
    whole (basename included), then extensionless directory paths.
    """
    return _scrub_text(text, redact_identifiers=True)


def redact_relational_text(text: str) -> str:
    """Scrub secrets and paths from join IDs while preserving ordinary UUIDs."""
    return _scrub_text(text, redact_identifiers=False)[:MAX_STRUCTURAL_LEN]


def _classify_key(name: str) -> str:
    """Classify a payload key for redaction. Priority order matters:

    - 'secret'     -> value redacted outright ('session_token' is a secret,
                      NOT a relational id, so it is caught here first).
    - 'identifier' -> value hashed (ifv/idfa/udid/deviceId AND bare 'id').
    - 'relational' -> a true join id (session/transaction/trace/...) scrubbed
                      for secrets/paths and length-capped; an ordinary UUID
                      survives intact for dedup/correlation.
    - 'enum'       -> a short enum/flag (type/kind/level/stage/mode/...) whose
                      TEXT is still scrubbed then short-capped, so a hostile
                      'type':'Bearer xyz' cannot leak through a structural key.
    - 'plain'      -> arbitrary free text, fully scrubbed."""
    norm = normalize_key(name)
    if any(part in norm for part in SENSITIVE_KEY_SUBSTRINGS):
        return "secret"
    if norm in IDENTIFIER_KEY_EXACT or any(part in norm for part in IDENTIFIER_KEY_SUBSTRINGS):
        return "identifier"
    if norm in RELATIONAL_ID_KEYS:
        return "relational"
    if norm in ENUM_STRUCTURAL_KEYS:
        return "enum"
    return "plain"


def _keep_relational(value: Any, depth: int) -> Any:
    """Preserve an ordinary join id after targeted secret/path scrubbing;
    nested containers recurse, and every string remains length-bounded."""
    if isinstance(value, str):
        return redact_relational_text(value)
    if isinstance(value, float):
        return value if math.isfinite(value) else "<unsupported>"
    if isinstance(value, (int, bool)) or value is None:
        return value
    return redact_value(value, depth + 1)


def _keep_enum(value: Any, depth: int) -> Any:
    """An enum/flag string is still SCRUBBED (a 'type' could carry injected
    text) and then short-capped; non-strings recurse/pass through."""
    if isinstance(value, str):
        return redact_text(value)[:MAX_ENUM_LEN]
    if isinstance(value, float):
        return value if math.isfinite(value) else "<unsupported>"
    if isinstance(value, (int, bool)) or value is None:
        return value
    return redact_value(value, depth + 1)


def redact_value(value: Any, depth: int = 0) -> Any:
    """Recursively redact secrets by key name and scrub sensitive free text.

    Applied to device-supplied payloads before they reach memory, the NDJSON
    journal, or the dashboard. Structural join keys preserve normal IDs after
    targeted secret/path scrubbing; arbitrary free text receives full scrubbing.
    Bounded on depth, key count, array length, and string length so a hostile
    or huge payload cannot exhaust memory or stack.
    """
    if depth > MAX_REDACT_DEPTH:
        return "<max-depth>"
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for count, (key, item) in enumerate(value.items()):
            if count >= MAX_REDACT_KEYS:
                result["_truncated"] = True
                break
            raw_name = str(key)
            # Dynamic keys are untrusted text too: a key such as
            # "token=SECRET", a URL, or a local path must not bypass the value
            # sanitizer merely because it appears to the left of a colon.
            # Classify the ORIGINAL key before truncation; otherwise a secret
            # suffix beyond MAX_STRUCTURAL_LEN can turn into a plain field.
            kind = _classify_key(raw_name)
            name = redact_text(raw_name)[:MAX_STRUCTURAL_LEN]
            if kind == "secret":
                result[name] = REDACTED
            elif kind == "identifier":
                result[name] = hash_identifier(item)
            elif kind == "relational":
                result[name] = _keep_relational(item, depth)
            elif kind == "enum":
                result[name] = _keep_enum(item, depth)
            else:
                result[name] = redact_value(item, depth + 1)
        return result
    if isinstance(value, (list, tuple)):
        items = list(value)
        capped = [redact_value(item, depth + 1) for item in items[:MAX_REDACT_ARRAY]]
        if len(items) > MAX_REDACT_ARRAY:
            capped.append("<truncated>")
        return capped
    if isinstance(value, str):
        return redact_text(value)
    if value is None or isinstance(value, (bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else "<unsupported>"
    return "<unsupported>"


def safe_event_timestamp(safe_payload: dict[str, Any], received_at: str) -> str:
    """Timestamp read from the REDACTED payload and validated, never bypassing
    the sanitizer. A client-supplied timestamp is only trusted if it looks like
    ISO-8601; otherwise time_ms is converted, else received_at is used."""
    supplied = safe_payload.get("timestamp")
    if isinstance(supplied, str) and ISO_TIMESTAMP_RE.match(supplied):
        return supplied
    milliseconds = safe_payload.get("time_ms")
    if isinstance(milliseconds, (int, float)) and not isinstance(milliseconds, bool) and milliseconds > 0:
        try:
            return datetime.fromtimestamp(milliseconds / 1000, timezone.utc).isoformat(
                timespec="milliseconds"
            ).replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            pass
    return received_at


def payload_fingerprint(payload: Any) -> str:
    """Deterministic content hash of a redacted payload, excluding volatile
    transport fields, so a genuine retry and a colliding-but-different payload
    can be told apart under the same (session, seq) key."""
    if isinstance(payload, dict):
        stable = {k: v for k, v in payload.items()
                  if normalize_key(k) not in ("timems", "uptime", "receivedat", "timestamp")}
    else:
        stable = payload
    encoded = json.dumps(stable, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8", "replace")).hexdigest()


class SeqRangeError(ValueError):
    """A device seq is present but out of the accepted numeric range."""


def normalized_seq(seq: Any) -> int | None:
    """Return the canonical int for a dedupable seq, None if seq is absent/not a
    number, or raise SeqRangeError for a present-but-out-of-range value.

    A seq may arrive as an int or a short numeric string. It must fit in the
    unsigned 64-bit range [0, MAX_SEQ]; a 5000-digit or negative value is
    rejected (caller maps SeqRangeError -> HTTP 400, never a 500)."""
    if seq is None or isinstance(seq, bool):
        return None
    if isinstance(seq, int):
        candidate = seq
    elif isinstance(seq, str):
        text = seq.strip()
        # Cheap length guard before int() so a giant string is never converted.
        if not text or len(text) > 20 or not text.lstrip("-").isdigit():
            raise SeqRangeError("seq is not a valid integer")
        candidate = int(text)
    else:
        return None  # non-numeric type: simply not dedupable
    if candidate < 0 or candidate > MAX_SEQ:
        raise SeqRangeError("seq is out of the accepted range")
    return candidate


def event_dedup_key(session_id: str, seq: Any) -> tuple[str, int] | None:
    """A stable idempotency key for a device event, or None when not dedupable.
    Raises SeqRangeError for a present-but-out-of-range seq."""
    canonical = normalized_seq(seq)
    if canonical is None:
        return None
    return (session_id, canonical)


def sanitize_event_payload(raw: dict[str, Any]) -> tuple[dict[str, Any], int | None]:
    """Redact an event and retain its canonical seq independent of key order."""
    safe_payload = redact_value(raw)
    canonical_seq = normalized_seq(raw.get("seq"))
    if canonical_seq is not None:
        remaining = [
            (key, value) for key, value in safe_payload.items()
            if key not in ("seq", "_truncated")
        ]
        was_truncated = bool(safe_payload.get("_truncated")) \
            or len(remaining) > MAX_REDACT_KEYS - 1
        safe_payload = {"seq": canonical_seq}
        safe_payload.update(dict(remaining[:MAX_REDACT_KEYS - 1]))
        if was_truncated:
            safe_payload["_truncated"] = True
    return safe_payload, canonical_seq


class JournalWriteError(Exception):
    """Raised when the append-only journal cannot be durably written. The
    caller must surface a retryable error and leave no in-memory side effect.

    ``commit_uncertain`` means the failed append could not be durably rolled
    back. The state then blocks later writes until restart so IDs/revisions
    cannot diverge from whichever bytes the filesystem ultimately retained.
    Artifact callers must also keep their temp blob for startup reconciliation.
    """

    def __init__(self, message: str, *, commit_uncertain: bool = False) -> None:
        super().__init__(message)
        self.commit_uncertain = commit_uncertain


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def safe_component(value: Any, fallback: str) -> str:
    cleaned = SAFE_NAME_RE.sub("_", utf8_safe_text(str(value or ""))).strip("._")
    return cleaned[:120] or fallback


def path_exists_strict(path: Path) -> bool:
    """Return False only for a confirmed missing path.

    ``Path.exists()`` may collapse permission and device errors into False on
    newer Python versions. Persistence callers need those errors to remain
    visible so an unreadable journal is never mistaken for an empty one.
    """
    try:
        path.stat()
    except FileNotFoundError:
        return False
    return True


def safe_relational_component(value: Any, fallback: str) -> str:
    return safe_component(redact_relational_text(str(value or "")), fallback)


def safe_artifact_filename(value: Any, kind: str) -> str:
    """Use opaque standard names; a user/project title is never persisted."""
    del value
    if kind == "xml":
        return "scene.xml"
    if kind == "amproj":
        return "project.amproj"
    return "artifact.bin"


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
        capture_grant_ttl: float = DEFAULT_CAPTURE_GRANT_TTL_SECONDS,
        capture_grant_max_files: int = DEFAULT_CAPTURE_GRANT_MAX_FILES,
        capture_grant_max_bytes: int | None = None,
        capture_allowed_kinds: frozenset[str] = DEFAULT_CAPTURE_ALLOWED_KINDS,
    ) -> None:
        self.data_dir = Path(data_dir)
        self.artifact_dir = self.data_dir / "artifacts"
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.artifact_dir.mkdir(parents=True, exist_ok=True)
        self.journal_path = self.data_dir / "events.ndjson"
        self.token = token
        self.max_artifact_bytes = max_artifact_bytes
        self.capture_grant_ttl = capture_grant_ttl
        self.capture_grant_max_files = capture_grant_max_files
        self.capture_grant_max_bytes = (
            capture_grant_max_bytes if capture_grant_max_bytes is not None
            else max_artifact_bytes * capture_grant_max_files
        )
        self.capture_allowed_kinds = capture_allowed_kinds

        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        # A dedicated journal-append lock keeps disk writes serialized even if
        # the RLock is reentered; every logical operation writes ONE line.
        self.journal_lock = threading.Lock()
        # Set when startup cannot read the journal or an append cannot be
        # durably rolled back. Durable state is then unknown, so state-bearing
        # reads and all later writes fail retryably until restart/replay.
        self._journal_poisoned = False
        # Fast in-memory dedup cache (session, seq) -> {"id","fingerprint"},
        # capped at self.max_dedup_keys. A cache miss for a dedupable key falls
        # back to a journal scan, so dedup is PERMANENT (never re-accepts an old
        # seq just because the cache evicted it).
        self.max_dedup_keys = MAX_DEDUP_KEYS
        # session_id -> monotonic clock of the last persisted last_seen touch,
        # to rate-limit poll heartbeats (the only op with no other record).
        self._last_touch_persist: dict[str, float] = {}
        self._reset_state_locked()
        # Rebuild in-memory state from the append-only journal so a restart
        # preserves sessions, events, commands, config, grants, and the cursor.
        self.replay_stats = self._replay_journal_locked()

    def _reset_state_locked(self) -> None:
        """Initialize/clear all in-memory collections to a pristine baseline.

        Replay rebuilds from this baseline, so running replay again is fully
        idempotent (clear-then-rebuild, never append onto live collections)."""
        self.sessions: dict[str, dict[str, Any]] = {}
        self.events: deque[dict[str, Any]] = deque(maxlen=MAX_IN_MEMORY_EVENTS)
        self.commands: deque[dict[str, Any]] = deque(maxlen=1_000)
        self.command_acks: dict[str, set[int]] = {}
        self.stream_updates: deque[dict[str, Any]] = deque(maxlen=MAX_STREAM_UPDATES)
        self.event_keys: "OrderedDict[tuple[str, int], dict[str, Any]]" = OrderedDict()
        self.dedup_conflicts = 0
        self.capture_grants: "OrderedDict[str, dict[str, Any]]" = OrderedDict()
        # (session, transaction, kind, sha256) -> artifact record, for idempotent
        # artifact retries (same file returns the same artifact_id, no second copy).
        self.artifact_keys: dict[tuple[str, str, str, str], dict[str, Any]] = {}
        self.event_id = 0
        self.stream_id = 0
        self.config: dict[str, Any] = {
            "mode": "full",
            "capture_next": False,
            "revision": 0,
            "updated_at": utc_now(),
        }

    def _normalize_replayed_capture_state_locked(self) -> None:
        """Fail closed when replay restores an arm without a usable grant.

        Pre-P1 command records could persist capture_next=True but had no grant
        model, and a P1 pending grant can expire while the process is stopped.
        Replaying either state verbatim tells a device to upload while the P1
        authorization gate must reject it. Synthesize deterministic, memory-only
        disarm commands so clients converge without changing the source journal.

        If another session still has a live pending grant, only expired sessions
        are targeted and the global capture flag remains true. Otherwise one
        broadcast disarm clears every client and the global flag becomes false.
        """
        now_epoch = time.time()
        pending = [
            grant for grant in self.capture_grants.values()
            if not grant["revoked"] and not grant["bound"] and not grant["consumed"]
        ]
        live_sessions = {
            grant["session_id"] for grant in pending
            if grant["expires_at"] > now_epoch
        }
        expired_sessions = {
            grant["session_id"] for grant in pending
            if grant["expires_at"] <= now_epoch
        } - live_sessions

        latest_capture = next(
            (
                command for command in reversed(self.commands)
                if command.get("type") == "capture_next"
            ),
            None,
        )
        terminal_broadcast_disarm = (
            latest_capture is not None
            and latest_capture.get("enabled") is False
            and not latest_capture.get("target_session")
        )
        needs_broadcast = not live_sessions and (
            self.config.get("capture_next") is True
            or (latest_capture is not None and not terminal_broadcast_disarm)
        )
        if needs_broadcast:
            targets = [""]
            next_capture = False
        elif live_sessions and expired_sessions:
            targets = sorted(expired_sessions)
            next_capture = True
        else:
            return

        current_revision = self.config["revision"]
        if (current_revision > MAX_SEQ - len(targets)
                or self.stream_id > MAX_SEQ - len(targets)):
            # There is no honest cursor value with which to deliver the required
            # disarm. Keep the service fail-closed instead of exposing armed=true.
            self._journal_poisoned = True
            return
        created_at = self.config.get("updated_at")
        if not isinstance(created_at, str):
            created_at = "1970-01-01T00:00:00.000Z"
        for target in targets:
            current_revision += 1
            fields: dict[str, Any] = {"enabled": False}
            if target:
                fields["session_id"] = target
            command = self._build_command(
                current_revision,
                "capture_next",
                fields,
                "replay-capture-normalization",
                created_at,
                self.config["mode"],
                next_capture,
                target_session=target,
            )
            self.commands.append(command)
        self.config.update({
            "capture_next": next_capture,
            "revision": current_revision,
            "updated_at": created_at,
        })

        # A P1-era malformed record can carry a stream id while omitting its
        # grant. Emit the same deterministic migration to SSE so a dashboard
        # that reconnects at the old cursor cannot be left showing "armed".
        for _target in targets:
            self.stream_id += 1
            self.stream_updates.append({
                "stream_id": self.stream_id,
                "topic": "command",
                "data": dict(self.config),
            })

    # -- Persistence / replay ------------------------------------------------

    def _replay_journal_locked(self) -> dict[str, int]:
        """Rebuild in-memory state from the NDJSON journal, idempotently.

        Clears state first, then applies every VALID record through the same
        _apply_record used by the live path. The journal is read in BINARY and
        decoded per line, so invalid UTF-8, malformed JSON, and schema-invalid
        records are each isolated (counted as skipped) without blocking later
        records. Because each record is a self-contained, deterministic delta
        (ids/revisions/cursors baked in), running replay twice on the same
        instance yields identical state and counts with no duplication.
        """
        stats = {"replayed": 0, "skipped": 0}
        with self.lock:
            self._reset_state_locked()
            self._journal_poisoned = False
            handle = None
            try:
                journal_exists = path_exists_strict(self.journal_path)
            except OSError:
                journal_exists = True
                self._journal_poisoned = True
            if journal_exists and not self._journal_poisoned:
                try:
                    handle = self.journal_path.open("rb")
                except OSError:
                    self._journal_poisoned = True
            if handle is not None:
                try:
                    # Opening the journal is not enough to establish a safe
                    # replay boundary: network filesystems and faulted disks
                    # can fail while iterating or closing an already-open file.
                    # Any such error makes the durable state uncertain, so keep
                    # the partial in-memory prefix but fail closed and preserve
                    # artifact temps for a later restart.
                    with handle:
                        for raw_line in handle:
                            raw_line = raw_line.strip()
                            if not raw_line:
                                continue
                            try:
                                record = json.loads(raw_line.decode("utf-8"))
                                if not isinstance(record, dict):
                                    raise ValueError("record is not an object")
                            except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                                stats["skipped"] += 1  # invalid UTF-8 / bad JSON
                                continue
                            try:
                                valid = self._record_is_valid(record)
                            except Exception:
                                valid = False
                            if not valid:
                                stats["skipped"] += 1  # schema-invalid: never applied
                                continue
                            if not self._record_order_is_valid(record):
                                stats["skipped"] += 1  # stale/duplicate ids or cursors
                                continue
                            try:
                                self._apply_record(record)
                            except Exception:
                                stats["skipped"] += 1  # defensive: one record cannot abort replay
                                continue
                            stats["replayed"] += 1
                except OSError:
                    self._journal_poisoned = True
            # With a readable (or absent) journal, reconcile committed temps and
            # sweep true orphans. A read-open failure is fail-closed: do not
            # delete any temp whose commit status could not be established.
            if not self._journal_poisoned:
                self._normalize_replayed_capture_state_locked()
                if not self._journal_poisoned:
                    self._reconcile_artifacts_locked()
        return stats

    # -- Schema validation ---------------------------------------------------

    @staticmethod
    def _is_int(value: Any) -> bool:
        return isinstance(value, int) and not isinstance(value, bool)

    def _stream_id_is_valid(self, record: dict[str, Any], *, required: bool = False) -> bool:
        if "stream_id" not in record:
            return not required
        stream_id = record.get("stream_id")
        return self._is_int(stream_id) and 0 <= stream_id <= MAX_SEQ

    @staticmethod
    def _command_target(command: dict[str, Any]) -> str:
        """Return the capture target while preserving explicit broadcast.

        P1 commands carry target_session. Older targeted commands only carried
        session_id, so that field is a fallback only when target_session is
        absent; an explicitly empty target_session still means broadcast.
        """
        if "target_session" in command:
            target = command.get("target_session")
        else:
            target = command.get("session_id", "")
        return target if isinstance(target, str) else ""

    def _command_is_valid(self, command: Any) -> bool:
        """A command must carry every field get_commands / the poller reads,
        with consistent id/revision and a valid mode enum."""
        if not isinstance(command, dict):
            return False
        revision = command.get("revision")
        identifier = command.get("id")
        if not (self._is_int(revision) and self._is_int(identifier)):
            return False
        if revision < 0 or revision > MAX_SEQ or identifier != revision:
            return False
        if command.get("type") not in ("set_mode", "capture_next", "flush"):
            return False
        if command.get("mode") not in MODES:  # mode must be a known enum
            return False
        if not isinstance(command.get("capture_next"), bool):
            return False
        # Target fields, when present, must be strings. Legacy commands used
        # session_id before target_session became the delivery field.
        if ("target_session" in command and not isinstance(command.get("target_session"), str)):
            return False
        if "session_id" in command and not isinstance(command.get("session_id"), str):
            return False
        target = self._command_target(command)
        if command["type"] == "capture_next":
            enabled = command.get("enabled")
            if not isinstance(enabled, bool):
                return False
            # A true arm always makes aggregate capture state true. A false
            # command may keep it true only when it targets one session while
            # another session still has a live pending grant.
            if enabled and command["capture_next"] is not True:
                return False
            if not enabled and command["capture_next"] is True and not target:
                return False
        return True

    @staticmethod
    def _sanitize_command(command: dict[str, Any]) -> dict[str, Any]:
        safe = {
            key: command[key] for key in (
                "record_type", "id", "revision", "type", "mode", "capture_next",
            ) if key in command
        }
        if "enabled" in command and isinstance(command["enabled"], bool):
            safe["enabled"] = command["enabled"]
        if isinstance(command.get("session_id"), str):
            safe["session_id"] = safe_relational_component(command["session_id"], "")
        if "target_session" in command:
            target = command.get("target_session")
            safe["target_session"] = safe_relational_component(target, "") if target else ""
        if isinstance(command.get("source"), str):
            safe["source"] = redact_text(command["source"])[:MAX_ENUM_LEN]
        if isinstance(command.get("created_at"), str):
            safe["created_at"] = redact_text(command["created_at"])[:MAX_STRUCTURAL_LEN]
        return safe

    @staticmethod
    def _sanitize_config_snapshot(config: dict[str, Any]) -> dict[str, Any]:
        safe = {
            "mode": config["mode"],
            "capture_next": config["capture_next"],
            "revision": config["revision"],
        }
        if isinstance(config.get("updated_at"), str):
            safe["updated_at"] = redact_text(config["updated_at"])[:MAX_STRUCTURAL_LEN]
        return safe

    def _artifact_is_valid(self, artifact: Any) -> bool:
        """Validate every field used by idempotency, replay, and blob repair."""
        if not isinstance(artifact, dict):
            return False
        required_strings = (
            "artifact_id", "session_id", "transaction", "kind", "sha256",
            "filename", "stored_path", "received_at", "grant_id",
        )
        if not all(isinstance(artifact.get(key), str) and artifact[key]
                   for key in required_strings):
            return False
        if not re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]):
            return False
        if not self._is_int(artifact.get("size")) or artifact["size"] < 0:
            return False
        if not isinstance(artifact.get("metadata"), dict):
            return False
        # A bundled record must point inside this state's artifact root. The
        # final file may legitimately be absent while its committed temp is
        # waiting for startup reconciliation.
        paths = self._artifact_storage_paths(artifact)
        if paths is None:
            return False
        final, temp = paths
        for candidate in (final, temp):
            try:
                mode = candidate.stat().st_mode
            except FileNotFoundError:
                continue
            except OSError:
                self._journal_poisoned = True
                return False
            if not stat_module.S_ISREG(mode):
                return False
        return True

    def _grant_is_valid(self, grant: Any) -> bool:
        """A grant must carry every field the authorization path reads, with
        sane ranges, so a partial or corrupt snapshot can never KeyError or
        mis-authorize during _authorize_capture_locked / disarm."""
        if not isinstance(grant, dict):
            return False
        if not (isinstance(grant.get("grant_id"), str) and grant["grant_id"]):
            return False
        for flag in ("bound", "consumed", "revoked"):
            if not isinstance(grant.get(flag), bool):
                return False
        files, byte_count = grant.get("files"), grant.get("bytes")
        max_files, max_bytes = grant.get("max_files"), grant.get("max_bytes")
        if not all(self._is_int(v) for v in (files, byte_count, max_files, max_bytes)):
            return False
        # Non-negative, and never already over their own limits.
        if files < 0 or byte_count < 0 or max_files < 0 or max_bytes < 0:
            return False
        if files > max_files or byte_count > max_bytes:
            return False
        if max_files > self.capture_grant_max_files or max_bytes > self.capture_grant_max_bytes:
            return False
        if not (isinstance(grant.get("allowed_kinds"), list)
                and grant["allowed_kinds"]
                and all(isinstance(k, str) and k for k in grant["allowed_kinds"])
                and len(set(grant["allowed_kinds"])) == len(grant["allowed_kinds"])):
            return False
        if not set(grant["allowed_kinds"]).issubset(self.capture_allowed_kinds):
            return False
        # These are the only two states produced by the live capture path:
        # pending (not bound/consumed, no counters or transaction) and consumed
        # (bound/consumed, at least one file and a transaction). Accepting a
        # hybrid state would let a corrupt replay authorize or revoke strangely.
        if grant["bound"] != grant["consumed"]:
            return False
        # session_id is required (a grant is always bound to a device at arm
        # time); transaction is a non-empty string once bound, else null.
        if not isinstance(grant.get("session_id"), str) or not grant["session_id"]:
            return False
        if "transaction" not in grant:
            return False
        transaction = grant["transaction"]
        if grant["bound"]:
            if not isinstance(transaction, str) or not transaction:
                return False
            if files < 1:
                return False
        elif transaction is not None:
            return False
        elif files != 0 or byte_count != 0:
            return False
        expires_at = grant.get("expires_at")
        if not (isinstance(expires_at, (int, float))
                and not isinstance(expires_at, bool)):
            return False
        try:
            if not math.isfinite(expires_at):
                return False
        except (OverflowError, TypeError):
            return False
        return True

    def _record_is_valid(self, record: dict[str, Any]) -> bool:
        """Strict, fully NESTED per-type schema check. A record is rejected if
        any field a later reader depends on is missing or mistyped, so it can
        never pollute running state (e.g. hello without last_seen, command
        without revision, grant without revoked, event without type)."""
        if not isinstance(record, dict):
            return False
        record_type = record.get("record_type")
        if record_type == "hello":
            session = record.get("session")
            return (
                self._stream_id_is_valid(record)
                and
                isinstance(session, dict)
                and isinstance(session.get("session_id"), str) and bool(session["session_id"])
                and isinstance(session.get("last_seen"), str)
                and isinstance(session.get("connected_at"), str)
            )
        if record_type == "event":
            structurally_valid = (
                self._is_int(record.get("id"))
                and 0 <= record["id"] <= MAX_SEQ
                and self._stream_id_is_valid(record)
                and isinstance(record.get("session_id"), str)
                and isinstance(record.get("received_at"), str)
                and isinstance(record.get("type"), str)
                and isinstance(record.get("level"), str)
                and isinstance(record.get("payload"), dict)
            )
            if not structurally_valid:
                return False
            try:
                sanitize_event_payload(record["payload"])
            except (SeqRangeError, TypeError, ValueError):
                return False
            return True
        if record_type == "event_batch":
            events = record.get("events")
            if not (isinstance(events, list) and 1 <= len(events) <= 500):
                return False
            if not all(
                isinstance(event, dict)
                and event.get("record_type") == "event"
                and self._stream_id_is_valid(event, required=True)
                and self._record_is_valid(event)
                for event in events
            ):
                return False
            event_ids = [event["id"] for event in events]
            stream_ids = [event["stream_id"] for event in events]
            return (
                event_ids == list(range(event_ids[0], event_ids[0] + len(event_ids)))
                and stream_ids == list(range(stream_ids[0], stream_ids[0] + len(stream_ids)))
            )
        if record_type == "command_batch":
            config = record.get("config")
            commands = record.get("commands")
            grants = record.get("grants", [])
            if not (isinstance(commands, list) and isinstance(config, dict) and isinstance(grants, list)):
                return False
            if not self._stream_id_is_valid(record, required=True):
                return False
            if not (self._is_int(config.get("revision"))
                    and 0 <= config["revision"] <= MAX_SEQ
                    and config.get("mode") in MODES
                    and isinstance(config.get("capture_next"), bool)):
                return False
            # Every embedded command and grant must itself be complete.
            if not all(self._command_is_valid(c) for c in commands):
                return False
            if not all(self._grant_is_valid(g) for g in grants):
                return False
            # A batch is one ordered revision transaction. If its config lags a
            # command (or commands repeat/jump), a poll cursor can permanently
            # advance past future live commands.
            revisions = [command["revision"] for command in commands]
            if not revisions:
                return False
            if revisions != list(range(revisions[0], revisions[0] + len(revisions))):
                return False
            if config["revision"] != revisions[-1]:
                return False
            if (commands[-1]["mode"] != config["mode"]
                    or commands[-1]["capture_next"] != config["capture_next"]):
                return False
            pending_grants = [
                grant for grant in grants
                if not grant["bound"] and not grant["revoked"]
            ]
            capture_commands = [
                command for command in commands
                if command["type"] == "capture_next" and command["enabled"] is True
            ]
            # A live arming always persists a pending grant in the same batch;
            # a mode/flush command must never smuggle an unrevoked grant into
            # replay while capture_next is false.
            if pending_grants and (not config["capture_next"] or not capture_commands):
                return False
            return True
        if record_type == "command":  # legacy single-command line
            return self._stream_id_is_valid(record) and self._command_is_valid(record)
        if record_type == "command_ack":
            ack = record.get("acknowledged")
            return (
                isinstance(record.get("session_id"), str)
                and self._stream_id_is_valid(record)
                and isinstance(ack, list)
                and all(self._is_int(i) and 0 <= i <= MAX_SEQ for i in ack)
            )
        if record_type == "artifact":
            artifact = record.get("artifact")
            if isinstance(artifact, dict):  # new bundled form
                if not self._artifact_is_valid(artifact):
                    return False
                # Bundled grant + optional reset command must be complete too.
                grant = record.get("grant")
                if not self._grant_is_valid(grant):
                    return False
                if not (grant["grant_id"] == artifact["grant_id"]
                        and grant["session_id"] == artifact["session_id"]
                        and grant["transaction"] == artifact["transaction"]
                        and grant["bound"] and grant["consumed"]
                        and grant["files"] >= 1
                        and grant["bytes"] >= artifact["size"]
                        and artifact["kind"] in grant["allowed_kinds"]):
                    return False
                if not (isinstance(record.get("received_at"), str)
                        and self._is_int(record.get("stream_id"))
                        and 0 <= record["stream_id"] <= MAX_SEQ):
                    return False
                expiry_snapshots = record.get("expiry_snapshots", [])
                if not isinstance(expiry_snapshots, list):
                    return False
                if not all(self._grant_is_valid(g) for g in expiry_snapshots):
                    return False
                reset = record.get("reset_command")
                if reset is not None:
                    reset_config = record.get("reset_config")
                    reset_stream_id = record.get("reset_stream_id")
                    reset_target = reset.get("target_session") \
                        if isinstance(reset, dict) else None
                    if not (self._command_is_valid(reset)
                            and reset.get("type") == "capture_next"
                            and reset.get("enabled") is False
                            and (
                                (reset["capture_next"] is True
                                 and reset_target == artifact["session_id"])
                                or (reset["capture_next"] is False
                                    and reset_target == "")
                            )
                            and isinstance(reset_config, dict)
                            and self._is_int(reset_config.get("revision"))
                            and reset_config["revision"] == reset["revision"]
                            and reset_config.get("mode") == reset["mode"]
                            and reset_config.get("capture_next") == reset["capture_next"]
                            and reset["revision"] <= MAX_SEQ
                            and self._is_int(reset_stream_id)
                            and reset_stream_id == record["stream_id"] + 1
                            and reset_stream_id <= MAX_SEQ):
                        return False
                elif "reset_config" in record or "reset_stream_id" in record:
                    return False
                return True
            # Legacy top-level artifact: accept the complete pre-P1 shape, but
            # never a partial record that could leak a path through SSE.
            if not (
                isinstance(record.get("artifact_id"), str) and bool(record["artifact_id"])
                and isinstance(record.get("session_id"), str) and bool(record["session_id"])
                and isinstance(record.get("filename"), str) and bool(record["filename"])
                and isinstance(record.get("kind"), str) and bool(record["kind"])
                and self._is_int(record.get("size")) and record["size"] >= 0
                and isinstance(record.get("sha256"), str)
                and re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) is not None
                and isinstance(record.get("stored_path"), str) and bool(record["stored_path"])
                and isinstance(record.get("received_at"), str)
                and isinstance(record.get("metadata"), dict)
                and self._stream_id_is_valid(record)
            ):
                return False
            return self._artifact_storage_paths(record) is not None
        if record_type == "session_touch":
            return isinstance(record.get("session_id"), str) and isinstance(record.get("last_seen"), str)
        if record_type == "capture_grant":  # legacy standalone grant snapshot
            return self._grant_is_valid(record.get("grant"))
        return False

    def _record_order_is_valid(self, record: dict[str, Any]) -> bool:
        """Reject valid-looking records that move durable cursors backwards."""
        record_type = record.get("record_type")

        if record_type == "event":
            if record["id"] <= self.event_id and "stream_id" in record:
                return False
        elif record_type == "event_batch":
            event_ids = [event["id"] for event in record["events"]]
            if event_ids[0] <= self.event_id:
                return False

        if record_type == "command":
            if record["revision"] <= self.config["revision"] and "stream_id" in record:
                return False
            if (record["revision"] <= self.config["revision"]
                    and "stream_id" not in record and self.config["revision"] >= MAX_SEQ):
                return False
        elif record_type == "command_batch":
            if record["commands"][0]["revision"] <= self.config["revision"]:
                return False
        elif record_type == "artifact" and isinstance(record.get("reset_command"), dict):
            if record["reset_command"]["revision"] <= self.config["revision"]:
                return False

        grant_snapshots: list[Any] = []
        if record_type == "capture_grant":
            grant_snapshots = [record.get("grant")]
        elif record_type == "command_batch":
            grant_snapshots = list(record.get("grants", []))
        elif record_type == "artifact" and isinstance(record.get("artifact"), dict):
            grant_snapshots = list(record.get("expiry_snapshots", []))
            grant_snapshots.append(record.get("grant"))
        # A single record can carry several snapshots of the same grant (for
        # example expiry/revocation followed by a bundled artifact snapshot).
        # Validate each candidate against the state produced by the previous
        # candidate in this record, rather than repeatedly comparing with the
        # pre-record live map.
        grant_states = dict(self.capture_grants)
        for raw_grant in grant_snapshots:
            candidate = self._sanitize_grant_snapshot(raw_grant)
            if candidate is None:
                return False
            if not self._grant_is_valid(candidate):
                return False
            current = grant_states.get(candidate["grant_id"])
            if current is not None and (
                    not self._grant_snapshot_advances(current, candidate)
                    or not self._grant_transition_is_valid(current, candidate)):
                return False
            grant_states[candidate["grant_id"]] = candidate
        if record_type == "capture_grant":
            candidate = self._sanitize_grant_snapshot(record.get("grant"))
            if (candidate is not None and not candidate["bound"] and not candidate["revoked"]
                    and not self.config["capture_next"]):
                return False

        if record_type == "artifact" and isinstance(record.get("artifact"), dict):
            artifact = self._sanitize_artifact_record(record["artifact"])
            prefix = (
                str(artifact.get("session_id") or ""),
                str(artifact.get("transaction") or ""),
                str(artifact.get("kind") or ""),
            )
            if all(prefix) and any(key[:3] == prefix for key in self.artifact_keys):
                return False

        stream_ids: list[int] = []
        if record_type == "event_batch":
            stream_ids = [event["stream_id"] for event in record["events"]]
        elif self._is_int(record.get("stream_id")):
            stream_ids = [record["stream_id"]]
            if record_type == "artifact" and self._is_int(record.get("reset_stream_id")):
                stream_ids.append(record["reset_stream_id"])
        if stream_ids:
            if any(later <= earlier for earlier, later in zip(stream_ids, stream_ids[1:])):
                return False
            if stream_ids[0] <= self.stream_id:
                return False
        return True

    # -- The single apply function (used by both live commit and replay) -----

    def _bump_stream_locked(self, stream_id: Any, topic: str, data: dict[str, Any]) -> None:
        if not self._is_int(stream_id) or not 0 <= stream_id <= MAX_SEQ:
            return
        self.stream_updates.append({"stream_id": stream_id, "topic": topic, "data": data})
        if stream_id > self.stream_id:
            self.stream_id = stream_id

    def _sanitize_grant_snapshot(self, grant: Any) -> dict[str, Any] | None:
        if isinstance(grant, dict) and isinstance(grant.get("grant_id"), str):
            safe = {
                key: grant[key] for key in (
                    "grant_id", "armed_at", "expires_at", "session_id", "transaction",
                    "bound", "consumed", "revoked", "files", "bytes", "max_files",
                    "max_bytes", "allowed_kinds",
                ) if key in grant
            }
            safe["grant_id"] = safe_relational_component(grant["grant_id"], "")
            safe["session_id"] = safe_relational_component(grant.get("session_id"), "")
            if isinstance(grant.get("transaction"), str):
                safe["transaction"] = redact_relational_text(grant["transaction"])
            if isinstance(grant.get("armed_at"), str):
                safe["armed_at"] = redact_text(grant["armed_at"])[:MAX_STRUCTURAL_LEN]
            safe["allowed_kinds"] = [
                safe_component(_keep_enum(kind, 0), "artifact")
                for kind in grant.get("allowed_kinds", [])
                if isinstance(kind, str)
            ]
            if not safe["grant_id"] or not safe["session_id"]:
                return None
            return safe
        return None

    def _apply_grant_snapshot_locked(self, grant: Any) -> None:
        safe = self._sanitize_grant_snapshot(grant)
        if safe is not None:
            self.capture_grants[safe["grant_id"]] = safe
            self.capture_grants.move_to_end(safe["grant_id"])

    def _has_live_pending_capture_locked(self, now_epoch: float | None = None) -> bool:
        """Return whether any unexpired, unbound grant still represents an arm."""
        if now_epoch is None:
            now_epoch = time.time()
        return any(
            not grant["revoked"]
            and not grant["bound"]
            and not grant["consumed"]
            and grant["expires_at"] > now_epoch
            for grant in self.capture_grants.values()
        )

    def _apply_pending_disarm_locked(self, command: dict[str, Any]) -> bool:
        """Derive pending-grant revocation from a durable disarm command.

        Legacy journals persisted capture commands and standalone grant
        snapshots independently. A later disarm is therefore authoritative even
        when it has no matching revoked-grant snapshot. Bound grants are left
        intact so the second file of an already-started XML/amproj transaction
        remains authorized; current explicit disarm batches still revoke those
        through their persisted grant snapshots. A targeted legacy disarm can
        carry the target device's local ``capture_next=false`` even while a
        different device remains armed; normalize that command's aggregate flag
        from the remaining live grants. Return whether the disarm was targeted.
        """
        if command.get("type") != "capture_next" or command.get("enabled") is not False:
            return False
        target = self._command_target(command)
        for grant_id, grant in list(self.capture_grants.items()):
            if grant["revoked"] or grant["bound"]:
                continue
            if target and grant["session_id"] != target:
                continue
            revoked = dict(grant)
            revoked["revoked"] = True
            self.capture_grants[grant_id] = revoked
        if target:
            command["capture_next"] = self._has_live_pending_capture_locked()
            return True
        return False

    @staticmethod
    def _grant_snapshot_advances(current: dict[str, Any], candidate: dict[str, Any]) -> bool:
        immutable = ("session_id", "max_files", "max_bytes", "allowed_kinds", "expires_at")
        if any(candidate.get(key) != current.get(key) for key in immutable):
            return False
        for flag in ("bound", "consumed", "revoked"):
            if current.get(flag) is True and candidate.get(flag) is not True:
                return False
        for counter in ("files", "bytes"):
            if candidate.get(counter, -1) < current.get(counter, -1):
                return False
        if current.get("transaction") is not None \
                and candidate.get("transaction") != current.get("transaction"):
            return False
        return True

    @staticmethod
    def _grant_transition_is_valid(
        current: dict[str, Any], candidate: dict[str, Any]
    ) -> bool:
        """Enforce the capture grant state machine across journal snapshots."""
        if current["bound"] and not candidate["bound"]:
            return False
        if current["consumed"] and not candidate["consumed"]:
            return False
        if current["revoked"] and not candidate["revoked"]:
            return False
        if current.get("transaction") is not None \
                and candidate.get("transaction") != current.get("transaction"):
            return False
        return True

    def _index_artifact_locked(self, artifact: dict[str, Any]) -> None:
        key = (
            str(artifact.get("session_id") or ""),
            str(artifact.get("transaction") or ""),
            str(artifact.get("kind") or ""),
            str(artifact.get("sha256") or ""),
        )
        if all(key):
            self.artifact_keys[key] = artifact

    def _sanitize_artifact_record(self, artifact: dict[str, Any]) -> dict[str, Any]:
        safe = {
            key: artifact[key] for key in (
                "artifact_id", "session_id", "filename", "kind", "size",
                "sha256", "stored_path", "received_at", "grant_id",
                "transaction", "metadata",
            ) if key in artifact
        }
        kind = safe_component(_keep_enum(safe.get("kind"), 0), "artifact")
        safe["kind"] = kind
        safe["artifact_id"] = safe_relational_component(
            safe.get("artifact_id"), "unknown-artifact"
        )
        safe["session_id"] = safe_relational_component(
            safe.get("session_id"), "unknown-session"
        )
        safe["filename"] = safe_artifact_filename(safe.get("filename"), kind)
        if isinstance(safe.get("transaction"), str):
            safe["transaction"] = redact_relational_text(safe["transaction"])
        if isinstance(safe.get("grant_id"), str):
            safe["grant_id"] = safe_relational_component(safe["grant_id"], "")
        if isinstance(safe.get("received_at"), str):
            safe["received_at"] = redact_text(safe["received_at"])[:MAX_STRUCTURAL_LEN]
        safe["metadata"] = redact_value(safe.get("metadata", {}))
        paths = self._artifact_storage_paths(artifact)
        if paths is not None:
            final, _ = paths
            try:
                safe["stored_path"] = final.resolve(strict=False).relative_to(
                    self.data_dir.resolve(strict=False)
                ).as_posix()
            except (OSError, ValueError):
                safe.pop("stored_path", None)
        return safe

    def _apply_config_snapshot_locked(self, config: dict[str, Any]) -> None:
        """Adopt a config snapshot only if it does not move revision backwards."""
        safe = self._sanitize_config_snapshot(config)
        if self._is_int(safe.get("revision")) and safe["revision"] >= self.config["revision"]:
            for field in ("mode", "capture_next", "revision", "updated_at"):
                if field in safe:
                    self.config[field] = safe[field]

    def _apply_record(self, record: dict[str, Any]) -> None:
        """Deterministically mutate memory from ONE record. Pure w.r.t. the
        journal (never writes), so it is safe to call from both the live commit
        path (after a successful append) and replay."""
        record_type = record["record_type"]
        stream_id = record.get("stream_id")

        if record_type == "hello":
            session = redact_value(dict(record["session"]))
            session["session_id"] = safe_relational_component(
                record["session"].get("session_id"), "unknown-session"
            )
            self.sessions[session["session_id"]] = session
            safe_record = {"record_type": "hello", "session": session}
            self._bump_stream_locked(stream_id, "session", safe_record)

        elif record_type == "event":
            # Pre-P1 journals can contain multiple process epochs whose ids
            # restart at 1 and have no durable stream cursor. Count those lines
            # as compatible replay input, but never re-apply a stale id.
            if record["id"] <= self.event_id:
                return
            raw_payload = record.get("payload") if isinstance(record.get("payload"), dict) else {}
            safe_payload, _ = sanitize_event_payload(raw_payload)
            received_at = redact_text(record.get("received_at", ""))[:MAX_STRUCTURAL_LEN]
            event = {
                "id": record["id"],
                "session_id": safe_relational_component(
                    record.get("session_id"), "unknown-session"
                ),
                "type": str(_keep_enum(record.get("type"), 0) or "log")[:80],
                "level": str(_keep_enum(record.get("level"), 0) or "info")[:20],
                "stage": _keep_enum(record.get("stage"), 0),
                "message": redact_value(record.get("message")),
                "timestamp": _keep_enum(record.get("timestamp"), 0),
                "received_at": received_at,
                "dedup_fingerprint": payload_fingerprint(safe_payload),
                "payload": safe_payload,
            }
            self._index_event_locked(event)
            sid = event["session_id"]
            if sid in self.sessions and isinstance(event.get("received_at"), str):
                self.sessions[sid]["last_seen"] = event["received_at"]
            self._bump_stream_locked(stream_id, "event", event)

        elif record_type == "event_batch":
            for event_record in record["events"]:
                self._apply_record(event_record)

        elif record_type == "command_batch":
            targeted_disarms: list[dict[str, Any]] = []
            for command in record["commands"]:
                if isinstance(command, dict):
                    safe_command = self._sanitize_command(command)
                    self.commands.append(safe_command)
                    if self._apply_pending_disarm_locked(safe_command):
                        targeted_disarms.append(safe_command)
            for grant in record.get("grants", []):
                self._apply_grant_snapshot_locked(grant)
            safe_config = self._sanitize_config_snapshot(record["config"])
            if targeted_disarms:
                aggregate_capture = self._has_live_pending_capture_locked()
                for command in targeted_disarms:
                    command["capture_next"] = aggregate_capture
                safe_config["capture_next"] = aggregate_capture
            self._apply_config_snapshot_locked(safe_config)
            self._bump_stream_locked(stream_id, "command", safe_config)

        elif record_type == "command":  # legacy single-command line
            command = self._sanitize_command(record)
            revision = command["revision"]
            # Pre-P1 processes reset revisions on restart and did not persist a
            # stream id. Rebase each stale legacy epoch deterministically in
            # memory so chronological commands remain deliverable as one
            # monotonic sequence while the source NDJSON stays byte-for-byte.
            if stream_id is None and revision <= self.config["revision"]:
                revision = self.config["revision"] + 1
                command["id"] = revision
                command["revision"] = revision
            self.commands.append(command)
            self._apply_pending_disarm_locked(command)
            self.config["revision"] = revision
            if isinstance(command.get("mode"), str):
                self.config["mode"] = command["mode"]
            if isinstance(command.get("capture_next"), bool):
                self.config["capture_next"] = command["capture_next"]
            if isinstance(command.get("created_at"), str):
                self.config["updated_at"] = command["created_at"]
            self._bump_stream_locked(stream_id, "command", command)

        elif record_type == "command_ack":
            sid = safe_relational_component(record["session_id"], "unknown-session")
            ids = {i for i in record["acknowledged"] if self._is_int(i)}
            self.command_acks.setdefault(sid, set()).update(ids)
            if sid in self.sessions and isinstance(record.get("received_at"), str):
                self.sessions[sid]["last_seen"] = redact_text(record["received_at"])
            data = {
                "record_type": "command_ack", "session_id": sid,
                "acknowledged": sorted(ids),
            }
            if isinstance(record.get("received_at"), str):
                data["received_at"] = redact_text(record["received_at"])[:MAX_STRUCTURAL_LEN]
            self._bump_stream_locked(stream_id, "command_ack", data)

        elif record_type == "artifact":
            artifact = record.get("artifact")
            if isinstance(artifact, dict):  # new bundled form
                artifact = self._sanitize_artifact_record(artifact)
                for snap in record.get("expiry_snapshots", []):
                    self._apply_grant_snapshot_locked(snap)
                self._apply_grant_snapshot_locked(record.get("grant"))
                self._index_artifact_locked(artifact)
                self._bump_stream_locked(stream_id, "artifact", artifact)
                reset_command = record.get("reset_command")
                if isinstance(reset_command, dict):
                    safe_reset_command = self._sanitize_command(reset_command)
                    self.commands.append(safe_reset_command)
                    targeted_disarm = self._apply_pending_disarm_locked(safe_reset_command)
                    if isinstance(record.get("reset_config"), dict):
                        safe_reset = self._sanitize_config_snapshot(record["reset_config"])
                        if targeted_disarm:
                            aggregate_capture = self._has_live_pending_capture_locked()
                            safe_reset_command["capture_next"] = aggregate_capture
                            safe_reset["capture_next"] = aggregate_capture
                        self._apply_config_snapshot_locked(safe_reset)
                    else:
                        safe_reset = self._sanitize_command(reset_command)
                    self._bump_stream_locked(
                        record.get("reset_stream_id"), "command", safe_reset,
                    )
                sid = artifact.get("session_id")
                if sid in self.sessions and isinstance(record.get("received_at"), str):
                    self.sessions[sid]["last_seen"] = redact_text(
                        record["received_at"]
                    )[:MAX_STRUCTURAL_LEN]
            else:  # legacy top-level artifact
                legacy = self._sanitize_artifact_record(record)
                legacy["record_type"] = "artifact"
                self._bump_stream_locked(stream_id, "artifact", legacy)

        elif record_type == "session_touch":
            sid = safe_relational_component(record["session_id"], "unknown-session")
            if sid in self.sessions:
                self.sessions[sid]["last_seen"] = redact_text(
                    record["last_seen"]
                )[:MAX_STRUCTURAL_LEN]

        elif record_type == "capture_grant":  # legacy standalone snapshot
            self._apply_grant_snapshot_locked(record["grant"])

    def _index_event_locked(self, event: dict[str, Any]) -> None:
        """Append an event to the display ring and index it for de-duplication.

        The dedup cache stores only (id, fingerprint) and is capped at
        self.max_dedup_keys, independent of the display ring; on a cache miss a
        journal scan still finds an old committed seq (permanent dedup)."""
        self.events.append(event)
        if self._is_int(event.get("id")) and event["id"] > self.event_id:
            self.event_id = event["id"]
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        key = self._dedup_key_safe(event.get("session_id", ""), payload.get("seq"))
        if key is not None:
            self.event_keys[key] = {
                "id": event["id"],
                "fingerprint": payload_fingerprint(payload),
            }
            self.event_keys.move_to_end(key)
            while len(self.event_keys) > self.max_dedup_keys:
                self.event_keys.popitem(last=False)

    def _lookup_committed_event_locked(self, key: tuple[str, int]) -> dict[str, Any] | None:
        """Journal-backed dedup lookup for a (session, seq) not in the hot cache.

        The scan uses the SAME schema and cross-record ordering rules as startup
        replay. A stale line rejected during replay can therefore never become a
        later false duplicate/conflict after the hot cache evicts its key."""
        session_id, seq = key
        try:
            journal_exists = path_exists_strict(self.journal_path)
        except OSError:
            self._journal_poisoned = True
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "event dedup journal is unavailable; retry",
            )
        if not journal_exists:
            return None
        try:
            handle = self.journal_path.open("rb")
        except OSError:
            self._journal_poisoned = True
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "event dedup journal is unavailable; retry",
            )

        # Lightweight replay state: no constructor/reconcile and no writes. It
        # exists only to evaluate each line against the exact evolving cursor,
        # revision, grant, and artifact state used by startup replay.
        shadow = BackendState.__new__(BackendState)
        shadow.data_dir = self.data_dir
        shadow.artifact_dir = self.artifact_dir
        # Validators must see the same capture policy as startup replay. A
        # grant-bearing command/artifact otherwise raises AttributeError inside
        # the defensive validation block, is silently skipped by the shadow,
        # and can make a later stale event look committed only to dedup.
        shadow.max_artifact_bytes = self.max_artifact_bytes
        shadow.capture_grant_ttl = self.capture_grant_ttl
        shadow.capture_grant_max_files = self.capture_grant_max_files
        shadow.capture_grant_max_bytes = self.capture_grant_max_bytes
        shadow.capture_allowed_kinds = self.capture_allowed_kinds
        shadow.max_dedup_keys = 1
        shadow._journal_poisoned = False
        shadow._reset_state_locked()
        found: dict[str, Any] | None = None
        try:
            with handle:
                for raw_line in handle:
                    raw_line = raw_line.strip()
                    if not raw_line:
                        continue
                    try:
                        record = json.loads(raw_line.decode("utf-8"))
                        if not isinstance(record, dict):
                            raise ValueError("record is not an object")
                    except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                        continue
                    try:
                        valid = shadow._record_is_valid(record)
                        ordered = valid and shadow._record_order_is_valid(record)
                    except Exception:
                        valid = ordered = False
                    if shadow._journal_poisoned:
                        self._journal_poisoned = True
                        raise ApiError(
                            HTTPStatus.SERVICE_UNAVAILABLE,
                            "event dedup persistence state is unavailable; retry",
                        )
                    if not valid or not ordered:
                        continue

                    candidates: list[dict[str, Any]] = []
                    if record.get("record_type") == "event":
                        # A no-stream legacy epoch can be replay-compatible but
                        # intentionally no-op when its id is stale.
                        if record["id"] > shadow.event_id:
                            candidates = [record]
                    elif record.get("record_type") == "event_batch":
                        candidates = record["events"]

                    matched: dict[str, Any] | None = None
                    for candidate in candidates:
                        candidate_session = safe_relational_component(
                            candidate.get("session_id"), "unknown-session"
                        )
                        if candidate_session != session_id:
                            continue
                        raw_payload = candidate.get("payload") \
                            if isinstance(candidate.get("payload"), dict) else {}
                        try:
                            payload, canonical_seq = sanitize_event_payload(raw_payload)
                        except SeqRangeError:
                            continue
                        if ((candidate_session, canonical_seq) == (session_id, seq)
                                and self._is_int(candidate.get("id"))):
                            matched = {
                                "id": candidate["id"],
                                "fingerprint": payload_fingerprint(payload),
                            }
                    try:
                        shadow._apply_record(record)
                    except Exception:
                        continue
                    if shadow._journal_poisoned:
                        self._journal_poisoned = True
                        raise ApiError(
                            HTTPStatus.SERVICE_UNAVAILABLE,
                            "event dedup persistence state is unavailable; retry",
                        )
                    if matched is not None:
                        found = matched
        except OSError:
            self._journal_poisoned = True
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "event dedup journal is unavailable; retry",
            )
        return found

    @staticmethod
    def _dedup_key_safe(session_id: str, seq: Any) -> tuple[str, int] | None:
        """event_dedup_key but never raises — for scanning already-committed
        records (replay/lookup), where a stray out-of-range seq must be ignored,
        not crash the scan."""
        try:
            return event_dedup_key(session_id, seq)
        except SeqRangeError:
            return None

    # -- Journal-first atomic commit (ONE line per logical operation) --------

    def _append_journal_line(self, record: dict[str, Any]) -> None:
        """Durably append one record (fsync). Raises JournalWriteError on any
        failure so the caller returns a retryable error with NO memory change.

        A pre-existing non-newline tail is first isolated with a newline, so a
        prior crash fragment cannot consume this valid record. If write/fsync
        fails, the file is truncated and fsync'd back to its original length.
        When that rollback cannot be confirmed, later writes are blocked until
        restart because the commit outcome is genuinely unknown.
        """
        try:
            line = json.dumps(
                record, ensure_ascii=False, allow_nan=False, separators=(",", ":")
            )
            record_payload = (line + "\n").encode("utf-8")
        except (TypeError, ValueError, UnicodeError) as exc:
            raise JournalWriteError(f"record is not serializable: {exc}") from exc
        with self.journal_lock:
            if self._journal_poisoned:
                raise JournalWriteError("journal requires restart after an uncertain append")

            handle = None
            start_size: int | None = None
            write_started = False
            try:
                # Unbuffered I/O makes the exact bytes covered by fsync and by a
                # rollback explicit; close cannot hide a second buffered flush.
                handle = self.journal_path.open("a+b", buffering=0)
                handle.seek(0, os.SEEK_END)
                start_size = handle.tell()
                prefix = b""
                if start_size:
                    handle.seek(-1, os.SEEK_END)
                    if handle.read(1) != b"\n":
                        prefix = b"\n"
                payload = prefix + record_payload
                handle.seek(0, os.SEEK_END)
                write_started = True
                offset = 0
                while offset < len(payload):
                    count = handle.write(payload[offset:])
                    if not isinstance(count, int) or count <= 0:
                        raise OSError("journal append made no progress")
                    offset += count
                os.fsync(handle.fileno())
            except OSError as exc:
                rolled_back = not write_started
                if write_started and start_size is not None:
                    try:
                        if handle is None or handle.closed:
                            handle = self.journal_path.open("r+b", buffering=0)
                        handle.truncate(start_size)
                        os.fsync(handle.fileno())
                        rolled_back = os.fstat(handle.fileno()).st_size == start_size
                    except OSError:
                        rolled_back = False
                uncertain = not rolled_back
                if uncertain:
                    self._journal_poisoned = True
                raise JournalWriteError(str(exc), commit_uncertain=uncertain) from exc
            finally:
                if handle is not None and not handle.closed:
                    try:
                        handle.close()
                    except OSError:
                        # With unbuffered I/O, a completed fsync is the commit
                        # or rollback point. A close-only error cannot change
                        # the already-fsync'd file length/content.
                        pass

    def _commit_locked(self, record: dict[str, Any]) -> None:
        """Atomically persist and apply ONE logical operation. The record must
        carry every id/revision/cursor baked in, so apply is deterministic. The
        journal write happens FIRST; apply runs only on success, so a failed
        write leaves memory byte-for-byte unchanged (all-or-nothing)."""
        self._append_journal_line(record)  # may raise JournalWriteError
        self._apply_record(record)
        self.condition.notify_all()

    def _next_stream_id_locked(self) -> int:
        if self.stream_id >= MAX_SEQ:
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "stream cursor space is exhausted",
            )
        return self.stream_id + 1

    def hello(self, payload: dict[str, Any]) -> dict[str, Any]:
        now = utc_now()
        # session id is resolved from the RAW payload (structural key), but every
        # descriptive client field is recursively sanitized BEFORE it is read
        # into the session, so a Bearer token or local path in app_version /
        # device_model / plugin_* never reaches session, journal, or SSE.
        session_value = payload.get("session_id") or payload.get("session")
        if isinstance(session_value, dict):
            session_value = session_value.get("id") or session_value.get("session_id")
        session_id = safe_relational_component(session_value, uuid.uuid4().hex)
        clean = redact_value(payload) if isinstance(payload, dict) else {}
        device = clean.get("device") if isinstance(clean.get("device"), dict) else {}
        app = clean.get("app") if isinstance(clean.get("app"), dict) else {}
        plugin = clean.get("plugin") if isinstance(clean.get("plugin"), dict) else {}
        # device.id is the identifierForVendor (IFV); redact_value already hashed
        # it (device_id/id keys are identifier-classified), so read the hash.
        raw_device_id = clean.get("device_id") or device.get("id")
        device_id = raw_device_id if (isinstance(raw_device_id, str) and raw_device_id.startswith("ifv:")) \
            else (hash_identifier(raw_device_id) if raw_device_id else "unknown-device")

        def clean_field(*values: Any) -> Any:
            for value in values:
                if value not in (None, ""):
                    return value
            return None

        with self.lock:
            self._require_persistence_ready_locked()
            self._expire_capture_state_locked(time.time())
            previous = self.sessions.get(session_id, {})
            session = {
                "session_id": session_id,
                "device_id": device_id,
                "connected_at": previous.get("connected_at", now),
                "last_seen": now,
                "app_version": clean_field(clean.get("app_version"), app.get("version")),
                "build": clean_field(clean.get("build"), app.get("build")),
                "os_version": clean_field(clean.get("os_version"), device.get("os_version")),
                "device_model": clean_field(clean.get("device_model"), device.get("model")),
                "plugin_version": clean_field(clean.get("plugin_version"), plugin.get("version")),
                "plugin_variant": clean_field(clean.get("plugin_variant"), plugin.get("variant")),
                "plugin_build_id": clean_field(clean.get("plugin_build_id"), plugin.get("build_id")),
                "protocol_version": clean.get("protocol_version"),
            }
            # ONE self-contained record; commit is all-or-nothing. On a journal
            # failure the ApiError(503) leaves sessions/cursor untouched.
            record = {
                "record_type": "hello",
                "received_at": now,
                "session": session,
                "stream_id": self._next_stream_id_locked(),
                "topic": "session",
            }
            try:
                self._commit_locked(record)
            except JournalWriteError:
                raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE, "hello could not be persisted; retry")
            self._last_touch_persist[session_id] = time.monotonic()
            return {
                "session_id": session_id,
                "protocol_version": PROTOCOL_VERSION,
                "config": dict(self.config),
                "server_time": now,
            }

    def _touch_session_locked(self, session_id: str) -> None:
        """Update last_seen. For most operations this is folded into that
        operation's own record (event.received_at, ack.received_at, ...), so it
        only touches memory here. For command polls — which have no other
        record — it persists a rate-limited session_touch so poll activity
        survives a restart. A failed heartbeat is swallowed; it must never fail
        the primary operation."""
        if not session_id or session_id not in self.sessions:
            return
        self.sessions[session_id]["last_seen"] = utc_now()

    def _persist_poll_touch_locked(self, session_id: str) -> None:
        if not session_id or session_id not in self.sessions:
            return
        clock = time.monotonic()
        if clock - self._last_touch_persist.get(session_id, 0.0) < SESSION_TOUCH_PERSIST_SECONDS:
            self.sessions[session_id]["last_seen"] = utc_now()
            return
        now = utc_now()
        record = {"record_type": "session_touch", "session_id": session_id, "last_seen": now}
        try:
            self._commit_locked(record)
            self._last_touch_persist[session_id] = clock
        except JournalWriteError:
            self.sessions[session_id]["last_seen"] = now  # memory-only fallback
            # A rollback-confirmed append failure leaves the in-memory state
            # readable; an uncertain append poisons persistence and must make
            # this poll fail closed instead of returning a default/stale view.
            self._require_persistence_ready_locked()

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

        # Validate the whole batch up front so a bad element rejects the batch
        # before any partial write. A present-but-out-of-range seq (overlong /
        # negative / > uint64) is a clean 400, never an uncaught 500.
        for raw in raw_events:
            if not isinstance(raw, dict):
                raise ApiError(HTTPStatus.BAD_REQUEST, "every event must be an object")
            try:
                normalized_seq(raw.get("seq"))
            except SeqRangeError as exc:
                raise ApiError(HTTPStatus.BAD_REQUEST, f"invalid seq: {exc}")

        with self.lock:
            self._require_persistence_ready_locked()
            # PHASE 1 — classify every event with ZERO writes. Each is a
            # duplicate (same (session,seq) + fingerprint), a conflict (same
            # key, different fingerprint), or new. A conflict ANYWHERE in the
            # batch aborts the whole batch with 409 before a single event is
            # committed, so a mid-batch conflict never leaves a half-written
            # batch. In-batch duplicate keys are resolved against each other too.
            plans: list[dict[str, Any]] = []
            seen_in_batch: dict[tuple[str, int], str] = {}
            for raw in raw_events:
                session_id = safe_relational_component(
                    raw.get("session_id") or raw.get("session") or default_session, "unknown-session"
                )
                # Dedup cannot depend on hostile JSON key order. The helper
                # forces canonical seq into the retained 256-key payload.
                safe_payload, canonical_seq = sanitize_event_payload(raw)
                fingerprint = payload_fingerprint(safe_payload)
                dedup_key = ((session_id, canonical_seq)
                             if canonical_seq is not None else None)

                prior = None
                if dedup_key is not None:
                    prior = self.event_keys.get(dedup_key)
                    if prior is None:
                        prior = self._lookup_committed_event_locked(dedup_key)
                        self._require_persistence_ready_locked()
                    # An earlier event in THIS batch with the same key also counts.
                    if prior is None and dedup_key in seen_in_batch:
                        prior = {"id": None, "fingerprint": seen_in_batch[dedup_key],
                                 "in_batch": True}
                if prior is not None:
                    if prior.get("fingerprint") != fingerprint:
                        # Deterministic conflict: reject the entire batch, no writes.
                        self.dedup_conflicts += 1
                        raise ApiError(
                            HTTPStatus.CONFLICT,
                            "duplicate (session, seq) with a different payload",
                        )
                    plans.append({"duplicate": True, "session_id": session_id,
                                  "prior": prior, "key": dedup_key})
                    continue

                if dedup_key is not None:
                    seen_in_batch[dedup_key] = fingerprint
                plans.append({
                    "duplicate": False, "session_id": session_id, "key": dedup_key,
                    "safe_payload": safe_payload, "fingerprint": fingerprint,
                })

            # PHASE 2: plan every new event, then commit them in one journal
            # append. A disk failure cannot leave a partially accepted batch.
            # Single-event requests retain the legacy event record format.
            new_count = sum(not plan["duplicate"] for plan in plans)
            if (self.event_id > MAX_SEQ - new_count
                    or self.stream_id > MAX_SEQ - new_count):
                raise ApiError(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    "event id or stream cursor space is exhausted",
                )
            accepted: list[dict[str, Any]] = [None] * len(plans)  # type: ignore[list-item]
            batch_ids: dict[tuple[str, int], int] = {}
            deferred_dupes: list[int] = []
            duplicate_sessions: set[str] = set()
            new_records: list[dict[str, Any]] = []
            next_event_id = self.event_id
            next_stream_id = self.stream_id
            for index, plan in enumerate(plans):
                session_id = plan["session_id"]
                if plan["duplicate"]:
                    duplicate_sessions.add(session_id)
                    prior = plan["prior"]
                    if prior.get("id") is not None:
                        accepted[index] = {"id": prior["id"], "session_id": session_id,
                                           "duplicate": True}
                    else:
                        deferred_dupes.append(index)  # in-batch dup: resolve after phase 2
                    continue

                safe_payload = plan["safe_payload"]
                received_at = utc_now()
                fields = safe_payload.get("fields") if isinstance(safe_payload.get("fields"), dict) else {}
                next_event_id += 1
                next_stream_id += 1
                event = {
                    "id": next_event_id,
                    "session_id": session_id,
                    "type": str(safe_payload.get("type") or safe_payload.get("kind") or "log")[:80],
                    "level": str(safe_payload.get("level") or fields.get("level") or "info")[:20],
                    "stage": safe_payload.get("stage") or fields.get("stage"),
                    "message": safe_payload.get("message") or fields.get("message") or fields.get("detail"),
                    "timestamp": safe_event_timestamp(safe_payload, received_at),
                    "received_at": received_at,
                    "dedup_fingerprint": plan["fingerprint"],
                    "payload": safe_payload,
                }
                record = {"record_type": "event", **event,
                          "stream_id": next_stream_id, "topic": "event"}
                new_records.append(record)
                if plan.get("key") is not None:
                    batch_ids[plan["key"]] = event["id"]
                accepted[index] = event

            if new_records:
                record = new_records[0] if len(new_records) == 1 else {
                    "record_type": "event_batch",
                    "events": new_records,
                }
                try:
                    self._commit_locked(record)
                except JournalWriteError:
                    raise ApiError(
                        HTTPStatus.SERVICE_UNAVAILABLE,
                        "event batch could not be persisted; retry",
                    )

            for session_id in duplicate_sessions:
                self._touch_session_locked(session_id)

            # Resolve in-batch duplicates to the id committed for their exact
            # (session, seq) key earlier in this same batch.
            for index in deferred_dupes:
                plan = plans[index]
                accepted[index] = {
                    "id": batch_ids.get(plan["key"]),
                    "session_id": plan["session_id"],
                    "duplicate": True,
                }
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
            self._require_persistence_ready_locked()
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
            self._require_persistence_ready_locked()
            sessions = sorted(self.sessions.values(), key=lambda item: item["last_seen"], reverse=True)
            return {"sessions": [dict(item) for item in sessions], "server_time": utc_now()}

    def _build_command(
        self, revision: int, command_type: str, fields: dict[str, Any],
        source: str, created_at: str, mode: str, capture_next: bool,
        target_session: str = "",
    ) -> dict[str, Any]:
        # target_session == "" means broadcast (all devices). A non-empty value
        # means only that session should receive it; other pollers skip it but
        # still advance their cursor past it (see get_commands).
        return {
            "record_type": "command",
            "id": revision,
            "revision": revision,
            "type": command_type,
            **fields,
            "mode": mode,
            "capture_next": capture_next,
            "source": redact_text(str(source))[:MAX_ENUM_LEN],
            "created_at": created_at,
            "target_session": target_session,
        }

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

        requested_session = payload.get("session_id") or payload.get("session")
        requested_session = safe_relational_component(requested_session, "") if requested_session else ""

        with self.lock:
            now = utc_now()
            # Resolve the capture target BEFORE building anything so a missing /
            # ambiguous device is a clean 400 with zero side effects.
            grant_session = ""
            if capture_present and requested_capture:
                grant_session = self._resolve_capture_session_locked(requested_session)

            # Build the ENTIRE transaction in local variables — no self.* writes
            # yet. mode, capture_next, revision, the command list, and any grant
            # snapshots are assembled, then committed as ONE record. A journal
            # failure therefore leaves mode/capture/revision/commands/grants all
            # exactly as they were (no partial application).
            revision = self.config["revision"]
            next_mode = self.config["mode"]
            next_capture = self.config["capture_next"]
            commands: list[dict[str, Any]] = []
            grant_snapshots: list[dict[str, Any]] = []
            revision_count = int(requested_mode is not None) + int(capture_present) \
                + int(command_type == "flush")
            if revision > MAX_SEQ - revision_count:
                raise ApiError(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    "command revision space is exhausted",
                )

            if requested_mode is not None:
                next_mode = requested_mode
                revision += 1
                commands.append(self._build_command(
                    revision, "set_mode", {"mode": requested_mode}, source, now, next_mode, next_capture))
            if capture_present:
                if requested_capture:
                    grant_snapshots.extend(self._plan_arm_grant_locked(now, grant_session))
                else:
                    grant_snapshots.extend(self._plan_revoke_all_locked())
                next_capture = requested_capture
                revision += 1
                fields = {"enabled": requested_capture}
                if requested_capture:
                    fields["session_id"] = grant_session
                # An ARM is targeted at the bound device; a disarm broadcasts so
                # every device drops any pending capture.
                target = grant_session if requested_capture else ""
                commands.append(self._build_command(
                    revision, "capture_next", fields, source, now, next_mode, next_capture,
                    target_session=target))
            if command_type == "flush":
                revision += 1
                commands.append(self._build_command(
                    revision, "flush", {}, source, now, next_mode, next_capture))

            config_snapshot = {
                "mode": next_mode,
                "capture_next": next_capture,
                "revision": revision,
                "updated_at": now,
            }
            record = {
                "record_type": "command_batch",
                "commands": commands,
                "grants": grant_snapshots,
                "config": config_snapshot,
                "stream_id": self._next_stream_id_locked(),
                "topic": "command",
            }
            try:
                self._commit_locked(record)
            except JournalWriteError:
                raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE, "command could not be persisted; retry")
            return {**self.config, "commands": [dict(item) for item in commands]}

    # -- Capture authorization grants ---------------------------------------

    def _parse_iso(self, value: Any) -> float:
        if not isinstance(value, str):
            return 0.0
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except (ValueError, OverflowError):
            return 0.0

    def _resolve_capture_session_locked(self, requested_session: str) -> str:
        """Pick the device a capture grant binds to. An explicit, known session
        wins. Otherwise there must be exactly one recently-active device, else a
        clear 400 — capture must never arm against an ambiguous target."""
        if requested_session:
            if requested_session not in self.sessions:
                raise ApiError(HTTPStatus.BAD_REQUEST, "capture session_id is not a known device")
            return requested_session
        cutoff = time.time() - ACTIVE_SESSION_WINDOW_SECONDS
        active = [
            sid for sid, session in self.sessions.items()
            if self._parse_iso(session.get("last_seen")) >= cutoff
        ]
        if len(active) == 1:
            return active[0]
        if not active:
            raise ApiError(HTTPStatus.BAD_REQUEST, "no active device to capture; specify session_id")
        raise ApiError(
            HTTPStatus.BAD_REQUEST,
            "multiple active devices; specify session_id for capture",
        )

    # Grant helpers are PLANNERS: they return grant snapshots to be committed
    # by the caller's single record. They never mutate self.capture_grants
    # directly (that happens in _apply_record after a durable write), and they
    # copy-before-modify so an abort leaves the live grant untouched.

    def _plan_revoke_pending_for_session_locked(self, session_id: str) -> list[dict[str, Any]]:
        snapshots = []
        for grant in self.capture_grants.values():
            if not grant["revoked"] and not grant["bound"] and grant["session_id"] == session_id:
                revoked = dict(grant)
                revoked["revoked"] = True
                snapshots.append(revoked)
        return snapshots

    def _plan_arm_grant_locked(self, created_at: str, session_id: str) -> list[dict[str, Any]]:
        # A fresh arming supersedes any earlier pending grant for this device.
        snapshots = self._plan_revoke_pending_for_session_locked(session_id)
        snapshots.append({
            "grant_id": uuid.uuid4().hex,
            "armed_at": created_at,
            "expires_at": time.time() + self.capture_grant_ttl,
            "session_id": session_id,
            "transaction": None,
            "bound": False,
            "consumed": False,
            "revoked": False,
            "files": 0,
            "bytes": 0,
            "max_files": self.capture_grant_max_files,
            "max_bytes": self.capture_grant_max_bytes,
            "allowed_kinds": sorted(self.capture_allowed_kinds),
        })
        return snapshots

    def _plan_revoke_all_locked(self) -> list[dict[str, Any]]:
        snapshots = []
        for grant in self.capture_grants.values():
            if not grant["revoked"]:
                revoked = dict(grant)
                revoked["revoked"] = True
                snapshots.append(revoked)
        return snapshots

    def _plan_expire_grants_locked(self, now_epoch: float) -> list[dict[str, Any]]:
        snapshots = []
        for grant in self.capture_grants.values():
            if not grant["revoked"] and grant.get("expires_at", 0) <= now_epoch:
                expired = dict(grant)
                expired["revoked"] = True
                snapshots.append(expired)
        return snapshots

    def _expire_capture_state_locked(self, now_epoch: float) -> None:
        """Durably disarm sessions whose pending capture grants have expired.

        Expiry is evaluated lazily by normal device/backend traffic. The grant
        revocations, command(s), config snapshot, and stream cursor are committed
        as one command_batch, so a failed append cannot leave an in-memory-only
        disarm. A live replacement grant for the same session suppresses the old
        grant's targeted disarm.
        """
        if self.config.get("capture_next") is not True:
            return

        pending = [
            grant for grant in self.capture_grants.values()
            if not grant["revoked"] and not grant["bound"] and not grant["consumed"]
        ]
        live_sessions = {
            grant["session_id"] for grant in pending
            if grant["expires_at"] > now_epoch
        }
        expired_sessions = {
            grant["session_id"] for grant in pending
            if grant["expires_at"] <= now_epoch
        } - live_sessions
        if not expired_sessions:
            return

        expiry_snapshots = self._plan_expire_grants_locked(now_epoch)
        next_capture = bool(live_sessions)
        targets = sorted(expired_sessions) if next_capture else [""]
        revision = self.config["revision"]
        if revision > MAX_SEQ - len(targets):
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "command revision space is exhausted",
            )
        if self.stream_id >= MAX_SEQ:
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "stream cursor space is exhausted",
            )

        now = utc_now()
        commands: list[dict[str, Any]] = []
        for target in targets:
            revision += 1
            fields: dict[str, Any] = {"enabled": False}
            if target:
                fields["session_id"] = target
            commands.append(self._build_command(
                revision,
                "capture_next",
                fields,
                "capture-grant-expiry",
                now,
                self.config["mode"],
                next_capture,
                target_session=target,
            ))

        record = {
            "record_type": "command_batch",
            "commands": commands,
            "grants": expiry_snapshots,
            "config": {
                "mode": self.config["mode"],
                "capture_next": next_capture,
                "revision": revision,
                "updated_at": now,
            },
            "stream_id": self._next_stream_id_locked(),
            "topic": "command",
        }
        try:
            self._commit_locked(record)
        except JournalWriteError:
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "capture grant expiry could not be persisted; retry",
            )

    def _authorize_capture_locked(
        self, session_id: str, transaction: str, kind: str, size: int, now_epoch: float
    ) -> dict[str, Any]:
        """Authorize one artifact upload against a live capture grant, or raise.

        - session_id and transaction must be non-empty (else 403; the handler
          rejects empties earlier as 400).
        - A grant already bound to this (session, transaction) admits further
          files of the SAME transaction (scene.xml + .amproj) until its file /
          byte / kind limits are hit.
        - Otherwise a pending grant for THIS session binds to this transaction.
        - Kind must be in the grant's allowed set; file count and total byte
          budget are enforced. Any violation raises 403 and stores nothing.
        Counters are only advanced after the caller commits, via
        _consume_grant_locked, so a rejected write leaves the grant unchanged.
        """
        if not session_id or not transaction:
            raise ApiError(HTTPStatus.FORBIDDEN, "artifact requires a session and transaction")
        expiry_snapshots = self._plan_expire_grants_locked(now_epoch)
        expired_ids = {snap["grant_id"] for snap in expiry_snapshots}

        def is_live(candidate: dict[str, Any]) -> bool:
            return not candidate["revoked"] and candidate["grant_id"] not in expired_ids

        grant = None
        for candidate in self.capture_grants.values():
            if (candidate["bound"] and is_live(candidate)
                    and candidate["session_id"] == session_id
                    and candidate["transaction"] == transaction):
                grant = candidate
                break
        if grant is None:
            for candidate in self.capture_grants.values():
                if (not candidate["bound"] and is_live(candidate)
                        and candidate["session_id"] == session_id):
                    grant = candidate
                    break
        if grant is None:
            raise ApiError(
                HTTPStatus.FORBIDDEN,
                "artifact upload is not authorized; arm capture_next first",
            )
        if kind not in grant["allowed_kinds"]:
            raise ApiError(HTTPStatus.FORBIDDEN, f"artifact kind '{kind}' is not permitted by the grant")
        if grant["files"] + 1 > grant["max_files"]:
            raise ApiError(HTTPStatus.FORBIDDEN, "capture grant file count exceeded")
        if grant["bytes"] + size > grant["max_bytes"]:
            raise ApiError(HTTPStatus.FORBIDDEN, "capture grant size budget exceeded")
        # Return the authorizing grant plus any expiry snapshots to be committed
        # atomically with the artifact. Nothing is mutated here.
        return {"grant": grant, "expiry_snapshots": expiry_snapshots}

    def _plan_consume_grant(self, grant: dict[str, Any], transaction: str, size: int) -> dict[str, Any]:
        """Return a consumed COPY of a grant (advanced counters). The live grant
        is untouched until the artifact record commits."""
        consumed = dict(grant)
        consumed["bound"] = True
        consumed["consumed"] = True
        consumed["transaction"] = transaction
        consumed["files"] = grant["files"] + 1
        consumed["bytes"] = grant["bytes"] + size
        return consumed

    def get_commands(self, after_revision: int = 0, session_id: str = "") -> dict[str, Any]:
        with self.lock:
            self._require_persistence_ready_locked()
            self._expire_capture_state_locked(time.time())
            # A poll is the only op with no other record, so persist a
            # rate-limited session_touch here to recover poll activity.
            self._persist_poll_touch_locked(session_id)
            # The touch itself can discover an uncertain journal append. Check
            # again before exposing the command/config snapshot.
            self._require_persistence_ready_locked()
            # Targeted delivery: a command with a non-empty target_session is
            # returned only to that device. Others SKIP it but still advance
            # next_cursor past it, so an unmatched poller never re-fetches a
            # command meant for someone else (no poll loop).
            # Filter AND cursor both key off "revision" — the same field — so
            # the cursor can never stall on an id/revision mismatch. The cursor
            # is the max revision in the pending window (delivered or skipped),
            # so it advances monotonically even when everything was targeted away.
            current_revision = self.config["revision"]
            # A cursor from a discarded/future journal cannot be allowed to
            # remain above the server forever. The config snapshot is the
            # authoritative recovery point; returning its current revision lets
            # the next poll resume normally.
            cursor_is_future = after_revision > current_revision
            pending = [] if cursor_is_future else [
                item for item in self.commands if item["revision"] > after_revision
            ]
            delivered = [
                dict(item) for item in pending
                if not item.get("target_session") or item.get("target_session") == session_id
            ]
            next_cursor = current_revision
            return {"config": dict(self.config), "commands": delivered, "next_cursor": next_cursor}

    def acknowledge_commands(self, payload: dict[str, Any]) -> dict[str, Any]:
        session_id = safe_relational_component(
            payload.get("session") or payload.get("session_id"), "unknown-session"
        )
        raw_ids = payload.get("acknowledged")
        if not isinstance(raw_ids, list) or len(raw_ids) > 1_000:
            raise ApiError(HTTPStatus.BAD_REQUEST, "acknowledged must be an array of command ids")
        acknowledged = []
        for raw_id in raw_ids:
            try:
                command_id = int(raw_id)
            except (TypeError, ValueError, OverflowError):
                raise ApiError(HTTPStatus.BAD_REQUEST, "acknowledged contains an invalid command id")
            if command_id < 0 or command_id > MAX_SEQ:
                raise ApiError(HTTPStatus.BAD_REQUEST, "command ids are out of range")
            acknowledged.append(command_id)
        acknowledged = sorted(set(acknowledged))
        with self.lock:
            record = {
                "record_type": "command_ack",
                "session_id": session_id,
                "acknowledged": acknowledged,
                "received_at": utc_now(),
                "stream_id": self._next_stream_id_locked(),
                "topic": "command_ack",
            }
            # ONE record, all-or-nothing. On failure the acks are not recorded.
            try:
                self._commit_locked(record)
            except JournalWriteError:
                raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE, "ack could not be persisted; retry")
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
        # Size is checked first so oversized uploads still fail with 413 (the
        # pre-P1 contract) before any authorization or write happens.
        if len(content) > self.max_artifact_bytes:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "artifact exceeds configured size limit")
        session_id = safe_relational_component(session_id, "")
        safe_metadata = redact_value(metadata) if isinstance(metadata, dict) else {}
        transaction = str(safe_metadata.get("transaction") or "")[:MAX_STRUCTURAL_LEN]
        if transaction:
            # One canonical value is used by metadata, authorization, the grant,
            # the idempotency key, and the journal.
            safe_metadata["transaction"] = transaction
        # A non-empty session and transaction are mandatory (400) — the grant
        # model binds on both, and an unattributed artifact is never stored.
        if not session_id:
            raise ApiError(HTTPStatus.BAD_REQUEST, "artifact requires a non-empty session")
        if not transaction:
            raise ApiError(HTTPStatus.BAD_REQUEST, "artifact requires a non-empty transaction")
        kind = safe_component(_keep_enum(kind, 0), "artifact")
        filename = safe_artifact_filename(filename, kind)
        size = len(content)
        sha256 = hashlib.sha256(content).hexdigest()
        now = utc_now()
        with self.lock:
            self._require_persistence_ready_locked()
            self._expire_capture_state_locked(time.time())
            # Idempotent artifact retry: the SAME (session, transaction, kind,
            # sha256) returns the original artifact record and writes no second
            # file or record.
            dedup_key = (session_id, transaction, kind, sha256)
            existing = self.artifact_keys.get(dedup_key)
            if existing is not None:
                paths = self._artifact_storage_paths(existing)
                if paths is None:
                    raise ApiError(
                        HTTPStatus.SERVICE_UNAVAILABLE,
                        "committed artifact storage is unavailable; retry after restart",
                    )
                final, temp = paths
                final_matches = self._artifact_file_matches(final, existing)
                self._require_persistence_ready_locked()
                if not final_matches:
                    # The client supplied the committed bytes again. Replace a
                    # missing/corrupt blob instead of returning false success.
                    temp_matches = self._artifact_file_matches(temp, existing)
                    self._require_persistence_ready_locked()
                    if not temp_matches:
                        self._safe_unlink(temp)
                        try:
                            self._atomic_write_bytes(temp, content)
                        except OSError:
                            self._safe_unlink(temp)
                            raise ApiError(
                                HTTPStatus.SERVICE_UNAVAILABLE,
                                "artifact repair failed; retry",
                            )
                    pending = self._promote_committed_artifact_locked(existing)
                    self._require_persistence_ready_locked()
                    repaired = self._artifact_file_matches(final, existing)
                    self._require_persistence_ready_locked()
                    if pending is not None or not repaired:
                        raise ApiError(
                            HTTPStatus.SERVICE_UNAVAILABLE,
                            "artifact repair failed; retry",
                        )
                else:
                    self._promote_committed_artifact_locked(existing)
                    self._require_persistence_ready_locked()
                self._touch_session_locked(session_id)
                return {**existing, "duplicate": True}

            # A transaction may contain one XML and one amproj, but never two
            # different blobs of the same kind. Exact-byte retries were handled
            # above; a different sha for the same slot is a deterministic 409.
            if any(key[:3] == dedup_key[:3] for key in self.artifact_keys):
                raise ApiError(
                    HTTPStatus.CONFLICT,
                    "artifact kind already committed with different content",
                )

            # Authorization gate: stored only when a live capture grant admits
            # this (session, transaction, kind, size). Raises 403/400 otherwise.
            authorization_time = time.time()
            auth = self._authorize_capture_locked(
                session_id, transaction, kind, size, authorization_time,
            )
            grant = auth["grant"]
            # Only the first file that BINDS the currently pending grant
            # consumes capture_next. A late second file from an older bound
            # transaction must not cancel a newly armed capture grant.
            should_reset_capture = not grant["bound"]
            expired_ids = {
                snapshot["grant_id"] for snapshot in auth["expiry_snapshots"]
            }
            remaining_pending = any(
                candidate["grant_id"] != grant["grant_id"]
                and candidate["grant_id"] not in expired_ids
                and not candidate["revoked"]
                and not candidate["bound"]
                and not candidate["consumed"]
                and candidate["expires_at"] > authorization_time
                for candidate in self.capture_grants.values()
            )
            next_capture = remaining_pending if should_reset_capture else self.config["capture_next"]
            if should_reset_capture and self.config["revision"] >= MAX_SEQ:
                raise ApiError(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    "command revision space is exhausted",
                )
            required_stream_ids = 2 if should_reset_capture else 1
            if self.stream_id > MAX_SEQ - required_stream_ids:
                raise ApiError(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    "stream cursor space is exhausted",
                )

            artifact_id = uuid.uuid4().hex
            session_dir = self.artifact_dir / session_id
            try:
                session_dir.mkdir(parents=True, exist_ok=True)
            except OSError:
                raise ApiError(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    "artifact storage is unavailable; retry",
                )
            stored_name = f"{int(time.time() * 1000)}_{artifact_id[:8]}_{filename}"
            destination = session_dir / stored_name

            artifact = {
                "artifact_id": artifact_id,
                "session_id": session_id,
                "filename": filename,
                "kind": kind,
                "size": size,
                "sha256": sha256,
                "stored_path": destination.relative_to(self.data_dir).as_posix(),
                "received_at": now,
                "grant_id": grant["grant_id"],
                "transaction": transaction,
                "metadata": safe_metadata,
            }
            # Bundle EVERYTHING this upload commits into one record: the artifact,
            # the consumed-grant snapshot, expiry snapshots, and — on the first
            # file under an armed grant — the capture_next reset command. One line
            # = one atomic commit.
            consumed = self._plan_consume_grant(grant, transaction, size)
            record: dict[str, Any] = {
                "record_type": "artifact",
                "artifact": artifact,
                "received_at": now,
                "grant": consumed,
                "expiry_snapshots": auth["expiry_snapshots"],
                "stream_id": self._next_stream_id_locked(),
                "topic": "artifact",
            }
            if should_reset_capture:
                reset_revision = self.config["revision"] + 1
                reset_target = session_id if next_capture else ""
                reset_fields: dict[str, Any] = {"enabled": False}
                if reset_target:
                    reset_fields["session_id"] = reset_target
                record["reset_command"] = self._build_command(
                    reset_revision, "capture_next", reset_fields,
                    "artifact-upload", now, self.config["mode"], next_capture,
                    target_session=reset_target,
                )
                record["reset_config"] = {
                    "mode": self.config["mode"], "capture_next": next_capture,
                    "revision": reset_revision, "updated_at": now,
                }
                record["reset_stream_id"] = record["stream_id"] + 1

            # Commit order for exactly-once, no-orphan semantics:
            #   1. write blob to a TEMP file (fsync'd, not yet visible),
            #   2. journal the record (fsync) — the durable source of truth,
            #   3. atomically rename temp -> final so the visible file appears
            #      only AFTER its record is durable,
            #   4. apply to memory.
            # A failure at (1) or (2) removes the temp and leaves no record and
            # no visible file. A crash between (2) and (3) leaves a committed
            # record whose file is missing a temp suffix — reconciled on restart
            # (see _reconcile_artifacts_locked): the record is authoritative.
            tmp_path = destination.with_name(destination.name + ".tmp-" + artifact_id[:8])
            try:
                self._atomic_write_bytes(tmp_path, content)
            except OSError:
                self._safe_unlink(tmp_path)
                raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE, "artifact write failed; retry")
            try:
                self._append_journal_line(record)  # durable commit point
            except JournalWriteError as exc:
                if not exc.commit_uncertain:
                    self._safe_unlink(tmp_path)
                raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE, "artifact could not be persisted; retry")
            try:
                os.replace(tmp_path, destination)  # atomic rename on same fs
            except OSError:
                # Record is already durable; the blob will be reconciled from the
                # temp on restart. Do not fail the request.
                pass
            self._apply_record(record)
            self.condition.notify_all()
        return artifact

    @staticmethod
    def _atomic_write_bytes(tmp_path: Path, content: bytes) -> None:
        """Write bytes to a temp file with flush + fsync so the data is durable
        before the caller renames it into place."""
        with tmp_path.open("wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())

    @staticmethod
    def _safe_unlink(path: Path) -> None:
        try:
            path.unlink()
        except OSError:
            pass

    def _artifact_file_matches(self, path: Path, artifact: dict[str, Any]) -> bool:
        expected_size = artifact.get("size")
        expected_sha = artifact.get("sha256")
        if not (isinstance(expected_size, int) and expected_size >= 0
                and isinstance(expected_sha, str)):
            return False
        try:
            file_stat = path.stat()
        except FileNotFoundError:
            return False
        except OSError:
            self._journal_poisoned = True
            return False
        if not stat_module.S_ISREG(file_stat.st_mode) or file_stat.st_size != expected_size:
            return False
        try:
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            return hmac.compare_digest(digest.hexdigest(), expected_sha)
        except FileNotFoundError:
            # A file can disappear between stat and open; treat it as missing so
            # an idempotent retry can reconstruct it from the supplied bytes.
            return False
        except OSError:
            # Permission/media errors are not evidence of a corrupt or absent
            # blob. Fail closed so no committed temp is deleted as an orphan.
            self._journal_poisoned = True
            return False

    def _artifact_storage_paths(self, artifact: dict[str, Any]) -> tuple[Path, Path] | None:
        stored = artifact.get("stored_path")
        artifact_id = artifact.get("artifact_id")
        if not (isinstance(stored, str) and stored and isinstance(artifact_id, str) and artifact_id):
            return None
        stored_path = Path(stored)
        final = stored_path if stored_path.is_absolute() else self.data_dir / stored_path
        if not final.name:
            return None
        try:
            final.resolve(strict=False).relative_to(self.artifact_dir.resolve(strict=False))
        except OSError:
            self._journal_poisoned = True
            return None
        except ValueError:
            return None
        temp = final.with_name(final.name + ".tmp-" + artifact_id[:8])
        return final, temp

    def _promote_committed_artifact_locked(self, artifact: dict[str, Any]) -> Path | None:
        """Promote a committed temp blob, returning it only when it must be kept."""
        paths = self._artifact_storage_paths(artifact)
        if paths is None:
            return None
        final, temp = paths
        final_matches = self._artifact_file_matches(final, artifact)
        if self._journal_poisoned:
            return temp
        if final_matches:
            self._safe_unlink(temp)
            return None
        temp_matches = self._artifact_file_matches(temp, artifact)
        if self._journal_poisoned:
            return temp
        if not temp_matches:
            self._safe_unlink(temp)
            return None
        try:
            os.replace(temp, final)
        except OSError:
            return temp
        return None

    def _reconcile_artifacts_locked(self) -> None:
        """After replay, ensure every committed artifact's blob is in place.

        If a crash happened after the journal commit but before the temp->final
        rename, the durable record points at a final path that does not yet
        exist while a matching .tmp-<id> sibling does. Promote it. Also sweep any
        orphan temp files with no committed record (writes that never committed)."""
        committed_temps: set[Path] = set()
        try:
            for artifact in self.artifact_keys.values():
                pending = self._promote_committed_artifact_locked(artifact)
                if self._journal_poisoned:
                    return
                if pending is not None:
                    committed_temps.add(pending.resolve(strict=False))

            # Resolve the complete candidate set before deleting anything. If
            # directory enumeration or path resolution fails midway, the
            # commit status of an unseen temp is unknown; preserve all temps and
            # poison persistence instead of doing a partial orphan sweep.
            if not path_exists_strict(self.artifact_dir):
                return
            temp_paths = list(self.artifact_dir.rglob("*.tmp-*"))
            resolved_temps = [
                (tmp, tmp.resolve(strict=False)) for tmp in temp_paths
            ]
        except OSError:
            self._journal_poisoned = True
            return

        # Sweep only uncommitted temps. A committed temp whose promotion still
        # fails must survive for a later retry or restart.
        for tmp, resolved in resolved_temps:
            if resolved not in committed_temps:
                self._safe_unlink(tmp)

    def stream_cursor_recoverable(self, after_stream_id: int) -> bool:
        """True if a client resuming at after_stream_id can be served without a
        gap. Reset is required when the cursor is either:
          - too OLD: older than the oldest buffered update (gap below), or
          - too NEW: greater than the current stream id (a future id that will
            never arrive — e.g. stale client after a journal was truncated),
        so the stream never blocks forever waiting for a nonexistent id."""
        with self.lock:
            if after_stream_id < 0:
                return False
            if after_stream_id > self.stream_id:
                return False  # future cursor: force reset instead of waiting
            if after_stream_id == 0:
                return True
            if not self.stream_updates:
                return after_stream_id >= self.stream_id
            oldest = self.stream_updates[0]["stream_id"]
            return after_stream_id >= oldest - 1

    def current_stream_id(self) -> int:
        with self.lock:
            return self.stream_id

    def _require_persistence_ready_locked(self) -> None:
        if self._journal_poisoned:
            raise ApiError(
                HTTPStatus.SERVICE_UNAVAILABLE,
                "persistence state is unavailable; retry after restart",
            )

    def require_persistence_ready(self) -> None:
        with self.lock:
            self._require_persistence_ready_locked()

    def persistence_ready(self) -> bool:
        with self.lock:
            return not self._journal_poisoned

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
        try:
            rendered = format_string % args
        except Exception:
            rendered = "request log formatting failed"
        sys.stderr.write(
            "[%s] %s %s\n" % (
                self.log_date_time_string(), self.client_address[0], redact_text(rendered)
            )
        )

    def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
        # Never log query strings or a malformed raw request line. Query values
        # and unread POST bodies are untrusted telemetry and may contain secrets.
        method = safe_component(getattr(self, "command", ""), "UNKNOWN")
        path = urlsplit(getattr(self, "path", "") or "").path
        known_paths = {
            "/", "/healthz", "/api/v1/hello", "/api/v1/events",
            "/api/v1/sessions", "/api/v1/commands", "/api/v1/artifacts",
            "/api/v1/stream",
        }
        if path.startswith("/static/"):
            path = "/static/*"
        elif path not in known_paths:
            path = "/<unknown>"
        self.log_message('"%s %s" %s %s', method, path, code, size)

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
                self._send_json(HTTPStatus.OK, {
                    "ok": True,
                    "protocol_version": PROTOCOL_VERSION,
                    "persistence_ready": self.debug_server.state.persistence_ready(),
                })
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
            self.close_connection = True
            self._send_json(exc.status, {"error": exc.message})
        except JournalWriteError as exc:
            # A durability failure that reached the entry point is always
            # retryable — surface 503, never a 500, on any path.
            self.close_connection = True
            self.log_error("journal write failed: %s", type(exc).__name__)
            self._send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "not persisted; retry"})
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as exc:
            self.close_connection = True
            self.log_error("unhandled request error: %s", type(exc).__name__)
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
        except (UnicodeDecodeError, ValueError):
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
            except ValueError:
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
        # Fail before committing the 200 response. A default in-memory state
        # after an unreadable journal is not a valid reset/config snapshot.
        self.debug_server.state.require_persistence_ready()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.wfile.write(b": connected\n\n")
        self.wfile.flush()
        # If the client's cursor has fallen behind the buffered (recoverable)
        # window, tell it to reset explicitly instead of silently skipping the
        # gap. The client should re-sync via the REST endpoints, then resume the
        # stream from the reported current id.
        if not self.debug_server.state.stream_cursor_recoverable(after_stream_id):
            current = self.debug_server.state.current_stream_id()
            reset = json.dumps(
                {"topic": "reset", "reason": "cursor_too_old", "current_stream_id": current},
                ensure_ascii=False, allow_nan=False, separators=(",", ":"),
            ).encode("utf-8")
            self.wfile.write(b"event: reset\n")
            self.wfile.write(b"data: " + reset + b"\n\n")
            self.wfile.flush()
            after_stream_id = current  # resume from head; the gap is unrecoverable
        cursor = after_stream_id
        while True:
            if not self.debug_server.state.persistence_ready():
                return
            updates = self.debug_server.state.wait_for_updates(cursor, timeout=15.0)
            if not self.debug_server.state.persistence_ready():
                return
            if not updates:
                self.wfile.write(b": heartbeat\n\n")
                self.wfile.flush()
                continue
            for update in updates:
                encoded = json.dumps(
                    update, ensure_ascii=False, allow_nan=False, separators=(",", ":")
                ).encode("utf-8")
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
        content = json.dumps(
            payload, ensure_ascii=False, allow_nan=False, separators=(",", ":")
        ).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            if status == HTTPStatus.UNAUTHORIZED:
                self.send_header("WWW-Authenticate", 'Bearer realm="AMProjDebug"')
            if self.close_connection:
                self.send_header("Connection", "close")
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
