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
            # The HTTP/1.1 Service, not the chart's appProtocol-grpc one (the WebSocket needs it).
            self.assertEqual(rule["backendRefs"], [{"name": "openshell-routes", "namespace": "openshell-system", "port": 8080}])
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


if __name__ == "__main__":
    unittest.main()
