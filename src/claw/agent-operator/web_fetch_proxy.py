# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Per-agent forward proxy enforcing the agent's web_fetch domain allowlist.

The agent pod's HTTP(S)_PROXY points here and its NetworkPolicy allows no other way out.
The allowlist (spec.webFetchAllowlist) is re-read per request; empty denies everything and
"*" allows any public destination. Names that resolve to non-public addresses are refused.
"""
import http.server
import ipaddress
import json
import os
import socket
import socketserver
import threading
import time
from urllib.parse import urlsplit

ALLOWLIST_PATH = os.environ.get("ALLOWLIST_PATH", "/etc/web-fetch-proxy/allowlist.json")
LISTEN_PORT = int(os.environ.get("PORT", "8888"))
CONNECT_PORTS = {int(p) for p in os.environ.get("CONNECT_PORTS", "443").split(",") if p.strip()}
# The corporate proxy hop drops connects now and then; a few retries absorb that.
CONNECT_RETRIES = int(os.environ.get("UPSTREAM_CONNECT_RETRIES", "3"))
CONNECT_RETRY_DELAY = float(os.environ.get("UPSTREAM_CONNECT_RETRY_DELAY", "0.5"))
UPSTREAM_HTTP_PROXY = os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy", "")
UPSTREAM_HTTPS_PROXY = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy", "")
_HOP_BY_HOP = {"connection", "keep-alive", "proxy-connection", "proxy-authorization",
               "te", "trailer", "transfer-encoding", "upgrade"}


def _load_allowlist():
    try:
        with open(ALLOWLIST_PATH) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    return [d.strip().lower() for d in data if isinstance(d, str) and d.strip()]


def _host_allowed(host, allowlist):
    if "*" in allowlist:
        return True
    host = (host or "").lower().rstrip(".")
    return any(host == d or host.endswith("." + d) for d in allowlist)


def _embedded_v4(ip):
    """The IPv4 tunnelled in an IPv6 address (mapped, 6to4, Teredo, NAT64), or None."""
    for attr in ("ipv4_mapped", "sixtofour"):
        v = getattr(ip, attr, None)
        if v:
            return v
    teredo = getattr(ip, "teredo", None)
    if teredo:
        return teredo[1]
    if ip in ipaddress.ip_network("64:ff9b::/96"):
        return ipaddress.ip_address(int(ip) & 0xFFFFFFFF)
    return None


def _is_public(ip):
    """Globally routable only; the explicit flags still fail closed if is_global changes."""
    for a in (ip, _embedded_v4(ip)):
        if a is not None and (a.is_private or a.is_loopback or a.is_link_local or a.is_reserved
                              or a.is_multicast or a.is_unspecified or not a.is_global):
            return False
    return True


def _resolve_allowed(host, port):
    """One vetted public (ip, port) to dial, so a second lookup cannot rebind it."""
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise ValueError(f"could not resolve '{host}': {e}")
    for family, _, _, _, sockaddr in infos:
        if family in (socket.AF_INET, socket.AF_INET6) and _is_public(ipaddress.ip_address(sockaddr[0])):
            return sockaddr[0], port
    raise ValueError(f"'{host}' resolves only to non-public addresses")


def _upstream_proxy(https):
    """(host, port) of the corporate proxy, or None for direct egress."""
    raw = UPSTREAM_HTTPS_PROXY if https else UPSTREAM_HTTP_PROXY
    if not raw:
        return None
    parts = urlsplit(raw if "://" in raw else f"http://{raw}")
    return parts.hostname, parts.port or 80


def _connect(addr):
    for attempt in range(CONNECT_RETRIES):
        try:
            return socket.create_connection(addr, timeout=10)
        except OSError:
            if attempt == CONNECT_RETRIES - 1:
                raise
            time.sleep(CONNECT_RETRY_DELAY)


def _read_head(sock, limit=65536):
    """Bytes up to and including the blank line ending a response head."""
    data = b""
    while b"\r\n\r\n" not in data and len(data) < limit:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def _pump(src, dst):
    try:
        while chunk := src.recv(65536):
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _splice(a, b):
    """Relay both directions until both sides close (a CONNECT tunnel)."""
    threads = [threading.Thread(target=_pump, args=pair, daemon=True) for pair in ((a, b), (b, a))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for s in (a, b):
        s.close()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[web-fetch-proxy] {fmt % args}", flush=True)

    def _deny(self, status, message):
        self.close_connection = True
        self.send_error(status, message)

    def do_CONNECT(self):
        host, _, port_s = self.path.rpartition(":")
        if not port_s.isdigit() or int(port_s) not in CONNECT_PORTS:
            return self._deny(403, f"port '{port_s}' is not allowed")
        port = int(port_s)
        if not _host_allowed(host, _load_allowlist()):
            return self._deny(403, f"domain '{host}' is not in this agent's web_fetch allowlist")
        upstream = _upstream_proxy(https=True)
        try:
            # Through the corporate proxy, it resolves the name, never reaching the cluster.
            target = upstream or _resolve_allowed(host, port)
        except ValueError as e:
            return self._deny(403, str(e))
        try:
            remote = _connect(target)
            if upstream:
                remote.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
                if b" 200 " not in _read_head(remote).split(b"\r\n", 1)[0]:
                    remote.close()
                    return self._deny(502, "the upstream proxy refused CONNECT")
        except OSError as e:
            return self._deny(502, f"could not reach '{host}:{port}': {e}")
        self.log_message("allowed CONNECT %s:%d", host, port)
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.close_connection = True
        _splice(self.connection, remote)

    def _forward(self):
        parts = urlsplit(self.path)
        if parts.scheme != "http" or not parts.hostname:
            return self._deny(400, "absolute-form http:// request required (this is a forward proxy)")
        host, port = parts.hostname, parts.port or 80
        if not _host_allowed(host, _load_allowlist()):
            return self._deny(403, f"domain '{host}' is not in this agent's web_fetch allowlist")
        upstream = _upstream_proxy(https=False)
        try:
            target = upstream or _resolve_allowed(host, port)
        except ValueError as e:
            return self._deny(403, str(e))
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        # An upstream proxy takes the absolute form; an origin takes the path.
        line = self.path if upstream else (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
        head = [f"{self.command} {line} HTTP/1.1"]
        head += [f"{k}: {v}" for k, v in self.headers.items() if k.lower() not in _HOP_BY_HOP]
        head.append("Connection: close")
        self.close_connection = True
        try:
            remote = _connect(target)
        except OSError as e:
            return self._deny(502, f"could not reach '{host}': {e}")
        self.log_message("allowed %s http://%s%s", self.command, host, parts.path or "/")
        # Once the response is relaying, a failure can only end the connection.
        with remote:
            try:
                remote.sendall(("\r\n".join(head) + "\r\n\r\n").encode() + body)
                while chunk := remote.recv(65536):
                    self.connection.sendall(chunk)
            except OSError:
                pass

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _forward


class _Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"[web-fetch-proxy] listening on :{LISTEN_PORT}, allowlist {ALLOWLIST_PATH}", flush=True)
    _Server(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()  # nosec B104
