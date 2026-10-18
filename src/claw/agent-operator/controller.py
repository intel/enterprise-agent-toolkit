# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Agent operator: reconciles intel-stack.io/v1alpha1 Agent resources.

The operator owns the platform side of an agent (namespace, isolation, identity,
memory) and delegates the runtime workload to the claw adapter, which manages one
OpenClawInstance per Agent. It never writes the OpenClawInstance's own fields.

Lifecycle: Pending -> Running <-> IdleSuspended; Failed on invalid input.
"""
import datetime
import fnmatch
import hashlib
import json
import logging
import os
import re
import secrets
import threading
import types

import kopf
import kubernetes
import kubernetes.config

import claw_adapter

API_GROUP, API_VERSION, AGENT_PLURAL = "intel-stack.io", "v1alpha1", "agents"
TOOL_PLURAL = "tools"
MANAGED_BY = {"app.kubernetes.io/managed-by": "agent-operator"}
AGENT_LABEL = "intel-stack.io/agent"
OWNER_LABEL = "intel-stack.io/owner"
OWNER_NAMESPACE_LABEL = "intel-stack.io/owner-namespace"


def _env_json(key, default):
    try:
        return json.loads(os.environ.get(key, "") or "null") or default
    except ValueError:
        return default


def _env_bool(key, default="false"):
    return os.environ.get(key, default).lower() == "true"


# ── Configuration ────────────────────────────────────────────────────────────
OPERATOR_NAMESPACE = os.environ.get("OPERATOR_NAMESPACE", "agent-operator-system")
OPERATOR_SA_NAME = os.environ.get("OPERATOR_SA_NAME", "agent-operator")
# Holds pods/exec with no ClusterRoleBinding; bound per agent namespace only.
AGENT_NS_EXEC_CLUSTER_ROLE = os.environ.get("AGENT_NS_EXEC_CLUSTER_ROLE", "agent-operator-agent-ns-exec")
AGENT_NS_EXEC_BINDING = "agent-ns-exec"
# The API backend's Secret access, bound per agent namespace instead of cluster-wide.
AGENT_NS_BACKEND_CLUSTER_ROLE = os.environ.get("AGENT_NS_BACKEND_CLUSTER_ROLE", "agent-operator-agent-ns-backend")
BACKEND_SA_NAME = os.environ.get("BACKEND_SA_NAME", "agent-backend")
AUTO_SUSPEND_IDLE_MINUTES = int(os.environ.get("AUTO_SUSPEND_IDLE_MINUTES") or 240)

PGVECTOR_DSN = os.environ.get("PGVECTOR_DSN", "")
EMBEDDING_DIM = int(os.environ.get("EMBEDDING_DIM") or 768)
MEMORY_TIERS = ("claudemd", "project", "auto")
# true renames a deleted agent's schema to deleted_<schema>_<ts> instead of dropping it.
MEMORY_RETAIN_ON_DELETE = _env_bool("MEMORY_RETAIN_ON_DELETE")

# Sandbox claims an agent leaves behind; labels must match mcp-sandbox-server's.
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox-system")
SANDBOX_CLAIM_GROUP, SANDBOX_CLAIM_VERSION, SANDBOX_CLAIM_PLURAL = (
    "extensions.agents.x-k8s.io", "v1beta1", "sandboxclaims")
SANDBOX_SESSION_LABEL = "intel-stack.io/sandbox-session"
SANDBOX_OWNER_LABEL = "intel-stack.io/sandbox-owner"
SANDBOX_OWNER_LABEL_VALUE = "mcp-sandbox-server"

NETWORK_POLICY_ENABLED = _env_bool("NETWORK_POLICY_ENABLED")
# [{namespace, ports, podSelector?}]; ports are destination pod ports (15008 for mesh pods).
NETWORK_POLICY_EGRESS_ALLOW = _env_json("NETWORK_POLICY_EGRESS_ALLOW", [])
# Granted to the identity proxy only, so the agent pod cannot bypass it.
NETWORK_POLICY_IDENTITY_EGRESS_ALLOW = _env_json("NETWORK_POLICY_IDENTITY_EGRESS_ALLOW", [])
# Workloads outside the agent namespace that reach the agent (the API backend), same shape.
NETWORK_POLICY_INGRESS_ALLOW = _env_json("NETWORK_POLICY_INGRESS_ALLOW", [])
RESOURCE_QUOTA_ENABLED = _env_bool("RESOURCE_QUOTA_ENABLED")
RESOURCE_QUOTA_HARD = _env_json("RESOURCE_QUOTA_HARD", {})
LIMIT_RANGE_ENABLED = _env_bool("LIMIT_RANGE_ENABLED")
LIMIT_RANGE_DEFAULT = _env_json("LIMIT_RANGE_DEFAULT", {})
LIMIT_RANGE_DEFAULT_REQUEST = _env_json("LIMIT_RANGE_DEFAULT_REQUEST", {})
POD_SECURITY_ENABLED = _env_bool("POD_SECURITY_ENABLED")
POD_SECURITY_LEVEL = os.environ.get("POD_SECURITY_LEVEL", "restricted")
# Enrol agent namespaces in the Istio ambient mesh (required under mesh-wide STRICT mTLS).
MESH_AMBIENT = _env_bool("MESH_AMBIENT")
MAX_AGENTS_PER_OWNER = int(os.environ.get("MAX_AGENTS_PER_OWNER") or 0)

# Per-agent proxies run from this operator's own image (/code), configured by ConfigMap.
PROXY_IMAGE = os.environ.get("PROXY_IMAGE", "")
WEB_FETCH_PROXY_ENABLED = _env_bool("WEB_FETCH_PROXY_ENABLED")
WEB_FETCH_PROXY_PORT = int(os.environ.get("WEB_FETCH_PROXY_PORT") or 8888)
WEB_FETCH_PROXY_HTTP_PROXY = os.environ.get("WEB_FETCH_PROXY_HTTP_PROXY", "")
WEB_FETCH_PROXY_HTTPS_PROXY = os.environ.get("WEB_FETCH_PROXY_HTTPS_PROXY", "")
WEB_FETCH_PROXY_NO_PROXY = os.environ.get("WEB_FETCH_PROXY_NO_PROXY", "")
WEB_FETCH_PROXY_NAME = "web-fetch-proxy"
WEB_FETCH_PROXY_LABELS = {**MANAGED_BY, "intel-stack.io/component": "web-fetch-proxy"}

# Per-agent identity proxy, the only holder of the agent's client secret.
# One port per identity tool, from PORT_BASE; the NetworkPolicy opens the whole span.
IDENTITY_PROXY_PORT_BASE = int(os.environ.get("IDENTITY_PROXY_PORT_BASE") or 8901)
IDENTITY_PROXY_PORT_SPAN = int(os.environ.get("IDENTITY_PROXY_PORT_SPAN") or 16)
IDENTITY_PROXY_NAME = "identity-proxy"
IDENTITY_PROXY_LABELS = {**MANAGED_BY, "intel-stack.io/component": "identity-proxy"}
IDENTITY_PROXY_CRED_DIR = "/etc/agent-tool-credentials"
TOOL_CREDENTIALS_SECRET_SUFFIX = "-tool-credentials"

# Each agent's dashboard and chat at https://<GW_HOSTNAME>/gw/<owner ns>/<name>/: the platform
# gateway signs the user in (OIDC), verifies the token and admits the owner and converse grantees.
GW_HOSTNAME = os.environ.get("GW_HOSTNAME", "")
GW_GATEWAY = {"name": os.environ.get("GW_GATEWAY_NAME", "eg-gateway"),
              "namespace": os.environ.get("GW_GATEWAY_NAMESPACE", "envoy-gateway-system"),
              "sectionName": os.environ.get("GW_GATEWAY_SECTION", "https")}
GW_OIDC_CLIENT_ID = os.environ.get("GW_OIDC_CLIENT_ID", "agent-console")
GW_OIDC_SECRET = os.environ.get("GW_OIDC_SECRET", "agent-console-oidc")
GW_AUDIENCE = os.environ.get("GW_AUDIENCE", "agent-backend")
GW_PORT = 18789

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "").rstrip("/")
# The realm's public issuer, which its tokens carry and browsers sign in at.
KEYCLOAK_ISSUER = os.environ.get("KEYCLOAK_ISSUER", "").rstrip("/")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "agent-toolkit")
# Service account holding realm-management/manage-clients in KEYCLOAK_REALM.
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "")
# One audience per MCP server, assigned OPTIONAL so a token carries only the one requested.
MCP_AUDIENCES = [a.strip() for a in os.environ.get(
    "MCP_AUDIENCES", "mcp-memory,mcp-github,mcp-sandbox").split(",") if a.strip()]
# {scope: tools it covers}; DEFAULT scopes, withheld only when every covered tool is denied.
PERMISSION_SCOPES = {
    "tools:memory.read": ["memory_read", "memory_list_tiers"],
    "tools:memory.write": ["memory_write"],
    "tools:shell": ["execute_python", "execute_shell", "install_package", "reset_sandbox"],
    "tools:github.read": ["list_issues", "get_issue", "list_repo_tree",
                          "get_file_contents", "get_pull_request"],
    "tools:github.write": ["create_issue", "add_issue_comment", "create_branch",
                           "commit_file", "create_pull_request", "mark_pr_ready"],
}

# A Tool receives the agent's token, so it must be an in-cluster Service: `.svc` plus
# nothing or `.cluster.local`, never a free suffix that could resolve off-cluster.
_SERVICE_URL_RE = re.compile(
    r"^https?://[a-z0-9]([-a-z0-9]*[a-z0-9])?\.[a-z0-9]([-a-z0-9]*[a-z0-9])?"
    r"\.svc(\.cluster\.local)?(:[0-9]{1,5})?(/[^\s]*)?$")

# Usernames feed Postgres DDL and every derived name; no '-' or '_' keeps
# agent-<username>-<name> unambiguous across owners, 39 keeps it within 63 chars.
_USERNAME_RE = re.compile(r"^[a-z0-9]{1,39}$")
# The agent name becomes a Service name, which must be a DNS-1035 label.
_AGENT_NAME_RE = re.compile(r"^[a-z]([-a-z0-9]*[a-z0-9])?$")
_MAX_DERIVED_NAME = 63


# ── Naming ───────────────────────────────────────────────────────────────────
def _owner_username(spec):
    username = (spec or {}).get("owner", {}).get("username")
    if not username:
        raise ValueError("spec.owner.username is required (agent naming is keyed by it)")
    if not _USERNAME_RE.match(username):
        raise ValueError(
            f"spec.owner.username {username!r} is malformed — must match {_USERNAME_RE.pattern}")
    return username


def _owner_ns(spec):
    """Namespace the Agent itself must live in."""
    return f"user-{_owner_username(spec)}"


def _agent_ns(name, spec):
    """Namespace the agent's workload runs in; also its Keycloak client id."""
    return f"agent-{_owner_username(spec)}-{name}"


_kc_client_id = _agent_ns


def _memory_schema(name, spec):
    return _agent_ns(name, spec).replace("-", "_")


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def _owner_label(owner):
    return owner.replace("@", "_at_")


# ── Adapter seam ─────────────────────────────────────────────────────────────
class AgentContext:
    """Everything the adapter needs about one Agent."""

    def __init__(self, name, spec, logger):
        self.name = name
        self.spec = spec or {}
        self.namespace = _agent_ns(name, self.spec)
        self.cr_namespace = _owner_ns(self.spec)
        self.memory_schema = _memory_schema(name, self.spec)
        self.owner = self.spec.get("owner", {}).get("principal", "unknown")
        self.skills = self.spec.get("skills", ["shell", "read_file", "list_files"])
        self.custom_tools = self.spec.get("tools", [])
        self.tools_deny = self.spec.get("toolsDeny", [])
        self.workspace_files = self.spec.get("workspace", {}) or {}
        self.logger = logger
        self.model = self.spec.get("model", {}) or {}
        self.model_api_key = self._read_secret_key(self.spec.get("modelSecretRef"), "apiKey")
        self.github_token = self._read_secret_key(self.spec.get("githubTokenSecretRef"), "token")

    def _read_secret_key(self, secret_name, key):
        """Decoded `key` of a Secret in the agent namespace, or None (never raises).

        Every None is warned: a dropped credential is otherwise invisible. Never logs the value."""
        if not secret_name:
            return None
        try:
            sec = kubernetes.client.CoreV1Api().read_namespaced_secret(secret_name, self.namespace)
            raw = (sec.data or {}).get(key)
            if raw:
                return __import__("base64").b64decode(raw).decode()
            state = "empty" if key in (sec.data or {}) else "absent"
            self.logger.warning(
                f"secret '{secret_name}' in '{self.namespace}': key '{key}' is {state} — "
                f"'{self.name}' will run WITHOUT this credential")
        except Exception as e:
            self.logger.warning(
                f"secret '{secret_name}' key '{key}' unreadable for '{self.name}': {e}")
        return None


ADAPTER = None


def _get_adapter():
    return ADAPTER


@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, logger, **_):
    global ADAPTER
    settings.persistence.finalizer = "intel-stack.io/agent-operator"
    settings.posting.level = 20
    if not (KEYCLOAK_URL and KEYCLOAK_CLIENT_ID and KEYCLOAK_CLIENT_SECRET and PROXY_IMAGE):
        raise kopf.PermanentError(
            "KEYCLOAK_URL, KEYCLOAK_CLIENT_ID, KEYCLOAK_CLIENT_SECRET and PROXY_IMAGE are required")
    try:
        kubernetes.config.load_incluster_config()
    except kubernetes.config.ConfigException:
        kubernetes.config.load_kube_config()
    core = types.SimpleNamespace(
        k8s=kubernetes,
        apply_identity_proxy=_apply_identity_proxy,
        tools=_tool_table,
        identity_proxy_port_base=IDENTITY_PROXY_PORT_BASE,
        identity_proxy_port_span=IDENTITY_PROXY_PORT_SPAN,
        web_fetch_proxy_enabled=WEB_FETCH_PROXY_ENABLED,
        web_fetch_proxy_port=WEB_FETCH_PROXY_PORT,
    )
    ADAPTER = claw_adapter.ClawAdapter(core, claw_adapter.config_from_env())
    logger.info(f"Per-agent identity: keycloak={KEYCLOAK_URL} realm={KEYCLOAK_REALM}; "
                f"web_fetch proxy={'on' if WEB_FETCH_PROXY_ENABLED else 'off'}")


# ── Handlers ─────────────────────────────────────────────────────────────────
@kopf.on.create(API_GROUP, API_VERSION, AGENT_PLURAL)
def on_create(spec, status, patch, name, namespace, logger, **_):
    _reconcile(spec, patch, name, namespace, logger, resuming=False)


@kopf.on.resume(API_GROUP, API_VERSION, AGENT_PLURAL)
def on_resume(spec, status, patch, name, namespace, logger, **_):
    """Re-converge every agent on operator start; every step is idempotent.

    Suspended agents keep their state; only their Keycloak scopes and proxy code are refreshed."""
    if (spec or {}).get("desiredState") == "Suspended" or (status or {}).get("phase") == "IdleSuspended":
        if _owner_ns_matches(spec, namespace):
            _reconcile_kc_audiences(name, spec, logger)
            _reconcile_proxy_images(name, spec, logger)
        return
    _reconcile(spec, patch, name, namespace, logger, resuming=True)


def _fail(patch, name, logger, msg):
    logger.warning(f"Rejecting agent '{name}': {msg}")
    patch.status["phase"] = "Failed"
    patch.status["suspendReason"] = msg


def _owner_ns_matches(spec, namespace):
    try:
        return namespace == _owner_ns(spec)
    except ValueError:
        return False


def _reconcile(spec, patch, name, namespace, logger, resuming):
    """Make the declared state true; create and resume share it."""
    owner = spec.get("owner", {}).get("principal", "unknown")
    logger.info(f"{'Reconciling' if resuming else 'Creating'} agent '{name}' owner={owner}")

    try:
        agent_ns = _agent_ns(name, spec)
    except ValueError as e:
        return _fail(patch, name, logger, str(e))
    # Every derived name comes from spec.owner.username, so the Agent must live in
    # that owner's namespace; otherwise anyone could act on another owner's agents.
    if namespace != _owner_ns(spec):
        return _fail(patch, name, logger,
                     f"an Agent owned by '{spec['owner']['username']}' must be created in "
                     f"namespace '{_owner_ns(spec)}', not '{namespace}'")
    if not _AGENT_NAME_RE.match(name):
        return _fail(patch, name, logger,
                     f"agent name {name!r} is malformed — must match {_AGENT_NAME_RE.pattern}")
    if len(agent_ns) > _MAX_DERIVED_NAME:
        return _fail(patch, name, logger,
                     f"derived name '{agent_ns}' is {len(agent_ns)} chars, limit {_MAX_DERIVED_NAME}")
    # Owner "operator" with agent "system" would otherwise land in the operator's own namespace.
    if agent_ns in (OPERATOR_NAMESPACE, SANDBOX_NAMESPACE):
        return _fail(patch, name, logger, f"derived namespace '{agent_ns}' is reserved for the platform")
    # Admission control for new agents only; lowering the cap never fails admitted ones.
    if MAX_AGENTS_PER_OWNER > 0 and not resuming:
        count = _owner_agent_count(owner)
        if count > MAX_AGENTS_PER_OWNER:
            return _fail(patch, name, logger,
                         f"owner '{owner}' has {count} agents, exceeds cap {MAX_AGENTS_PER_OWNER}")

    if not resuming:
        patch.status["phase"] = "Pending"
    try:
        _ensure_namespace(agent_ns, owner, name, logger)
    except ValueError as e:
        return _fail(patch, name, logger, str(e))
    # Isolation before the workload, so its pod is born constrained.
    _apply_web_fetch_proxy(agent_ns, spec.get("webFetchAllowlist", []), logger)
    _apply_network_policy(agent_ns, logger)
    _apply_resource_quota(agent_ns, logger)
    _grant_agent_ns_exec(agent_ns, logger)
    _apply_gateway_route(name, spec, logger)

    conditions, failures = [], []

    def _cond(kind, ok, message, reason=None):
        conditions.append({
            "type": kind, "status": "True" if ok else "False", "lastTransitionTime": _now(),
            "reason": reason or ("Provisioned" if ok else "ProvisioningFailed"),
            "message": message,
        })
        if not ok and reason != "Disabled":
            failures.append(kind)
        return ok

    kc_ok = _provision_keycloak_client(name, agent_ns, owner, logger, spec)
    _cond("IdentityReady", kc_ok,
          f"Keycloak client {_kc_client_id(name, spec)}" if kc_ok
          else "Keycloak client provisioning failed")
    _create_gateway_secret(name, agent_ns, logger)

    schema = _provision_agent_memory(name, spec, logger)
    if schema:
        _cond("MemoryReady", True, f"pgvector schema {schema}")
    elif not PGVECTOR_DSN:
        _cond("MemoryReady", False, "per-agent memory is not configured", reason="Disabled")
    else:
        _cond("MemoryReady", False, f"pgvector schema {_memory_schema(name, spec)} was not provisioned")

    ctx = AgentContext(name, spec, logger)
    adapter = _get_adapter()
    backend_ref = adapter.create(ctx)
    if backend_ref:
        patch.status["backendRef"] = backend_ref
    backend_ok = _cond("BackendReady", bool(backend_ref),
                       f"OpenClawInstance {backend_ref['name']}" if backend_ref
                       else "OpenClawInstance was not created")

    # Create only: the agent edits its workspace, so a restart must not overwrite it.
    if not resuming:
        try:
            adapter.post_create(ctx)
            _cond("SeedingComplete", True, "workspace seeded")
        except Exception as e:
            logger.warning(f"Workspace seeding for '{name}' failed (continuing): {e}")
            _cond("SeedingComplete", False, f"workspace seeding failed: {e}")

    patch.status["conditions"] = conditions
    if backend_ok and not failures:
        patch.status["phase"] = "Running"
        patch.status["suspendReason"] = ""
        logger.info(f"Agent '{name}' is Running in namespace '{agent_ns}'")
    elif backend_ok:
        patch.status["phase"] = "Running"
        patch.status["suspendReason"] = f"degraded: {', '.join(failures)}"
        logger.warning(f"Agent '{name}' is Running but DEGRADED: {', '.join(failures)}")
    else:
        patch.status["phase"] = "Pending"
        patch.status["suspendReason"] = f"backend not provisioned ({', '.join(failures)})"
        logger.error(f"Agent '{name}': backend not provisioned — leaving phase=Pending")
    patch.status["memoryRef"] = schema or ""
    patch.status["lastActivity"] = _now()


@kopf.on.update(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec")
def on_update(patch, name, logger, **_):
    patch.status["lastActivity"] = _now()


@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.desiredState")
def on_desired_state(new, old, status, spec, name, namespace, patch, logger, **_):
    """Suspend and resume. Idempotent: auto-suspend also flips desiredState."""
    if old is None or not _owner_ns_matches(spec, namespace):
        return
    phase = (status or {}).get("phase")
    ctx = AgentContext(name, spec, logger)
    if new == "Suspended" and phase != "IdleSuspended":
        logger.info(f"Suspending agent '{name}'")
        _reap_agent_sandboxes(name, spec, logger, "suspended")
        _get_adapter().suspend(ctx)
        patch.status.update(phase="IdleSuspended", suspendedAt=_now(), suspendReason="manual")
    elif new == "Running" and phase != "Running":
        logger.info(f"Resuming agent '{name}'")
        _get_adapter().resume(ctx)
        patch.status.update(phase="Running", resumedAt=_now(), suspendReason="",
                            lastActivity=_now())


@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.skills")
@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.tools")
@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.toolsDeny")
@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.workspace")
@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.model")
@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.modelSecretRef")
@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.githubTokenSecretRef")
def on_capabilities_change(reason, old, new, spec, name, namespace, patch, logger, **_):
    """Re-render and roll the backend on a live edit.

    Gated on `reason`, not `old is None`: a field absent at creation also reports old=None."""
    if reason == kopf.Reason.CREATE or old == new or not _owner_ns_matches(spec, namespace):
        return
    _reconcile_kc_audiences(name, spec, logger)
    ctx = AgentContext(name, spec, logger)
    try:
        _grant_agent_ns_exec(ctx.namespace, logger)
        _get_adapter().update(ctx)
        patch.status["lastActivity"] = _now()
        logger.info(f"Agent '{name}': backend re-provisioned")
    except Exception as e:
        logger.warning(f"Agent '{name}': re-provision failed: {e}")


@kopf.on.field(API_GROUP, API_VERSION, AGENT_PLURAL, field="spec.webFetchAllowlist")
def on_web_fetch_allowlist_change(spec, name, namespace, patch, logger, **_):
    """The proxy re-reads its allowlist per request, so no pod roll is needed."""
    if not WEB_FETCH_PROXY_ENABLED or not _owner_ns_matches(spec, namespace):
        return
    agent_ns = _agent_ns(name, spec)
    _apply_web_fetch_proxy(agent_ns, spec.get("webFetchAllowlist", []), logger)
    _apply_network_policy(agent_ns, logger)
    patch.status["lastActivity"] = _now()


@kopf.timer(API_GROUP, API_VERSION, AGENT_PLURAL, interval=300.0)
def auto_idle_suspend(spec, status, name, namespace, patch, logger, **_):
    if AUTO_SUSPEND_IDLE_MINUTES <= 0 or spec.get("desiredState", "Running") != "Running":
        return
    if status.get("phase") != "Running" or not status.get("lastActivity"):
        return
    try:
        last = datetime.datetime.fromisoformat(status["lastActivity"].replace("Z", "+00:00"))
    except ValueError:
        return
    idle_min = (datetime.datetime.now(datetime.timezone.utc) - last).total_seconds() / 60.0
    if idle_min < AUTO_SUSPEND_IDLE_MINUTES or not _owner_ns_matches(spec, namespace):
        return
    logger.info(f"Auto-suspending '{name}' (idle {idle_min:.0f}m >= {AUTO_SUSPEND_IDLE_MINUTES}m)")
    _reap_agent_sandboxes(name, spec, logger, "auto-idle")
    try:
        _get_adapter().suspend(AgentContext(name, spec, logger))
    except Exception as e:
        logger.warning(f"Auto-suspend adapter call failed for '{name}': {e}")
    # Keep desiredState in step so a later desiredState=Running is a real change.
    patch.spec["desiredState"] = "Suspended"
    patch.status.update(phase="IdleSuspended", suspendedAt=_now(), suspendReason="auto-idle")


@kopf.timer(API_GROUP, API_VERSION, AGENT_PLURAL, interval=30.0, initial_delay=10.0)
def pod_readiness(spec, status, name, namespace, patch, logger, **_):
    """Keep a PodReady condition, so clients can tell whether the agent answers now."""
    if not _owner_ns_matches(spec, namespace):
        return
    _apply_gateway_route(name, spec, logger)  # catches grants that expired since the last pass
    ready = _pod_ready(_agent_ns(name, spec), name)
    conditions = [c for c in (status or {}).get("conditions") or [] if c.get("type") != "PodReady"]
    current = next((c for c in (status or {}).get("conditions") or [] if c.get("type") == "PodReady"), {})
    if current.get("status") == ("True" if ready else "False"):
        return
    suspended = (spec or {}).get("desiredState") == "Suspended"
    patch.status["conditions"] = conditions + [{
        "type": "PodReady", "status": "True" if ready else "False", "lastTransitionTime": _now(),
        "reason": "Ready" if ready else ("Suspended" if suspended else "NotReady"),
        "message": "the agent pod is ready" if ready else "the agent pod is not ready"}]


def _pod_ready(agent_ns, name):
    try:
        pods = kubernetes.client.CoreV1Api().list_namespaced_pod(
            agent_ns, label_selector=f"app.kubernetes.io/instance={name}").items
    except kubernetes.client.ApiException:
        return False
    return any(c.type == "Ready" and c.status == "True"
               for p in pods for c in (p.status.conditions or []) if not p.metadata.deletion_timestamp)


@kopf.on.delete(API_GROUP, API_VERSION, AGENT_PLURAL)
def on_delete(spec, name, namespace, logger, **_):
    """Tear down everything the agent owns; a misplaced Agent owns nothing."""
    if not _owner_ns_matches(spec, namespace):
        logger.warning(f"Agent '{name}' was never provisioned here — nothing to tear down")
        return
    agent_ns = _agent_ns(name, spec)
    try:
        _get_adapter().delete(AgentContext(name, spec, logger))
    except Exception as e:
        logger.warning(f"Backend delete for '{name}' failed (continuing): {e}")
    # Sandboxes first: their label derives from the Keycloak client id.
    _reap_agent_sandboxes(name, spec, logger, "agent-deleted")
    _delete_keycloak_client(name, logger, spec)
    _delete_gateway_route(name, spec, logger)
    for suffix in ("-gateway-token", "-keycloak-credentials", TOOL_CREDENTIALS_SECRET_SUFFIX):
        _delete_secret(f"{name}{suffix}", agent_ns)
    _teardown_agent_memory(name, spec, logger)
    _delete_agent_namespace(agent_ns, name, logger)
    _reap_owner_namespace(namespace, exclude=name, logger=logger)
    logger.info(f"Agent '{name}' cleanup complete")


# ── Tools (cluster-scoped Tool resources) ────────────────────────────────────
_tools_lock = threading.Lock()
_tools = None  # last resolved {skill: entry}


def _resolve_tools(items):
    """({skill: entry}, {tool name: phase}) from Tool objects.

    The oldest Tool per skill wins; an off-cluster URL is Rejected; an alias never shadows a skill."""
    items = sorted(items, key=lambda t: (t["metadata"].get("creationTimestamp") or "", t["metadata"]["name"]))
    table, phases, owners = {}, {}, {}
    for t in items:
        name, spec = t["metadata"]["name"], t.get("spec") or {}
        skill = spec.get("skill")
        if not skill or not _SERVICE_URL_RE.match(spec.get("url") or ""):
            phases[name] = "Rejected"
        elif skill in table:
            phases[name] = "Conflicting"
        else:
            phases[name], owners[skill] = "Registered", spec
            table[skill] = {"url": spec["url"], "transport": spec.get("transport") or "sse",
                            "requiresIdentity": bool(spec.get("requiresIdentity")),
                            "alwaysOn": bool(spec.get("alwaysOn")), "aliases": []}
    claimed = set(table)
    for skill, entry in table.items():
        for alias in owners[skill].get("aliasSkills") or []:
            if alias not in claimed:
                claimed.add(alias)
                entry["aliases"].append(alias)
    return table, phases


def _refresh_tools(logger):
    """Re-read every Tool, record its phase, and return the resolved table."""
    global _tools
    api = kubernetes.client.CustomObjectsApi()
    with _tools_lock:
        items = api.list_cluster_custom_object(API_GROUP, API_VERSION, TOOL_PLURAL).get("items", [])
        table, phases = _resolve_tools(items)
        for t in items:
            name, phase = t["metadata"]["name"], phases[t["metadata"]["name"]]
            if (t.get("status") or {}).get("phase") == phase:
                continue
            if phase != "Registered":
                logger.warning(f"Tool '{name}' is {phase}")
            try:
                api.patch_cluster_custom_object_status(API_GROUP, API_VERSION, TOOL_PLURAL, name, {
                    "status": {"phase": phase, "observedGeneration": t["metadata"].get("generation")}})
            except kubernetes.client.ApiException as e:
                logger.warning(f"Tool '{name}' status update failed: {e}")
        _tools = table
        return table


def _tool_table():
    """The adapter's view of the Tools; the watch below keeps it current."""
    return _tools if _tools is not None else _refresh_tools(logging.getLogger(__name__))


@kopf.on.event(API_GROUP, API_VERSION, TOOL_PLURAL)
def on_tool_event(logger, **_):
    """Re-converge running agents when the resolved table changes (not on status-only events)."""
    before = _tools
    if _refresh_tools(logger) == before or before is None:
        return
    agents = kubernetes.client.CustomObjectsApi().list_cluster_custom_object(
        API_GROUP, API_VERSION, AGENT_PLURAL).get("items", [])
    for agent in agents:
        name, spec = agent["metadata"]["name"], agent.get("spec") or {}
        if (spec.get("desiredState") == "Suspended" or (agent.get("status") or {}).get("phase") != "Running"
                or not _owner_ns_matches(spec, agent["metadata"]["namespace"])):
            continue
        try:
            _get_adapter().update(AgentContext(name, spec, logger), reseed=False)
        except Exception as e:
            logger.warning(f"Agent '{name}': tool re-wiring failed: {e}")


# ── Per-agent gateway route ──────────────────────────────────────────────────
def _gw_path(name, spec):
    return f"/gw/{_owner_ns(spec)}/{name}"


def _gw_allowed(name, spec):
    """Emails that may use the agent's gateway: the owner and live converse grantees."""
    owner = (spec.get("owner") or {}).get("principal", "").lower()
    now = datetime.datetime.now(datetime.timezone.utc)
    try:
        grants = kubernetes.client.CustomObjectsApi().list_namespaced_custom_object(
            API_GROUP, API_VERSION, _owner_ns(spec), "agentgrants").get("items", [])
    except kubernetes.client.ApiException:
        grants = []
    allowed = {owner}
    for g in (g.get("spec") or {} for g in grants):
        try:
            live = datetime.datetime.fromisoformat(str(g.get("expiresAt", "")).replace("Z", "+00:00")) > now
        except ValueError:
            live = False
        if (live and g.get("agentRef") == name and str(g.get("grantor", "")).lower() == owner
                and "converse" in (g.get("capabilities") or [])):
            allowed.add(str(g.get("grantee", "")).lower())
    return sorted(a for a in allowed if a)


def _gw_objects(name, spec):
    """HTTPRoute + SecurityPolicy (operator namespace) and ReferenceGrant (agent namespace)."""
    agent_ns, path = _agent_ns(name, spec), _gw_path(name, spec)
    labels = {**MANAGED_BY, AGENT_LABEL: name}
    meta = {"name": agent_ns, "namespace": OPERATOR_NAMESPACE, "labels": labels}
    no_credentials = {"type": "RequestHeaderModifier", "requestHeaderModifier": {"remove": ["Authorization", "Cookie"]}}
    backend = [{"name": name, "namespace": agent_ns, "port": GW_PORT}]
    route = {
        "apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute", "metadata": meta,
        "spec": {
            "parentRefs": [GW_GATEWAY], "hostnames": [GW_HOSTNAME],
            "rules": [
                # The chat API is served at the root, the dashboard under its base path.
                {"matches": [{"path": {"type": "PathPrefix", "value": f"{path}/v1/"}}],
                 "filters": [no_credentials, {"type": "URLRewrite", "urlRewrite": {
                     "path": {"type": "ReplacePrefixMatch", "replacePrefixMatch": "/v1/"}}}],
                 "backendRefs": backend},
                {"matches": [{"path": {"type": "PathPrefix", "value": path}}],
                 "filters": [no_credentials], "backendRefs": backend,
                 "timeouts": {"request": "0s"}},
            ]}}
    policy = {
        "apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "SecurityPolicy", "metadata": meta,
        "spec": {
            "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": agent_ns}],
            "oidc": {
                "provider": {"issuer": KEYCLOAK_ISSUER,
                             "authorizationEndpoint": f"{KEYCLOAK_ISSUER}/protocol/openid-connect/auth",
                             "tokenEndpoint": f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"},
                "clientID": GW_OIDC_CLIENT_ID, "clientSecret": {"name": GW_OIDC_SECRET},
                "redirectURL": f"https://{GW_HOSTNAME}{path}/oauth2/callback",
                "forwardAccessToken": True, "refreshToken": True,
                # A script's bearer token skips the browser sign-in; the checks below still apply.
                "passThroughAuthHeader": True,
                # The console's chat calls get a 401 to act on, not a sign-in page.
                "denyRedirect": {"headers": [{"name": "x-requested-with", "value": "XMLHttpRequest"}]}},
            "jwt": {"providers": [{
                "name": "keycloak", "issuer": KEYCLOAK_ISSUER, "audiences": [GW_AUDIENCE],
                "remoteJWKS": {"uri": f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/certs"},
                # The verified email is the user the agent gateway trusts (trusted-proxy mode).
                "claimToHeaders": [{"claim": "email", "header": "x-gw-user"}]}]},
            "authorization": {"defaultAction": "Deny", "rules": [{
                "name": "owner-and-grantees", "action": "Allow",
                "principal": {"jwt": {"provider": "keycloak", "scopes": ["agent:converse"],
                                      "claims": [{"name": "email", "values": _gw_allowed(name, spec)}]}}}]}}}
    grant = {
        "apiVersion": "gateway.networking.k8s.io/v1beta1", "kind": "ReferenceGrant",
        "metadata": {"name": "agent-gateway-route", "namespace": agent_ns, "labels": MANAGED_BY},
        "spec": {"from": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "namespace": OPERATOR_NAMESPACE}],
                 "to": [{"group": "", "kind": "Service", "name": name}]}}
    return route, policy, grant


_GW_KINDS = {"HTTPRoute": ("gateway.networking.k8s.io", "v1", "httproutes"),
             "SecurityPolicy": ("gateway.envoyproxy.io", "v1alpha1", "securitypolicies"),
             "ReferenceGrant": ("gateway.networking.k8s.io", "v1beta1", "referencegrants")}


def _put_custom(obj, logger):
    """Create, or merge-patch the spec of, a namespaced custom object; False on failure."""
    group, version, plural = _GW_KINDS[obj["kind"]]
    api, meta = kubernetes.client.CustomObjectsApi(), obj["metadata"]
    try:
        current = api.get_namespaced_custom_object(group, version, meta["namespace"], plural, meta["name"])
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            logger.warning(f"{obj['kind']} {meta['name']}: read failed: {e}")
            return False
        current = None
    try:
        if current is None:
            api.create_namespaced_custom_object(group, version, meta["namespace"], plural, obj)
        elif current.get("spec") != obj["spec"]:
            api.patch_namespaced_custom_object(group, version, meta["namespace"], plural, meta["name"],
                                               {"spec": obj["spec"]})
    except kubernetes.client.ApiException as e:
        logger.warning(f"{obj['kind']} {meta['name']}: apply failed: {e}")
        return False
    return True


def _apply_gateway_route(name, spec, logger):
    if GW_HOSTNAME and KEYCLOAK_ISSUER:
        for obj in _gw_objects(name, spec):
            _put_custom(obj, logger)


def _delete_gateway_route(name, spec, logger):
    agent_ns = _agent_ns(name, spec)
    for kind in ("SecurityPolicy", "HTTPRoute"):
        group, version, plural = _GW_KINDS[kind]
        try:
            kubernetes.client.CustomObjectsApi().delete_namespaced_custom_object(
                group, version, OPERATOR_NAMESPACE, plural, agent_ns)
        except kubernetes.client.ApiException as e:
            if e.status != 404:
                logger.warning(f"{kind} {agent_ns}: delete failed: {e}")


@kopf.on.event(API_GROUP, API_VERSION, "agentgrants")
def on_grant_event(body, logger, **_):
    """A grant changes who may use the agent's gateway; expiry is caught by pod_readiness."""
    ns, agent = body["metadata"]["namespace"], (body.get("spec") or {}).get("agentRef")
    if not (GW_HOSTNAME and agent):
        return
    try:
        spec = kubernetes.client.CustomObjectsApi().get_namespaced_custom_object(
            API_GROUP, API_VERSION, ns, AGENT_PLURAL, agent).get("spec") or {}
    except kubernetes.client.ApiException:
        return
    if _owner_ns_matches(spec, ns):
        _apply_gateway_route(agent, spec, logger)


# ── Per-agent memory (pgvector schema + tier tables) ─────────────────────────
def _provision_agent_memory(name, spec, logger):
    """Per-agent schema with one table per memory tier; None if not configured or failed."""
    if not PGVECTOR_DSN:
        return None
    schema = _memory_schema(name, spec)
    try:
        import psycopg  # noqa: PLC0415
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
            conn.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema}"')
            for tier in MEMORY_TIERS:
                conn.execute(
                    f'CREATE TABLE IF NOT EXISTS "{schema}"."{tier}" ('
                    f'id BIGSERIAL PRIMARY KEY, content TEXT, embedding VECTOR({EMBEDDING_DIM}), '
                    f'metadata JSONB, created_at TIMESTAMPTZ DEFAULT now())')
                conn.execute(
                    f'CREATE INDEX IF NOT EXISTS "{schema}_{tier}_emb_idx" '
                    f'ON "{schema}"."{tier}" USING hnsw (embedding vector_cosine_ops)')
            conn.commit()
        logger.info(f"Provisioned memory schema '{schema}'")
        return schema
    except Exception as e:
        logger.warning(f"Memory provisioning failed for '{name}': {e}")
        return None


def _teardown_agent_memory(name, spec, logger):
    if not PGVECTOR_DSN:
        return
    schema = _memory_schema(name, spec)
    try:
        import psycopg  # noqa: PLC0415
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            if MEMORY_RETAIN_ON_DELETE:
                archive = f"deleted_{schema}_{datetime.datetime.now(datetime.timezone.utc):%Y%m%d%H%M%S}"
                conn.execute(f'ALTER SCHEMA IF EXISTS "{schema}" RENAME TO "{archive}"')
                logger.info(f"Archived memory schema '{schema}' -> '{archive}'")
            else:
                conn.execute(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE')
                logger.info(f"Dropped memory schema '{schema}'")
            conn.commit()
    except Exception as e:
        logger.warning(f"Memory teardown failed for '{name}': {e}")


# ── Namespace, RBAC, isolation ───────────────────────────────────────────────
def _ensure_namespace(ns, owner, agent_name, logger):
    api = kubernetes.client.CoreV1Api()
    labels = {**MANAGED_BY, AGENT_LABEL: agent_name, OWNER_LABEL: _owner_label(owner)}
    if POD_SECURITY_ENABLED:
        for mode in ("enforce", "warn", "audit"):
            labels[f"pod-security.kubernetes.io/{mode}"] = POD_SECURITY_LEVEL
    if MESH_AMBIENT:
        labels["istio.io/dataplane-mode"] = "ambient"
    try:
        existing = api.read_namespace(ns).metadata.labels or {}
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            raise
        api.create_namespace(kubernetes.client.V1Namespace(
            metadata=kubernetes.client.V1ObjectMeta(name=ns, labels=labels)))
        logger.info(f"Created namespace '{ns}'")
        return
    # Only a namespace this operator created is reconciled: adopting a pre-existing one would
    # put default-deny and a quota on it, and delete it with the agent.
    if existing.get("app.kubernetes.io/managed-by") != MANAGED_BY["app.kubernetes.io/managed-by"]:
        raise ValueError(f"namespace '{ns}' already exists and was not created by the agent operator")
    for key in (AGENT_LABEL, OWNER_LABEL):
        if existing.get(key, labels[key]) != labels[key]:
            raise ValueError(f"namespace '{ns}' belongs to another {key.split('/')[1]}")
    api.patch_namespace(ns, {"metadata": {"labels": labels}})


def _grant_agent_ns_exec(agent_ns, logger):
    """Namespaced grants in this agent namespace only: exec for the operator (workspace seeding)
    and the API backend's credential Secrets. RoleBindings to chart ClusterRoles it may `bind`."""
    rbac = kubernetes.client.RbacAuthorizationV1Api()
    grants = [(AGENT_NS_EXEC_BINDING, AGENT_NS_EXEC_CLUSTER_ROLE, OPERATOR_SA_NAME, OPERATOR_NAMESPACE)]
    if BACKEND_SA_NAME:
        grants.append(("agent-backend", AGENT_NS_BACKEND_CLUSTER_ROLE, BACKEND_SA_NAME, OPERATOR_NAMESPACE))
    for name, role, sa, sa_ns in grants:
        binding = kubernetes.client.V1RoleBinding(
            metadata=kubernetes.client.V1ObjectMeta(name=name, namespace=agent_ns, labels=MANAGED_BY),
            role_ref=kubernetes.client.V1RoleRef(api_group="rbac.authorization.k8s.io", kind="ClusterRole", name=role),
            subjects=[kubernetes.client.RbacV1Subject(kind="ServiceAccount", name=sa, namespace=sa_ns)])
        try:
            try:
                rbac.create_namespaced_role_binding(agent_ns, binding)
            except kubernetes.client.ApiException as e:
                if e.status != 409:
                    raise
                rbac.replace_namespaced_role_binding(name, agent_ns, binding)
        except kubernetes.client.ApiException as e:
            logger.error(f"REFUSED RoleBinding {name} in '{agent_ns}': {e}; check ClusterRole '{role}' "
                         f"exists and the operator may bind it")


def _apply(create, replace, name, ns, body, logger, what):
    """Create, or replace on 409. Returns False on any other failure."""
    try:
        create(ns, body)
    except kubernetes.client.ApiException as e:
        if e.status != 409:
            logger.warning(f"{what} apply failed in '{ns}': {e}")
            return False
        replace(name, ns, body)
    return True


def _proxy_pod_spec(script, config_map, mount, env, ports, extra_volumes=(), extra_mounts=()):
    """Restricted-PSS pod spec running /code/<script> from the operator image; no API token."""
    c = kubernetes.client
    return c.V1PodSpec(
        automount_service_account_token=False,
        security_context=c.V1PodSecurityContext(
            run_as_non_root=True, run_as_user=65532, run_as_group=65532,
            seccomp_profile=c.V1SeccompProfile(type="RuntimeDefault")),
        containers=[c.V1Container(
            name="proxy", image=PROXY_IMAGE, command=["python", f"/code/{script}"], env=env,
            ports=[c.V1ContainerPort(container_port=p) for p in ports],
            volume_mounts=[c.V1VolumeMount(name="config", mount_path=mount, read_only=True),
                           *extra_mounts],
            security_context=c.V1SecurityContext(
                allow_privilege_escalation=False, read_only_root_filesystem=True,
                capabilities=c.V1Capabilities(drop=["ALL"])),
        )],
        volumes=[c.V1Volume(name="config", config_map=c.V1ConfigMapVolumeSource(name=config_map)),
                 *extra_volumes],
    )


def _apply_proxy_workload(ns, name, labels, config_hash, pod_spec, service_ports, logger):
    """Deployment + Service for a per-agent proxy; config_hash rolls the pod on a change."""
    c = kubernetes.client
    apps, core = c.AppsV1Api(), c.CoreV1Api()
    deployment = c.V1Deployment(
        metadata=c.V1ObjectMeta(name=name, namespace=ns, labels=labels),
        spec=c.V1DeploymentSpec(
            replicas=1, selector=c.V1LabelSelector(match_labels=labels),
            template=c.V1PodTemplateSpec(
                metadata=c.V1ObjectMeta(labels=labels,
                                        annotations={"intel-stack.io/config-hash": config_hash}),
                spec=pod_spec)))
    if not _apply(apps.create_namespaced_deployment, apps.replace_namespaced_deployment,
                  name, ns, deployment, logger, f"{name} Deployment"):
        return
    service = c.V1Service(
        metadata=c.V1ObjectMeta(name=name, namespace=ns, labels=labels),
        spec=c.V1ServiceSpec(selector=labels, ports=[
            c.V1ServicePort(name=f"p-{p}", port=p, target_port=p) for p in service_ports]))
    # Patch, not replace: a Service replace without its clusterIP is rejected.
    _apply(core.create_namespaced_service, core.patch_namespaced_service,
           name, ns, service, logger, f"{name} Service")


def _apply_identity_proxy(agent_name, agent_ns, routes, logger, tool_credentials=None):
    """Per-agent identity proxy: holds the client secret and attaches the bearer token.

    `routes` is {port: {"url", "scope", "credHeaders"?}} from the adapter; `tool_credentials`
    {file: value} go in their own Secret, replaced every time so a revoked PAT disappears."""
    c = kubernetes.client
    core = c.CoreV1Api()
    routes = {int(p): r for p, r in (routes or {}).items()}
    routes_json = json.dumps({str(p): routes[p] for p in sorted(routes)})
    cm_name = f"{IDENTITY_PROXY_NAME}-routes"
    cm = c.V1ConfigMap(
        metadata=c.V1ObjectMeta(name=cm_name, namespace=agent_ns, labels=IDENTITY_PROXY_LABELS),
        data={"routes.json": routes_json})
    if not _apply(core.create_namespaced_config_map, core.replace_namespaced_config_map,
                  cm_name, agent_ns, cm, logger, "identity-proxy ConfigMap"):
        return
    cred_secret = f"{agent_name}{TOOL_CREDENTIALS_SECRET_SUFFIX}"
    _apply(core.create_namespaced_secret, core.replace_namespaced_secret, cred_secret, agent_ns,
           c.V1Secret(metadata=c.V1ObjectMeta(name=cred_secret, namespace=agent_ns,
                                              labels=IDENTITY_PROXY_LABELS),
                      string_data={k: v for k, v in (tool_credentials or {}).items() if v}),
           logger, "identity-proxy tool credentials")
    # Optional secrets: a pod that starts and 503s recovers once kubelet syncs them.
    pod_spec = _proxy_pod_spec(
        "identity_proxy.py", cm_name, "/etc/identity-proxy",
        env=[c.V1EnvVar(name="ROUTES_PATH", value="/etc/identity-proxy/routes.json"),
             c.V1EnvVar(name="CREDS_DIR", value="/etc/agent-identity"),
             c.V1EnvVar(name="CRED_HEADER_DIR", value=IDENTITY_PROXY_CRED_DIR)],
        ports=sorted(routes),
        extra_volumes=[
            c.V1Volume(name="identity", secret=c.V1SecretVolumeSource(
                secret_name=f"{agent_name}-keycloak-credentials", optional=True)),
            c.V1Volume(name="tool-credentials", secret=c.V1SecretVolumeSource(
                secret_name=cred_secret, optional=True))],
        extra_mounts=[c.V1VolumeMount(name="identity", mount_path="/etc/agent-identity", read_only=True),
                      c.V1VolumeMount(name="tool-credentials", mount_path=IDENTITY_PROXY_CRED_DIR,
                                      read_only=True)])
    # Routes are bound at startup, so a route change must roll the pod.
    _apply_proxy_workload(agent_ns, IDENTITY_PROXY_NAME, IDENTITY_PROXY_LABELS,
                          hashlib.sha256(routes_json.encode()).hexdigest()[:16], pod_spec,
                          sorted(routes) or [IDENTITY_PROXY_PORT_BASE], logger)
    logger.info(f"Applied identity proxy ({len(routes)} route(s)) in '{agent_ns}'")


def _apply_web_fetch_proxy(agent_ns, allowlist, logger):
    """Per-agent forward proxy enforcing spec.webFetchAllowlist (empty = deny all)."""
    if not WEB_FETCH_PROXY_ENABLED:
        return
    c = kubernetes.client
    core = c.CoreV1Api()
    cm_name = f"{WEB_FETCH_PROXY_NAME}-allowlist"
    cm = c.V1ConfigMap(
        metadata=c.V1ObjectMeta(name=cm_name, namespace=agent_ns, labels=WEB_FETCH_PROXY_LABELS),
        data={"allowlist.json": json.dumps(sorted(set(allowlist or [])))})
    if not _apply(core.create_namespaced_config_map, core.replace_namespaced_config_map,
                  cm_name, agent_ns, cm, logger, "web-fetch-proxy ConfigMap"):
        return
    env = [c.V1EnvVar(name="PORT", value=str(WEB_FETCH_PROXY_PORT)),
           c.V1EnvVar(name="ALLOWLIST_PATH", value="/etc/web-fetch-proxy/allowlist.json")]
    for key, value in (("HTTP_PROXY", WEB_FETCH_PROXY_HTTP_PROXY),
                       ("HTTPS_PROXY", WEB_FETCH_PROXY_HTTPS_PROXY),
                       ("NO_PROXY", WEB_FETCH_PROXY_NO_PROXY)):
        if value:
            env += [c.V1EnvVar(name=key, value=value), c.V1EnvVar(name=key.lower(), value=value)]
    pod_spec = _proxy_pod_spec("web_fetch_proxy.py", cm_name, "/etc/web-fetch-proxy", env,
                               [WEB_FETCH_PROXY_PORT])
    # The allowlist is re-read per request, so its edits never roll the pod.
    _apply_proxy_workload(agent_ns, WEB_FETCH_PROXY_NAME, WEB_FETCH_PROXY_LABELS, "static",
                          pod_spec, [WEB_FETCH_PROXY_PORT], logger)
    _apply_web_fetch_proxy_egress(agent_ns, logger)


def _resolver_ip_blocks():
    """Link-local/loopback nameservers (e.g. nodelocaldns), which no podSelector matches."""
    import ipaddress
    ips = set()
    try:
        with open("/etc/resolv.conf") as fh:
            for fields in (line.split() for line in fh):
                if len(fields) >= 2 and fields[0] == "nameserver":
                    try:
                        addr = ipaddress.ip_address(fields[1])
                    except ValueError:
                        continue
                    if addr.version == 4 and (addr.is_link_local or addr.is_loopback):
                        ips.add(str(addr))
    except OSError:
        pass
    return sorted(ips)


def _dns_egress_rule():
    c = kubernetes.client
    peers = [c.V1NetworkPolicyPeer(
        namespace_selector=c.V1LabelSelector(match_labels={"kubernetes.io/metadata.name": "kube-system"}),
        pod_selector=c.V1LabelSelector(match_labels={"k8s-app": "kube-dns"}))]
    peers += [c.V1NetworkPolicyPeer(ip_block=c.V1IPBlock(cidr=f"{ip}/32")) for ip in _resolver_ip_blocks()]
    return c.V1NetworkPolicyEgressRule(
        to=peers, ports=[c.V1NetworkPolicyPort(protocol=p, port=53) for p in ("UDP", "TCP")])


_NON_PUBLIC_V4 = ["10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                  "192.168.0.0/16"]


def _corporate_proxy_ports():
    """Ports of the configured corporate proxies; their names may resolve to rotating addresses."""
    from urllib.parse import urlsplit
    return sorted({urlsplit(raw if "://" in raw else f"http://{raw}").port or 80
                   for raw in (WEB_FETCH_PROXY_HTTP_PROXY, WEB_FETCH_PROXY_HTTPS_PROXY) if raw})


def _put_network_policy(ns, name, spec, logger, labels=None):
    net = kubernetes.client.NetworkingV1Api()
    policy = kubernetes.client.V1NetworkPolicy(
        metadata=kubernetes.client.V1ObjectMeta(name=name, namespace=ns, labels=labels or MANAGED_BY),
        spec=spec)
    return _apply(net.create_namespaced_network_policy, net.replace_namespaced_network_policy,
                  name, ns, policy, logger, f"NetworkPolicy {name}")


def _apply_web_fetch_proxy_egress(agent_ns, logger):
    """Internet egress for the web_fetch proxy pod alone: the corporate proxy, else public HTTP(S)."""
    if not NETWORK_POLICY_ENABLED:
        return
    c = kubernetes.client
    proxy_ports = _corporate_proxy_ports()
    if proxy_ports:
        # This pod dials only its configured proxy, so the port is the boundary.
        rule = c.V1NetworkPolicyEgressRule(
            to=[c.V1NetworkPolicyPeer(ip_block=c.V1IPBlock(cidr="0.0.0.0/0"))],
            ports=[c.V1NetworkPolicyPort(protocol="TCP", port=p) for p in proxy_ports])
    else:
        rule = c.V1NetworkPolicyEgressRule(
            to=[c.V1NetworkPolicyPeer(ip_block=c.V1IPBlock(cidr="0.0.0.0/0", _except=_NON_PUBLIC_V4))],
            ports=[c.V1NetworkPolicyPort(protocol="TCP", port=p) for p in (80, 443)])
    _put_network_policy(agent_ns, f"{WEB_FETCH_PROXY_NAME}-egress", c.V1NetworkPolicySpec(
        pod_selector=c.V1LabelSelector(match_labels=WEB_FETCH_PROXY_LABELS),
        policy_types=["Egress"], egress=[_dns_egress_rule(), rule]), logger, WEB_FETCH_PROXY_LABELS)


def _ns_peers_and_ports(entry):
    c = kubernetes.client
    peer = c.V1NetworkPolicyPeer(
        namespace_selector=c.V1LabelSelector(match_labels={"kubernetes.io/metadata.name": entry["namespace"]}),
        pod_selector=c.V1LabelSelector(match_labels=entry["podSelector"]) if entry.get("podSelector") else None)
    return [peer], [c.V1NetworkPolicyPort(protocol="TCP", port=int(p)) for p in entry.get("ports", [])] or None


def _egress_ns_rules(entries):
    """Egress rules from [{namespace, ports, podSelector?}]."""
    rules = []
    for entry in (e for e in entries if e.get("namespace")):
        peers, ports = _ns_peers_and_ports(entry)
        rules.append(kubernetes.client.V1NetworkPolicyEgressRule(to=peers, ports=ports))
    return rules


def _ingress_ns_rules(entries):
    """Ingress rules from [{namespace, ports, podSelector?}]."""
    rules = []
    for entry in (e for e in entries if e.get("namespace")):
        peers, ports = _ns_peers_and_ports(entry)
        rules.append(kubernetes.client.V1NetworkPolicyIngressRule(_from=peers, ports=ports))
    return rules


def _local_ports(port, end_port=None):
    """Ports for in-namespace egress; the ambient mesh carries it as HBONE on 15008."""
    c = kubernetes.client
    if MESH_AMBIENT:
        return [c.V1NetworkPolicyPort(protocol="TCP", port=15008)]
    return [c.V1NetworkPolicyPort(protocol="TCP", port=port, end_port=end_port)]


def _apply_network_policy(agent_ns, logger):
    """Default-deny for the agent namespace: same-namespace ingress, allowlisted egress."""
    if not NETWORK_POLICY_ENABLED:
        return
    c = kubernetes.client
    egress = [_dns_egress_rule()]
    if WEB_FETCH_PROXY_ENABLED:
        egress.append(c.V1NetworkPolicyEgressRule(
            to=[c.V1NetworkPolicyPeer(pod_selector=c.V1LabelSelector(match_labels=WEB_FETCH_PROXY_LABELS))],
            ports=_local_ports(WEB_FETCH_PROXY_PORT)))
    egress.append(c.V1NetworkPolicyEgressRule(
        to=[c.V1NetworkPolicyPeer(pod_selector=c.V1LabelSelector(match_labels=IDENTITY_PROXY_LABELS))],
        ports=_local_ports(IDENTITY_PROXY_PORT_BASE, IDENTITY_PROXY_PORT_BASE + IDENTITY_PROXY_PORT_SPAN - 1)))
    egress += _egress_ns_rules(NETWORK_POLICY_EGRESS_ALLOW)
    ingress = [c.V1NetworkPolicyIngressRule(_from=[c.V1NetworkPolicyPeer(
        namespace_selector=c.V1LabelSelector(match_labels={"kubernetes.io/metadata.name": agent_ns}))])]
    ingress += _ingress_ns_rules(NETWORK_POLICY_INGRESS_ALLOW)
    if _put_network_policy(agent_ns, "agent-default-deny", c.V1NetworkPolicySpec(
            pod_selector=c.V1LabelSelector(), policy_types=["Ingress", "Egress"],
            ingress=ingress, egress=egress), logger):
        logger.info(f"Applied NetworkPolicy (default-deny + allowlist) in '{agent_ns}'")
    # Separate object: NetworkPolicy is additive, so MCP egress cannot be withheld
    # from the agent pod inside the namespace-wide policy above.
    _put_network_policy(agent_ns, "identity-proxy-egress", c.V1NetworkPolicySpec(
        pod_selector=c.V1LabelSelector(match_labels=IDENTITY_PROXY_LABELS),
        policy_types=["Egress"], egress=_egress_ns_rules(NETWORK_POLICY_IDENTITY_EGRESS_ALLOW)),
        logger)


def _apply_resource_quota(agent_ns, logger):
    c = kubernetes.client
    api = c.CoreV1Api()
    if RESOURCE_QUOTA_ENABLED and RESOURCE_QUOTA_HARD:
        _apply(api.create_namespaced_resource_quota, api.replace_namespaced_resource_quota,
               "agent-quota", agent_ns, c.V1ResourceQuota(
                   metadata=c.V1ObjectMeta(name="agent-quota", namespace=agent_ns, labels=MANAGED_BY),
                   spec=c.V1ResourceQuotaSpec(hard={k: str(v) for k, v in RESOURCE_QUOTA_HARD.items()})),
               logger, "ResourceQuota")
    if LIMIT_RANGE_ENABLED and (LIMIT_RANGE_DEFAULT or LIMIT_RANGE_DEFAULT_REQUEST):
        _apply(api.create_namespaced_limit_range, api.replace_namespaced_limit_range,
               "agent-limits", agent_ns, c.V1LimitRange(
                   metadata=c.V1ObjectMeta(name="agent-limits", namespace=agent_ns, labels=MANAGED_BY),
                   spec=c.V1LimitRangeSpec(limits=[c.V1LimitRangeItem(
                       type="Container",
                       default={k: str(v) for k, v in LIMIT_RANGE_DEFAULT.items()} or None,
                       default_request={k: str(v) for k, v in LIMIT_RANGE_DEFAULT_REQUEST.items()} or None)])),
               logger, "LimitRange")


def _owner_agent_count(owner):
    objs = kubernetes.client.CustomObjectsApi().list_cluster_custom_object(
        group=API_GROUP, version=API_VERSION, plural=AGENT_PLURAL)
    return sum(1 for o in objs.get("items", [])
               if o.get("spec", {}).get("owner", {}).get("principal") == owner)


def _create_gateway_secret(agent_name, agent_ns, logger):
    """Random gateway token; never re-minted, the running pod already holds it."""
    secret = kubernetes.client.V1Secret(
        metadata=kubernetes.client.V1ObjectMeta(name=f"{agent_name}-gateway-token", namespace=agent_ns),
        string_data={"token": secrets.token_hex(24)})
    try:
        kubernetes.client.CoreV1Api().create_namespaced_secret(agent_ns, secret)
        logger.info(f"Created gateway secret for '{agent_name}'")
    except kubernetes.client.ApiException as e:
        if e.status != 409:
            raise


def _delete_secret(name, ns):
    try:
        kubernetes.client.CoreV1Api().delete_namespaced_secret(name, ns)
    except kubernetes.client.ApiException:
        pass


def _delete_namespace(ns, logger):
    try:
        kubernetes.client.CoreV1Api().delete_namespace(ns)
        logger.info(f"Deleted namespace '{ns}'")
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            logger.warning(f"Failed to delete namespace '{ns}': {e}")


def _delete_agent_namespace(ns, agent_name, logger):
    """Delete the agent namespace only if this operator created it for this agent."""
    try:
        labels = kubernetes.client.CoreV1Api().read_namespace(ns).metadata.labels or {}
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            logger.warning(f"Cannot read namespace '{ns}': {e}")
        return
    if labels.get("app.kubernetes.io/managed-by") != MANAGED_BY["app.kubernetes.io/managed-by"] \
            or labels.get(AGENT_LABEL) != agent_name:
        logger.warning(f"Namespace '{ns}' is not this agent's — leaving it")
        return
    _delete_namespace(ns, logger)


def _reap_owner_namespace(ns, exclude, logger):
    """Delete an owner namespace (labelled owner-namespace=true) once its last Agent is gone."""
    try:
        meta = kubernetes.client.CoreV1Api().read_namespace(ns).metadata
    except kubernetes.client.ApiException as e:
        if e.status != 404:
            logger.warning(f"Owner-namespace reap: cannot read '{ns}': {e}")
        return
    if (meta.labels or {}).get(OWNER_NAMESPACE_LABEL) != "true" or meta.deletion_timestamp:
        return
    try:
        agents = kubernetes.client.CustomObjectsApi().list_namespaced_custom_object(
            group=API_GROUP, version=API_VERSION, namespace=ns, plural=AGENT_PLURAL).get("items", [])
    except Exception as e:
        logger.warning(f"Owner-namespace reap: cannot list agents in '{ns}': {e}")
        return
    if any(a.get("metadata", {}).get("name") != exclude for a in agents):
        return
    logger.info(f"Owner namespace '{ns}' is empty — reaping")
    _delete_namespace(ns, logger)


# ── Code-execution sandboxes ─────────────────────────────────────────────────
def _sandbox_session_hash(agent_name, spec):
    """mcp-sandbox-server's session label: sha256 of the client id (the token's azp), 32 hex."""
    return hashlib.sha256(_kc_client_id(agent_name, spec).encode()).hexdigest()[:32]


def _reap_agent_sandboxes(name, spec, logger, reason):
    """Delete the agent's SandboxClaims; quiet where agent-sandbox or the grant is absent."""
    try:
        selector = (f"{SANDBOX_OWNER_LABEL}={SANDBOX_OWNER_LABEL_VALUE},"
                    f"{SANDBOX_SESSION_LABEL}={_sandbox_session_hash(name, spec)}")
    except ValueError:
        return 0
    api = kubernetes.client.CustomObjectsApi()
    kw = dict(group=SANDBOX_CLAIM_GROUP, version=SANDBOX_CLAIM_VERSION,
              namespace=SANDBOX_NAMESPACE, plural=SANDBOX_CLAIM_PLURAL)
    try:
        claims = api.list_namespaced_custom_object(label_selector=selector, **kw).get("items", [])
    except kubernetes.client.ApiException as e:
        if e.status not in (403, 404):
            logger.warning(f"Sandbox reap for '{name}': cannot list claims: {e}")
        return 0
    except Exception as e:
        logger.warning(f"Sandbox reap for '{name}': cannot list claims: {e}")
        return 0
    reaped = 0
    for claim_name in filter(None, ((c.get("metadata") or {}).get("name") for c in claims)):
        try:
            api.delete_namespaced_custom_object(name=claim_name, **kw)
            reaped += 1
            logger.info(f"Deleted sandbox claim '{claim_name}' for agent '{name}' ({reason})")
        except kubernetes.client.ApiException as e:
            if e.status != 404:
                logger.warning(f"Could not delete sandbox claim '{claim_name}': {e}")
        except Exception as e:
            logger.warning(f"Could not delete sandbox claim '{claim_name}': {e}")
    return reaped


# ── Keycloak (per-agent identity) ────────────────────────────────────────────
def _kc_headers(logger):
    """Admin headers from a client_credentials token, or None."""
    import requests
    try:
        resp = requests.post(
            f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
            data={"grant_type": "client_credentials", "client_id": KEYCLOAK_CLIENT_ID,
                  "client_secret": KEYCLOAK_CLIENT_SECRET}, timeout=10)
    except Exception as e:
        logger.warning(f"Keycloak unreachable: {e}")
        return None
    if resp.status_code != 200:
        # Keycloak never echoes the credential, so the body is safe to log.
        logger.warning(f"Keycloak login failed: {resp.status_code} {resp.text[:100]}")
        return None
    return {"Authorization": f"Bearer {resp.json().get('access_token')}",
            "Content-Type": "application/json"}


def _clients_url():
    return f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/clients"


def _find_kc_client(client_id, headers, logger):
    import requests
    try:
        resp = requests.get(_clients_url(), params={"clientId": client_id}, headers=headers, timeout=10)
        return (resp.json() or [None])[0] if resp.status_code == 200 else None
    except Exception as e:
        logger.warning(f"Could not look up Keycloak client '{client_id}': {e}")
        return None


def _ensure_realm_client_scopes(headers, logger):
    """Create the audience and permission client scopes; return {name: id} ({} on failure)."""
    import requests
    url = f"{KEYCLOAK_URL}/admin/realms/{KEYCLOAK_REALM}/client-scopes"

    def _list():
        resp = requests.get(url, headers=headers, timeout=10)
        resp.raise_for_status()
        return {s.get("name"): s.get("id") for s in resp.json()}

    try:
        by_name = _list()
    except Exception as e:
        logger.warning(f"Could not list client scopes: {e}")
        return {}
    for name in [*MCP_AUDIENCES, *PERMISSION_SCOPES]:
        if name in by_name:
            continue
        body = {"name": name, "protocol": "openid-connect",
                "description": "MCP server audience" if name in MCP_AUDIENCES else "MCP operation permission",
                # The scope name lands in the token's `scope` claim, which the MCP servers check.
                "attributes": {"include.in.token.scope": "true", "display.on.consent.screen": "false"}}
        try:
            r = requests.post(url, json=body, headers=headers, timeout=10)
            if r.status_code not in (200, 201, 409):
                logger.warning(f"Could not create client scope '{name}': {r.status_code} {r.text[:100]}")
                continue
            by_name = _list()
            if name in MCP_AUDIENCES and by_name.get(name):
                # The audience lives on the scope, so requesting the scope adds it.
                requests.post(f"{url}/{by_name[name]}/protocol-mappers/models", json={
                    "name": f"mcp-audience-{name}", "protocol": "openid-connect",
                    "protocolMapper": "oidc-audience-mapper",
                    "config": {"included.custom.audience": name, "access.token.claim": "true",
                               "id.token.claim": "false"}}, headers=headers, timeout=10)
            logger.info(f"Created Keycloak client scope '{name}'")
        except Exception as e:
            logger.warning(f"Could not create client scope '{name}': {e}")
    return by_name


def _granted_permission_scopes(spec):
    """Every permission scope except one whose covered tools are all in spec.toolsDeny."""
    denies = [d for d in (spec.get("toolsDeny") or []) if isinstance(d, str)]

    def denied(tool):
        # Bare MCP name, OpenClaw's `<server>__<tool>` form, or a glob of either.
        return any(d == tool or d.endswith(f"__{tool}") or fnmatch.fnmatch(tool, d)
                   or fnmatch.fnmatch(f"x__{tool}", d) for d in denies)

    return [s for s, tools in PERMISSION_SCOPES.items() if not all(denied(t) for t in tools)]


def _ensure_kc_client_scopes(client_uuid, headers, client_id, spec, logger):
    """Audiences OPTIONAL (requested per call), permissions DEFAULT; revoked scopes are removed."""
    import requests
    realm_scopes = _ensure_realm_client_scopes(headers, logger)
    if not realm_scopes:
        return
    granted = set(_granted_permission_scopes(spec))
    base = f"{_clients_url()}/{client_uuid}"

    def assign(kind, name, add):
        scope_id = realm_scopes.get(name)
        if not scope_id:
            return
        try:
            r = (requests.put if add else requests.delete)(
                f"{base}/{kind}-client-scopes/{scope_id}", headers=headers, timeout=10)
            if r.status_code not in (200, 204, 404):
                logger.warning(f"Could not set {kind} scope '{name}' on '{client_id}': "
                               f"{r.status_code} {r.text[:100]}")
        except Exception as e:
            logger.warning(f"Could not set {kind} scope '{name}' on '{client_id}': {e}")

    for aud in MCP_AUDIENCES:
        assign("optional", aud, True)
    for name in PERMISSION_SCOPES:
        assign("default", name, name in granted)


def _reconcile_kc_audiences(agent_name, spec, logger):
    """Bring an existing client's scopes up to date (suspended agents, toolsDeny edits)."""
    headers = _kc_headers(logger)
    client = headers and _find_kc_client(_kc_client_id(agent_name, spec), headers, logger)
    if client:
        _ensure_kc_client_scopes(client["id"], headers, client["clientId"], spec, logger)


def _reconcile_proxy_images(agent_name, spec, logger):
    """Move a suspended agent's proxies to the current image; nothing else changes."""
    agent_ns = _agent_ns(agent_name, spec)
    apps = kubernetes.client.AppsV1Api()
    for name in (IDENTITY_PROXY_NAME, WEB_FETCH_PROXY_NAME):
        try:
            dep = apps.read_namespaced_deployment(name, agent_ns)
        except kubernetes.client.ApiException:
            continue
        container = dep.spec.template.spec.containers[0]
        if container.image == PROXY_IMAGE:
            continue
        container.image = PROXY_IMAGE
        try:
            apps.replace_namespaced_deployment(name, agent_ns, dep)
            logger.info(f"{name} image updated for suspended agent '{agent_name}'")
        except kubernetes.client.ApiException as e:
            logger.warning(f"{name} image update failed in '{agent_ns}': {e}")


def _hardcoded_claim(name, value):
    return {"name": name.replace("_", "-"), "protocol": "openid-connect",
            "protocolMapper": "oidc-hardcoded-claim-mapper",
            "config": {"claim.name": name, "claim.value": value, "jsonType.label": "String",
                       "access.token.claim": "true", "id.token.claim": "false",
                       "userinfo.token.claim": "false"}}


def _provision_keycloak_client(agent_name, agent_ns, owner, logger, spec):
    """Create (or adopt, if owned by `owner`) the agent's client and store its credentials."""
    import requests
    headers = _kc_headers(logger)
    if not headers:
        return False
    client_id = _kc_client_id(agent_name, spec)
    # Consumers read these claims; they never parse the client id.
    body = {"clientId": client_id, "enabled": True, "publicClient": False,
            "serviceAccountsEnabled": True, "standardFlowEnabled": False,
            "directAccessGrantsEnabled": False, "clientAuthenticatorType": "client-secret",
            "protocol": "openid-connect",
            "attributes": {"agent.owner": owner, "agent.name": agent_name},
            "protocolMappers": [_hardcoded_claim("agent_name", agent_name),
                                _hardcoded_claim("memory_schema", _memory_schema(agent_name, spec))]}
    resp = requests.post(_clients_url(), json=body, headers=headers, timeout=10)
    if resp.status_code not in (200, 201, 409):
        logger.warning(f"Failed to create Keycloak client: {resp.status_code} {resp.text[:100]}")
        return False
    client = _find_kc_client(client_id, headers, logger)
    if not client:
        return False
    # Never hand out a client someone else owns; an unknown owner refuses too.
    existing_owner = (client.get("attributes") or {}).get("agent.owner")
    if existing_owner != owner:
        logger.error(f"REFUSING Keycloak client '{client_id}': owned by "
                     f"'{existing_owner or '<unset>'}', requested by '{owner}'")
        return False
    _ensure_kc_client_scopes(client["id"], headers, client_id, spec, logger)
    resp = requests.get(f"{_clients_url()}/{client['id']}/client-secret", headers=headers, timeout=10)
    if resp.status_code != 200:
        logger.warning("Failed to retrieve client secret")
        return False
    secret = kubernetes.client.V1Secret(
        metadata=kubernetes.client.V1ObjectMeta(
            name=f"{agent_name}-keycloak-credentials", namespace=agent_ns,
            labels={AGENT_LABEL: agent_name}),
        string_data={
            "client_id": client_id,
            "client_secret": resp.json().get("value", ""),
            "token_endpoint": f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
            "owner": owner,
        })
    try:
        kubernetes.client.CoreV1Api().create_namespaced_secret(agent_ns, secret)
        logger.info(f"Stored Keycloak credentials for '{agent_name}'")
    except kubernetes.client.ApiException as e:
        if e.status != 409:
            raise
    return True


def _delete_keycloak_client(agent_name, logger, spec):
    import requests
    headers = _kc_headers(logger)
    client = headers and _find_kc_client(_kc_client_id(agent_name, spec), headers, logger)
    if not client:
        return
    resp = requests.delete(f"{_clients_url()}/{client['id']}", headers=headers, timeout=10)
    if resp.status_code in (200, 204):
        logger.info(f"Deleted Keycloak client '{client['clientId']}'")
    else:
        logger.warning(f"Failed to delete Keycloak client: {resp.status_code}")
