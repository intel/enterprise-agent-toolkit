# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""An agent's sandboxes are deleted when it is suspended or deleted, and only its own."""
import hashlib
import types
import unittest

from testlib import ApiException, Logger, Patch, load_controller, spec

C = load_controller()


class _Claims:
    def __init__(self, names=(), list_error=None, delete_errors=None):
        self.names, self.list_error, self.delete_errors = list(names), list_error, delete_errors or {}
        self.selectors, self.deleted = [], []

    def list_namespaced_custom_object(self, label_selector, **kw):
        self.selectors.append((kw["namespace"], label_selector))
        if self.list_error:
            raise self.list_error
        return {"items": [{"metadata": {"name": n}} for n in self.names]}

    def delete_namespaced_custom_object(self, name, **kw):
        if name in self.delete_errors:
            raise self.delete_errors[name]
        self.deleted.append(name)


def _install(claims):
    C.kubernetes.client = types.SimpleNamespace(CustomObjectsApi=lambda: claims, ApiException=ApiException)


class ReapTest(unittest.TestCase):
    def test_only_this_agent_s_claims_are_selected_and_all_are_deleted(self):
        claims = _Claims(["a", "b"])
        _install(claims)
        self.assertEqual(C._reap_agent_sandboxes("lab", spec("alice"), Logger(), "test"), 2)
        session = hashlib.sha256(b"agent-alice-lab").hexdigest()[:32]
        self.assertEqual(claims.selectors, [(C.SANDBOX_NAMESPACE, f"{C.SANDBOX_OWNER_LABEL}="
                                             f"{C.SANDBOX_OWNER_LABEL_VALUE},{C.SANDBOX_SESSION_LABEL}={session}")])
        self.assertEqual(claims.deleted, ["a", "b"])

    def test_owners_with_the_same_agent_name_have_different_sessions(self):
        self.assertNotEqual(C._sandbox_session_hash("lab", spec("alice")), C._sandbox_session_hash("lab", spec("bob")))

    def test_no_agent_sandbox_or_no_grant_is_quiet(self):
        for status in (403, 404):
            log = Logger()
            _install(_Claims(list_error=ApiException(status)))
            self.assertEqual(C._reap_agent_sandboxes("lab", spec("alice"), log, "test"), 0)
            self.assertEqual(log.warnings, [])

    def test_other_failures_are_reported_and_do_not_stop_the_rest(self):
        log = Logger()
        _install(_Claims(list_error=ApiException(500)))
        C._reap_agent_sandboxes("lab", spec("alice"), log, "test")
        self.assertEqual(len(log.warnings), 1)
        claims = _Claims(["gone", "refused", "ok"],
                         delete_errors={"gone": ApiException(404), "refused": ApiException(403)})
        _install(claims)
        log = Logger()
        self.assertEqual(C._reap_agent_sandboxes("lab", spec("alice"), log, "test"), 1)
        self.assertEqual((claims.deleted, len(log.warnings)), (["ok"], 1))

    def test_an_agent_without_a_valid_owner_is_skipped(self):
        _install(_Claims(["a"]))
        self.assertEqual(C._reap_agent_sandboxes("lab", {"owner": {}}, Logger(), "test"), 0)


class TeardownPathsTest(unittest.TestCase):
    def setUp(self):
        self.reaped = []
        adapter = types.SimpleNamespace(suspend=lambda ctx: None, resume=lambda ctx: None)
        stubs = {"_reap_agent_sandboxes": lambda name, s, log, reason: self.reaped.append(reason),
                 "_get_adapter": lambda: adapter, "AgentContext": lambda *a: None}
        for name, value in stubs.items():
            self.addCleanup(setattr, C, name, getattr(C, name))
            setattr(C, name, value)

    def test_suspend_frees_the_sandbox_and_resume_does_not(self):
        s = spec("alice")
        C.on_desired_state(new="Suspended", old="Running", status={"phase": "Running"}, spec=s,
                           name="lab", namespace="user-alice", patch=Patch(), logger=Logger())
        C.on_desired_state(new="Running", old="Suspended", status={"phase": "IdleSuspended"}, spec=s,
                           name="lab", namespace="user-alice", patch=Patch(), logger=Logger())
        self.assertEqual(self.reaped, ["suspended"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
