<img src="docs copy/assets/banner.jpg" alt="Intel® Agent Toolkit" width="100%">

<!-- vale off (due to hyperlinks) -->
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://github.com/intel/agent-toolkit/blob/main/LICENSE)
[![Platform: Intel hardware](https://img.shields.io/badge/Platform-Intel%C2%AE%20hardware-0068B5)](https://www.intel.com/content/www/us/en/products/details/processors.html)
[![Deployment: Kubernetes](https://img.shields.io/badge/Deployment-Kubernetes-326CE5)](https://kubernetes.io)
[![Gateway: LiteLLM](https://img.shields.io/badge/Gateway-LiteLLM-green)](https://litellm.ai)
[![Frameworks: LangGraph · CrewAI](https://img.shields.io/badge/Frameworks-LangGraph%20%C2%B7%20CrewAI-orange)](https://github.com/intel/agent-toolkit)
<!-- vale on -->

# Intel® Agent Toolkit

**Deploy a production-ready, open source agentic AI stack.**

> A Kubernetes platform with an API gateway, inference routing, agent memory, sandboxed code execution, MCP tools, and observability. Toolkit Manager installs the cluster and the stack. The first run finishes in hours.

---

Teams that want **production AI agents** usually discover that a language-model endpoint is not enough. An agent has to remember a conversation, look up company data, call internal APIs, and sometimes run code it just generated. Doing that on a public cloud API also means prompts and documents leave the premises, and every team rebuilds the same plumbing (memory, sandbox, keys, traces).

Intel® Agent Toolkit is that plumbing, running on Kubernetes on **Intel® hardware** you already operate. [Toolkit Manager](https://github.com/intel/toolkit-manager) installs, updates, and tears it down, including the cluster and model serving. Applications keep an **OpenAI-compatible API**. Developers change the base URL and API key; they do not rewrite clients or drop LangGraph, CrewAI, or similar frameworks. Data and weights stay on your hardware. A GPU is not required.

<p align="center">
  <img src="docs copy/assets/overview.png" alt="Intel® Agent Toolkit. Your agent (LangGraph, CrewAI, OpenClaw, Microsoft Agent Framework) calls an API gateway (LiteLLM, auth, rate limits). The stack provides memory (Redis, PostgreSQL, pgvector), inference and routing (vLLM, SGLang, cloud LLMs), tools and MCP servers, a policy-enforced sandbox (Agent Sandbox, OpenShell), and observability (Langfuse, Prometheus, Grafana). Deployment scales from one node to a rack with Ansible, Helm, and autoscaling, on Kubernetes or Docker Compose, using Intel® Xeon® for orchestration and execution, with GPUs and cloud LLMs for inference.">
</p>

---

## What you get

A default install gives you the components below. Every one of them is configurable: turn it off, change its settings, or bring your own (an existing cluster with `existing_kubernetes`, Keycloak instead of LiteLLM, the models you list in `llm_services_autodeploy_models`). See [Configuration](docs copy/configuration/configuration.md).

| Component | Implementation | Purpose |
|---|---|---|
| **API gateway** | LiteLLM (or Keycloak in front of the AI gateway) | A single HTTPS URL and key for every model |
| **Model serving** | vLLM on Intel® hardware | The language model the agent calls |
| **Short-term memory** | Redis Stack (with RediSearch) | Session state and recent context |
| **Long-term memory** | PostgreSQL + pgvector | RAG, embeddings, and data that persists across restarts |
| **Code sandbox** | Isolated Kubernetes pods | Execute agent-generated code without access to the host |
| **Tools** | MCP server templates | Register APIs and tools the agent can invoke |
| **Observability** | Langfuse + Prometheus / Grafana | Tokens, latency, and each agent step |

Out of the box, Redis, pgvector, and the sandbox are on; each has an `*_enabled` flag to switch it off. MCP templates are installed, but no MCP server runs until you add one. KubeRay (distributed Ray jobs) is off until you set `kuberay_enabled: true`.

Agents are written in LangGraph, CrewAI, or any OpenAI-compatible SDK. This repository is the infrastructure those frameworks call; it does not replace them.

---

## Quickstart

Install on a single host and send a first chat request. Run all commands on that host as a non-root user with `sudo`. The gateway name is `litellm.<base_domain_name>`. With the example domain below, that is `litellm.api.example.com`.

### 1. Prepare the host

Requirements: Ubuntu 22.04 or 24.04, x86_64, 48 cores, 32 GB RAM, 150 GB free disk, and internet access. The default model needs more RAM than 32 GB: a default install requests about 131 GiB. On a 128 GB node, set `llm_services_autodeploy_models` to `qwen2-5-coder-7b` or `llama-3-1-8b` in step 3. See [Prerequisites](docs copy/getting-started/prerequisites.md).

Raise the inotify limits, then configure passwordless SSH (the installer uses SSH even on a single node):

```bash
sudo tee /etc/sysctl.d/90-inotify.conf > /dev/null <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
EOF
sudo sysctl --system

[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes localhost true && echo "SSH OK"
```

Continue only if the output includes `SSH OK`. Add `/etc/hosts` after install, once you have the gateway IP (step 5).

### 2. Install Toolkit Manager and generate the configuration

```bash
git clone -b release-1.2 https://github.com/intel/toolkit-manager.git
cd toolkit-manager
./toolkit_manager.sh configure
./toolkit_manager.sh init agent-toolkit
```

Run the remaining commands from the `toolkit-manager` directory.

### 3. Set the configuration

`init` writes the configuration to `env/local/`. Change these and leave the rest.

| File | Setting | Purpose |
|---|---|---|
| `global_config.yaml` | `base_domain_name: api.example.com` | Domain. The API is `https://litellm.api.example.com`. |
| `global_config.yaml` | `auth_provider: litellm` | LiteLLM gateway. The default written by `init` is already `litellm`. |
| `config.agent-toolkit.yaml` | `llm_services_autodeploy_models: ["qwen2-5-coder-14b"]` | Default chat model. Names must match `models.yaml`. |

`gateway_tls_mode: selfsigned` generates the certificate. `storage_backend: local-path` stores data on this host.

### 4. Install

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx   # only for a gated model (Llama, Gemma)
./toolkit_manager.sh install agent-toolkit
```

The first install takes 20–40 minutes. If it stops, rerun the same command to resume. The model pod can take another 10–15 minutes to download weights.

### 5. Verify

```bash
export KUBECONFIG=$(pwd)/env/local/kubeconfig.yaml
kubectl get nodes
kubectl get pods -A

GW=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
echo "$GW"
grep -q "litellm.api.example.com" /etc/hosts || \
  echo "$GW litellm.api.example.com langfuse.api.example.com" | sudo tee -a /etc/hosts

export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d)

curl -k https://litellm.api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

curl -k https://litellm.api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{"model": "qwen2-5-coder-14b",
       "messages": [{"role": "user", "content": "Write a Python hello world"}],
       "max_tokens": 100}'
```

`/v1/models` lists `qwen2-5-coder-14b`, and `/v1/chat/completions` returns the reply in `choices[0].message.content`. The `-k` flag is required because the certificate is self-signed.

| Symptom | Resolution |
|---|---|
| `Could not resolve host` | The `/etc/hosts` line is missing or uses the wrong IP. Rerun the `GW=` commands. |
| `401` | `LITELLM_MASTER_KEY` is not set in this shell. Rerun the `export`. |
| `model not found` | Use the `id` returned by `/v1/models`. The default id is `qwen2-5-coder-14b`. |
| `500`, `503`, or a timeout | The model is still loading. Wait until its pod is `1/1 Running`, then retry. |
| Pods stuck, `too many open files` | The inotify sysctl from step 1 was not applied on this node. |

Any OpenAI-compatible SDK uses base URL `https://litellm.api.example.com/v1` and that master key. Field-level detail is in the [single-node quickstart](docs copy/getting-started/quickstart.md). Failures: [Troubleshooting](docs copy/faq-and-troubleshooting/troubleshooting.md).

---

## Choose how to run it

| Path | Best for | Guide |
|---|---|---|
| **Single node** | First run on one host | [Single-node quickstart](docs copy/getting-started/quickstart.md) |
| **Multi-node** | One control plane plus workers | [Multi-node](docs copy/deployment/multi-node.md) |
| **Docker Compose** | Containers on one Linux host, without Toolkit Manager | [Docker](docs copy/deployment/docker.md) |

Not in this release: rack-scale networking, Intel® Arc™ (XPU), and the Flowise plugin.

---

## Documentation

The guides written for a first install are in [`docs copy/`](docs copy/README.md). The flat notes those guides were checked against are in [`docs/`](docs/README.md).

- [Docs index](docs copy/README.md)
- [Meet the Agent Toolkit](docs copy/overview/meet.md)
- [Prerequisites](docs copy/getting-started/prerequisites.md)
- [Single-node quickstart](docs copy/getting-started/quickstart.md)
- [Configuration](docs copy/configuration/configuration.md): the YAML files under `env/local/`
- [Routing](docs copy/configuration/routing.md): virtual model names, including the hybrid router
- [Guardrails](docs copy/configuration/guardrails.md): content-safety screening before the main model
- [Backend URLs](docs copy/reference/backend-connections.md): in-cluster Redis, pgvector, sandbox, and gateway
- [FAQ](docs copy/faq-and-troubleshooting/frequently-asked-questions.md): short answers to the questions people ask first
- [Troubleshooting](docs copy/faq-and-troubleshooting/troubleshooting.md): Toolkit Manager, API, and pod failures
- [Intel® Inference Toolkit](https://github.com/intel/inference-toolkit): model serving installed by Toolkit Manager
- [Intel® Chatbot Toolkit](https://swcatalog.intel.com/developer/docs/enterprise-rag): retrieval-augmented chat on the Intel® Software Catalog

> Discover more Intel® AI software on the [Intel® Software Catalog](https://swcatalog.intel.com/).

---

## Contributing

Bug reports, doc fixes, and new components are all welcome. [CONTRIBUTING.md](CONTRIBUTING.md) starts with a table of what to do for each kind of change, then walks through your first pull request.

---

## License

Licensed under the [Apache License, Version 2.0](https://github.com/intel/agent-toolkit/blob/main/LICENSE).
