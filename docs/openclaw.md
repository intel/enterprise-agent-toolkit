# OpenClaw

OpenClaw is an AI agent platform deployed via a Kubernetes operator.
It connects directly to vLLM for model inference — no proxy layer needed.

---

## Deployment

### Step 1: Install the Operator

The operator is installed automatically when `deploy_openclaw=on` in `agentic-config.cfg`:

```bash
# In core/inventory/agentic-config.cfg
deploy_openclaw=on
```

Then run:
```bash
./deploy-agentic-stack.sh
```

Or install manually:
```bash
helm install openclaw-operator oci://ghcr.io/paperclipinc/charts/openclaw-operator \
  --namespace openclaw-operator-system --create-namespace
```

This installs:
- CRDs: `OpenClawInstance`, `OpenClawClusterDefaults`, `OpenClawSelfConfig`
- Controller: manages lifecycle of OpenClaw instances

### Step 2: Deploy an Instance

Deploy an instance pointing to your vLLM model:

```bash
helm install openclaw-enhanced core/helm-charts/openclaw-instance/ \
  --namespace openclaw --create-namespace \
  --set model.id="Qwen/Qwen3-Coder-30B-A3B-Instruct" \
  --set model.baseUrl="http://vllm-qwen3-coder-30b-cpu-service.default.svc.cluster.local:80/v1"
```

To use a different model:
```bash
helm install openclaw-enhanced core/helm-charts/openclaw-instance/ \
  --namespace openclaw --create-namespace \
  --set model.id="google/gemma-4-26B-A4B-it" \
  --set model.name="Gemma4 26B" \
  --set model.baseUrl="http://vllm-gemma4-26b-a4b-cpu-service.default.svc.cluster.local:80/v1"
```

### Step 3: Access the Web UI

```bash
kubectl port-forward -n openclaw svc/openclaw-enhanced 18789:18789
# Open: http://localhost:18789
```

From laptop via SSH tunnel:
```bash
ssh -L 18789:localhost:18789 sdp@<server-ip>
```

---

## Helm Chart Values

The instance chart is at `core/helm-charts/openclaw-instance/`.

| Value | Default | Description |
|-------|---------|-------------|
| `model.id` | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | Model ID (must match vLLM's `/v1/models`) |
| `model.name` | `Qwen3 Coder 30B` | Display name |
| `model.baseUrl` | `http://vllm-qwen3-coder-30b-cpu-service.default.svc.cluster.local:80/v1` | vLLM endpoint |
| `model.apiKey` | `sk-no-key-needed` | API key (vLLM doesn't require one) |
| `image.repository` | `ghcr.io/openclaw/openclaw` | Container image |
| `image.tag` | `latest` | Image tag |
| `resources.requests.cpu` | `2` | CPU request |
| `resources.requests.memory` | `4Gi` | Memory request |
| `storage.size` | `20Gi` | PVC size |
| `gateway.token` | `openclaw-gateway-token-change-me-in-production` | Gateway auth token |
| `security.networkPolicy.enabled` | `false` | NetworkPolicy (disable for cross-namespace vLLM access) |

---

## Architecture

```
OpenClaw Pod (namespace: openclaw)
    │
    │ api: openai-completions
    │ model: Qwen/Qwen3-Coder-30B-A3B-Instruct
    │
    ▼
vLLM Service (namespace: default)
    service: vllm-qwen3-coder-30b-cpu-service:80
    endpoint: /v1/chat/completions
```

No LiteLLM, Redis, PostgreSQL, or other services needed for basic operation.

---

## Configuration Details

The helm chart creates an `OpenClawInstance` CRD with:

- **`config.raw`** — registers the vLLM provider in OpenClaw's internal config
- **`mergeMode: merge`** — config persists across pod restarts
- **`api: openai-completions`** — uses standard `/v1/chat/completions` format
- **`baseUrl` with `/v1`** — required because OpenClaw appends `/chat/completions` to it
- **`model.id`** — must match exactly what vLLM reports (e.g. `Qwen/Qwen3-Coder-30B-A3B-Instruct`)
- **NetworkPolicy disabled** — default policy only allows DNS+HTTPS; vLLM is on port 80

---

## Troubleshooting

### "Unknown model: openai/X"

Missing `models.providers.openai.models[]` entry. The model id in the helm values
must match exactly what vLLM reports at `/v1/models`.

### "model was not found by the provider" (404)

`baseUrl` is missing `/v1`. It must end with `/v1` so OpenClaw constructs
`/v1/chat/completions` correctly.

### "provider rejected the request schema or tool payload"

Wrong `api` type. Must be `openai-completions` for vLLM.

### Network timeout

NetworkPolicy is blocking. Ensure `security.networkPolicy.enabled=false` or add
`additionalEgress` for port 80 to the vLLM namespace.

### Config resets on pod restart

The chart uses `mergeMode: merge` which preserves runtime changes.
The `config.raw` from the CRD is applied on every startup by the operator init container.

### Useful commands

```bash
kubectl get openclawinstance -n openclaw
kubectl get pods -n openclaw
kubectl logs -n openclaw openclaw-enhanced-0 -c openclaw --tail=30
kubectl exec -n openclaw openclaw-enhanced-0 -c openclaw -- cat /home/openclaw/.openclaw/openclaw.json
```

---

## Uninstall

```bash
# Remove instance
helm uninstall openclaw-enhanced -n openclaw
kubectl delete namespace openclaw

# Remove operator
helm uninstall openclaw-operator -n openclaw-operator-system
kubectl delete namespace openclaw-operator-system
kubectl delete crd openclawinstances.openclaw.rocks openclawclusterdefaults.openclaw.rocks openclawselfconfigs.openclaw.rocks
```
