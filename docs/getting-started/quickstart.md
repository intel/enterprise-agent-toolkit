# Single-node quickstart

[← Docs index](../README.md)

This walkthrough installs the Agent Toolkit on **one host**: a single machine, physical or virtual, running on Intel® hardware. That host is the only Kubernetes node. When it finishes, you have a cluster, a model behind LiteLLM, and an OpenAI-compatible API you can call with `curl` or any OpenAI SDK.

Complete **[Prerequisites](prerequisites.md)** first so SSH and `/etc/hosts` (or DNS) are already in place. No certificate is needed: the installer generates one. If you have more than one host, stop here and use [multi-node deployment](../deployment/multi-node.md) instead: the YAML is the same, but the inventory is not.

Run every command from the [Stack Manager](https://github.com/intel/enterprise-ai-solutions) directory, the one that contains `stack-manager`.

## 1. Prepare the host and seed config

```bash
git clone https://github.com/intel/enterprise-ai-solutions.git
cd enterprise-ai-solutions
./stack-manager configure              # one-time: Python venv, yq, kubectl, helm
./stack-manager init agent-toolkit     # writes env/local/
```

`init` is the step that creates the YAML you will edit. It is not the install.

## 2. Edit the environment files

All live config is under `env/local/`. Change those files, not the copies in git.

### `env/local/global_config.yaml`: name and auth

```yaml
base_domain_name: api.example.com
auth_provider: litellm
```

| Field | What it means |
|---|---|
| `base_domain_name` | Hostname of the gateway. Must match DNS or `/etc/hosts`. |
| `auth_provider: litellm` | Use LiteLLM as the API gateway. The default is `keycloak`. LiteLLM issues the master key used in step 5, and turns on Langfuse traces and the content-safety guardrail. |

Leave these two at their defaults:

| Field | Default | What it means |
|---|---|---|
| `gateway_tls_mode` | `selfsigned` | The installer creates a root CA and a certificate for `base_domain_name` and `*.base_domain_name`. To use your own certificate, see [Production TLS](prerequisites.md#production). |
| `storage_backend` | `local-path` | Disk on this node. Use `nfs` or `ceph` on multi-node. |

Already have a cluster? Set `existing_kubernetes: /path/to/kubeconfig` to skip building Kubernetes.

### `env/local/config.inference.yaml`: serve models

```yaml
llm_services_deploy_models: true
```

Without this flag, the toolkit comes up (Redis, pgvector, sandbox) but no language-model pod starts. You need it for `/v1/chat/completions` to return tokens.

### `env/local/config.agent-toolkit.yaml`: optional Ray

Redis, pgvector, the sandbox, and MCP deploy by default. KubeRay does not: leave it `false` unless you need distributed Ray jobs:

```yaml
kuberay_enabled: false
```

Set `true` only if you need Ray. The full guide is [KubeRay](../reference/kuberay.md).

### Hugging Face token

Needed only for gated models (Llama, Gemma). The default Qwen models are ungated, so you can skip this for the first Hello.

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

## 3. Choose a model

In `env/local/models.yaml`, set `autodeploy: true` on each model you want. Everything else stays in the catalog but does not start.

| Catalog name | Hugging Face id | Typical use |
|---|---|---|
| `qwen3-4b` | `Qwen/Qwen3-4B-Instruct-2507` | Default chat: start here |
| `qwen3-coder-30b` | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | Coding |
| `qwen2-5-coder-14b` | `Qwen/Qwen2.5-Coder-14B-Instruct` | Coding Agent |
| `qwen2-5-coder-7b` | `Qwen/Qwen2.5-Coder-7B-Instruct` | Smaller coder |
| `qwen3-30b-a3b` | `Qwen/Qwen3-30B-A3B-Instruct-2507` | Larger chat |
| `gemma-4-26b` | `google/gemma-4-26B-A4B-it` | Chat (gated) |
| `llama-3-1-8b` | `meta-llama/Llama-3.1-8B-Instruct` | Chat (gated). Sequential tool calls only: no parallel tools |
| `deepseek-r1-qwen-32b` | `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` | Reasoning |
| `bge-base-en` | `BAAI/bge-base-en-v1.5` | Embeddings (needed for semantic routing) |
| `bge-reranker` | `BAAI/bge-reranker-base` | Reranking |
| `qwen3guard` | content-safety guard | Used by [Guardrails](../configuration/guardrails.md) |

Example: serve only the default chat model:

```yaml
  - name: qwen3-4b
    model_id: Qwen/Qwen3-4B-Instruct-2507
    category: llm
    autodeploy: true
```

Some catalog entries include a smaller **draft** model for speculative decoding (the draft guesses tokens; the main model checks them). If an entry has a draft, it is configured for you when that entry is `autodeploy: true`.

## 4. Install

```bash
./stack-manager install agent-toolkit
```

This builds Kubernetes (unless you brought your own cluster with `existing_kubernetes`), then model serving and the toolkit. Re-run the same command to resume a failed run. The first run is about 20–40 minutes; the model pod can take another 10–15 minutes to download weights.

## 5. Confirm it works

```bash
# Nodes and pods. The vLLM pod may sit in ContainerCreating for 10–15 min while weights download.
kubectl get nodes
kubectl get pods -A

export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d)

# Replace api.example.com with your base_domain_name
curl -k https://api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "Qwen/Qwen3-4B-Instruct-2507",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

Use the `id` from `/v1/models` as `"model"` if it is not exactly the Hugging Face name.

The master key lives in secret `litellm-master-key` (namespace `litellm`). Inside the LiteLLM pod it is `PROXY_MASTER_KEY`. The in-cluster service is `litellm.litellm.svc.cluster.local:4000`.

`-k` skips TLS verification, because the certificate is signed by the installer's own CA. To verify it instead, replace `-k` with `--cacert env/local/logs/ai-solutions-ca.crt`, the root CA the installer exports. Production should use a CA-issued certificate.

## What also came up

You did not install these by hand. The install started them. Verify when you need them; URLs are in the [backend reference](../reference/backend-connections.md).

| Component | Check | In-cluster URL |
|---|---|---|
| **Redis** (session memory) | `kubectl get pods -n redis` then `kubectl exec -n redis redis-stack-server-0 -- sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'` | Read `REDIS_URL` from secret `redis-stack-server-credentials` |
| **pgvector** (long-term memory) | `kubectl get pods -n pgvector` | Read `DATABASE_URL` from secret `pgvector-credentials` |
| **Agent sandbox** | `kubectl get pods -n agent-sandbox-system` and `kubectl get sandboxtemplate -n agent-sandbox-system` | `http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080` |

Redis requires a password (the chart will not render without one). The Service is ClusterIP: do not change it to NodePort. Full notes: [backend reference](../reference/backend-connections.md#redis). Sandbox templates and SDK: [Agent sandbox](../reference/agent-sandbox.md).

## Optional: route simple vs complex prompts

The default is one model. If you want LiteLLM to pick a small or large model per prompt, that is **Auto Router** in the LiteLLM UI. It is not required for Hello.

Intent-based routing (and the other routing options) are in [Routing](../configuration/routing.md).

You need at least two chat models plus the embedding model:

```yaml
  - name: qwen3-coder-30b
    autodeploy: true
  - name: deepseek-r1-qwen-32b
    autodeploy: true
  - name: bge-base-en
    autodeploy: true
```

Re-run `./stack-manager install agent-toolkit`. Then open `https://<base_domain_name>` → **Models+Endpoints** → **Add Model** → **Auto Router**.

| Field | Example | Meaning |
|---|---|---|
| Auto Router Name | `smart_router` | The `"model"` your app will send |
| Default Model | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | Used when no route matches |
| Embedding Model | `BAAI/bge-base-en-v1.5` | Must already be in the Models list |

Add at least two routes (utterances are example phrases the router matches):

- **Simple** → smaller/faster model. Utterances such as `what is [topic]`, `hello`, `write a simple [language] function`. Score threshold `0.5`.
- **Complex** → larger model. Utterances such as `design a [system] architecture`, `debug this complex [issue]`. Score threshold `0.5`.

Save, then call `"model": "smart_router"`. Check which model ran in Langfuse at `https://trace-<base_domain_name>`.

Lower thresholds (0.3–0.4) match more loosely; higher (0.6–0.7) need a closer phrase match. Official reference: [LiteLLM Auto Routing](https://docs.litellm.ai/docs/proxy/auto_routing#litellm-proxy-server).

## Next steps

Once Hello works, most people either change which models are served or point an application at the in-cluster backends:

- Build a LangChain agent on the gateway and trace it in Langfuse: [Build your first agent](first-agent.md).
- Edit the YAML under `env/local/` using [Configuration](../configuration/configuration.md).
- Copy Redis, pgvector, and sandbox URLs from the [backend connection reference](../reference/backend-connections.md).
- Turn on content-safety screening in [Guardrails](../configuration/guardrails.md), or Ray jobs in [KubeRay](../reference/kuberay.md).
- Add another server with [multi-node deployment](../deployment/multi-node.md), or [tear the stack down](../deployment/decommission.md) and install again.
- Optional routing choices are in [Routing](../configuration/routing.md). Common questions: [FAQ](../faq-and-troubleshooting/frequently-asked-questions.md). Terms: [glossary](../reference/glossary.md). Failures: [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md).
