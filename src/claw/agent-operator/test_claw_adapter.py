# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""claw adapter: tool and identity wiring, model credentials, workspace seeding, rendering."""
import json
import types
import unittest
import urllib.parse

import claw_adapter

MCP = {
    "memory": "http://mcp-memory-server.agent-operator-system.svc.cluster.local:8000/sse",
    "sandbox": "http://mcp-sandbox-server.agent-sandbox-system.svc.cluster.local:8000/sse",
    "github": "http://mcp-github-server.agent-operator-system.svc.cluster.local:8000/sse",
}
PAT = "ghp-alice-own-pat"
# The controller's resolved Tool table, as core.tools() returns it.
TOOLS = {
    "memory": {"url": MCP["memory"], "requiresIdentity": True, "alwaysOn": True, "aliases": []},
    "sandbox": {"url": MCP["sandbox"], "requiresIdentity": True, "alwaysOn": False, "aliases": ["shell"]},
    "github": {"url": MCP["github"], "requiresIdentity": True, "alwaysOn": False, "aliases": []},
}


class _Logger:
    def __init__(self):
        self.warnings, self.errors = [], []

    def warning(self, m):
        self.warnings.append(m)

    def error(self, m):
        self.errors.append(m)

    def info(self, m):
        pass


class _Ctx:
    def __init__(self, skills, github_token="", model=None, model_api_key="", workspace=None):
        self.name = "lab"
        self.namespace = "agent-alice-lab"
        self.cr_namespace = "user-alice"
        self.memory_schema = "agent_alice_lab"
        self.owner = "alice@example.com"
        self.skills, self.custom_tools, self.tools_deny = skills, [], []
        self.github_token, self.model, self.model_api_key = github_token, model or {}, model_api_key
        self.workspace_files = workspace or {}
        self.logger = _Logger()


def _adapter(port_span=16, env=None, tools=None):
    env = {"MODEL_ID": "qwen", "MODEL_PROVIDER": "ai-gateway",
           "MODEL_BASE_URL": "http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1",
           "MODEL_CONTEXT_WINDOW": "32768", **(env or {})}
    core = types.SimpleNamespace(
        k8s=types.SimpleNamespace(client=None), tools=lambda: TOOLS if tools is None else tools,
        identity_proxy_port_base=8901, identity_proxy_port_span=port_span,
        web_fetch_proxy_enabled=False, web_fetch_proxy_port=8888)
    return claw_adapter.ClawAdapter(core, claw_adapter.config_from_env(env))


class IdentityWiringTest(unittest.TestCase):
    def test_every_identity_tool_has_a_route_and_points_at_it(self):
        ctx = _Ctx(["github", "shell"])
        servers, routes = _adapter()._mcp_wiring(ctx)
        # shell aliases sandbox; memory is always on.
        self.assertEqual(set(servers), {"memory", "github", "sandbox"})
        for skill, server in servers.items():
            split = urllib.parse.urlsplit(server["url"])
            self.assertEqual(split.hostname, f"identity-proxy.{ctx.namespace}.svc.cluster.local")
            self.assertEqual(routes[split.port], {"url": MCP[skill], "scope": f"mcp-{skill}"})
            self.assertEqual(split.path, "/sse")

    def test_ports_are_stable_across_reconciles(self):
        first = _adapter()._mcp_wiring(_Ctx(["github", "shell"]))[1]
        second = _adapter()._mcp_wiring(_Ctx(["shell", "github"]))[1]
        self.assertEqual(first, second)

    def test_span_overflow_omits_the_tool_instead_of_calling_it_unproxied(self):
        ctx = _Ctx(["github", "shell"])
        servers, routes = _adapter(port_span=2)._mcp_wiring(ctx)
        self.assertEqual(len(routes), 2)
        self.assertTrue(any("exceeds" in w for w in ctx.logger.warnings))
        self.assertEqual(len(servers), 2)
        self.assertTrue(all("identity-proxy" in s["url"] for s in servers.values()))


class GithubTokenTest(unittest.TestCase):
    """The PAT goes to the identity proxy's Secret; the route names the file, never the value."""

    def _github_route(self, ctx):
        servers, routes = _adapter()._mcp_wiring(ctx)
        return servers, routes[urllib.parse.urlsplit(servers["github"]["url"]).port]

    def test_the_pat_is_in_neither_the_config_nor_the_route(self):
        servers, route = self._github_route(_Ctx(["github"], github_token=PAT))
        self.assertNotIn(PAT, json.dumps(servers) + json.dumps(route))
        self.assertEqual(route["credHeaders"], {"X-Agent-Github-Token": "github_token"})

    def test_the_route_file_is_the_secret_key(self):
        ctx = _Ctx(["github"], github_token=PAT)
        _, route = self._github_route(ctx)
        self.assertEqual(set(route["credHeaders"].values()),
                         set(claw_adapter.ClawAdapter._tool_credentials(ctx)))

    def test_no_pat_means_no_header_and_an_empty_secret(self):
        ctx = _Ctx(["github"])
        _, route = self._github_route(ctx)
        self.assertNotIn("credHeaders", route)
        self.assertEqual(claw_adapter.ClawAdapter._tool_credentials(ctx), {})

    def test_only_the_github_route_carries_it(self):
        _, routes = _adapter()._mcp_wiring(_Ctx(["github", "shell"], github_token=PAT))
        self.assertEqual([r["scope"] for r in routes.values() if "credHeaders" in r], ["mcp-github"])


class ToolSelectionTest(unittest.TestCase):
    def _servers(self, skills, tools=None):
        return set(_adapter(tools=tools)._mcp_wiring(_Ctx(skills))[0])

    def test_an_alias_wires_its_tool(self):
        self.assertEqual(self._servers(["shell"]), {"memory", "sandbox"})

    def test_a_tool_without_the_alias_is_not_wired(self):
        tools = {**TOOLS, "sandbox": {**TOOLS["sandbox"], "aliases": []}}
        self.assertEqual(self._servers(["shell"], tools), {"memory"})

    def test_an_unregistered_skill_wires_nothing(self):
        self.assertEqual(self._servers(["github"], {"memory": TOOLS["memory"]}), {"memory"})

    def test_a_tool_without_identity_is_called_directly(self):
        tools = {"docs": {"url": "http://docs.tools.svc:8000/sse", "requiresIdentity": False,
                          "alwaysOn": True, "aliases": []}}
        servers, routes = _adapter(tools=tools)._mcp_wiring(_Ctx([]))
        self.assertEqual((servers["docs"]["url"], routes), ("http://docs.tools.svc:8000/sse", {}))


class GatewayAuthTest(unittest.TestCase):
    def _gateway(self, env=None):
        adapter = _adapter(env=env)
        adapter.core.apply_identity_proxy = lambda *a, **k: None
        adapter._ensure_model_key_secret = lambda ctx: "lab-model-api-key"
        return adapter._render_instance(_Ctx(["shell"]))["spec"]["config"]

    def test_with_trusted_proxies_the_gateway_takes_the_user_from_the_platform_gateway(self):
        cfg = self._gateway({"GATEWAY_TRUSTED_PROXIES": "10.233.64.0/18"})
        gw = cfg["raw"]["gateway"]
        self.assertEqual((gw["trustedProxies"], gw["auth"]["mode"], gw["auth"]["trustedProxy"]["userHeader"]),
                         (["10.233.64.0/18"], "trusted-proxy", "x-gw-user"))
        self.assertEqual(gw["controlUi"]["basePath"], "/gw/user-alice/lab")
        self.assertIn("gateway.auth.token", cfg["forcePaths"])

    def test_without_them_the_gateway_keeps_token_auth(self):
        cfg = self._gateway()
        self.assertNotIn("auth", cfg["raw"]["gateway"])
        self.assertNotIn("gateway.auth.token", cfg["forcePaths"])


class ModelTest(unittest.TestCase):
    def test_the_cluster_default_is_used_without_an_override(self):
        v = _adapter()._model_vars(_Ctx([]))
        self.assertEqual((v["model_ref"], v["context_window"]), ("ai-gateway/qwen", 32768))

    def test_an_override_drops_the_cluster_context_window(self):
        v = _adapter()._model_vars(_Ctx([], model={"id": "other"}))
        self.assertEqual((v["model_id"], v["context_window"]), ("other", 0))

    def test_the_cluster_key_never_goes_to_an_agent_chosen_endpoint(self):
        adapter = _adapter(env={"MODEL_API_KEY": "cluster-key"})
        self.assertEqual(adapter._model_key(_Ctx([])), "cluster-key")
        self.assertEqual(adapter._model_key(_Ctx([], model={"baseUrl": "https://x.example/v1"})),
                         claw_adapter.NO_KEY)
        self.assertEqual(adapter._model_key(_Ctx([], model={"baseUrl": "https://x"}, model_api_key="own")),
                         "own")

    def test_an_empty_key_becomes_the_placeholder(self):
        self.assertEqual(_adapter()._model_key(_Ctx([])), claw_adapter.NO_KEY)

    def test_the_runtime_image_defaults_to_a_digest(self):
        cfg = claw_adapter.config_from_env({})
        self.assertTrue(cfg["openclawDigest"].startswith("sha256:"))
        self.assertNotEqual(cfg["openclawTag"], "latest")


class SeedTest(unittest.TestCase):
    def _seed(self, files):
        adapter, calls = _adapter(), []
        adapter._exec = lambda ctx, argv, stdin: calls.append((argv, stdin))
        ctx = _Ctx([])
        adapter._seed_files(ctx, files)
        return calls, ctx

    def test_paths_are_arguments_not_script_text(self):
        calls, _ = self._seed({"skills/x/SKILL.md": "hi"})
        argv, stdin = calls[0]
        self.assertEqual(argv[4], f"{claw_adapter.WORKSPACE}/skills/x/SKILL.md")
        self.assertNotIn("SKILL.md", argv[2])
        self.assertEqual(argv[5], str(len(stdin)))

    def test_unsafe_paths_are_skipped(self):
        bad = {"../etc/passwd": "x", 'a"; rm -rf /; echo "': "x", "$(id)": "x", "a/../../b": "x"}
        calls, ctx = self._seed(bad)
        self.assertEqual(calls, [])
        self.assertEqual(len(ctx.logger.warnings), len(bad))

    def test_base64_content_is_passed_through(self):
        calls, _ = self._seed({"logo.png": "base64:AAEC"})
        self.assertEqual(calls[0][1], "AAEC")


class _FakeK8s:
    """Records JSON patches and applies them, so idempotence is observable."""

    def __init__(self, live_spec):
        self.patches, self.deleted, outer = [], [], self
        self.live = {"spec": live_spec}

        class ApiException(Exception):
            def __init__(self, status=500):
                self.status = status

        class CustomObjectsApi:
            def get_namespaced_custom_object(self, **kw):
                return outer.live

            @property
            def api_client(self):
                class Client:
                    def call_api(self, path, method, body=None, **kw):
                        outer.patches.append(body)
                        for op in body:
                            outer.live["spec"][op["path"].split("/")[-1]] = op["value"]
                return Client()

        class CoreV1Api:
            def create_namespaced_secret(self, ns, body):
                raise ApiException(409)

            def replace_namespaced_secret(self, *a):
                pass

            def list_namespaced_pod(self, ns, label_selector=None):
                return types.SimpleNamespace(items=[types.SimpleNamespace(
                    metadata=types.SimpleNamespace(name="lab-0"))])

            def delete_namespaced_pod(self, name, ns):
                outer.deleted.append(name)

        self.client = types.SimpleNamespace(
            CustomObjectsApi=CustomObjectsApi, CoreV1Api=CoreV1Api, ApiException=ApiException,
            V1Secret=lambda **kw: kw, V1ObjectMeta=lambda **kw: kw)


class ReconcileTest(unittest.TestCase):
    def _adapter(self, live_spec):
        adapter = _adapter()
        adapter.k8s = adapter.core.k8s = fake = _FakeK8s(live_spec)
        adapter.core.apply_identity_proxy = lambda *a, **k: None
        return adapter, fake

    def test_a_stale_config_is_patched_and_the_pod_rolled_once(self):
        adapter, fake = self._adapter({"config": {"raw": {"stale": True}}})
        self.assertTrue(adapter._patch_instance(_Ctx(["shell"])))
        self.assertFalse(adapter._patch_instance(_Ctx(["shell"])))
        self.assertEqual((len(fake.patches), fake.deleted), (1, ["lab-0"]))

    def test_a_removed_skill_is_removed_from_the_config(self):
        adapter, fake = self._adapter({})
        adapter._patch_instance(_Ctx(["github"]))
        adapter._patch_instance(_Ctx([]))
        servers = fake.live["spec"]["config"]["raw"]["mcp"]["servers"]
        self.assertNotIn("github", servers)


class RenderTest(unittest.TestCase):
    """Renders the real template (needs Jinja2 and PyYAML)."""

    def _spec(self, ctx, **env):
        adapter = _adapter(env=env)
        adapter.core.apply_identity_proxy = lambda *a, **k: None
        adapter._ensure_model_key_secret = lambda c: f"{c.name}-model-api-key"
        return adapter._render_instance(ctx)["spec"]

    def test_the_instance_is_pinned_isolated_and_credential_free(self):
        spec = self._spec(_Ctx(["github"], github_token=PAT))
        self.assertTrue(spec["image"]["digest"].startswith("sha256:"))
        self.assertFalse(spec["shareProcessNamespace"])
        self.assertFalse(spec["autoUpdate"]["enabled"])
        self.assertFalse(spec["security"]["networkPolicy"]["enabled"])
        self.assertEqual(spec["gateway"]["existingSecret"], "lab-gateway-token")
        self.assertNotIn(PAT, json.dumps(spec))
        key_ref = next(e for e in spec["env"] if e["name"] == "OPENAI_API_KEY")["valueFrom"]
        self.assertEqual(key_ref["secretKeyRef"], {"name": "lab-model-api-key", "key": "apiKey"})

    def test_the_context_window_and_compaction_follow_the_model(self):
        raw = self._spec(_Ctx([]))["config"]["raw"]
        model = raw["models"]["providers"]["ai-gateway"]["models"][0]
        self.assertEqual(model["contextWindow"], 32768)
        self.assertEqual(raw["agents"]["defaults"]["compaction"]["reserveTokensFloor"], 0)
        raw = self._spec(_Ctx([], model={"id": "other"}))["config"]["raw"]
        self.assertNotIn("compaction", raw["agents"]["defaults"])

    def test_agent_supplied_model_fields_cannot_inject_yaml(self):
        evil = 'x"\n  sidecars: [{name: pwn, image: evil}]\n#'
        spec = self._spec(_Ctx([], model={"id": evil, "name": evil, "baseUrl": evil}))
        self.assertNotIn("sidecars", spec)
        self.assertEqual(spec["config"]["raw"]["models"]["providers"]["ai-gateway"]["models"][0]["id"], evil)

    def test_plugins_and_mcp_are_always_present(self):
        raw = self._spec(_Ctx([]))["config"]["raw"]
        self.assertEqual(raw["plugins"], {"allow": []})
        self.assertIn("servers", raw["mcp"])

    def test_optional_blocks_are_omitted_when_unset(self):
        spec = self._spec(_Ctx([]))
        self.assertNotIn("memorySearch", spec["config"]["raw"]["agents"]["defaults"])
        self.assertNotIn("allowedOrigins", spec["config"]["raw"]["gateway"]["controlUi"])
        self.assertNotIn("HTTP_PROXY", [e["name"] for e in spec["env"]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
