# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Sandbox MCP server: isolated code execution for agents, on agent-sandbox.

Each agent gets its own sandbox, keyed by its token's `azp` (agent-<username>-<name>), so no
two agents share files, packages or shell state. A sandbox never outlives its use: claims
carry a lease that is renewed while in use, idle sessions are terminated, claims left by a
previous process are adopted or swept, and the operator deletes an agent's claims when the
agent is suspended or deleted. Tools: execute_python, execute_shell, install_package,
reset_sandbox.
"""
import base64
import datetime
import hashlib
import logging
import os
import shlex
import threading
import time

from fastmcp import FastMCP
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox import connector as _connector
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

import auth

# force: the SDK installs a root handler at import, which would silence the AUDIT lines.
logging.basicConfig(level=logging.INFO, force=True)
logger = logging.getLogger("mcp-sandbox")

ROUTER_URL = os.environ.get("SANDBOX_ROUTER_URL",
                            "http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080")
ROUTER_AUTH_TOKEN = os.environ.get("ROUTER_AUTH_TOKEN", "")
NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox-system")
WARMPOOL = os.environ.get("SANDBOX_WARMPOOL", "claw-agent-pool")
IDLE_TIMEOUT = int(os.environ.get("SANDBOX_IDLE_TIMEOUT_SECONDS", "1800"))
LEASE = int(os.environ.get("SANDBOX_LEASE_SECONDS", "3600"))
REAP_INTERVAL = int(os.environ.get("SANDBOX_REAP_INTERVAL_SECONDS", "120"))
ORPHAN_GRACE = int(os.environ.get("SANDBOX_ORPHAN_GRACE_SECONDS", "900"))
READY_TIMEOUT = int(os.environ.get("SANDBOX_READY_TIMEOUT_SECONDS", "300"))
SCOPE_SHELL = "tools:shell"
# Shared with the operator, which deletes an agent's claims by these labels.
OWNER_LABEL, OWNER_LABEL_VALUE = "intel-stack.io/sandbox-owner", "mcp-sandbox-server"
SESSION_LABEL = "intel-stack.io/sandbox-session"

# The sandbox user's HOME is read-only; pip, git and the proxy settings need these.
# Paths inside the sandbox pod, not this server's filesystem.
_ENV = {"HOME": "/tmp", "PYTHONUSERBASE": "/tmp/.local", "PIP_CACHE_DIR": "/tmp/.cache/pip"}  # nosec B108
for _key in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"):
    if os.environ.get(f"SANDBOX_{_key}"):
        _ENV[_key] = _ENV[_key.lower()] = os.environ[f"SANDBOX_{_key}"]
_ENV_PREFIX = "".join(f"export {k}={shlex.quote(v)}; " for k, v in _ENV.items()) + \
    'export PATH="/tmp/.local/bin:$PATH"; '

if ROUTER_AUTH_TOKEN:
    # The SDK has no header option, so the router's bearer token is added per request.
    _send = _connector.SandboxConnector.send_request

    def _send_with_auth(self, method, endpoint, **kwargs):
        kwargs["headers"] = {"Authorization": f"Bearer {ROUTER_AUTH_TOKEN}", **(kwargs.get("headers") or {})}
        return _send(self, method, endpoint, **kwargs)

    _connector.SandboxConnector.send_request = _send_with_auth

mcp = FastMCP("sandbox")
_client = None
_sessions, _last_used = {}, {}
_lock = threading.Lock()


def session_label(session_key):
    return hashlib.sha256(session_key.encode()).hexdigest()[:32]


def _sh(command):
    """commands.run execs without a shell; run `command` in sh with the sandbox env."""
    return f"sh -c {shlex.quote(_ENV_PREFIX + command)}"


def _get_client():
    global _client
    if _client is None:
        _client = SandboxClient(connection_config=SandboxDirectConnectionConfig(api_url=ROUTER_URL))
    return _client


def _lease():
    expiry = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=LEASE)
    return {"shutdownTime": expiry.strftime("%Y-%m-%dT%H:%M:%SZ"), "shutdownPolicy": "Delete"}


def _renew(claim):
    """Push the claim's expiry out; a refused renewal only ends the session on schedule."""
    if LEASE > 0 and claim:
        try:
            _get_client().k8s_helper.patch_sandbox_claim(claim, NAMESPACE, {"spec": {"lifecycle": _lease()}})
        except Exception as e:
            logger.warning(f"lease renewal failed for claim '{claim}': {e}")


def _delete_claim(claim, reason):
    _get_client().delete_sandbox(claim, namespace=NAMESPACE)
    logger.info(f"AUDIT sandbox_claim_deleted claim={claim} reason={reason}")


def _claim_age(claim):
    try:
        created = (_get_client().k8s_helper.get_sandbox_claim(claim, NAMESPACE) or {}) \
            .get("metadata", {}).get("creationTimestamp")
        born = datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
        return (datetime.datetime.now(datetime.timezone.utc) - born).total_seconds()
    except Exception:
        return None


def _adopt(session_key):
    """Re-attach to this agent's live claim after a restart; extra or broken claims are deleted."""
    selector = f"{OWNER_LABEL}={OWNER_LABEL_VALUE},{SESSION_LABEL}={session_label(session_key)}"
    try:
        claims = _get_client().list_all_sandboxes(namespace=NAMESPACE, label_selector=selector)
    except Exception as e:
        logger.warning(f"could not list claims to adopt: {e}")
        return None
    adopted = None
    for claim in claims:
        if adopted is not None:
            _delete_claim(claim, "duplicate-session")
            continue
        try:
            sandbox = _get_client().get_sandbox(claim, namespace=NAMESPACE)
            sandbox.commands.run("true")
        except Exception:
            _delete_claim(claim, "unusable")
            continue
        adopted = sandbox
        logger.info(f"AUDIT sandbox_adopted azp={session_key} claim={claim}")
    if adopted is not None:
        _renew(adopted.claim_name)
    return adopted


def _get_sandbox(session_key):
    """The caller's own sandbox: the live one, an adopted one, or a new claim."""
    with _lock:
        sandbox = _sessions.get(session_key)
    if sandbox is not None:
        try:
            sandbox.commands.run("true")
        except Exception:
            sandbox = None
    sandbox = sandbox or _adopt(session_key)
    if sandbox is None:
        sandbox = _get_client().create_sandbox(
            warmpool=WARMPOOL, namespace=NAMESPACE, sandbox_ready_timeout=READY_TIMEOUT,
            labels={OWNER_LABEL: OWNER_LABEL_VALUE, SESSION_LABEL: session_label(session_key)},
            shutdown_after_seconds=LEASE if LEASE > 0 else None)
        logger.info(f"AUDIT sandbox_created azp={session_key} claim={sandbox.claim_name}")
    with _lock:
        _sessions[session_key], _last_used[session_key] = sandbox, time.monotonic()
    return sandbox


def _terminate(session_key, reason):
    with _lock:
        sandbox = _sessions.pop(session_key, None)
        _last_used.pop(session_key, None)
    if sandbox is None:
        return
    try:
        sandbox.terminate()
        logger.info(f"AUDIT sandbox_terminated azp={session_key} reason={reason}")
    except Exception as e:
        logger.warning(f"terminating the sandbox of '{session_key}' failed: {e}")


def _reap_once():
    """Terminate idle sessions, renew the live ones, delete orphaned claims past their grace."""
    now = time.monotonic()
    with _lock:
        idle = [k for k, t in _last_used.items() if IDLE_TIMEOUT > 0 and now - t >= IDLE_TIMEOUT]
    for key in idle:
        _terminate(key, f"idle>{IDLE_TIMEOUT}s")
    with _lock:
        held = {s.claim_name for s in _sessions.values() if s.claim_name}
    for claim in held:
        _renew(claim)
    try:
        claims = _get_client().list_all_sandboxes(namespace=NAMESPACE,
                                                  label_selector=f"{OWNER_LABEL}={OWNER_LABEL_VALUE}")
    except Exception as e:
        logger.warning(f"orphan sweep could not list claims: {e}")
        return
    for claim in set(claims) - held:
        age = _claim_age(claim)
        if age is not None and age >= ORPHAN_GRACE:
            _delete_claim(claim, f"orphan-{int(age)}s")


def _reaper():
    while True:
        try:
            _reap_once()
        except Exception as e:
            logger.error(f"sandbox reaper pass failed: {e}")
        time.sleep(REAP_INTERVAL)


def _run(tool, command, **audit):
    """Run `command` in the caller's sandbox and format the result for the agent."""
    try:
        azp = auth.caller(SCOPE_SHELL)["azp"]
        result = _get_sandbox(azp).commands.run(_sh(command))
        logger.info(f"AUDIT {tool} azp={azp}" + "".join(f" {k}={v}" for k, v in audit.items()))
    except auth.AuthError as e:
        return f"Error: {e}"
    except Exception as e:
        logger.warning(f"{tool} failed: {e}")
        return f"Error: {e}"
    out = [result.stdout] if result.stdout else []
    if result.stderr:
        out.append(f"STDERR:\n{result.stderr}")
    if result.exit_code != 0:
        out.append(f"Exit code: {result.exit_code}")
    return "\n".join(out) or "Executed successfully (no output)"


@mcp.tool(description="Execute Python code in your own isolated sandbox")
def execute_python(code: str) -> str:
    encoded = base64.b64encode(code.encode()).decode()
    return _run("execute_python", f"echo {encoded} | base64 -d > /tmp/_exec.py && python3 /tmp/_exec.py")


@mcp.tool(description="Execute a shell command in your own isolated sandbox")
def execute_shell(command: str) -> str:
    return _run("execute_shell", command)


@mcp.tool(description="Install a Python package in your own sandbox with pip")
def install_package(package: str) -> str:
    return _run("install_package", f"pip install --user {shlex.quote(package)}", package=shlex.quote(package))


@mcp.tool(description="Discard your sandbox; the next call starts a fresh one")
def reset_sandbox() -> str:
    try:
        _terminate(auth.caller(SCOPE_SHELL)["azp"], "reset_sandbox")
    except auth.AuthError as e:
        return f"Error: {e}"
    return "Sandbox reset. A fresh environment starts on the next call."


if __name__ == "__main__":
    if REAP_INTERVAL > 0:
        threading.Thread(target=_reaper, name="sandbox-reaper", daemon=True).start()
    mcp.run(transport="sse", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))  # nosec B104
