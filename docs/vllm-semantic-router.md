# vLLM Semantic Router

vLLM Semantic Router is a signal-driven decision routing framework for
Mixture-of-Models deployments. It routes every request to the best model
across local, private, and frontier backends -- guided by cost, latency,
privacy, and safety constraints.

For more information, see [vllm-semantic-router.com](https://vllm-semantic-router.com/).

---

## Architecture

```
Client
    |
    |  HTTPS (external)
    v
LiteLLM GenAI Gateway
    |  - authenticates the request
    |  - model="vllm-sr/auto" triggers routing
    |  - starts Langfuse trace
    v
vLLM Semantic Router
    |  - extracts semantic signals from the prompt
    |  - evaluates routing decisions
    |  - selects the best model
    |  - routes to the appropriate backend
    v
Model Backend (local vLLM, Bedrock, OpenAI, etc.)
    |  - runs inference
    |  - returns response
    v
Response flows back through the chain to the client
```

Observability is handled via OpenTelemetry. vLLM-SR emits traces that appear
in Langfuse alongside the LiteLLM traces, giving a complete view of routing
decisions and inference performance.

> **Note:** not available in this release.

---

## Getting Started

### Prerequisites

- The base stack must be deployed (Kubernetes, ingress, LiteLLM, at least one model)
- `vllm_sr_enabled: true` in `env/<name>/config.inference.yaml`

### Deploy

Run the standard deployment script:

```bash
./es_auto_installer.sh install agent-toolkit
```

The script will:
1. Discover deployed model services in the cluster
2. Deploy the vLLM-SR Helm chart
3. Wait for all containers to become healthy
4. Register `vllm-sr/auto` as a model in LiteLLM

### Verify

Send a request through the routing layer:

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -d '{
    "model": "vllm-sr/auto",
    "messages": [{"role": "user", "content": "write a hello world in python"}]
  }'
```

You can also call a model directly (bypasses routing):

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -d '{
    "model": "qwen2-5-coder-14b",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

### Access the Dashboard

The dashboard is exposed via the gateway on its own host, `vllm-sr.<base_domain_name>`:

```
https://vllm-sr.<base_domain_name>/
```

For example: `https://vllm-sr.example.com/`

The dashboard serves root paths (`/login`, `/api`, `/assets`, ...) and cannot
run under a sub-path, so it gets its own host instead of sharing `litellm.<base_domain_name>`
with the GenAI Gateway (LiteLLM) UI. The router API (`/v1/route`) is not published at the gateway in this release; send requests to the `vllm-sr/auto` model through LiteLLM instead.

Prerequisites for the dashboard host:

- **DNS:** `vllm-sr.<base_domain_name>` must resolve to the gateway (DNS record, or
  `/etc/hosts` on the node and on every client machine).
- **TLS certificate:** the certificate must cover `vllm-sr.<base_domain_name>`, either
  as a SAN entry (`DNS:vllm-sr.<base_domain_name>`) or via a parent-domain wildcard
  (e.g. `*.<base_domain_name>`). See [Prerequisites](prerequisites.md). Existing
  certificates without it must be regenerated.
- **Corporate proxy:** add `vllm-sr.<base_domain_name>` to the browser/OS proxy bypass
  list, as for `litellm.<base_domain_name>`.

Default credentials are generated at deploy time into the `vllm-sr-dashboard` Secret
(namespace `vllm-semantic-router-system`, keys `admin-email` / `admin-password`).

---

## Request Flow

1. Client sends `POST /v1/chat/completions` with `model: "vllm-sr/auto"`
2. LiteLLM authenticates the request, starts a Langfuse trace, and forwards
   to vLLM-SR
3. vLLM-SR runs semantic signal classification on the prompt
4. The decision engine evaluates routing rules top-down by priority:
   - `coding-route` (priority 10): matches coding-related prompts
   - `reasoning-route` (priority 50): matches analytical prompts
   - `default-route` (priority 100): catch-all
5. vLLM-SR routes the request to the selected backend
6. The response flows back to the client

There is no infinite loop because LiteLLM treats `vllm-sr/auto` and the real
model names as separate routing entries. Only `vllm-sr/auto` goes to vLLM-SR;
real model names go directly to their respective backends.

---

## Configuration

### Routing Configuration

The routing config is defined in `core/helm-charts/vllm-sr/router-config.yaml`
as a reference, and rendered into a ConfigMap via the Helm template at
`core/helm-charts/vllm-sr/templates/configmap.yaml`.

Key sections:

**Signals** define how prompts are classified:

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

To add a new signal category, add another embedding entry with a name,
threshold (similarity score cutoff), and a list of candidate phrases that
represent that category.

**Decisions** define routing rules evaluated top-down by priority:

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

Lower priority number means higher precedence. The first matching decision wins.

> **Note:** not available in this release.

**Model backends** are the models the router can route to. In normal use they
are discovered automatically at deploy time (see
[Onboarding a New Model](#onboarding-a-new-model)), so you do not edit them by
hand.

Each backend has this shape:

```yaml
providers:
  models:
    - name: qwen2-5-coder-14b                                   # short name used in decisions
      provider_model_id: "qwen2-5-coder-14b"                    # the model the backend serves
      backend_refs:
        - name: "primary"
          endpoint: "qwen2-5-coder-14b-kserve-workload-svc.llm-inference.svc.cluster.local:8000"  # its endpoint
          protocol: "http"
          weight: 100
```

- `name` — the short identifier referenced in `routing.decisions`.
- `provider_model_id` — the model id the backend actually serves.
- `endpoint` — the in-cluster endpoint, `host:port`.
- `protocol` — the API style; `http` for vLLM backends.

### Helm Values

All configuration is in `env/<name>/config.inference.yaml`. Key settings:

| Value | Description |
|-------|-------------|
| `vllm_sr_image_tag` | vLLM-SR container version |
| `vllm_sr_dashboard_admin_email` | Dashboard login email (default `admin@<base_domain_name>`) |
| `vllm_sr_dashboard_secret` | Secret holding the dashboard login password (default `vllm-sr-dashboard`, generated at deploy time) |
| `vllm_sr_cache_backend` | Semantic cache: `memory` or `redis` |
| `routing.enableSemanticCache` | Enable/disable response caching — not available in this release |
| `routing.cacheThreshold` | Similarity above which a cached response is reused (default `0.92`) — not available in this release |
| `vllm_sr_default_model` | Backend **name** served when the router has no better choice. Default: the toolkit's default model (`qwen2-5-coder-14b`); the first routed model when that one is not routed |
| `routing.enableJailbreakDetection` | **Not yet wired** — not available in this release |
| `routing.enablePiiDetection` | **Not yet wired** — not available in this release |
| `observability.enabled` | Enable trace export to Langfuse — not available in this release |

### Updating the Routing Config

After editing the settings (or `vllm_sr_config_override`, the full routing config) in `env/<name>/config.inference.yaml`, redeploy with:

```bash
./es_auto_installer.sh install agent-toolkit
```

Or update only vLLM-SR:

```bash
./es_auto_installer.sh install vllm_sr --only
```

The pod restarts automatically when the ConfigMap changes.

---

## Onboarding a New Model

When you deploy a model through the toolkit with vLLM-SR enabled
(`vllm_sr_enabled: true`), the model is onboarded into routing automatically. There
is no separate registration step.

During deployment, vLLM-SR discovers the model services running in the cluster,
adds each one as a routing backend, and rebuilds its routing config. The model
then shows up in the dashboard and becomes a candidate for routing.

To add a model:

1. Deploy the model through the toolkit (`llm_services_autodeploy_models` in
   `env/<name>/config.agent-toolkit.yaml`, then `./es_auto_installer.sh install agent-toolkit`)
   with `vllm_sr_enabled: true`.
2. That's it — the model is discovered and added to routing as part of the same
   deployment.

You can confirm the model is available in the dashboard:

```
https://vllm-sr.<base_domain_name>/
```

### How routing picks up the new model

Once a model is a backend, it participates in routing as follows:

- The **reasoning** and **default** routes consider every model, so a new model
  is immediately eligible for general and reasoning traffic.
- The **coding** route considers models whose name identifies them as coder
  models. A coding model joins this route when `coder` appears in its name.

To route a new category of prompts (for example, math or legal), add a signal
and a matching decision as described in
[Routing Configuration](#routing-configuration).

### Verify routing

Send a prompt and check which model answered (the `model` field of the response):

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "vllm-sr/auto", "messages": [{"role": "user", "content": "write a python function to sort a list"}]}' \
  | jq -r .model
```

Clients keep calling `vllm-sr/auto` as before — the router dispatches to the new
model internally, so no client changes are needed.

---

## LiteLLM Integration

vLLM-SR is registered in LiteLLM as a model called `vllm-sr/auto`. This
registration happens automatically at the end of the deployment playbook.

Clients choose between:
- `model: "vllm-sr/auto"` -- request goes through semantic routing
- `model: "<model-name>"` -- request goes directly to that model

Both paths go through LiteLLM for authentication and spend tracking.

---

## Langfuse Integration

vLLM-SR emits OpenTelemetry traces for every routed request. These appear
in Langfuse as nested spans alongside the LiteLLM traces.

### What Langfuse Shows

For each request routed through vLLM-SR, Langfuse displays:

**From LiteLLM** (`service.name: litellm`):
- Input prompt and output response
- Token counts and cost
- Total latency

**From vLLM-SR** (`service.name: vllm-semantic-router`):
- `semantic_router.signal.evaluation` -- which signals matched, confidence score
- `semantic_router.decision.evaluation` -- which route was selected, which model
- `semantic_router.upstream.request` -- backend call latency, HTTP status

> **Note:** not available in this release.

Together these give full visibility into why a model was selected and how
it performed.

---

## Troubleshooting

**Pod is not becoming Ready**

Check which container is failing:

```bash
kubectl get pods -n vllm-semantic-router-system -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}: {.ready}{"\n"}{end}'
```

Common causes:
- vllm-sr container: downloading encoder model (takes 1-2 minutes on first start)
- envoy container: increase file descriptor limits if you see "Too many open files"

**Traces not appearing in Langfuse**

Check the vLLM-SR container for export errors:

```bash
kubectl logs -n vllm-sr <pod-name> -c vllm-sr | grep "traces export"
```

> **Note:** not available in this release.

**LiteLLM returns "Connection error" for vllm-sr/auto**

Verify vLLM-SR is reachable from the litellm namespace:

```bash
kubectl exec -n litellm deploy/litellm -c litellm -- \
  python3 -c "import socket; s=socket.socket(); s.connect(('semantic-router.envoy-gateway-system.svc.cluster.local', 80)); print('OK')"
```

**Dashboard shows "Failed to read config"**

Check the dashboard container logs:

```bash
kubectl logs -n vllm-semantic-router-system deploy/semantic-router-dashboard
```
