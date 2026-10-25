# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""The per-agent gateway route: who the platform gateway admits, and what reaches the agent."""
import datetime
import types
import unittest

from testlib import ApiException, Logger, load_controller, spec

C = load_controller()
C.GW_HOSTNAME, C.KEYCLOAK_ISSUER = "agents.example.com", "https://keycloak.example.com/realms/agent-toolkit"


def _iso(minutes):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=minutes)).isoformat()


def _grant(grantee, caps=("converse",), minutes=60, grantor="alice@example.com", agent="lab"):
    return {"spec": {"agentRef": agent, "grantor": grantor, "grantee": grantee,
                     "capabilities": list(caps), "expiresAt": _iso(minutes)}}


class _Grants:
    def __init__(self, items):
        self.items = items

    def list_namespaced_custom_object(self, group, version, ns, plural):
        return {"items": self.items}


def _with_grants(items):
    C.kubernetes.client = types.SimpleNamespace(CustomObjectsApi=lambda: _Grants(items), ApiException=ApiException)


class AllowedTest(unittest.TestCase):
    def test_the_owner_and_live_converse_grantees_only(self):
        _with_grants([_grant("bob@example.com"), _grant("carol@example.com", caps=("view",)),
                      _grant("dave@example.com", minutes=-1), _grant("eve@example.com", grantor="mallory@example.com"),
                      _grant("frank@example.com", agent="other")])
        self.assertEqual(C._gw_allowed("lab", spec("alice")), ["alice@example.com", "bob@example.com"])


class RouteTest(unittest.TestCase):
    def setUp(self):
        _with_grants([])
        self.route, self.policy, self.grant = C._gw_objects("lab", spec("alice"))

    def test_the_route_is_the_agent_path_and_strips_the_user_s_credentials(self):
        rules = self.route["spec"]["rules"]
        self.assertEqual([r["matches"][0]["path"]["value"] for r in rules], ["/gw/user-alice/lab/v1/", "/gw/user-alice/lab"])
        for r in rules:
            self.assertIn({"type": "RequestHeaderModifier", "requestHeaderModifier": {"remove": ["Authorization", "Cookie"]}},
                          r["filters"])
            self.assertEqual(r["backendRefs"], [{"name": "lab", "namespace": "agent-alice-lab", "port": 18789}])

    def test_the_policy_signs_in_verifies_and_denies_by_default(self):
        p = self.policy["spec"]
        self.assertEqual(p["authorization"]["defaultAction"], "Deny")
        self.assertEqual(p["authorization"]["rules"][0]["principal"]["jwt"]["claims"],
                         [{"name": "email", "values": ["alice@example.com"]},
                          {"name": "email_verified_string", "values": ["true"]}])
        self.assertEqual(p["authorization"]["rules"][0]["principal"]["jwt"]["scopes"], ["agent:converse"])
        self.assertEqual(p["jwt"]["providers"][0]["claimToHeaders"], [{"claim": "email", "header": "x-gw-user"}])
        self.assertEqual(p["jwt"]["providers"][0]["audiences"], ["agent-backend"])
        self.assertEqual(p["oidc"]["redirectURL"], "https://agents.example.com/gw/user-alice/lab/oauth2/callback")
        self.assertTrue(p["oidc"]["passThroughAuthHeader"])
        self.assertEqual(p["oidc"]["cookieConfig"], {"sameSite": "Lax"})

    def test_only_this_route_may_reach_only_this_service(self):
        self.assertEqual(self.grant["metadata"]["namespace"], "agent-alice-lab")
        self.assertEqual(self.grant["spec"]["to"], [{"group": "", "kind": "Service", "name": "lab"}])
        self.assertEqual(self.grant["spec"]["from"][0]["namespace"], C.OPERATOR_NAMESPACE)


class _Api(_Grants):
    """Records writes; the SecurityPolicy write fails when asked to."""

    def __init__(self, policy_fails):
        super().__init__([])
        self.policy_fails, self.written, self.deleted = policy_fails, [], []

    def get_namespaced_custom_object(self, group, version, ns, plural, name):
        raise ApiException(404)

    def create_namespaced_custom_object(self, group, version, ns, plural, body):
        if self.policy_fails and body["kind"] == "SecurityPolicy":
            raise ApiException(422)
        self.written.append(body["kind"])

    def delete_namespaced_custom_object(self, group, version, ns, plural, name):
        self.deleted.append(plural)


class ApplyOrderTest(unittest.TestCase):
    def _apply(self, policy_fails):
        api = _Api(policy_fails)
        C.kubernetes.client = types.SimpleNamespace(CustomObjectsApi=lambda: api, ApiException=ApiException)
        C._apply_gateway_route("lab", spec("alice"), Logger())
        return api

    def test_the_policy_is_written_before_the_route(self):
        api = self._apply(policy_fails=False)
        self.assertEqual(api.written, ["SecurityPolicy", "HTTPRoute", "ReferenceGrant"])
        self.assertEqual(api.deleted, [])

    def test_no_route_is_left_without_its_policy(self):
        # Otherwise the agent would be reachable without signing in.
        api = self._apply(policy_fails=True)
        self.assertEqual(api.written, [])
        self.assertEqual(api.deleted, ["httproutes"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
