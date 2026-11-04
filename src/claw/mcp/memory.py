# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Memory MCP server: per-agent long-term memory on pgvector.

Every call must carry a Keycloak token minted by the agent's identity proxy. The caller's
schema comes from the token's `memory_schema` claim, so an agent can only reach its own
memory; there is no target-agent argument. Tools: memory_write, memory_read,
memory_list_tiers.
"""
import json
import logging
import os
import re

import psycopg
import requests
from fastmcp import FastMCP
from psycopg import sql

import auth

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("mcp-memory")

PGVECTOR_DSN = os.environ.get("PGVECTOR_DSN", "")
EMBEDDING_URL = os.environ.get("EMBEDDING_URL", "").rstrip("/")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "bge-base-en")
# bge-base-en takes 512 tokens; ~3.5 characters per token keeps the input under it.
EMBEDDING_MAX_CHARS = int(os.environ.get("EMBEDDING_MAX_CHARS", "1600"))
TIERS = ("claudemd", "project", "auto")
SCOPE_READ, SCOPE_WRITE = "tools:memory.read", "tools:memory.write"
_SCHEMA_RE = re.compile(r"^agent_[a-z0-9_]+$")


def _caller(required_scope):
    """(schema, client id) of the calling agent; the schema comes from its token."""
    claims = auth.caller(required_scope)
    schema = claims.get("memory_schema") or ""
    if not _SCHEMA_RE.match(schema):
        raise auth.AuthError("token has no valid memory_schema claim")
    return schema, claims["azp"]


def _embed(text):
    resp = requests.post(f"{EMBEDDING_URL}/embeddings", timeout=30,
                         json={"model": EMBEDDING_MODEL, "input": text[:EMBEDDING_MAX_CHARS]})
    resp.raise_for_status()
    return "[" + ",".join(str(float(x)) for x in resp.json()["data"][0]["embedding"]) + "]"


def _tier(tier):
    if tier not in TIERS:
        raise ValueError(f"invalid tier '{tier}', must be one of {TIERS}")
    return tier


def _table(schema, tier):
    return sql.Identifier(schema, _tier(tier))


mcp = FastMCP("memory")


@mcp.tool(description="Store a memory in your own memory. tier: claudemd|project|auto (default auto).")
def memory_write(content: str, tier: str = "auto", metadata: dict = None) -> str:
    try:
        schema, azp = _caller(SCOPE_WRITE)
        vec = _embed(content)
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            conn.execute(sql.SQL("INSERT INTO {} (content, embedding, metadata) VALUES (%s, %s::vector, %s::jsonb)")
                         .format(_table(schema, tier)), (content, vec, json.dumps(metadata or {})))
        logger.info(f"AUDIT memory_write azp={azp} schema={schema} tier={tier}")
        return f"Stored memory in tier {tier}"
    except Exception as e:
        logger.warning(f"memory_write failed: {e}")
        return f"Error: {e}"


@mcp.tool(description="Semantic search of your own memory. tier: claudemd|project|auto (default auto).")
def memory_read(query: str, tier: str = "auto", limit: int = 5) -> list:
    try:
        schema, azp = _caller(SCOPE_READ)
        vec = _embed(query)
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            rows = conn.execute(
                sql.SQL("SELECT content, metadata, created_at, 1 - (embedding <=> %s::vector) "
                        "FROM {} ORDER BY embedding <=> %s::vector LIMIT %s").format(_table(schema, tier)),
                (vec, vec, max(1, min(int(limit), 50)))).fetchall()
        logger.info(f"AUDIT memory_read azp={azp} schema={schema} tier={tier} hits={len(rows)}")
        return [{"content": r[0], "metadata": r[1], "created_at": str(r[2]), "score": round(float(r[3]), 4)}
                for r in rows]
    except Exception as e:
        logger.warning(f"memory_read failed: {e}")
        return [{"error": str(e)}]


@mcp.tool(description="List the memory tiers in your own memory.")
def memory_list_tiers() -> list:
    try:
        schema, _ = _caller(SCOPE_READ)
        with psycopg.connect(PGVECTOR_DSN, connect_timeout=5) as conn:
            rows = conn.execute("SELECT table_name FROM information_schema.tables WHERE table_schema = %s",
                                (schema,)).fetchall()
        return [r[0] for r in rows]
    except Exception as e:
        return [{"error": str(e)}]


if __name__ == "__main__":
    mcp.run(transport="sse", host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))  # nosec B104
