# Backend Connection Reference — Intel® AI for Enterprise Agent Toolkit

All shared backends are deployed into their own namespaces and are reachable from any workload namespace in the cluster labelled `istio.io/dataplane-mode=ambient` (the toolkit namespaces run in the Istio ambient mesh with strict mTLS).

## Redis (Session Memory & Caching)

| Instance | Kubernetes Service | URL | Scope |
|---|---|---|---|
| **Redis Stack** (`redis_stack_enabled: true`) | `redis-stack-server.redis.svc.cluster.local:6379` (ClusterIP) | `redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379` | All namespaces (in-cluster only) |

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

Enabled with `agent_sandbox_enabled: true` (default) in `env/<name>/config.agent-toolkit.yaml`. See [agent-sandbox.md](agent-sandbox.md) for full details.

| Resource | Value |
|---|---|
| **Namespace** | `agent-sandbox-system` |
| **Router service** | `sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080` |
| **SDK** | `pip install k8s-agent-sandbox` |
| **Default template** | `python-sandbox-template` (namespace: `agent-sandbox-system`) |

```bash
# Quick health check (requires port-forward or in-cluster)
kubectl port-forward -n agent-sandbox-system svc/sandbox-router-svc 8080:8080 &
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

## OpenShell (Policy-Enforced Sandboxes)

Enabled with `openshell_enabled: true` (requires `agent_sandbox_enabled: true`). See [openshell.md](openshell.md) for full details.

| Resource | Value |
|---|---|
| **Gateway namespace** | `openshell-system` |
| **Gateway service** | `openshell.openshell-system.svc.cluster.local:8080` (gRPC, mTLS) |
| **Sandbox namespace** | `openshell-sandboxes` |
| **Client mTLS bundle** | Secret `openshell-client-tls` in `openshell-system` |
| **CLI** | [OpenShell v0.0.116 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.0.116) |
| **GenAI provider** | `genai-gateway` (attach with `openshell sandbox create --provider genai-gateway`) |

```bash
# Admin access (ClusterIP only)
kubectl port-forward -n openshell-system svc/openshell 8080:8080 &
```

## PostgreSQL + pgvector (Vector Store & Long-Term Memory)

Enabled with `pgvector_enabled: true` (default). See [README.md](README.md#step-2b--postgresql--pgvector-vector-store--long-term-memory) for deployment details.

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

Enabled with `kuberay_enabled: true`. Tuned via the `kuberay_*` settings in `env/<name>/config.agent-toolkit.yaml` (e.g. `kuberay_worker_replicas`). See [kuberay.md](kuberay.md) for the full guide.

| Resource | Value |
|---|---|
| **Namespace** | `ray-system` *(default; set via `kuberay_namespace`)* |
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

Enabled with `deploy_flowise=on`.

> **Note:** not available in this release.

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