# vLLM semantic router

[← Docs index](../README.md)

> **Not available in this release.** The steps below are the procedure for when it is. Confirm `vllm_sr_enabled` on your install before you depend on `vllm-sr/auto`. The short enable and call sequence is also on [Routing](routing.md#semantic-routing).

vLLM Semantic Router classifies each prompt and sends it to one deployed model. A request with `"model": "vllm-sr/auto"` is routed. A request that names a real model goes to that model. Project background: [vllm-semantic-router.com](https://vllm-semantic-router.com/).

```
Client
    |
    |  HTTPS
    v
LiteLLM
    |  authenticates the request
    |  model="vllm-sr/auto" triggers routing
    |  starts a Langfuse trace
    v
vLLM Semantic Router
    |  classifies the prompt
    |  selects a backend
    v
Model backend (local vLLM, or a cloud model registered in LiteLLM)
    v
Response returns through the same path
```

vLLM-SR emits OpenTelemetry traces that show up in Langfuse next to the LiteLLM traces. Trace export is not available in this release. See [Langfuse](#langfuse).

## Install

The cluster, the gateway, and at least one model are already up. In `env/local/config.inference.yaml`:

```yaml
vllm_sr_enabled: true
```

```bash
./toolkit_manager.sh install agent-toolkit
```

The install discovers model services already in the cluster, deploys the vLLM-SR Helm chart, waits until the containers are healthy, and registers `vllm-sr/auto` in LiteLLM. To install only this piece: `./toolkit_manager.sh install vllm_sr --only`.

### Call it

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -d '{
    "model": "vllm-sr/auto",
    "messages": [{"role": "user", "content": "write a hello world in python"}]
  }'
```

A named model bypasses routing:

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -d '{
    "model": "qwen2-5-coder-14b",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

### Dashboard

The dashboard is on its own host, because it serves `/login`, `/api`, and `/assets` at the root and cannot sit under a sub-path:

```text
https://vllm-sr.<base_domain_name>/
```

The router API (`/v1/route`) is not published at the gateway in this release. Send requests to `vllm-sr/auto` through LiteLLM.

- **DNS.** `vllm-sr.<base_domain_name>` resolves to the gateway, as a DNS record or a line in `/etc/hosts` on the node and on every client. See [Prerequisites](../getting-started/prerequisites.md).
- **TLS.** The certificate covers `vllm-sr.<base_domain_name>`, as a SAN (`DNS:vllm-sr.<base_domain_name>`) or a wildcard (`*.<base_domain_name>`). A certificate that lacks it has to be reissued.
- **Proxy.** Add `vllm-sr.<base_domain_name>` to the proxy bypass list, the same way as `litellm.<base_domain_name>`.

Default credentials are generated at deploy time into Secret `vllm-sr-dashboard` in namespace `vllm-semantic-router-system`, keys `admin-email` and `admin-password`.

## Request flow

1. The client sends `POST /v1/chat/completions` with `model: "vllm-sr/auto"`.
2. LiteLLM authenticates the request, starts a Langfuse trace, and forwards to vLLM-SR.
3. vLLM-SR classifies the prompt.
4. The decision engine evaluates rules from the smallest priority number to the largest:
   - `coding-route` (priority 10) matches coding prompts
   - `reasoning-route` (priority 50) matches analytical prompts
   - `default-route` (priority 100) is the catch-all
5. vLLM-SR sends the request to the selected backend.
6. The response returns to the client.

LiteLLM treats `vllm-sr/auto` and the real model names as separate entries, so a routed call does not loop. Only `vllm-sr/auto` goes to vLLM-SR.

## Routing configuration

The reference config is `core/helm-charts/vllm-sr/router-config.yaml`. The Helm template `core/helm-charts/vllm-sr/templates/configmap.yaml` renders it into a ConfigMap. Day to day, edit `vllm_sr_config_override` in `env/local/config.inference.yaml` and reinstall.

**Signals** classify prompts:

```yaml
routing:
  signals:
    embeddings:
      - name: coding_tasks
        threshold: 0.72
        candidates:
          - "write code"
          - "implement function"
          - "debug this"
```

A new category is another embedding entry: a name, a similarity threshold, and candidate phrases.

**Decisions** are evaluated from the smallest priority number. The first match wins.

```yaml
routing:
  decisions:
    - name: coding-route
      description: "Route coding tasks to coder model"
      priority: 10
      rules:
        operator: AND
        conditions:
          - type: embedding
            name: coding_tasks
      modelRefs:
        - model: qwen2-5-coder-14b
          use_reasoning: false
```

Editing decisions by hand is not available in this release. The shape above is what the chart renders.

**Model backends** are discovered at deploy time. See [Add a model](#add-a-model). Each one has this shape:

```yaml
providers:
  models:
    - name: qwen2-5-coder-14b
      provider_model_id: "qwen2-5-coder-14b"
      backend_refs:
        - name: "primary"
          endpoint: "qwen2-5-coder-14b-kserve-workload-svc.llm-inference.svc.cluster.local:8000"
          protocol: "http"
          weight: 100
```

- `name` is the identifier used in `routing.decisions`.
- `provider_model_id` is the model id the backend serves.
- `endpoint` is `host:port` inside the cluster.
- `protocol` is `http` for vLLM backends.

### Settings

All of these live in `env/local/config.inference.yaml`.

| Setting | Meaning |
|---|---|
| `vllm_sr_image_tag` | vLLM-SR container version |
| `vllm_sr_dashboard_admin_email` | Dashboard login email. Default `admin@<base_domain_name>` |
| `vllm_sr_dashboard_secret` | Secret that holds the dashboard password. Default `vllm-sr-dashboard`, generated at deploy time |
| `vllm_sr_cache_backend` | Semantic cache: `memory` or `redis` |
| `routing.enableSemanticCache` | Response caching. Not available in this release |
| `routing.cacheThreshold` | Similarity above which a cached response is reused. Default `0.92`. Not available in this release |
| `vllm_sr_default_model` | Backend name used when the router has no better choice. Default is `qwen2-5-coder-14b`, or the first routed model when that one is not routed |
| `routing.enableJailbreakDetection` | Not wired. Not available in this release |
| `routing.enablePiiDetection` | Not wired. Not available in this release |
| `observability.enabled` | Export traces to Langfuse. Not available in this release |

After you edit those settings, or `vllm_sr_config_override`:

```bash
./toolkit_manager.sh install agent-toolkit
# or only this piece:
./toolkit_manager.sh install vllm_sr --only
```

The pod restarts when the ConfigMap changes.

## Add a model

With `vllm_sr_enabled: true`, a model deployed through the toolkit is added to routing in the same run. There is no separate registration step. vLLM-SR discovers the model services, adds each one as a backend, and rebuilds its routing config. The model then shows up in the dashboard.

1. Put the catalog name in `llm_services_autodeploy_models` in `env/local/config.agent-toolkit.yaml`, with `vllm_sr_enabled: true`.
2. Run `./toolkit_manager.sh install agent-toolkit`.

Confirm it on `https://vllm-sr.<base_domain_name>/`.

Once a model is a backend:

- The reasoning and default routes consider every model, so a new model is eligible for that traffic immediately.
- The coding route considers models whose name contains `coder`.

A new prompt category (math, legal) needs a signal and a matching decision. See [Routing configuration](#routing-configuration).

Check which model answered:

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "vllm-sr/auto", "messages": [{"role": "user", "content": "write a python function to sort a list"}]}' \
  | jq -r .model
```

Clients keep calling `vllm-sr/auto`. The router dispatches internally.

## LiteLLM

`vllm-sr/auto` is registered in LiteLLM at the end of the deployment playbook (`vllm_sr_litellm_model_name`).

- `"model": "vllm-sr/auto"` goes through semantic routing.
- `"model": "<catalog-name>"` goes to that model.

Both paths go through LiteLLM for authentication and spend tracking.

## Langfuse

vLLM-SR emits an OpenTelemetry trace for every routed request. In Langfuse those spans sit next to the LiteLLM trace. Trace export is not available in this release.

For a request that did go through vLLM-SR, Langfuse shows:

From LiteLLM (`service.name: litellm`): the prompt, the response, token counts, cost, and total latency.

From vLLM-SR (`service.name: vllm-semantic-router`):

- `semantic_router.signal.evaluation`: which signals matched, and the confidence score
- `semantic_router.decision.evaluation`: which route was selected, and which model
- `semantic_router.upstream.request`: backend latency and HTTP status

## Troubleshooting

**Pod is not Ready.** See which container failed:

```bash
kubectl get pods -n vllm-semantic-router-system -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}: {.ready}{"\n"}{end}'
```

The vllm-sr container downloads the encoder on first start (about 1–2 minutes). The envoy container needs a higher file-descriptor limit when the log says `Too many open files`. Raise `fs.inotify.max_user_instances` before install. See [Prerequisites](../getting-started/prerequisites.md#node-kernel-settings).

**Traces are missing in Langfuse.** Trace export is not available in this release. When it is, check the vLLM-SR container:

```bash
kubectl logs -n vllm-sr <pod-name> -c vllm-sr | grep "traces export"
```

**LiteLLM returns `Connection error` for `vllm-sr/auto`.** Check that vLLM-SR is reachable from the `litellm` namespace:

```bash
kubectl exec -n litellm deploy/litellm -c litellm -- \
  python3 -c "import socket; s=socket.socket(); s.connect(('semantic-router.envoy-gateway-system.svc.cluster.local', 80)); print('OK')"
```

**Dashboard shows `Failed to read config`.**

```bash
kubectl logs -n vllm-semantic-router-system deploy/semantic-router-dashboard
```

## Next steps

- [Routing](routing.md): `vllm-sr/auto` next to the hybrid router
- [Hybrid router](hybrid-router.md): complexity routing, on by default in this release
- [Choose a model](../getting-started/quickstart.md#3-choose-a-model)
