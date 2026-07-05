# Agent Memory Convention

Per-agent memory isolation for persistent agents. Each agent gets its own
pgvector Postgres schema (true namespace isolation), plus a Redis ephemeral
cache. Any agent runtime (OpenClaw today, Hermes tomorrow) reads/writes memory
through a standard **MCP memory server** — no runtime-specific code.

---

## Memory tiers

| Tier | Storage | Purpose |
|------|---------|---------|
| `claudemd` | pgvector `agent_{name}.claudemd` | CLAUDE.md-style instructions — user-edited, read every turn. Few writes, many reads. |
| `project` | pgvector `agent_{name}.project` | Longer-lived project working knowledge. |
| `auto` | pgvector `agent_{name}.auto` | Agent-written, append-mostly, semantic recall. **Default tier.** |
| `ctx` (ephemeral) | Redis `agent:{id}:ctx` | Live LLM context buffer. Managed by the suspend/resume contract (Item 3), not by the memory adapter. |

For backends without Claw's tier model, only `auto` is used; the other tiers sit
unused. Tier semantics are Claw-shaped, not Claw-mandatory.

---

## Schema naming & structure

- Schema per agent: `agent_{name}` with `-` replaced by `_` (Postgres identifier
  rules). E.g. agent `code-bot` → schema `agent_code_bot`.
- One table per tier, each:
  ```sql
  CREATE TABLE "agent_{name}"."{tier}" (
    id         BIGSERIAL PRIMARY KEY,
    content    TEXT,
    embedding  VECTOR(768),          -- matches the embedding model (bge-base-en-v1.5)
    metadata   JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
  );
  CREATE INDEX ... USING hnsw (embedding vector_cosine_ops);
  ```
- **Embedding dimension is 768** for `BAAI/bge-base-en-v1.5`. It is NOT 1536 — the
  legacy `public.agent_memory` table uses 1536 (OpenAI-style); do not copy that.
  If you change the embedding model, set `pgvector.embeddingDim` to match.

The operator provisions the schema + tier tables on agent creation
(`_provision_agent_memory`) and drops the schema on deletion
(`_teardown_agent_memory`, `DROP SCHEMA ... CASCADE`). Both are graceful no-ops if
`PGVECTOR_DSN` is unset.

---

## Read / write contract (MCP tools)

The `mcp-memory-server` exposes three MCP tools over SSE. An agent gets them
automatically when created with the `memory` skill — the operator injects the
server into the agent's `mcp.servers` config.

| Tool | Signature | Behavior |
|------|-----------|----------|
| `memory_write` | `(content, tier="auto", metadata=None)` | Embeds `content` via LiteLLM, inserts into the **caller's own** `agent_{caller}.{tier}` |
| `memory_read` | `(query, tier="auto", limit=5)` | Embeds `query`, cosine-searches the caller's tier, returns top-`limit` rows with scores |
| `memory_list_tiers` | `()` | Lists the tier tables that exist for the caller |

**There is no `agent` parameter.** The target schema is derived from the caller's
verified identity (see Authorization), so an agent can only ever act on its **own**
memory — cross-agent access is not expressible. Default tier is `auto`;
`claudemd`/`project` require an explicit `tier` argument.

Embeddings use LiteLLM (`/v1/embeddings`, model `BAAI/bge-base-en-v1.5`). The
memory server is **stateless** — all persistence is in pgvector; restarting it
loses nothing.

---

## Usage

```bash
# Create an agent with the memory skill → schema provisioned + MCP wired
helm install my-agent core/helm-charts/agent-instance/ \
  --set owner=user@example.com --set "skills={memory}"

# The agent's MCP config now includes the memory server; it can call
# memory_write / memory_read / memory_list_tiers directly.
```

The `mcp-memory-server` is deployed once (cluster-wide), in the `pgvector`
namespace:
```bash
PW=$(kubectl get secret pgvector-credentials -n pgvector -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
DSN="host=pgvector.pgvector.svc.cluster.local port=5432 dbname=agentdb user=agentuser password=$PW sslmode=disable"
helm install mcp-memory core/helm-charts/mcp-memory-server/ \
  --namespace pgvector \
  --set-string pgvector.dsn="$DSN" \
  --set litellm.apiKey="<litellm-key>"
```

---

## ⚠️ Credential gotcha (pgvector `pg_hba.conf`)

The pgvector chart's `pg_hba.conf` uses **`trust`** for `local` / `127.0.0.1`
(no password check) but **`scram-sha-256`** for remote TCP. Consequences:

1. `psql` run *inside* the pgvector pod accepts any password — it uses the local
   trust socket. This is misleading; it does not validate the TCP credential.
2. The `agentuser` role's real password (for remote TCP — how the operator and
   memory server connect) is the secret key **`POSTGRES_PASSWORD`**, NOT
   `POSTGRES_USER_PASSWORD` and NOT the password embedded in `DATABASE_URL`.

**Always build the DSN from `POSTGRES_PASSWORD`** with `user=agentuser`. Verify
over TCP, not via in-pod `psql`.

---

## Authorization — private-only, inexpressible cross-agent access

Each agent may access **only its own** schema. Cross-agent memory access is not just
denied — it is **not expressible**: the tools have no `agent` parameter, so the
target schema is *derived* from the caller's identity, never supplied by the LLM. An
agent that needs another's knowledge asks it over the secured dispatch channel (a
lead asks a worker; the worker answers from its own memory).

**How identity is established (unforgeable):**
- The operator injects each agent's identity as static transport headers on the
  memory MCP entry in `openclaw.json`. The LLM controls tool *arguments* but **not**
  transport headers, so it cannot impersonate another agent.
  - **Enforced mode** (`MEMORY_AUTH_ENABLED=true`, default when `KEYCLOAK_URL` set):
    headers carry the agent's own Keycloak client creds
    (`X-Agent-Client-Id`/`-Secret`/`-Token-Endpoint`). On each call the server mints
    a token from them, verifies it via Keycloak JWKS (RS256), and takes the caller
    name from the token's `azp` (`agent-{name}`). Tokens are cached in-process until
    near expiry to avoid a mint per call.
  - **Dev mode** (`MEMORY_AUTH_ENABLED=false`): identity is read from the
    `X-Agent-Id` header **without** cryptographic proof. Use only in trusted dev.
- The server derives `schema = agent_{caller}` and logs an `AUDIT` line per call
  (`AUDIT memory_read agent={caller} tier=... hits=...`) — attribution is tied to the
  *verified* identity, not a client-supplied argument.

**Verified end-to-end:**
- Tool signatures expose **no** `agent` param: `memory_read(query, tier, limit)`,
  `memory_write(content, tier, metadata)`, `memory_list_tiers()`.
- A call passing `agent="bob"` is rejected by schema validation
  (`unexpected keyword argument 'agent'`) — the old exploit is inexpressible.
- Same-agent write→recall works through a real OpenClaw agent turn.

> **Migration note.** Agents created *before* this change have a memory MCP entry
> with no identity headers, so their memory calls will fail. **Re-provision
> pre-existing agents** (`helm uninstall` + `helm install`, or delete/recreate the
> Agent CR) so the operator injects the headers. New agents get them automatically.

Reuses the attenuated-JWT machinery proven in the dispatch server
(`mcp-dispatch-server/src/server.py: _mint_and_verify_token`).

---

## Boundaries

- **Not Enterprise RAG.** This adapter owns the per-agent write/read path only. It
  does not duplicate corpus retrieval; that is the Enterprise RAG workstream's job.
- **Shared team namespaces** (`team:{id}:*`) are a v1beta1 concern — out of scope.
- **LiteLLM stays out of the memory path** except for embeddings. Memory
  governance happens at the adapter, not the gateway.

---

## Files

| File | Role |
|------|------|
| `core/helm-charts/agent-operator/templates/configmap-controller.yaml` | Operator: `_provision_agent_memory` / `_teardown_agent_memory`, memory-MCP auto-wire |
| `core/helm-charts/mcp-memory-server/` | The MCP memory adapter (stateless; pgvector-backed) |
| `docs/conventions/agent-memory.md` | This document |
