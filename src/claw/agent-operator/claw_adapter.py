# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""claw runtime: one OpenClawInstance per Agent.

The OpenClaw operator owns the resulting workload. This adapter only creates the
instance, patches the two fields it authors (spec.config, spec.env) and toggles
spec.suspended; it never rewrites anything else.
"""
import base64
import os
import re
import time
import urllib.parse

TEMPLATE_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE = "/home/openclaw/.openclaw/workspace"
IDENTITY_PROXY_SERVICE = "identity-proxy"
# The agent's own GitHub PAT: header the GitHub MCP server reads, file the identity proxy reads.
GITHUB_TOKEN_HEADER = "X-Agent-Github-Token"
GITHUB_TOKEN_CRED_FILE = "github_token"
# Sent when no key is configured; the in-cluster inference gateway needs none.
NO_KEY = "sk-no-key-needed"

# OpenClaw's system prompt alone is about 19,500 tokens a turn, so a smaller context cannot hold
# a conversation. With no size known, assume this rather than OpenClaw's 200000, which outgrows
# most self-hosted models and fails once a conversation is longer than the model's limit.
MIN_CONTEXT_WINDOW = 32768
FALLBACK_CONTEXT_WINDOW = 32768

# Workspace keys are relative paths of plain segments.
_WORKSPACE_PATH_RE = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")

SKILL_MAP = {
    "shell": {"tools": {"exec": {"security": "full", "ask": "off"}}},
    "browser-automation": {"plugins": ["browser-automation"]},
    "diagram-maker": {"plugins": ["diagram-maker"]},
    "canvas": {"plugins": ["canvas"]},
}


def _bool(value, default):
    if value in (None, ""):
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _int(value, default):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def config_from_env(env=None):
    """Adapter configuration, from the operator container's environment."""
    env = os.environ if env is None else env
    return {
        "openclawImage": env.get("OPENCLAW_IMAGE", "ghcr.io/openclaw/openclaw"),
        "openclawTag": env.get("OPENCLAW_TAG", "2026.7.1-1"),
        "openclawDigest": env.get(
            "OPENCLAW_DIGEST", "sha256:2f5ce8848a1a69b3c460622e566cb9395da9fd18d7ef7b038cd8e2c4f195decf"),
        "agentTimeoutSeconds": _int(env.get("AGENT_TIMEOUT_SECONDS"), 900),
        "model": {
            "provider": env.get("MODEL_PROVIDER", "ai-gateway"),
            "id": env.get("MODEL_ID", ""),
            "name": env.get("MODEL_NAME", ""),
            "baseUrl": env.get("MODEL_BASE_URL", ""),
            "apiKey": env.get("MODEL_API_KEY", ""),
            "allowPrivateNetwork": _bool(env.get("MODEL_ALLOW_PRIVATE_NETWORK"), True),
            "contextWindow": _int(env.get("MODEL_CONTEXT_WINDOW"), 0),
        },
        "compactionReserveTokens": _int(env.get("COMPACTION_RESERVE_TOKENS"), 6144),
        # OpenClaw's built-in memory search; empty leaves it off.
        "embeddingBaseUrl": env.get("EMBEDDING_BASE_URL", ""),
        "embeddingModel": env.get("EMBEDDING_MODEL", "BAAI/bge-base-en-v1.5"),
        "controlUiAllowedOrigins": [
            o.strip() for o in env.get("CONTROL_UI_ALLOWED_ORIGINS", "").split(",") if o.strip()],
        # The platform gateway's pod addresses; set, the agent gateway takes the user from it.
        "trustedProxies": [c.strip() for c in env.get("GATEWAY_TRUSTED_PROXIES", "").split(",") if c.strip()],
    }


def _render(template_name, **values):
    """Render a template with [[ ]] / [% %] / [# #] delimiters (no clash with Helm or YAML)."""
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
    env = Environment(
        loader=FileSystemLoader(TEMPLATE_DIR), undefined=StrictUndefined,
        variable_start_string="[[", variable_end_string="]]",
        block_start_string="[%", block_end_string="%]",
        comment_start_string="[#", comment_end_string="#]",
        # YAML output, not HTML: values are JSON-encoded in the template instead.
        trim_blocks=True, lstrip_blocks=True, autoescape=False)  # nosec B701
    return env.get_template(template_name).render(**values)


def _render_cr(template_name, **values):
    import yaml
    return yaml.safe_load(_render(template_name, **values))


class ClawAdapter:
    def __init__(self, core, config):
        self.core = core
        self.k8s = core.k8s
        self.cfg = config
        model = config["model"]
        self.model_provider = model["provider"]
        self.model_id = model["id"]
        self.model_name = model["name"] or model["id"]
        self.model_base_url = model["baseUrl"]
        self.model_api_key = model["apiKey"] or NO_KEY
        self.identity_proxy_port_base = int(core.identity_proxy_port_base)
        self.identity_proxy_port_span = int(core.identity_proxy_port_span)
        self.web_fetch_proxy_enabled = bool(core.web_fetch_proxy_enabled)
        self.web_fetch_proxy_port = int(core.web_fetch_proxy_port)

    # ── Adapter interface ────────────────────────────────────────────────────
    def create(self, ctx):
        api = self.k8s.client.CustomObjectsApi()
        body = self._render_instance(ctx)
        try:
            api.create_namespaced_custom_object(
                group="openclaw.rocks", version="v1alpha1", namespace=ctx.namespace,
                plural="openclawinstances", body=body)
            ctx.logger.info(f"Created OpenClawInstance '{ctx.name}'")
        except self.k8s.client.ApiException as e:
            if e.status != 409:
                raise
            # Exists: converge the fields we author (no-op when unchanged).
            self._patch_instance(ctx, body)
        return {"apiVersion": "openclaw.rocks/v1alpha1", "kind": "OpenClawInstance", "name": ctx.name}

    def update(self, ctx, reseed=True):
        """Patch the authored config, roll the pod if it changed, then re-seed the workspace."""
        changed = self._patch_instance(ctx)
        if reseed and ctx.workspace_files:
            if changed:
                self._wait_pod_ready(ctx)
            self._seed_files(ctx, ctx.workspace_files)

    def post_create(self, ctx):
        if ctx.workspace_files:
            self._wait_pod_ready(ctx)
            self._seed_files(ctx, ctx.workspace_files)

    def suspend(self, ctx):
        self._set_suspended(ctx, True)

    def resume(self, ctx):
        self._set_suspended(ctx, False)
        self._wait_pod_ready(ctx)

    def delete(self, ctx):
        try:
            self.k8s.client.CustomObjectsApi().delete_namespaced_custom_object(
                group="openclaw.rocks", version="v1alpha1", namespace=ctx.namespace,
                plural="openclawinstances", name=ctx.name)
            ctx.logger.info(f"Deleted OpenClawInstance '{ctx.name}'")
        except self.k8s.client.ApiException as e:
            if e.status != 404:
                ctx.logger.warning(f"Failed to delete OpenClawInstance '{ctx.name}': {e}")

    # ── Model ────────────────────────────────────────────────────────────────
    def _model_vars(self, ctx):
        """Per-agent spec.model overrides the cluster default, field by field."""
        m = ctx.model or {}
        provider = m.get("provider") or self.model_provider
        model_id = m.get("id") or self.model_id
        return {
            "model_ref": f"{provider}/{model_id}",
            "model_provider": provider,
            "model_id": model_id,
            "model_name": m.get("name") or m.get("id") or self.model_name,
            "model_base_url": m.get("baseUrl") or self.model_base_url,
            "context_window": self._context_window(ctx, model_id, m),
        }

    def served_context(self, model_id):
        """The model's served context size, where this runtime can ask; None when unknown."""
        return None

    def _context_window(self, ctx, model_id, m):
        """The size OpenClaw plans for: never more than the model serves, never left to its 200000.

        The agent's own size if given (the console sets it from the gateway's list), else the
        cluster setting for the cluster's own model, else what the model serves, else a
        conservative fallback. Notes go to ctx.model_notes for the agent's ModelContext condition."""
        notes = []
        served = self.served_context(model_id)
        default = self.cfg["model"]["contextWindow"] if model_id == self.model_id and not m.get("baseUrl") else 0
        size = int(m.get("contextWindow") or 0) or default or served or 0
        if not size:
            size = FALLBACK_CONTEXT_WINDOW
            notes.append(f"the context size of '{model_id}' is unknown; assumed {size}")
        elif served and size > served:
            notes.append(f"{size} is more than '{model_id}' serves; capped at {served}")
            size = served
        if size < MIN_CONTEXT_WINDOW:
            notes.append(f"{size} tokens is under the {MIN_CONTEXT_WINDOW} an agent needs; long conversations will fail")
        ctx.context_window, ctx.model_notes = size, notes
        return size

    def _model_key(self, ctx):
        """The agent's own key; the cluster default only when the default endpoint is used."""
        if ctx.model_api_key:
            return ctx.model_api_key
        if (ctx.model or {}).get("baseUrl"):
            return NO_KEY
        return self.model_api_key

    def _ensure_model_key_secret(self, ctx):
        """Per-agent Secret the instance references, so the key is never in the CR."""
        api = self.k8s.client.CoreV1Api()
        name = f"{ctx.name}-model-api-key"
        body = self.k8s.client.V1Secret(
            metadata=self.k8s.client.V1ObjectMeta(name=name, namespace=ctx.namespace),
            string_data={"apiKey": self._model_key(ctx)})
        try:
            api.create_namespaced_secret(ctx.namespace, body)
        except self.k8s.client.ApiException as e:
            if e.status != 409:
                raise
            api.replace_namespaced_secret(name, ctx.namespace, body)
        return name

    # ── Tools ────────────────────────────────────────────────────────────────
    @staticmethod
    def _tool_credentials(ctx):
        """{file: value} for the identity proxy's Secret; empty clears a revoked PAT."""
        return {GITHUB_TOKEN_CRED_FILE: ctx.github_token} if ctx.github_token else {}

    def _mcp_wiring(self, ctx):
        """(servers for openclaw.json, routes for the identity proxy), from one pass so they agree."""
        servers = {t["name"]: {"url": t["url"], "transport": "sse"}
                   for t in ctx.custom_tools if t.get("name") and t.get("url")}
        # {skill: entry} of Registered Tools; each entry's aliases are already conflict-free.
        registry = self.core.tools()
        requested = set(ctx.skills or [])
        requested |= {s for s, e in registry.items()
                      if e.get("alwaysOn") or requested & set(e.get("aliases") or [])}

        identity_scopes = {}
        for skill in sorted(requested & set(registry)):
            entry = registry[skill]
            if entry.get("requiresIdentity"):
                identity_scopes[skill] = f"mcp-{skill}"
            servers[skill] = {"url": entry["url"], "transport": entry.get("transport", "sse")}

        # Ports follow sorted skill names, so an unchanged skill set never rolls the proxy.
        routes = {}
        for i, skill in enumerate(sorted(identity_scopes)):
            if i >= self.identity_proxy_port_span:
                ctx.logger.warning(f"agent '{ctx.name}': {len(identity_scopes)} identity tools exceeds "
                                   f"the proxy port span {self.identity_proxy_port_span}; '{skill}' omitted")
                servers.pop(skill)
                continue
            port = self.identity_proxy_port_base + i
            upstream = urllib.parse.urlsplit(servers[skill]["url"])
            routes[port] = {"url": servers[skill]["url"], "scope": identity_scopes[skill]}
            if skill == "github" and ctx.github_token:
                routes[port]["credHeaders"] = {GITHUB_TOKEN_HEADER: GITHUB_TOKEN_CRED_FILE}
            servers[skill]["url"] = urllib.parse.urlunsplit((
                "http", f"{IDENTITY_PROXY_SERVICE}.{ctx.namespace}.svc.cluster.local:{port}",
                upstream.path, upstream.query, ""))
        return servers, routes

    # ── OpenClawInstance ─────────────────────────────────────────────────────
    def _render_instance(self, ctx):
        tools, plugins = {}, []
        for skill in ctx.skills or []:
            tools.update(SKILL_MAP.get(skill, {}).get("tools", {}))
            plugins.extend(SKILL_MAP.get(skill, {}).get("plugins", []))
        mcp_servers, routes = self._mcp_wiring(ctx)
        # The proxy must serve the ports before the agent is told to call them.
        self.core.apply_identity_proxy(ctx.name, ctx.namespace, routes, ctx.logger,
                                       tool_credentials=self._tool_credentials(ctx))
        proxy = (f"http://web-fetch-proxy.{ctx.namespace}.svc.cluster.local:{self.web_fetch_proxy_port}"
                 if self.web_fetch_proxy_enabled else "")
        return _render_cr(
            "openclaw-instance.yaml.j2", cfg=self.cfg,
            name=ctx.name, namespace=ctx.namespace, cr_namespace=ctx.cr_namespace,
            owner_label=ctx.owner.replace("@", "_at_"),
            model_key_secret=self._ensure_model_key_secret(ctx), tools=tools, plugins=plugins,
            tools_deny=ctx.tools_deny, mcp_servers=mcp_servers, web_fetch_proxy=proxy,
            **self._model_vars(ctx))

    def _patch_instance(self, ctx, rendered=None):
        """JSON-patch spec.config and spec.env; returns True if the pod was rolled."""
        api = self.k8s.client.CustomObjectsApi()
        body = (rendered or self._render_instance(ctx))["spec"]
        try:
            live = api.get_namespaced_custom_object(
                group="openclaw.rocks", version="v1alpha1", namespace=ctx.namespace,
                plural="openclawinstances", name=ctx.name).get("spec", {})
        except self.k8s.client.ApiException as e:
            if e.status == 404:
                ctx.logger.info(f"OpenClawInstance '{ctx.name}' absent — nothing to update")
                return False
            raise
        if live.get("config") == body["config"] and live.get("env") == body["env"]:
            return False
        # JSON patch, not merge patch: a merge patch never removes keys, so a dropped
        # skill would stay wired forever. "add" also creates spec.env when absent.
        ops = [{"op": "replace", "path": "/spec/config", "value": body["config"]},
               {"op": "add", "path": "/spec/env", "value": body["env"]}]
        api.api_client.call_api(
            f"/apis/openclaw.rocks/v1alpha1/namespaces/{ctx.namespace}/openclawinstances/{ctx.name}",
            "PATCH", header_params={"Content-Type": "application/json-patch+json",
                                    "Accept": "application/json"},
            body=ops, response_type="object", auth_settings=["BearerToken"],
            _return_http_data_only=True)
        ctx.logger.info(f"Patched OpenClawInstance '{ctx.name}' config")
        self._roll_pod(ctx)
        return True

    def _roll_pod(self, ctx):
        """Delete the pod so its StatefulSet recreates it with the new config."""
        core = self.k8s.client.CoreV1Api()
        try:
            for pod in core.list_namespaced_pod(
                    ctx.namespace, label_selector=f"app.kubernetes.io/instance={ctx.name}").items:
                core.delete_namespaced_pod(pod.metadata.name, ctx.namespace)
                ctx.logger.info(f"Rolled pod {pod.metadata.name} for '{ctx.name}'")
        except self.k8s.client.ApiException as e:
            ctx.logger.warning(f"Could not roll pod for '{ctx.name}': {e}")

    def _set_suspended(self, ctx, suspended):
        try:
            self.k8s.client.CustomObjectsApi().patch_namespaced_custom_object(
                group="openclaw.rocks", version="v1alpha1", namespace=ctx.namespace,
                plural="openclawinstances", name=ctx.name, body={"spec": {"suspended": suspended}})
            ctx.logger.info(f"Set OpenClawInstance '{ctx.name}' suspended={suspended}")
        except self.k8s.client.ApiException as e:
            ctx.logger.warning(f"Failed to set suspended={suspended} on '{ctx.name}': {e}")

    def _wait_pod_ready(self, ctx, timeout=180):
        api = self.k8s.client.CoreV1Api()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                for pod in api.list_namespaced_pod(
                        ctx.namespace, label_selector=f"app.kubernetes.io/instance={ctx.name}").items:
                    if pod.metadata.deletion_timestamp is None and any(
                            c.type == "Ready" and c.status == "True" for c in pod.status.conditions or []):
                        return pod.metadata.name
            except self.k8s.client.ApiException:
                pass
            time.sleep(5)
        ctx.logger.warning(f"Pod for '{ctx.name}' not Ready within {timeout}s (continuing)")
        return None

    # ── Workspace seeding ────────────────────────────────────────────────────
    def _exec(self, ctx, argv, stdin, timeout=60):
        """Run argv in the agent container and fail on a non-zero exit."""
        from kubernetes.stream import stream  # noqa: PLC0415
        resp = stream(self.k8s.client.CoreV1Api().connect_get_namespaced_pod_exec,
                      f"{ctx.name}-0", ctx.namespace, container="openclaw", command=argv,
                      stderr=True, stdin=True, stdout=True, tty=False, _preload_content=False)
        try:
            resp.write_stdin(stdin)
            resp.run_forever(timeout=timeout)
            if resp.returncode != 0:
                raise RuntimeError(f"exit {resp.returncode}: {resp.read_stderr()[:200]}")
        finally:
            resp.close()

    def _seed_files(self, ctx, files):
        """Write spec.workspace files; content is plain text or "base64:<data>"."""
        seeded = []
        for rel, content in files.items():
            rel = str(rel).strip("/")
            if not _WORKSPACE_PATH_RE.match(rel) or ".." in rel.split("/"):
                ctx.logger.warning(f"Skipping unsafe workspace path '{rel}'")
                continue
            content = content or ""
            data = content[len("base64:"):] if content.startswith("base64:") \
                else base64.b64encode(content.encode()).decode()
            # Path and length are arguments, never script text; reading exactly
            # N bytes ends the command without relying on stdin EOF over exec.
            argv = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && head -c "$2" | base64 -d > "$1"',
                    "seed", f"{WORKSPACE}/{rel}", str(len(data))]
            try:
                self._exec(ctx, argv, data)
                seeded.append(rel)
            except Exception as e:
                if "403" in str(e) or "Forbidden" in str(e):
                    ctx.logger.error(f"Cannot seed '{rel}' for '{ctx.name}': exec forbidden in "
                                     f"{ctx.namespace} (expected RoleBinding 'agent-ns-exec').")
                else:
                    ctx.logger.warning(f"Could not seed '{rel}' for '{ctx.name}': {e}")
        if seeded:
            ctx.logger.info(f"Seeded {len(seeded)} workspace file(s) for '{ctx.name}'")
