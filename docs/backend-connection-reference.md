# Backend Connection Reference — Intel® AI for Enterprise Agent Toolkit

All shared backends are deployed into their own namespaces and are reachable from any workload namespace in the cluster.

## Redis (Session Memory & Caching)

| Instance | Kubernetes Service | URL | Scope |
|---|---|---|---|
| **Redis Stack** (`deploy_redis=on`) | `redis-stack-server.redis.svc.cluster.local:6379` (ClusterIP) | `redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379` | All namespaces (in-cluster only) |

Redis requires a password. The credentials and the full URL are stored in the `redis-stack-server-credentials` Secret:

```bash
# Full connection URL (preferred — do not hardcode the password)
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_URL}' | base64 -d

# Password only
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d

# Quick connectivity test
kubectl exec -n redis redis-stack-server-0 -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
# PONG
```

> The `default:` username in the URL is required — Redis 6+ rejects the `redis://:<password>@...` form with `WRONGPASS`.
> The Service is `ClusterIP` and a NetworkPolicy is applied; Redis is not reachable from outside the cluster. Use `kubectl port-forward` for local access instead of changing the Service type.

## Agent Sandbox (Sandboxed Execution)

Enabled with `deploy_agent_sandbox=on`. See [agent-sandbox.md](agent-sandbox.md) for full details.

| Resource | Value |
|---|---|
| **Namespace** | `agent-sandbox` |
| **Router service** | `sandbox-router-svc.agent-sandbox.svc.cluster.local:8080` |
| **SDK** | `pip install k8s-agent-sandbox` |
| **Default template** | `python-sandbox-template` (namespace: `agent-sandbox`) |

```bash
# Quick health check (requires port-forward or in-cluster)
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080 &
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

## PostgreSQL + pgvector (Vector Store & Long-Term Memory)

Enabled with `deploy_pgvector=on`. See [README.md](README.md#step-2b--postgresql--pgvector-vector-store--long-term-memory) for deployment details.

| Resource | Value |
|---|---|
| **Namespace** | `pgvector` |
| **Host** | `pgvector.pgvector.svc.cluster.local` |
| **Port** | `5432` |
| **Database** | `agentdb` |
| **User** | `agentuser` |
| **Connection string** | `postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb` |
| **Credentials secret** | `kubectl get secret pgvector-credentials -n pgvector -o jsonpath='{.data.DATABASE_URL}' \| base64 -d` |

## KubeRay (Distributed Computing)

Enabled with `deploy_kuberay=on`. Tuned via `core/inventory/kuberay-config.yaml`. See [kuberay.md](kuberay.md) for the full guide.

| Resource | Value |
|---|---|
| **Namespace** | `ray-system` *(default; set via `kuberay-config.yaml`)* |
| **Ray Client API** | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` |
| **Ray Dashboard** | `http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265` |
| **Dashboard (local)** | `kubectl port-forward svc/ray-cluster-head-svc 8265:8265 -n ray-system` |

```bash
# Verify all Ray pods are Running
kubectl get pods -n ray-system

# Quick Python connectivity test (from inside the cluster or via port-forward)
python3 -c "
import ray
ray.init('ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001')
print(ray.cluster_resources())
"
```

## Flowise (Agent Builder)

Enabled with `deploy_flowise=on`. See [flowise.md](flowise.md) for the full guide.

| Resource | Value |
|---|---|
| **Namespace** | `flowise` |
| **Flowise service** | `flowise.flowise.svc.cluster.local:3000` |
| **Flowise admin UI** | `https://flowise-<cluster_url>` |

```bash
# Check pods
kubectl get pods -n flowise

# Retrieve the Flowise API key
grep '^flowise_api_key:' core/inventory/metadata/vault.yml | awk -F'"' '{print $2}'
```