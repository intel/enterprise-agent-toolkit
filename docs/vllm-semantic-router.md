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

---

## Getting Started

### Prerequisites

- The base stack must be deployed (Kubernetes, ingress, LiteLLM, at least one model)
- `deploy_vllm_sr=on` in `core/inventory/agentic-config.cfg`

### Deploy

Run the standard deployment script:

```bash
./deploy-agentic-stack.sh
```

The script will:
1. Discover deployed model services in the cluster
2. Deploy the vLLM-SR Helm chart
3. Wait for all containers to become healthy
4. Register `vllm-sr/auto` as a model in LiteLLM

### Verify

Send a request through the routing layer:

```bash
curl -k https://<cluster_url>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -d '{
    "model": "vllm-sr/auto",
    "messages": [{"role": "user", "content": "write a hello world in python"}]
  }'
```

You can also call a model directly (bypasses routing):

```bash
curl -k https://<cluster_url>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -d '{
    "model": "Qwen/Qwen2.5-Coder-14B-Instruct",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

### Access the Dashboard

The dashboard is exposed via ingress on its own host, `vllm-sr-<cluster_url>`:

```
https://vllm-sr-<cluster_url>/router
```

For example: `https://vllm-sr-api.example.com/router`

The dashboard serves root paths (`/login`, `/api`, `/assets`, ...) and cannot
run under a sub-path, so it gets its own host instead of sharing `<cluster_url>`
with the GenAI Gateway (LiteLLM) UI. The router API stays on
`https://<cluster_url>/v1/route`.

Prerequisites for the dashboard host:

- **DNS:** `vllm-sr-<cluster_url>` must resolve to the ingress (DNS record, or
  `/etc/hosts` on the node and on every client machine).
- **TLS certificate:** the certificate must cover `vllm-sr-<cluster_url>`, either
  as a SAN entry (`DNS:vllm-sr-<cluster_url>`) or via a parent-domain wildcard
  (e.g. `*.example.com` for `api.example.com`). See [Prerequisites](prerequisites.md). Existing
  certificates without it must be regenerated.
- **Corporate proxy:** add `vllm-sr-<cluster_url>` to the browser/OS proxy bypass
  list, as for `<cluster_url>`.

Default credentials are configured at deploy time via Ansible vault
(see Configuration section below).

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
        - model: qwen2-5-coder-14b-instruct
          use_reasoning: false
```

Lower priority number means higher precedence. The first matching decision wins.

**Model backends** are the models the router can route to. In normal use they
are discovered automatically at deploy time (see
[Onboarding a New Model](#onboarding-a-new-model)), so you do not edit them by
hand.

Each backend has this shape:

```yaml
backends:
  - name: qwen2-5-coder-14b-instruct                          # short name used in decisions
    model: "Qwen/Qwen2.5-Coder-14B-Instruct"                  # the model the backend serves
    baseUrl: "http://vllm-qwen-2-5-coder-14b-cpu-service.default:80/v1"  # its endpoint
    apiFormat: openai
```

- `name` — the short identifier referenced in `routing.decisions`.
- `model` — the model id the backend actually serves.
- `baseUrl` — the in-cluster endpoint, ending in `/v1`.
- `apiFormat` — the API style; `openai` for vLLM backends.

### Helm Values

All configuration is in `core/helm-charts/vllm-sr/values.yaml`. Key settings:

| Value | Description |
|-------|-------------|
| `image.tag` | vLLM-SR container version |
| `dashboard.adminEmail` | Dashboard login email (from vault) |
| `dashboard.adminPassword` | Dashboard login password (from vault) |
| `cache.backend` | Semantic cache: `memory` or `redis` |
| `routing.enableSemanticCache` | Enable/disable response caching |
| `routing.cacheThreshold` | Similarity above which a cached response is reused (default `0.92`) |
| `routing.defaultModel` | Backend **name** served when the router has no better choice. Empty => the first discovered backend. Set automatically by `deploy-vllm-sr.yml` |
| `routing.enableJailbreakDetection` | **Not yet wired** — see the note in `values.yaml` |
| `routing.enablePiiDetection` | **Not yet wired** — see the note in `values.yaml` |
| `observability.enabled` | Enable trace export to Langfuse |

### Updating the Routing Config

After editing the configmap template or values, redeploy with:

```bash
./deploy-agentic-stack.sh
```

Or update only vLLM-SR:

```bash
cd core
ansible-playbook -i inventory/hosts.yaml playbooks/deploy-vllm-sr.yml \
  --extra-vars "secret_name=<cluster_url> cert_file=<cert_path> key_file=<key_path>" \
  --vault-password-file inventory/.vault-passfile
```

The pod restarts automatically when the ConfigMap changes.

---

## Onboarding a New Model

When you deploy a model through the toolkit with vLLM-SR enabled
(`deploy_vllm_sr=on`), the model is onboarded into routing automatically. There
is no separate registration step.

During deployment, vLLM-SR discovers the model services running in the cluster,
adds each one as a routing backend, and rebuilds its routing config. The model
then shows up in the dashboard and becomes a candidate for routing.

To add a model:

1. Deploy the model through the toolkit with `deploy_vllm_sr=on`.
2. That's it — the model is discovered and added to routing as part of the same
   deployment.

You can confirm the model is available in the dashboard:

```
https://<cluster_url>/router
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

Send a prompt and check the selected model in the Langfuse trace
(`semantic_router.decision.evaluation`):

```bash
curl -k https://<cluster_url>/v1/chat/completions \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "vllm-sr/auto", "messages": [{"role": "user", "content": "write a python function to sort a list"}]}'
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

Together these give full visibility into why a model was selected and how
it performed.

---

## Troubleshooting

**Pod is not becoming Ready**

Check which container is failing:

```bash
kubectl get pods -n vllm-sr -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}: {.ready}{"\n"}{end}'
```

Common causes:
- vllm-sr container: downloading encoder model (takes 1-2 minutes on first start)
- envoy container: increase file descriptor limits if you see "Too many open files"

**Traces not appearing in Langfuse**

Check the vLLM-SR container for export errors:

```bash
kubectl logs -n vllm-sr <pod-name> -c vllm-sr | grep "traces export"
```

**LiteLLM returns "Connection error" for vllm-sr/auto**

Verify vLLM-SR is reachable from the genai-gateway namespace:

```bash
kubectl exec -n genai-gateway <litellm-pod> -- \
  python3 -c "import socket; s=socket.socket(); s.connect(('vllm-sr-envoy.vllm-sr.svc.cluster.local', 8801)); print('OK')"
```

**Dashboard shows "Failed to read config"**

Check the dashboard container logs:

```bash
kubectl logs -n vllm-sr <pod-name> -c dashboard
```
