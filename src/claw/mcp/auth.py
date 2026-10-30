# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Caller identity for the MCP servers.

Every call carries a Keycloak token minted by the agent's identity proxy. It must be signed by
the realm, issued for this server's audience (requested as a scope, so a token for another
server is refused) and hold the operation's permission scope. `azp` is the agent's client id.
"""
import functools
import hashlib
import os
import time

import jwt
import requests
from fastmcp.server.dependencies import get_http_headers

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "").rstrip("/")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "agent-toolkit")
MCP_AUDIENCE = os.environ.get("MCP_AUDIENCE", "")
_cache = {}  # sha256(token) -> (claims, expiry); never the token itself


class AuthError(Exception):
    pass


@functools.lru_cache(maxsize=1)
def _jwks():
    return jwt.PyJWKClient(f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/certs")


@functools.lru_cache(maxsize=1)
def _issuer():
    """The realm's advertised issuer; tokens carry it, not the in-cluster URL."""
    if os.environ.get("KEYCLOAK_ISSUER"):
        return os.environ["KEYCLOAK_ISSUER"]
    resp = requests.get(f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/.well-known/openid-configuration",
                        timeout=10)
    resp.raise_for_status()
    return resp.json()["issuer"]


def _verify(token):
    try:
        claims = jwt.decode(token, _jwks().get_signing_key_from_jwt(token).key, algorithms=["RS256"],
                            audience=MCP_AUDIENCE, issuer=_issuer(),
                            options={"require": ["exp", "iat", "azp"]})
    except jwt.InvalidTokenError as e:
        raise AuthError(f"identity token rejected: {e}")
    if MCP_AUDIENCE not in (claims.get("scope") or "").split():
        raise AuthError(f"token was not minted for {MCP_AUDIENCE}")
    return claims


def caller(required_scope):
    """Verified claims of the calling agent, if its token holds `required_scope`."""
    raw = get_http_headers(include={"authorization"}).get("authorization", "")
    if not raw.lower().startswith("bearer "):
        raise AuthError("no bearer token — calls must come through the agent's identity proxy")
    token = raw[7:].strip()
    key = hashlib.sha256(token.encode()).hexdigest()
    cached = _cache.get(key)
    if not cached or cached[1] - time.time() <= 30:
        claims = _verify(token)
        cached = _cache[key] = (claims, float(claims["exp"]))
        for stale in [k for k, (_, exp) in _cache.items() if exp < time.time()]:
            _cache.pop(stale, None)
    claims = cached[0]
    if required_scope not in (claims.get("scope") or "").split():
        raise AuthError(f"this agent is not entitled to '{required_scope}'")
    return claims
