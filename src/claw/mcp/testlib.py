# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Signed test tokens and a patched realm for the MCP servers' auth."""
import os
import time
import types
import unittest

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

os.environ.setdefault("MCP_AUDIENCE", "mcp-test")
import auth  # noqa: E402

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
ISSUER = "https://keycloak.example.com/realms/agent-toolkit"


def token(audience, scope, key=KEY, scope_claim=None, **claims):
    """A signed token whose `scope` holds the audience plus `scope`, unless scope_claim is given."""
    body = {"iss": ISSUER, "aud": audience, "azp": "agent-alice-lab", "iat": int(time.time()),
            "exp": int(time.time()) + 300, "scope": scope_claim or f"{audience} {scope}"}
    body.update(claims)
    return jwt.encode({k: v for k, v in body.items() if v is not None}, key, algorithm="RS256")


class AuthCase(unittest.TestCase):
    """Patches the realm (issuer, JWKS) and the request headers of auth for one audience."""
    audience = "mcp-test"

    def setUp(self):
        auth._cache.clear()
        signing = types.SimpleNamespace(key=KEY.public_key())
        self.headers = {}
        for name, value in (("_issuer", lambda: ISSUER),
                            ("_jwks", lambda: types.SimpleNamespace(get_signing_key_from_jwt=lambda t: signing)),
                            ("get_http_headers", lambda include=None: self.headers),
                            ("MCP_AUDIENCE", self.audience)):
            self.addCleanup(setattr, auth, name, getattr(auth, name))
            setattr(auth, name, value)

    def call_as(self, tok):
        auth._cache.clear()
        self.headers = {"authorization": f"Bearer {tok}"}
