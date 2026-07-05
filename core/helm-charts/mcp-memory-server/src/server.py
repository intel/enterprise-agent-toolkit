"""
MCP Memory Server — backend-agnostic per-agent memory adapter.

Exposes MCP tools (SSE transport) that any agent runtime (OpenClaw, Hermes, ...)
can call to read/write persistent memory. Storage is pgvector; embeddings via
LiteLLM (OpenAI-compatible /v1/embeddings).

Per-agent isolation: each agent has a Postgres schema `agent_{name}` with one
table per memory tier (claudemd, project, auto). The operator provisions these
on agent creation; this server only reads/writes them.

Authorization (private-only model): a caller may access ONLY its own schema.
The operator injects the agent's OWN Keycloak client credentials as static
transport headers (X-Agent-Client-Id / X-Agent-Client-Secret) that the LLM
cannot forge. On each call this server mints a token from those creds, verifies
it via JWKS, extracts the caller identity (azp = "agent-{name}"), and rejects
any call whose requested `agent` != caller. Cross-agent knowledge must flow
through the secured dispatch channel (a lead asks a worker), never by reading
another agent's schema directly.

Tools:
  memory_write(agent, content, tier="auto", metadata=None) -> str
  memory_read(agent, query, tier="auto", limit=5)          -> list
  memory_list_tiers(agent)                                 -> list
"""

import os
import json
import logging

from fastmcp import FastMCP
from fastmcp.server.dependencies import get_http_headers

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PGVECTOR_DSN = os.environ.get("PGVECTOR_DSN", "")
LITELLM_URL = os.environ.get("LITELLM_URL", "http://genai-gateway-service.genai-gateway.svc.cluster.local:4000/v1")
LITELLM_API_KEY = os.environ.get("LITELLM_API_KEY", "sk-no-key")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "BAAI/bge-base-en-v1.5")
TIERS = ("claudemd", "project", "auto")

# ── Authorization config ────────────────────────────────────────────────────
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "master")
# Enforce per-agent isolation when auth is explicitly enabled OR Keycloak is
# configured. Set MEMORY_AUTH_ENABLED=false to disable (dev only).
_auth_env = os.environ.get("MEMORY_AUTH_ENABLED", "")
if _auth_env:
    MEMORY_AUTH_ENABLED = _auth_env.lower() == "true"
else:
    MEMORY_AUTH_ENABLED = bool(KEYCLOAK_URL)

CLIENT_ID_HEADER = "x-agent-client-id"
CLIENT_SECRET_HEADER = "x-agent-client-secret"
TOKEN_ENDPOINT_HEADER = "x-agent-token-endpoint"
AGENT_ID_HEADER = "x-agent-id"        # dev-mode identity (unverified) + display
_AGENT_PREFIX = "agent-"

if not MEMORY_AUTH_ENABLED:
    logger.warning("MEMORY_AUTH_ENABLED is FALSE — identity is taken from the "
                   "X-Agent-Id header WITHOUT cryptographic proof (dev mode).")


class AuthError(Exception):
    """Raised when the caller's identity cannot be established."""


# Short-lived cache of minted+verified tokens keyed by client_id, to avoid a
# Keycloak round-trip on every call. Value: (caller_name, expiry_epoch).
_token_cache = {}


def _caller_agent():
    """Return the calling agent's name — the sole source of the target schema.

    There is NO `agent` tool argument: an agent can only ever act on its OWN
    memory, so cross-agent access is not even expressible.

    Enforced mode (MEMORY_AUTH_ENABLED): identity is PROVEN by minting a token
    from the agent's own Keycloak client creds (injected as unforgeable transport
    headers) and verifying it via JWKS; the name comes from the token's `azp`.

    Dev mode: identity is read from the X-Agent-Id header without proof.
    """
    import time

    headers = get_http_headers(include={
        CLIENT_ID_HEADER, CLIENT_SECRET_HEADER, TOKEN_ENDPOINT_HEADER, AGENT_ID_HEADER})

    if not MEMORY_AUTH_ENABLED:
        name = headers.get(AGENT_ID_HEADER, "")
        if not name:
            raise AuthError("missing X-Agent-Id header (dev mode)")
        return name

    client_id = headers.get(CLIENT_ID_HEADER, "")
    client_secret = headers.get(CLIENT_SECRET_HEADER, "")
    token_endpoint = headers.get(TOKEN_ENDPOINT_HEADER, "") or \
        f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token"

    if not client_id or not client_secret:
        raise AuthError("missing agent identity headers")

    # Serve from cache if the token is still comfortably valid.
    cached = _token_cache.get(client_id)
    now = time.time()
    if cached and cached[1] - now > 30:
        return cached[0]

    import requests
    r = requests.post(token_endpoint, data={
        "grant_type": "client_credentials",
        "client_id": client_id, "client_secret": client_secret,
    }, timeout=10)
    if r.status_code != 200:
        raise AuthError(f"identity token mint failed: {r.status_code}")
    kc_token = r.json().get("access_token", "")

    import jwt
    from jwt import PyJWKClient
    jwks_url = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/certs"
    signing_key = PyJWKClient(jwks_url).get_signing_key_from_jwt(kc_token)
    claims = jwt.decode(kc_token, signing_key.key, algorithms=["RS256"],
                        options={"verify_aud": False})

    # Identity marker: azp / client_id == "agent-{name}"
    azp = claims.get("azp") or claims.get("client_id") or ""
    if not azp.startswith(_AGENT_PREFIX):
        raise AuthError(f"token identity '{azp}' is not an agent client")
    caller = azp[len(_AGENT_PREFIX):]
    exp = float(claims.get("exp", now))
    _token_cache[client_id] = (caller, exp)
    return caller


mcp = FastMCP("memory")


def _schema(agent):
    return "agent_" + agent.replace("-", "_")


def _validate_tier(tier):
    if tier not in TIERS:
        raise ValueError(f"invalid tier '{tier}', must be one of {TIERS}")


def _embed(text):
    """Get an embedding vector from LiteLLM."""
    import requests
    resp = requests.post(
        f"{LITELLM_URL}/embeddings",
        headers={"Authorization": f"Bearer {LITELLM_API_KEY}", "Content-Type": "application/json"},
        json={"model": EMBEDDING_MODEL, "input": text},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]


def _vec_literal(vec):
    """Render a Python float list as a pgvector literal string."""
    return "[" + ",".join(str(float(x)) for x in vec) + "]"


@mcp.tool(description="Store a memory in YOUR OWN memory. tier: claudemd|project|auto (default auto). "
                      "Operates only on the calling agent's memory — there is no target-agent parameter.")
def memory_write(content: str, tier: str = "auto", metadata: dict = None) -> str:
    try:
        agent = _caller_agent()
        _validate_tier(tier)
        import psycopg
        emb = _embed(content)
        schema = _schema(agent)
        meta_json = json.dumps(metadata or {})
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            conn.execute(
                f'INSERT INTO "{schema}"."{tier}" (content, embedding, metadata) '
                f'VALUES (%s, %s::vector, %s::jsonb)',
                (content, _vec_literal(emb), meta_json),
            )
            conn.commit()
        logger.info(f"AUDIT memory_write agent={agent} tier={tier}")
        return f"Stored memory in {schema}.{tier}"
    except Exception as e:
        logger.error(f"memory_write failed: {e}")
        return f"Error: {e}"


@mcp.tool(description="Semantic search YOUR OWN memory. tier: claudemd|project|auto (default auto). "
                      "Operates only on the calling agent's memory — there is no target-agent parameter.")
def memory_read(query: str, tier: str = "auto", limit: int = 5) -> list:
    try:
        agent = _caller_agent()
        _validate_tier(tier)
        import psycopg
        emb = _embed(query)
        schema = _schema(agent)
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            rows = conn.execute(
                f'SELECT content, metadata, created_at, '
                f'       1 - (embedding <=> %s::vector) AS score '
                f'FROM "{schema}"."{tier}" '
                f'ORDER BY embedding <=> %s::vector LIMIT %s',
                (_vec_literal(emb), _vec_literal(emb), limit),
            ).fetchall()
        logger.info(f"AUDIT memory_read agent={agent} tier={tier} hits={len(rows)}")
        return [
            {"content": r[0], "metadata": r[1], "created_at": str(r[2]), "score": round(float(r[3]), 4)}
            for r in rows
        ]
    except Exception as e:
        logger.error(f"memory_read failed: {e}")
        return [{"error": str(e)}]


@mcp.tool(description="List available memory tiers in YOUR OWN memory. "
                      "Operates only on the calling agent's memory — there is no target-agent parameter.")
def memory_list_tiers() -> list:
    try:
        agent = _caller_agent()
        import psycopg
        schema = _schema(agent)
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            rows = conn.execute(
                "SELECT table_name FROM information_schema.tables WHERE table_schema = %s",
                (schema,),
            ).fetchall()
        logger.info(f"AUDIT memory_list_tiers agent={agent}")
        return [r[0] for r in rows]
    except Exception as e:
        return [{"error": str(e)}]


if __name__ == "__main__":
    mcp.run(transport="sse", port=8000, host="0.0.0.0")
