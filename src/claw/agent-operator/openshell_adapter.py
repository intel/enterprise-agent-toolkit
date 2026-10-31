# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""openshell runtime: OpenClaw in an NVIDIA OpenShell sandbox, in the agent's own namespace.

The agent namespace is also the agent's OpenShell workspace (operator workspace mode), so
the sandbox's workload and supervisor pods live beside its identity proxy. The agent process
runs in the workload pod, which reaches only its supervisor; every connection it opens is
checked against the policy rendered here, and the model key stays in the gateway (the pod
sees a placeholder). OpenClaw serves on loopback; users reach it through the gateway's
service route, which only the platform gateway may call (openshell-gateway-ingress).
"""
import base64
import json
import os
import pathlib
import urllib.error
import urllib.parse
import urllib.request

import claw_adapter

WORKSPACE = "/sandbox/.openclaw/workspace"
CONFIG_PATH = "/sandbox/.openclaw/openclaw.json"
SERVICE_NAME = "openclaw"
SERVICE_PORT = 18789
# Workspace names become part of service hostnames; OpenShell rejects longer ones.
MAX_WORKSPACE_NAME = 19
# The objects of the openshell-workspace chart, created per agent namespace.
SANDBOX_SA = "openshell-sandbox"
WORKSPACE_BINDING = "openshell-workspace-sandbox"
WORKSPACE_SSH_POLICY = "openshell-workspace-sandbox-ssh"
# Read-only system paths and the two writable ones; fixed when the sandbox is created.
READ_ONLY_PATHS = ["/usr", "/lib", "/proc", "/dev/urandom", "/app", "/etc", "/var/log"]
READ_WRITE_PATHS = ["/sandbox", "/tmp", "/dev/null"]  # nosec B108: sandbox-local tmp
NODE = "/usr/local/bin/node"
PYPI_HOSTS = ["pypi.org", "files.pythonhosted.org"]
# The image's interpreter; `*` within a segment is the only glob OpenShell 0.1.x accepts.
PYTHON = "/usr/bin/python3*"
# In the ambient mesh: ztunnel's DNS proxy answers the sandbox runtime's DNS self-check in a way
# it rejects, so the workload pod opts out of DNS capture (the gateway allowlists this key), and
# the mesh carries workload <-> supervisor traffic on its tunnel port, which OpenShell's own
# NetworkPolicies (port 5500 only) do not allow.
DNS_CAPTURE_ANNOTATION = "ambient.istio.io/dns-capture"
MESH_TUNNEL_PORT = 15008
MESH_POLICY = "openshell-sandbox-mesh"
# The two model gateways an openshell agent may use. genai-gateway (LiteLLM) holds budgets and the
# content-safety guardrail; its key is injected by the workspace's provider. ai-gateway (Envoy AI
# Gateway) needs no key in-cluster and is reached directly, when the cluster enables it.
AI_GATEWAY_PROVIDER = "ai-gateway"
NO_KEY = claw_adapter.NO_KEY
# Code runs with OpenClaw's own exec in the sandboxed pod, so the sandbox MCP is not wired.
EXCLUDED_SKILLS = {"sandbox"}
# The config is written once from the environment; later edits arrive as a file and a restart.
START_COMMAND = (
    'mkdir -p "$(dirname "$OC_CONFIG")" '
    '&& { [ -s "$OC_CONFIG" ] || printf %s "$OC_CONFIG_B64" | base64 -d > "$OC_CONFIG"; } '
    '&& cd /app && exec node openclaw.mjs gateway --port ' + str(SERVICE_PORT))


def config_from_env(env=None):
    """Adapter configuration, from the operator container's environment."""
    env = os.environ if env is None else env
    cfg = claw_adapter.config_from_env(env)
    cfg["openshell"] = {
        "endpoint": env.get("OPENSHELL_ENDPOINT", "openshell.openshell-system.svc.cluster.local:8080"),
        # ca.crt, tls.crt and tls.key of the gateway's client certificate (openshell-client-tls).
        "tlsDir": env.get("OPENSHELL_TLS_DIR", "/etc/openshell-tls"),
        "gatewayNamespace": env.get("OPENSHELL_NAMESPACE", "openshell-system"),
        "gatewayServiceAccount": env.get("OPENSHELL_SERVICE_ACCOUNT", "openshell"),
        # The chart's ClusterRole with the workspace chart's Role rules, bound per namespace.
        "workspaceClusterRole": env.get("OPENSHELL_WORKSPACE_CLUSTER_ROLE", "agent-operator-openshell-workspace"),
        "gatewayPodLabels": {"app.kubernetes.io/name": "openshell",
                             "app.kubernetes.io/instance": env.get("OPENSHELL_RELEASE_NAME", "openshell")},
        "workspaceLabel": env.get("OPENSHELL_WORKSPACE_LABEL", "openshell.ai/workspace=eat"),
        "image": env.get("OPENSHELL_SANDBOX_IMAGE", ""),
        "providerName": env.get("OPENSHELL_PROVIDER_NAME", "genai-gateway"),
        "providerType": env.get("OPENSHELL_PROVIDER_TYPE", "eat-genai-gateway"),
        # The cluster key, from Secret <namespace>/<name>, key <key>.
        "modelKeySecret": env.get("OPENSHELL_MODEL_KEY_SECRET", "openshell-system/openshell-genai-key/api_key"),
        # A LiteLLM key that may manage users and keys (not call models). Set, every openshell agent
        # gets its own key, owned by its user in LiteLLM, so usage is tracked per agent and per user;
        # empty keeps the shared cluster key above.
        "litellmAdminKey": env.get("LITELLM_ADMIN_KEY", ""),
        # Optional limits per agent key and per user (tokens and requests per minute; 0 = none).
        # LiteLLM counts tokens without model prices; its dollar budgets need prices set.
        "agentTpmLimit": claw_adapter._int(env.get("OPENSHELL_AGENT_TPM_LIMIT"), 0),
        "agentRpmLimit": claw_adapter._int(env.get("OPENSHELL_AGENT_RPM_LIMIT"), 0),
        "userTpmLimit": claw_adapter._int(env.get("OPENSHELL_USER_TPM_LIMIT"), 0),
        "userRpmLimit": claw_adapter._int(env.get("OPENSHELL_USER_RPM_LIMIT"), 0),
        # The provider profile's endpoint: the only model host the supervisor injects a key for.
        "modelBaseUrl": env.get("OPENSHELL_MODEL_BASE_URL", ""),
        # The Envoy AI Gateway's URL; empty leaves openshell agents on genai-gateway only.
        "aiGatewayUrl": env.get("OPENSHELL_AI_GATEWAY_URL", ""),
        "serviceDomain": env.get("OPENSHELL_SERVICE_DOMAIN", "openshell.localhost"),
        "pypi": claw_adapter._bool(env.get("OPENSHELL_PYPI_ENABLED"), True),
    }
    return cfg


def service_host(workspace, sandbox, domain="openshell.localhost"):
    """Host the gateway routes to the sandbox's OpenClaw service."""
    return f"{workspace}--{sandbox}--{SERVICE_NAME}.{domain}"


def _status(error):
    """The gRPC status name of a gateway error (the SDK raises grpc.RpcError subclasses)."""
    code = getattr(error, "code", None)
    try:
        return code().name if callable(code) else ""
    except Exception:
        return ""


def _endpoint(host, port, protocol=""):
    ep = {"host": host, "port": int(port)}
    if protocol:
        ep.update(protocol=protocol, access="NETWORK_ACCESS_PRESET_READ_WRITE",
                  enforcement="NETWORK_ENFORCEMENT_MODE_ENFORCE")
    return ep


def _web_hosts(allowlist, logger):
    """spec.webFetchAllowlist as policy hosts: each domain and its subdomains.

    "*" (any site) is not granted: a policy can name any host only by IP range, and that range
    would include the cluster's own private addresses."""
    hosts = []
    for entry in allowlist or []:
        domain = str(entry).strip().lower()
        if domain == "*":
            logger.warning("webFetchAllowlist '*' is not supported by the openshell runtime; list domains")
            continue
        if domain:
            hosts.append(domain)
            # A wildcard needs at least three labels.
            if domain.count(".") >= 1:
                hosts.append(f"*.{domain}")
    return hosts


def _url_endpoint(url):
    u = urllib.parse.urlsplit(url)
    if not u.hostname:
        return None
    return _endpoint(u.hostname, u.port or (443 if u.scheme == "https" else 80))


class OpenShellAdapter(claw_adapter.ClawAdapter):
    """Same model, tool and identity wiring as the claw runtime; a different workload."""

    def __init__(self, core, config, client_factory=None, litellm=None, fetch_json=None):
        super().__init__(core, config)
        self.os_cfg = config["openshell"]
        self._litellm_call = litellm or self._litellm_http
        self._fetch_json = fetch_json or self._get_json
        self._sizes = {}  # model: (looked up at, served context size or None)
        self.mesh_ambient = bool(getattr(core, "mesh_ambient", False))
        self._client_factory = client_factory or self._connect
        self._client = None

    # ── Gateway connection ───────────────────────────────────────────────────
    def _connect(self):
        from openshell import SandboxClient, TlsConfig  # noqa: PLC0415
        tls_dir = pathlib.Path(self.os_cfg["tlsDir"])
        # Deleting a sandbox waits for its pods to stop, which can take longer than the 30 s default.
        return SandboxClient(self.os_cfg["endpoint"], timeout=120, tls=TlsConfig(
            ca_path=tls_dir / "ca.crt", cert_path=tls_dir / "tls.crt", key_path=tls_dir / "tls.key"))

    @property
    def client(self):
        if self._client is None:
            self._client = self._client_factory()
        return self._client

    def _rpc(self, method, request):
        """A gateway RPC the SDK does not wrap; AlreadyExists counts as done."""
        try:
            return getattr(self.client._stub, method)(request, timeout=30)
        except Exception as e:
            if _status(e) == "ALREADY_EXISTS":
                return None
            raise

    @staticmethod
    def _pb():
        from openshell._proto import datamodel_pb2, openshell_pb2  # noqa: PLC0415
        return openshell_pb2, datamodel_pb2

    # ── Adapter interface ────────────────────────────────────────────────────
    def create(self, ctx):
        if len(ctx.namespace) > MAX_WORKSPACE_NAME:
            raise ValueError(f"namespace '{ctx.namespace}' is longer than {MAX_WORKSPACE_NAME} characters")
        self._ensure_workspace(ctx)
        self._ensure_provider(ctx)
        _, routes = self._mcp_wiring(ctx)
        # The proxy must serve the ports before the agent is told to call them.
        self.core.apply_identity_proxy(ctx.name, ctx.namespace, routes, ctx.logger,
                                       tool_credentials=self._tool_credentials(ctx))
        try:
            ref = self.client.get(ctx.name, workspace=ctx.namespace)
            ctx.logger.info(f"OpenShell sandbox '{ctx.name}' exists (phase {ref.phase})")
        except Exception as e:
            if _status(e) != "NOT_FOUND":
                raise
            self._create_sandbox(ctx)
        # Only the fields status.backendRef has; the workspace is the agent namespace.
        return {"apiVersion": "openshell.ai/v1", "kind": "Sandbox", "name": ctx.name}

    def update(self, ctx, reseed=True):
        """Network policy and config follow the spec; the filesystem policy is fixed at create."""
        _, routes = self._mcp_wiring(ctx)
        self.core.apply_identity_proxy(ctx.name, ctx.namespace, routes, ctx.logger,
                                       tool_credentials=self._tool_credentials(ctx))
        self.update_policy(ctx)
        self._write(ctx, CONFIG_PATH, self._config_json(ctx))
        # The supervisor restarts the main process (restart policy always) with the new file. The
        # bracket keeps pkill -f from matching this shell's own command line, which would kill it.
        self._exec(ctx, ["sh", "-c", "pkill -f '[o]penclaw-gateway' || true"])
        if reseed and ctx.workspace_files:
            self.client.wait_ready(ctx.name, workspace=ctx.namespace)
            self._seed_files(ctx, ctx.workspace_files)

    def update_policy(self, ctx):
        _, routes = self._mcp_wiring(ctx)
        pb, _ = self._pb()
        self._rpc("UpdateConfig", pb.UpdateConfigRequest(
            workspace_scope=self._scope(ctx), sandbox=ctx.name, policy=self._policy(ctx, routes)))
        ctx.logger.info(f"Updated OpenShell policy of '{ctx.name}'")

    def post_create(self, ctx):
        if ctx.workspace_files:
            self.client.wait_ready(ctx.name, workspace=ctx.namespace)
            self._seed_files(ctx, ctx.workspace_files)

    def suspend(self, ctx):
        try:
            self.client.suspend(ctx.name, workspace=ctx.namespace)
        except Exception as e:
            # Drivers without suspend: a stopped sandbox keeps its workspace volume.
            ctx.logger.info(f"Suspend of '{ctx.name}' unavailable ({e}); stopping it")
            self.client.stop(ctx.name, workspace=ctx.namespace)

    def resume(self, ctx):
        try:
            self.client.resume(ctx.name, workspace=ctx.namespace, restart_if_restore_fails=True)
        except Exception as e:
            ctx.logger.info(f"Resume of '{ctx.name}' unavailable ({e}); starting it")
            self.client.start(ctx.name, workspace=ctx.namespace)
        self.client.wait_ready(ctx.name, workspace=ctx.namespace)

    def delete(self, ctx):
        """Sandbox, provider and workspace record; the operator deletes the namespace."""
        pb, _ = self._pb()
        steps = (
            ("sandbox", lambda: self.client.delete(ctx.name, workspace=ctx.namespace, allow_missing=True)),
            ("provider", lambda: self._rpc("DeleteProvider", pb.DeleteProviderRequest(
                workspace_scope=self._scope(ctx), name=self.os_cfg["providerName"], allow_missing=True))),
            ("workspace", lambda: self._workspaces().delete(ctx.namespace, allow_missing=True)),
            # The agent's LiteLLM key; its user and their usage history stay.
            *((("LiteLLM key", lambda: self._litellm_call("/key/delete", {"key_aliases": [ctx.namespace]})),)
              if self.os_cfg["litellmAdminKey"] else ()),
        )
        for what, step in steps:
            try:
                step()
            except Exception as e:
                ctx.logger.warning(f"OpenShell {what} delete for '{ctx.name}' failed: {e}")

    def ready(self, ctx):
        try:
            ref = self.client.get(ctx.name, workspace=ctx.namespace)
        except Exception:
            return False
        return any(c.type == "Ready" and c.status == "True" for c in ref.conditions)

    # ── Workspace ────────────────────────────────────────────────────────────
    def _scope(self, ctx):
        _, dm = self._pb()
        return dm.WorkspaceSelector(workspace=ctx.namespace)

    def _workspaces(self):
        from openshell.sandbox import WorkspaceClient  # noqa: PLC0415
        return WorkspaceClient.from_sandbox_client(self.client)

    def _ensure_workspace(self, ctx):
        """Label the namespace and add what the openshell-workspace chart would, then register it."""
        # Sandbox ServiceAccount, the gateway's access (the chart's Role, as a ClusterRole
        # binding) and SSH from the gateway only.
        c = self.k8s.client
        key, _, value = self.os_cfg["workspaceLabel"].partition("=")
        c.CoreV1Api().patch_namespace(ctx.namespace, {"metadata": {"labels": {key: value}}})
        gw_sa, gw_ns = self.os_cfg["gatewayServiceAccount"], self.os_cfg["gatewayNamespace"]
        meta = lambda name: c.V1ObjectMeta(name=name, namespace=ctx.namespace,  # noqa: E731
                                           labels={"app.kubernetes.io/managed-by": "agent-operator"})
        core, rbac, net = c.CoreV1Api(), c.RbacAuthorizationV1Api(), c.NetworkingV1Api()
        objects = [
            (core.create_namespaced_service_account, core.replace_namespaced_service_account, SANDBOX_SA,
             c.V1ServiceAccount(metadata=meta(SANDBOX_SA), automount_service_account_token=False)),
            # A binding to the chart's ClusterRole: the operator needs only `bind` on it, not
            # the sandbox permissions it grants the gateway here.
            (rbac.create_namespaced_role_binding, rbac.replace_namespaced_role_binding, WORKSPACE_BINDING,
             c.V1RoleBinding(
                 metadata=meta(WORKSPACE_BINDING),
                 role_ref=c.V1RoleRef(api_group="rbac.authorization.k8s.io", kind="ClusterRole",
                                      name=self.os_cfg["workspaceClusterRole"]),
                 subjects=[c.RbacV1Subject(kind="ServiceAccount", name=gw_sa, namespace=gw_ns)])),
            (net.create_namespaced_network_policy, net.replace_namespaced_network_policy, WORKSPACE_SSH_POLICY,
             c.V1NetworkPolicy(metadata=meta(WORKSPACE_SSH_POLICY), spec=c.V1NetworkPolicySpec(
                 pod_selector=c.V1LabelSelector(match_labels={"openshell.ai/managed-by": "openshell"}),
                 policy_types=["Ingress"],
                 ingress=[c.V1NetworkPolicyIngressRule(
                     _from=[c.V1NetworkPolicyPeer(
                         namespace_selector=c.V1LabelSelector(match_labels={"kubernetes.io/metadata.name": gw_ns}),
                         pod_selector=c.V1LabelSelector(match_labels=self.os_cfg["gatewayPodLabels"]))],
                     ports=[c.V1NetworkPolicyPort(port=2222, protocol="TCP")])]))),
        ]
        if self.mesh_ambient:
            # Workload <-> its supervisor over the mesh tunnel; nothing else is opened.
            peer = [c.V1NetworkPolicyPeer(pod_selector=c.V1LabelSelector(
                match_labels={"openshell.ai/boundary-role": "supervisor"}))]
            tunnel = [c.V1NetworkPolicyPort(port=MESH_TUNNEL_PORT, protocol="TCP")]
            objects.append((net.create_namespaced_network_policy, net.replace_namespaced_network_policy, MESH_POLICY,
                            c.V1NetworkPolicy(metadata=meta(MESH_POLICY), spec=c.V1NetworkPolicySpec(
                                pod_selector=c.V1LabelSelector(match_labels={"openshell.ai/boundary-role": "workload"}),
                                policy_types=["Ingress", "Egress"],
                                ingress=[c.V1NetworkPolicyIngressRule(_from=peer, ports=tunnel)],
                                egress=[c.V1NetworkPolicyEgressRule(to=peer, ports=tunnel)]))))
        for create, replace, name, body in objects:
            try:
                create(ctx.namespace, body)
            except c.ApiException as e:
                if e.status != 409:
                    raise
                replace(name, ctx.namespace, body)
        try:
            self._workspaces().create(ctx.namespace)
            ctx.logger.info(f"Registered OpenShell workspace '{ctx.namespace}'")
        except Exception as e:
            if _status(e) != "ALREADY_EXISTS":
                raise

    def _cluster_key(self):
        ns, name, key = self.os_cfg["modelKeySecret"].split("/", 2)
        data = self.k8s.client.CoreV1Api().read_namespaced_secret(name, ns).data or {}
        if not data.get(key):
            raise ValueError(f"Secret {ns}/{name} has no '{key}'")
        return base64.b64decode(data[key]).decode()

    def _ensure_provider(self, ctx):
        """The workspace's model provider; it holds the key, the sandbox sees a placeholder."""
        pb, dm = self._pb()
        try:
            self.client._stub.GetProvider(pb.GetProviderRequest(
                workspace_scope=self._scope(ctx), name=self.os_cfg["providerName"]), timeout=30)
            return  # a key is minted once, with the provider; the gateway keeps it
        except Exception as e:
            if _status(e) != "NOT_FOUND":
                raise
        key = self._agent_key(ctx) if self.os_cfg["litellmAdminKey"] else self._cluster_key()
        provider = dm.Provider(
            metadata=dm.ObjectMeta(name=self.os_cfg["providerName"]), type=self.os_cfg["providerType"],
            credentials={"OPENAI_API_KEY": key}, profile_workspace="")
        self._rpc("CreateProvider", pb.CreateProviderRequest(workspace_scope=self._scope(ctx), provider=provider))
        ctx.logger.info(f"Created OpenShell provider in '{ctx.namespace}'")

    # ── LiteLLM: a key per agent, owned by its user ──────────────────────────
    def _litellm_http(self, path, body=None):
        """POST (GET with no body) to LiteLLM's API with the admin key; (status, parsed body)."""
        base = (self.os_cfg["modelBaseUrl"] or self.model_base_url).rstrip("/")
        base = base[:-3] if base.endswith("/v1") else base
        req = urllib.request.Request(f"{base}{path}", json.dumps(body).encode() if body is not None else None, {
            "Authorization": f"Bearer {self.os_cfg['litellmAdminKey']}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:  # nosec B310: in-cluster LiteLLM URL
                return resp.status, json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, e.read()[:300].decode(errors="replace")

    @staticmethod
    def _get_json(url):
        """GET a model server's JSON, with no key: only its public model list is read."""
        with urllib.request.urlopen(url, timeout=5) as resp:  # nosec B310: the upstream LiteLLM lists
            return json.loads(resp.read() or b"null")

    def served_context(self, model_id):
        """The model's served context size, cached a minute; None when unknown.

        The model server's own figure (vLLM's max_model_len, at the upstream LiteLLM lists for the
        model) is what it enforces. LiteLLM's max_input_tokens is only a fallback: it is empty for a
        newly registered model and can be the model's published size rather than the served one.
        The AI Gateway serves the same models under the same names."""
        import time  # noqa: PLC0415
        cached = self._sizes.get(model_id)
        if cached and time.time() - cached[0] < 60:
            return cached[1]
        size = None
        try:
            size = self._lookup_context(model_id)
        except Exception:  # an unreachable LiteLLM or model leaves the size unknown, never the agent broken
            pass
        self._sizes[model_id] = (time.time(), size)
        return size

    def _lookup_context(self, model_id):
        if not self.os_cfg["litellmAdminKey"]:
            return None
        status, body = self._litellm_call("/model/info", None)
        entries = (body.get("data") or []) if status == 200 and isinstance(body, dict) else []
        entry = next((e for e in entries if e.get("model_name") == model_id), None)
        if not entry:
            return None
        api_base = (entry.get("litellm_params") or {}).get("api_base") or ""
        if api_base.startswith(("http://", "https://")):
            try:
                served = self._fetch_json(f"{api_base.rstrip('/')}/models")
                sizes = [int(m.get("max_model_len") or 0) for m in (served or {}).get("data") or []]
                if any(sizes):
                    return max(sizes)
            except Exception:  # not a vLLM server, or unreachable: fall back to LiteLLM's figure
                pass
        return int((entry.get("model_info") or {}).get("max_input_tokens") or 0) or None

    @staticmethod
    def _limits(tpm, rpm):
        return {**({"tpm_limit": tpm} if tpm else {}), **({"rpm_limit": rpm} if rpm else {})}

    def _agent_key(self, ctx):
        """A new key for this agent (alias: its namespace), owned by its user, whom it creates if new."""
        status, body = self._litellm_call("/user/new", {
            "user_id": ctx.owner, "user_email": ctx.owner,
            **self._limits(self.os_cfg["userTpmLimit"], self.os_cfg["userRpmLimit"])})
        if status not in (200, 409):  # 409: the user exists
            raise RuntimeError(f"LiteLLM user {ctx.owner}: HTTP {status}: {body}")
        # An alias can outlive its provider (a failed create); aliases are unique.
        self._litellm_call("/key/delete", {"key_aliases": [ctx.namespace]})
        status, body = self._litellm_call("/key/generate", {
            "key_alias": ctx.namespace, "user_id": ctx.owner,
            "metadata": {"agent": ctx.name, "agent_namespace": ctx.namespace, "runtime": "openshell"},
            **self._limits(self.os_cfg["agentTpmLimit"], self.os_cfg["agentRpmLimit"])})
        if status != 200 or not isinstance(body, dict) or not body.get("key"):
            raise RuntimeError(f"LiteLLM key for {ctx.namespace}: HTTP {status}: {body}")
        ctx.logger.info(f"Minted LiteLLM key '{ctx.namespace}' for user {ctx.owner}")
        return body["key"]

    # ── Sandbox ──────────────────────────────────────────────────────────────
    def _mcp_wiring(self, ctx):
        servers, routes = super()._mcp_wiring(ctx)
        for skill in EXCLUDED_SKILLS & set(servers):
            servers.pop(skill)
            routes = {p: r for p, r in routes.items() if not r["scope"].endswith(f"-{skill}")}
        return servers, routes

    def model_gateway(self, ctx):
        """(provider, base URL, key) for the agent's spec.model.provider; genai-gateway by default."""
        requested = (ctx.model or {}).get("provider")
        if requested == AI_GATEWAY_PROVIDER and self.os_cfg["aiGatewayUrl"]:
            return AI_GATEWAY_PROVIDER, self.os_cfg["aiGatewayUrl"], NO_KEY
        # A secret reference the supervisor resolves to the provider's key, never the key itself.
        return self.os_cfg["providerName"], self.os_cfg["modelBaseUrl"] or self.model_base_url, "${OPENAI_API_KEY}"

    def _model_vars(self, ctx):
        """The model fields, with the provider named after the gateway it really uses."""
        model = super()._model_vars(ctx)
        provider, base_url, _ = self.model_gateway(ctx)
        model.update(model_provider=provider, model_ref=f"{provider}/{model['model_id']}", model_base_url=base_url)
        return model

    def _config_json(self, ctx):
        """openclaw.json: the claw runtime's config, served on loopback behind the gateway relay."""
        import json  # noqa: PLC0415
        tools, plugins = {}, []
        for skill in ctx.skills or []:
            tools.update(claw_adapter.SKILL_MAP.get(skill, {}).get("tools", {}))
            plugins.extend(claw_adapter.SKILL_MAP.get(skill, {}).get("plugins", []))
        # Code execution is this runtime's purpose: exec is always on, in the sandboxed pod.
        tools.update(claw_adapter.SKILL_MAP["shell"]["tools"])
        mcp_servers, _ = self._mcp_wiring(ctx)
        # The relay delivers every request from loopback, after the platform gateway signed the
        # user in and named them in x-gw-user; nothing else can reach the relay.
        cfg = {**self.cfg, "trustedProxies": ["127.0.0.1/32"]}
        model = self._model_vars(ctx)
        cr = claw_adapter._render_cr(
            "openclaw-instance.yaml.j2", cfg=cfg, name=ctx.name, namespace=ctx.namespace,
            cr_namespace=ctx.cr_namespace, owner_label=ctx.owner.replace("@", "_at_"),
            model_key_secret="unused", tools=tools, plugins=plugins, tools_deny=ctx.tools_deny,
            mcp_servers=mcp_servers, web_fetch_proxy="", **model)
        config = cr["spec"]["config"]["raw"]
        provider, _, key = self.model_gateway(ctx)
        config["models"]["providers"][provider]["apiKey"] = key
        # What the OpenClaw operator adds on the claw runtime: without gateway.mode OpenClaw
        # refuses to start. Loopback only: the supervisor's relay is the way in.
        config["gateway"].update(mode="local", bind="loopback", port=SERVICE_PORT)
        return json.dumps(config, indent=2)

    def _policy(self, ctx, routes):
        """Default deny, plus exactly what this agent needs. The provider adds the model endpoint."""
        from google.protobuf import json_format  # noqa: PLC0415
        from openshell._proto import sandbox_pb2  # noqa: PLC0415
        node = [{"path": NODE}]
        rules = {}
        if routes:
            proxy = f"{claw_adapter.IDENTITY_PROXY_SERVICE}.{ctx.namespace}.svc.cluster.local"
            rules["identity_proxy"] = {"name": "agent-identity-proxy", "binaries": node, "endpoints": [
                _endpoint(proxy, port, "rest") for port in sorted(routes)]}
        direct = [_url_endpoint(t["url"]) for t in ctx.custom_tools or [] if t.get("url")]
        if self.cfg.get("embeddingBaseUrl"):
            direct.append(_url_endpoint(self.cfg["embeddingBaseUrl"]))
        provider, base_url, _ = self.model_gateway(ctx)
        if provider == AI_GATEWAY_PROVIDER:
            direct.append(_url_endpoint(base_url))  # genai-gateway's endpoint comes with the provider
        if any(direct):
            rules["agent_services"] = {"name": "agent-services", "binaries": node,
                                       "endpoints": [ep for ep in direct if ep]}
        web = _web_hosts(ctx.spec.get("webFetchAllowlist"), ctx.logger)
        if web:
            rules["web_fetch"] = {"name": "web-fetch-allowlist", "binaries": node,
                                  "endpoints": [{"host": h, "ports": [80, 443]} for h in web]}
        if self.os_cfg["pypi"]:
            rules["pypi"] = {"name": "pypi", "binaries": [{"path": PYTHON}],
                             "endpoints": [_endpoint(h, 443) for h in PYPI_HOSTS]}
        return json_format.ParseDict({
            "version": 1,
            "filesystem": {"include_workdir": True, "read_only": READ_ONLY_PATHS, "read_write": READ_WRITE_PATHS},
            "landlock": {"compatibility": "best_effort"},
            "network_policies": rules,
        }, sandbox_pb2.SandboxPolicy())

    def _create_sandbox(self, ctx):
        if not self.os_cfg["image"]:
            raise ValueError("OPENSHELL_SANDBOX_IMAGE is not set")
        from openshell.sandbox import ServiceExposure  # noqa: PLC0415
        pb, _ = self._pb()
        _, routes = self._mcp_wiring(ctx)
        config = self._config_json(ctx)
        annotations = {DNS_CAPTURE_ANNOTATION: "false"} if self.mesh_ambient else {}
        spec = pb.SandboxSpec(
            template=pb.SandboxTemplate(image=self.os_cfg["image"], annotations=annotations),
            policy=self._policy(ctx, routes),
            providers=[self.os_cfg["providerName"]],
            environment={"HOME": "/sandbox", "OC_CONFIG": CONFIG_PATH,
                         "OC_CONFIG_B64": base64.b64encode(config.encode()).decode()},
            command=["sh", "-c", START_COMMAND],
            restart_policy=pb.SANDBOX_RESTART_POLICY_ALWAYS)
        self.client.create(
            workspace=ctx.namespace, name=ctx.name, spec=spec,
            labels={"intel-stack.io/agent": ctx.name, "intel-stack.io/owner": ctx.owner.replace("@", "_at_")},
            service_exposures=[ServiceExposure(service=SERVICE_NAME, target_port=SERVICE_PORT)])
        ctx.logger.info(f"Created OpenShell sandbox '{ctx.name}' in workspace '{ctx.namespace}'")

    # ── Files ────────────────────────────────────────────────────────────────
    def _exec(self, ctx, argv, stdin=None, timeout=60):
        res = self.client.exec(ctx.name, argv, workspace=ctx.namespace, stdin=stdin,
                               timeout_seconds=timeout, no_login_shell=True)
        if res.exit_code != 0:
            raise RuntimeError(f"exit {res.exit_code}: {res.stderr[:200]!r}")
        return res

    def _write(self, ctx, path, content):
        # The path is an argument, never script text.
        self._exec(ctx, ["sh", "-c", 'mkdir -p "$(dirname "$1")" && cat > "$1"', "write", path],
                   stdin=content.encode() if isinstance(content, str) else content)

    def _seed_files(self, ctx, files):
        """Write spec.workspace files; content is plain text or "base64:<data>"."""
        seeded = []
        for rel, content in files.items():
            rel = str(rel).strip("/")
            if not claw_adapter._WORKSPACE_PATH_RE.match(rel) or ".." in rel.split("/"):
                ctx.logger.warning(f"Skipping unsafe workspace path '{rel}'")
                continue
            content = content or ""
            data = base64.b64decode(content[len("base64:"):]) if content.startswith("base64:") else content.encode()
            try:
                self._write(ctx, f"{WORKSPACE}/{rel}", data)
                seeded.append(rel)
            except Exception as e:
                ctx.logger.warning(f"Could not seed '{rel}' for '{ctx.name}': {e}")
        if seeded:
            ctx.logger.info(f"Seeded {len(seeded)} workspace file(s) for '{ctx.name}'")
