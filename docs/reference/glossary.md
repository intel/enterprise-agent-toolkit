# Glossary

[← Docs index](../README.md)

Terms that appear across these guides. If a page uses a word without explaining it, the definition is here.

## Agent

A program that calls a language model, then takes actions (run code, call a tool, search memory) and uses the result to continue. A single chat completion is not an agent; the loop of model → action → model is. See [Meet the Agent Toolkit](../overview/meet.md#what-is-an-agent-in-this-stack).

## Agent toolkit

This repository: Redis, pgvector, the sandbox, MCP, and optional KubeRay, plus the Kubernetes and model-serving pieces a full install brings up with them. [Stack Manager](../overview/meet.md#which-repository-to-start-from) clones it into `ext/` and installs, updates, and tears it down. Start at [Meet the Agent Toolkit](../overview/meet.md).

## Autodeploy

A flag on a model entry in `env/local/models.yaml`. `autodeploy: true` means the installer will serve that model. `false` (the default) leaves it in the catalog but does not start a pod. Catalog table: [Choose a model](../getting-started/quickstart.md#3-choose-a-model). Fields: [Configuration](../configuration/configuration.md#modelsyaml).

## Base domain (`base_domain_name`)

The hostname of the gateway, for example `api.example.com`. Other UIs are subdomains of it (`trace-api.example.com` for Langfuse). Set it in `env/local/global_config.yaml`. It must match DNS or `/etc/hosts` and the TLS certificate. See [DNS and TLS](../getting-started/prerequisites.md#2-dns-and-tls).

## Host

The machine you install on: a physical server or a virtual machine with Intel® hardware. On the first-run path that is **one host**, and Kubernetes treats it as the only node. See the [single-node quickstart](../getting-started/quickstart.md).

## Node

A host that has joined the Kubernetes cluster. A single-node install is one host. A multi-node install is several hosts, split into a control-plane node and worker nodes. See [multi-node deployment](../deployment/multi-node.md).

## Gateway

The HTTPS front door your application calls. In `auth_provider: litellm` mode that is LiteLLM. It speaks the OpenAI API: `/v1/chat/completions`, `/v1/models`, and so on. URLs and the master key: [Backend connection reference](backend-connections.md).

## Gated model

A Hugging Face model you cannot download until you accept its license and pass a token. Llama and Gemma are gated. Qwen3-4B is not. Set `HF_TOKEN` in the environment before `install` if you need one. See [Hugging Face token](../configuration/configuration.md#hugging-face-token).

## Idempotent install

Running `./stack-manager install agent-toolkit` again does not start from scratch. Toolkit components that are already installed are skipped: the check is whether the release exists, not whether it is healthy. Use it to resume a failed run. A changed setting for Redis, pgvector, the sandbox, or KubeRay does not take effect on a re-run: see [Decommission and redeploy](../deployment/decommission.md). See the [single-node quickstart](../getting-started/quickstart.md#4-install).

## Inference layer

Model serving (vLLM) and the gateway. The toolkit needs it. You get it automatically when you `install agent-toolkit`. See [What install brings up](../overview/meet.md#what-install-brings-up).

## Init

`./stack-manager init agent-toolkit` copies default YAML into `env/local/` (or `env/<name>/`). Edit those files. Do not edit the copies inside this git repo as your live config. See [Which repository to start from](../overview/meet.md#which-repository-to-start-from).

## Langfuse

The tracing UI. Every LLM call is stored: prompt, completion, tokens, latency, which model ran. Default URL: `https://trace-<base_domain_name>`. Connection notes: [Backend connection reference](backend-connections.md).

## LiteLLM

Open-source proxy that presents many model backends as one OpenAI-compatible API. In this stack it is the gateway and the place where routers and guardrails register. See [Routing](../configuration/routing.md) and [Guardrails](../configuration/guardrails.md).

## Master key

The LiteLLM admin token. Stored in the Kubernetes secret `litellm-master-key` in namespace `litellm`. Your first `curl` uses this key. Do not put it in git. How to read it: [Backend connection reference](backend-connections.md) and [FAQ: Where is the API key?](../faq-and-troubleshooting/frequently-asked-questions.md#api-key).

## MCP (Model Context Protocol)

A standard for attaching tools (APIs, databases, files) to an agent. This stack ships a template chart. Nothing is deployed until you add entries to `mcp_servers_list`. Field list: [Configuration](../configuration/configuration.md#configagent-toolkityaml).

## pgvector

A PostgreSQL extension that stores embedding vectors next to ordinary rows. Used here as long-term agent memory and for RAG. URL: [Backend connection reference](backend-connections.md). Related product: [Intel® Chatbot Toolkit](https://swcatalog.intel.com/developer/docs/enterprise-rag).

## Platform layer

Kubernetes, storage, mesh, identity, Prometheus / Grafana. Installed first. You need it before inference or the toolkit can run. See [What install brings up](../overview/meet.md#what-install-brings-up).

## Provider block

One capability (gateway, memory, sandbox, …) with a default implementation you can replace later. You can run all defaults. You do not have to swap anything. See [Meet the Agent Toolkit](../overview/meet.md#toolkit-components).

## RAG (Retrieval-Augmented Generation)

Look up relevant text from a store (here: pgvector), then put it in the prompt so the model answers from your data. This toolkit provides pgvector. The full product is separate: [Intel® Chatbot Toolkit](https://swcatalog.intel.com/developer/docs/enterprise-rag).

## Stack Manager

Stack Manager installs, updates, and tears down Intel® Agent Toolkit. Clone [that repository](https://github.com/intel/enterprise-ai-solutions) and run commands from its root. `init agent-toolkit` clones this repository under `ext/`. See [Which repository to start from](../overview/meet.md#which-repository-to-start-from).

## Sandbox

A short-lived Kubernetes pod where the agent runs code. Isolated filesystem and network. Default template is a Python runtime. Guide: [Agent sandbox](agent-sandbox.md). URL: [Backend connection reference](backend-connections.md#agent-sandbox).

## Routing

Optional. The application calls a virtual model name; the stack selects which deployed model serves the request. Not required for the first chat completion. See [Routing](../configuration/routing.md) and the [hybrid router](../configuration/hybrid-router.md).

## vLLM

The engine that loads the model and serves tokens. It runs on Intel® hardware in this stack. You do not call vLLM directly; you call the gateway. See [Backend connection reference](backend-connections.md).

## Related pages

- [Docs index](../README.md)
- [Meet the Agent Toolkit](../overview/meet.md)
- [FAQ](../faq-and-troubleshooting/frequently-asked-questions.md)
- [Configuration](../configuration/configuration.md)
