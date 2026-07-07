"""
MCP Sandbox Server — bridges OpenClaw agents to agent-sandbox for isolated code execution.

Exposes MCP tools via SSE transport:
  - execute_python: Run Python code in an isolated sandbox pod
  - execute_shell: Run shell commands in the sandbox
  - install_package: pip install in the sandbox
  - reset_sandbox: Terminate and recreate fresh sandbox

Connects to sandbox-router via SandboxDirectConnectionConfig (permitted by
the controller's auto-generated NetworkPolicy).
"""

import base64
import os
import logging

from fastmcp import FastMCP
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SANDBOX_ROUTER_URL = os.environ.get(
    "SANDBOX_ROUTER_URL",
    "http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080"
)
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox")
SANDBOX_TEMPLATE = os.environ.get("SANDBOX_TEMPLATE", "python-sandbox-template")

# Build a shell env-var prefix so commands run inside the sandbox pod can reach
# the internet via the corporate proxy. Uses SANDBOX_HTTPS_PROXY / SANDBOX_HTTP_PROXY
# (not the standard names) so the kubernetes client in THIS pod is not affected.
_HTTP_PROXY = os.environ.get("SANDBOX_HTTP_PROXY", "")
_HTTPS_PROXY = os.environ.get("SANDBOX_HTTPS_PROXY", "")
_NO_PROXY = os.environ.get("SANDBOX_NO_PROXY", "localhost,127.0.0.1,10.0.0.0/8,.svc,.cluster.local")

_PROXY_PREFIX = ""
if _HTTPS_PROXY:
    _PROXY_PREFIX += (
        f"export http_proxy={_HTTP_PROXY!r}; "
        f"export HTTP_PROXY={_HTTP_PROXY!r}; "
        f"export https_proxy={_HTTPS_PROXY!r}; "
        f"export HTTPS_PROXY={_HTTPS_PROXY!r}; "
        f"export no_proxy={_NO_PROXY!r}; "
        f"export NO_PROXY={_NO_PROXY!r}; "
        f"export GIT_SSL_NO_VERIFY=false; "
    )


def _with_proxy(command: str) -> str:
    """Wrap command in sh -c with proxy env-vars exported, so git/pip reach the internet.
    commands.run() execs directly (no shell), so export must be inside sh -c."""
    if not _PROXY_PREFIX:
        return command
    # Escape any single quotes in the command before embedding in sh -c '...'
    safe = command.replace("'", "'\\''")
    return f"sh -c '{_PROXY_PREFIX}{safe}'"


os.environ["FASTMCP_STATELESS_HTTP"] = "1"
mcp = FastMCP("sandbox-executor")

_sandbox_client = None
_session_sandbox = None


def _get_client():
    global _sandbox_client
    if _sandbox_client is None:
        _sandbox_client = SandboxClient(
            connection_config=SandboxDirectConnectionConfig(api_url=SANDBOX_ROUTER_URL)
        )
        logger.info(f"SandboxClient initialized → {SANDBOX_ROUTER_URL}")
    return _sandbox_client


def _get_sandbox():
    global _session_sandbox
    if _session_sandbox is not None:
        try:
            _session_sandbox.commands.run("true")
            return _session_sandbox
        except Exception:
            logger.info("Stale sandbox session, creating new one")
            _session_sandbox = None

    client = _get_client()
    _session_sandbox = client.create_sandbox(
        template=SANDBOX_TEMPLATE,
        namespace=SANDBOX_NAMESPACE,
    )
    logger.info(f"Sandbox session created (template={SANDBOX_TEMPLATE})")
    return _session_sandbox


def _format_result(result):
    output = []
    if result.stdout:
        output.append(result.stdout)
    if result.stderr:
        output.append(f"STDERR:\n{result.stderr}")
    if result.exit_code != 0:
        output.append(f"Exit code: {result.exit_code}")
    return "\n".join(output) if output else "Executed successfully (no output)"


@mcp.tool(description="Execute Python code in an isolated sandbox pod")
def execute_python(code: str) -> str:
    """Execute Python code in an isolated Kubernetes sandbox pod."""
    try:
        sandbox = _get_sandbox()
        encoded = base64.b64encode(code.encode()).decode()
        inner = f"echo {encoded} | base64 -d > /tmp/_exec.py && python3 /tmp/_exec.py"
        result = sandbox.commands.run(_with_proxy(inner))
        return _format_result(result)
    except Exception as e:
        logger.error(f"execute_python failed: {e}")
        return f"Error: {str(e)}"


@mcp.tool(description="Execute a shell command in the isolated sandbox pod")
def execute_shell(command: str) -> str:
    """Execute a shell command in the sandbox."""
    try:
        sandbox = _get_sandbox()
        result = sandbox.commands.run(_with_proxy(command))
        return _format_result(result)
    except Exception as e:
        logger.error(f"execute_shell failed: {e}")
        return f"Error: {str(e)}"


@mcp.tool(description="Install a Python package in the sandbox using pip")
def install_package(package: str) -> str:
    """Install a Python package in the sandbox."""
    try:
        sandbox = _get_sandbox()
        result = sandbox.commands.run(_with_proxy(f"pip install {package}"))
        if result.exit_code == 0:
            return f"Successfully installed {package}"
        return f"Failed to install {package}:\n{result.stderr}"
    except Exception as e:
        return f"Error: {str(e)}"


@mcp.tool(description="Terminate current sandbox and start fresh")
def reset_sandbox() -> str:
    """Reset the sandbox environment."""
    global _session_sandbox
    try:
        if _session_sandbox is not None:
            _session_sandbox.terminate()
            _session_sandbox = None
            logger.info("Sandbox terminated")
        return "Sandbox reset. Fresh environment on next execution."
    except Exception as e:
        return f"Error resetting: {str(e)}"


if __name__ == "__main__":
    mcp.run(transport="sse", port=8000, host="0.0.0.0")
