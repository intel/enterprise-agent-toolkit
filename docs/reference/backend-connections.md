# Backend connection reference

[← Docs index](../README.md)

Your **application** calls the public gateway at `https://<base_domain_name>`. **Agents running inside the cluster** also need Redis, pgvector, and the sandbox. Those are ClusterIP services: they are not published on the public URL. Read passwords from Kubernetes secrets; do not hardcode them.

All of these come up with `install agent-toolkit` unless a section says otherwise.

## LiteLLM (API gateway)

Present when `auth_provider: litellm`. This is what browsers and `curl` hit from outside the cluster.

| | |
|---|---|
| **Namespace** | `litellm` |
| **In-cluster** | `http://litellm.litellm.svc.cluster.local:4000` |
| **External** | `https://<base_domain_name>` |
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
| **External** | `https://<base_domain_name>` |

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

Do not change the Service to NodePort or LoadBalancer. From outside the cluster, use `kubectl port-forward`.

A NetworkPolicy is on by default. Its `allowedNamespaces` list is empty, which lets every pod in the cluster connect. `config.agent-toolkit.yaml` does not expose that list yet, and re-running `install` skips Redis once the release exists, so restrict it with a Helm upgrade from the Stack Manager directory:

```bash
helm upgrade redis ext/<toolkit-repo>/charts/redis-stack -n redis --reuse-values \
  --set "redis-stack-server.redis_stack_server.networkPolicy.allowedNamespaces={litellm,agent-sandbox-system}"
```

That needs a CNI that enforces NetworkPolicy (Calico does).

To rotate the password, use the same Helm upgrade. Changing `redis_stack_password` and re-running `install` does nothing on a running cluster, because the Redis install is skipped:

```bash
helm upgrade redis ext/<toolkit-repo>/charts/redis-stack -n redis --reuse-values \
  --set "redis-stack-server.redis_stack_server.auth.password=<new-password>"
kubectl rollout restart statefulset/redis-stack-server -n redis
```

The secret `redis-stack-server-credentials` is rewritten with the new password. Restart the workloads that use it so they reload the secret.

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
| **External** | `https://trace-<base_domain_name>` |

## Related pages

- [Single-node quickstart](../getting-started/quickstart.md): first `curl` to the gateway
- [Agent sandbox](agent-sandbox.md): templates and SDK (not only the URL)
- [KubeRay](kuberay.md): Ray client and dashboard
- [Configuration](../configuration/configuration.md): YAML that turns these services on
- [Guardrails](../configuration/guardrails.md): screening on the same LiteLLM gateway
- [Glossary](glossary.md)
