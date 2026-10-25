# Quick Start — Intel® AI for Enterprise Agent Toolkit
This guide provides step-by-step instructions on how to deploy the Intel® AI for Enterprise Agent Toolkit on a single node.

## Table of Contents

- [Step 1 — Base Stack](#step-1--base-stack)
- [Verify the Base Stack](#verify-the-base-stack)
- [Step 1b — Semantic Router](#step-1b--semantic-router-intelligent-query-routing)
- [Step 2 — Redis (Shared Memory Backend)](#step-2--redis-shared-memory-backend)
- [Step 2b — PostgreSQL + pgvector (Vector Store)](#step-2b--postgresql--pgvector-vector-store--long-term-memory)
- [Step 2c — Agent Sandbox (Sandboxed Code Execution)](#step-2c--agent-sandbox-sandboxed-code-execution)
- [Step 2d — OpenShell (Policy-Enforced Sandboxes)](#step-2d--openshell-policy-enforced-sandboxes)

---

## Step 1 — Base Stack

```bash
git clone https://github.com/intel/enterprise-ai-solutions.git
cd enterprise-ai-solutions
./es_auto_installer.sh configure
./es_auto_installer.sh init agent-toolkit          # creates env/local/ (env name defaults to "local")
```

### 2. Edit `env/local/global_config.yaml` and `env/local/config.agent-toolkit.yaml`

Open `env/local/global_config.yaml` and `env/local/config.agent-toolkit.yaml` and fill in your values:

```yaml
# env/local/global_config.yaml
# Your base domain — this becomes the base URL for all services (e.g. litellm.<base_domain_name>)
base_domain_name: "example.com"

# TLS certificate — self-signed by default

# Kubernetes — provisioned by the installer by default; for a BYO cluster set:
# existing_kubernetes: /path/to/kubeconfig

# Enable/disable stack components
auth_provider: "litellm"      # set by init agent-toolkit
observability_enabled: true

# Proxy settings (optional, depending on network)
http_proxy: ""
https_proxy: ""
no_proxy: ""
```

```yaml
# env/local/config.agent-toolkit.yaml
# Model(s) to deploy — select the model(s) from the model list (ex: qwen2-5-coder-14b), separated by commas
llm_services_autodeploy_models: ["qwen2-5-coder-14b"]

# Enable/disable stack components
# deploy_agenticai_plugin (Flowise agentic AI plugin): not available in this release
redis_stack_enabled: true     # standalone Redis Stack in its own namespace
pgvector_enabled: true        # optional: PostgreSQL 16 + pgvector — shared vector store and long-term memory backend
kuberay_enabled: false        # optional: KubeRay operator — enables Ray distributed computing inside the cluster
agent_sandbox_enabled: true   # optional: Agent Sandbox controller — isolated pod environments for safe code execution
openshell_enabled: false      # optional: NVIDIA OpenShell policy-enforced sandboxes (requires agent_sandbox_enabled: true)
```

>*Note:* For proxy settings, see [running-behind-proxy.md](./running-behind-proxy.md).

### 3. Choose your model

Set `llm_services_autodeploy_models` in `config.agent-toolkit.yaml` to one value from the table below:

**CPU models** 

| # | Value to set in `llm_services_autodeploy_models` | Model |
|---|---|---|
| `21` | `qwen3-coder-30b` | Qwen/Qwen3-Coder-30B-A3B-Instruct |
| `22` | `qwen2-5-coder-14b` | Qwen/Qwen2.5-Coder-14B-Instruct *(default — used by the Coding Agent)* |
| `23` | `bge-base-en` | BAAI/bge-base-en-v1.5 *(text embedding)* |
| `24` | `bge-reranker` | BAAI/bge-reranker-base *(reranking)* |
| `25` | `qwen3-30b-a3b` | Qwen/Qwen3-30B-A3B-Instruct-2507 |
| `26` | `gemma-4-26b` | google/gemma-4-26B-A4B-it |
| `27` | `llama-3-1-8b` | meta-llama/Llama-3.1-8B-Instruct |
| `28` | `llama-3-1-8b-specdec` | meta-llama/Llama-3.1-8B-Instruct *(with speculative decoding)* |
| `29` | `qwen3-coder-30b-specdec` | Qwen/Qwen3-Coder-30B-A3B-Instruct *(with speculative decoding)* |
| `30` | `qwen3-6-35b-a3b` | Qwen/Qwen3.6-35B-A3B |

> **Note:** `meta-llama/Llama-3.1-8B-Instruct` does not support parallel tool calling. Only sequential tool calls are supported with this model.

> **Note:** For how per-model CPU/memory sizing and vLLM flags are configured under the
> hood, or to add a new model, see [Xeon (CPU) vLLM Model Configuration](xeon-model-configuration.md).

**Speculative Decoding:**

Models that support speculative decoding are available with a `-specdec` suffix (e.g. `qwen3-coder-30b-specdec`, `qwen2-5-coder-14b-specdec`, `llama-3-1-8b-specdec`). This technique uses a smaller draft model to generate candidate tokens quickly, which are then verified by the larger target model in parallel — reducing time-to-first-token and overall generation latency while preserving output quality.

These models are registered in LiteLLM with a `-specdec` suffix to distinguish them from their non-speculative counterparts (e.g. `qwen3-coder-30b-specdec`). The draft model is automatically configured during deployment.

To deploy a speculative decoding variant, set the `-specdec` model in `config.agent-toolkit.yaml`:

```yaml
llm_services_autodeploy_models: ["qwen3-coder-30b-specdec"]
```

Multiple models can be deployed together using a comma-separated list: `llm_services_autodeploy_models: ["qwen3-coder-30b", "bge-base-en"]`

### 4. Run the deployment

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx   # HuggingFace token (required to pull gated models)
./es_auto_installer.sh install agent-toolkit
```

**Estimated time:** 20–40 minutes on a fresh node.

All output is also written to `deploy.log` in the repo root.

> **Note:** not available in this release.

---

## Verify the Base Stack

After Step 1 completes, verify all pods are healthy before proceeding to Step 2:

```bash
# All pods should be Running
# (the vLLM pod may take an additional 10-15 min to pull the model weights)
kubectl get pods -A

# Retrieve the LiteLLM master key
export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm -o jsonpath='{.data.master_key}' | base64 -d)

# (Optional) If behind a corporate proxy, update no_proxy to prevent the request from being intercepted by the proxy (replace <base_domain_name> with your base_domain_name)
export no_proxy="${no_proxy},litellm.<base_domain_name>,langfuse.<base_domain_name>"

# Confirm the model API is responding (replace <base_domain_name> with your base_domain_name;
# TLS is self-signed by default, so use curl -k; add the gateway IP for litellm.<base_domain_name> to /etc/hosts):
# First, list registered models to confirm the model name:
curl -k https://litellm.<base_domain_name>/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

# Then test chat completions (replace <base_domain_name> with your base_domain_name, then use the model name returned by /v1/models above):
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "qwen2-5-coder-14b",
       "messages": [{"role":"user","content":"Write a Python hello world"}],
       "max_tokens": 100}'
```

> The `LITELLM_MASTER_KEY` is stored in the `litellm-master-key` Secret (key `master_key`) in the `litellm` namespace.

---

## Step 1b — Semantic Router (Intelligent Query Routing)

Semantic routing automatically directs queries to the most appropriate model based on content analysis using embeddings. This allows you to route simple queries to faster/cheaper CPU models while directing complex tasks to larger CPU models.

**Why Use Semantic Routing?**

- **Cost optimization:** Route simple queries to efficient models, complex ones to powerful models
- **Latency reduction:** Fast models handle straightforward requests quickly
- **Intelligent dispatch:** Coding tasks → coding-specialized models, reasoning → larger models
- **Transparent routing:** Applications use a single model name (e.g., `hybrid-router`), routing happens server-side

> **📚 For more information:** See the official [LiteLLM Auto Routing documentation](https://docs.litellm.ai/docs/proxy/auto_routing#litellm-proxy-server)

### Prerequisites

- Step 1 complete and base stack verified
- At least one model deployed (you'll add an embedding model for routing and a second model to route to)

### 1. Deploy an Embedding Model for Semantic Matching and a Second Model

Semantic routing requires an embedding model to generate vector representations of user queries and match them against predefined utterances. A Text Embedding Inference (TEI) service with **BAAI/bge-base-en-v1.5** will be deployed using the deploy script.

A second larger model i.e. **Qwen/Qwen3-Coder-30B-A3B-Instruct** with better capabilities will also be deployed alongside your existing one.

**Update `env/local/config.agent-toolkit.yaml` to include the embedding model and second model:**

```yaml
llm_services_autodeploy_models: ["qwen2-5-coder-14b", "bge-base-en", "qwen3-coder-30b"]
```

**Deploy the model:**

*Important:* For single-node deployments, the NRI balloon policy will use remaining CPUs to deploy models. Because the first model has already been deployed, there will not be enough CPUs to deploy additional models. To address this, the variable `nri_total_reserved_cpus` inside [core/inventory/metadata/vars/inference_llm_models.yml](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/inventory/metadata/vars/inference_llm_models.yml) needs to be adjusted.

> **Note:** not available in this release.

The following formula can be used to calculate the value of `nri_total_reserved_cpus`. `total_cpus` depends on your system and `desired_vllm_cpus` should be large enough based on the model size. For a sizing guide, refer to the Intel AI Performance Advisor for [cloud instances](https://xeonprocessoradvisor.intel.com/csp-ai-performance-advisor) and [on-prem servers](https://xeonprocessoradvisor.intel.com/on-prem-ai-performance-advisor).

```bash
nri_total_reserved_cpus = total_cpus - desired_vllm_cpus_per_model
```

After updating `inference_llm_models.yml`, it is **highly recommended** to uninstall the existing model first before proceeeding with re-running the deploy script. This will re-install all 3 models using the new NRI balloon policy to ensure there are enough CPU cores.

```bash
kubectl get llminferenceservices,inferenceservices -n llm-inference   # see list of vllm deployments
./model-manager undeploy <first_model_name>   # uninstall the existing vllm deployment
./es_auto_installer.sh install agent-toolkit
```

Restart the GenAI Gateway's Deployment:
```bash
kubectl rollout restart deployment litellm -n litellm
```

Follow the steps to [re-verify the base stack](#verify-the-base-stack) to ensure models can be accessed.

### 2. Access the LiteLLM UI

The LiteLLM admin UI is not published at the edge. Port-forward the LiteLLM Service:

```bash
kubectl port-forward -n litellm svc/litellm 4000:4000
```

Then navigate to the LiteLLM UI in your browser:

```
http://localhost:4000/ui
```

Login credentials:
- Username: default which is `admin`
- Password: the value of `LITELLM_MASTER_KEY`

### 3. Configure Semantic Router via UI

**Step 3a - Verify the Embedding Model:**

The embedding model is automatically registered in LiteLLM when deployed via `es_auto_installer.sh`. Verify it's available:

1. Navigate to: **Models+Endpoints** → **All Models** tab
2. Look for `bge-base-en` in the models list
3. Note the model name - you'll use it in the next step (typically `bge-base-en`)

**Step 3b - Configure the Auto Router:**

> **Note:** not available in this release.

Navigate to: **Models+Endpoints** → **Add Model** → **Auto Router** Tab.
For **Router Type**, select `Semantic Router`.

**Configure the following required fields:**

| Field | Value | Description |
|-------|-------|-------------|
| **Auto Router Name** | `hybrid-router` | The model name developers will use in API requests (you can choose any name) |
| **Default Model** | `qwen2-5-coder-14b` | Fallback model when no route matches (your smaller/faster model) |
| **Embedding Model** | `bge-base-en` | The embedding model deployed in Step 2 (auto-registered) |

**Configure Routes:**

Click **Add Route** to create routing rules. Configure at least two routes:

**Route 1 - Simple Queries (Smaller/Faster Model):**
- **Target Model:** `qwen2-5-coder-14b`
- **Description:** Simple queries and basic coding tasks
- **Score Threshold:** `0.5`
- **Utterances:**
  ```
  what is [topic]
  define [term]
  explain [concept] simply
  hello
  write a simple [language] function
  ```

**Route 2 - Complex Queries (More Powerful Model):**
- **Target Model:** `qwen3-coder-30b` (larger CPU model)
- **Description:** Complex coding tasks and system design
- **Score Threshold:** `0.5`
- **Utterances:**
  ```
  design a [system] architecture
  optimize this [language] code for performance
  debug this complex [issue]
  refactor this codebase to use [pattern]
  implement a distributed [system]
  create a production-ready [application]
  how to code a program in [language]
  can you explain this [language] code
  can you convert this [language] code to [target_language]
  ```

Click **Add Auto Router** to activate the semantic router. To view it, refresh the page and go back to the **Models+Endpoints** → **All Models** tab.

### 4. Verify Semantic Routing

Test that queries are being routed correctly based on content:

**Simple query (should route to smaller model - fast response):**

```bash
export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm -o jsonpath='{.data.master_key}' | base64 -d)

curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "hybrid-router",
    "messages": [{"role":"user","content":"What is a Python list?"}],
    "max_tokens": 100
  }'
```

**Complex query (should route to more powerful model):**

```bash
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "hybrid-router",
    "messages": [{"role":"user","content":"How to code a program in Python that implements a distributed task queue with Redis backend"}],
    "max_tokens": 200
  }'
```

**Check routing decisions in Langfuse:**

Navigate to the Langfuse dashboard to see which model handled each request:

```
https://langfuse.<base_domain_name>
```

Login credentials: `kubectl get secret langfuse-secrets -n langfuse -o jsonpath='{.data.admin_email}' | base64 -d` and `... -o jsonpath='{.data.admin_password}' | base64 -d`; the project is `inference`.

Go inside the `default` project. Under **Tracing**, select the most recent `litellm_request`, scroll down to **Metadata** → **attributes**. Look at the `llm.model_name` field to confirm routing decisions.

### How It Works

1. When a request comes in with `model="hybrid-router"` (or your chosen router name), LiteLLM generates embeddings for the input message
2. It compares these embeddings against the utterances defined in your routes
3. If a route's similarity score exceeds the threshold, the request is routed to that model
4. If no route matches, the request goes to the default model

### Routing Configuration Tips

- **Adjust score_threshold:** Lower values (0.3-0.4) route more queries to that model, higher values (0.6-0.7) require closer matches
- **Add more utterances:** Include domain-specific examples that represent your actual workload patterns
- **Use placeholders:** `[variable]` in utterances creates flexible matching patterns (e.g., `[language]`, `[system]`)
- **Monitor in Langfuse:** Track which queries route where and adjust thresholds based on actual usage
- **Test thoroughly:** Send diverse queries to understand routing behavior before production use

---

## Step 2 — Redis (Shared Memory Backend)

Redis is the **common memory backend** for all agentic workloads in this stack — deploy it before any use-case agent (MCP agents, etc.).

The `core/helm-charts/redis` chart deploys **Redis Stack** (includes RediSearch) into its own `redis` namespace as a single persistent instance shared across all agents.

**Automated deployment (recommended):**

By default, Redis should already be deployed. You can check by running `kubectl get pods -n redis`. If not, follow the instructions below to deploy it.

Set `redis_stack_enabled: true` in `env/local/config.agent-toolkit.yaml`:
```yaml
redis_stack_enabled: true
```

Then re-run `es_auto_installer.sh`:
```bash
./es_auto_installer.sh install agent-toolkit
```

The deployment script generates the password into the `redis-stack-server-credentials` Kubernetes Secret and passes it to the chart, so no manual credential setup is needed.

**Manual deployment (alternative / standalone):**

> **Note:** not available in this release.

A password is mandatory — the chart refuses to render without one.

```bash
# 1. Resolve Helm chart dependencies (fetches the redis-stack-server subchart)
helm dependency build core/helm-charts/redis

# 2. Deploy into the `redis` namespace with a password
_redis_pw=$(grep '^redis_stack_password:' core/inventory/metadata/vault.yml | awk -F'"' '{print $2}')
helm upgrade --install redis core/helm-charts/redis \
  --namespace redis \
  --create-namespace \
  --set-string "redis-stack-server.redis_stack_server.auth.password=${_redis_pw}" \
  --wait --timeout 5m
unset _redis_pw
```

**Verify it is running:**

```bash
kubectl get pods -n redis
# NAME                       READY   STATUS    RESTARTS   AGE
# redis-stack-server-0       1/1     Running   0          60s

# Quick connectivity test (a password is required)
kubectl exec -n redis redis-stack-server-0 -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
# PONG
```

**Redis URL (in-cluster) — use this in all agents:**

The full URL, including the password, is stored in a Kubernetes Secret. Read it from there rather than hardcoding credentials:

```bash
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_URL}' | base64 -d
# redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379
```

> This URL is the single source of truth for all agent workloads connecting to Redis within the cluster.
> Note the `default:` username — Redis 6+ rejects the `redis://:<password>@...` form with `WRONGPASS`.

### Redis security notes

- **Authentication is mandatory.** The chart fails to render if no password is supplied. Redis with `nopass` allows any client that can reach the port to read and modify all agent session data and to execute arbitrary Lua and JavaScript (via RedisGears) on the server.
- **The Service is `ClusterIP`**, reachable only from inside the cluster. Do not change it to `NodePort` or `LoadBalancer` — that publishes Redis on every node IP in the 30000-32767 range. If you need external access, use `kubectl port-forward` instead.
- **A NetworkPolicy is applied by default.** It admits any in-cluster pod unless you list namespaces. To restrict Redis to only the workloads that need it:

  ```bash
  --set "redis-stack-server.redis_stack_server.networkPolicy.allowedNamespaces={litellm,agent-sandbox-system}"
  ```

  NetworkPolicy requires a CNI that enforces it (Calico, the default here, does).
- **Rotate the password** by updating `redis_stack_password` in `vault.yml` and re-running the deployment; restart dependent workloads so they pick up the new Secret.

  > **Note:** not available in this release.

---

## Step 2b — PostgreSQL + pgvector (Vector Store & Long-Term Memory)

PostgreSQL 16 with the **pgvector** extension gives every agentic workload a persistent, queryable vector store for long-term memory, RAG pipelines, semantic search, and structured state storage — all within the cluster.

**When to enable:**
- Your agent needs long-term memory that survives pod/session restarts
- You are building RAG pipelines that store and retrieve embeddings
- Use cases require structured relational + vector data in the same store
- You want a production-grade alternative to in-memory vector stores

By default, `pgvector` should already be deployed. You can check by running `kubectl get pods -n pgvector`. If not, follow the instructions below to deploy it.

Enable it in `env/local/config.agent-toolkit.yaml`:
```yaml
pgvector_enabled: true
```

Then re-run the deploy script:
```bash
./es_auto_installer.sh install agent-toolkit
```

**What gets deployed:**

| Resource | Detail |
|---|---|
| Namespace | `pgvector` |
| Image | `pgvector/pgvector:pg16` (PostgreSQL 16 + pgvector extension) |
| Service | `pgvector.pgvector.svc.cluster.local:5432` |
| Database | `agentdb` |
| User | `agentuser` |
| Credentials secret | `pgvector-credentials` in the `pgvector` namespace |

**Verify it is running:**

```bash
kubectl get pods -n pgvector
# NAME                    READY   STATUS    RESTARTS   AGE
# pgvector-0              1/1     Running   0          60s

# Confirm pgvector extension is active
kubectl exec -n pgvector pgvector-0 -- \
  psql -U agentuser -d agentdb \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname='vector';"
# extname | extversion
# --------+-----------
# vector  | 0.8.0
```

**Retrieve the connection string from the cluster secret:**

```bash
kubectl get secret pgvector-credentials -n pgvector \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d
# postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb
```

**In-cluster connection string (for use in agent workloads):**

```
postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb
```

---

## Step 2c — Agent Sandbox (Sandboxed Code Execution)

Agent Sandbox provides **isolated, ephemeral Kubernetes pods** for safe code execution.
Every sandbox is a fully self-contained pod — the agent can run arbitrary code, install
packages, and write files without touching the host or other workloads.

By default, Agent Sandbox should already be deployed. You can check by running `kubectl get pods -n agent-sandbox-system`. If not, follow the instructions below to deploy it.

Enable it in `env/local/config.agent-toolkit.yaml`:
```yaml
agent_sandbox_enabled: true
```

Then re-run the deploy script:
```bash
./es_auto_installer.sh install agent-toolkit
```

**What gets deployed** (all in the `agent-sandbox-system` namespace):

| Component | Description |
|---|---|
| `agent-sandbox-controller` | Kubernetes operator that manages Sandbox pod lifecycle |
| CRDs | `sandboxes`, `sandboxtemplates`, `sandboxclaims`, `sandboxwarmpools` |
| `sandbox-router` | HTTP proxy that routes SDK requests to sandbox pods |
| `python-sandbox-template` | Default SandboxTemplate using a locally-built Python runtime |

**Verify:**

```bash
kubectl get pods -n agent-sandbox-system
# NAME                                          READY   STATUS    RESTARTS
# agent-sandbox-controller-xxx                  1/1     Running   0
# sandbox-router-deployment-xxx                 1/1     Running   0

kubectl get sandboxtemplate -n agent-sandbox-system
# NAME                      AGE
# python-sandbox-template   1m
```

> **In-cluster router URL** (used by the in-cluster agent):
> `http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080`

For the full guide — adding custom templates, WarmPools, and SDK usage — see
**[agent-sandbox.md](agent-sandbox.md)**.

---

## Step 2d — OpenShell (Policy-Enforced Sandboxes)

NVIDIA OpenShell runs on top of Agent Sandbox and enforces egress default-deny, L7 rules,
Landlock and credential isolation inside every sandbox. The GenAI Gateway is registered as a
provider: sandboxes see a placeholder key and the supervisor injects a dedicated LiteLLM
virtual key.

```yaml
# env/local/config.agent-toolkit.yaml
agent_sandbox_enabled: true
openshell_enabled: true
```

```yaml
# core/inventory/metadata/vars/inference_openshell.yml — single-admin mode
openshell_allow_unauthenticated_clusterip_only: true
```

> **Note:** not available in this release.

```bash
./es_auto_installer.sh install agent-toolkit
```

**Verify:**

```bash
kubectl get pods -n openshell-system
# NAME          READY   STATUS    RESTARTS
# openshell-0   1/1     Running   0
```

For CLI setup, running a sandbox against the GenAI Gateway, and known limitations, see
**[openshell.md](openshell.md)**.

---
