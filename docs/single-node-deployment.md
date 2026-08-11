# Quick Start — Intel® AI for Enterprise Agent Toolkit
This guide provides step-by-step instructions on how to deploy the Intel AI for Enterprise Agent Toolkit on a single node.

## Table of Contents

- [Step 1 — Base Stack](#step-1--base-stack)
- [Verify the Base Stack](#verify-the-base-stack)
- [Step 1b — Semantic Router](#step-1b--semantic-router-intelligent-query-routing)
- [Step 2 — Redis (Shared Memory Backend)](#step-2--redis-shared-memory-backend)
- [Step 2b — PostgreSQL + pgvector (Vector Store)](#step-2b--postgresql--pgvector-vector-store--long-term-memory)
- [Step 2c — Agent Sandbox (Sandboxed Code Execution)](#step-2c--agent-sandbox-sandboxed-code-execution)

---

## Step 1 — Base Stack

```bash
git clone https://github.com/intel/enterprise-agent-toolkit.git
cd enterprise-agent-toolkit
```

### 2. Edit `core/inventory/agentic-config.cfg`

Open `core/inventory/agentic-config.cfg` and fill in your values:

```ini
# Your cluster FQDN — this becomes the base URL for all services
cluster_url=api.example.com

# TLS certificate — provide a full-chain cert + private key
# For a custom domain: supply your CA-signed or self-signed cert/key files
cert_file=/path/to/your/fullchain.pem
key_file=/path/to/your/private.key
# HuggingFace token (required to pull gated models)
hugging_face_token=hf_xxxxxxxxxxxxxxxxxxxx
# Model to deploy — select the model from the model list (ex :cpu-qwen3-coder-30b)
models=cpu-qwen3-coder-30b
# Enable/disable stack components
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_redis=on          # standalone Redis Stack in its own namespace
deploy_pgvector=off      # optional: PostgreSQL 16 + pgvector — shared vector store and long-term memory backend
deploy_agent_sandbox=on  # optional: Agent Sandbox controller — isolated pod environments for safe code execution
deploy_kuberay=off       # optional
```

### 3. Choose your model

Set the `models` field in `agentic-config.cfg` to one value from the table below:

**CPU models** 

| # | Value to set in `models` | Model |
|---|---|---|
| `21` | `cpu-qwen3-coder-30b` | Qwen/Qwen3-Coder-30B-A3B-Instruct |
| `22` | `cpu-qwen2-5-coder-14b` | Qwen/Qwen2.5-Coder-14B-Instruct *(default — used by the Coding Agent)* |
| `23` | `cpu-bge-base-en` | BAAI/bge-base-en-v1.5 *(text embedding)* |
| `24` | `cpu-bge-reranker-base` | BAAI/bge-reranker-base *(reranking)* |
| `25` | `cpu-qwen3-30b-a3b` | Qwen/Qwen3-30B-A3B-Instruct-2507 |
| `26` | `cpu-gemma4-26b-a4b` | google/gemma-4-26B-A4B-it |
| `27` | `cpu-llama-8b` | meta-llama/Llama-3.1-8B-Instruct |
| `28` | `cpu-llama-8b-specdec` | meta-llama/Llama-3.1-8B-Instruct *(with speculative decoding)* |
| `29` | `cpu-qwen3-coder-30b-specdec` | Qwen/Qwen3-Coder-30B-A3B-Instruct *(with speculative decoding)* |

> **Note:** `meta-llama/Llama-3.1-8B-Instruct` does not support parallel tool calling. Only sequential tool calls are supported with this model.

**Speculative Decoding:**

Models that support speculative decoding are available with a `-specdec` suffix (e.g. `cpu-qwen3-coder-30b-specdec`, `cpu-qwen2-5-coder-14b-specdec`, `cpu-llama-8b-specdec`). This technique uses a smaller draft model to generate candidate tokens quickly, which are then verified by the larger target model in parallel — reducing time-to-first-token and overall generation latency while preserving output quality.

These models are registered in LiteLLM with a `-Specdec` suffix to distinguish them from their non-speculative counterparts (e.g. `Qwen/Qwen3-Coder-30B-A3B-Instruct-Specdec`). The draft model is automatically configured during deployment.

To deploy a speculative decoding variant, set the `-specdec` model in `agentic-config.cfg`:

```ini
models=cpu-qwen3-coder-30b-specdec
```

Multiple models can be deployed together using a comma-separated list: `models=cpu-qwen3-coder-30b,cpu-bge-base-en`

### 4. Run the deployment

```bash
chmod +x deploy-agentic-stack.sh
./deploy-agentic-stack.sh
```

**Estimated time:** 20–40 minutes on a fresh node.

All output is also written to `deploy.log` in the repo root.

---

## Verify the Base Stack

After Step 1 completes, verify all pods are healthy before proceeding to Step 2:

```bash
# All pods should be Running
# (the vLLM pod may take an additional 10-15 min to pull the model weights)
kubectl get pods -A

# Retrieve the LiteLLM master key
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

# Confirm the model API is responding (replace api.example.com with your cluster_url):
# First, list registered models to confirm the model name:
curl -k https://api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

# Then test chat completions (use the model name returned by /v1/models above):
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "Qwen/Qwen3-Coder-30B-A3B-Instruct",
       "messages": [{"role":"user","content":"Write a Python hello world"}],
       "max_tokens": 100}'
```

> The `LITELLM_MASTER_KEY` is set in the `genai-gateway-deployment` environment variables in the `genai-gateway` namespace.

---

## Step 1b — Semantic Router (Intelligent Query Routing)

Semantic routing automatically directs queries to the most appropriate model based on content analysis using embeddings. This allows you to route simple queries to faster/cheaper CPU models while directing complex tasks to larger CPU models.

**Why Use Semantic Routing?**

- **Cost optimization:** Route simple queries to efficient models, complex ones to powerful models
- **Latency reduction:** Fast models handle straightforward requests quickly
- **Intelligent dispatch:** Coding tasks → coding-specialized models, reasoning → larger models
- **Transparent routing:** Applications use a single model name (e.g., `smart_router`), routing happens server-side

> **📚 For more information:** See the official [LiteLLM Auto Routing documentation](https://docs.litellm.ai/docs/proxy/auto_routing#litellm-proxy-server)

### Prerequisites

- Step 1 complete and base stack verified
- At least one model deployed (you'll add a second model for routing)

### 1. Deploy a Second Model

To enable semantic routing, deploy a more powerful model alongside your existing one.
- A **larger CPU model** for better capabilities


**Deploy a Larger CPU Model:**

Update `core/inventory/agentic-config.cfg`:

```ini
# Add a larger CPU model (option 24 is DeepSeek-R1-Distill-Qwen-32B or option 27 is Qwen3-Coder-30B)
models=cpu-qwen3-coder-30b,cpu-deepseek-r1-distill-qwen-32b
```

**Deploy the model:**

```bash
# Update agentic-config.cfg with the new model, then re-run the deploy script.
# It resumes automatically — already-running components are skipped.
./deploy-agentic-stack.sh
```


### 2. Deploy Embedding Model for Semantic Matching

Semantic routing requires an embedding model to generate vector representations of user queries and match them against predefined utterances. Deploy a Text Embedding Inference (TEI) service with **BAAI/bge-base-en-v1.5** using the deploy script.

**Update `core/inventory/agentic-config.cfg` to include the embedding model:**

```ini
# Add embedding model to your existing models
models=cpu-bge-base-en
```

**Deploy the embedding model:**

```bash
# Update agentic-config.cfg to add the embedding model, then re-run:
./deploy-agentic-stack.sh
```

### 3. Access the LiteLLM UI

Navigate to the LiteLLM UI in your browser:

```
https://api.example.com
```

Replace `api.example.com` with your actual `cluster_url` from the configuration.

Login credentials:
- The UI uses the same authentication as the API
- You'll need your `LITELLM_MASTER_KEY` for API access

### 4. Configure Semantic Router via UI

**Step 4a - Verify the Embedding Model:**

The embedding model is automatically registered in LiteLLM when deployed via `deploy-agentic-stack.sh`. Verify it's available:

1. Navigate to: **Models+Endpoints** → **Models** tab
2. Look for `BAAI/bge-base-en-v1.5` in the models list
3. Note the model name - you'll use it in the next step (typically `BAAI/bge-base-en-v1.5`)

**Step 4b - Configure the Auto Router:**

Navigate to: **Models+Endpoints** → **Add Model** → **Auto Router** Tab

**Configure the following required fields:**

| Field | Value | Description |
|-------|-------|-------------|
| **Auto Router Name** | `smart_router` | The model name developers will use in API requests (you can choose any name) |
| **Default Model** | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | Fallback model when no route matches (your smaller/faster model) |
| **Embedding Model** | `BAAI/bge-base-en-v1.5` | The embedding model deployed in Step 2 (auto-registered) |

**Configure Routes:**

Click **Add Route** to create routing rules. Configure at least two routes:

**Route 1 - Simple Queries (Smaller/Faster Model):**
- **Target Model:** `Qwen/Qwen3-Coder-30B-A3B-Instruct`
- **Utterances:**
  ```
  what is [topic]
  define [term]
  explain [concept] simply
  hello
  write a simple [language] function
  ```
- **Description:** Simple queries and basic coding tasks
- **Score Threshold:** `0.5`

**Route 2 - Complex Queries (More Powerful Model):**
- **Target Model:** `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` (larger CPU model)
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
- **Description:** Complex coding tasks and system design
- **Score Threshold:** `0.5`

Click **Save** to activate the semantic router.

### 5. Verify Semantic Routing

Test that queries are being routed correctly based on content:

**Simple query (should route to smaller model - fast response):**

```bash
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "smart_router",
    "messages": [{"role":"user","content":"What is a Python list?"}],
    "max_tokens": 100
  }'
```

**Complex query (should route to more powerful model):**

```bash
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "smart_router",
    "messages": [{"role":"user","content":"How to code a program in Python that implements a distributed task queue with Redis backend"}],
    "max_tokens": 200
  }'
```

**Check routing decisions in Langfuse:**

Navigate to the Langfuse dashboard to see which model handled each request:

```
https://trace-api.example.com
```

Look for the `model` field in the trace details to confirm routing decisions.

### How It Works

1. When a request comes in with `model="smart_router"` (or your chosen router name), LiteLLM generates embeddings for the input message
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

Set `deploy_redis=on` in `core/inventory/agentic-config.cfg` before running `./deploy-agentic-stack.sh`. Redis is deployed automatically as part of the stack, in the correct order .

```ini
deploy_redis=on
```

The deployment script reads `redis_stack_password` from `core/inventory/metadata/vault.yml` and passes it to the chart, so no manual credential setup is needed.

**Manual deployment (alternative / standalone):**

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
  --set "redis-stack-server.redis_stack_server.networkPolicy.allowedNamespaces={genai-gateway,agent-sandbox}"
  ```

  NetworkPolicy requires a CNI that enforces it (Calico, the default here, does).
- **Rotate the password** by updating `redis_stack_password` in `vault.yml` and re-running the deployment; restart dependent workloads so they pick up the new Secret.

---

## Step 2b — PostgreSQL + pgvector (Vector Store & Long-Term Memory)

PostgreSQL 16 with the **pgvector** extension gives every agentic workload a persistent, queryable vector store for long-term memory, RAG pipelines, semantic search, and structured state storage — all within the cluster.

**When to enable:**
- Your agent needs long-term memory that survives pod/session restarts
- You are building RAG pipelines that store and retrieve embeddings
- Use cases require structured relational + vector data in the same store
- You want a production-grade alternative to in-memory vector stores

**Enable in `core/inventory/agentic-config.cfg`:**

```ini
deploy_pgvector=on
```

Then run (or re-run) the deploy script — already-running components are skipped automatically:

```bash
./deploy-agentic-stack.sh
```

**What gets deployed:**

| Resource | Detail |
|---|---|
| Namespace | `pgvector` |
| Image | `pgvector/pgvector:pg16` (PostgreSQL 16 + pgvector extension) |
| Service | `pgvector.pgvector.svc.cluster.local:5432` |
| Database | `agentdb` |
| User | `agentuser` |
| Credentials secret | `pgvector-credentials` in the `pgvector` namespace or available in `core/inventory/metadata/vault.yml` |

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


```ini
# core/inventory/agentic-config.cfg
deploy_agent_sandbox=on
```

```bash
./deploy-agentic-stack.sh
```

**What gets deployed** (all in the `agent-sandbox` namespace):

| Component | Description |
|---|---|
| `agent-sandbox-controller` | Kubernetes operator that manages Sandbox pod lifecycle |
| CRDs | `sandboxes`, `sandboxtemplates`, `sandboxclaims`, `sandboxwarmpools` |
| `sandbox-router` | HTTP proxy that routes SDK requests to sandbox pods |
| `python-sandbox-template` | Default SandboxTemplate using a locally-built Python runtime |

**Verify:**

```bash
kubectl get pods -n agent-sandbox
# NAME                                          READY   STATUS    RESTARTS
# agent-sandbox-controller-xxx                  1/1     Running   0
# sandbox-router-deployment-xxx                 1/1     Running   0

kubectl get sandboxtemplate -n agent-sandbox
# NAME                      AGE
# python-sandbox-template   1m
```

> **In-cluster router URL** (used by the in-cluster agent):
> `http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080`

For the full guide — adding custom templates, WarmPools, and SDK usage — see
**[agent-sandbox.md](agent-sandbox.md)**.

---
