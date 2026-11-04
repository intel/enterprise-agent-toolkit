# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""identity_proxy.py as a real subprocess, against a fake Keycloak and a fake MCP upstream.

In-process tests would skip main()'s per-port binding, which carries the security property.
"""
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

PROXY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "identity_proxy.py")
SECRET = "s3cr3t-never-in-the-pod"
PAT = "ghp-alice-own-pat"


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _Recorder:
    def __init__(self):
        self.requests, self.token_mints = [], 0

    def find(self, method, needle):
        for entry in reversed(self.requests):
            if entry[0] == method and needle in entry[1]:
                return entry
        return None


class _TokenHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    assigned = ("mcp-memory", "mcp-sandbox")  # anything else is refused like Keycloak does

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        self.server.rec.token_mints += 1
        scope = urllib.parse.parse_qs(body).get("scope", [""])[0]
        if scope and scope not in self.assigned:
            return self._json(400, {"error": "invalid_scope"})
        # The token names its scope, so the upstream's bearer shows which mint it came from.
        self._json(200, {"access_token": f"tok-{scope or 'none'}", "expires_in": 300})

    def _json(self, status, obj):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class _UpstreamHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _record(self):
        # raw keeps duplicate headers, which a dict would hide.
        self.server.rec.requests.append(
            (self.command, self.path, {k.lower(): v for k, v in self.headers.items()},
             [(k.lower(), v) for k, v in self.headers.items()]))

    def do_GET(self):
        self._record()
        if self.path.startswith("/sse"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for i in range(3):
                self.wfile.write(f"event: message\ndata: {i}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.3)
            self.close_connection = True
        else:
            self._plain(b"ok")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._record()
        self._plain(b'{"ok": true}')

    def _plain(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def _serve(handler, rec):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", _free_port()), handler)
    srv.rec = rec
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def _wait_for_port(port, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.3):
                return True
        except OSError:
            time.sleep(0.05)
    return False


class _Proxy:
    """Fake realm + upstream + a proxy process serving `routes` ({name: route minus url})."""

    def __init__(self, routes, creds=True, pat=None):
        self.rec = _Recorder()
        self.token_srv, self.up_srv = _serve(_TokenHandler, self.rec), _serve(_UpstreamHandler, self.rec)
        self.tmp = tempfile.TemporaryDirectory()
        self.creds = os.path.join(self.tmp.name, "creds")
        self.cred_dir = os.path.join(self.tmp.name, "toolcreds")
        os.makedirs(self.creds)
        os.makedirs(self.cred_dir)
        if creds:
            for k, v in {"client_id": "agent-alice-lab", "client_secret": SECRET,
                         "token_endpoint": f"http://127.0.0.1:{self.token_srv.server_port}/token"}.items():
                self._write(os.path.join(self.creds, k), v)
        if pat:
            self._write(os.path.join(self.cred_dir, "github_token"), pat + "\n")
        self.ports = {name: _free_port() for name in routes}
        upstream = f"http://127.0.0.1:{self.up_srv.server_port}/sse"
        routes_path = os.path.join(self.tmp.name, "routes.json")
        self._write(routes_path, json.dumps(
            {str(self.ports[n]): {"url": upstream, **r} for n, r in routes.items()}))
        env = dict(os.environ, ROUTES_PATH=routes_path, CREDS_DIR=self.creds,
                   CRED_HEADER_DIR=self.cred_dir)
        self.proc = subprocess.Popen([sys.executable, PROXY], env=env)
        if not all(_wait_for_port(p) for p in self.ports.values()):
            self.close()
            raise AssertionError("proxy did not bind its route ports")

    @staticmethod
    def _write(path, text):
        with open(path, "w") as fh:
            fh.write(text)

    def post(self, name, sid, headers=None):
        req = urllib.request.Request(f"http://127.0.0.1:{self.ports[name]}/messages/?session_id={sid}",
                                     data=b"{}", headers=headers or {})
        urllib.request.urlopen(req, timeout=10).read()
        return self.rec.find("POST", f"session_id={sid}")

    def raw(self, name, request):
        """Send bytes as-is: urllib capitalizes header names, which hides duplicates."""
        with socket.create_connection(("127.0.0.1", self.ports[name]), timeout=10) as sock:
            sock.sendall(request)
            while sock.recv(4096):
                pass

    def close(self):
        self.proc.kill()
        self.proc.wait(timeout=5)
        for srv in (self.token_srv, self.up_srv):
            srv.shutdown()
            srv.server_close()
        self.tmp.cleanup()


class IdentityProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = _Proxy({"r": {}})

    @classmethod
    def tearDownClass(cls):
        cls.p.close()

    def test_the_bearer_is_attached(self):
        self.assertEqual(self.p.post("r", "1")[2].get("authorization"), "Bearer tok-none")

    def test_pod_supplied_identity_headers_are_stripped(self):
        h = self.p.post("r", "2", {"Authorization": "Bearer forged", "X-Agent-Client-Id": "agent-bob-x",
                                   "X-Agent-Client-Secret": "stolen",
                                   "X-Agent-Token-Endpoint": "http://evil.invalid/token"})[2]
        self.assertEqual(h.get("authorization"), "Bearer tok-none")
        for gone in ("x-agent-client-id", "x-agent-client-secret", "x-agent-token-endpoint"):
            self.assertNotIn(gone, h)

    def test_a_lowercase_authorization_does_not_survive_as_a_duplicate(self):
        self.p.raw("r", b"POST /messages/?session_id=lc HTTP/1.1\r\nHost: x\r\n"
                        b"authorization: Bearer forged\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
        auth = [v for k, v in self.p.rec.find("POST", "session_id=lc")[3] if k == "authorization"]
        self.assertEqual(auth, ["Bearer tok-none"])

    def test_a_lowercase_host_does_not_survive_as_a_duplicate(self):
        # Two Host headers make the MCP server answer 400 before any handler runs.
        self.p.raw("r", b"GET /sse?probe=host HTTP/1.1\r\nhost: identity-proxy.agent-alice-lab.svc:8901\r\n"
                        b"accept: text/event-stream\r\nconnection: close\r\n\r\n")
        hosts = [v for k, v in self.p.rec.find("GET", "probe=host")[3] if k == "host"]
        self.assertEqual(len(hosts), 1)
        self.assertNotIn("identity-proxy", hosts[0])

    def test_the_secret_never_leaves_the_proxy(self):
        self.p.post("r", "s")
        for entry in self.p.rec.requests:
            self.assertNotIn(SECRET, json.dumps(entry[2]))

    def test_the_token_is_minted_once_and_cached(self):
        self.p.post("r", "warm")
        before = self.p.rec.token_mints
        for i in range(3):
            self.p.post("r", f"c{i}")
        self.assertEqual(self.p.rec.token_mints, before)

    def test_sse_streams_incrementally(self):
        start = time.time()
        resp = urllib.request.urlopen(f"http://127.0.0.1:{self.p.ports['r']}/sse", timeout=10)
        self.assertIn(b"event: message", resp.readline())
        self.assertLess(time.time() - start, 0.6, "the proxy is buffering the stream")
        self.assertIn(b"data: 2", resp.read())

    def test_the_upstream_is_chosen_by_port_not_by_request(self):
        entry = self.p.post("r", "3", {"Host": "mcp-github-server.agent-operator-system.svc.cluster.local"})
        self.assertEqual(entry[2].get("authorization"), "Bearer tok-none")


class ScopeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = _Proxy({"mem": {"scope": "mcp-memory"}, "sbx": {"scope": "mcp-sandbox"},
                        "gh": {"scope": "mcp-github"}})

    @classmethod
    def tearDownClass(cls):
        cls.p.close()

    def test_each_route_gets_its_own_scoped_token(self):
        self.assertEqual(self.p.post("mem", "s1")[2]["authorization"], "Bearer tok-mcp-memory")
        self.assertEqual(self.p.post("sbx", "s2")[2]["authorization"], "Bearer tok-mcp-sandbox")

    def test_the_scope_comes_from_the_port_not_the_request(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.p.ports['mem']}/messages/?session_id=s3&scope=mcp-sandbox",
            data=b'{"scope":"mcp-sandbox"}', headers={"Scope": "mcp-sandbox"})
        urllib.request.urlopen(req, timeout=10).read()
        self.assertEqual(self.p.rec.find("POST", "session_id=s3")[2]["authorization"], "Bearer tok-mcp-memory")

    def test_an_unassigned_scope_fails_closed_with_the_reason(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(f"http://127.0.0.1:{self.p.ports['gh']}/sse", timeout=10)
        self.assertEqual(cm.exception.code, 503)
        self.assertIn("invalid_scope", cm.exception.read().decode())
        self.assertIsNone(self.p.rec.find("GET", "/sse"))


class MissingCredentialsTest(unittest.TestCase):
    def test_fails_closed_with_503(self):
        p = _Proxy({"r": {}}, creds=False)
        try:
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(f"http://127.0.0.1:{p.ports['r']}/sse", timeout=10)
            self.assertEqual(cm.exception.code, 503)
            self.assertEqual(p.rec.requests, [])
        finally:
            p.close()


class CredHeaderTest(unittest.TestCase):
    """The upstream sees the PAT from this proxy's mount, whatever the pod sent."""

    @classmethod
    def setUpClass(cls):
        hdr = "X-Agent-Github-Token"
        cls.p = _Proxy({"ok": {"credHeaders": {hdr: "github_token"}},
                        "escape": {"credHeaders": {hdr: "../creds/client_secret"}},
                        "missing": {"credHeaders": {hdr: "absent"}},
                        "plain": {}}, pat=PAT)

    @classmethod
    def tearDownClass(cls):
        cls.p.close()

    def test_the_mounted_pat_is_injected(self):
        self.assertEqual(self.p.post("ok", "c1")[2].get("x-agent-github-token"), PAT)

    def test_a_pod_supplied_pat_is_replaced(self):
        entry = self.p.post("ok", "c2", {"X-Agent-Github-Token": "ghp-someone-elses"})
        self.assertEqual([v for k, v in entry[3] if k == "x-agent-github-token"], [PAT])

    def test_a_pod_supplied_pat_is_dropped_where_no_route_names_one(self):
        entry = self.p.post("plain", "c3", {"X-Agent-Github-Token": "ghp-invented"})
        self.assertNotIn("x-agent-github-token", entry[2])

    def test_a_path_in_the_file_name_is_refused(self):
        entry = self.p.post("escape", "c4")
        self.assertNotIn("x-agent-github-token", entry[2])
        self.assertNotIn(SECRET, json.dumps(entry[2]))

    def test_a_missing_file_leaves_the_header_absent(self):
        self.assertNotIn("x-agent-github-token", self.p.post("missing", "c5")[2])

    def test_a_rotated_secret_takes_effect_without_a_restart(self):
        path = os.path.join(self.p.cred_dir, "github_token")
        _Proxy._write(path, "ghp-rotated")
        try:
            self.assertEqual(self.p.post("ok", "c6")[2].get("x-agent-github-token"), "ghp-rotated")
        finally:
            _Proxy._write(path, PAT + "\n")


class NoRoutesTest(unittest.TestCase):
    def test_idles_instead_of_crashlooping(self):
        with tempfile.TemporaryDirectory() as tmp:
            routes = os.path.join(tmp, "routes.json")
            _Proxy._write(routes, "{}")
            proc = subprocess.Popen([sys.executable, PROXY], env=dict(os.environ, ROUTES_PATH=routes))
            try:
                time.sleep(1.0)
                self.assertIsNone(proc.poll(), "the proxy exited instead of idling")
            finally:
                proc.kill()
                proc.wait(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
