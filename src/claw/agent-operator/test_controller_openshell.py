# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""The openshell runtime in the controller: admission, and the route to the sandbox."""
import types
import unittest

from testlib import ApiException, Logger, Patch, load_controller, spec

C = load_controller()
C.GW_HOSTNAME, C.KEYCLOAK_ISSUER = "agents.example.com", "https://keycloak.example.com/realms/agent-toolkit"


class _Adapter:
    def create(self, ctx):
        raise AssertionError("reconcile continued past a guard")


class _Grants:
    def list_namespaced_custom_object(self, group, version, ns, plural):
        return {"items": []}


class RuntimeAdmissionTest(unittest.TestCase):
    def setUp(self):
        saved = dict(C.ADAPTERS)
        self.addCleanup(lambda: (C.ADAPTERS.clear(), C.ADAPTERS.update(saved)))
        C.ADAPTERS.clear()
        C.ADAPTERS.update(claw=_Adapter(), openshell=_Adapter())
        saved_providers = C.OPENSHELL_MODEL_PROVIDERS
        self.addCleanup(lambda: setattr(C, "OPENSHELL_MODEL_PROVIDERS", saved_providers))
        C.OPENSHELL_MODEL_PROVIDERS = ["genai-gateway", "ai-gateway"]  # a cluster with LiteLLM

    def _reconcile(self, name, username, **extra):
        patch, logger = Patch(), Logger()
        C._reconcile(spec(username, **extra), patch, name, f"user-{username}", logger, resuming=False)
        return patch.status

    def test_a_runtime_that_is_not_enabled_fails(self):
        C.ADAPTERS.pop("openshell")
        status = self._reconcile("oss", "vkumar4", runtime="openshell")
        self.assertEqual(status["phase"], "Failed")
        self.assertIn("runtime 'openshell' is not enabled", status["suspendReason"])

    def test_a_long_namespace_fails_and_says_how_long_the_name_may_be(self):
        status = self._reconcile("oss-solo", "vkumar4", runtime="openshell")
        self.assertEqual(status["phase"], "Failed")
        self.assertIn("'agent-vkumar4-oss-solo' is 22", status["suspendReason"])
        self.assertIn("at most 5 characters", status["suspendReason"])  # 19 - len("agent-vkumar4-")

    def test_a_username_with_no_room_says_so(self):
        status = self._reconcile("a", "averyverylonguser", runtime="openshell")
        self.assertIn("leaves no room", status["suspendReason"])

    def test_the_same_long_name_is_fine_for_claw(self):
        self.assertIsNone(C._runtime_error("oss-solo", spec("vkumar4"), "agent-vkumar4-oss-solo"))

    def test_an_unknown_model_provider_fails_for_openshell(self):
        status = self._reconcile("oss", "vkumar4", runtime="openshell", model={"provider": "openai", "id": "gpt"})
        self.assertIn("model provider", status["suspendReason"])
        self.assertIsNone(C._runtime_error("oss", spec("vkumar4", runtime="openshell", model={"provider": "genai-gateway"}),
                                           "agent-vkumar4-oss"))

    def test_without_litellm_a_genai_gateway_agent_is_told_what_to_change(self):
        C.OPENSHELL_MODEL_PROVIDERS = ["ai-gateway"]
        status = self._reconcile("oss", "vkumar4", runtime="openshell", model={"provider": "genai-gateway", "id": "x"})
        self.assertEqual(status["phase"], "Failed")
        self.assertIn("needs LiteLLM", status["suspendReason"])
        self.assertIn("set the agent's model provider to ai-gateway", status["suspendReason"])

    def test_without_litellm_only_the_ai_gateway_is_offered(self):
        litellm = {"OPENSHELL_MODEL_BASE_URL": "http://litellm/v1", "OPENSHELL_AI_GATEWAY_URL": "http://aigw/v1"}
        self.assertEqual(C.openshell_model_providers(litellm), ["genai-gateway", "ai-gateway"])
        self.assertEqual(C.openshell_model_providers({"OPENSHELL_MODEL_BASE_URL": "http://litellm/v1"}), ["genai-gateway"])
        self.assertEqual(C.openshell_model_providers({}), ["ai-gateway"])
        self.assertEqual(C.openshell_model_providers({"OPENSHELL_AI_GATEWAY_URL": "http://aigw/v1"}), ["ai-gateway"])

    def test_a_custom_model_endpoint_fails_for_openshell(self):
        status = self._reconcile("oss", "vkumar4", runtime="openshell", model={"baseUrl": "http://x.example/v1"})
        self.assertIn("not supported", status["suspendReason"])


class OpenShellRouteTest(unittest.TestCase):
    def setUp(self):
        C.kubernetes.client = types.SimpleNamespace(CustomObjectsApi=lambda: _Grants(), ApiException=ApiException)
        self.route, self.policy, _, _ = C._gw_objects("oss", spec("vkumar4", runtime="openshell"))

    def test_both_rules_go_to_the_openshell_gateway_with_the_sandbox_host(self):
        host = "agent-vkumar4-oss--oss--openclaw.openshell.localhost"
        for rule in self.route["spec"]["rules"]:
            # The chart's Backend: HTTP/1.1-only TLS to the gateway, which the WebSocket needs.
            self.assertEqual(rule["backendRefs"], [{"group": "gateway.envoyproxy.io", "kind": "Backend",
                                                    "name": "agent-operator-openshell", "namespace": "openshell-system",
                                                    "port": 8080}])
            hostnames = [f["urlRewrite"].get("hostname") for f in rule["filters"] if f["type"] == "URLRewrite"]
            self.assertEqual(hostnames, [host])

    def test_the_chat_rule_still_strips_the_prefix_and_the_credentials(self):
        chat = self.route["spec"]["rules"][0]
        rewrite = next(f for f in chat["filters"] if f["type"] == "URLRewrite")["urlRewrite"]
        self.assertEqual(rewrite["path"], {"type": "ReplacePrefixMatch", "replacePrefixMatch": "/v1/"})
        self.assertIn({"type": "RequestHeaderModifier", "requestHeaderModifier": {"remove": ["Authorization", "Cookie"]}},
                      chat["filters"])

    def test_the_owner_check_is_unchanged(self):
        self.assertEqual(self.policy["spec"]["authorization"]["defaultAction"], "Deny")


class ModelContextConditionTest(unittest.TestCase):
    def test_a_resolved_size_is_true_and_an_assumed_or_capped_one_is_a_false_warning(self):
        ok = C._model_context_condition(types.SimpleNamespace(context_window=40960, model_notes=[]))
        self.assertEqual((ok["type"], ok["status"], ok["reason"], ok["message"]),
                         ("ModelContext", "True", "Resolved", "40960 tokens"))
        warn = C._model_context_condition(types.SimpleNamespace(
            context_window=32768, model_notes=["the context size of 'x' is unknown; assumed 32768"]))
        self.assertEqual((warn["status"], warn["reason"]), ("False", "SizeAdjusted"))
        self.assertIn("assumed 32768", warn["message"])

    def test_no_condition_before_the_model_is_rendered(self):
        self.assertIsNone(C._model_context_condition(types.SimpleNamespace()))


if __name__ == "__main__":
    unittest.main()
