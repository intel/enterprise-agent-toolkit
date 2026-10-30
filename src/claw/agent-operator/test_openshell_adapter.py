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
    def __init__(self):
        self.calls = []

    def __getattr__(self, method):
        def call(request, timeout=None):
            self.calls.append((method, request))
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


def _adapter(env=None, client=None, workspaces=None, mesh=False):
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
    a = oa.OpenShellAdapter(core, cfg, client_factory=lambda: client)
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

    def test_the_agent_s_context_size_is_used(self):
        _, _, cfg = self._config({"id": "qwen3-4b", "contextWindow": 40960})
        self.assertEqual(cfg["models"]["providers"]["genai-gateway"]["models"][0]["contextWindow"], 40960)


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
        self.assertEqual(ref["kind"], "Sandbox")
        made = [name for name, _ in k8s.calls]
        for call in ("patch_namespace", "create_namespaced_service_account",
                     "create_namespaced_role_binding", "create_namespaced_network_policy"):
            self.assertIn(call, made)
        self.assertNotIn("create_namespaced_role", made)  # bound to the chart's ClusterRole instead
        binding = next(args[1] for name, args in k8s.calls if name == "create_namespaced_role_binding")
        self.assertEqual(binding["role_ref"]["name"], "agent-operator-openshell-workspace")
        self.assertEqual(binding["subjects"][0]["namespace"], "openshell-system")
        self.assertEqual(ws.created, ["agent-vkumar4-oss"])
        method, req = client._stub.calls[0]
        self.assertEqual(method, "CreateProvider")
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

    def test_suspend_and_resume_fall_back_to_stop_and_start(self):
        client = _Client()
        client.unavailable = ("suspend", "resume")
        a, client, *_ = _adapter(client=client)
        a.suspend(_ctx())
        a.resume(_ctx())
        self.assertEqual(client.calls, ["suspend", "stop", "resume", "start", "wait_ready"])

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
