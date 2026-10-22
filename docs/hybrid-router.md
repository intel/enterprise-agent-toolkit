# Hybrid Router — Intelligent Inference Routing for the GenAI Gateway

The **Hybrid Router** adds cost- and latency-aware model selection to the LiteLLM
GenAI Gateway. Clients call a single virtual model (`hybrid-router`); the router
classifies each request by complexity and dispatches it to the best real model for
that tier, learning over time which model is most efficient.

It is integrated into the stock LiteLLM proxy image **without rebuilding the image** —
the router code is mounted from a Kubernetes ConfigMap and activated through a
LiteLLM callback. Enable or disable it with a single Helm value.

---

## Table of Contents

- [Why](#why)
- [How it works](#how-it-works)
- [Two routing layers](#two-routing-layers)
  - [Layer 1 — Complexity classification](#layer-1--complexity-classification)
  - [Layer 2 — Efficiency (multi-armed bandit)](#layer-2--efficiency-multi-armed-bandit)
- [Deployment](#deployment)
- [Configuration reference](#configuration-reference)
- [Onboarding the virtual model](#onboarding-the-virtual-model)
- [Testing](#testing)
- [Observability](#observability)
- [File layout](#file-layout)
- [Disabling the router](#disabling-the-router)

---

## Why

Sending every request to a large model is slow and expensive; sending everything to
a small model sacrifices quality on hard prompts. The Hybrid Router picks the
smallest model that can handle each request:

- **Simple** prompts (greetings, factual lookups) → small, fast models.
- **Complex / reasoning** prompts (architecture, chain-of-thought, proofs) → larger models.
- Within a tier, an online **multi-armed bandit (MAB)** learns which candidate model is
  fastest and highest-throughput, and shifts traffic toward it automatically.

The result is lower average latency and cost with no client-side changes — callers
keep calling one model name.

---

## How it works

The integration mirrors LiteLLM's own built-in `ComplexityRouter`. At proxy startup,
the custom module monkey-patches `litellm.router.Router` to recognise a new
`auto_router/hybrid_router` deployment prefix. A pre-routing hook then intercepts every
request to the virtual model *before* a deployment is chosen.

```
Request  model="hybrid-router"
  │
  ▼
Router.async_pre_routing_hook  (patched by custom_hybrid_router.py)
  │  model in hybrid_routers?   NO  → normal LiteLLM routing (unaffected)
  │                             YES ↓
  │  1. Extract user + system text from messages
  │  2. HybridRouter.classify()   → SIMPLE / MEDIUM / COMPLEX / REASONING
  │  3. HybridRouter.pick_model() → best real model for that tier (MAB bandit)
  │  4. Return PreRoutingHookResponse(model=<chosen real model>)
  │
  ▼
LiteLLM routes to the chosen real model as normal
  │
  ▼
async_log_success_event / async_log_failure_event
     Compute latency + token throughput → reward → bandit.update()
     (the bandit learns, per tier, which model is fastest over time)
```

Requests to any other model name (`llama-8b`, `qwen-local-4b`, …) are **not touched** —
only traffic addressed to the virtual `hybrid-router` entry is intercepted.

---

## Two routing layers

### Layer 1 — Complexity classification

A lightweight, rules-based classifier (no extra model call) scores each prompt across
several dimensions — estimated token count, code / reasoning / technical / simple
keyword hits, multi-step patterns (`first … then`, `step 2`, numbered lists), and
question density — then maps the weighted score to a tier.

| Tier | Score range | Typical queries |
|------|-------------|-----------------|
| `SIMPLE` | `< 0.15` | Greetings, factual lookups, yes/no |
| `MEDIUM` | `0.15 – 0.35` | Explanations, summaries, basic coding |
| `COMPLEX` | `0.35 – 0.60` | Architecture, multi-step code, technical analysis |
| `REASONING` | `≥ 0.60` **or** 2+ reasoning markers | Chain-of-thought, deduction, proof |

Tier boundaries, token thresholds, keyword lists, and dimension weights are all
overridable via `complexity_router_config` (see the reference below).

### Layer 2 — Efficiency (multi-armed bandit)

Each tier owns an independent bandit whose arms are that tier's candidate models. A
model may be fast for `SIMPLE` prompts but slow for `COMPLEX` ones (longer generation),
so per-tier bandits learn these behaviours separately.

After each response the router computes a reward and updates the arm:

```
time_per_token = latency_seconds / max(completion_tokens, 1)
reward         = target_tpt / (target_tpt + time_per_token)     # in (0, 1]
```

Failures record a reward of `0`. When `quality_weight > 0`, the reward blends
efficiency with a quality score:
`reward = (1 - quality_weight) * efficiency + quality_weight * quality_score`.

Three bandit algorithms ship (selectable via `bandit`):

| Value | Algorithm | Behaviour |
|-------|-----------|-----------|
| `thompson` *(default)* | Beta-Bernoulli Thompson Sampling | Posterior sampling; strong exploration/exploitation balance |
| `ucb` | Upper Confidence Bound | Optimism under uncertainty; `delta` widens the exploration bound |
| `epsilon_greedy` | ε-greedy | Explores uniformly with probability `epsilon`, else greedy |

> A tier with only one candidate model skips the bandit entirely and routes directly.

---

## Deployment

The router is part of the **`genai-gateway`** Helm chart and is controlled by one value:

```yaml
# core/helm-charts/genai-gateway/values.yaml
customRouter:
  # Mount the custom hybrid router into the LiteLLM container.
  enabled: true
```

When `customRouter.enabled: true`, the chart:

1. Renders the router source into the `genai-gateway-router-code` ConfigMap
   (`templates/router-configmap.yaml`).
2. Volume-mounts each Python file into `/app/` and `/app/router_strategy/…` in the
   LiteLLM container (`templates/deployment.yaml`).
3. Registers the callback so LiteLLM imports the module (and applies the monkey-patch)
   at startup:

   ```yaml
   litellm_settings:
     callbacks: ["langfuse_otel", "custom_hybrid_router.proxy_handler_instance"]
   ```

No image rebuild is required. To change router *code*, edit the files under
`core/helm-charts/genai-gateway/router/` and `helm upgrade`; to change router *config*,
edit the virtual model entry (below) and restart the pod.

---

## Configuration reference

Routing configuration lives on the virtual model's `litellm_params.hybrid_router_config`.

| Key | Default | Description |
|-----|---------|-------------|
| `bandit` | `thompson` | MAB algorithm: `ucb`, `epsilon_greedy`, `thompson` |
| `delta` | `0.1` | UCB exploration parameter — smaller = more exploration (must be in `(0, 1)`) |
| `epsilon` | `0.1` | ε-greedy exploration probability (must be in `[0, 1]`) |
| `target_tpt` | `1.0` | Target time-per-token; sets the reward curve's midpoint |
| `quality_weight` | `0.0` | Quality-vs-efficiency blend in `[0, 1]`; `0` = pure efficiency |
| `tier_candidates` | *(defaults to `hybrid_router_default_model` for every tier)* | Map of tier → list of real model names |
| `tier_priors` | *(none)* | Optional per-tier, per-arm Beta priors `(alpha, beta)` for Thompson Sampling |
| `complexity_router_config` | built-in defaults | Override tier boundaries, token thresholds, keyword lists, dimension weights |
| `hybrid_router_default_model` | — | Fallback model; **required** if `tier_candidates` is omitted |

`complexity_router_config.tier_boundaries` accepts `simple_medium`, `medium_complex`,
and `complex_reasoning` (defaults `0.15`, `0.35`, `0.60`).

---

## Onboarding the virtual model

Add the real backend models to the gateway as usual, then add **one** virtual entry
whose `model` uses the `auto_router/hybrid_router` prefix. Example config:

```yaml
model_list:
  # --- real backends ---
  - model_name: llama-8b
    litellm_params:
      model: openai/Llama-3.1-8B
      api_base: http://inference-8b:8000/v1
      api_key: not-needed
  - model_name: llama-70b
    litellm_params:
      model: openai/Llama-3.1-70B
      api_base: http://inference-70b:8000/v1
      api_key: not-needed

  # --- virtual hybrid-router entry (what clients call) ---
  - model_name: hybrid-router
    litellm_params:
      model: auto_router/hybrid_router
      hybrid_router_default_model: llama-8b
      hybrid_router_config:
        bandit: thompson
        target_tpt: 1.0
        quality_weight: 0.0
        tier_candidates:
          SIMPLE:    [llama-8b, llama-70b]
          MEDIUM:    [llama-8b, llama-70b]
          COMPLEX:   [llama-70b]
          REASONING: [llama-70b]
        complexity_router_config:
          tier_boundaries:
            simple_medium: 0.15
            medium_complex: 0.35
            complex_reasoning: 0.60
```

The `auto_router/hybrid_router` model is never dispatched directly — the pre-routing
hook rewrites the target before LiteLLM selects a deployment.

### Onboarding at runtime via the `/model/new` API

If the gateway is already running (and `store_model_in_db` is enabled), you can add the
virtual entry live — no config edit or restart — by POSTing to `/model/new` with the
master key. First retrieve the key the same way as the other guides:

```bash
# Retrieve the LiteLLM master key from the running deployment
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

# Replace api.example.com with your gateway (cluster) URL
curl -k --location 'https://api.example.com/model/new' \
  --header "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  --header 'Content-Type: application/json' \
  --data '{
    "model_name": "hybrid_router2",
    "litellm_params": {
        "model": "auto_router/hybrid_router",
        "hybrid_router_default_model": "Qwen/Qwen2.5-Coder-14B-Instruct",
        "hybrid_router_config": {
            "bandit": "thompson",
            "delta": 0.1,
            "epsilon": 0.1,
            "target_tpt": 1.0,
            "quality_weight": 0.0,
            "tier_candidates": {
                "SIMPLE": [
                    "meta-llama/Llama-3.1-8B-Instruct",
                    "Qwen/Qwen2.5-Coder-14B-Instruct"
                ],
                "MEDIUM": [
                    "meta-llama/Llama-3.1-8B-Instruct",
                    "Qwen/Qwen2.5-Coder-14B-Instruct"
                ],
                "COMPLEX": [
                    "Qwen/Qwen3-Coder-30B-A3B-Instruct"
                ],
                "REASONING": [
                    "Qwen/Qwen3-Coder-30B-A3B-Instruct"
                ]
            },
            "complexity_router_config": {
                "tier_boundaries": {
                    "simple_medium": 0.15,
                    "medium_complex": 0.35,
                    "complex_reasoning": 0.60
                },
                "token_thresholds": {
                    "simple": 15,
                    "complex": 400
                }
            }
        }
    },
    "model_info": {}
}'
```

The `model_name` is what clients call (here `hybrid_router2`), and every model listed
in `tier_candidates` / `hybrid_router_default_model` must already be onboarded on the
gateway. The `LITELLM_MASTER_KEY` is set in the `genai-gateway-deployment` environment
variables in the `genai-gateway` namespace.

---

## Testing

Send any request to `model="hybrid-router"`:

```bash
curl http://<gateway-host>:4000/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "hybrid-router", "messages": [{"role": "user", "content": "What is 2+2?"}]}'
```

The router classifies the prompt and transparently forwards it. Requests addressed to
`llama-8b`, `llama-70b`, or any other model name are unaffected.

---

## Observability

The proxy logs one line at startup and one per routed request:

```
[HybridRouterProxy] litellm.router.Router patched for auto_router/hybrid_router
[HybridRouterProxy] Initialised model_name=hybrid-router bandit=thompson default=llama-8b tiers=['SIMPLE', 'MEDIUM', 'COMPLEX', 'REASONING']
[HybridRouterProxy] model=hybrid-router call_id=... tier=SIMPLE -> llama-8b
```

Inspect them with:

```bash
kubectl logs -n genai-gateway deploy/genai-gateway-deployment -c litellm-container -f
```

Per-tier bandit state (arm counts, running means, and — for Thompson — the Beta
`alpha`/`beta` posteriors) is exposed programmatically via
`HybridRouterProxy.router_state()`. Latency and token metrics also flow to Langfuse /
Prometheus through the standard gateway telemetry pipeline.

---

## File layout

```
core/helm-charts/genai-gateway/
├── values.yaml                       ← customRouter.enabled + callbacks
├── templates/
│   ├── router-configmap.yaml         ← renders router code into a ConfigMap
│   └── deployment.yaml               ← volume-mounts the code into /app/
└── router/
    ├── custom_hybrid_router.py       ← callback + Router monkey-patch (entry point)
    └── router_strategy/
        ├── complexity_router/        ← (tier config; sourced from LiteLLM)
        ├── efficiency_router/
        │   ├── bandit.py             ← UCB / EpsilonGreedy / ThompsonSampling
        │   └── efficiency_router.py  ← standalone efficiency router + reward fns
        └── hybrid_router/
            └── hybrid_router.py      ← two-layer router (classify → pick)
```

---

## Disabling the router

Set `customRouter.enabled: false` in `values.yaml` and `helm upgrade`. The ConfigMap and
volume mounts are removed and the callback is dropped, so the gateway behaves as a stock
LiteLLM proxy. Remove the virtual `hybrid-router` model entry as well so clients no
longer reference it.
