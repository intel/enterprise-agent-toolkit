# Backend connection reference

[← Docs index](../README.md)

Your **application** calls the public gateway at `https://litellm.<base_domain_name>`. **Agents running inside the cluster** also need Redis, pgvector, and the sandbox. Those are ClusterIP services: they are not published on the public URL. Read passwords from Kubernetes secrets; do not hardcode them.

All of these come up with `install agent-toolkit` unless a section says otherwise.

## LiteLLM (API gateway)

Present when `auth_provider: litellm`. This is what browsers and `curl` hit from outside the cluster.

| | |
|---|---|
| **Namespace** | `litellm` |
| **In-cluster** | `http://litellm.litellm.svc.cluster.local:4000` |
| **External** | `https://litellm.<base_domain_name>` |
| **Master key** | Secret `litellm-master-key`, key `master_key` |

```bash
kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d
```

## Model inference

Models are served behind the AI gateway as well as LiteLLM.

| Access | URL |
|---|---|
| **In-cluster** | `http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/<model>/v1` |
| **External** | `https://litellm.<base_domain_name>/v1` |

## Redis (short-term memory)
<a id="redis"></a>

Redis Stack with RediSearch. A password is required (the chart will not render without one). The Service is ClusterIP only: do not change it to NodePort.

| | |
|---|---|
| **Namespace** | `redis` |
| **Service** | `redis-stack-server.redis.svc.cluster.local:6379` |
| **URL shape** | `redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379` |
| **Secret** | `redis-stack-server-credentials` |

```bash
# Full URL (preferred)
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_URL}' | base64 -d

kubectl exec -n redis redis-stack-server-0 -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
```

The username `default` is required. `redis://:<password>@...` fails with `WRONGPASS` on Redis 6+.

Redis with no password would let any client that can reach the port read session data and run Lua and JavaScript through RedisGears. The chart refuses to render without a password.

Leave the Service as ClusterIP. NodePort or LoadBalancer would publish Redis on every node IP in the range 30000–32767. From outside the cluster, use `kubectl port-forward`.

Redis runs in the ambient mesh. Namespaces in the mesh can reach it. Plaintext clients from outside the mesh are refused.

Password rotation is not automated in this release. Re-running `install` skips Redis once the release exists, so a new value in YAML does not change the live password.

## Agent sandbox

Isolated pods for agent-generated code. Full guide: [Agent sandbox](agent-sandbox.md).

| | |
|---|---|
| **Namespace** | `agent-sandbox-system` |
| **Router** | `sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080` |
| **Version** | `v0.5.0` |
| **CRDs** | `sandboxes`, `sandboxtemplates`, `sandboxwarmpools` (`v1beta1`) |
| **SDK** | `pip install k8s-agent-sandbox` |
| **Default template** | `python-sandbox-template` |

```bash
kubectl port-forward -n agent-sandbox-system svc/sandbox-router-svc 8080:8080
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

## PostgreSQL + pgvector (long-term memory)

| | |
|---|---|
| **Namespace** | `pgvector` |
| **Host** | `pgvector.pgvector.svc.cluster.local:5432` |
| **Database / user** | `agentdb` / `agentuser` |
| **Secret** | `pgvector-credentials` (key `DATABASE_URL`) |

```bash
kubectl get secret pgvector-credentials -n pgvector \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d
# postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb

kubectl exec -n pgvector pgvector-0 -- \
  psql -U agentuser -d agentdb \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"
# extname | extversion
# vector  | 0.8.0
```

## KubeRay (optional)

Only if `kuberay_enabled: true`. Guide: [KubeRay](kuberay.md).

| | |
|---|---|
| **Namespace** | `ray-system` |
| **Ray Client** | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` |
| **Dashboard** | `http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265` |

```bash
kubectl get pods -n ray-system
kubectl port-forward svc/ray-cluster-head-svc 8265:8265 -n ray-system
```

## Langfuse (traces)

Present in `auth_provider: litellm` mode.

| | |
|---|---|
| **Namespace** | `langfuse` |
| **In-cluster** | `http://langfuse-web.langfuse.svc.cluster.local:3000` |
| **External** | `https://langfuse.<base_domain_name>` |

## Related pages

- [Single-node quickstart](../getting-started/quickstart.md): first `curl` to the gateway
- [Agent sandbox](agent-sandbox.md): templates and SDK (not only the URL)
- [KubeRay](kuberay.md): Ray client and dashboard
- [Configuration](../configuration/configuration.md): YAML that turns these services on
- [Guardrails](../configuration/guardrails.md): screening on the same LiteLLM gateway
- [Glossary](glossary.md)
