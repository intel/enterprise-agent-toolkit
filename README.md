# Enterprise Agent Toolkit

A batteries‑included Enterprise Agent Toolkit optimized for Intel® Xeon and Intel accelerators, delivering ready‑to‑deploy components for memory, sandboxing, tools, orchestration, and governance.

This repo gives one-click deployment of a production-grade Agentic AI platform.

Deploys a full Kubernetes-based stack with GenAI Gateway (LiteLLM + Langfuse), observability (Prometheus + Grafana), and the user selected SLM or LLM model for CPU/GPU  and an Coding Agent service.

---

## Table of Contents

- [What is the Enterprise Agent Toolkit?](#what-is-the-enterprise-agent-toolkit)
- [Platform Capabilities](#platform-capabilities)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
  - [Step 1 — Base Stack](#step-1--base-stack)
  - [Verify the Base Stack](#verify-the-base-stack)
  - [Step 2 — Redis (Shared Memory Backend)](#step-2--redis-shared-memory-backend)
  - [Step 2b — PostgreSQL + pgvector (Vector Store)](#step-2b--postgresql--pgvector-vector-store--long-term-memory)
  - [Step 3 — Coding Agent](#step-3--coding-agent-separate-step)
- [Backend Connection Reference](#backend-connection-reference)
- [Project Structure](#project-structure)
- [License](#license)

---

## What is the Enterprise Agent Toolkit?

The Enterprise Agent Toolkit is a production-ready, Kubernetes-based platform that turns a single Linux server into a fully operational AI agent infrastructure. It bundles every layer an enterprise needs to build, run, and govern AI agents — from secure API routing and intelligent model dispatch, to sandboxed code execution, persistent agent memory, and real-time observability.

Built on Intel® Xeon® Scalable processors, the stack is optimized for CPU-efficient inference out of the box and is designed to grow: models on external GPU clusters can be added to the same gateway at any time.


```bash
# Edit core/inventory/agentic-config.cfg with your domain, certs, HF token, and model
vim core/inventory/agentic-config.cfg

# Run the one-click deployment
./deploy-agentic-stack.sh
```

---

## Platform Capabilities

### API Gateway & Access Control
Unified, secure API entry point with policy-driven routing, rate limiting, and enterprise-grade authentication and authorization for agents, tools, and applications. Powered by **LiteLLM** (OpenAI-compatible gateway) and **Keycloak** (OAuth2/OIDC identity management), every request is authenticated and governed before it reaches a model or tool.

### Intelligent Routing
Automatically routes inference workloads to CPUs or GPUs based on the intent of the request — reasoning and planning tasks stay on in-cluster CPU nodes, while heavy compute (encoders, large generation) can be forwarded to external GPU clusters. The routing layer is model-agnostic and supports any OpenAI-compatible backend.

### Actions & Sandbox
Enables safe agent actions through sandboxed code execution, tool isolation, token telemetry, and policy-driven governance to control blast radius and ensure enterprise compliance. The built-in **Coding Agent** runs LLM-generated code inside isolated subprocesses with workspace scoping, preventing agents from affecting the host environment.

### Memory, State & Context
Provides scalable short- and long-term agent memory using vector databases and relational stores to maintain context across tasks, sessions, and workflows. **Redis** (with RediSearch) is deployed as the default memory backend, giving agents persistent session state, semantic search over past interactions, and cross-request continuity.

### Intel Tools & MCP
Accelerates agent actions via Intel-optimized tools, **Model Context Protocol (MCP)** integrations, classic AI/ML pipelines, and ingestion/ETL services. MCP server templates are included for extending the agent with domain-specific tooling without modifying the core stack.

### Orchestration
Orchestrates all agent workloads with **Kubernetes** (via Kubespray), **Helm**, and an Ansible-based automation layer. The stack supports distributed execution, rolling updates, high-availability scaling, and multi-node expansion out of the box. See the [Single-Node Deployment Guide](docs/single-node-deployment.md) and the [Multi-Node Deployment Guide](docs/multi-node-deployment.md) for step-by-step instructions on deploying across multiple servers.

### Observability & Telemetry
Integrates seamlessly with enterprise monitoring tooling, providing real-time metrics, traces, and logs through **Prometheus**, **Grafana**, **Loki**, and **Langfuse** (LLM-native tracing). Every token, latency measurement, and agent step is captured and queryable from the included dashboards.

---

## Requirements

### Hardware

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 48 cores | 96+ cores |
| RAM | 32 GB | 64 GB |
| Disk | 100 GB  | 200 GB  |
| OS | Ubuntu 22.04 / 24.04 | Ubuntu 22.04 LTS |
| Architecture | x86_64 | x86_64 |


### Access

- A [Hugging Face](https://huggingface.co) account with an API token that has **read** access to gated models.
- `sudo` privileges on the deployment node.
- Internet access from the node to pull Helm charts and container images.

### SSH Key Setup

Log in as a non-root user with `sudo` privileges. Using `root` or a password-based account may cause unexpected behavior during deployment.

1. **Generate an SSH key pair** (or use an existing one):

   ```bash
   ssh-keygen -t rsa -b 4096
   ```

   Leave the password blank when prompted.

2. **Copy the public key** (`id_rsa.pub`) to every control plane and workload node that will be part of the cluster.

3. **Add the public key** to `~/.ssh/authorized_keys` on each node:

   ```bash
   echo "<PUBLIC_KEY_CONTENTS>" >> ~/.ssh/authorized_keys
   ```

4. **Verify SSH access** from the Ansible control machine to each node:

   ```bash
   chmod 600 <path_to_PRIVATE_KEY>
   ssh -i <path_to_PRIVATE_KEY> <USERNAME>@<IP_ADDRESS>
   ```

   If a bastion host is used, ensure the Ansible control machine can reach the cluster nodes through it.

5. **Configure the Ansible inventory** (`core/inventory/hosts.yaml`) with your node IPs and SSH user. Example templates are provided for both deployment topologies:

   | Topology | Example inventory |
   |---|---|
   | Single node (all-in-one) | [docs/examples/single-node/hosts.yaml](docs/examples/single-node/hosts.yaml) |
   | Multi-node (3 control-plane + N workers) | [docs/examples/multi-node/hosts.yaml](docs/examples/multi-node/hosts.yaml) |

   Copy the appropriate template to `core/inventory/hosts.yaml` and replace `ansible_user`, `ansible_host`, and `ansible_ssh_private_key_file` with your actual values.

### DNS and SSL/TLS Setup

#### Production Environment

- Use a registered domain name with DNS records pointing to your server or load balancer.
- Obtain an SSL/TLS certificate from a trusted Certificate Authority (CA) and install it on your system.
- The certificate must cover the base domain **and all use-case subdomains**. For a `cluster_url` of `api.example.com` the following FQDNs need to be covered:

  | FQDN | Purpose |
  |---|---|
  | `api.example.com` | GenAI Gateway (LiteLLM) |
  | `trace-api.example.com` | Langfuse trace UI |
  | `coding-agent-api.example.com` | Coding Agent UI |

  Request a **multi-SAN** or **wildcard** (`*.api.example.com`) certificate from your CA that includes all of the above.
- Set up automatic renewal or calendar reminders before certificates expire.
- Ensure required firewall ports (e.g., port 80 for HTTP validation) are open during certificate issuance.

#### Development Environment

For local testing, `api.example.com` can be mapped to `localhost` or the node's private IP.

1. **Add entries to `/etc/hosts`** for every subdomain the stack uses:

   ```bash
   # Get the private IP of the machine
   hostname -I

   # Add all stack subdomains to /etc/hosts (replace 127.0.0.1 with the node IP if needed)
   # Replace api.example.com with your actual cluster_url
   sudo bash -c 'cat >> /etc/hosts <<EOF
   127.0.0.1 api.example.com
   127.0.0.1 trace-api.example.com
   127.0.0.1 coding-agent-api.example.com
   EOF'
   ```

   The subdomains follow this pattern for a `cluster_url` of `api.example.com`:

   | Host entry | Service |
   |---|---|
   | `api.example.com` | GenAI Gateway (LiteLLM) |
   | `trace-api.example.com` | Langfuse trace UI |
   | `coding-agent-api.example.com` | Coding Agent UI |

2. **Generate a self-signed SSL certificate** covering all subdomains:

   ```bash
   # Replace api.example.com with your actual cluster_url
   DOMAIN="api.example.com"

   mkdir -p ~/certs && cd ~/certs && \
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
     -subj "/CN=${DOMAIN}" \
     -addext "subjectAltName = DNS:${DOMAIN}, DNS:trace-${DOMAIN}, DNS:coding-agent-${DOMAIN}"
   ```

   > **Note:** The `-addext` option requires OpenSSL ≥ 1.1.1. If you add more use cases later, regenerate the cert with the additional `DNS:` entries.

   Files generated:
   - `cert.pem` — the self-signed certificate (contains SANs for all subdomains)
   - `key.pem` — the private key

   Set these paths in `core/inventory/agentic-config.cfg`:

   ```ini
   cert_file=/home/<user>/certs/cert.pem
   key_file=/home/<user>/certs/key.pem
   ```

---

## Quick Start

> **Single-node deployment** is described below. To deploy across multiple servers (1 control-plane + N workers, or 3-control-plane HA), see the [Multi-Node Deployment Guide](docs/multi-node-deployment.md).

### Step 1 — Base Stack

```bash
# 1. Clone the repository
git clone https://github.com/intel-innersource/applications.ai.enterprise.enterprise-agent-toolkit.git
cd applications.ai.enterprise.enterprise-agent-toolkit
```

#### 2. Edit `core/inventory/agentic-config.cfg`

Open `core/inventory/agentic-config.cfg` and fill in your values:

```ini
# Your cluster FQDN — this becomes the base URL for all services
cluster_url=api.example.com     # change to your domain e.g. intel.edge.com

# TLS certificate — provide a full-chain cert + private key
# For a custom domain: supply your CA-signed or self-signed cert/key files
cert_file=/path/to/your/fullchain.pem
key_file=/path/to/your/private.key

# HuggingFace token (required to pull gated models)
hugging_face_token=hf_xxxxxxxxxxxxxxxxxxxx

# Model to deploy — select the model from the model list (ex :cpu-qwen3-coder-30b)
models=cpu-qwen3-coder-30b
cpu_or_gpu=cpu

# Enable/disable stack components
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_redis=on          # standalone Redis Stack in its own namespace (required before coding-agent)
deploy_pgvector=off      # optional: PostgreSQL 16 + pgvector — shared vector store and long-term memory backend
deploy_coding_agent=on
```

> **Custom domain certs:** If using a custom domain (e.g. `intel.edge.com`), provide the full certificate chain
> (intermediate + root CA + leaf cert in one file) as `cert_file`, and the matching private key as `key_file`.
> If no cert files are provided, the script auto-generates a self-signed certificate for the domain.

#### 3. Choose your model

Set the `models` field in `agentic-config.cfg` to one value from the table below:

**CPU models** (`cpu_or_gpu=cpu`)

| # | Value to set in `models` | Model |
|---|---|---|
| `21` | `cpu-llama-8b` | meta-llama/Llama-3.1-8B-Instruct |
| `22` | `cpu-qwen3-coder-30b` | Qwen/Qwen3-Coder-30B-A3B-Instruct |
| `23` | `cpu-qwen2-5-coder-14b` | Qwen/Qwen2.5-Coder-14B-Instruct *(default — used by the Coding Agent)* |
| `24` | `cpu-whisper-small` | openai/whisper-small *(ASR — speech-to-text)* |
| `25` | `cpu-tei` | BAAI/bge-small-en-v1.5 *(text embedding)* |
| `26` | `cpu-rerank` | BAAI/bge-reranker-base *(reranking)* |


Multiple models can be deployed together using a comma-separated list: `models=cpu-qwen3-coder-30b,cpu-llama-8b`

#### 4. Run the deployment

```bash
chmod +x deploy-agentic-stack.sh
./deploy-agentic-stack.sh
```

**What the script does automatically:**

| Step | Action |
|---|---|
| 1 | Detect OS, architecture, and package manager |
| 2 | Install system prerequisites (`git`, `curl`, `python3`, etc.) |
| 3 | Configure passwordless SSH to localhost |
| 4 | Generate or reuse TLS certificate for `cluster_url` |
| 5 | Add `cluster_url` → `127.0.0.1` to `/etc/hosts` (if not DNS-resolvable) |
| 6 | Install Kubernetes via Kubespray (~15 min) |
| 7 | Deploy NGINX Ingress Controller |
| 8 | Deploy LiteLLM + Redis + Langfuse (GenAI Gateway) |
| 9 | Deploy Prometheus + Grafana + Loki (Observability) |
| 10 | Deploy selected model(s) via vLLM CPU or GPU |

**Estimated time:** 20–40 minutes on a fresh node.

All output is also written to `deploy.log` in the repo root.

---

### Verify the Base Stack

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

### Step 1b — Semantic Router (Intelligent Query Routing)

Semantic routing automatically directs queries to the most appropriate model based on content analysis using embeddings. This allows you to route simple queries to faster/cheaper CPU models while directing complex tasks to more powerful GPU models or larger CPU models.

**Why Use Semantic Routing?**

- **Cost optimization:** Route simple queries to efficient models, complex ones to powerful models
- **Latency reduction:** Fast models handle straightforward requests quickly
- **Intelligent dispatch:** Coding tasks → coding-specialized models, reasoning → larger models
- **Transparent routing:** Applications use a single model name (e.g., `smart_router`), routing happens server-side

> **📚 For more information:** See the official [LiteLLM Auto Routing documentation](https://docs.litellm.ai/docs/proxy/auto_routing#litellm-proxy-server)

#### Prerequisites

- Step 1 complete and base stack verified
- At least one model deployed (you'll add a second model for routing)

#### 1. Deploy a Second Model (GPU-based or Larger CPU Model)

To enable semantic routing, deploy a more powerful model alongside your existing one. This can be either:
- A **GPU model** for maximum performance (if you have GPU nodes available)
- A **larger CPU model** for better capabilities without requiring GPU hardware

**Option A - Deploy a GPU Model:**

Update `core/inventory/agentic-config.cfg`:

```ini
models=6
cpu_or_gpu=g
```

**Option B - Deploy a Larger CPU Model:**

Update `core/inventory/agentic-config.cfg`:

```ini
# Add a larger CPU model (option 24 is DeepSeek-R1-Distill-Qwen-32B or option 27 is Qwen3-Coder-30B)
models=cpu-qwen3-coder-30b,cpu-deepseek-r1-distill-qwen-32b
cpu_or_gpu=cpu
```

**Deploy the model:**

```bash
# Update agentic-config.cfg with the new model, then re-run the deploy script.
# It resumes automatically — already-running components are skipped.
./deploy-agentic-stack.sh
```

**Verify the new model is running:**

```bash
kubectl get pods -n default | grep vllm

# Test the new model endpoint
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

# Get the exact model path (replace with your actual model deployment)
kubectl get svc -n default | grep vllm

# Example test for GPU model:
# curl -k https://api.example.com/Qwen2.5-32B-Instruct-vllmgpu/v1/chat/completions ...

# Example test for larger CPU model:
# curl -k https://api.example.com/DeepSeek-R1-Distill-Qwen-32B-vllmcpu/v1/chat/completions ...
```

#### 2. Deploy Embedding Model for Semantic Matching

Semantic routing requires an embedding model to generate vector representations of user queries and match them against predefined utterances. Deploy a Text Embedding Inference (TEI) service with **BAAI/bge-base-en-v1.5** using the deploy script.

**Update `core/inventory/agentic-config.cfg` to include the embedding model:**

```ini
# Add embedding model (option 11) to your existing models
models=cpu-qwen3-coder-30b,11
cpu_or_gpu=g  # TEI embedding model requires GPU deployment mode
```

**Deploy the embedding model:**

```bash
# Update agentic-config.cfg to add the embedding model, then re-run:
./deploy-agentic-stack.sh
```

**Verify the embedding service is running:**

```bash
kubectl get pods -n default | grep tei
# Wait for pod to be Running (may take 5-10 minutes to download model)

# Test the embeddings endpoint through the GenAI Gateway
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

curl -k https://api.example.com/v1/embeddings \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "BAAI/bge-base-en-v1.5",
    "input": "Hello, world!"
  }'

# Expected output: JSON with embeddings array
```

#### 3. Access the LiteLLM UI

Navigate to the LiteLLM UI in your browser:

```
https://api.example.com
```

Replace `api.example.com` with your actual `cluster_url` from the configuration.

Login credentials:
- The UI uses the same authentication as the API
- You'll need your `LITELLM_MASTER_KEY` for API access

#### 4. Configure Semantic Router via UI

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
- **Target Model:** `Qwen/Qwen2.5-32B-Instruct` (GPU model) OR `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` (larger CPU model)
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

#### 5. Verify Semantic Routing

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

#### How It Works

1. When a request comes in with `model="smart_router"` (or your chosen router name), LiteLLM generates embeddings for the input message
2. It compares these embeddings against the utterances defined in your routes
3. If a route's similarity score exceeds the threshold, the request is routed to that model
4. If no route matches, the request goes to the default model

#### Routing Configuration Tips

- **Adjust score_threshold:** Lower values (0.3-0.4) route more queries to that model, higher values (0.6-0.7) require closer matches
- **Add more utterances:** Include domain-specific examples that represent your actual workload patterns
- **Use placeholders:** `[variable]` in utterances creates flexible matching patterns (e.g., `[language]`, `[system]`)
- **Monitor in Langfuse:** Track which queries route where and adjust thresholds based on actual usage
- **Test thoroughly:** Send diverse queries to understand routing behavior before production use

---

### Step 2 — Redis (Shared Memory Backend)

Redis is the **common memory backend** for all agentic workloads in this stack — deploy it before any use-case agent (Coding Agent, MCP agents, etc.).

The `core/helm-charts/redis` chart deploys **Redis Stack** (includes RediSearch) into its own `redis` namespace as a single persistent instance shared across all agents.

**Automated deployment (recommended):**

Set `deploy_redis=on` in `core/inventory/agentic-config.cfg` before running `./deploy-agentic-stack.sh`. Redis is deployed automatically as part of the stack, in the correct order (before the Coding Agent).

```ini
deploy_redis=on
```

**Manual deployment (alternative / standalone):**

```bash
# 1. Resolve Helm chart dependencies (fetches the redis-stack-server subchart)
helm dependency build core/helm-charts/redis

# 2. Deploy into the `redis` namespace
helm upgrade --install redis core/helm-charts/redis \
  --namespace redis \
  --create-namespace \
  --wait --timeout 5m
```

**Verify it is running:**

```bash
kubectl get pods -n redis
# NAME                       READY   STATUS    RESTARTS   AGE
# redis-stack-server-0       1/1     Running   0          60s

# Quick connectivity test
kubectl exec -n redis redis-stack-server-0 -- redis-cli ping
# PONG
```

**Redis URL (in-cluster) — use this in all agents:**

```
redis://redis-stack-server.redis.svc.cluster.local:6379
```

> This URL is the single source of truth for all agent workloads connecting to Redis within the cluster.

---

### Step 2b — PostgreSQL + pgvector (Vector Store & Long-Term Memory)

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

### Step 3 — Coding Agent

The Coding Agent can be deployed **in one shot alongside the base stack** (recommended) or **added later** once you have verified the base stack is healthy. Either way the script handles the build and deploy automatically.

**What the script does during Coding Agent deployment:**

| Sub-step | Action |
|---|---|
| 3a | Install `nerdctl` (container CLI for containerd — no Docker daemon needed) |
| 3b | Install `BuildKit` (daemonless image builder) |
| 3c | Start `buildkitd` wired to containerd's `k8s.io` namespace |
| 3d | Build `coding-agent:latest` image directly into containerd (no registry needed) |
| 3e | Ensure Helm is installed |
| 3f | Deploy with `redis.enabled=false` and `redisUrl` pointing to the shared Redis |
| 3g | `helm upgrade --install` into the `coding-agent` namespace |

#### Option A — One-shot (base stack + Coding Agent together)

Set `deploy_coding_agent=on` in `core/inventory/agentic-config.cfg` **before** running the script. The deploy script deploys the full base stack and then the Coding Agent in a single run:

```ini
# core/inventory/agentic-config.cfg
deploy_redis=on
deploy_coding_agent=on
```

```bash
./deploy-agentic-stack.sh
# Deploys base stack, then automatically deploys Coding Agent at the end
```

Alternatively, pass `--coding-agent` on the command line for the same effect without editing the config:

```bash
./deploy-agentic-stack.sh --coding-agent
```

#### Option B — Two-stage (verify base stack first, then add Coding Agent)

Run the base stack first, verify the model API is responding, then re-run to add the Coding Agent. The resume detection skips already-running components so only the Coding Agent steps execute:

```bash
# Stage 1 — deploy base stack only
./deploy-agentic-stack.sh

# Verify model is responding (see "Verify the Base Stack" section above)
curl -k https://api.example.com/v1/models -H "Authorization: Bearer <key>"

# Stage 2 — add Coding Agent on top of the running stack
./deploy-agentic-stack.sh --coding-agent
```

> On re-runs, if the `coding-agent` namespace already exists the script skips the Coding Agent deployment automatically (resume mode).

**Switching the Coding Agent to a different model (without full redeploy):**

If you deploy a new LLM model and want the Coding Agent to use it immediately, update `models=` in `core/inventory/agentic-config.cfg` and then use the interactive menu:

```bash
./deploy-agentic-stack.sh --menu
# Select: 3) Update Deployed Inference Cluster
#       → 2) Manage LLM Models
#       → 6) Switch Coding Agent to Current Model
```

This reads the current `models=` value from your config, resolves it to the HuggingFace model ID, patches the running Coding Agent configmap, and restarts the pod.

**Updating the Coding Agent model ID directly with Helm:**

To switch the Coding Agent to a different model ID without using the interactive menu, run `helm upgrade` with `--set agent.modelName`:

```bash
helm upgrade coding-agent usecases/coding-agent/helm-chart \
  --namespace coding-agent \
  --reuse-values \
  --set agent.modelName="Qwen/Qwen3-Coder-30B-A3B-Instruct"
```

Replace `Qwen/Qwen3-Coder-30B-A3B-Instruct` with the  model ID registered in LiteLLM .

This updates the `MODEL_NAME`, `OPENAI_MODEL`, and `OPENAI_CHAT_COMPLETION_MODEL` keys in the Coding Agent ConfigMap. The Coding Agent deployment automatically detects the ConfigMap change and triggers a rolling restart.



**Access the Coding Agent:**

The Coding Agent runs on its own subdomain to avoid conflicts with the GenAI Gateway at `api.example.com`:

```
https://coding-agent-api.example.com
```

The TLS certificate must include `coding-agent-api.example.com` as a SAN (Subject Alternative Name). If you followed the [DNS and SSL/TLS Setup](#dns-and-sslTLS-setup) section above, this is already covered. Replace `api.example.com` with your actual `cluster_url`.

> **Authentication — DevUI login and API access**
>
> When you open the Coding Agent URL in a browser, the DevUI will display a login prompt asking for an **auth token**.
> The same **DevUI token** is also required as a `Bearer` credential for all Coding Agent API calls (`/v1/entities`, `/v1/responses`, etc.).
> It is a dedicated credential for the Coding Agent — separate from the LiteLLM master key, which is used only for the GenAI Gateway.
>
> Retrieve it at any time with:
> ```bash
> grep '^coding_agent_devui_token:' core/inventory/metadata/vault.yml \
>   | sed 's/coding_agent_devui_token:[[:space:]]*//' | tr -d '"'
> ```
> Example token format: `devui-a3f7c2b1e8d94f60a2c1b3e7f8d0c4e2`

For local/dev access without DNS, you can also use port-forward:

```bash
kubectl port-forward -n coding-agent svc/coding-agent 8090:8090
# Open http://localhost:8090
```

**Coding Agent API examples:**

```bash
# Retrieve the DevUI token (set once, reuse for all calls below)
DEVUI_TOKEN=$(grep '^coding_agent_devui_token:' core/inventory/metadata/vault.yml \
  | sed 's/coding_agent_devui_token:[[:space:]]*//' | tr -d '"')

# Get the agent entity ID
AGENT_ID=$(curl -s http://localhost:8090/v1/entities \
  -H "Authorization: Bearer ${DEVUI_TOKEN}" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['entities'][0]['id'])")

# Submit a coding task to the agent
curl -s http://localhost:8090/v1/responses \
  -H "Authorization: Bearer ${DEVUI_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"metadata\":{\"entity_id\":\"${AGENT_ID}\"},\
       \"input\":[{\"type\":\"message\",\"role\":\"user\",\
                  \"content\":[{\"text\":\"Write a Python function to calculate Fibonacci numbers\",\"type\":\"input_text\"}]}],\
       \"stream\":false}"

# Health / metadata check (unauthenticated — does not require the DevUI token)
curl http://localhost:8090/meta
```

---

## Backend Connection Reference

All shared backends are deployed into their own namespaces and are reachable from any workload namespace in the cluster.

### Redis (Session Memory & Caching)

| Instance | Kubernetes Service | URL | Scope |
|---|---|---|---|
| **Redis Stack** (`deploy_redis=on`) | `redis-stack-server.redis.svc.cluster.local:6379` | `redis://redis-stack-server.redis.svc.cluster.local:6379` | All namespaces |

```bash
# Verify the Redis URL is in use by the Coding Agent
kubectl get configmap -n coding-agent coding-agent-config -o jsonpath='{.data.REDIS_URL}'
# redis://redis-stack-server.redis.svc.cluster.local:6379

# Quick connectivity test
kubectl exec -n redis redis-stack-server-0 -- redis-cli ping
# PONG
```

### PostgreSQL + pgvector (Vector Store & Long-Term Memory)

Enabled with `deploy_pgvector=on`. See [Step 2b](#step-2b--postgresql--pgvector-vector-store--long-term-memory) for full details.

| Resource | Value |
|---|---|
| **Namespace** | `pgvector` |
| **Host** | `pgvector.pgvector.svc.cluster.local` |
| **Port** | `5432` |
| **Database** | `agentdb` |
| **User** | `agentuser` |
| **Connection string** | `postgresql://agentuser:<password>@pgvector.pgvector.svc.cluster.local:5432/agentdb` |
| **Credentials secret** | `kubectl get secret pgvector-credentials -n pgvector -o jsonpath='{.data.DATABASE_URL}' \| base64 -d` |

---

### Decommission / Reset and Redeploy from Scratch

> **Warning:** This destroys the entire Kubernetes cluster and all workloads, data, and secrets. It cannot be undone.

#### Step 1 — Decommission via the interactive menu

```bash
./deploy-agentic-stack.sh --menu
# Select option 2 — "Decommission Existing Cluster"
# Confirm the prompt — this runs the full cluster purge playbook
```

What the decommission does:
- Runs Kubespray's `reset.yml` to remove all Kubernetes components from the node
- Removes all Helm releases and namespaces (`genai-gateway`, `coding-agent`, `redis`, `observability`, etc.)
- Cleans up container images injected into containerd
- Removes the generated `hosts.yaml` inventory

> The `core/inventory/agentic-config.cfg` file is **not** deleted — your settings are preserved for the next run.

#### Step 2 — Redeploy from scratch

After decommission completes, set the components you want back to `on` in `agentic-config.cfg`, then run:

```bash
# Turn Kubernetes installation back on (was set to off after first install)
# Edit core/inventory/agentic-config.cfg:
#   deploy_kubernetes_fresh=on
#   deploy_ingress_controller=on
#   deploy_genai_gateway=on
#   deploy_observability=on
#   deploy_llm_models=on
#   deploy_redis=on
#   deploy_coding_agent=on   # if you want the Coding Agent

./deploy-agentic-stack.sh
```

The script will deploy everything from scratch. Components are automatically set to `off` in the config once deployed so subsequent re-runs skip already-running components.

---

## Project Structure

```
enterprise-agent-toolkit/
├── deploy-agentic-stack.sh            # One-click deployment entry point
├── deploy.log                         # Runtime deployment log (generated)
├── README.md
├── LICENSE
├── SECURITY.md
├── core/
│   ├── agentic-stack.sh               # Compatibility shim → forwards to deploy-agentic-stack.sh
│   ├── helm-charts/
│   │   ├── genai-gateway/             # LiteLLM + Langfuse chart
│   │   ├── genai-gateway-trace/       # Langfuse trace backend chart
│   │   ├── observability/             # Prometheus + Grafana + Loki stack
│   │   ├── vllm/                      # vLLM CPU serving chart
│   │   ├── redis/                     # Redis Stack (shared memory backend for all agents)
│   │   ├── pgvector/                  # PostgreSQL 16 + pgvector (vector store & long-term memory)
│   │   ├── mcp-server-template/       # MCP tool server template
│   │   └── ...
│   ├── inventory/                     # Ansible inventory (generated by deploy script)
│   │   ├── hosts.yaml
│   │   └── agentic-config.cfg
│   ├── lib/                           # Shared shell library (model selection, system checks)
│   ├── playbooks/                     # Ansible playbooks for each component
│   ├── roles/                         # Ansible roles
│   └── scripts/                       # Utility scripts (token generation, etc.)
├── usecases/                          # End-to-end use case examples and source
│   └── coding-agent/                  # Coding Agent use case
│       ├── README.md                  # Overview, API reference, usage guide
│       ├── docker-compose.yml         # Local dev stack (no Kubernetes required)
│       ├── src/                       # Coding Agent application source
│       │   ├── Dockerfile
│       │   ├── app.py                 # FastAPI + LangGraph ReAct agent (REDIS_URL env var)
│       │   └── requirements.txt
│       ├── helm-chart/                # Coding Agent Helm chart (+ Redis subchart)
│       │   └── values.yaml            # Set redis.enabled=false + redisUrl to use standalone
│       └── examples/                  # curl, Python, and OpenAI SDK examples
└── docs/                              # Extended documentation
    ├── examples/
    │   ├── single-node/
    │   │   └── hosts.yaml             # Inventory template: single-node (all-in-one)
    │   └── multi-node/
    │       └── hosts.yaml             # Inventory template: 3 control-plane + N workers
    ├── single-node-deployment.md
    ├── multi-node-deployment.md
    ├── configuring-inference-config-cfg-file.md
    ├── running-behind-proxy.md
    └── ...
```

---

## License

Licensed under the [Apache License Version 2.0](LICENSE).

## Security

See [SECURITY.md](SECURITY.md) for our security policy and vulnerability reporting guidelines.

## Trademark Information

Intel, the Intel logo, Xeon, and Gaudi are trademarks of Intel Corporation or its subsidiaries.  
Other names and brands may be claimed as the property of others.  
&copy; Intel Corporation
