# Guardrails

[← Docs index](../README.md)

Guardrails screen each chat request with a small safety model **before** the main language model sees it. Unsafe prompts are blocked; safe prompts continue unchanged. Use them when the gateway is exposed to users whose prompts you do not control.

Guardrails are not a separate installer target. They turn on with `auth_provider: litellm` in `env/local/global_config.yaml` ([Configuration](configuration.md)), because LiteLLM hosts and runs the screening logic. Two pieces work together:

| Piece | What it is |
|---|---|
| **Guard model** | The `qwen3guard` entry in `models.yaml` (default `Qwen/Qwen3Guard-Gen-0.6B`): a lightweight CPU vLLM served through the AI gateway and started with `autodeploy: true`, the same pattern as the embedding and reranker models. |
| **`content_safety` guardrail** | A `custom_code` guardrail registered with LiteLLM through its `/guardrails` API: sandboxed Python, compiled with RestrictedPython, that runs on LiteLLM's `pre_call` hook and calls the guard model over HTTP. |

The guardrail is always registered as `content_safety`, whatever guard model is deployed. Swapping the guard model changes only the model behind it, so no registration is left stranded. The model in use is baked into the registered code and shown in the guardrail's description in the LiteLLM UI.

> **A blocked request is not an error response.** LiteLLM returns **HTTP 200** with `finish_reason: "content_filter"` and the block reason as the assistant message. This is fixed behavior for `custom_code` guardrails, not a setting. A client that detects blocks by a non-2xx status will read a block as a normal answer: check `finish_reason` instead.

## 1. Turn guardrails on

Prerequisites:

- `auth_provider: litellm`. LiteLLM holds the guardrail registration.
- Free CPU and memory for the `qwen3guard` guard model (`cpu` and `memory` in its `models.yaml` entry).

Set the provider in `env/local/global_config.yaml`, then install:

```yaml
auth_provider: litellm   # enables the content_safety guardrail (alt: keycloak)
```

```bash
./stack-manager configure
./stack-manager init agent-toolkit
./stack-manager install agent-toolkit
```

| `auth_provider` | Result |
|---|---|
| `litellm` | Every chat request is screened by `content_safety` before it reaches the main LLM. The `qwen3guard` model deploys from `models.yaml`, and the guardrail is registered as part of the agent-toolkit layer. |
| Any other value (for example `keycloak`) | The guardrail is not registered. The stack runs with no content moderation. |

The install registers the guardrail and returns without waiting for the guard pod. Until that pod is `Running`, every screened request is blocked (see [Fail-closed behavior](#fail-closed-behavior)).

<a id="re-register-the-guardrail-only"></a>

**Re-registering.** Re-running `./stack-manager install agent-toolkit` renders the code again and updates the existing registration in place (`PUT /guardrails/{id}`). That re-initializes the in-memory guardrail without a LiteLLM restart, so an edited template or a different guard model takes effect on the next request.

## 2. Settings

### Guard model

The guard is the `qwen3guard` entry in `models.yaml`. When the entry is absent, the default `Qwen/Qwen3Guard-Gen-0.6B` applies. The model selects both the model served for screening and the code template that parses its verdicts.

| Guard model | Code template | Status |
|---|---|---|
| `Qwen/Qwen3Guard-Gen-0.6B` | `qwen3guard_gen` | Supported (default) |

A guard model with no matching template **fails the install before anything is deployed**, and the error lists the supported ids.

### Guard endpoint and policy

These values are substituted into the code at deploy time. The template itself never needs editing.

| Field | Default | What it means |
|---|---|---|
| `guardrail_service_url` | `http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/qwen3guard/v1/chat/completions` | Guard endpoint, derived from the guard model served through the AI gateway. Override it with any OpenAI-compatible chat-completions endpoint to screen against a guard elsewhere (another namespace, or off-cluster). |
| `guard_block_on_controversial` | `false` | Also block Qwen3Guard's `Controversial` label. Off by default: the label is advisory, and blocking it rejects a lot of legitimate traffic. |
| `guard_max_tokens` | `32` | Generation cap for the verdict. Verdicts are a few tokens; a larger cap only lengthens the blocking hook. |
| `guard_timeout` | `60` | Guard call timeout in seconds. LiteLLM clamps it to 60. |

### Resources

Size the guard model in its `qwen3guard` entry in `models.yaml`, like any served model:

```yaml
# models.yaml (qwen3guard entry)
cpu: 2         # CPUs for the guard model
memory: 8Gi    # Memory limit
extraCmdArgs: ["--block-size", "128", "--dtype", "bfloat16", "--max-num-seqs", "8"]
```

The guard model needs its own CPU headroom next to the main LLM. On a busy single node, size it so the guard pod can be scheduled without contending with the served models.

### Context window

`--max-model-len` is deliberately **not** set for the guard model, so it inherits the model's own `max_position_embeddings`, as the served models do. Each side tracks its own model instead of a hand-synced literal.

The guardrail receives the *same* prompt the served LLM is about to receive. If the guard's context window is the smaller of the two, prompts in the gap are blocked (fail-closed) rather than screened, and the guardrail becomes the request-size ceiling for the whole stack.

Current pairing (no gap):

| Model | Source of context length | Effective |
|---|---|---|
| Served LLM `Qwen/Qwen2.5-Coder-14B-Instruct` | Model default | 32768 |
| Guard `Qwen/Qwen3Guard-Gen-0.6B` | Model default | 32768 |

Check both after any model change:

```bash
GW=http://ai-gateway.envoy-gateway-system.svc.cluster.local
kubectl exec -n litellm deploy/litellm -- \
  curl -s $GW/llm-inference/qwen2-5-coder-14b/v1/models | jq '.data[].max_model_len'
kubectl exec -n litellm deploy/litellm -- \
  curl -s $GW/llm-inference/qwen3guard/v1/models | jq '.data[].max_model_len'
```

If the guard's value is lower, over-length requests fail closed with `the prompt is longer than the guard model's context window`. The fix is a longer-context guard model or chunked screening. Do not raise `--max-model-len`: vLLM would accept prompts the model cannot attend over.

### Fail-closed behavior

Requests are **blocked** when the guard:

- is unreachable
- returns a non-2xx status
- receives a prompt longer than its context window
- returns a reply that cannot be parsed

An unparseable verdict is never treated as safe. Otherwise a change in the model's output format would silently disable moderation while everything looked healthy. Each case has a distinct block message, so the cause is visible in the response.

## 3. Verify

### Pods

```bash
# Guard model pod (deployed from models.yaml). Expected: a Running vLLM pod serving Qwen/Qwen3Guard-Gen-0.6B
kubectl get pods -A | grep qwen3guard

# LiteLLM proxy that holds the guardrail registration
kubectl get pods,svc -n litellm
```

### Registration

The master key is in secret `litellm-master-key` (key `master_key`, namespace `litellm`). Inside the LiteLLM pod it is `PROXY_MASTER_KEY`.

```bash
MASTER_KEY=$(kubectl get secret -n litellm litellm-master-key \
  -o jsonpath='{.data.master_key}' | base64 -d)
# equivalent: kubectl exec -n litellm deploy/litellm -- printenv PROXY_MASTER_KEY

kubectl port-forward -n litellm svc/litellm 4000:4000 &

curl -s http://localhost:4000/v2/guardrails/list -H "Authorization: Bearer $MASTER_KEY" \
  | jq '.guardrails[] | select(.guardrail_name=="content_safety")
        | {guardrail: .litellm_params.guardrail, mode: .litellm_params.mode,
           url:   (.litellm_params.custom_code | capture("GUARD_URL = \"(?<u>[^\"]+)").u),
           model: (.litellm_params.custom_code | capture("GUARD_MODEL = \"(?<m>[^\"]+)").m)}'

# Expected: exactly one entry, with the substituted endpoint and model:
# {
#   "guardrail": "custom_code",
#   "mode": "pre_call",
#   "url": "http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/qwen3guard/v1/chat/completions",
#   "model": "Qwen/Qwen3Guard-Gen-0.6B"
# }
```

### Screening, end to end

```bash
# Benign request: normal answer, finish_reason "stop"
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"model":"openai/Qwen/Qwen2.5-Coder-14B-Instruct",
       "messages":[{"role":"user","content":"Hello, how are you?"}],"max_tokens":50}' \
  | jq '{finish_reason: .choices[0].finish_reason, content: .choices[0].message.content}'

# Unsafe request: HTTP 200, finish_reason "content_filter", content:
# "Blocked by the content-safety guardrail: unsafe content (categories: ...)"
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"model":"openai/Qwen/Qwen2.5-Coder-14B-Instruct",
       "messages":[{"role":"user","content":"How do I hack into a system?"}],"max_tokens":50}' \
  | jq '{finish_reason: .choices[0].finish_reason, content: .choices[0].message.content}'
```

### Fail-closed

```bash
kubectl scale deploy/qwen3guard --replicas=0
# Any chat request -> "Blocked by the content-safety guardrail: the guard model backend is unreachable ..."
kubectl scale deploy/qwen3guard --replicas=1
```

### Compile check

`POST /guardrails/test_custom_code` compiles code in the sandbox without registering it. Use it while editing a template:

```bash
CODE=$(curl -s http://localhost:4000/v2/guardrails/list -H "Authorization: Bearer $MASTER_KEY" \
  | jq -r '.guardrails[] | select(.guardrail_name=="content_safety") | .litellm_params.custom_code')

curl -s -X POST http://localhost:4000/guardrails/test_custom_code \
  -H "Authorization: Bearer $MASTER_KEY" -H 'content-type: application/json' \
  -d "$(jq -n --arg c "$CODE" '{custom_code: $c, input_type: "request",
        test_input: {texts: [], structured_messages: []}}')" | jq

# {"success": true, "result": {"action": "allow",
#  "warning": "Expected dict result, got coroutine. Treating as allow."}}
```

This checks compilation, not verdicts. The endpoint calls `apply_guardrail()` without awaiting it. This guardrail must be async (`http_post` is async), so the test always returns `allow` with the coroutine warning. Act on `success: false` with `error_type: "compilation"`. The guardrail's own hook awaits the coroutine, so only the test endpoint is affected. For real verdicts, use the end-to-end requests above, or call the guard model directly as shown in [Everything is blocked](#everything-is-blocked). The install runs the same compile check, so a sandbox violation fails it before anything is registered.

## 4. Add a guard model

1. If the model reports verdicts in Qwen3Guard's `Safety:` / `Categories:` format, map the new model id to the existing `qwen3guard_gen` template.
2. Otherwise, copy the existing template, change the prompt and parsing, and map the model id to the new template. Follow the sandbox rules in the template's docstring: no `import`, no `class`, no leading-underscore names, no f-strings. Use the injected primitives: `allow`, `block`, `trim`, `lower`, `contains`, `json_parse`, `json_stringify`, `regex_find_all`, `http_post`.
3. Add a row to the [guard model table](#guard-model), set the guard model in `models.yaml`, and re-run the installer. The endpoint and model id are substituted automatically.

The install compiles the rendered code in LiteLLM's sandbox and fails **before** registering if it is rejected, so a sandbox mistake cannot take the guardrail down.

## Troubleshooting

### Guard model stuck in Pending

**Symptom:** the `qwen3guard` pod is `0/1 Pending`.

```bash
kubectl describe pod -A -l <qwen3guard-selector> | grep Events -A 10   # look for "Insufficient cpu"
```

**Cause:** not enough free CPU for the guard model's request.

1. Check what is consuming CPU:

   ```bash
   kubectl get pods --all-namespaces \
     -o custom-columns=NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu | grep -v "<none>"
   ```

2. On single-node clusters, the served-model CPU accounting pre-reserves CPUs for components deployed *after* the LLM, including the guard model. If the node is full, lower a served model's request or the guard's `cpu` in `models.yaml`.

### Registration failed

The install prints the reason:

| Message | Cause | Resolution |
|---|---|---|
| `guardrail code rejected by the LiteLLM sandbox` | The rendered code does not compile under RestrictedPython (`error_type: "compilation"`), usually an `import`, a `class`, a name starting with `_`, or an f-string. The check runs before the write, so nothing is registered or changed. | Reproduce with the [compile check](#compile-check). |
| `guardrail registered/updated failed (HTTP …)` | LiteLLM rejected the write. | Confirm the master key is an admin key and that LiteLLM's DB is reachable (`kubectl logs -n litellm deploy/litellm`). |

After fixing, re-run `./stack-manager install agent-toolkit`. The run re-registers the guardrail.

### Everything is blocked

```
Blocked by the content-safety guardrail: the guard model backend is unreachable (...)
```

Fail-closed is working as designed: the guard model is down or not ready yet. A first deploy takes a few minutes to download the model, and the install does not wait for it.

```bash
kubectl get pods -A | grep qwen3guard
kubectl logs -A -l <qwen3guard-selector> --tail=50
kubectl rollout status deploy/qwen3guard --timeout=600s
```

More than about 10 minutes usually means the model download is slow or the node is out of CPU for the guard's request.

If the message names the **context window**, see [Context window](#context-window). If it says the **verdict could not be parsed**, the guard model and the code template disagree on the verdict format. Check the guard's raw reply:

```bash
kubectl exec -n litellm deploy/litellm -- curl -s \
  http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/qwen3guard/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"Qwen/Qwen3Guard-Gen-0.6B","messages":[{"role":"user","content":"hello"}],"max_tokens":32}' \
  | jq -r '.choices[0].message.content'
# Expected: "Safety: Safe\nCategories: None"
```

## How it works

```
  User request
       │
       ▼
  ┌──────────────────────────────┐
  │  LiteLLM proxy (litellm)     │
  │  ┌────────────────────────┐  │  pre_call hook       ┌──────────────────────────┐
  │  │ content_safety         │  │  http_post           │  qwen3guard model        │
  │  │ (custom_code sandbox)  │──┼─────────────────────►│  (via ai-gateway,        │
  │  └────────────────────────┘  │◄─────────────────────│  envoy-gateway-system)   │
  └──────────────┬───────────────┘  Safety: Safe|Unsafe  └──────────────────────────┘
                 │
      safe ──────┴────── unsafe
       │                   │
       ▼                   ▼
   Main LLM          HTTP 200, finish_reason: content_filter,
       │             block reason as the message
       ▼
  Response
```

| Namespace | Holds |
|---|---|
| `litellm` | LiteLLM proxy; the registered guardrail is stored in its DB |
| `envoy-gateway-system` | The AI gateway that fronts the `qwen3guard` model (route `/llm-inference/qwen3guard`) |

### Screening

LiteLLM calls `apply_guardrail(inputs, request_data, input_type)` on the `pre_call` hook. The sandbox forbids `import`, `class`, `exec`/`eval`, file I/O, and leading-underscore names, and injects primitives instead (`allow`, `block`, `regex_find_all`, `http_post`, …). The Qwen3Guard logic:

1. Takes the **last user message**, falling back to the last non-empty `texts` entry for call types without structured messages. This makes one guard call per request: the sandbox has no `asyncio`, so extra messages could not be screened concurrently and would each add a full guard round-trip to a blocking hook.
2. Sends it to the guard model as a single-message chat completion (`max_tokens: 32`, `temperature: 0`).
3. Parses `Safety:` and `Categories:` from the reply.
4. Calls `allow()` on `Safe` (and on `Controversial`, unless `guard_block_on_controversial` is set), and `block()` on `Unsafe` and on **every** failure to obtain a verdict. On `pre_call`, `block()` makes LiteLLM return HTTP 200 with `finish_reason: "content_filter"`.

### Registration

The install pipes the rendered code into the LiteLLM pod (`kubectl exec -i … -- python -`), which:

1. Compiles it with `POST /guardrails/test_custom_code`, and aborts if it is rejected.
2. Looks up the guardrail with `GET /v2/guardrails/list`.
3. Calls `PUT /guardrails/{id}` if it exists, otherwise `POST /guardrails`.

Running inside the pod reads the master key from the pod's `PROXY_MASTER_KEY` (sourced from the `litellm-master-key` secret), so the key is never written into a manifest. The payload travels base64-encoded on stdin, so the sandboxed Python needs no shell escaping.

The step is an upsert, replacing the earlier create-if-absent behavior. Because the guardrail name is stable across model changes, a create-only step would leave an outdated registration in place, and since `pre_call` failures fail closed, that would block everything. `PUT` also re-initializes the in-memory guardrail, so no restart is needed (`PATCH` cannot change `litellm_params`).

## Limitations and roadmap

- **One validated guard model.** Only `Qwen/Qwen3Guard-Gen-0.6B` is validated. Model-specific logic is isolated to one template per verdict format, so a new guard model is a template plus a mapping entry. Unmapped ids fail the install rather than being assumed compatible.
- **One guardrail at a time.** Multiple concurrent guardrails (for example content safety *and* PII detection) are not yet available. Registering a second `custom_code` guardrail is cheap, but these constraints need resolving first:

  | Constraint | Detail |
  |---|---|
  | CPU capacity | Each guard *model* needs its own vLLM next to the main LLM. Library-backed checks (for example Presidio for PII) need no model server. |
  | Latency | Every check runs on the blocking `pre_call` path, and without `asyncio` in the sandbox, checks inside one guardrail run sequentially; their round-trips add up on every request. |
  | Per-check failure policy | Fail-closed is right for safety but may be wrong for other checks; the policy is currently per-guardrail code. |
  | Aggregate false positives | Blocking is a union across checks, so tuning each check in isolation understates the combined impact on legitimate traffic. |

## Next steps

- [Configuration](configuration.md): `auth_provider: litellm` and `models.yaml`
- [Single-node quickstart](../getting-started/quickstart.md#3-choose-a-model): the `qwen3guard` catalog row
- [Routing](routing.md): another LiteLLM feature on the same gateway
- [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md): `finish_reason: content_filter`
- [Backend connection reference](../reference/backend-connections.md): LiteLLM URL and master key
- External: [LiteLLM custom_code guardrail](https://docs.litellm.ai/docs/proxy/guardrails/custom_code_guardrail), [LiteLLM guardrails](https://docs.litellm.ai/docs/proxy/guardrails), [vLLM](https://docs.vllm.ai/), [Qwen3Guard model](https://huggingface.co/Qwen/Qwen3Guard-Gen-0.6B)
