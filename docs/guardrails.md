# Guardrails — Safety Content Moderation

**Guardrails** provides safety content moderation for LLM requests in the Agentic AI Stack. It screens chat requests through a dedicated guard model before they reach the main LLM, blocking unsafe or policy-violating content.

Two components:

1. **Guard vLLM** — lightweight CPU vLLM instance serving the guard model, selected by `guardrail_model` (default: `qwen3guard`)
2. **A `custom_code` guardrail registered with the GenAI Gateway** — the screening logic itself, sandboxed Python stored in the gateway and run on LiteLLM's `pre_call` hook. It calls the guard vLLM directly over HTTP.

The screening logic lives in one Ansible
template, [qwen3guard_gen.py.j2](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/lib/guardrails/qwen3guard_gen.py.j2), which
[deploy-guardrails.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/deploy-guardrails.yml) renders (guard endpoint,
model id, policy) and registers through the gateway's `/guardrails` API. LiteLLM compiles it
with RestrictedPython and calls its `apply_guardrail()` on every request.

The guard vLLM is a release of the existing `vllm` chart — `vllm-guard`, configured by
[guardrail-values.yaml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/helm-charts/vllm/guardrail-values.yaml) — the same pattern
the embedding and reranker deployments use (`vllm/embedding-values.yaml`,
`vllm/reranker-values.yaml`): one chart, one values file per variant.

The guardrail's **identity is model-agnostic**: it is registered as `content_safety`
whatever guard model is deployed. Swapping `guardrail_model` changes only the model behind
it, never its name, so no gateway registration is ever left stranded. The model actually in
use is baked into the registered code and shown in the guardrail's description in the
gateway UI.

> **A blocked request is an error response.** LiteLLM's `pre_call` path returns
> **HTTP 500** with the block reason in `error.message`, for example
> `Custom code guardrail execution failed: Blocked by the content-safety guardrail: unsafe content (categories: …)`.
> That is fixed behaviour for `custom_code` guardrails, not a configurable choice,
> so a client that decides "blocked" from a non-2xx status sees the block — check
> `error.message` for the reason.
>
> Re-running the install is idempotent: the registration step **updates** the stored code
> via `PUT /guardrails/{id}`, which re-initializes the in-memory guardrail — no gateway
> restart, so an edited template or a different guard model takes effect on the next request.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Request Flow                             │
└─────────────────────────────────────────────────────────────┘

  User Request
       │
       ▼
  ┌──────────────────────────────┐
  │  GenAI Gateway (LiteLLM)     │
  │  ┌────────────────────────┐  │  pre_call hook       ┌─────────────────────────┐
  │  │ content_safety         │  │  http_post           │  Guard vLLM             │
  │  │ (custom_code sandbox)  │──┼─────────────────────►│  (guardrail_model)      │
  │  └────────────────────────┘  │◄─────────────────────│  via the AI gateway     │
  └──────────────┬───────────────┘  Safety: Safe|Unsafe  └─────────────────────────┘
                 │                                        Namespace: llm-inference
      safe ──────┴────── unsafe
       │                   │
       ▼                   ▼
  ┌─────────────┐   HTTP 500 with the
  │  Main LLM   │   block reason in error.message
  └─────────────┘
       │
       ▼
  Response to User
```

**Namespaces:**
- `llm-inference` — guard model (`qwen3guard`), next to the other models
- `litellm` — LiteLLM proxy; holds the registered guardrail in its DB

---

## Configuration

### Enable/Disable

Edit `env/<name>/config.agent-toolkit.yaml`:

```yaml
guardrails_enabled: true   # Enable guardrails (default: on with LiteLLM)
```

- `true` — deploys the guard vLLM and registers the guardrail; LiteLLM screens every chat request before it reaches the main LLM.
- `false` — skips the step entirely; the stack runs unchanged with no content moderation.

**Guard model:** optional `guardrail_model` key in the same file (a catalog name). When
absent, `qwen3guard` applies. The value selects
both the model served by the guard vLLM and the code template that parses its verdicts.

| `guardrail_model` value | Code template | Status |
|---|---|---|
| `qwen3guard` (`Qwen/Qwen3Guard-Gen-0.6B`) | `qwen3guard_gen.py.j2` | Supported (default) |

The mapping is `guard_code_templates` in
[deploy-guardrails.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/deploy-guardrails.yml). A model with no entry
**fails the playbook before anything is deployed**, with the supported ids in the error —
rather than deploying a guard whose verdicts nothing can parse.

> **Note:** not available in this release.

**Fail-closed behaviour:** requests are blocked when the guard is unreachable, when it
returns a non-2xx, when the prompt exceeds its context window, or when its reply cannot be
parsed. An unparseable verdict is never treated as "safe" — otherwise a change in the
model's output format would silently disable moderation while everything looked healthy.
Each case produces a distinct block message, so the cause is visible in the response.

### Guard endpoint and policy

All of these are settings in `env/<name>/config.agent-toolkit.yaml`, substituted into the
code at deploy time — the template itself never needs editing:

| Var | Default | Purpose |
|---|---|---|
| `guardrail_service_url` | derived: `http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/qwen3guard/v1/chat/completions` | Guard endpoint. Derived from the AI gateway and the guard model's namespace/name; override to screen against an OpenAI-compatible guard elsewhere (another namespace, off-cluster). |
| `guard_block_on_controversial` | `false` | Also block Qwen3Guard's `Controversial` label. Off by default: it is advisory and blocking it rejects a lot of legitimate traffic. |
| `guard_max_tokens` | `32` | Generation cap for the verdict. Verdicts are a few tokens; a larger cap only lengthens the blocking hook. |
| `guard_timeout` | `60` | Guard call timeout (LiteLLM clamps this to 60s). |

```bash
# e.g. point the guardrail at a guard vLLM in another namespace:
# set in env/<name>/config.agent-toolkit.yaml
#   guardrail_service_url: "http://ai-gateway.envoy-gateway-system.svc.cluster.local/other-ns/qwen3guard/v1/chat/completions"
./es_auto_installer.sh install agent-toolkit
```

### Resource Allocation

Edit the `qwen3guard` entry in `env/<name>/models.yaml`:

```yaml
  - name: qwen3guard
    model_id: Qwen/Qwen3Guard-Gen-0.6B
    cpu: 8         # CPUs for the guard model
    memory: 16Gi   # Memory limit
    args: [ "--block-size", "128", "--dtype", "bfloat16", "--max-num-seqs", "8", "--tensor-parallel-size", "1" ]
    env:
      VLLM_CPU_KVCACHE_SPACE: "4"
```

**Neither `cpu` nor `memory` above is what a normal CPU deploy actually gets.** On a CPU
platform with the balloon policy enabled, `deploy-guardrails.yml` overrides both from the
detected node topology, the same way the served LLMs are sized:

| | value used | derivation |
|---|---|---|
| `cpu` | `min(optimal_cpu_cores, workload_cpus)` | per-model `optimal_cpu_cores` above, clamped to the CPUs the balloon leaves free |
| `memory` | `clamp(socket-0 usable, 128, 256) Gi` | [utils/get_optimal_memory.yaml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/roles/utils/tasks/get_optimal_memory.yaml), shared with `deploy-inference-models.yml`; TP comes from the guard's own `tensor_parallel_size` (1), not the node's NUMA count |

> **Note:** not available in this release.

So on a large Xeon the guard's limit lands at the 256Gi cap, and the `8Gi` above applies only
to deploys that skip that path: XPU/GPU platforms, a disabled balloon policy, or a standalone
`helm upgrade --install`. **8Gi is not enough** — the guard's four vLLM processes peak at
~8.6 GiB (a 6.8 GiB worker holding the 4 GiB KV cache plus bf16 weights, a ~0.9 GiB API
server, a ~0.7 GiB EngineCore), so an 8Gi cgroup limit OOM-kills the pod with exit code 137
in a `CrashLoopBackOff`. Raise `memory` here before deploying the guard on one of those paths.
Do *not* cut `VLLM_CPU_KVCACHE_SPACE` to fit instead: at 4 GiB it yields 37,376 tokens against
a 32,768 context window, and halving it puts the cache below the guard's own window, so long
prompts fail closed rather than being screened.

**Important:** the guard vLLM uses the **Recreate** deployment strategy. RollingUpdate would
need the guard's CPU request twice over during a rollout, and on a busy single node the new
pod stays `Pending` forever.

> **Note:** not available in this release.

### Context window

`--max-model-len` is deliberately **not** set for the guard vLLM, so it inherits the guard
model's own `max_position_embeddings` — the same way the served models are configured (their
`args` in `env/<name>/models.yaml` do not set it either). Both sides therefore track
their own model instead of a literal that has to be kept in sync by hand.

This matters because the guardrail runs `pre_call` and is handed the *same* prompt the
served LLM is about to receive. If the guard's context window is the smaller of the two,
prompts in the gap are rejected by the guard and blocked (fail-closed) rather than screened
— the guardrail silently becomes the request-size ceiling for the whole stack.

Current pairing (both 32768, so no gap):

| | source of context length | effective |
|---|---|---|
| served LLM `qwen2-5-coder-14b` | model default | 32768 |
| guard `qwen3guard` | model default | 32768 |

Verify after any model change:

```bash
kubectl exec -n llm-inference deploy/<model>-kserve -c main -- python3 -c \
  "import json,urllib.request; print([m['max_model_len'] for m in json.load(urllib.request.urlopen('http://localhost:8000/v1/models'))['data']])"
kubectl exec -n llm-inference deploy/qwen3guard-kserve -c main -- python3 -c \
  "import json,urllib.request; print([m['max_model_len'] for m in json.load(urllib.request.urlopen('http://localhost:8000/v1/models'))['data']])"
```

If the guard's number is lower, over-length requests fail closed with `the prompt is longer
than the guard model's context window` (reported distinctly from an unreachable guard).
Resolving it needs a deliberate choice — a longer-context guard model, or chunked screening
— not a larger `--max-model-len`, which would only make vLLM accept a prompt the model
cannot actually attend over.

### Adding a guard model

1. If the model reports verdicts in Qwen3Guard's `Safety:` / `Categories:` format, reuse the
   existing template: add one line to `guard_code_templates` in
   [deploy-guardrails.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/deploy-guardrails.yml).
2. Otherwise add `core/lib/guardrails/<family>.py.j2` — copy the existing one and change the
   prompt/parsing — and map the model id to it. Keep the sandbox rules (see the template's
   docstring): no `import`, no `class`, no leading-underscore names, no f-strings; use the
   injected primitives (`allow`, `block`, `trim`, `lower`, `contains`, `json_parse`,
   `json_stringify`, `regex_find_all`, `http_post`).

   > **Note:** not available in this release.
3. Add a row to the table above, set `guardrail_model`, re-run the install. The endpoint
   and model id are substituted for you.

The playbook compiles the rendered code in the gateway's sandbox
(`POST /guardrails/test_custom_code`) and fails **before** registering if it is rejected, so
a sandbox mistake cannot take the guardrail down.

---

## Deployment

### Prerequisites

- GenAI Gateway deployed (holds the guardrail registration)
- Free CPU/memory for the guard vLLM (see `cpu`/`memory` on the `qwen3guard` entry in `env/<name>/models.yaml`)

### Deploy with Full Stack

```bash
cd /path/to/enterprise-ai-solutions

grep "guardrails_enabled" env/local/config.agent-toolkit.yaml   # verify config
./es_auto_installer.sh install agent-toolkit
```

Guardrails deploy after the GenAI Gateway in the deployment sequence
([fresh-install.sh](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/lib/cluster/deployment/fresh-install.sh),
[guardrails-controller.sh](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/lib/components/guardrails-controller.sh)).

### Redeploy Guardrails Only

The playbooks run from `core/kubespray`, not `core`: `deploy-guardrails.yml` loads
`config/vault.yml` relative to the working directory, and `core/lib/system/setup-env.sh`
copies `core/playbooks/` (including `templates/`) there on every stack deploy. Refresh that
copy first if you have edited the playbooks:

> **Note:** not available in this release.

```bash
cd /path/to/enterprise-ai-solutions

./model-manager deploy qwen3guard --wait              # redeploy the guard model
./es_auto_installer.sh install agent-toolkit          # re-render and re-register the guardrail
```

`guardrails_repo_dir` is where the guardrail code template is read from — the repo, not the
copy — so an edit to `core/lib/guardrails/*.j2` takes effect on the next run.

> **Note:** not available in this release.

Idempotent: re-running renders the code again and updates the existing registration in
place.

---

## Verification

### Check Deployment Status

```bash
kubectl get llminferenceservice qwen3guard -n llm-inference
kubectl get pods -n llm-inference | grep qwen3guard

# Expected — the guard model:
# NAME         URL                                             READY
# qwen3guard   http://<ip>/llm-inference/qwen3guard            True
```

### Verify Registration

```bash
MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm -o jsonpath='{.data.master_key}' | base64 -d)
kubectl port-forward -n litellm svc/litellm 4000:4000 &

curl -s http://localhost:4000/v2/guardrails/list -H "Authorization: Bearer $MASTER_KEY" \
  | jq '.guardrails[] | select(.guardrail_name=="content_safety")
        | {guardrail: .litellm_params.guardrail, mode: .litellm_params.mode,
           url:   (.litellm_params.custom_code | capture("GUARD_URL = \"(?<u>[^\"]+)").u),
           model: (.litellm_params.custom_code | capture("GUARD_MODEL = \"(?<m>[^\"]+)").m)}'

# Expected — exactly one entry, with the substituted endpoint and model:
# {
#   "guardrail": "custom_code",
#   "mode": "pre_call",
#   "url": "http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/qwen3guard/v1/chat/completions",
#   "model": "qwen3guard"
# }
```

### Compile-check the registered code

`POST /guardrails/test_custom_code` compiles code in the sandbox without registering it —
useful while editing a template:

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

**This is a compile check, not a verdict check.** The endpoint calls `apply_guardrail()`
without awaiting it, so an async guardrail — which this one must be, since `http_post` is
async — always comes back as `allow` with that coroutine warning, whatever the code would
decide. `success: false` with `error_type: "compilation"` is the signal to act on. The
guardrail's own hook does await the coroutine, so this affects only the test endpoint.

For real verdicts, use the end-to-end requests below (or call the guard model directly, as in
[Everything Is Blocked](#everything-is-blocked)). The same pre-flight call runs inside the
deploy, so a sandbox violation fails the install before anything is registered.

### Test Safety Filtering End to End

```bash
# Benign request — normal answer, finish_reason "stop"
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"model":"qwen2-5-coder-14b",
       "messages":[{"role":"user","content":"Hello, how are you?"}],"max_tokens":50}' \
  | jq '{finish_reason: .choices[0].finish_reason, content: .choices[0].message.content}'

# Unsafe request — HTTP 500, block reason in error.message
curl -s http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer $MASTER_KEY" \
  -d '{"model":"qwen2-5-coder-14b",
       "messages":[{"role":"user","content":"How do I hack into a system?"}],"max_tokens":50}' \
  | jq '.error.message'
```

### Test Fail-Closed

```bash
./model-manager undeploy qwen3guard --wait
# any chat request -> "...the guard model backend is unreachable..."
./model-manager deploy qwen3guard --wait
```

---

## Troubleshooting

### Guard vLLM Stuck in Pending

**Symptom:** `qwen3guard-kserve-xxx   0/1   Pending`

```bash
kubectl describe pod -n llm-inference <pod-name> | grep Events -A 10   # look for "Insufficient cpu"
```

**Cause:** not enough free CPU for the guard's request.

> **`Insufficient memory` instead of `Insufficient cpu`?** The memory floor in
> [utils/get_optimal_memory.yaml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/roles/utils/tasks/get_optimal_memory.yaml) is 128 GB
> — it is returned even when the node has less than that free, because the formula is shared
> with the served LLMs, where a smaller request cannot hold the model. On a node under ~128 GB
> the guard therefore stays `Pending` rather than starting and OOM-looping. Lower the floor for
> that node, or set `memory` explicitly in `guardrail-values.yaml` and deploy with the balloon
> policy off so the derived value does not override it (minimum ~12Gi against the ~8.6 GiB peak).

> **Note:** not available in this release.

1. Check what is consuming CPU:
   ```bash
   kubectl get pods --all-namespaces \
     -o custom-columns=NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu | grep -v "<none>"
   ```
2. Confirm the strategy is Recreate, not RollingUpdate:
   ```bash
   kubectl get deployment -n llm-inference qwen3guard-kserve -o yaml | grep -A 2 "strategy:"
   ```

   > **Note:** not available in this release.
3. On single-node clusters, check the `headroom_buffer` in the `workload_cpus` calculation in
   [deploy-inference-models.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/deploy-inference-models.yml) — it
   pre-reserves CPUs for components deployed *after* the LLM, including the guard vLLM.

   > **Note:** not available in this release.

### Registration Failed

The playbook prints the reason. Two distinct failures:

- **`guardrail code rejected by the gateway sandbox`** — the rendered code does not compile
  under RestrictedPython (`error_type: "compilation"`). Usual causes: an `import`, a `class`,
  a name starting with `_`, or an f-string. The check runs before the write, so nothing is
  registered or changed. Reproduce and iterate with `POST /guardrails/test_custom_code`
  (see above).
- **`guardrail registered/updated failed (HTTP …)`** — the gateway rejected the write. Check
  that the master key is an admin key and that the gateway's DB is reachable
  (`kubectl logs -n litellm deploy/litellm -c litellm`).

After fixing, re-run the install ([Redeploy Guardrails Only](#redeploy-guardrails-only)) —
the helm upgrade is a no-op on an unchanged release, so the run effectively just re-registers.

### Everything Is Blocked

```
Blocked by the content-safety guardrail: the guard model backend is unreachable (...)
```

Fail-closed working as designed — the guard vLLM is down or not yet ready:

```bash
kubectl get pods -n llm-inference | grep qwen3guard
kubectl logs -n llm-inference deploy/qwen3guard-kserve -c main --tail=50
```

A first deploy takes a few minutes to download the model. If the message names the **context
window** instead, see [Context window](#context-window). If it says the **verdict could not
be parsed**, `guardrail_model` and the code template disagree about the verdict format —
check the guard's raw reply:

```bash
kubectl exec -n llm-inference deploy/qwen3guard-kserve -c main -- python3 -c \
  "import json,urllib.request as u; r=u.Request('http://localhost:8000/v1/chat/completions', json.dumps({'model':'qwen3guard','messages':[{'role':'user','content':'hello'}],'max_tokens':32}).encode(), {'content-type':'application/json'}); print(json.load(u.urlopen(r))['choices'][0]['message']['content'])"
# Expected: "Safety: Safe\nCategories: None"
```

### Guard Still Not Ready After the Playbook Finishes

> **Note:** not available in this release.

Expected: the playbook registers the guardrail and returns without waiting for the guard pod,
because nothing in the registration needs a running guard. Until the pod is `Running`, every
screened request is blocked (fail-closed), so check it before treating the guardrail as live:

```bash
kubectl -n llm-inference rollout status deploy/qwen3guard-kserve --timeout=600s
```

Taking more than ~10 minutes is usually the model download, or RollingUpdate deadlocking on
CPU — confirm `deploymentStrategy.type: Recreate` in `vllm/guardrail-values.yaml`.

---

## How It Works

### The `custom_code` guardrail

LiteLLM compiles the registered code with RestrictedPython and calls
`apply_guardrail(inputs, request_data, input_type)` on the `pre_call` hook. The sandbox
forbids `import`, `class`, `exec`/`eval`, file I/O and leading-underscore names, and injects
the primitives the code uses instead (`allow`, `block`, `regex_find_all`, `http_post`, …).

[qwen3guard_gen.py.j2](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/lib/guardrails/qwen3guard_gen.py.j2) does:

1. take the **last user message** (falling back to the last non-empty `texts` entry for call
   types without structured messages) — one guard call per request; the sandbox has no
   `asyncio`, so extra messages could not be screened concurrently and would each add a full
   guard round-trip to a hook that blocks the request
2. `POST` it to the guard vLLM as a single-message chat completion (`max_tokens: 32`,
   `temperature: 0`)
3. parse `Safety:` / `Categories:` out of the reply
4. `allow()` on `Safe` (and `Controversial`, unless `guard_block_on_controversial`),
   `block()` on `Unsafe` and on **every** failure to obtain a verdict

`block()` on `pre_call` makes the gateway return HTTP 500 with the reason in
`error.message`.

### Registration

[register-guardrail-genai-gateway.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/register-guardrail-genai-gateway.yml)
pipes [register-guardrail.py.j2](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/templates/register-guardrail.py.j2) into
the gateway pod (`kubectl exec -i … -- python -`), which:

1. compiles the code via `POST /guardrails/test_custom_code` and aborts on rejection
2. looks the guardrail up in `GET /v2/guardrails/list`
3. `PUT /guardrails/{id}` if it exists, else `POST /guardrails`

Running inside the pod lets it read `LITELLM_MASTER_KEY` from the pod's own environment, so
the key is not persisted into any manifest, and the payload travels base64-encoded on stdin
so the sandboxed Python needs no shell escaping.

**Upsert, not create-if-absent** (the earlier behaviour): the guardrail name is stable across
model changes, so a create-only step would leave an outdated registration in place — and
since `pre_call` failures fail closed, that means blocking everything. `PUT` also
re-initializes the in-memory guardrail, so no gateway restart is needed (`PATCH` cannot
change `litellm_params`).

---

## Roadmap

**Additional guard models.** Model-specific logic is isolated to one template per verdict
format under `core/lib/guardrails/`, so a new guard model is a template plus a
`guard_code_templates` entry. Only `Qwen/Qwen3Guard-Gen-0.6B` is validated today;
unmapped ids fail the deploy rather than being assumed compatible.

**Multiple concurrent guardrails** (e.g. content safety *and* PII detection) is not yet
supported. Registering a second `custom_code` guardrail is now cheap, but several
constraints need resolving first:

- **CPU capacity** — each guard *model* needs its own vLLM alongside the main LLM.
  Library-backed checks (e.g. Presidio for PII) need no model server at all.
- **Latency** — every check runs on the blocking `pre_call` path, and the sandbox has no
  `asyncio`, so checks inside one guardrail cannot be issued concurrently; their round-trips
  add up on every request.
- **Per-check failure policy** — fail-closed is right for safety but may be wrong for other
  checks; the policy is currently per-guardrail code.
- **Aggregate false-positive rate** — blocking is a union across checks, so tuning each in
  isolation understates the combined impact on legitimate traffic.

---

## References

- **LiteLLM custom_code guardrail:** https://docs.litellm.ai/docs/proxy/guardrails/custom_code_guardrail
- **LiteLLM Guardrails:** https://docs.litellm.ai/docs/proxy/guardrails
- **vLLM Documentation:** https://docs.vllm.ai/
- **Qwen3Guard Model:** https://huggingface.co/Qwen/Qwen3Guard-Gen-0.6B
- **Deployment Playbooks:**
  - [deploy-guardrails.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/deploy-guardrails.yml)
  - [register-guardrail-genai-gateway.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/playbooks/register-guardrail-genai-gateway.yml)
- **Related Components:**
  - [GenAI Gateway](https://github.com/intel/enterprise-agent-toolkit/tree/release-1.1.0/core/helm-charts/genai-gateway/)
