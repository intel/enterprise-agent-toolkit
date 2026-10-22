# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""*SecretRef reads never fail silently and never log the credential."""
import base64
import types
import unittest

from testlib import Logger, load_controller

NS = "agent-devuser-oss"


class _Core:
    def __init__(self, data=None, boom=None):
        self.data, self.boom, self.reads = data, boom, []

    def read_namespaced_secret(self, name, namespace):
        self.reads.append((name, namespace))
        if self.boom:
            raise self.boom
        return types.SimpleNamespace(data=self.data)


def _b64(s):
    return base64.b64encode(s.encode()).decode()


class ReadSecretKeyTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_controller()
        self.log = Logger()

    def _read(self, core, secret_name="my-pat", key="token"):
        self.mod.kubernetes.client.CoreV1Api = lambda: core
        ctx = types.SimpleNamespace(namespace=NS, name="oss", logger=self.log)
        return self.mod.AgentContext._read_secret_key(ctx, secret_name, key)

    def test_a_present_value_is_decoded_quietly(self):
        core = _Core({"token": _b64("ghp_realtoken")})
        self.assertEqual(self._read(core), "ghp_realtoken")
        self.assertEqual(self.log.warnings, [])
        self.assertEqual(core.reads, [("my-pat", NS)])

    def test_an_unset_ref_reads_nothing_and_says_nothing(self):
        core = _Core({"token": _b64("x")})
        self.assertIsNone(self._read(core, secret_name=None))
        self.assertEqual((self.log.warnings, core.reads), ([], []))

    def test_an_empty_value_and_a_missing_key_are_told_apart(self):
        for data, word, other in (({"token": ""}, "empty", "absent"),
                                  ({"pat": _b64("x")}, "absent", "empty"),
                                  (None, "absent", "empty")):
            self.log.warnings.clear()
            self.assertIsNone(self._read(_Core(data)))
            self.assertEqual(len(self.log.warnings), 1)
            self.assertIn(word, self.log.warnings[0])
            self.assertNotIn(other, self.log.warnings[0])

    def test_an_unreadable_secret_warns_and_does_not_raise(self):
        self.assertIsNone(self._read(_Core(boom=RuntimeError("(404) not found"))))
        self.assertIn("unreadable", self.log.warnings[0])

    def test_no_warning_carries_the_secret(self):
        secret = "ghp_donotlogme"
        for core in (_Core({"token": ""}), _Core({"pat": _b64(secret)}), _Core(None),
                     _Core(boom=RuntimeError("(403) forbidden"))):
            self.log.warnings.clear()
            self._read(core)
            for w in self.log.warnings:
                self.assertNotIn(secret, w)
                self.assertNotIn(_b64(secret), w)

    def test_the_warning_says_where_to_look(self):
        self._read(_Core({"token": ""}), key="apiKey")
        for expected in ("my-pat", "'apiKey'", NS, "oss"):
            self.assertIn(expected, self.log.warnings[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
