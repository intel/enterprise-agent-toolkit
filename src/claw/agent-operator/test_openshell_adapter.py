# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""openshell adapter: policy, config, workspace and sandbox lifecycle, against fakes."""
import base64
import json
import types
import unittest

from google.protobuf import json_format

import openshell_adapter as oa

TOOLS = {
    "memory": {"url": "http://mcp-memory-server.agent-operator-system.svc.cluster.local:8000/sse",
               "requiresIdentity": True, "alwaysOn": True, "aliases": []},
    "sandbox": {"url": "http://mcp-sandbox-server.agent-sandbox-system.svc.cluster.local:8000/sse",
                "requiresIdentity": True, "alwaysOn": False, "aliases": ["shell"]},
    "github": {"url": "http://mcp-github-server.agent-operator-system.svc.cluster.local:8000/sse",
               "requiresIdentity": True, "alwaysOn": False, "aliases": []},
}
KEY = "sk-cluster-key"
LITELLM = "http://litellm.litellm.svc.cluster.local:4000/v1"


class _Logger:
    def __init__(self):
        self.infos, self.warnings, self.errors = [], [], []

    def info(self, m):
        self.infos.append(m)

    def warning(self, m):
        self.warnings.append(m)

    def error(self, m):
        self.errors.append(m)


class _Status(Exception):
    """A gateway error with a gRPC status, as the SDK raises them."""

    def __init__(self, name):
        super().__init__(name)
        self._name = name

    def code(self):
        return types.SimpleNamespace(name=self._name)


class _ApiException(Exception):
    def __init__(self, status):
        super().__init__(status)
        self.status = status


class _K8s:
    """kubernetes.client stand-in: model classes return their kwargs, API calls are recorded."""

    def __init__(self):
        self.calls = []
        self.ApiException = _ApiException
        k8s = self

        class _Api:
            def __getattr__(self, name):
                def call(*args, **kwargs):
                    k8s.calls.append((name, args))
                    if name == "read_namespaced_secret":
                        return types.SimpleNamespace(data={"api_key": base64.b64encode(KEY.encode()).decode()})
                return call

        for api in ("CoreV1Api", "RbacAuthorizationV1Api", "NetworkingV1Api"):
            setattr(self, api, _Api)

    def __getattr__(self, name):
        if name.startswith("V1") or name.startswith("RbacV1"):
            return lambda **kw: {"kind": name, **kw}
        raise AttributeError(name)


class _Stub:
    def __init__(self, provider_exists=False):
        self.calls, self.provider_exists = [], provider_exists

    def __getattr__(self, method):
        def call(request, timeout=None):
            self.calls.append((method, request))
            if method == "GetProvider" and not self.provider_exists:
                raise _Status("NOT_FOUND")
            return types.SimpleNamespace()
        return call


class _Client:
    def __init__(self, exists=False):
        self.exists = exists
        self._stub = _Stub()
        self.created, self.execs, self.calls = [], [], []

    def get(self, name, *, workspace):
        if not self.exists:
            raise _Status("NOT_FOUND")
        return types.SimpleNamespace(phase=2, conditions=(types.SimpleNamespace(type="Ready", status="True"),))

    def create(self, **kw):
        self.created.append(kw)

    def exec(self, name, argv, *, workspace, stdin=None, timeout_seconds=None, no_login_shell=False):
        self.execs.append((argv, stdin))
        return types.SimpleNamespace(exit_code=0, stdout="", stderr="")

    def __getattr__(self, name):  # suspend, resume, stop, start, wait_ready, delete
        def call(*args, **kwargs):
            self.calls.append(name)
            if name in getattr(self, "unavailable", ()):
                raise _Status("UNIMPLEMENTED")
        return call


class _Workspaces:
    def __init__(self, exists=False):
        self.exists, self.created = exists, []

    def create(self, name):
        if self.exists:
            raise _Status("ALREADY_EXISTS")
        self.created.append(name)

    def delete(self, name, allow_missing=False):
        pass


def _ctx(name="oss", username="vkumar4", skills=("shell", "github"), allowlist=(), files=None):
    return types.SimpleNamespace(
        name=name, namespace=f"agent-{username}-{name}", cr_namespace=f"user-{username}",
        owner=f"{username}@example.com", skills=list(skills), custom_tools=[], tools_deny=[],
        github_token="ghp-own", model={}, model_api_key=None, workspace_files=files or {},
        spec={"webFetchAllowlist": list(allowlist)}, logger=_Logger())


def _adapter(env=None, client=None, workspaces=None, mesh=False, litellm=None):
    k8s = _K8s()
    routes_applied = []
    core = types.SimpleNamespace(
        k8s=types.SimpleNamespace(client=k8s), tools=lambda: TOOLS, mesh_ambient=mesh,
        identity_proxy_port_base=8901, identity_proxy_port_span=16,
        web_fetch_proxy_enabled=False, web_fetch_proxy_port=8888,
        apply_identity_proxy=lambda name, ns, routes, logger, tool_credentials=None: routes_applied.append(routes))
    cfg = oa.config_from_env({"MODEL_ID": "qwen", "MODEL_PROVIDER": "genai-gateway",
                              "MODEL_BASE_URL": "http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1",
                              "OPENSHELL_MODEL_BASE_URL": LITELLM,
                              "OPENSHELL_SANDBOX_IMAGE": "registry/openclaw-sandbox:1", **(env or {})})
    client = client or _Client()
    a = oa.OpenShellAdapter(core, cfg, client_factory=lambda: client, litellm=litellm)
    a._workspaces = lambda: workspaces or _Workspaces()
    return a, client, k8s, routes_applied


def _rules(a, ctx):
    _, routes = a._mcp_wiring(ctx)
    return json_format.MessageToDict(a._policy(ctx, routes), preserving_proto_field_name=True)


class PolicyTest(unittest.TestCase):
    def test_identity_proxy_ports_are_the_only_mcp_endpoints_and_sandbox_mcp_is_dropped(self):
        a, *_ = _adapter()
        ctx = _ctx()
        servers, routes = a._mcp_wiring(ctx)
        self.assertNotIn("sandbox", servers)  # code runs with exec in the sandboxed pod
        self.assertEqual({r["scope"] for r in routes.values()}, {"mcp-github", "mcp-memory"})
        proxy = _rules(a, ctx)["network_policies"]["identity_proxy"]
        self.assertEqual([e["port"] for e in proxy["endpoints"]], sorted(routes))
        self.assertTrue(all(e["host"] == "identity-proxy.agent-vkumar4-oss.svc.cluster.local"
                            for e in proxy["endpoints"]))
        self.assertEqual(proxy["binaries"], [{"path": oa.NODE}])

    def test_web_allowlist_covers_subdomains_and_never_grants_any_host(self):
        a, *_ = _adapter()
        ctx = _ctx(allowlist=["docs.python.org", "*"])
        web = _rules(a, ctx)["network_policies"]["web_fetch"]["endpoints"]
        self.assertEqual([e["host"] for e in web], ["docs.python.org", "*.docs.python.org"])
        self.assertEqual(web[0]["ports"], [80, 443])
        self.assertTrue(any("'*' is not supported" in w for w in ctx.logger.warnings))

    def test_no_allowlist_means_no_web_rule_and_pypi_can_be_turned_off(self):
        a, *_ = _adapter({"OPENSHELL_PYPI_ENABLED": "false"})
        rules = _rules(a, _ctx())["network_policies"]
        self.assertNotIn("web_fetch", rules)
        self.assertNotIn("pypi", rules)

    def test_pypi_is_for_python_only(self):
        a, *_ = _adapter()
        pypi = _rules(a, _ctx())["network_policies"]["pypi"]
        self.assertEqual([e["host"] for e in pypi["endpoints"]], oa.PYPI_HOSTS)
        self.assertEqual(pypi["binaries"], [{"path": oa.PYTHON}])
        self.assertNotIn("**", oa.PYTHON)  # OpenShell 0.1.x rejects ** in binary paths

    def test_filesystem_writes_only_to_sandbox_and_tmp(self):
        a, *_ = _adapter()
        fs = _rules(a, _ctx())["filesystem"]
        self.assertEqual(fs["read_write"], oa.READ_WRITE_PATHS)
        self.assertNotIn("/sandbox", fs["read_only"])


class ConfigTest(unittest.TestCase):
    def setUp(self):
        a, *_ = _adapter()
        self.cfg = json.loads(a._config_json(_ctx(skills=["github"])))

    def test_users_come_only_through_the_loopback_relay(self):
        gw = self.cfg["gateway"]
        self.assertEqual(gw["trustedProxies"], ["127.0.0.1/32"])
        self.assertEqual(gw["auth"]["mode"], "trusted-proxy")
        self.assertEqual(gw["auth"]["trustedProxy"]["userHeader"], "x-gw-user")
        self.assertEqual(gw["controlUi"]["basePath"], "/gw/user-vkumar4/oss")
        # OpenClaw will not start without a mode, and must serve on loopback only.
        self.assertEqual((gw["mode"], gw["bind"], gw["port"]), ("local", "loopback", oa.SERVICE_PORT))

    def test_model_goes_to_the_provider_endpoint_with_a_placeholder_key(self):
        provider = self.cfg["models"]["providers"]["genai-gateway"]
        self.assertEqual(provider["baseUrl"], LITELLM)
        self.assertEqual(provider["apiKey"], "${OPENAI_API_KEY}")

    def test_exec_is_on_even_without_the_shell_skill_and_no_fetch_proxy(self):
        self.assertEqual(self.cfg["tools"]["exec"], {"security": "full", "ask": "off"})
        self.assertNotIn("web", self.cfg["tools"])


AIGW = "http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1"


class _LiteLLM:
    """LiteLLM's management API: records calls, answers like the real one."""

    def __init__(self, user_exists=False, generate_status=200, models=None, keys=None):
        self.calls, self.user_exists, self.generate_status = [], user_exists, generate_status
        self.models, self.keys = models or [], keys or []

    def __call__(self, path, body):
        self.calls.append((path, body))
        if path == "/model/info":
            return 200, {"data": self.models}
        if path.startswith("/key/list"):
            return 200, {"keys": self.keys}
        if path == "/user/new":
            return (409, "exists") if self.user_exists else (200, {"user_id": body["user_id"]})
        if path == "/key/generate":
            return (self.generate_status, {"key": "sk-agent-own"} if self.generate_status == 200 else "denied")
        return 200, {}


ADMIN = {"LITELLM_ADMIN_KEY": "sk-admin", "OPENSHELL_AGENT_TPM_LIMIT": "50000", "OPENSHELL_USER_RPM_LIMIT": "60"}


class AgentKeyTest(unittest.TestCase):
    def test_each_agent_gets_its_own_key_owned_by_its_user(self):
        ll = _LiteLLM()
        a, client, *_ = _adapter(ADMIN, litellm=ll)
        a.create(_ctx())
        paths = [p for p, _ in ll.calls if p != "/model/info"]
        self.assertEqual(paths, ["/user/new", "/key/delete", "/key/generate"])
        user, gen = ll.calls[0][1], ll.calls[2][1]
        self.assertEqual((user["user_id"], user.get("rpm_limit")), ("vkumar4@example.com", 60))
        self.assertIs(user["auto_create_key"], False)  # else LiteLLM mints the user a key nobody holds
        self.assertEqual((gen["key_alias"], gen["user_id"], gen.get("tpm_limit")),
                         ("agent-vkumar4-oss", "vkumar4@example.com", 50000))
        req = next(r for m, r in client._stub.calls if m == "CreateProvider")
        self.assertEqual(dict(req.provider.credentials), {"OPENAI_API_KEY": "sk-agent-own"})  # not the cluster key

    def test_an_existing_user_is_fine_and_an_existing_provider_mints_nothing(self):
        ll = _LiteLLM(user_exists=True)
        a, *_ = _adapter(ADMIN, litellm=ll)
        a.create(_ctx())
        self.assertIn("/key/generate", [p for p, _ in ll.calls])
        ll2 = _LiteLLM()
        client = _Client()
        client._stub = _Stub(provider_exists=True)
        a2, *_ = _adapter(ADMIN, client=client, litellm=ll2)
        a2.create(_ctx())
        # A key is minted once, with the provider; an existing one is only checked.
        self.assertFalse([p for p, _ in ll2.calls if p in ("/user/new", "/key/generate", "/key/delete")])

    def test_an_agent_key_may_call_models_only(self):
        ll = _LiteLLM()
        a, *_ = _adapter(ADMIN, litellm=ll)
        a.create(_ctx())
        routes = next(b for p, b in ll.calls if p == "/key/generate")["allowed_routes"]
        self.assertIn("/v1/chat/completions", routes)
        self.assertIn("/v1/embeddings", routes)
        for route in ("/key/generate", "/key/list", "/key/info", "/user/new", "/model/info"):
            self.assertNotIn(route, routes)  # the supervisor adds the key to anything the sandbox sends

    def _existing(self, keys):
        ll = _LiteLLM(keys=keys)
        client = _Client()
        client._stub = _Stub(provider_exists=True)
        a, *_ = _adapter(ADMIN, client=client, litellm=ll)
        ctx = _ctx()
        a.create(ctx)
        return ll, ctx

    def test_an_existing_key_with_every_route_is_limited(self):
        ll, ctx = self._existing([{"token": "hash-1", "key_alias": "agent-vkumar4-oss", "allowed_routes": []}])
        self.assertIn("/key/list?key_alias=agent-vkumar4-oss&return_full_object=true", [p for p, _ in ll.calls])
        self.assertIn(("/key/update", {"key": "hash-1", "allowed_routes": oa.AGENT_KEY_ROUTES}), ll.calls)
        ll, _ = self._existing([{"token": "hash-1", "key_alias": "agent-vkumar4-oss",
                                 "allowed_routes": list(reversed(oa.AGENT_KEY_ROUTES))}])
        self.assertNotIn("/key/update", [p for p, _ in ll.calls])  # already limited

    def test_a_failed_limit_is_a_warning_not_a_failed_agent(self):
        def refuses(path, body):
            if path.startswith("/key/list"):
                return 200, {"keys": [{"token": "hash-1", "allowed_routes": []}]}
            return (403, "denied") if path == "/key/update" else (200, {})
        client = _Client()
        client._stub = _Stub(provider_exists=True)
        a, *_ = _adapter(ADMIN, client=client, litellm=refuses)
        ctx = _ctx()
        a.create(ctx)
        self.assertTrue(any("Could not limit" in w for w in ctx.logger.warnings))

    def test_a_refused_key_stops_the_create(self):
        a, client, *_ = _adapter(ADMIN, litellm=_LiteLLM(generate_status=403))
        with self.assertRaises(RuntimeError):
            a.create(_ctx())
        self.assertFalse(any(m == "CreateProvider" for m, _ in client._stub.calls))

    def test_without_an_admin_key_the_cluster_key_is_used(self):
        ll = _LiteLLM()
        a, client, *_ = _adapter(litellm=ll)
        a.create(_ctx())
        self.assertEqual(ll.calls, [])
        req = next(r for m, r in client._stub.calls if m == "CreateProvider")
        self.assertEqual(dict(req.provider.credentials), {"OPENAI_API_KEY": KEY})

    def test_delete_removes_the_agent_s_key(self):
        ll = _LiteLLM()
        a, *_ = _adapter(ADMIN, litellm=ll)
        a.delete(_ctx())
        self.assertIn(("/key/delete", {"key_aliases": ["agent-vkumar4-oss"]}), ll.calls)


class ModelGatewayTest(unittest.TestCase):
    def _config(self, model, env=None):
        a, *_ = _adapter(env)
        ctx = _ctx(skills=["github"])
        ctx.model = model
        return a, ctx, json.loads(a._config_json(ctx))

    def test_genai_gateway_is_the_default_and_its_key_is_a_placeholder(self):
        _, _, cfg = self._config({})
        provider = cfg["models"]["providers"]["genai-gateway"]
        self.assertEqual((provider["baseUrl"], provider["apiKey"]), (LITELLM, "${OPENAI_API_KEY}"))
        self.assertEqual(cfg["agents"]["defaults"]["model"]["primary"], "genai-gateway/qwen")

    def test_ai_gateway_is_reached_directly_with_no_key_when_enabled(self):
        a, ctx, cfg = self._config({"provider": "ai-gateway", "id": "qwen3-coder-30b"}, {"OPENSHELL_AI_GATEWAY_URL": AIGW})
        provider = cfg["models"]["providers"]["ai-gateway"]
        self.assertEqual((provider["baseUrl"], provider["apiKey"]), (AIGW, oa.NO_KEY))
        self.assertEqual(cfg["agents"]["defaults"]["model"]["primary"], "ai-gateway/qwen3-coder-30b")
        hosts = [e["host"] for e in _rules(a, ctx)["network_policies"]["agent_services"]["endpoints"]]
        self.assertIn("ai-gateway.envoy-gateway-system.svc.cluster.local", hosts)

    def test_ai_gateway_falls_back_to_genai_gateway_when_not_enabled(self):
        _, _, cfg = self._config({"provider": "ai-gateway", "id": "qwen3-coder-30b"})
        self.assertEqual(list(cfg["models"]["providers"]), ["genai-gateway"])

    def test_embeddings_go_through_litellm_with_the_agent_s_key_and_no_ai_gateway_rule(self):
        env = {"EMBEDDING_BASE_URL": AIGW, "EMBEDDING_MODEL": "bge-base-en", "OPENSHELL_AI_GATEWAY_URL": AIGW}
        a, ctx, cfg = self._config({"provider": "genai-gateway", "id": "qwen3-coder-30b"}, env)
        search = cfg["agents"]["defaults"]["memorySearch"]
        self.assertEqual((search["model"], search["remote"]), ("bge-base-en", {"baseUrl": LITELLM, "apiKey": "${OPENAI_API_KEY}"}))
        rules = _rules(a, ctx)["network_policies"]
        hosts = [e["host"] for r in rules.values() for e in r["endpoints"]]
        # The AI Gateway answers any model with no key, past LiteLLM's accounting and guardrail.
        self.assertNotIn("ai-gateway.envoy-gateway-system.svc.cluster.local", hosts)

    def test_the_ai_gateway_rule_is_only_for_agents_that_chose_it(self):
        env = {"EMBEDDING_BASE_URL": AIGW, "OPENSHELL_AI_GATEWAY_URL": AIGW}
        a, ctx, cfg = self._config({"provider": "ai-gateway", "id": "qwen3-coder-30b"}, env)
        hosts = [e["host"] for e in _rules(a, ctx)["network_policies"]["agent_services"]["endpoints"]]
        self.assertEqual(hosts, ["ai-gateway.envoy-gateway-system.svc.cluster.local"])
        self.assertEqual(cfg["agents"]["defaults"]["memorySearch"]["remote"]["baseUrl"], LITELLM)

    def test_the_agent_s_context_size_is_used(self):
        _, _, cfg = self._config({"id": "qwen3-4b", "contextWindow": 40960})
        self.assertEqual(cfg["models"]["providers"]["genai-gateway"]["models"][0]["contextWindow"], 40960)


def _entry(name, api_base, max_input_tokens=None):
    return {"model_name": name, "litellm_params": {"api_base": api_base, "model": f"openai/{name}"},
            "model_info": {"max_input_tokens": max_input_tokens}}


class _ModelServers:
    """The model servers' /models: {url: max_model_len}; any other URL is unreachable."""

    def __init__(self, sizes):
        self.sizes, self.calls = sizes, []

    def __call__(self, url):
        self.calls.append(url)
        if url not in self.sizes:
            raise OSError("unreachable")
        return {"data": [{"id": "m", "max_model_len": self.sizes[url]}]}


Q06 = "http://ai-gateway/llm-inference/qwen3-0-6b/v1"
Q17 = "http://ai-gateway/llm-inference/qwen3-1-7b/v1"


class ContextWindowTest(unittest.TestCase):
    """OpenClaw plans for this size: more than the model serves fails long conversations."""

    def _adapter(self, models, servers, env=None):
        ll = _LiteLLM(models=models)
        a, *_ = _adapter({**ADMIN, **(env or {})}, litellm=ll)
        a._fetch_json = servers
        return a, ll

    def _size(self, a, model):
        ctx = _ctx()
        ctx.model = model
        return a._model_vars(ctx)["context_window"], ctx.model_notes

    def test_the_served_size_comes_from_the_model_server_not_litellm_s_published_figure(self):
        # Deployed with --max-model-len=16384; LiteLLM shows the model's published 40960, or nothing.
        a, _ = self._adapter([_entry("qwen3-0-6b", Q06, 40960)], _ModelServers({f"{Q06}/models": 16384}))
        self.assertEqual(a.served_context("qwen3-0-6b"), 16384)

    def test_litellm_s_figure_is_the_fallback_when_the_server_does_not_say(self):
        a, _ = self._adapter([_entry("qwen3-1-7b", Q17, 40960)], _ModelServers({}))
        self.assertEqual(a.served_context("qwen3-1-7b"), 40960)

    def test_an_agent_without_a_size_gets_the_served_size(self):
        a, _ = self._adapter([_entry("qwen3-1-7b", Q17)], _ModelServers({f"{Q17}/models": 40960}))
        self.assertEqual(self._size(a, {"id": "qwen3-1-7b"}), (40960, []))
        self.assertEqual(self._size(a, {"provider": "ai-gateway", "id": "qwen3-1-7b"}), (40960, []))

    def test_a_size_above_the_served_one_is_capped(self):
        a, _ = self._adapter([_entry("qwen3-1-7b", Q17)], _ModelServers({f"{Q17}/models": 40960}))
        size, notes = self._size(a, {"id": "qwen3-1-7b", "contextWindow": 262144})
        self.assertEqual(size, 40960)
        self.assertIn("capped at 40960", notes[0])

    def test_the_cluster_setting_is_capped_too(self):
        # The cluster's own model (qwen) with MODEL_CONTEXT_WINDOW above what it serves.
        a, _ = self._adapter([_entry("qwen", Q17)], _ModelServers({f"{Q17}/models": 40960}),
                             {"MODEL_CONTEXT_WINDOW": "262144"})
        self.assertEqual(self._size(a, {})[0], 40960)

    def test_an_unknown_size_is_the_conservative_fallback_with_a_note(self):
        a, _ = self._adapter([], _ModelServers({}))
        size, notes = self._size(a, {"id": "unlisted"})
        self.assertEqual(size, oa.claw_adapter.FALLBACK_CONTEXT_WINDOW)
        self.assertIn("unknown", notes[0])

    def test_a_model_under_the_minimum_is_noted(self):
        a, _ = self._adapter([_entry("qwen3-0-6b", Q06)], _ModelServers({f"{Q06}/models": 16384}))
        size, notes = self._size(a, {"id": "qwen3-0-6b"})
        self.assertEqual(size, 16384)
        self.assertIn("under the 32768", notes[0])

    def test_sizes_are_cached_and_a_failing_litellm_never_breaks_the_agent(self):
        a, ll = self._adapter([_entry("qwen3-1-7b", Q17)], _ModelServers({f"{Q17}/models": 40960}))
        a.served_context("qwen3-1-7b")
        a.served_context("qwen3-1-7b")
        self.assertEqual([p for p, _ in ll.calls].count("/model/info"), 1)

        def down(path, body):
            raise OSError("connection refused")
        a2, *_ = _adapter(ADMIN, litellm=down)
        self.assertIsNone(a2.served_context("qwen3-1-7b"))

    def test_no_key_goes_to_the_model_server(self):
        servers = _ModelServers({f"{Q17}/models": 40960})
        a, _ = self._adapter([_entry("qwen3-1-7b", Q17)], servers)
        a.served_context("qwen3-1-7b")
        self.assertEqual(servers.calls, [f"{Q17}/models"])  # a bare URL: _get_json sends no header

    def test_without_an_admin_key_nothing_is_looked_up(self):
        ll = _LiteLLM(models=[_entry("qwen3-1-7b", Q17, 40960)])
        a, *_ = _adapter(litellm=ll)
        self.assertIsNone(a.served_context("qwen3-1-7b"))
        self.assertEqual(ll.calls, [])


class LifecycleTest(unittest.TestCase):
    def test_a_namespace_over_19_characters_is_refused(self):
        a, client, *_ = _adapter()
        with self.assertRaises(ValueError):
            a.create(_ctx(name="oss-solo"))  # agent-vkumar4-oss-solo is 22
        self.assertEqual(client.created, [])

    def test_create_builds_the_workspace_provider_and_sandbox(self):
        ws = _Workspaces()
        a, client, k8s, routes_applied = _adapter(workspaces=ws)
        ref = a.create(_ctx())
        self.assertEqual(ref, {"apiVersion": "openshell.ai/v1", "kind": "Sandbox", "name": "oss"})  # the CRD's fields only
        made = [name for name, _ in k8s.calls]
        for call in ("patch_namespace", "create_namespaced_service_account",
                     "create_namespaced_role_binding", "create_namespaced_network_policy"):
            self.assertIn(call, made)
        self.assertNotIn("create_namespaced_role", made)  # bound to the chart's ClusterRole instead
        binding = next(args[1] for name, args in k8s.calls if name == "create_namespaced_role_binding")
        self.assertEqual(binding["role_ref"]["name"], "agent-operator-openshell-workspace")
        self.assertEqual(binding["subjects"][0]["namespace"], "openshell-system")
        self.assertEqual(ws.created, ["agent-vkumar4-oss"])
        method, req = next(c for c in client._stub.calls if c[0] == "CreateProvider")
        self.assertEqual(dict(req.provider.credentials), {"OPENAI_API_KEY": KEY})
        self.assertEqual(req.provider.profile_workspace, "")  # the global profile
        self.assertTrue(routes_applied)  # the identity proxy before the sandbox calls it
        made = client.created[0]
        self.assertEqual((made["workspace"], made["name"]), ("agent-vkumar4-oss", "oss"))
        self.assertEqual(list(made["spec"].providers), ["genai-gateway"])
        self.assertNotIn(KEY, str(made["spec"]))  # the key never enters the sandbox spec
        self.assertEqual(made["service_exposures"][0].target_port, oa.SERVICE_PORT)

    def test_in_the_ambient_mesh_dns_capture_is_off_and_the_tunnel_is_allowed(self):
        a, client, k8s, _ = _adapter(mesh=True)
        a.create(_ctx())
        tmpl = client.created[0]["spec"].template
        self.assertEqual(dict(tmpl.annotations), {oa.DNS_CAPTURE_ANNOTATION: "false"})
        policy = next(args[1] for name, args in k8s.calls
                      if name == "create_namespaced_network_policy" and args[1]["metadata"]["name"] == oa.MESH_POLICY)
        self.assertEqual(policy["spec"]["pod_selector"]["match_labels"], {"openshell.ai/boundary-role": "workload"})
        for rule in policy["spec"]["ingress"] + policy["spec"]["egress"]:
            self.assertEqual([p["port"] for p in rule["ports"]], [oa.MESH_TUNNEL_PORT])

    def test_outside_the_mesh_neither_is_added(self):
        a, client, k8s, _ = _adapter(mesh=False)
        a.create(_ctx())
        self.assertEqual(dict(client.created[0]["spec"].template.annotations), {})
        self.assertFalse(any(name == "create_namespaced_network_policy" and args[1]["metadata"]["name"] == oa.MESH_POLICY
                             for name, args in k8s.calls))

    def test_an_existing_sandbox_and_workspace_are_kept(self):
        client = _Client(exists=True)
        a, client, *_ = _adapter(client=client, workspaces=_Workspaces(exists=True))
        a.create(_ctx())
        self.assertEqual(client.created, [])

    def test_an_existing_sandbox_gets_the_current_policy_and_a_changed_config(self):
        client = _Client(exists=True)
        a, client, *_ = _adapter(client=client)
        a.create(_ctx())
        self.assertIn("UpdateConfig", [m for m, _ in client._stub.calls])
        writes = [stdin for argv, stdin in client.execs if argv[-1] == oa.CONFIG_PATH and stdin]
        self.assertEqual(len(writes), 1)  # the fake's config is empty, so it differs
        self.assertTrue(any("pkill" in " ".join(argv) for argv, _ in client.execs))

    def test_an_unchanged_config_is_not_rewritten_or_restarted(self):
        client = _Client(exists=True)
        a, client, *_ = _adapter(client=client)
        current = a._config_json(_ctx())
        client.exec = lambda name, argv, **kw: (client.execs.append((argv, kw.get("stdin"))),
                                               types.SimpleNamespace(exit_code=0, stdout=current, stderr=""))[1]
        a.create(_ctx())
        self.assertEqual([argv for argv, _ in client.execs], [["cat", oa.CONFIG_PATH]])

    def test_suspend_and_resume_fall_back_to_stop_and_start(self):
        client = _Client()
        client.unavailable = ("suspend", "resume")
        a, client, *_ = _adapter(client=client)
        a.suspend(_ctx())
        a.resume(_ctx())
        self.assertEqual(client.calls, ["suspend", "stop", "resume", "start", "wait_ready"])

    def test_an_update_restarts_openclaw_without_matching_its_own_shell(self):
        a, client, *_ = _adapter()
        a.update(_ctx(), reseed=False)
        restart = [argv for argv, _ in client.execs if "pkill" in " ".join(argv)]
        self.assertEqual(len(restart), 1)
        self.assertIn("'[o]penclaw-gateway'", restart[0][-1])  # 'openclaw-gateway' would match sh -c itself
        self.assertNotIn(" openclaw-gateway", restart[0][-1])

    def test_seeding_writes_safe_paths_only_and_decodes_base64(self):
        a, client, *_ = _adapter()
        ctx = _ctx(files={"AGENTS.md": "hi", "../etc/x": "no", "bin/run": "base64:" + base64.b64encode(b"\x01").decode()})
        a._seed_files(ctx, ctx.workspace_files)
        written = {argv[-1]: stdin for argv, stdin in client.execs}
        self.assertEqual(written, {f"{oa.WORKSPACE}/AGENTS.md": b"hi", f"{oa.WORKSPACE}/bin/run": b"\x01"})
        self.assertTrue(any("unsafe" in w for w in ctx.logger.warnings))

    def test_service_host_is_what_the_gateway_route_targets(self):
        self.assertEqual(oa.service_host("agent-vkumar4-oss", "oss"),
                         "agent-vkumar4-oss--oss--openclaw.openshell.localhost")


if __name__ == "__main__":
    unittest.main()
