# Multi-Node Deployment Guide

This guide describes how to deploy the Intel AI for Enterprise Agent Toolkit across multiple nodes — a control-plane node running all stack services plus one or more worker nodes that host additional LLM inference workloads.

The Kubernetes layer is provisioned by **Kubespray**, which natively supports multi-node clusters. Everything above Kubernetes (LiteLLM, Langfuse, Redis, Prometheus/Grafana) runs on the cluster and is automatically distributed by Kubernetes scheduling.


## Table of Contents

- [Step 1 — Configure `hosts.yaml`](#step-1--configure-hostsyaml)
- [Step 2 — Configure /etc/hosts and TLS](#step-2--configure-etchosts-and-tls)
- [Step 3 — Configure agentic-config.cfg](#step-3--configure-agentic-configcfg)
- [Step 4 — Deploy](#step-4--deploy)
- [Step 5 — Verify](#step-5--verify)
- [Step 6 — Semantic Router (Intelligent Query Routing)](#step-6--semantic-router-intelligent-query-routing)
- [Step 7 — Redis (Shared Memory Backend)](#step-7--redis-shared-memory-backend)
- [Step 8 — PostgreSQL + pgvector (Vector Store)](#step-8--postgresql--pgvector-vector-store--long-term-memory)
- [Step 9 — Agent Sandbox (Sandboxed Code Execution)](#step-9--agent-sandbox-sandboxed-code-execution)
- [Adding a Worker Node to a Running Cluster](#adding-a-worker-node-to-a-running-cluster)
- [Supported Deployment Topologies](#supported-deployment-topologies)
- [Notes](#notes)
- [Troubleshooting](#troubleshooting)

---

## Step 1 — Configure `hosts.yaml`

The default `core/inventory/hosts.yaml` is a single-node config pointing to `localhost`. For multi-node, edit it to list every node under the correct Kubespray groups.

### Single Master + Multiple Workers (recommended for most deployments)

```yaml
all:
  hosts:
    master1:
      ansible_host: 10.0.0.1          # control-plane private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker1:
      ansible_host: 10.0.0.2          # worker node 1 private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker2:
      ansible_host: 10.0.0.3          # worker node 2 private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
  children:
    kube_control_plane:
      hosts:
        master1:
    kube_node:
      hosts:
        master1:
        worker1:
        worker2:
    etcd:
      hosts:
        master1:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
```


> **Note:** The node running `./deploy-agentic-stack.sh` must be able to reach all other nodes via SSH using the key specified in `ansible_ssh_private_key_file`.

---

## Step 2 — Configure `/etc/hosts` and TLS

### On every node

Add all stack subdomains pointing to the control-plane node (or load balancer IP):

```bash
# Replace 10.0.0.1 with your control-plane/LB IP
# Replace api.example.com with your actual cluster_url
sudo bash -c 'cat >> /etc/hosts <<EOF
10.0.0.1 api.example.com
10.0.0.1 trace-api.example.com
EOF'
```

### On the control-plane node — generate or supply TLS certificates

```bash
DOMAIN="api.example.com"   # replace with your cluster_url

mkdir -p ~/certs && cd ~/certs && \
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName = DNS:${DOMAIN}, DNS:trace-${DOMAIN}, DNS:*.${DOMAIN}"
```

Set the generated paths in `core/inventory/agentic-config.cfg`:

```ini
cert_file=/home/ubuntu/certs/cert.pem
key_file=/home/ubuntu/certs/key.pem
```

---

## Step 3 — Configure `agentic-config.cfg`

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

### Choose your model

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

---

## Step 4 — Deploy

Run the deployment script from the control-plane node:

```bash
chmod +x deploy-agentic-stack.sh
./deploy-agentic-stack.sh
```

Kubespray will use `core/inventory/hosts.yaml` to provision Kubernetes across all listed nodes (~20–30 min). The remaining stack components are then deployed on top.

---

## Step 5 — Verify

After deployment, confirm all nodes joined the cluster and all pods are healthy:

```bash
# All nodes should show Ready
kubectl get nodes -o wide

# All pods should be Running
# (the vLLM pod may take an additional 10-15 min to pull the model weights)
kubectl get pods -A

# Retrieve the LiteLLM master key
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

# List registered models to confirm the model name
curl -k https://api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

# Test chat completions (use the model name returned by /v1/models above)
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "Qwen/Qwen3-Coder-30B-A3B-Instruct",
       "messages": [{"role":"user","content":"Write a Python hello world"}],
       "max_tokens": 100}'
```

> The `LITELLM_MASTER_KEY` is set in the `genai-gateway-deployment` environment variables in the `genai-gateway` namespace.

---

## Step 6 — Semantic Router (Intelligent Query Routing)

Semantic routing automatically directs queries to the most appropriate model based on content analysis using embeddings. This allows you to route simple queries to faster/cheaper CPU models while directing complex tasks to more powerful GPU models or larger CPU models.

**Why Use Semantic Routing?**

- **Cost optimization:** Route simple queries to efficient models, complex ones to powerful models
- **Latency reduction:** Fast models handle straightforward requests quickly
- **Intelligent dispatch:** Coding tasks → coding-specialized models, reasoning → larger models
- **Transparent routing:** Applications use a single model name (e.g., `smart_router`), routing happens server-side

> **📚 For more information:** See the official [LiteLLM Auto Routing documentation](https://docs.litellm.ai/docs/proxy/auto_routing#litellm-proxy-server)

### Prerequisites

- Step 5 complete and base stack verified
- At least one model deployed (you'll add a second model for routing)

### 1. Deploy a Second Model

Update `core/inventory/agentic-config.cfg` to add a more powerful model alongside your existing one:

```ini
models=cpu-qwen3-coder-30b,cpu-deepseek-r1-distill-qwen-32b
```

```bash
# Re-run the deploy script — already-running components are skipped automatically
./deploy-agentic-stack.sh
```

### 2. Deploy Embedding Model for Semantic Matching

Semantic routing requires an embedding model to generate vector representations of user queries. Update `core/inventory/agentic-config.cfg` to include the embedding model:

```ini
models=cpu-bge-base-en
```

```bash
./deploy-agentic-stack.sh
```

### 3. Access the LiteLLM UI

Navigate to the LiteLLM UI in your browser:

```
https://api.example.com
```

Replace `api.example.com` with your actual `cluster_url`.

### 4. Configure Semantic Router via UI

**Step 4a — Verify the Embedding Model:**

1. Navigate to: **Models+Endpoints** → **Models** tab
2. Look for `BAAI/bge-base-en-v1.5` in the models list

**Step 4b — Configure the Auto Router:**

Navigate to: **Models+Endpoints** → **Add Model** → **Auto Router** Tab

| Field | Value | Description |
|-------|-------|-------------|
| **Auto Router Name** | `smart_router` | The model name developers will use in API requests |
| **Default Model** | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | Fallback model when no route matches |
| **Embedding Model** | `BAAI/bge-base-en-v1.5` | The embedding model deployed above |

**Configure Routes:**

Click **Add Route** to create routing rules. Configure at least two routes:

**Route 1 — Simple Queries (Smaller/Faster Model):**
- **Target Model:** `Qwen/Qwen3-Coder-30B-A3B-Instruct`
- **Utterances:**
  ```
  what is [topic]
  define [term]
  explain [concept] simply
  hello
  write a simple [language] function
  ```
- **Score Threshold:** `0.5`

**Route 2 — Complex Queries (More Powerful Model):**
- **Target Model:** `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B`
- **Utterances:**
  ```
  design a [system] architecture
  optimize this [language] code for performance
  debug this complex [issue]
  refactor this codebase to use [pattern]
  implement a distributed [system]
  create a production-ready [application]
  how to code a program in [language]
  ```
- **Score Threshold:** `0.5`

Click **Save** to activate the semantic router.

### 5. Verify Semantic Routing

```bash
export LITELLM_MASTER_KEY=$(kubectl get deploy -n genai-gateway genai-gateway-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LITELLM_MASTER_KEY")].value}')

# Simple query — should route to the smaller/faster model
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "smart_router", "messages": [{"role":"user","content":"What is a Python list?"}], "max_tokens": 100}'

# Complex query — should route to the more powerful model
curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "smart_router", "messages": [{"role":"user","content":"How to code a program in Python that implements a distributed task queue with Redis backend"}], "max_tokens": 200}'
```

Check routing decisions in Langfuse at `https://trace-api.example.com` — look for the `model` field in trace details.

---

## Step 7 — Redis (Shared Memory Backend)

Redis is the **common memory backend** for all agentic workloads in this stack — deploy it before any use-case agent (MCP agents, etc.).

The `core/helm-charts/redis` chart deploys **Redis Stack** (includes RediSearch) into its own `redis` namespace as a single persistent instance shared across all agents.

**Automated deployment (recommended):**

Set `deploy_redis=on` in `core/inventory/agentic-config.cfg` before running `./deploy-agentic-stack.sh`. Redis is deployed automatically as part of the stack.

```ini
deploy_redis=on
```

**Manual deployment (alternative / standalone):**

A password is mandatory — the chart refuses to render without one.

```bash
# 1. Resolve Helm chart dependencies
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

kubectl exec -n redis redis-stack-server-0 -- sh -c \
  'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping'
# PONG
```

**Redis URL (in-cluster) — use this in all agents:**

```bash
kubectl get secret redis-stack-server-credentials -n redis \
  -o jsonpath='{.data.REDIS_URL}' | base64 -d
# redis://default:<password>@redis-stack-server.redis.svc.cluster.local:6379
```

### Redis security notes

Redis holds agent session state and is a code-execution surface (Lua, plus JavaScript via RedisGears), so it must never be reachable unauthenticated.

- **Authentication is mandatory** — the chart fails to render without a password.
- **The Service is `ClusterIP`.** Do not switch it to `NodePort` or `LoadBalancer`. On a multi-node cluster a NodePort binds the 30000-32767 range on *every* node IP, so anything that can route to any node reaches Redis. This matters most when nodes have public addresses or sit in a permissive cloud security group.
- **Firewall the NodePort range.** In addition to the inter-node ports listed above, restrict `30000-32767` to trusted sources at the host firewall or cloud security-group level. Do not expose it to the internet.
- **Restrict Redis to the namespaces that need it** with the bundled NetworkPolicy (requires an enforcing CNI such as Calico):

  ```bash
  --set "redis-stack-server.redis_stack_server.networkPolicy.allowedNamespaces={genai-gateway,agent-sandbox}"
  ```

---

## Step 8 — PostgreSQL + pgvector (Vector Store & Long-Term Memory)

PostgreSQL 16 with the **pgvector** extension gives every agentic workload a persistent, queryable vector store for long-term memory, RAG pipelines, semantic search, and structured state storage.

**When to enable:**
- Your agent needs long-term memory that survives pod/session restarts
- You are building RAG pipelines that store and retrieve embeddings
- Use cases require structured relational + vector data in the same store

**Enable in `core/inventory/agentic-config.cfg`:**

```ini
deploy_pgvector=on
```

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

## Step 9 — Agent Sandbox (Sandboxed Code Execution)

Agent Sandbox provides **isolated, ephemeral Kubernetes pods** for safe code execution. Every sandbox is a fully self-contained pod — the agent can run arbitrary code, install packages, and write files without touching the host or other workloads.

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

For the full guide — adding custom templates, WarmPools, and SDK usage — see **[agent-sandbox.md](agent-sandbox.md)**.

---

To expand a running cluster with an additional worker node:

1. Add the new node's entry to `core/inventory/hosts.yaml` under both `all.hosts` and `kube_node`.
2. Ensure passwordless SSH is set up from the control-plane node to the new node.
3. Either re-run the deploy script (recommended — it detects the new node automatically):

```bash
./deploy-agentic-stack.sh
```

Or use the interactive menu:

```bash
./deploy-agentic-stack.sh --menu
# Select: 4) Manage Cluster Nodes
#       → Add Worker Node
```

The script runs Kubespray's `cluster.yml` to join the node and re-applies the NRI balloon CPU policy if applicable.

---

## Supported Deployment Topologies

| Topology | Use case |
|---|---|
| Single node (default) | Development, testing, single-server deployments |
| 1 control-plane + N workers | Production — scale inference horizontally |
| 3 control-planes + N workers | HA production — no single point of failure on the control plane |

---

## Notes

- The **NGINX Ingress Controller** binds to the control-plane node by default. For HA deployments with multiple control-plane nodes, configure a load balancer in front and point `cluster_url` DNS to the LB IP.
- **Redis** runs as a single `StatefulSet` in the `redis` namespace. It is shared across all agent namespaces but is not clustered by default. For high-availability Redis, configure Redis Cluster or Redis Sentinel via the `core/helm-charts/redis` chart values.
- **Model weights** are pulled onto whichever node the vLLM pod is scheduled. For multi-worker setups with PVC-backed model storage, see the `modelUsePVC` option in `core/helm-charts/vllm/values.yaml`.
- Ensure all required ports are open between nodes (Kubernetes API: 6443, etcd: 2379–2380, Calico: 179, kubelet: 10250).

---

## Troubleshooting

| Symptom | Resolution |
|---|---|
| Node shows `NotReady` | Check kubelet: `systemctl status kubelet` on the affected node |
| SSH connection refused during Kubespray | Verify `ansible_host` IPs and `ansible_ssh_private_key_file` paths in `hosts.yaml` |
| Pods stuck in `Pending` | Check node resources: `kubectl describe node <node>` |
| Model pod not scheduled on worker | Confirm the worker has sufficient CPU/RAM and no taints blocking scheduling: `kubectl describe node <worker>` |

For further help, open an issue in the repository.