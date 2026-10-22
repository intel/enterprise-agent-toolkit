# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Memory server: the schema comes only from the caller's verified token."""
import unittest

import auth
import memory
from testlib import AuthCase, token


class MemoryCallerTest(AuthCase):
    audience = "mcp-memory"

    def _token(self, **claims):
        return token("mcp-memory", "tools:memory.read tools:memory.write",
                     memory_schema=claims.pop("memory_schema", "agent_alice_lab"), **claims)

    def test_the_schema_and_client_come_from_the_token(self):
        self.call_as(self._token())
        self.assertEqual(memory._caller(memory.SCOPE_WRITE), ("agent_alice_lab", "agent-alice-lab"))

    def test_a_missing_or_foreign_schema_is_refused(self):
        for schema in (None, "public", "pg_catalog", 'agent_x"; drop'):
            self.call_as(self._token(memory_schema=schema))
            with self.assertRaises(auth.AuthError):
                memory._caller(memory.SCOPE_READ)

    def test_only_known_tiers_reach_sql(self):
        for bad in ("auto; DROP", "users", ""):
            with self.assertRaises(ValueError):
                memory._table("agent_alice_lab", bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
