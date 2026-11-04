# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Sandbox server: one sandbox per proven caller, adopted after restarts, never leaked."""
import ast
import datetime
import hashlib
import os
import types
import unittest

import sandbox
from testlib import AuthCase, token

CONTROLLER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "agent-operator", "controller.py")


class _Sandbox:
    def __init__(self, claim, alive=True):
        self.claim_name, self.alive, self.ran, self.terminated = claim, alive, [], False
        self.commands = types.SimpleNamespace(run=self._run)

    def _run(self, cmd):
        if not self.alive:
            raise RuntimeError("gone")
        self.ran.append(cmd)
        return types.SimpleNamespace(stdout="out", stderr="", exit_code=0)

    def terminate(self):
        self.terminated = True


class _Client:
    """agent-sandbox SDK stand-in holding claims as {name: (labels, sandbox, age_seconds)}."""

    def __init__(self):
        self.claims, self.created, self.deleted, self.patched = {}, [], [], []
        self.k8s_helper = types.SimpleNamespace(patch_sandbox_claim=lambda n, ns, body: self.patched.append(n),
                                                get_sandbox_claim=self._get_claim)

    def _get_claim(self, name, ns):
        born = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=self.claims[name][2])
        return {"metadata": {"creationTimestamp": born.strftime("%Y-%m-%dT%H:%M:%SZ")}}

    def list_all_sandboxes(self, namespace, label_selector):
        want = dict(kv.split("=") for kv in label_selector.split(","))
        return [n for n, (labels, _, _) in self.claims.items() if want.items() <= labels.items()]

    def get_sandbox(self, name, namespace):
        return self.claims[name][1]

    def create_sandbox(self, warmpool, namespace, sandbox_ready_timeout, labels, shutdown_after_seconds):
        name = f"claim-{len(self.claims)}"
        self.claims[name] = (labels, _Sandbox(name), 0)
        self.created.append((warmpool, labels, shutdown_after_seconds))
        return self.claims[name][1]

    def delete_sandbox(self, name, namespace):
        self.deleted.append(name)
        self.claims.pop(name, None)


class SandboxCase(AuthCase):
    audience = "mcp-sandbox"

    def setUp(self):
        super().setUp()
        self.client = _Client()
        for name, value in (("_client", self.client), ("_sessions", {}), ("_last_used", {})):
            self.addCleanup(setattr, sandbox, name, getattr(sandbox, name))
            setattr(sandbox, name, value)

    def as_agent(self, azp, scope="tools:shell"):
        self.call_as(token("mcp-sandbox", scope, azp=azp))


class SessionTest(SandboxCase):
    def test_each_agent_gets_its_own_labelled_leased_sandbox(self):
        for azp in ("agent-alice-helper", "agent-bob-helper", "agent-alice-helper"):
            self.as_agent(azp)
            self.assertIn("out", sandbox.execute_python("print(1)"))
        self.assertEqual(len(self.client.created), 2)
        pool, labels, lease = self.client.created[0]
        self.assertEqual((pool, lease), (sandbox.WARMPOOL, sandbox.LEASE))
        self.assertEqual(labels, {sandbox.OWNER_LABEL: sandbox.OWNER_LABEL_VALUE,
                                  sandbox.SESSION_LABEL: sandbox.session_label("agent-alice-helper")})

    def test_a_restarted_server_adopts_the_agent_s_claim_before_creating(self):
        labels = {sandbox.OWNER_LABEL: sandbox.OWNER_LABEL_VALUE,
                  sandbox.SESSION_LABEL: sandbox.session_label("agent-alice-lab")}
        self.client.claims = {"live": (labels, _Sandbox("live"), 60), "dup": (labels, _Sandbox("dup"), 60)}
        self.as_agent("agent-alice-lab")
        sandbox.execute_shell("ls")
        self.assertEqual((self.client.created, self.client.deleted, self.client.patched), ([], ["dup"], ["live"]))

    def test_a_dead_sandbox_is_replaced(self):
        self.as_agent("agent-alice-lab")
        sandbox.execute_shell("ls")
        sandbox._sessions["agent-alice-lab"].alive = False
        self.client.claims.clear()
        sandbox.execute_shell("ls")
        self.assertEqual(len(self.client.created), 2)

    def test_without_the_shell_scope_nothing_runs(self):
        self.as_agent("agent-alice-lab", scope="tools:memory.read")
        self.assertIn("not entitled", sandbox.execute_shell("id"))
        self.assertEqual(self.client.created, [])

    def test_reset_terminates_only_the_caller_s_sandbox(self):
        for azp in ("agent-alice-lab", "agent-bob-lab"):
            self.as_agent(azp)
            sandbox.execute_shell("true")
        bob = sandbox._sessions["agent-bob-lab"]
        sandbox.reset_sandbox()
        self.assertTrue(bob.terminated)
        self.assertIn("agent-alice-lab", sandbox._sessions)


class ReaperTest(SandboxCase):
    def test_idle_sessions_end_live_ones_renew_and_old_orphans_go(self):
        self.as_agent("agent-alice-lab")
        sandbox.execute_shell("true")
        live = sandbox._sessions["agent-alice-lab"]
        owner = {sandbox.OWNER_LABEL: sandbox.OWNER_LABEL_VALUE}
        self.client.claims.update({"young": (owner, _Sandbox("young"), 10),
                                   "old": (owner, _Sandbox("old"), sandbox.ORPHAN_GRACE + 1)})
        sandbox._reap_once()
        self.assertEqual((self.client.patched, self.client.deleted), ([live.claim_name], ["old"]))
        sandbox._last_used["agent-alice-lab"] -= sandbox.IDLE_TIMEOUT
        sandbox._reap_once()
        self.assertTrue(live.terminated)


class CommandTest(unittest.TestCase):
    def test_commands_run_in_sh_with_the_sandbox_env_and_quoted(self):
        cmd = sandbox._sh("echo 'it''s'; id")
        self.assertTrue(cmd.startswith("sh -c '"))
        self.assertIn("HOME=/tmp", cmd)


class OperatorContractTest(unittest.TestCase):
    """The operator deletes an agent's claims by the labels this server sets."""

    def test_both_sides_use_the_same_labels_and_hash(self):
        with open(CONTROLLER) as fh:
            tree = ast.parse(fh.read())
        consts = {t.id: ast.literal_eval(n.value) for n in tree.body if isinstance(n, ast.Assign)
                  for t in n.targets if isinstance(t, ast.Name) and isinstance(n.value, ast.Constant)}
        self.assertEqual((consts["SANDBOX_OWNER_LABEL"], consts["SANDBOX_OWNER_LABEL_VALUE"],
                          consts["SANDBOX_SESSION_LABEL"]),
                         (sandbox.OWNER_LABEL, sandbox.OWNER_LABEL_VALUE, sandbox.SESSION_LABEL))
        self.assertEqual(sandbox.session_label("agent-alice-lab"),
                         hashlib.sha256(b"agent-alice-lab").hexdigest()[:32])


if __name__ == "__main__":
    unittest.main(verbosity=2)
