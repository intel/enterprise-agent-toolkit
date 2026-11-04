# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Per-agent identity proxy: the only holder of the agent's Keycloak client secret.

Runs in the agent's namespace. Each listening port fronts one MCP server: the proxy
mints a client-credentials token scoped to that server and attaches it as
`Authorization: Bearer`, so the agent pod holds no credential. The upstream and the
scope come from the port, never from the request, and identity or credential headers
sent by the pod are stripped. One port per upstream keeps MCP's SSE paths untouched.
"""
import http.client
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROUTES_PATH = os.environ.get("ROUTES_PATH", "/etc/identity-proxy/routes.json")
CREDS_DIR = os.environ.get("CREDS_DIR", "/etc/agent-identity")
# Credentials the agent spends on third parties (e.g. a GitHub PAT), from its own Secret.
CRED_HEADER_DIR = os.environ.get("CRED_HEADER_DIR", "/etc/agent-tool-credentials")
TOKEN_SKEW_SECONDS = int(os.environ.get("TOKEN_SKEW_SECONDS", "30"))
# Connect is bounded; reading is not, because SSE streams idle between events.
UPSTREAM_CONNECT_TIMEOUT = float(os.environ.get("UPSTREAM_CONNECT_TIMEOUT", "10"))

# Hop-by-hop headers (RFC 7230 6.1), plus Content-Length and Host, which are re-set.
_HOP_BY_HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
               "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host"}
# Anything the pod could send to assert identity or a credential; always removed.
_STRIPPED_REQUEST_HEADERS = {"authorization", "x-agent-client-id", "x-agent-client-secret",
                             "x-agent-token-endpoint", "x-agent-github-token"}


def _read_file(directory, name):
    try:
        with open(os.path.join(directory, name)) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def _read_cred_header_file(name):
    """A tool credential by file name; any path component is refused. Read per request."""
    if not name or "/" in name or os.sep in name or name.startswith("."):
        sys.stderr.write(f"identity-proxy: refusing cred file name {name!r}\n")
        return ""
    return _read_file(CRED_HEADER_DIR, name)


def _load_routes():
    """{port: (upstream_url, scope, {header: cred_file})} from routes.json."""
    try:
        with open(ROUTES_PATH) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"identity-proxy: cannot read {ROUTES_PATH}: {e}\n")
        return {}
    routes = {}
    for port, entry in (data or {}).items():
        if not isinstance(entry, dict):
            continue
        try:
            p = int(port)
        except (TypeError, ValueError):
            continue
        url = entry.get("url")
        raw = entry.get("credHeaders") or {}
        cred_headers = {str(h): str(f) for h, f in raw.items() if h and f} if isinstance(raw, dict) else {}
        if isinstance(url, str) and url.startswith(("http://", "https://")):
            routes[p] = (url, entry.get("scope") or "", cred_headers)
    return routes


class _TokenSource:
    """One cached token per scope, so a token minted for one server is refused by the others."""

    def __init__(self):
        self._lock = threading.Lock()
        self._cache = {}

    def get(self, scope=""):
        with self._lock:
            now = time.time()
            cached = self._cache.get(scope)
            if cached and cached[1] - now > TOKEN_SKEW_SECONDS:
                return cached[0]
            # Read per mint, so a rotated Secret takes effect without a restart.
            client_id = _read_file(CREDS_DIR, "client_id")
            client_secret = _read_file(CREDS_DIR, "client_secret")
            token_endpoint = _read_file(CREDS_DIR, "token_endpoint")
            if not (client_id and client_secret and token_endpoint):
                raise RuntimeError("identity credentials not mounted")
            form = {"grant_type": "client_credentials", "client_id": client_id,
                    "client_secret": client_secret}
            if scope:
                form["scope"] = scope
            req = urllib.request.Request(
                token_endpoint, data=urllib.parse.urlencode(form).encode(),
                headers={"Content-Type": "application/x-www-form-urlencoded"})
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:  # nosec B310 - in-cluster Keycloak
                    payload = json.loads(resp.read().decode())
            except urllib.error.HTTPError as e:
                # invalid_scope means the agent is not entitled to this tool: a denial, not a fault.
                try:
                    detail = json.loads(e.read().decode()).get("error", "")
                except (ValueError, OSError):
                    detail = ""
                raise RuntimeError(f"mint failed for scope {scope or '(none)'}: {e.code} {detail}")
            token = payload.get("access_token", "")
            if not token:
                raise RuntimeError("token endpoint returned no access_token")
            self._cache[scope] = (token, now + float(payload.get("expires_in", 60)))
            return token


_TOKENS = _TokenSource()


def _handler_for(upstream, scope="", cred_headers=None):
    cred_headers = cred_headers or {}
    split = urllib.parse.urlsplit(upstream)
    scheme, host = split.scheme, split.hostname
    port = split.port or (443 if scheme == "https" else 80)

    class _Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "identity-proxy/1"

        def log_message(self, fmt, *args):
            sys.stderr.write(f"identity-proxy {upstream} {fmt % args}\n")

        def _forward(self):
            try:
                token = _TOKENS.get(scope)
            except Exception as e:
                self._fail(503, f"identity unavailable: {e}")
                return
            length = int(self.headers.get("Content-Length") or 0)
            payload = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in _HOP_BY_HOP and k.lower() not in _STRIPPED_REQUEST_HEADERS}
            headers["Authorization"] = f"Bearer {token}"
            # Only non-empty files: an absent header means "use the server's shared credential".
            for header, file_name in cred_headers.items():
                value = _read_cred_header_file(file_name)
                if value:
                    headers[header] = value
            headers["Host"] = host if port in (80, 443) else f"{host}:{port}"
            if payload is not None:
                headers["Content-Length"] = str(len(payload))
            conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
            conn = conn_cls(host, port, timeout=UPSTREAM_CONNECT_TIMEOUT)
            try:
                conn.request(self.command, self.path, body=payload, headers=headers)
                conn.sock.settimeout(None)
                resp = conn.getresponse()
            except OSError as e:
                conn.close()
                self._fail(502, f"upstream unreachable: {e}")
                return
            try:
                self.send_response(resp.status, resp.reason)
                for k, v in resp.getheaders():
                    if k.lower() not in _HOP_BY_HOP:
                        self.send_header(k, v)
                # Close-delimited and flushed per chunk, so SSE events stream as they arrive.
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                while chunk := resp.read1(4096):
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                conn.close()

        def _fail(self, status, message):
            body = json.dumps({"error": message}).encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True

        do_GET = do_POST = do_DELETE = do_PUT = do_PATCH = _forward

    return _Handler


class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True  # an SSE stream holds its thread for the whole session
    allow_reuse_address = True


def main():
    routes = _load_routes()
    if not routes:
        sys.stderr.write("identity-proxy: no routes configured — idling\n")
        while True:
            time.sleep(3600)
    for port, (upstream, scope, cred_headers) in sorted(routes.items()):
        srv = _Server(("0.0.0.0", port), _handler_for(upstream, scope, cred_headers))  # nosec B104
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        sys.stderr.write(f"identity-proxy: :{port} -> {upstream} scope={scope or '(none)'} "
                         f"creds={','.join(sorted(cred_headers)) or '(none)'}\n")
    sys.stderr.flush()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
