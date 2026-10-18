# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Memory server authorization: only a verified, correctly scoped token reaches a schema."""
import time
import types
import unittest

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

import memory

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ISSUER = "https://keycloak.example.com/realms/agent-toolkit"


def _token(key=KEY, **claims):
    body = {"iss": ISSUER, "aud": "mcp-memory", "azp": "agent-alice-lab", "iat": int(time.time()),
            "exp": int(time.time()) + 300, "memory_schema": "agent_alice_lab",
            "scope": "mcp-memory tools:memory.read tools:memory.write"}
    body.update(claims)
    return jwt.encode({k: v for k, v in body.items() if v is not None}, key, algorithm="RS256")


class AuthTest(unittest.TestCase):
    def setUp(self):
        memory._token_cache.clear()
        signing = types.SimpleNamespace(key=KEY.public_key())
        self.headers = {}
        for name, value in (("_issuer", lambda: ISSUER),
                            ("_jwks", lambda: types.SimpleNamespace(get_signing_key_from_jwt=lambda t: signing)),
                            ("get_http_headers", lambda include=None: self.headers)):
            self.addCleanup(setattr, memory, name, getattr(memory, name))
            setattr(memory, name, value)

    def _as(self, token):
        self.headers = {"authorization": f"Bearer {token}"}

    def test_a_valid_token_yields_its_own_schema(self):
        self._as(_token())
        self.assertEqual(memory._caller(memory.SCOPE_WRITE), ("agent_alice_lab", "agent-alice-lab"))

    def test_no_bearer_is_refused(self):
        with self.assertRaises(memory.AuthError):
            memory._caller(memory.SCOPE_READ)

    def test_forged_or_misdirected_tokens_are_refused(self):
        for token in (_token(key=OTHER_KEY), _token(aud="mcp-sandbox"), _token(iss="https://evil"),
                      _token(exp=int(time.time()) - 10), _token(scope="mcp-sandbox tools:memory.read"),
                      _token(memory_schema="public"), _token(memory_schema=None), _token(azp=None)):
            memory._token_cache.clear()
            self._as(token)
            with self.assertRaises(memory.AuthError):
                memory._caller(memory.SCOPE_READ)

    def test_a_denied_operation_is_refused(self):
        self._as(_token(scope="mcp-memory tools:memory.read"))
        self.assertEqual(memory._caller(memory.SCOPE_READ)[0], "agent_alice_lab")
        with self.assertRaises(memory.AuthError):
            memory._caller(memory.SCOPE_WRITE)

    def test_the_cache_holds_no_token(self):
        token = _token()
        self._as(token)
        memory._caller(memory.SCOPE_READ)
        self.assertNotIn(token, repr(memory._token_cache))

    def test_only_known_tiers_reach_sql(self):
        for bad in ("auto; DROP", "users", ""):
            with self.assertRaises(ValueError):
                memory._tier(bad)


if __name__ == "__main__":
    unittest.main(verbosity=2)
