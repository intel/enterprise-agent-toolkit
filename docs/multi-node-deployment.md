# Multi-Node Deployment Guide

> **100G Arista fabric deployment?** If your rack has a 100G Clos fabric, Intel® E810-C NICs, and NVMe storage nodes, use the **[Rack-Scale Deployment Guide](rack-scale-deployment.md)** instead — it covers BGP, dual-homed nodes, and Ceph-on-fabric with a single `rack-profile.yaml` config.
>
> **Note:** not available in this release.

This guide describes how to deploy the Intel® AI for Enterprise Agent Toolkit across multiple nodes — a control-plane node running all stack services plus one or more worker nodes that host additional LLM inference workloads.

The Kubernetes layer is provisioned by **Kubespray**, which natively supports multi-node clusters. Everything above Kubernetes (LiteLLM, Langfuse, Redis, Prometheus/Grafana) runs on the cluster and is automatically distributed by Kubernetes scheduling.


## Table of Contents

- [Step 1 — Configure `hosts.yaml`](#step-1--configure-hostsyaml)
- [Step 2 — Configure the environment files](#step-2--configure-the-environment-files)
- [Step 3 — Deploy](#step-3--deploy)
- [Step 4 — Verify](#step-4--verify)
- [Step 5 — Semantic Router (Intelligent Query Routing)](#step-5--semantic-router-intelligent-query-routing)
- [Step 6 — Redis (Shared Memory Backend)](#step-6--redis-shared-memory-backend)
- [Step 7 — PostgreSQL + pgvector (Vector Store)](#step-7--postgresql--pgvector-vector-store--long-term-memory)
- [Step 8 — Agent Sandbox (Sandboxed Code Execution)](#step-8--agent-sandbox-sandboxed-code-execution)
- [Adding a Worker Node to a Running Cluster](#adding-a-worker-node-to-a-running-cluster)
- [Supported Deployment Topologies](#supported-deployment-topologies)
- [Notes](#notes)
- [Troubleshooting](#troubleshooting)

---

## Step 1 — Configure `hosts.yaml`

The default `env/<name>/inventory/hosts.yaml`, created by `./es_auto_installer.sh init agent-toolkit`, is a single-node config pointing to `localhost`. For multi-node, edit it to list every node under the correct Kubespray groups.

### Single Master + Multiple Workers (recommended for most deployments)

```yaml
all:
  hosts:
    master1:
      ansible_host: 10.0.0.1          # control-plane private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_connection: ssh
      ansible_become: true
    worker1:
      ansible_host: 10.0.0.2          # worker node 1 private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_connection: ssh
      ansible_become: true
    worker2:
      ansible_host: 10.0.0.3          # worker node 2 private IP
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_connection: ssh
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


> **Note:** The node running `./es_auto_installer.sh install agent-toolkit` must be able to reach all other nodes via SSH using the key specified in `ansible_ssh_private_key_file`. For the node you run it on, either set `ansible_connection: local` in place of the SSH settings, or make sure that node can SSH to itself with the same key. Keep `ansible_connection: ssh` on every other node: the installer's playbook runs locally, and steps it runs for a node without that line (Kata, CPU pinning) would run on the installer machine instead.

---

## Step 2 — Configure the environment files

Open `env/<name>/global_config.yaml` and `env/<name>/config.agent-toolkit.yaml` and fill in your values:

```yaml
# ---- env/<name>/global_config.yaml ----

# Required on multi-node: shared storage that every node can mount. nfs provisions an NFS server on the
# first control-plane node at /data/nfs (ceph and netapp-trident also work); local-path is single-node only
storage_backend: nfs

# Your cluster FQDN — this becomes the base URL for all services
base_domain_name: "example.com"

# TLS certificate — provide a full-chain cert + private key
# For a custom domain: supply your CA-signed or self-signed cert/key files
gateway_tls_mode: "custom"     # selfsigned (default) | custom
gateway_tls_cert_file: "/path/to/your/fullchain.pem"
gateway_tls_key_file: "/path/to/your/private.key"

# Enable/disable stack components
auth_provider: "litellm"      # set by init agent-toolkit
observability_enabled: true

# Proxy settings (optional, depending on network)
http_proxy: ""
https_proxy: ""
no_proxy: ""

# ---- env/<name>/config.agent-toolkit.yaml ----

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

HuggingFace token (required to pull gated models): run `export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx` before `./es_auto_installer.sh install agent-toolkit`.

>*Note:* For proxy settings, see [running-behind-proxy.md](./running-behind-proxy.md).

### Choose your model

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

> **Memory:** a node needs the `memory:` requests of its models (in `env/<name>/models.yaml`) plus about 17 GiB for the rest of the stack, and 16 GiB more for Qwen3Guard while the content-safety guardrail is on. The default install requests about 131 GiB (`qwen2-5-coder-14b` 96 GiB, Qwen3Guard 16 GiB, router 2 GiB, the rest 17 GiB); each model runs on one node, so one node must have room for it. On 128 GB nodes choose a 64 GiB model (`qwen2-5-coder-7b`, `llama-3-1-8b`). `qwen3-coder-30b` requests 160 GiB.

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

---

## Step 3 — Deploy

Run the deployment script from the control-plane node:

```bash
./es_auto_installer.sh init agent-toolkit
./es_auto_installer.sh install agent-toolkit
```

Kubespray will use `env/<name>/inventory/hosts.yaml` to provision Kubernetes across all listed nodes (~20–30 min). The remaining stack components are then deployed on top.

---

## Step 4 — Verify

After deployment, confirm all nodes joined the cluster and all pods are healthy:

```bash
# The installer writes the cluster's kubeconfig into the env
export KUBECONFIG=$(pwd)/env/<name>/kubeconfig.yaml

# All nodes should show Ready
kubectl get nodes -o wide

# All pods should be Running
# (the vLLM pod may take an additional 10-15 min to pull the model weights)
kubectl get pods -A

# Retrieve the LiteLLM master key
export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm -o jsonpath='{.data.master_key}' | base64 -d)

# (Optional) If behind a corporate proxy, update no_proxy to prevent the request from being intercepted by the proxy (replace <base_domain_name> with your base_domain_name)
export no_proxy="${no_proxy},litellm.<base_domain_name>,langfuse.<base_domain_name>"

# Gateway IP: map litellm.<base_domain_name> (and the other service names) to it in /etc/hosts
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'

# List registered models to confirm the model name (replace <base_domain_name> with your base_domain_name)
curl -k https://litellm.<base_domain_name>/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

# Test chat completions (replace <base_domain_name> with your base_domain_name, then use the model name returned by /v1/models above)
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "qwen2-5-coder-14b",
       "messages": [{"role":"user","content":"Write a Python hello world"}],
       "max_tokens": 100}'
```

> The `LITELLM_MASTER_KEY` is stored in the `litellm-master-key` Secret in the `litellm` namespace.

---

## Step 5 — Semantic Router (Intelligent Query Routing)

Semantic routing automatically directs queries to the most appropriate model based on content analysis using embeddings. This allows you to route simple queries to faster/cheaper CPU models while directing complex tasks to more powerful GPU models or larger CPU models.

**Why Use Semantic Routing?**

- **Cost optimization:** Route simple queries to efficient models, complex ones to powerful models
- **Latency reduction:** Fast models handle straightforward requests quickly
- **Intelligent dispatch:** Coding tasks → coding-specialized models, reasoning → larger models
- **Transparent routing:** Applications use a single model name (e.g., `hybrid-router`), routing happens server-side

> **📚 For more information:** See the official [LiteLLM Auto Routing documentation](https://docs.litellm.ai/docs/proxy/auto_routing#litellm-proxy-server)

### Prerequisites

- Step 4 complete and base stack verified
- At least one model deployed (you'll add a second model for routing)

### 1. Deploy a Second Model and an Embedding Model

The hybrid router spreads requests over the deployed chat models, so deploy a second one. **BAAI/bge-base-en-v1.5** (`bge-base-en`) is added as well, as the embedding model for your agents.

A second larger model i.e. **Qwen/Qwen3-Coder-30B-A3B-Instruct** with better capabilities will also be deployed alongside your existing one.

**Update `env/<name>/config.agent-toolkit.yaml` to include the embedding model and second model:**

```yaml
llm_services_autodeploy_models: ["qwen2-5-coder-14b", "bge-base-en", "qwen3-coder-30b"]
```

**Deploy the model:**

*Important:* With the NRI balloon policy, the default model (`cpu: auto`) takes the free physical cores of one NUMA node. When no NUMA node has enough free cores left, a further deploy stops with `NRI pre-flight failed: not enough physical cores`. To make room, set an explicit `cpu:` for each model in `env/<name>/models.yaml` (see [xeon-model-configuration.md](xeon-model-configuration.md)), then re-run the install:

```bash
./es_auto_installer.sh install agent-toolkit
```

Restart the GenAI Gateway's Deployment:
```bash
kubectl rollout restart deployment litellm -n litellm
```

Follow the steps to [re-verify the base stack](#step-4--verify) to ensure models can be accessed.

### 2. Access the LiteLLM UI

Open `https://litellm.<base_domain_name>/ui` in your browser (the gateway IP must be in `/etc/hosts` for that name, as in the quick-start). Without the hosts entry, port-forward the LiteLLM Service and open `http://localhost:4000/ui`:

```
kubectl port-forward -n litellm svc/litellm 4000:4000
```

Login credentials:
- Username: default which is `admin`
- Password: the value of `LITELLM_MASTER_KEY`

### 3. Configure Semantic Router via UI

**Step 3a — Verify the Embedding Model:**

1. Navigate to: **Models+Endpoints** → **All Models** tab
2. Look for `bge-base-en` in the models list

**Step 3b — The hybrid router:**

This release creates the `hybrid-router` model at install (`hybrid_router_enabled: true`, the default), so there is no UI step. It sorts each request by complexity and sends it to one of the deployed chat models. Models deployed after the install join it when you re-run `./es_auto_installer.sh install agent-toolkit`. Tiers and model lists: [hybrid-router.md](hybrid-router.md).

### 4. Verify Semantic Routing

```bash
export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm -o jsonpath='{.data.master_key}' | base64 -d)

# Simple query — should route to the smaller/faster model
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "hybrid-router", "messages": [{"role":"user","content":"What is a Python list?"}], "max_tokens": 100}'

# Complex query — should route to the more powerful model
curl -k https://litellm.<base_domain_name>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "hybrid-router", "messages": [{"role":"user","content":"How to code a program in Python that implements a distributed task queue with Redis backend"}], "max_tokens": 200}'
```

Check routing decisions in Langfuse at `https://langfuse.<base_domain_name>`.

Login credentials: the Langfuse login and password are generated into the `langfuse-secrets` Secret in the `langfuse` namespace (keys `admin_email` / `admin_password`).

Go inside the `inference` project. Under **Tracing**, select the most recent `litellm_request`, scroll down to **Metadata** → **attributes**. Look at the `llm.model_name` field to confirm routing decisions.

---

## Step 6 — Redis (Shared Memory Backend)

Redis is the **common memory backend** for all agentic workloads in this stack — deploy it before any use-case agent (MCP agents, etc.).

The `charts/redis-stack` chart deploys **Redis Stack** (includes RediSearch) into its own `redis` namespace as a single persistent instance shared across all agents.

**Automated deployment (recommended):**

By default, Redis should already be deployed. You can check by running `kubectl get pods -n redis`. If not, follow the instructions below to deploy it.

Set `redis_stack_enabled: true` in `env/<name>/config.agent-toolkit.yaml`:
```yaml
redis_stack_enabled: true
```

Then re-run `es_auto_installer.sh`:
```bash
./es_auto_installer.sh install agent-toolkit
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
- **Mesh-only access.** Redis runs in the ambient mesh: namespaces in the mesh reach it, plaintext clients from outside are refused.

---

## Step 7 — PostgreSQL + pgvector (Vector Store & Long-Term Memory)

PostgreSQL 16 with the **pgvector** extension gives every agentic workload a persistent, queryable vector store for long-term memory, RAG pipelines, semantic search, and structured state storage.

**When to enable:**
- Your agent needs long-term memory that survives pod/session restarts
- You are building RAG pipelines that store and retrieve embeddings
- Use cases require structured relational + vector data in the same store

By default, `pgvector` should already be deployed. You can check by running `kubectl get pods -n pgvector`. If not, follow the instructions below to deploy it.

Enable it in `env/<name>/config.agent-toolkit.yaml`:
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

## Step 8 — Agent Sandbox (Sandboxed Code Execution)

Agent Sandbox provides **isolated, ephemeral Kubernetes pods** for safe code execution. Every sandbox is a fully self-contained pod — the agent can run arbitrary code, install packages, and write files without touching the host or other workloads.

By default, Agent Sandbox should already be deployed. You can check by running `kubectl get pods -n agent-sandbox-system`. If not, follow the instructions below to deploy it.

Enable it in `env/<name>/config.agent-toolkit.yaml`:
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

For the full guide — adding custom templates, WarmPools, and SDK usage — see **[agent-sandbox.md](agent-sandbox.md)**.

---

## Adding a Worker Node to a Running Cluster

To expand a running cluster with an additional worker node:

> **Note:** not available in this release. The installer provisions Kubernetes only while `env/<name>/kubeconfig.yaml` does not exist, so list every node in `env/<name>/inventory/hosts.yaml` before the first `./es_auto_installer.sh install agent-toolkit`.

---

## Supported Deployment Topologies

| Topology | Use case |
|---|---|
| Single node (default) | Development, testing, single-server deployments |
| 1 control-plane + N workers | Production — scale inference horizontally |
| 3 control-planes + N workers | HA production — no single point of failure on the control plane |

---

## Notes

- The platform gateway is the `eg-gateway` LoadBalancer Service in `envoy-gateway-system`; MetalLB assigns its address. Point DNS for `*.<base_domain_name>` at that address.
- **Redis** runs as a single `StatefulSet` in the `redis` namespace. It is shared across all agent namespaces but is not clustered by default. For high-availability Redis, configure Redis Cluster or Redis Sentinel via the `charts/redis-stack` chart values.
- **Model weights** are downloaded once into the `model-store` PVC in `llm-inference` and reused by later deploys.
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