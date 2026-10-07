#!/usr/bin/env python3
"""Caddy smoke test: the rendered caddy/Caddyfile.tmpl, served by the real caddy
binary (with the plugins the project's caddy image builds in), routing requests to
stub upstreams.

    caddy_smoke.py OUT_DIR

Renders the template with .aidev/caddy-render.sh, points the upstreams it names
(denser-blog, denser-wallet, block-explorer-ui, varnish, swagger, the JSON-RPC
server) at stub HTTP servers on 127.0.0.1, starts `caddy run`, and checks each
route. Then does the same with the site-wide `compression.snippet` from
caddy/snippets/README.md added, and checks every response is still encoded exactly
once (cases prefixed `compression.snippet: `). Writes OUT_DIR/caddy-smoke.xml (one
junit case per check) and each caddy's log to OUT_DIR/caddy-<variant>.log. Runs
without a network: everything is on the loopback.

Each stub answers with headers naming itself and the path it received, and a body
that depends only on the path: compressible JavaScript for `*.js`, HTML otherwise,
JSON for the API stubs. `/blog/precompressed.js` comes back already gzip-encoded,
as an upstream that compresses its own responses would send it.

Every request is sent with a browser's `Accept-Encoding`, and every check decodes
the response by its `Content-Encoding` before comparing bodies, so a check holds
whether or not Caddy compresses. What each response was encoded with, and its
size on the wire, is printed and recorded in the case's system-out.
"""

from __future__ import annotations

import gzip
import http.client
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
import zlib
from collections.abc import Callable
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape, quoteattr

import zstandard

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CADDY_PORT = 18080
CADDY_ADMIN = "127.0.0.1:18019"
# The template proxies POST / to http://{$JSONRPC_API_SERVER_NAME}:9000.
JSONRPC_PORT = 9000
ACCEPT_ENCODING = "zstd, br, gzip, deflate"
READY_TIMEOUT_S = 30

# Upstream host name in the template -> stub port (and the stub's name).
UPSTREAMS = {
    "denser-blog": 18101,
    "denser-wallet": 18102,
    "block-explorer-ui": 18103,
    "varnish": 18104,
    "swagger": 18105,
}

PRECOMPRESSED_PATH = "/blog/precompressed.js"


def js_body(path: str) -> bytes:
    """About 200 KB of repetitive, compressible JavaScript, unique per path."""
    line = f"export function chunk_{zlib.crc32(path.encode()) % 100000}(a, b) {{ return a.map((x) => x + b); }} // {path}\n"
    return (line * (200_000 // len(line) + 1)).encode()


def html_body(stub: str, path: str) -> bytes:
    row = f'<div class="row"><span>{stub}</span><a href="{path}">{path}</a></div>\n'
    return f"<!doctype html><html><head><title>{stub}</title></head><body>\n{row * 300}</body></html>\n".encode()


def json_body(stub: str, path: str) -> bytes:
    return (
        f'{{"stub": "{stub}", "path": "{path}", "items": [{", ".join(['{"n": 1}'] * 2000)}]}}\n'
    ).encode()


def expected_response(stub: str, path: str) -> tuple[str, bytes]:
    """(content type, body) the stub `stub` answers `path` with, before any encoding."""
    clean = path.split("?", 1)[0]
    if stub in ("varnish", "drone"):
        return "application/json", json_body(stub, clean)
    if clean.endswith(".js"):
        return "application/javascript; charset=utf-8", js_body(clean)
    return "text/html; charset=utf-8", html_body(stub, clean)


def make_stub(name: str) -> type[BaseHTTPRequestHandler]:
    class Stub(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _answer(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            if length:
                self.rfile.read(length)
            content_type, body = expected_response(name, self.path)
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("X-Stub", name)
            self.send_header("X-Stub-Path", self.path)
            self.send_header(
                "X-Stub-Accept-Encoding", self.headers.get("Accept-Encoding", "")
            )
            if self.path == PRECOMPRESSED_PATH:
                body = gzip.compress(body)
                self.send_header("Content-Encoding", "gzip")
                self.send_header("Vary", "Accept-Encoding")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        do_GET = do_POST = do_HEAD = _answer

        def log_message(self, *args: object) -> None:
            pass

    return Stub


def start_stubs() -> list[ThreadingHTTPServer]:
    servers = []
    for name, port in [*UPSTREAMS.items(), ("drone", JSONRPC_PORT)]:
        server = ThreadingHTTPServer(("127.0.0.1", port), make_stub(name))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    return servers


def point_upstreams_at_stubs(caddyfile: str) -> None:
    """Rewrite `http://<upstream>` in the rendered Caddyfile to the stub's loopback port."""
    with open(caddyfile, encoding="utf-8") as handle:
        text = handle.read()
    for name, port in UPSTREAMS.items():
        text, count = re.subn(
            rf"http://{re.escape(name)}(?=[\s{{])", f"http://127.0.0.1:{port}", text
        )
        if count == 0:
            raise RuntimeError(f"the rendered Caddyfile proxies to no http://{name}")
    with open(caddyfile, "w", encoding="utf-8") as handle:
        handle.write(text)


def caddy_env(xdg: str) -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "CADDY_SITES": f"http://localhost:{CADDY_PORT}",
            "CADDY_TLS_SELF_SIGNED": "false",
            "JSONRPC_API_SERVER_NAME": "127.0.0.1",
            "ADMIN_ENDPOINT_PROTOCOL": "https",
            "CADDY_ADMIN": CADDY_ADMIN,
            "XDG_DATA_HOME": os.path.join(xdg, "data"),
            "XDG_CONFIG_HOME": os.path.join(xdg, "config"),
        }
    )
    return env


@dataclass
class Response:
    status: int
    headers: dict[str, str]
    wire: bytes
    body: bytes = field(default=b"")

    @property
    def encoding(self) -> str:
        return self.headers.get("content-encoding", "")


def decode(wire: bytes, content_encoding: str) -> bytes:
    """Undo Content-Encoding (applied in the order listed) like a browser would."""
    data = wire
    for coding in reversed(
        [c.strip() for c in content_encoding.split(",") if c.strip()]
    ):
        if coding == "gzip":
            data = gzip.decompress(data)
        elif coding == "zstd":
            data = zstandard.ZstdDecompressor().decompressobj().decompress(data)
        elif coding != "identity":
            raise AssertionError(f"cannot decode Content-Encoding {coding!r}")
    return data


def request(
    method: str,
    path: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> Response:
    conn = http.client.HTTPConnection("localhost", CADDY_PORT, timeout=10)
    try:
        conn.request(
            method,
            path,
            body=body,
            headers={"Accept-Encoding": ACCEPT_ENCODING, **(headers or {})},
        )
        raw = conn.getresponse()
        wire = raw.read()
        response = Response(
            raw.status, {k.lower(): v for k, v in raw.getheaders()}, wire
        )
    finally:
        conn.close()
    response.body = decode(response.wire, response.encoding)
    return response


def wait_ready(caddy: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + READY_TIMEOUT_S
    while time.monotonic() < deadline:
        if caddy.poll() is not None:
            raise RuntimeError(f"caddy exited with {caddy.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", CADDY_PORT), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError(
        f"caddy did not listen on {CADDY_PORT} within {READY_TIMEOUT_S}s"
    )


# --- checks -----------------------------------------------------------------


def describe(path: str, response: Response) -> str:
    encoding = response.encoding or "identity"
    return (
        f"{path}: {response.status} content-type={response.headers.get('content-type', '')} "
        f"content-encoding={encoding} wire={len(response.wire)}B decoded={len(response.body)}B"
    )


def check_proxied(stub: str, path: str) -> Callable[[], str]:
    """`path` reaches `stub` with the path unchanged, and the decoded body is the stub's."""

    def check() -> str:
        response = request("GET", path)
        assert response.status == 200, f"status {response.status}"
        assert response.headers.get("x-stub") == stub, (
            f"answered by {response.headers.get('x-stub')!r}, not {stub!r}"
        )
        assert response.headers.get("x-stub-path") == path, (
            f"upstream saw {response.headers.get('x-stub-path')!r}"
        )
        content_type, body = expected_response(stub, path)
        assert response.headers.get("content-type") == content_type, (
            response.headers.get("content-type")
        )
        assert response.body == body, "decoded body differs from what the upstream sent"
        return describe(path, response)

    return check


def check_rest_api() -> str:
    path = "/hafah-api/version"
    summary = check_proxied("varnish", path)()
    response = request("GET", path)
    assert response.headers.get("access-control-allow-origin") == "*", (
        "no CORS header on a REST API response"
    )
    return summary


def check_jsonrpc_post() -> str:
    payload = b'{"jsonrpc":"2.0","method":"condenser_api.get_dynamic_global_properties","params":[],"id":1}'
    response = request(
        "POST", "/", body=payload, headers={"Content-Type": "application/json"}
    )
    assert response.status == 200, f"status {response.status}"
    assert response.headers.get("x-stub") == "drone", (
        f"answered by {response.headers.get('x-stub')!r}"
    )
    assert response.headers.get("access-control-allow-origin") == "*", (
        "no CORS header on a JSON-RPC response"
    )
    assert response.body == expected_response("drone", "/")[1]
    return describe("POST /", response)


def check_robots() -> str:
    response = request("GET", "/robots.txt")
    assert response.status == 200, f"status {response.status}"
    assert b"Disallow: /blog/" in response.body, response.body[:200]
    return describe("/robots.txt", response)


def check_cors_preflight() -> str:
    response = request("OPTIONS", "/hafah-api/version")
    assert response.status == 204, f"status {response.status}"
    assert response.headers.get("access-control-allow-origin") == "*"
    return describe("OPTIONS /hafah-api/version", response)


def check_precompressed_passthrough() -> str:
    """An upstream's own gzip reaches the client encoded once, not twice."""
    response = request("GET", PRECOMPRESSED_PATH)
    assert response.status == 200, f"status {response.status}"
    assert response.headers.get("x-stub") == "denser-blog"
    assert response.encoding == "gzip", (
        f"content-encoding {response.encoding!r}, expected the upstream's gzip"
    )
    assert response.body == expected_response("denser-blog", PRECOMPRESSED_PATH)[1], (
        "body is not the upstream's"
    )
    return describe(PRECOMPRESSED_PATH, response)


def check_compressed(
    stub: str, path: str, accept: str, encoding: str
) -> Callable[[], str]:
    """With `Accept-Encoding: accept`, `path` comes back `encoding`-encoded, at most a third of its size."""

    def check() -> str:
        response = request("GET", path, headers={"Accept-Encoding": accept})
        assert response.status == 200, f"status {response.status}"
        assert response.headers.get("x-stub") == stub, (
            f"answered by {response.headers.get('x-stub')!r}, not {stub!r}"
        )
        assert response.encoding == encoding, (
            f"content-encoding {response.encoding!r}, expected {encoding!r}"
        )
        assert response.body == expected_response(stub, path)[1], (
            "decoded body differs from what the upstream sent"
        )
        assert len(response.wire) * 3 <= len(response.body), (
            f"{len(response.wire)}B on the wire for {len(response.body)}B"
        )
        return describe(path, response)

    return check


def check_rest_api_not_compressed() -> str:
    path = "/hafah-api/version"
    response = request("GET", path)
    assert response.status == 200, f"status {response.status}"
    assert response.encoding == "", (
        f"content-encoding {response.encoding!r} on a REST API response"
    )
    return describe(path, response)


CHECKS: list[tuple[str, Callable[[], str]]] = [
    ("blog root", check_proxied("denser-blog", "/blog")),
    ("blog page", check_proxied("denser-blog", "/blog/trending")),
    (
        "blog js asset",
        check_proxied(
            "denser-blog", "/blog/_next/static/chunks/9007-053f889d0a75a024.js"
        ),
    ),
    ("wallet root", check_proxied("denser-wallet", "/wallet")),
    (
        "wallet js asset",
        check_proxied("denser-wallet", "/wallet/_next/static/chunks/main-app.js"),
    ),
    ("explorer root", check_proxied("block-explorer-ui", "/explorer")),
    (
        "explorer js asset",
        check_proxied("block-explorer-ui", "/explorer/_next/static/chunks/app.js"),
    ),
    ("rest api via varnish", check_rest_api),
    ("json-rpc post to root", check_jsonrpc_post),
    ("fallback to swagger", check_proxied("swagger", "/")),
    ("robots.txt", check_robots),
    ("cors preflight", check_cors_preflight),
    ("upstream-encoded response passes through", check_precompressed_passthrough),
    (
        "blog js compressed",
        check_compressed(
            "denser-blog",
            "/blog/_next/static/chunks/9007-053f889d0a75a024.js",
            ACCEPT_ENCODING,
            "zstd",
        ),
    ),
    (
        "blog js gzip for gzip-only client",
        check_compressed(
            "denser-blog",
            "/blog/_next/static/chunks/3737-2496fbddf4b51e75.js",
            "gzip",
            "gzip",
        ),
    ),
    (
        "blog page compressed",
        check_compressed("denser-blog", "/blog/trending", ACCEPT_ENCODING, "zstd"),
    ),
    (
        "wallet js compressed",
        check_compressed(
            "denser-wallet",
            "/wallet/_next/static/chunks/main-app.js",
            ACCEPT_ENCODING,
            "zstd",
        ),
    ),
    (
        "explorer js compressed",
        check_compressed(
            "block-explorer-ui",
            "/explorer/_next/static/chunks/app.js",
            ACCEPT_ENCODING,
            "zstd",
        ),
    ),
    ("rest api not compressed", check_rest_api_not_compressed),
]

# The site-wide `encode` an operator can add as caddy/snippets/compression.snippet
# (caddy/snippets/README.md, "Enable compression"). With it, the UI routes pass
# through two `encode` handlers; each response must still be encoded exactly once.
COMPRESSION_SNIPPET = """encode {
  zstd
  gzip
  minimum_length 1024
}
"""

SNIPPET_CHECKS: list[tuple[str, Callable[[], str]]] = [
    (
        "blog js compressed once",
        check_compressed(
            "denser-blog",
            "/blog/_next/static/chunks/9007-053f889d0a75a024.js",
            ACCEPT_ENCODING,
            "zstd",
        ),
    ),
    (
        "blog js gzip once for gzip-only client",
        check_compressed(
            "denser-blog",
            "/blog/_next/static/chunks/3737-2496fbddf4b51e75.js",
            "gzip",
            "gzip",
        ),
    ),
    (
        "blog page compressed once",
        check_compressed("denser-blog", "/blog/trending", ACCEPT_ENCODING, "zstd"),
    ),
    (
        "wallet js compressed once",
        check_compressed(
            "denser-wallet",
            "/wallet/_next/static/chunks/main-app.js",
            ACCEPT_ENCODING,
            "zstd",
        ),
    ),
    (
        "explorer js compressed once",
        check_compressed(
            "block-explorer-ui",
            "/explorer/_next/static/chunks/app.js",
            ACCEPT_ENCODING,
            "zstd",
        ),
    ),
    ("upstream-encoded response passes through", check_precompressed_passthrough),
    (
        "rest api compressed once by the snippet",
        check_compressed("varnish", "/hafah-api/version", ACCEPT_ENCODING, "zstd"),
    ),
]

# (name prefix, snippet files to add to caddy/snippets, checks)
VARIANTS: list[tuple[str, dict[str, str], list[tuple[str, Callable[[], str]]]]] = [
    ("", {}, CHECKS),
    ("compression.snippet: ", {"compression.snippet": COMPRESSION_SNIPPET}, SNIPPET_CHECKS),
]


# --- runner -----------------------------------------------------------------


def write_junit(path: str, results: list[tuple[str, float, str, str | None]]) -> None:
    failures = sum(1 for result in results if result[3] is not None)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<testsuite name="caddy-smoke" tests="{len(results)}" failures="{failures}" errors="0" skipped="0" '
        f'time="{sum(r[1] for r in results):.3f}">',
    ]
    for name, seconds, out, failure in results:
        case = f'<testcase classname="caddy-smoke" name={quoteattr(name)} time="{seconds:.3f}">'
        if failure is not None:
            case += f"<failure message={quoteattr(failure.splitlines()[-1] if failure else 'failed')}>{escape(failure)}</failure>"
        if out:
            case += f"<system-out>{escape(out)}</system-out>"
        lines.append(case + "</testcase>")
    lines.append("</testsuite>")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def run_checks(
    checks: list[tuple[str, Callable[[], str]]], prefix: str
) -> list[tuple[str, float, str, str | None]]:
    results = []
    for short_name, check in checks:
        name = prefix + short_name
        started = time.monotonic()
        try:
            out, failure = check(), None
            print(f"PASS {name}: {out}")
        except Exception as error:  # noqa: BLE001 - every failure is a case's result
            out, failure = (
                "",
                f"{type(error).__name__}: {error}\n{traceback.format_exc()}",
            )
            print(f"FAIL {name}: {type(error).__name__}: {error}")
        results.append((name, time.monotonic() - started, out, failure))
    return results


def run_variant(
    out_dir: str,
    prefix: str,
    snippets: dict[str, str],
    checks: list[tuple[str, Callable[[], str]]],
) -> list[tuple[str, float, str, str | None]]:
    """Render the template with `snippets` added, start caddy on it, and run `checks`."""
    label = prefix.rstrip(": ") or "default"
    conf = os.path.join(out_dir, f"caddy-smoke-etc-{label}")
    env = caddy_env(os.path.join(out_dir, "caddy-smoke-xdg"))
    caddy = None
    try:
        subprocess.run(
            [os.path.join(REPO, ".aidev", "caddy-render.sh"), conf], env=env, check=True
        )
        for name, text in snippets.items():
            with open(os.path.join(conf, "snippets", name), "w", encoding="utf-8") as handle:
                handle.write(text)
        caddyfile = os.path.join(conf, "Caddyfile")
        point_upstreams_at_stubs(caddyfile)
        with open(os.path.join(out_dir, f"caddy-{label}.log"), "wb") as log:
            caddy = subprocess.Popen(
                ["caddy", "run", "--config", caddyfile, "--adapter", "caddyfile"],
                cwd=conf,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
        wait_ready(caddy)
        return run_checks(checks, prefix)
    except Exception:  # noqa: BLE001 - a setup failure is reported as one failing case
        failure = traceback.format_exc()
        print(failure, file=sys.stderr)
        return [(f"{prefix}caddy starts with the rendered Caddyfile", 0.0, "", failure)]
    finally:
        if caddy is not None and caddy.poll() is None:
            caddy.send_signal(signal.SIGTERM)
            try:
                caddy.wait(timeout=10)
            except subprocess.TimeoutExpired:
                caddy.kill()


def main(out_dir: str) -> int:
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    start_stubs()
    results = []
    for prefix, snippets, checks in VARIANTS:
        results += run_variant(out_dir, prefix, snippets, checks)
    write_junit(os.path.join(out_dir, "caddy-smoke.xml"), results)
    return 1 if any(result[3] is not None for result in results) else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} OUT_DIR")
    sys.exit(main(sys.argv[1]))
