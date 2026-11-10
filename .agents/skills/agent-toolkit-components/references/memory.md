# Redis Stack and pgvector from agent code

Both services are inside the Istio ambient mesh with STRICT mTLS. A client pod must run in an ambient namespace (`namespace-onboarding.md`), otherwise the connection is reset. They have no external endpoint. From a laptop, use `kubectl port-forward`.

## Redis Stack: short-term memory

Use it for session and chat state, LangGraph checkpoints, semantic caches and RediSearch vector indexes. It is Redis Stack 7.4 with RediSearch loaded: one replica, password required, no TLS (the mesh encrypts traffic).

| | Value |
|---|---|
| Host | `redis-stack-server.redis.svc.cluster.local:6379` |
| Secret | `redis-stack-server-credentials` in ns `redis` |
| Keys | `REDIS_URL`, `REDIS_PASSWORD` |
| URL form | `redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379` |
| Storage | 10Gi PVC `db-redis-stack-server-0` (`redis_stack_persistence_size`, fixed after the first install) |

```bash
REDIS_URL=$(kubectl get secret redis-stack-server-credentials -n redis -o jsonpath='{.data.REDIS_URL}' | base64 -d)   # holds the password; do not echo
```

```python
import os, redis
r = redis.Redis.from_url(os.environ["REDIS_URL"])
r.ping()
```

The same `REDIS_URL` works for LangGraph's Redis checkpointer and for RedisVL or LangChain `RedisVectorStore`.

- Use the URL as stored (`redis://default:<password>@...`). `WRONGPASS invalid username-password pair` usually means an old password after Redis was reinstalled; some clients also fail when the username is empty.
- A namespace other than `redis` (`redis_stack_namespace`) changes the host. Set it before the first install.

## pgvector: long-term memory and RAG store

PostgreSQL 16 with the `vector` extension.

| | Value |
|---|---|
| Host | `pgvector.pgvector.svc.cluster.local:5432` |
| Database / user | `agentdb` / `agentuser` (`pgvector_database`, `pgvector_username`) |
| Secret | `pgvector-credentials` in ns `pgvector` |
| Keys | `DATABASE_URL` (URL), `POSTGRES_DSN` (libpq `key=value`), `host`, `port`, `database`, `username`, `password` |
| Storage | 20Gi PVC `data-pgvector-0` (`pgvector_storage_size`, fixed after the first install) |

```bash
DATABASE_URL=$(kubectl get secret pgvector-credentials -n pgvector -o jsonpath='{.data.DATABASE_URL}' | base64 -d)   # holds the password; do not echo
```

- `psycopg.connect(os.environ["POSTGRES_DSN"])` works as is.
- SQLAlchemy and LangChain `PGVector` need the scheme `postgresql+psycopg://`. Replace the `postgresql://` prefix of `DATABASE_URL`.
- `agentuser` is the database superuser; there is no separate `postgres` role.
- Do not change `pgvector_database` or `pgvector_username` after the first install. The database was initialised with the old names, and validation then fails with `FATAL: role "<new>" does not exist`.

### Tables created at install

| Table | Purpose | Notable columns |
|---|---|---|
| `agent_memory` | Long-term memory | `agent_id`, `user_id`, `session_id`, `content`, `embedding VECTOR(1536)`, `metadata JSONB` |
| `agent_events` | Audit and event log | `event_type`, `payload JSONB`, `duration_ms` |
| `agent_cache` | Semantic cache | `cache_key` (unique), `embedding VECTOR(1536)`, `value JSONB`, `hit_count`, `expires_at` |

The embedding columns are fixed at **1536 dimensions** with HNSW cosine indexes. An embedding model with another size fails with `expected 1536 dimensions, not N`. Create your own table with the right dimension (for example `VECTOR(768)` for a 768-dimension model), or alter the column before storing data.

## Embeddings

Embeddings through LiteLLM need an embedding model deployed in the inference layer. None is deployed by default. Deploy one with `./model-manager deploy <name>` from the Toolkit Manager root **(changes the cluster)**, then use the name that `GET /v1/models` returns. If `/v1/embeddings` then fails with HTTP 400, see LLM-3 in the agent-toolkit-troubleshoot skill (`references/inference.md`): some versions register embedding models in LiteLLM in a way that breaks this call.

## Wiring credentials into an agent pod

The Secrets live in the service namespaces. Copy them into the agent namespace **(changes the cluster)**, or sync them with your secret manager, then reference them:

```yaml
env:
  - name: REDIS_URL
    valueFrom: {secretKeyRef: {name: redis-stack-server-credentials, key: REDIS_URL}}
  - name: DATABASE_URL
    valueFrom: {secretKeyRef: {name: pgvector-credentials, key: DATABASE_URL}}
```

Tearing down and reinstalling Redis or pgvector deletes the data and generates **new passwords**. Copy the Secrets again afterwards.

## Inspect

```bash
kubectl get pods,pvc,svc -n redis
kubectl logs -n redis redis-stack-server-0
kubectl get pods,pvc -n pgvector
kubectl logs -n pgvector pgvector-0
```
