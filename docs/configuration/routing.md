# Routing

[← Docs index](../README.md)

By default, applications specify a **deployed** model (for example `Qwen/Qwen3-4B-Instruct-2507`). **Routing** introduces a virtual model name instead. The stack classifies the prompt, selects an appropriate deployed model, and returns the completion. Client code does not change: it still calls `/v1/chat/completions`, but `"model"` is the virtual name.

Routing is optional. Requests that already name a real model continue to reach that model directly. You only need this page if you want one application-facing name that fans out to several backends.

| Requirement | Mechanism | Guide |
|---|---|---|
| Phrase matching configured in the LiteLLM UI | Auto Router | [Quickstart](../getting-started/quickstart.md#optional-route-simple-vs-complex-prompts) |
| Intent or category (code, chat, reasoning) | Semantic routing | [Semantic routing](#semantic-routing) |
| Complexity with cost and latency optimization over time | Hybrid router | [Hybrid router](hybrid-router.md) |

Use **one** mechanism per virtual model name. These are alternative implementations, not layers you stack on top of each other.

---

## Semantic routing

> [!WARNING]
> **Needs a team check.** Semantic routing (`vllm_sr_enabled`) was backlog in the first Stack Manager release. Confirm it actually deploys with your `stack-manager` before you follow the rest of this section. LiteLLM Auto Router in the [quickstart](../getting-started/quickstart.md#optional-route-simple-vs-complex-prompts) does not depend on this flag.

Semantic routing sits in front of the models you have already deployed. It classifies each prompt by intent, difficulty, and category, then dispatches the request to a matching model: a smaller chat model for simple queries, a coding model for code, or a larger model for demanding reasoning. Applications continue to call a **single** model name.

- Coding prompts are sent to a coding model; general chat is sent to a general-purpose model.
- Lower-complexity traffic remains on a smaller, faster model; heavier prompts use a larger model.
- For families such as Qwen3 and DeepSeek, reasoning modes can be enabled when the prompt requires them.

The classifier and embedding models used by the router are cached on a persistent volume so a pod restart does not trigger a re-download.

### Enable semantic routing

Semantic routing is disabled by default. Enabling it does not alter models that applications already call by name.

1. In `env/<env>/config.inference.yaml` (the default environment is `local`):

   ```yaml
   vllm_sr_enabled: true
   ```

2. Deploy (initialize inference only if you have not already):

   ```bash
   ./stack-manager init inference      # only if not already initialized
   ./stack-manager install inference   # or: install agent-toolkit
   ```

The installer is idempotent. Re-run it at any time; components that are already running are skipped.

### Invoke the router

The virtual model name defaults to **`semantic-router`**. Override it with `vllm_sr_litellm_model_name` in `config.inference.yaml`:

```yaml
vllm_sr_litellm_model_name: vllm-sr-auto
```

Use that name in the calls below instead of `semantic-router`.

**LiteLLM mode** (`auth_provider: litellm`): replace `api.example.com` with your `base_domain_name`:

```bash
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-virtual-key>" \
  -d '{
    "model": "semantic-router",
    "messages": [{"role": "user", "content": "Write a Python function to merge two sorted lists"}]
  }'
```

Guardrails and Langfuse apply the same as any other LiteLLM call.

**Envoy mode** (`auth_provider: keycloak`):

```bash
curl -k https://api.example.com/llm-inference/semantic-router/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-jwt>" \
  -d '{
    "model": "semantic-router",
    "messages": [{"role": "user", "content": "Write a Python function to merge two sorted lists"}]
  }'
```

### Per-request selection

- `"model": "semantic-router"`: the router selects a deployed model.
- `"model": "qwen3-4b"` (any catalog name): that model is used; the router is bypassed.

Both forms are valid whether routing is enabled or not. They can be mixed in the same application.

### From Python or an orchestration framework

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.example.com/v1",
    api_key="<your-virtual-key>",
)

resp = client.chat.completions.create(
    model="semantic-router",
    messages=[{"role": "user", "content": "Refactor this function to run asynchronously"}],
)
print(resp.choices[0].message.content)
```

In Envoy mode, set `base_url` to `https://api.example.com/llm-inference/semantic-router/v1` and pass the JWT as `api_key`.

LangGraph, CrewAI, and other OpenAI-compatible clients: set the model to `semantic-router` and point the base URL at the gateway.

### Models eligible for routing

Deployed models are defined in `env/<env>/models.yaml` (`autodeploy: true`). Two keys in `config.inference.yaml` control routing:

- **`vllm_sr_route_models`**: models the router may select.
- **`vllm_sr_config_override`**: maps a prompt category to a model.

Example: send coding prompts to a coder model and all other prompts to a small chat model:

```yaml
# env/<env>/config.inference.yaml

vllm_sr_enabled: true
vllm_sr_litellm_model_name: semantic-router

vllm_sr_route_models:
  - qwen3-4b
  - qwen2-5-coder-14b
  - qwen3-coder-30b

vllm_sr_config_override:
  decisions:
    - name: coding
      description: Send code-related prompts to a coder model
      modelRefs:
        - model: qwen2-5-coder-14b
    - name: default
      description: Everything else
      modelRefs:
        - model: qwen3-4b
```

Every model in that list must already be deployed. Add another `decisions` entry for an additional category (for example mathematics or long-form reasoning). Then apply the change:

```bash
./stack-manager install inference
```

### Verify routing

Send a coding prompt and a general prompt. They should be served by different models.

```bash
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-virtual-key>" \
  -d '{"model": "semantic-router",
       "messages": [{"role": "user", "content": "Write a Python function to reverse a linked list"}]}'

curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-virtual-key>" \
  -d '{"model": "semantic-router",
       "messages": [{"role": "user", "content": "What time zone is Tokyo in?"}]}'
```

In LiteLLM mode, open Langfuse and inspect the `model` field on each trace.

---

## Next steps

- Phrase matching in the LiteLLM UI: [Quickstart: Auto Router](../getting-started/quickstart.md#optional-route-simple-vs-complex-prompts)
- Complexity- and cost-aware selection: [Hybrid router](hybrid-router.md)
- Model serving flags: [Configuration](configuration.md)
- Traces after a routed call: [backend connection reference](../reference/backend-connections.md) (Langfuse)
- Failures: [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md)

## Related pages

- [Meet the Agent Toolkit](../overview/meet.md)
- [Glossary](../reference/glossary.md#routing)
- [Guardrails](guardrails.md)
