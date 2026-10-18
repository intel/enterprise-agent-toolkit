# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""web_fetch_proxy.py: SSRF vetting offline, and forwarding as a real subprocess."""
import http.server
import ipaddress
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
import urllib.request

import web_fetch_proxy as p

PROXY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web_fetch_proxy.py")


def _ip(s):
    return ipaddress.ip_address(s)


class IsPublicTest(unittest.TestCase):
    def test_non_routable_addresses_are_refused(self):
        for s in ("100.64.0.1", "100.127.255.254", "10.233.55.159", "169.254.169.254", "127.0.0.1",
                  "0.0.0.0", "172.16.0.1", "192.168.1.1", "224.0.0.1", "192.0.0.1", "198.18.0.1",
                  "203.0.113.5", "240.0.0.1", "255.255.255.255", "::1", "fe80::1", "fc00::1"):
            self.assertFalse(p._is_public(_ip(s)), s)

    def test_tunnelled_v4_is_unwrapped_and_refused(self):
        for s in ("::ffff:10.0.0.1", "2002:a00:1::", "64:ff9b::a9fe:a9fe"):
            self.assertFalse(p._is_public(_ip(s)), s)

    def test_internet_addresses_pass(self):
        for s in ("8.8.8.8", "1.1.1.1", "140.82.121.4", "2620:fe::fe", "2606:4700:4700::1111"):
            self.assertTrue(p._is_public(_ip(s)), s)


class ResolveAllowedTest(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, socket, "getaddrinfo", socket.getaddrinfo)

    def _answers(self, *addrs):
        socket.getaddrinfo = lambda host, port, *a, **kw: [
            (socket.AF_INET6 if _ip(s).version == 6 else socket.AF_INET, socket.SOCK_STREAM,
             socket.IPPROTO_TCP, "", (s, port)) for s in addrs]

    def test_the_vetted_address_is_returned_not_the_name(self):
        self._answers("10.0.0.5", "100.64.0.1", "8.8.8.8")
        self.assertEqual(p._resolve_allowed("mixed.test", 443), ("8.8.8.8", 443))

    def test_a_name_with_only_private_answers_is_refused(self):
        for addr in ("100.64.12.9", "169.254.169.254"):
            self._answers(addr)
            with self.assertRaises(ValueError):
                p._resolve_allowed("rebind.test", 443)

    def test_an_unresolvable_name_is_refused(self):
        def boom(*a, **kw):
            raise socket.gaierror("no such host")
        socket.getaddrinfo = boom
        with self.assertRaises(ValueError):
            p._resolve_allowed("nope.test", 443)


class HostAllowedTest(unittest.TestCase):
    def test_suffix_match_does_not_reach_lookalikes(self):
        allow = ["github.com"]
        for host, ok in (("api.github.com", True), ("github.com", True), ("GitHub.com.", True),
                         ("notgithub.com", False), ("github.com.evil.test", False)):
            self.assertEqual(p._host_allowed(host, allow), ok, host)

    def test_empty_denies_and_wildcard_allows(self):
        self.assertFalse(p._host_allowed("github.com", []))
        self.assertTrue(p._host_allowed("anything.test", ["*"]))


class _Upstream(http.server.BaseHTTPRequestHandler):
    """A stand-in corporate proxy that records each request line."""
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _reply(self):
        self.server.seen.append((self.command, self.path, self.headers.get("Connection")))
        body = b"" if self.command == "HEAD" else b"hello"
        self.send_response(200)
        self.send_header("Content-Length", "5")
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_HEAD = do_PUT = do_DELETE = _reply


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class ForwardingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.up = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Upstream)
        cls.up.seen = []
        threading.Thread(target=cls.up.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory()
        allow = os.path.join(cls.tmp.name, "allowlist.json")
        with open(allow, "w") as fh:
            json.dump(["example.com"], fh)
        cls.port = _free_port()
        upstream = f"http://127.0.0.1:{cls.up.server_port}"
        cls.proc = subprocess.Popen([sys.executable, PROXY], env=dict(
            os.environ, PORT=str(cls.port), ALLOWLIST_PATH=allow, HTTP_PROXY=upstream,
            HTTPS_PROXY=upstream, http_proxy="", https_proxy=""))
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                socket.create_connection(("127.0.0.1", cls.port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.05)

    @classmethod
    def tearDownClass(cls):
        cls.proc.kill()
        cls.proc.wait(timeout=5)
        cls.up.shutdown()
        cls.up.server_close()
        cls.tmp.cleanup()

    def _open(self, url, method="GET"):
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": f"http://127.0.0.1:{self.port}"}))
        return opener.open(urllib.request.Request(url, method=method), timeout=10)

    def test_each_method_is_forwarded_as_itself_and_completes(self):
        for method in ("GET", "HEAD", "PUT", "DELETE"):
            start = time.time()
            self._open("http://www.example.com/x?y=1", method).read()
            self.assertLess(time.time() - start, 5, f"{method} hung on a keep-alive upstream")
            self.assertEqual(self.up.seen[-1], (method, "http://www.example.com/x?y=1", "close"))

    def test_a_domain_off_the_allowlist_is_refused(self):
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self._open("http://example.org/")
        self.assertEqual(cm.exception.code, 403)

    def test_connect_only_to_allowed_ports(self):
        for target, status in (("example.com:22", b"403"), ("example.com:x", b"403"),
                               ("evil.test:443", b"403")):
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
                s.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                self.assertIn(status, s.recv(1024).split(b"\r\n", 1)[0], target)


if __name__ == "__main__":
    unittest.main(verbosity=2)
