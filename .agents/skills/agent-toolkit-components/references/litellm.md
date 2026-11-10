# LiteLLM: the agents' model endpoint

LiteLLM is the OpenAI-compatible gateway in front of every model. It provides virtual keys, budgets, the content-safety guardrail, and a Langfuse trace for every call.

## Endpoints

| From | Base URL |
|---|---|
| A pod in an allowed namespace (`namespace-onboarding.md`) | `http://litellm.litellm.svc.cluster.local:4000/v1` |
| Outside the cluster, `routing_mode: subdomain` (default) | `https://litellm.<base_domain_name>/v1` |
| Outside the cluster, `routing_mode: path` (main track) | `https://<base_domain_name>/litellm/v1` |
| A laptop without DNS | `kubectl port-forward -n litellm svc/litellm 4000:4000`, then `http://localhost:4000/v1` |

The non-secret config map `litellm-credentials` in `litellm` names this install's API host (`api_url` or `hostname`, depending on the version) and admin UI host (`ui_url`; add `/ui/` to open it): `kubectl get cm litellm-credentials -n litellm -o jsonpath='{.data}'`.

Path mode with the toolkit default `litellm_public_paths: []` may publish no API route at all on the main track (untested). If `https://<base_domain_name>/litellm/v1/models` redirects to a sign-in page, set `litellm_public_paths` to the API paths (agent-toolkit-configuration skill).

From outside, trust the gateway CA when TLS is self-signed: `env/<env>/logs/ai-solutions-ca.crt` under the Toolkit Manager root. Pass it to curl with `--cacert`, or to Python with `REQUESTS_CA_BUNDLE` / `SSL_CERT_FILE`.

## Keys

- **Master key**: Secret `litellm-master-key`, key `master_key`, namespace `litellm`. Admin only, for minting and managing keys. Never put it in agent code or config.
- **Virtual key**: one per agent, limited to the models it needs, with a budget and an expiry.

Mint a virtual key **(changes the cluster)**. The master key goes into a variable and is not printed:

```bash
MK=$(kubectl get secret litellm-master-key -n litellm -o jsonpath='{.data.master_key}' | base64 -d)
curl -s --cacert env/<env>/logs/ai-solutions-ca.crt "https://litellm.<base_domain_name>/key/generate" \
  -H "Authorization: Bearer $MK" -H 'Content-Type: application/json' \
  -d '{"key_alias":"<agent>","models":["<model>"],"max_budget":10,"duration":"30d"}' \
  | jq -r .key > <agent>.key
```

Or through a port-forward, with `http://localhost:4000/key/generate`. This works even when `litellm_public_paths` limits what the external host publishes.

Store the key as a Secret in the agent's namespace and mount it as `OPENAI_API_KEY`. Manage keys (updates and deletes change the cluster) with `GET /key/list?return_full_object=true`, `GET /key/info?key=<key>`, `POST /key/update` and `POST /key/delete` (`{"keys": [...]}` or `{"key_aliases": [...]}`). Keys and spend live in the platform PostgreSQL, so they survive a toolkit teardown.

Admin UI: on the main track `https://litellm-ui.<base_domain_name>/ui/` (path mode: `https://<base_domain_name>/litellm/ui/`), with Keycloak sign-in. On the release track `https://litellm.<base_domain_name>/ui/`, user `admin`, password = master key. The trailing slash is required.

## Model names

Always take names from the live list rather than from docs:

```bash
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer $(cat <agent>.key)" | jq -r '.data[].id'
```

Usually present with the toolkit defaults:

| Name | What |
|---|---|
| `qwen2-5-coder-14b` | The default chat model (`llm_services_autodeploy_models`) |
| `hybrid-router` | Picks a model per request by cost and latency (`hybrid_router_enabled`) |
| `vllm-sr/auto` | vLLM Semantic Router, only with `vllm_sr_enabled: true` |
| `qwen3guard` | The guard model. It is used by the guardrail; agents should not call it. |

More models: `./model-manager deploy <name>` from the Toolkit Manager root (catalog: `env/<env>/models.yaml`). Embedding models serve `/v1/embeddings`. None is deployed by default.

## Client configuration

The OpenAI SDK, LangChain `ChatOpenAI`, CrewAI and LangGraph all read:

```bash
OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1
OPENAI_API_KEY=<virtual key>
NO_PROXY=.svc,.cluster.local,localhost,127.0.0.1     # when the pod has proxy variables
```

- Set the client timeout to at least 180 s. CPU inference under load is slow.
- Requests from one client IP are rate-limited at the external gateway (600 a minute). In-cluster calls do not pass that gateway.
- Every request, embeddings included, is screened by the guardrail when it is on. A block is HTTP 500 with a message starting `Custom code guardrail execution failed: Blocked by the content-safety guardrail:`. Handle it as "refused", not as a crash. The reasons are listed in the agent-toolkit-troubleshoot skill (`references/inference.md`, GRD-1).
- Tag traces for Langfuse with LiteLLM metadata, for example `extra_body={"metadata": {"trace_user_id": "<agent>", "session_id": "<id>"}}` in the OpenAI Python SDK.

## Reading errors

Classify a LiteLLM error by `error.type` and `error.message` in the JSON body, not by the status code alone. The codes differ between LiteLLM versions; for example, an over-budget key is 400 on the release track and 429 on the main track.

| `error.type` or message | Meaning |
|---|---|
| `budget_exceeded` | The key's budget is spent |
| `expired_key` | The key has expired |
| `key_model_access_denied` (or `team_model_access_denied`) | The key may not use this model |
| `auth_error`, or no key | Missing or invalid key |
| `Invalid model name passed in model=...` (400) | Not a registered name; check `/v1/models` |
| 500 with the guardrail prefix | Guardrail decision |
| 429 with no LiteLLM error body | The external gateway's rate limit (600 a minute per client IP) |
| Other 500, 503, 504 | Model or gateway problem (agent-toolkit-troubleshoot skill) |
