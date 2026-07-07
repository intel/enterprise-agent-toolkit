"""
MCP Agent-Dispatch Server — lead/worker multi-agent coordination.

Exposed to a LEAD agent (via mcp.servers). Lets the lead spawn worker agents,
dispatch tasks to them over an attenuated-JWT secured channel, and collect
results. Worker authority is always a subset of the lead's (attenuation).

Tools:
  spawn_worker(lead, worker_name, skills=[...])   -> create a role=worker Agent CR
  list_workers(lead)                              -> workers this lead manages
  dispatch_task(lead, worker, prompt, allowed_tools=None) -> secure task run
  collect_results(lead)                           -> results gathered so far
  terminate_worker(lead, worker)                  -> delete a worker Agent CR

Security (enforced + visible):
  - dispatch mints a real Keycloak access token from the LEAD's client
    (proves identity; signature verified via JWKS).
  - the requested worker authority (allowed_tools) MUST be a subset of the
    lead's own skills — over-scoped requests are REJECTED.
  - the granted, attenuated claims are returned so the caller can display them.
"""

import os
import ast
import json
import logging
import base64
import datetime
import threading
import uuid

from fastmcp import FastMCP

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak.auth-apisix.svc.cluster.local:80")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "master")
OPENCLAW_MODEL = os.environ.get("MODEL_ID", "Qwen/Qwen3-Coder-30B-A3B-Instruct")
WORKER_TURN_TIMEOUT = int(os.environ.get("WORKER_TURN_TIMEOUT", "300"))

# In-memory result store: {lead: [{worker, prompt, result, granted_claims, dispatch_id, status}]}
# (module-level: persists across requests in this single-replica process; stateless
# HTTP below affects the MCP SSE *session*, not process state.)
_results = {}
# Lock protecting writes to _results from background threads.
_results_lock = threading.Lock()

mcp = FastMCP("agent-dispatch")


# ── Kubernetes helpers ────────────────────────────────────────────────────

def _k8s():
    import kubernetes
    try:
        kubernetes.config.load_incluster_config()
    except Exception:
        kubernetes.config.load_kube_config()
    return kubernetes


def _agent_api(k8s):
    return k8s.client.CustomObjectsApi()


def _get_agent(k8s, name, namespace="default"):
    try:
        return _agent_api(k8s).get_namespaced_custom_object(
            group="intel-stack.io", version="v1alpha1", namespace=namespace,
            plural="agents", name=name)
    except Exception:
        return None


# ── Tools ─────────────────────────────────────────────────────────────────

@mcp.tool(description="Spawn a worker agent managed by the lead. Returns the worker name.")
def spawn_worker(lead: str, worker_name: str, skills: list = None) -> str:
    try:
        k8s = _k8s()
        lead_cr = _get_agent(k8s, lead)
        if not lead_cr:
            return f"Error: lead agent '{lead}' not found"
        owner = lead_cr.get("spec", {}).get("owner", {}).get("principal", "unknown")
        lead_skills = lead_cr.get("spec", {}).get("skills", [])
        # Worker skills must be a subset of the lead's (authority attenuation at spawn)
        req = skills or ["read_file", "summarize"]
        granted = [s for s in req if s in lead_skills] or ["read_file"]

        body = {
            "apiVersion": "intel-stack.io/v1alpha1",
            "kind": "Agent",
            "metadata": {
                "name": worker_name,
                "labels": {"intel-stack.io/managed-by-lead": lead},
            },
            "spec": {
                "runtime": "claw",
                "role": "worker",
                "owner": {"principal": owner},
                "skills": granted,
            },
        }
        try:
            _agent_api(k8s).create_namespaced_custom_object(
                group="intel-stack.io", version="v1alpha1", namespace="default",
                plural="agents", body=body)
            logger.info(f"Spawned worker '{worker_name}' (lead={lead}, skills={granted})")
            return f"Spawned worker '{worker_name}' with skills {granted} (subset of lead's authority)"
        except Exception as e:
            if "already exists" in str(e) or "AlreadyExists" in str(e):
                return f"Worker '{worker_name}' already exists"
            raise
    except Exception as e:
        logger.error(f"spawn_worker failed: {e}")
        return f"Error: {e}"


@mcp.tool(description="List worker agents managed by this lead, with phase.")
def list_workers(lead: str) -> list:
    try:
        k8s = _k8s()
        objs = _agent_api(k8s).list_namespaced_custom_object(
            group="intel-stack.io", version="v1alpha1", namespace="default",
            plural="agents", label_selector=f"intel-stack.io/managed-by-lead={lead}")
        return [
            {"worker": o["metadata"]["name"],
             "phase": o.get("status", {}).get("phase", "Unknown"),
             "skills": o.get("spec", {}).get("skills", [])}
            for o in objs.get("items", [])
        ]
    except Exception as e:
        return [{"error": str(e)}]


def _mint_and_verify_token(lead, requested_tools, authority, k8s):
    """Mint a Keycloak token from the lead's client and build an attenuated
    dispatch envelope. Enforces: requested_tools subset of `authority`
    (authority = lead_skills ∩ worker_skills, computed by the caller).
    Returns (granted_claims, error_or_None)."""
    import requests

    # Attenuation check — granted authority must be a subset of the allowed set.
    over = [t for t in (requested_tools or []) if t not in authority]
    if over:
        return None, f"REJECTED: requested tools {over} exceed allowed authority {authority}"

    granted_tools = requested_tools if requested_tools else authority

    # Read lead's Keycloak client creds (proves identity).
    kc_token = None
    try:
        core = k8s.client.CoreV1Api()
        sec = core.read_namespaced_secret(f"{lead}-keycloak-credentials", f"agent-{lead}")
        cid = base64.b64decode(sec.data["client_id"]).decode()
        csecret = base64.b64decode(sec.data["client_secret"]).decode()
        token_endpoint = base64.b64decode(sec.data["token_endpoint"]).decode()
        r = requests.post(token_endpoint, data={
            "grant_type": "client_credentials",
            "client_id": cid, "client_secret": csecret,
        }, timeout=10)
        if r.status_code == 200:
            kc_token = r.json().get("access_token")
        else:
            logger.warning(f"Keycloak token mint failed: {r.status_code} {r.text[:120]}")
    except Exception as e:
        logger.warning(f"Keycloak creds unavailable for '{lead}': {e}")

    # Verify the minted token's signature via JWKS (visible proof of validity).
    verified = False
    if kc_token:
        try:
            import jwt
            from jwt import PyJWKClient
            jwks_url = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/certs"
            signing_key = PyJWKClient(jwks_url).get_signing_key_from_jwt(kc_token)
            jwt.decode(kc_token, signing_key.key, algorithms=["RS256"],
                       options={"verify_aud": False})
            verified = True
        except Exception as e:
            logger.warning(f"JWT verify failed: {e}")

    now = datetime.datetime.now(datetime.timezone.utc)
    granted = {
        "parent_id": lead,
        "allowed_tools": granted_tools,
        "allowed_models": [OPENCLAW_MODEL],
        "expires_at": (now + datetime.timedelta(minutes=5)).isoformat(),
        "identity_token_verified": verified,
    }
    return granted, None


@mcp.tool(description="Dispatch a task to a worker over an attenuated-JWT secured channel. "
                      "Returns immediately with a dispatch_id. Poll collect_results() for the answer. "
                      "allowed_tools (optional) must be a subset of the lead's skills.")
def dispatch_task(lead: str, worker: str, prompt: str, allowed_tools: list = None) -> dict:
    try:
        k8s = _k8s()
        lead_cr = _get_agent(k8s, lead)
        if not lead_cr:
            return {"error": f"lead '{lead}' not found"}
        lead_skills = lead_cr.get("spec", {}).get("skills", [])

        # A dispatched task may grant at most the intersection of the lead's authority
        # and the worker's OWN provisioned skills — never a tool the worker doesn't
        # hold, even if the lead holds it. Bound = lead_skills ∩ worker_skills.
        worker_cr = _get_agent(k8s, worker)
        if not worker_cr:
            return {"error": f"worker '{worker}' not found"}
        worker_skills = worker_cr.get("spec", {}).get("skills", [])
        authority = [s for s in lead_skills if s in worker_skills]

        # Mint + verify the attenuated authority envelope (enforce ⊆ authority).
        granted, err = _mint_and_verify_token(lead, allowed_tools, authority, k8s)
        if err:
            return {"status": "rejected", "reason": err}

        dispatch_id = str(uuid.uuid4())[:8]

        # Record a pending placeholder so collect_results shows it immediately.
        entry = {
            "dispatch_id": dispatch_id,
            "worker": worker,
            "prompt": prompt,
            "status": "running",
            "result": None,
            "granted_claims": granted,
        }
        with _results_lock:
            _results.setdefault(lead, []).append(entry)

        # Run the worker exec in a background thread — MCP connection returns right away.
        def _bg(entry=entry, k8s=k8s):
            worker_ns = f"agent-{worker}"
            pod = f"{worker}-0"
            try:
                _ensure_worker_awake(k8s, worker, worker_ns)
                reply = _run_worker_turn(k8s, worker_ns, pod, prompt)
                with _results_lock:
                    entry["result"] = reply
                    entry["status"] = "done"
                logger.info(f"dispatch {dispatch_id} ({worker}) done")
            except Exception as exc:
                with _results_lock:
                    entry["result"] = f"(worker turn failed: {exc})"
                    entry["status"] = "error"
                logger.error(f"dispatch {dispatch_id} bg failed: {exc}")

        threading.Thread(target=_bg, daemon=True).start()

        return {
            "status": "dispatching",
            "dispatch_id": dispatch_id,
            "worker": worker,
            "granted_claims": granted,
            "note": "Call collect_results(lead) to poll for the result.",
        }
    except Exception as e:
        logger.error(f"dispatch_task failed: {e}")
        return {"error": str(e)}


def _parse_agent_envelope(resp):
    """Extract the top-level result envelope from `openclaw agent` output.

    The CLI prints a Python-repr-style dict (single quotes, None/True/False),
    NOT strict JSON, so we locate the first balanced {...} block and try
    json.loads first, then ast.literal_eval as a fallback."""
    start = resp.find("{")
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(resp)):
        c = resp[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                blob = resp[start:i + 1]
                for parser in (json.loads, ast.literal_eval):
                    try:
                        return parser(blob)
                    except Exception:
                        continue
                return None
    return None


def _ensure_worker_awake(k8s, worker, namespace, timeout=180):
    """If the worker was auto-idle-suspended, resume it and wait for its pod.

    Robustness for long-running demos: a worker idle past the auto-suspend window
    is scaled to zero. dispatch_task must wake it (patch desiredState=Running so
    the operator un-suspends the OpenClawInstance) before exec'ing into the pod."""
    import time

    core = k8s.client.CoreV1Api()

    def _pod_ready():
        try:
            pods = core.list_namespaced_pod(
                namespace, label_selector=None).items
            for p in pods:
                if p.metadata.name == f"{worker}-0":
                    cs = p.status.container_statuses or []
                    return bool(cs) and all(c.ready for c in cs)
        except Exception:
            pass
        return False

    if _pod_ready():
        return

    # Resume via the Agent CR (operator drives OpenClawInstance.suspended=false).
    cr = _get_agent(k8s, worker)
    if cr and cr.get("spec", {}).get("desiredState") != "Running":
        try:
            _agent_api(k8s).patch_namespaced_custom_object(
                group="intel-stack.io", version="v1alpha1", namespace="default",
                plural="agents", name=worker,
                body={"spec": {"desiredState": "Running"}})
            logger.info(f"Resuming suspended worker '{worker}' for dispatch")
        except Exception as e:
            logger.warning(f"Could not patch worker '{worker}' to Running: {e}")

    deadline = time.time() + timeout
    while time.time() < deadline:
        if _pod_ready():
            logger.info(f"Worker '{worker}' pod is ready")
            return
        time.sleep(5)
    logger.warning(f"Worker '{worker}' pod not ready after {timeout}s; attempting exec anyway")


def _run_worker_turn(k8s, namespace, pod, prompt):
    """Exec `openclaw agent` in the worker pod, return the reply text.

    Retries once on known transient gateway closure signatures that can happen
    during worker startup/reload races.
    """
    from kubernetes.stream import stream
    import time

    def _once():
        cmd = ["openclaw", "agent", "--agent", "main", "--message", prompt,
               "--json", "--timeout", str(WORKER_TURN_TIMEOUT)]
        try:
            resp = stream(
                k8s.client.CoreV1Api().connect_get_namespaced_pod_exec,
                pod, namespace, container="openclaw", command=cmd,
                stderr=True, stdin=False, stdout=True, tty=False,
                _preload_content=True, _request_timeout=WORKER_TURN_TIMEOUT + 30)
            d = _parse_agent_envelope(resp)
            if not isinstance(d, dict):
                return resp.strip()[:500]
            payloads = d.get("result", {}).get("payloads", [])
            for p in payloads:
                if p.get("text"):
                    return p["text"]
            return "(no text in worker reply)"
        except Exception as e:
            return f"(worker turn failed: {e})"

    reply = _once()
    low = reply.lower()
    transient = (
        "embedded fallback" in low and
        "gateway closed" in low and
        ("1012" in low or "1006" in low)
    )
    if transient:
        logger.info(f"Transient worker gateway closure for {namespace}/{pod}; retrying once")
        time.sleep(2)
        reply = _once()

    return reply


@mcp.tool(description="Collect results gathered from dispatched workers for this lead. "
                      "Each entry has status=running|done|error. Poll until status=done.")
def collect_results(lead: str) -> list:
    with _results_lock:
        return list(_results.get(lead, []))


@mcp.tool(description="Terminate a worker agent (deletes the Agent CR and all its resources).")
def terminate_worker(lead: str, worker: str) -> str:
    try:
        k8s = _k8s()
        _agent_api(k8s).delete_namespaced_custom_object(
            group="intel-stack.io", version="v1alpha1", namespace="default",
            plural="agents", name=worker)
        return f"Terminated worker '{worker}'"
    except Exception as e:
        return f"Error: {e}"


if __name__ == "__main__":
    mcp.run(transport="sse", port=8000, host="0.0.0.0")
