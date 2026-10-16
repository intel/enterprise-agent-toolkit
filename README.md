<!-- vale off (due to hyperlinks) -->
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://github.com/intel/enterprise-agent-toolkit/blob/main/LICENSE)
[![Platform: Intel hardware](https://img.shields.io/badge/Platform-Intel%C2%AE%20hardware-0068B5)](https://www.intel.com/content/www/us/en/products/details/processors.html)
[![Deployment: Kubernetes](https://img.shields.io/badge/Deployment-Kubernetes-326CE5)](https://kubernetes.io)
[![Gateway: LiteLLM](https://img.shields.io/badge/Gateway-LiteLLM-green)](https://litellm.ai)
[![Frameworks: LangGraph · CrewAI](https://img.shields.io/badge/Frameworks-LangGraph%20%C2%B7%20CrewAI-orange)](https://github.com/intel/enterprise-agent-toolkit)
<!-- vale on -->

# Intel® Agent Toolkit

**The fast path to deploying AI agents on Intel® Xeon® silicon. Go from bare metal to a working agent stack in minutes.**

> Deploy and connect LLM inference, RAG, and agent workflows in a customizable Kubernetes-based platform, with a GenAI gateway, security, intelligent routing, observability, model serving, and infrastructure automation built in.

---

Teams that want **production AI agents** usually discover that a language-model endpoint is not enough. An agent has to remember a conversation, look up company data, call internal APIs, and sometimes run code it just generated. Doing that on a public cloud API also means prompts and documents leave the premises, and every team rebuilds the same plumbing (memory, sandbox, keys, traces).

Intel® Agent Toolkit is that plumbing, running on Kubernetes on **Intel® hardware** you already operate. [AI Solutions](https://github.com/intel/enterprise-ai-solutions) installs, updates, and tears it down, including the cluster and model serving. Applications keep an **OpenAI-compatible API**. Developers change the base URL and API key; they do not rewrite clients or drop LangGraph, CrewAI, or similar frameworks. Data and weights stay on your hardware. A GPU is not required.

<p align="center">
  <img src="docs/assets/overview.png" alt="Intel® Agent Toolkit. Your agent (LangGraph, CrewAI, OpenClaw, Microsoft Agent Framework) calls an API gateway (LiteLLM, auth, rate limits). The stack provides memory (Redis, PostgreSQL, pgvector), inference and routing (vLLM, SGLang, cloud LLMs), tools and MCP servers, a policy-enforced sandbox (Agent Sandbox, OpenShell), and observability (Langfuse, Prometheus, Grafana). Deployment scales from one node to a rack with Ansible, Helm, and autoscaling, on Kubernetes or Docker Compose, using Intel® Xeon® for orchestration and execution, with GPUs and cloud LLMs for inference.">
</p>

---

## What you get

A default install gives you the components below. Every one of them is configurable: turn it off, change its settings, or bring your own (an existing cluster with `existing_kubernetes`, Keycloak instead of LiteLLM, the models you choose in `models.yaml`). See [Configuration](docs/configuration/configuration.md).

| Component | Implementation | Purpose |
|---|---|---|
| **API gateway** | LiteLLM (or Keycloak in front of the AI gateway) | A single HTTPS URL and key for every model |
| **Model serving** | vLLM on Intel® hardware | The language model the agent calls |
| **Short-term memory** | Redis Stack (with RediSearch) | Session state and recent context |
| **Long-term memory** | PostgreSQL + pgvector | RAG, embeddings, and data that persists across restarts |
| **Code sandbox** | Isolated Kubernetes pods | Execute agent-generated code without access to the host |
| **Observability** | Langfuse + Prometheus / Grafana | Tokens, latency, and each agent step |

Out of the box, Redis, pgvector, and the sandbox are on; each has an `*_enabled` flag to switch it off. KubeRay (distributed Ray jobs) is off until you set `kuberay_enabled: true`.

Agents are written in LangGraph, CrewAI, or any OpenAI-compatible SDK. This repository is the infrastructure those frameworks call; it does not replace them.

---

## Quickstart

Install on a single host and send a first chat request. Run all commands on that host as a non-root user with `sudo`. Step 1 maps the example domain `api.example.com` to the host, so no DNS record or CA-issued certificate is required.

### 1. Prepare the host

Requirements: Ubuntu 22.04 or 24.04 on Intel® Xeon®, 48 cores, 32 GB RAM, 150 GB free disk, and internet access. See [Prerequisites](docs/getting-started/prerequisites.md).

Configure passwordless SSH (the installer uses SSH even on a single node) and map the example domain to the host:

```bash
[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes localhost true && echo "SSH OK"

grep -q "api.example.com" /etc/hosts || \
  echo "127.0.0.1 api.example.com trace-api.example.com" | sudo tee -a /etc/hosts
```

Continue only if the output includes `SSH OK`.

### 2. Install AI Solutions and generate the configuration

```bash
git clone https://github.com/intel/enterprise-ai-solutions.git
cd enterprise-ai-solutions
./es_auto_installer.sh configure                 # one-time: Python venv, yq, kubectl, helm
./es_auto_installer.sh init agent-toolkit        # clones this repo under ext/ and writes env/local/
```

Run the remaining commands from the `enterprise-ai-solutions` directory.

### 3. Set the configuration

`init` writes the configuration to `env/local/`. Change the following values and leave everything else at its default.

| File | Setting | Purpose |
|---|---|---|
| `global_config.yaml` | `base_domain_name: api.example.com` | Gateway hostname. Must match the `/etc/hosts` entry from step 1. |
| `global_config.yaml` | `auth_provider: litellm` | Uses LiteLLM as the gateway. LiteLLM issues the API key used in step 5. The default, `keycloak`, uses a different authentication flow. |
| `config.inference.yaml` | `llm_services_deploy_models: true` | Enables model serving, which is off by default. |
| `models.yaml` | `autodeploy: true` on the existing `qwen3-4b` entry | Serves Qwen3-4B, a small ungated model that runs on CPU. Edit the existing entry; do not add a new one. |

The remaining defaults suit a single host: `gateway_tls_mode: selfsigned` generates the certificate, and `storage_backend: local-path` stores data on the host disk.

### 4. Install

```bash
./es_auto_installer.sh install agent-toolkit
```

The first install takes 20-40 minutes. If it stops, rerun the same command to resume.

### 5. Verify

After the install, the model pod downloads its weights, which takes 10-15 minutes. Wait until it reports `1/1 Running`:

```bash
kubectl get pods -A
```

Retrieve the API key and send a request:

```bash
export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d)

curl -k https://api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "qwen3-4b",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

`/v1/models` lists `qwen3-4b`, and `/v1/chat/completions` returns the reply in `choices[0].message.content`. The `-k` flag is required because the certificate is self-signed.

| Symptom | Resolution |
|---|---|
| `Could not resolve host` | Add the `/etc/hosts` entry from step 1. |
| `401` | `LITELLM_MASTER_KEY` is not set in the current shell. Rerun the `export` command. |
| `model not found` | Use the `id` returned by `/v1/models` as the `"model"` value. |
| `500`, `503`, or a timeout | The model is still loading. Wait for `1/1 Running`, then retry. |

Any OpenAI-compatible SDK connects with the base URL `https://api.example.com/v1` and the master key. For a custom domain and certificate, other models, or field-level detail, see the [single-node quickstart](docs/getting-started/quickstart.md) and [Troubleshooting](docs/faq-and-troubleshooting/troubleshooting.md).

---

## Choose how to run it

The quickstart above installs on one host. For a different layout, pick it from the table.

| Path | Best for | Guide |
|---|---|---|
| **Single node** | First run on one host, or a small pilot | [Single-node quickstart](docs/getting-started/quickstart.md) |
| **Multi-node** | Several hosts: one control-plane node plus worker nodes for extra model pods | [Multi-node](docs/deployment/multi-node.md) |
| **Docker Compose** | Containers on a single Linux host with `docker/deploy.sh` (not installed by `es_auto_installer.sh`) | [Docker](docs/deployment/docker.md) |

---

## Documentation

The technical documentation lives in [`docs/`](docs/README.md). The index is organized by task (meet, get started, deploy, customize, operate, reference). These are the pages most people open first:

- [Docs index](docs/README.md): jump table into the rest of the docs
- [Meet the Agent Toolkit](docs/overview/meet.md): what the toolkit is, how AI Solutions installs it, and what each component is for
- [Prerequisites](docs/getting-started/prerequisites.md): hardware, SSH keys, DNS, and TLS
- [Single-node quickstart](docs/getting-started/quickstart.md): install, confirm pods, send a chat request
- [Configuration](docs/configuration/configuration.md): the YAML files under `env/local/`
- [Routing](docs/configuration/routing.md): virtual model names and Auto Router
- [Guardrails](docs/configuration/guardrails.md): content-safety screening before the main model
- [Backend URLs](docs/reference/backend-connections.md): in-cluster Redis, pgvector, sandbox, and gateway
- [FAQ](docs/faq-and-troubleshooting/frequently-asked-questions.md): short answers to the questions people ask first
- [Troubleshooting](docs/faq-and-troubleshooting/troubleshooting.md): AI Solutions, API, and pod failures
- [Intel® Chatbot Toolkit](https://swcatalog.intel.com/developer/docs/enterprise-rag): related product on the Intel® Software Catalog

> Discover more Intel® AI software on the [Intel® Software Catalog](https://swcatalog.intel.com/).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how AI Solutions installs this repository and how to add a component.

---

## License

Licensed under the [Apache License, Version 2.0](https://github.com/intel/enterprise-agent-toolkit/blob/main/LICENSE).
