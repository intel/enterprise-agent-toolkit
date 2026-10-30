# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Derived names and tenancy: agent-<username>-<name> must map to exactly one owner and agent."""
import types
import unittest

from testlib import ApiException, Logger, Patch, load_controller, spec

C = load_controller()


class UsernameShapeTest(unittest.TestCase):
    def test_hyphen_is_refused(self):
        # "ab-c"+"bot" and "ab"+"c-bot" would otherwise derive the same namespace.
        for u in ("ab-c", "a-b", "-x", "x-", "a--b"):
            with self.assertRaises(ValueError, msg=u) as cm:
                C._owner_username(spec(u))
            self.assertIn("malformed", str(cm.exception))

    def test_alphanumeric_1_to_39_is_accepted(self):
        for u in ("v", "devuser", "agent007", "a" * 39):
            self.assertEqual(C._owner_username(spec(u)), u)

    def test_everything_else_is_refused(self):
        # The username reaches Postgres DDL, so the charset is an allowlist.
        for u in ("a" * 40, "jean.luc", "a_b", "Bob", "bob!", "a b", ""):
            with self.assertRaises(ValueError, msg=u):
                C._owner_username(spec(u))

    def test_absent_username_says_so(self):
        with self.assertRaises(ValueError) as cm:
            C._owner_username({"owner": {"principal": "x@example.com"}})
        self.assertIn("required", str(cm.exception))


class DerivedNamesTest(unittest.TestCase):
    def test_every_derived_name_uses_the_same_key(self):
        s = spec("devuser")
        self.assertEqual(C._agent_ns("my-agent", s), "agent-devuser-my-agent")
        self.assertEqual(C._kc_client_id("my-agent", s), "agent-devuser-my-agent")
        self.assertEqual(C._memory_schema("my-agent", s), "agent_devuser_my_agent")
        self.assertEqual(C._owner_ns(s), "user-devuser")

    def test_the_ambiguous_pair_cannot_be_built(self):
        self.assertEqual(C._agent_ns("c-bot", spec("ab")), "agent-ab-c-bot")
        with self.assertRaises(ValueError):
            C._agent_ns("bot", spec("ab-c"))


class _Adapter:
    def create(self, ctx):
        raise AssertionError("reconcile continued past a guard")


class ReconcileGuardTest(unittest.TestCase):
    """Guards run before anything touches the cluster, so these run offline."""

    def setUp(self):
        self.saved = C.ADAPTER
        C.ADAPTER = _Adapter()
        self.addCleanup(setattr, C, "ADAPTER", self.saved)

    def _reconcile(self, name, username, namespace=None):
        patch, logger = Patch(), Logger()
        C._reconcile(spec(username), patch, name, namespace or f"user-{username}", logger,
                     resuming=False)
        return patch, logger

    def test_an_agent_outside_its_owner_namespace_is_refused(self):
        # Otherwise any Agent could name another owner and act on their resources.
        patch, _ = self._reconcile("bot", "alice", namespace="user-bob")
        self.assertEqual(patch.status["phase"], "Failed")
        self.assertIn("must be created in namespace 'user-alice'", patch.status["suspendReason"])

    def test_a_64_char_derived_name_is_refused(self):
        patch, logger = self._reconcile("b" * 18, "a" * 39)
        self.assertEqual(patch.status["phase"], "Failed")
        self.assertIn("64 chars, limit 63", patch.status["suspendReason"])
        self.assertTrue(any("Rejecting" in w for w in logger.warnings))

    def test_exactly_63_is_within_the_limit(self):
        self.assertEqual(len(C._agent_ns("b" * 17, spec("a" * 39))), C._MAX_DERIVED_NAME)

    def test_a_malformed_username_fails_instead_of_raising(self):
        patch, _ = self._reconcile("bot", "ab-c", namespace="user-ab-c")
        self.assertEqual(patch.status["phase"], "Failed")
        self.assertIn("malformed", patch.status["suspendReason"])

    def test_a_name_starting_with_a_digit_is_refused(self):
        patch, _ = self._reconcile("1bot", "alice")
        self.assertEqual(patch.status["phase"], "Failed")
        self.assertIn("malformed", patch.status["suspendReason"])

    def test_the_platform_namespaces_are_reserved(self):
        for username in ("operator", "sandbox"):
            patch, _ = self._reconcile("system", username)
            self.assertEqual(patch.status["phase"], "Failed")
            self.assertIn("reserved for the platform", patch.status["suspendReason"])

    def test_the_owner_check_ignores_malformed_specs(self):
        self.assertFalse(C._owner_ns_matches(spec("ab-c"), "user-ab-c"))
        self.assertTrue(C._owner_ns_matches(spec("alice"), "user-alice"))


class _Core:
    def __init__(self, labels=None, missing=False):
        self.labels, self.missing = labels or {}, missing
        self.created, self.patched, self.deleted = [], [], []

    def read_namespace(self, ns):
        if self.missing:
            raise ApiException(404)
        return types.SimpleNamespace(metadata=types.SimpleNamespace(labels=self.labels))

    def create_namespace(self, body):
        self.created.append(body)

    def patch_namespace(self, ns, body):
        self.patched.append(body)

    def delete_namespace(self, ns):
        self.deleted.append(ns)


def _install_core(core):
    C.kubernetes.client = types.SimpleNamespace(
        CoreV1Api=lambda: core, ApiException=ApiException,
        V1Namespace=lambda **kw: kw, V1ObjectMeta=lambda **kw: kw)


class NamespaceOwnershipTest(unittest.TestCase):
    def test_a_namespace_claimed_by_another_agent_is_not_adopted(self):
        _install_core(_Core({C.AGENT_LABEL: "other", C.OWNER_LABEL: "alice_at_example.com"}))
        with self.assertRaises(ValueError):
            C._ensure_namespace("agent-alice-bot", "alice@example.com", "bot", Logger())

    def test_a_namespace_the_operator_did_not_create_is_not_adopted(self):
        # Adopting it would later delete it with the agent.
        for labels in ({}, {C.AGENT_LABEL: "bot", C.OWNER_LABEL: "alice_at_example.com"}):
            core = _Core(labels)
            _install_core(core)
            with self.assertRaises(ValueError):
                C._ensure_namespace("agent-alice-bot", "alice@example.com", "bot", Logger())
            self.assertEqual(core.patched, [])

    def test_its_own_namespace_is_reconciled(self):
        core = _Core({**C.MANAGED_BY, C.AGENT_LABEL: "bot", C.OWNER_LABEL: "alice_at_example.com"})
        _install_core(core)
        C._ensure_namespace("agent-alice-bot", "alice@example.com", "bot", Logger())
        self.assertEqual(core.patched[0]["metadata"]["labels"][C.AGENT_LABEL], "bot")

    def test_teardown_leaves_a_namespace_it_does_not_own(self):
        core = _Core({C.AGENT_LABEL: "bot"})  # no managed-by label
        _install_core(core)
        C._delete_agent_namespace("agent-alice-bot", "bot", Logger())
        self.assertEqual(core.deleted, [])

    def test_teardown_deletes_its_own_namespace(self):
        core = _Core({**C.MANAGED_BY, C.AGENT_LABEL: "bot"})
        _install_core(core)
        C._delete_agent_namespace("agent-alice-bot", "bot", Logger())
        self.assertEqual(core.deleted, ["agent-alice-bot"])


class PermissionScopeTest(unittest.TestCase):
    def test_a_scope_is_withheld_only_when_every_tool_it_covers_is_denied(self):
        granted = C._granted_permission_scopes({"toolsDeny": ["memory_write"]})
        self.assertNotIn("tools:memory.write", granted)
        self.assertIn("tools:memory.read", granted)

    def test_server_prefixed_names_and_globs_deny_too(self):
        granted = C._granted_permission_scopes(
            {"toolsDeny": ["github__create_issue", "github__add_issue_comment", "*branch",
                           "commit_file", "create_pull_request", "mark_pr_ready"]})
        self.assertNotIn("tools:github.write", granted)
        self.assertIn("tools:github.read", granted)

    def test_no_deny_grants_everything(self):
        self.assertEqual(set(C._granted_permission_scopes({})), set(C.PERMISSION_SCOPES))


if __name__ == "__main__":
    unittest.main(verbosity=2)
