# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""The operator holds pods/exec one agent namespace at a time, never cluster-wide."""
import os
import types
import unittest

from testlib import CHART_TEMPLATES, ApiException, Logger, load_controller


class _Obj:
    def __init__(self, **kw):
        self.__dict__.update(kw)


class _Rbac:
    def __init__(self, fail=None):
        self.calls, self.fail = [], fail or {}

    def _do(self, op, *a):
        self.calls.append((op, *a))
        if op in self.fail:
            raise ApiException(self.fail[op])

    def create_namespaced_role_binding(self, ns, obj):
        self._do("create_binding", ns, obj)

    def replace_namespaced_role_binding(self, name, ns, obj):
        self._do("replace_binding", name, ns, obj)


class GrantAgentNsExecTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_controller()

    def _run(self, fail=None):
        rbac = _Rbac(fail)
        self.mod.kubernetes.client = types.SimpleNamespace(
            RbacAuthorizationV1Api=lambda: rbac, ApiException=ApiException,
            V1ObjectMeta=_Obj, V1RoleRef=_Obj, RbacV1Subject=_Obj,
            V1RoleBinding=lambda **kw: _Obj(kind="RoleBinding", **kw))
        log = Logger()
        self.mod._grant_agent_ns_exec("agent-alice-bot", log)
        return rbac, log

    def test_binds_the_exec_clusterrole_in_the_agent_namespace(self):
        rbac, _ = self._run()
        binding = rbac.calls[0][2]
        self.assertEqual(binding.role_ref.kind, "ClusterRole")
        self.assertEqual(binding.role_ref.name, self.mod.AGENT_NS_EXEC_CLUSTER_ROLE)
        self.assertEqual(binding.metadata.namespace, "agent-alice-bot")

    def test_the_operator_is_the_only_subject(self):
        rbac, _ = self._run()
        subjects = [(s.name, s.namespace) for s in rbac.calls[0][2].subjects]
        self.assertEqual(subjects, [(self.mod.OPERATOR_SA_NAME, self.mod.OPERATOR_NAMESPACE)])

    def test_an_existing_binding_is_replaced_quietly(self):
        rbac, log = self._run(fail={"create_binding": 409})
        self.assertIn("replace_binding", [c[0] for c in rbac.calls])
        self.assertEqual(log.warnings + log.errors, [])

    def test_a_refusal_is_an_error_and_does_not_raise(self):
        for fail in ({"create_binding": 403}, {"create_binding": 409, "replace_binding": 403}):
            _, log = self._run(fail=fail)
            self.assertEqual(len(log.errors), 1)
            self.assertIn(self.mod.AGENT_NS_EXEC_CLUSTER_ROLE, log.errors[0])


@unittest.skipUnless(os.path.isdir(CHART_TEMPLATES), "chart not in this build context")
class ChartAgreementTest(unittest.TestCase):
    """Runs from the repository; the image build context holds only the source."""

    def setUp(self):
        self.mod = load_controller()

    @staticmethod
    def _read(name):
        with open(os.path.join(CHART_TEMPLATES, name)) as fh:
            return "\n".join(line.split("#")[0] for line in fh)

    def _rule(self, resource):
        role = self._read("rbac.yaml")
        return role.split(f'resources: ["{resource}"]')[1].split("- apiGroups")[0]

    def test_no_cluster_wide_exec(self):
        self.assertNotIn("pods/exec", self._read("rbac.yaml"))

    def test_the_exec_clusterrole_has_the_name_the_code_binds(self):
        exec_role = self._read("clusterrole-agent-ns-exec.yaml")
        self.assertIn(f"name: {self.mod.AGENT_NS_EXEC_CLUSTER_ROLE}", exec_role)
        self.assertIn("pods/exec", exec_role)

    def test_bind_is_narrowed_to_that_clusterrole(self):
        role = self._read("rbac.yaml")
        self.assertIn(f'resourceNames: ["{self.mod.AGENT_NS_EXEC_CLUSTER_ROLE}"]', role)

    def test_rolebindings_can_be_updated_but_roles_not_written(self):
        self.assertIn("update", self._rule("rolebindings"))
        self.assertNotIn('resources: ["roles"]', self._read("rbac.yaml"))

    def test_secrets_cannot_be_listed(self):
        self.assertNotIn("list", self._rule("secrets"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
