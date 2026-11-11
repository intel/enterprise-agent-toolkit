# LiteLLM, models, guardrail and routers

The toolkit uses the inference layer (`<root>/ext/enterprise.ai-inference/`) for every LLM call: LiteLLM in namespace `litellm`, models in `llm-inference`. Fixes marked **(changes the cluster)** need the user's OK.

## Read a LiteLLM error correctly

Classify by the JSON body (`error.type`, `error.message`) first. Status codes for key problems differ between LiteLLM versions: an over-budget key is 400 on the release track and 429 on the main track, and a model the key may not use is 401 on release and 403 on main.

| Status | Body or situation | Meaning | Entry |
|---|---|---|---|
| 400, 401, 403 or 429 | `error.type` `budget_exceeded`, `expired_key`, `key_model_access_denied`, `team_model_access_denied` or `auth_error` | A key problem: over budget, expired, model not allowed, or a missing or invalid key | LLM-1 |
| 400 | `Invalid model name passed in model=<x>` | The model is not registered under that name | LLM-2 |
| 500 | starts with `Custom code guardrail execution failed: Blocked by the content-safety guardrail:` | The guardrail decided; read the reason | GRD-1 |
| 500 | anything else | A backend or model error | MOD-* |
| 413 | | Request body too large for the AI gateway | LLM-6 |
| 429 | no LiteLLM error body | Edge rate limit at the gateway: 600 requests a minute per client IP | |
| 503, 504 | | AI gateway or model unavailable, or a 600 s timeout | MOD-* |
| Connection reset | | Mesh policy, not LiteLLM | `network.md` |

## LiteLLM

### LLM-1 A key problem (400, 401, 403 or 429 with a LiteLLM error body)
- **Check:** read `error.type` in the response. With the master key held in a variable, `GET /key/info?key=<virtual-key>` shows `models`, `expires`, `spend` and `max_budget`.
- **Fix:** mint a key with the right models and budget, or raise the budget with `POST /key/update` **(changes the cluster)** (agent-toolkit-components skill, `references/litellm.md`).

### LLM-2 `Invalid model name passed in model=<x>. Call /v1/models to view available models for your key.`
- **Why:** the name differs from the deploy name, the model is still loading or failed, or a doc example names a model you do not run (many examples use `qwen2-5-coder-14b`).
- **Check:** `GET /v1/models` with the same key; `kubectl get llminferenceservices,inferenceservices -n llm-inference`.
- **Fix:** use a name from `/v1/models`, or wait until the model is Ready (MOD-5). Ready but missing: MOD-6.

### LLM-3 Embeddings return HTTP 400, or rerank returns HTTP 500, through LiteLLM
- **Why:** on the main track, model-manager registers every model in LiteLLM as `openai/<name>` with no `mode`, embedding and rerank models included. LiteLLM then sends an embeddings request vLLM rejects, and has no rerank route for that provider. The release track registers them as `hosted_vllm/<name>` with `model_info.mode` and does not have this problem.
- **Check:** models are stored in LiteLLM's database, not in the `litellm-config` ConfigMap. With a port-forward (`kubectl port-forward -n litellm svc/litellm 4000:4000`) and the master key in a variable: `curl -s localhost:4000/model/info -H "Authorization: Bearer $MK" | jq '.data[] | {model_name, model: .litellm_params.model, mode: .model_info.mode}'`.
- **Fix:** report it as an inference-layer bug. As a workaround, re-register the model with `POST /model/new`: `litellm_params.model` = `hosted_vllm/<name>`, the same `api_base`, and `model_info.mode` = `embedding` or `rerank` **(changes the cluster)**.

### LLM-4 A changed LiteLLM setting (hybrid router, tier candidates, sizing, `routing_mode`) has no effect
- **Why:** an existing LiteLLM release is skipped: `LiteLLM already deployed in litellm — skipping install (litellm_reconcile: true upgrades it with the current settings).` The access policies, the HTTPRoute and the guardrail are applied on every run anyway.
- **Fix:** `./es_auto_installer.sh install litellm --only --env <env> -- -e litellm_reconcile=true` **(changes the cluster)**.

### LLM-5 Client times out on chat calls
- **Why:** CPU inference. A busy 14B model has taken 85 s, and 1,500 output tokens about 3 minutes through the gateway.
- **Fix:** client timeout of at least 180 s; lower `max_tokens`; or use a smaller model.

### LLM-6 HTTP 413 on large requests (long histories, many tool schemas)
- **Why (likely, not reproduced):** the AI gateway (Gateway `ai-gateway` in `llm-inference`) uses Envoy's default request buffer of 32 KiB unless a ClientTrafficPolicy raises it.
- **Check:** `kubectl get clienttrafficpolicy -A -o yaml | grep -B8 bufferLimit`. Look only at a policy whose `targetRefs` names the `ai-gateway` Gateway; one for another Gateway (such as `semantic-router`) does not count.
- **Fix:** shorten the request, and report the size that failed. Raising the buffer is an inference-layer change.

### LLM-7 The admin UI does not open
- **Main track:** `https://litellm-ui.<base_domain_name>/ui/`, sign in through Keycloak as a member of `platform-admins` (day-0 user `platform-admin`; first password in Secret `platform-bootstrap-admin`, key `value`, namespace `keycloak`; change it at first sign-in). The browser must also resolve and trust `keycloak.<base_domain_name>`. Password and master-key login are disabled.
- **Release track:** `https://litellm.<base_domain_name>/ui/` with user `admin` and the master key as password. The trailing slash is required; without it the browser is redirected to an `http://` URL that fails.
- **Main track, path mode:** the UI is at `https://<base_domain_name>/litellm/ui/`.
- **Check URLs:** `kubectl get cm litellm-credentials -n litellm -o jsonpath='{.data}'` names the API host (`api_url` or `hostname`) and the UI host (`ui_url`; add `/ui/`). It holds no secrets.

### LLM-8 Traces stop appearing in Langfuse
- **Check:** `kubectl get pods -n langfuse` and look at restarts of the ClickHouse pod: `kubectl describe pod -n langfuse <clickhouse-pod> | grep -A3 'Last State'`.
- **Why:** a ClickHouse pod that is OOMKilled drops traces silently; LiteLLM still answers normally. It has been seen with the default small sizing.
- **Fix:** report it with the restart count. LiteLLM traffic is not affected.

## Guardrail

### GRD-1 HTTP 500 `Custom code guardrail execution failed: Blocked by the content-safety guardrail: <reason>`
The guardrail screens the last user message of **every** request and every key, embeddings included. The reason tells you what happened:

| Reason | Meaning | Action |
|---|---|---|
| `unsafe content (categories: X).` | A real policy block. The guardrail worked. | Rephrase. Not a fault. |
| `controversial content (categories: X).` | Blocked because `guard_block_on_controversial: true` | Set it to `false` if not wanted, and re-run install **(changes the cluster)** |
| `the guard model backend is unreachable (<error>).` | **Infrastructure.** Fail-closed, so every request is blocked. | GRD-2 |
| `the prompt is longer than the guard model's context window (qwen3guard), so it could not be screened.` | The prompt is over about 32k tokens. The guard is the stack's size limit. | Shorten the prompt |
| `the guard model's verdict could not be parsed (qwen3guard).` | The guard model replied in an unexpected format | Check the guard model and template versions |

### GRD-2 Every request is blocked: `the guard model backend is unreachable (...)`
- **Check:** `kubectl get llminferenceservice qwen3guard -n llm-inference -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` (must be `True`).

| In the brackets | Cause | Fix |
|---|---|---|
| `404`, or a connection error right after install | The guard model is not deployed or not Ready yet. It loads first and can take several minutes. | Wait until Ready. If it failed, see MOD-*. |
| `403` behind a corporate proxy | LiteLLM's call to the guard went to the proxy | Re-run the install; it adds the guard address to LiteLLM's `NO_PROXY` **(changes the cluster)** |
| `Blocked URL` | The guard host is missing from LiteLLM's allowed hosts | Re-run the install **(changes the cluster)** |
| `500` | The guard pod is down | `kubectl get pods -n llm-inference \| grep qwen3guard`, then MOD-* |

`./model-manager undeploy all` removes the guard model too, and then every request is blocked. Redeploy it with `./model-manager deploy qwen3guard` **(changes the cluster)**. To run without the guardrail, follow the agent-toolkit-configuration skill (section 4, "Guardrail off"). On the main track, setting `guardrails_enabled: false` alone does not unregister it.

## Routers

### GRD-3 `hybrid-router` always answers with the same model
- **Why:** its tier candidates are static. By default every tier is the first model in `llm_services_autodeploy_models`. Models deployed later do not join it on re-run.
- **Fix:** set `hybrid_router_tier_candidates` (see `<root>/ext/enterprise.ai-inference/roles/litellm/defaults/main.yaml` for the format) in `env/<env>/config.agent-toolkit.yaml`, then install with `-- -e litellm_reconcile=true` **(changes the cluster)**.

### GRD-4 `vllm-sr/auto` does not route to a newly deployed model
- **Why:** the vLLM Semantic Router picks its routable models when it is installed.
- **Fix:** re-run `./es_auto_installer.sh install vllm_sr --only --env <env>` after deploying the model **(changes the cluster)**.

### GRD-5 HTTP 500 for under a second right after a model deploy or a router change
- **Why:** the AI gateway reloads its configuration.
- **Fix:** retry.

### GRD-6 The vLLM Semantic Router install times out behind a slow proxy
- **Why:** its classifier models download at first start.
- **Check:** `kubectl get pods -n vllm-semantic-router-system`
- **Fix:** re-run the install once the pod is up **(changes the cluster)**.

## Models (`llm-inference`)

Start with:
```bash
kubectl get llminferenceservices,inferenceservices -n llm-inference
kubectl describe llminferenceservice <m> -n llm-inference
kubectl get pods -n llm-inference -o wide | grep <m>
kubectl describe pod <pod> -n llm-inference | sed -n '/Events/,$p'
kubectl logs -n llm-inference deploy/<m>-kserve -c main --tail=200     # add --previous after a crash
```
Select the model pod with `deploy/<m>-kserve`. A label selector such as `-l app.kubernetes.io/name=<m>` also matches the router-scheduler pod.

### MOD-1 Pending: `didn't match Pod's node affinity`
- **Why:** the catalog requires AMX CPUs (`require_amx: true`), and no node has the AMX label, or node feature discovery is not running.
- **Check:** `kubectl get nodes -L feature.node.kubernetes.io/cpu-cpuid.AMXBF16`; `kubectl get pods -n node-feature-discovery`.
- **Fix:** on non-AMX hosts set `require_amx: false` under `defaults:` in `env/<env>/models.yaml`, then deploy the models again **(changes the cluster)**. The guard model needs it too.

### MOD-2 Pending: `Insufficient cpu` or `Insufficient memory`
- **Check:** `kubectl describe node | grep -A8 'Allocated resources'`
- **Why:** models are Guaranteed pods. A redeploy briefly needs the requests **twice** (rolling update).
- **Fix:** lower `cpu` and `memory` in `env/<env>/models.yaml`, or undeploy a model **(changes the cluster)**.

### MOD-3 `OOMKilled`, exit code 137, or CrashLoopBackOff without a config error
- **Why:** memory is below the weights plus the KV cache (`VLLM_CPU_KVCACHE_SPACE`, in GiB) plus overhead.
- **Fix:** raise `memory` for the model and deploy again, or deploy with a smaller cache: `./model-manager deploy <m> --env VLLM_CPU_KVCACHE_SPACE=<GiB>` **(changes the cluster)**.

### MOD-4 CrashLoopBackOff with a vLLM configuration error
Read `kubectl logs ... --previous`. The shipped catalog already works around the first three below; you see them only with your own `args:` or an older catalog:
- `--mamba-block-size can only be set with --enable-prefix-caching`
- `CrossAttentionManager does not support caching`
- `mat1 must be a 2D tensor` (vision models)
- `Target model vocab_size=... Draft model vocab_size=...`: `qwen2-5-coder-14b-specdec` never loads (upstream vLLM limitation)

`qwen3-5-2b-ovms` crashes with SIGSEGV (exit 139) on some Xeon hosts. Do not use these two models.

### MOD-5 Running but never Ready; events show `Startup probe failed`
- **Why:** a large model has up to 20 minutes to load. `./model-manager deploy --wait` gives up after 900 s **and still exits 0**, so its exit code proves nothing.
- **Fix:** watch `kubectl get llminferenceservice <m> -n llm-inference`, or deploy with `--wait --wait-timeout 1800` **(changes the cluster)**.

### MOD-6 Ready, but missing from `/v1/models` (`The model is serving but will NOT appear in /v1/models.`)
- **Why:** registration in LiteLLM failed. From the host it runs a short-lived curl pod in `litellm`, which needs to pull its image.
- **Fix:** `./model-manager deploy <m>` again to re-register **(changes the cluster)**.

### MOD-7 Redeploying a changed model fails: `only 0 balloon slot(s) free`
- **Why:** the CPU pre-flight counts the model's own running pod.
- **Fix:** undeploy, then deploy; or run the deploy with `MM_NRI_PREFLIGHT=warn` **(changes the cluster)**.

### MOD-8 model-manager stops with `Multiple environments available but stdin is not a terminal.`
- **Fix:** `ES_ENV=<env> ./model-manager ...`. Its `--env K=V` option sets an environment variable in the model pod; it does not pick the Toolkit Manager environment.
