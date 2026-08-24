#!/usr/bin/env python3
"""Loopback JSON-RPC proxy that splits oversized batches for L1 read paths.

Listens on loopback, forwards to L1_RPC_URL (env only — never argv). Single
requests pass through unchanged. Batches larger than L1_BATCH_PROXY_CHUNK (default
40) are split into sequential upstream chunks with pacing so no upstream second
carries more than ~CHUNK sub-calls. Responses are merged in request order with
every request id preserved.

Partial chunk failure: entries in a failed chunk receive per-entry JSON-RPC
error objects (upstream error forwarded when present). Successful chunks are not
masked — D-0054.

Env:
  L1_RPC_URL              upstream http(s) URL (required)
  L1_BATCH_PROXY_LISTEN   host:port (default 127.0.0.1:9549); host must be loopback
  L1_BATCH_PROXY_CHUNK    max sub-calls per upstream chunk (default 40)
  L1_BATCH_PROXY_PACE_SEC seconds to sleep between chunks (default 1.0)
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional
from urllib.parse import urlparse

JSONRPC_PARSE_ERROR = -32700
JSONRPC_INVALID_REQUEST = -32600
JSONRPC_SERVER_ERROR = -32000

MAX_BODY_BYTES = 1_048_576
MAX_LINE_BYTES = 8192
MAX_TRAILER_LINES = 64


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def redact_rpc_url(url: str) -> str:
    if not url:
        return "<empty>"
    parsed = urlparse(url)
    netloc = parsed.hostname or ""
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    path = "/…" if parsed.path and parsed.path != "/" else ""
    return f"{parsed.scheme}://{netloc}{path}"


def require_loopback_listen(host: str) -> str:
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise SystemExit(
            f"ERROR: L1_BATCH_PROXY_LISTEN host must be loopback "
            f"(127.0.0.1/localhost/::1), got {host!r}"
        )
    return host


def require_http_url(name: str, url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise SystemExit(f"ERROR: {name} must be an http(s) URL with a host")
    return url


def error_response(req_id: Any, message: str, code: int = JSONRPC_SERVER_ERROR) -> dict:
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": code, "message": message},
    }


def _transfer_encoding_is_chunked(te_header: str) -> bool:
    parts = [p.strip().lower() for p in te_header.split(",") if p.strip()]
    return bool(parts) and parts[-1] == "chunked"


def _readline_bounded(rfile, max_line: int = MAX_LINE_BYTES) -> bytes:
    line = rfile.readline(max_line + 1)
    if not line:
        return b""
    if b"\n" not in line or len(line) > max_line:
        raise ValueError(f"header line exceeds max {max_line} bytes")
    return line


def read_chunked_body(rfile, max_bytes: int = MAX_BODY_BYTES) -> bytes:
    chunks: list[bytes] = []
    total = 0
    trailer_count = 0
    while True:
        size_line = _readline_bounded(rfile)
        if not size_line:
            raise ValueError("truncated chunked body")
        total += len(size_line)
        if total > max_bytes:
            raise ValueError(f"body exceeds max {max_bytes} bytes")
        size_field = size_line.strip()
        if b";" in size_field:
            size_field = size_field.split(b";", 1)[0].strip()
        try:
            size = int(size_field, 16)
        except ValueError as exc:
            raise ValueError("bad chunk size") from exc
        if size < 0:
            raise ValueError("bad chunk size")
        if size == 0:
            while True:
                trailer = _readline_bounded(rfile)
                if not trailer:
                    raise ValueError("truncated chunked trailers")
                total += len(trailer)
                if total > max_bytes:
                    raise ValueError(f"body exceeds max {max_bytes} bytes")
                if trailer in (b"\r\n", b"\n"):
                    break
                trailer_count += 1
                if trailer_count > MAX_TRAILER_LINES:
                    raise ValueError(f"too many trailer lines (max {MAX_TRAILER_LINES})")
            break
        if total + size + 2 > max_bytes:
            raise ValueError(f"body exceeds max {max_bytes} bytes")
        data = rfile.read(size)
        if len(data) < size:
            raise ValueError("truncated chunk")
        chunks.append(data)
        total += size
        crlf = rfile.read(2)
        if crlf != b"\r\n":
            raise ValueError("missing chunk CRLF")
        total += 2
    return b"".join(chunks)


def read_http_body(headers, rfile, max_bytes: int = MAX_BODY_BYTES) -> bytes:
    te = headers.get("Transfer-Encoding", "") or ""
    if _transfer_encoding_is_chunked(te):
        return read_chunked_body(rfile, max_bytes=max_bytes)
    if te.strip():
        raise ValueError(f"unsupported Transfer-Encoding: {te!r}")
    raw_len = headers.get("Content-Length", "0") or "0"
    try:
        length = int(raw_len)
    except ValueError as exc:
        raise ValueError("bad Content-Length") from exc
    if length < 0:
        raise ValueError("negative Content-Length")
    if length > max_bytes:
        raise ValueError(f"body exceeds max {max_bytes} bytes")
    if length == 0:
        return b""
    data = rfile.read(length)
    if len(data) < length:
        raise ValueError("truncated body")
    return data


class ProxyState:
    def __init__(self) -> None:
        upstream = _env("L1_RPC_URL")
        if not upstream:
            raise SystemExit("ERROR: L1_RPC_URL is required")
        self.upstream = require_http_url("L1_RPC_URL", upstream)
        chunk_s = _env("L1_BATCH_PROXY_CHUNK", "40")
        try:
            self.chunk_size = int(chunk_s)
        except ValueError as exc:
            raise SystemExit(f"ERROR: bad L1_BATCH_PROXY_CHUNK {chunk_s!r}") from exc
        if self.chunk_size < 1:
            raise SystemExit(f"ERROR: L1_BATCH_PROXY_CHUNK must be >= 1 (got {self.chunk_size})")
        pace_s = _env("L1_BATCH_PROXY_PACE_SEC", "1.0")
        try:
            self.pace_sec = float(pace_s)
        except ValueError as exc:
            raise SystemExit(f"ERROR: bad L1_BATCH_PROXY_PACE_SEC {pace_s!r}") from exc
        if self.pace_sec < 0:
            raise SystemExit(f"ERROR: L1_BATCH_PROXY_PACE_SEC must be >= 0 (got {self.pace_sec})")


STATE: Optional[ProxyState] = None


def _forward_raw(body: bytes, content_type: str) -> tuple[int, bytes, str]:
    assert STATE is not None
    req = urllib.request.Request(
        STATE.upstream,
        data=body,
        method="POST",
        headers={
            "Content-Type": content_type or "application/json",
            "User-Agent": "fortel2-l1-batch-proxy/1",
        },
    )
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = resp.read()
            ctype = resp.headers.get("Content-Type", "application/json")
            return resp.status, payload, ctype
    except urllib.error.HTTPError as err:
        payload = err.read()
        ctype = err.headers.get("Content-Type", "application/json")
        return err.code, payload, ctype
    except urllib.error.URLError as err:
        msg = error_response(None, f"upstream unreachable: {err.reason}")
        return 502, json.dumps(msg).encode(), "application/json"
    except TimeoutError:
        msg = error_response(None, "upstream timed out")
        return 504, json.dumps(msg).encode(), "application/json"


def _parse_json_payload(payload: bytes) -> Any:
    return json.loads(payload.decode("utf-8"))


def _chunk_error_entries(
    chunk_requests: list[Any], http_status: int, payload: bytes
) -> list[dict]:
    """Per-entry errors for a failed chunk — do not mask partial success (D-0054)."""
    upstream_err: Optional[dict] = None
    try:
        parsed = _parse_json_payload(payload)
        if isinstance(parsed, dict) and "error" in parsed:
            upstream_err = parsed["error"]
    except (UnicodeDecodeError, json.JSONDecodeError):
        pass

    out: list[dict] = []
    for item in chunk_requests:
        req_id = item.get("id") if isinstance(item, dict) else None
        if upstream_err is not None:
            out.append(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": dict(upstream_err),
                }
            )
        else:
            out.append(
                error_response(
                    req_id,
                    f"upstream returned HTTP {http_status}",
                    JSONRPC_SERVER_ERROR,
                )
            )
    return out


def _normalize_chunk_responses(
    chunk_requests: list[Any], http_status: int, payload: bytes
) -> list[Any]:
    if not (200 <= http_status < 300):
        return _chunk_error_entries(chunk_requests, http_status, payload)

    try:
        parsed = _parse_json_payload(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return [
            error_response(
                item.get("id") if isinstance(item, dict) else None,
                f"upstream returned non-JSON (HTTP {http_status})",
                JSONRPC_SERVER_ERROR,
            )
            for item in chunk_requests
        ]

    if isinstance(parsed, list):
        if len(parsed) != len(chunk_requests):
            return [
                error_response(
                    item.get("id") if isinstance(item, dict) else None,
                    f"upstream batch length mismatch (got {len(parsed)}, want {len(chunk_requests)})",
                    JSONRPC_SERVER_ERROR,
                )
                for item in chunk_requests
            ]
        return parsed

    if len(chunk_requests) == 1:
        return [parsed]

    return [
        error_response(
            item.get("id") if isinstance(item, dict) else None,
            "upstream returned single response for batch chunk",
            JSONRPC_SERVER_ERROR,
        )
        for item in chunk_requests
    ]


def split_batch(items: list[Any], chunk_size: int) -> list[list[Any]]:
    return [items[i : i + chunk_size] for i in range(0, len(items), chunk_size)]


def handle_jsonrpc_body(body: bytes, content_type: str) -> tuple[int, bytes, str]:
    assert STATE is not None
    try:
        parsed = json.loads(body.decode("utf-8") if body else "null")
    except (UnicodeDecodeError, json.JSONDecodeError):
        err = error_response(None, "parse error", JSONRPC_PARSE_ERROR)
        return 200, json.dumps(err).encode(), "application/json"

    if isinstance(parsed, dict):
        return _forward_raw(body, content_type)

    if not isinstance(parsed, list):
        err = error_response(None, "invalid request", JSONRPC_INVALID_REQUEST)
        return 200, json.dumps(err).encode(), "application/json"

    if len(parsed) == 0:
        err = error_response(None, "empty batch", JSONRPC_INVALID_REQUEST)
        return 200, json.dumps(err).encode(), "application/json"

    if len(parsed) <= STATE.chunk_size:
        return _forward_raw(body, content_type)

    chunks = split_batch(parsed, STATE.chunk_size)
    merged: list[Any] = []
    for idx, chunk in enumerate(chunks):
        if idx > 0 and STATE.pace_sec > 0:
            time.sleep(STATE.pace_sec)
        status, payload, _ctype = _forward_raw(
            json.dumps(chunk).encode(), "application/json"
        )
        part = _normalize_chunk_responses(chunk, status, payload)
        merged.extend(part)
    # JSON-RPC batch responses must use HTTP 2xx so Go clients decode the body.
    # Per-entry errors carry upstream failure; non-2xx would discard successful chunks.
    return 200, json.dumps(merged).encode(), "application/json"


def _write_json(
    handler: BaseHTTPRequestHandler,
    status: int,
    payload: bytes,
    ctype: str = "application/json",
    close: bool = False,
) -> None:
    handler.send_response(status)
    if close:
        handler.send_header("Connection", "close")
        handler.close_connection = True
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fortel2-l1-batch-proxy/1"
    sys_version = ""

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_POST(self) -> None:  # noqa: N802
        try:
            body = read_http_body(self.headers, self.rfile)
        except ValueError as exc:
            msg = error_response(None, f"bad request body: {exc}", JSONRPC_INVALID_REQUEST)
            _write_json(self, 400, json.dumps(msg).encode(), close=True)
            return
        ctype = self.headers.get("Content-Type", "application/json")
        try:
            status, payload, out_ctype = handle_jsonrpc_body(body, ctype)
        except Exception as exc:  # noqa: BLE001
            msg = error_response(None, f"proxy error: {exc}", JSONRPC_SERVER_ERROR)
            _write_json(self, 502, json.dumps(msg).encode())
            return
        _write_json(self, status, payload, out_ctype)

    def do_GET(self) -> None:  # noqa: N802
        assert STATE is not None
        body = (
            f'{{"ok":true,"upstream":"{redact_rpc_url(STATE.upstream)}",'
            f'"chunk":{STATE.chunk_size}}}\n'
        ).encode()
        _write_json(self, 200, body)


def self_test() -> None:
    """Property checks for test-helpers.sh (no live L1 required)."""
    import socket
    import threading

    assert split_batch(list(range(65)), 40) == [list(range(40)), list(range(40, 65))]
    assert redact_rpc_url("https://foo.quiknode.pro/abc123/def") == "https://foo.quiknode.pro/…"

    upstream_calls: list[list[Any]] = []
    upstream_mode: dict[str, Any] = {"fail_chunk": -1, "http_code": 200}

    class Upstream(BaseHTTPRequestHandler):
        server_version = "test-upstream/1"
        sys_version = ""

        def log_message(self, *_args) -> None:  # noqa: A003
            return

        def do_POST(self) -> None:  # noqa: N802
            n = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(n)
            parsed = json.loads(body.decode())
            if isinstance(parsed, list):
                batch = parsed
            else:
                batch = [parsed]
            upstream_calls.append(batch)
            chunk_idx = len(upstream_calls) - 1
            code = upstream_mode["http_code"]
            if chunk_idx == upstream_mode["fail_chunk"]:
                payload = json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32005, "message": "50/second request limit reached"},
                    }
                ).encode()
                self.send_response(429)
            else:
                out = []
                for item in batch:
                    req_id = item["id"]
                    if len(batch) == 1:
                        out = {"jsonrpc": "2.0", "id": req_id, "result": f"r-{req_id}"}
                    else:
                        out.append({"jsonrpc": "2.0", "id": req_id, "result": f"r-{req_id}"})
                if isinstance(out, dict):
                    payload = json.dumps(out).encode()
                else:
                    payload = json.dumps(out).encode()
                self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    up = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    up_port = up.server_address[1]
    threading.Thread(target=up.serve_forever, daemon=True).start()

    global STATE
    os.environ["L1_RPC_URL"] = f"http://127.0.0.1:{up_port}/secret-key-path"
    os.environ["L1_BATCH_PROXY_CHUNK"] = "40"
    os.environ["L1_BATCH_PROXY_PACE_SEC"] = "0"
    STATE = ProxyState()

    # Single request passes through unchanged.
    upstream_calls.clear()
    single = b'{"jsonrpc":"2.0","id":7,"method":"eth_blockNumber","params":[]}'
    status, payload, _ = handle_jsonrpc_body(single, "application/json")
    assert status == 200
    assert json.loads(payload) == {"jsonrpc": "2.0", "id": 7, "result": "r-7"}
    assert len(upstream_calls) == 1 and len(upstream_calls[0]) == 1

    # Upstream unreachable → JSON-RPC error (before batch tests tear down upstream).
    saved_upstream = os.environ["L1_RPC_URL"]
    os.environ["L1_RPC_URL"] = "http://127.0.0.1:1/unreachable"
    STATE = ProxyState()
    status, payload, _ = handle_jsonrpc_body(single, "application/json")
    assert status == 502
    err = json.loads(payload)
    assert err["error"]["code"] == JSONRPC_SERVER_ERROR
    assert "unreachable" in err["error"]["message"].lower()
    os.environ["L1_RPC_URL"] = saved_upstream
    STATE = ProxyState()

    # 65-request batch → ≥2 chunks, each ≤40, merged ids in order with distinct results.
    upstream_calls.clear()
    batch = [{"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": []} for i in range(65)]
    status, payload, _ = handle_jsonrpc_body(json.dumps(batch).encode(), "application/json")
    assert status == 200
    resp = json.loads(payload)
    assert isinstance(resp, list) and len(resp) == 65
    assert len(upstream_calls) >= 2
    assert all(len(c) <= 40 for c in upstream_calls)
    for i, entry in enumerate(resp):
        assert entry["id"] == i
        assert entry["result"] == f"r-{i}"

    # Order/id trap: if merged in completion order this would fail (ids 40+ before 39).
    upstream_calls.clear()
    batch = [{"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": []} for i in range(45)]
    status, payload, _ = handle_jsonrpc_body(json.dumps(batch).encode(), "application/json")
    resp = json.loads(payload)
    assert [e["id"] for e in resp] == list(range(45))
    assert [e["result"] for e in resp] == [f"r-{i}" for i in range(45)]

    # Upstream 429 on second chunk → per-entry errors for affected entries only.
    upstream_calls.clear()
    upstream_mode["fail_chunk"] = 1
    batch = [{"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": []} for i in range(65)]
    status, payload, _ = handle_jsonrpc_body(json.dumps(batch).encode(), "application/json")
    assert status == 200
    resp = json.loads(payload)
    assert len(resp) == 65
    for i in range(40):
        assert "result" in resp[i], i
        assert resp[i]["result"] == f"r-{i}"
    for i in range(40, 65):
        assert "error" in resp[i], i
        assert resp[i]["error"]["message"] == "50/second request limit reached"
    upstream_mode["fail_chunk"] = -1

    # Mutation probe: wrong merge order would pass length/id checks but fail result mapping.
    def _bad_merge(chunks_resp: list[list[Any]]) -> list[Any]:
        return [x for part in reversed(chunks_resp) for x in part]

    fake = [[{"jsonrpc": "2.0", "id": i, "result": f"r-{i}"} for i in range(40)],
            [{"jsonrpc": "2.0", "id": i, "result": f"r-{i}"} for i in range(40, 45)]]
    bad = _bad_merge(fake)
    assert [e["id"] for e in bad] != list(range(45))

    up.shutdown()
    print("l1-batch-proxy self-test ok", flush=True)


def main() -> int:
    global STATE
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return 0

    listen = _env("L1_BATCH_PROXY_LISTEN", "127.0.0.1:9549")
    if ":" not in listen:
        raise SystemExit(f"ERROR: L1_BATCH_PROXY_LISTEN must be host:port (got {listen!r})")
    host, port_s = listen.rsplit(":", 1)
    host = require_loopback_listen(host)
    try:
        port = int(port_s)
    except ValueError as exc:
        raise SystemExit(f"ERROR: bad L1_BATCH_PROXY_LISTEN port in {listen!r}") from exc
    if port < 1 or port > 65535:
        raise SystemExit(f"ERROR: L1_BATCH_PROXY_LISTEN port out of range: {port}")

    STATE = ProxyState()
    print(
        f"l1-batch-proxy: listening on http://{host}:{port} "
        f"upstream={redact_rpc_url(STATE.upstream)} chunk={STATE.chunk_size}",
        flush=True,
    )
    server = ThreadingHTTPServer((host, port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
