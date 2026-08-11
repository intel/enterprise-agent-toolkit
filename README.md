# Intel® AI for Enterprise Agent Toolkit

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://github.com/intel/enterprise-agent-toolkit/blob/main/LICENSE)
[![Platform: Intel Xeon](https://img.shields.io/badge/Platform-Intel%C2%AE%20Xeon%C2%AE-0068B5)](https://www.intel.com/xeon)
[![Deployment: Kubernetes](https://img.shields.io/badge/Deployment-Kubernetes-326CE5)](https://kubernetes.io)
[![Gateway: LiteLLM](https://img.shields.io/badge/Gateway-LiteLLM-green)](https://litellm.ai)
[![Frameworks: LangGraph · CrewAI · Flowise](https://img.shields.io/badge/Frameworks-LangGraph%20%C2%B7%20CrewAI%20%C2%B7%20Flowwise-orange)](https://github.com/intel/enterprise-agent-toolkit)

> **Deploy a production-grade, open source agentic AI stack on Intel® Xeon® in hours — not months.**
> A batteries-included Kubernetes platform with API gateway, intelligent inference routing, agent memory, sandboxed code execution, MCP tool integration, and full agent and system observability — all pre-integrated and ready to run.

**Keywords:** agentic AI platform · enterprise AI agents · open source AI agent stack · Kubernetes AI deployment · LLM inference on CPU · Intel Xeon AI · LiteLLM gateway · AI agent memory RAG · on-premise LLM deployment · private AI infrastructure · AI agent observability · MCP server Kubernetes · vLLM sglang Intel · Enterprise Agnet Toolkit 

---

## Table of Contents

- [Why This Matters](#why-this-matters)
- [Business Value at a Glance](#business-value-at-a-glance)
- [Architecture](#architecture)
- [Provider Design Pattern](#provider-design-pattern)
- [Provider Blocks](#provider-blocks)
  - [API Gateway & Access Control](#api-gateway--access-control)
  - [Intelligent Inference Routing](#intelligent-inference-routing)
  - [Actions & Tools](#actions--tools)
  - [Code Execution & Sandbox](#code-execution--sandbox)
  - [Memory, State & Context](#memory-state--context)
  - [Observability & Telemetry](#observability--telemetry)
  - [Deployment & Orchestration](#deployment--orchestration)
- [Infrastructure Core](#infrastructure-core)
- [Validated Orchestration Frameworks](#validated-orchestration-frameworks)
- [Example Business Use Cases](#example-business-use-cases-not-pre-bundled)
- [Deployment Model](#deployment-model)
- [Build vs. Build-from-Scratch](#build-vs-build-from-scratch)
- [Frequently Asked Questions](#frequently-asked-questions)
- [Repository Structure](#repository-structure)
- [Links](#links)

---

## Why This Matters

AI agents are not just smarter chatbots — they are autonomous systems that plan, act, and iterate across multi-step tasks. Building a production-ready agentic AI platform from scratch requires solving a dozen infrastructure problems simultaneously: secure API access, LLM inference routing, agent memory and state management, sandboxed code execution, LLM observability, and enterprise governance.

Most organizations waste months stitching together LiteLLM, Redis, pgvector, Kubernetes, Langfuse, and agent sandboxes. This open source toolkit delivers them pre-integrated, pre-optimized for Intel® Xeon®, and deployable in a single automated workflow.

**The core insight:** GPUs accelerate reasoning. But the *value* of agentic AI comes from end-to-end task execution — and that control plane (state, tools, policy, coordination) runs efficiently on CPUs. This toolkit is designed around that reality, making it the ideal platform for cost-efficient, on-premise, and private AI deployments.

---

## Business Value at a Glance

| Problem | What the Toolkit Delivers |
|---|---|
| Long time-to-production | One-click Kubernetes deployment — base stack live in hours |
| Integration complexity | All layers pre-integrated: gateway, memory, sandbox, observability |
| Vendor lock-in risk | Provider Design Pattern — swap or extend any component without re-architecting |
| Governance & compliance gaps | Policy-driven API gateway, sandboxed execution, full audit trail |
| GPU cost dependency | CPU-efficient LLM inference by default on Xeon; GPU addable on demand |
| Observability blind spots | Every token, latency, and agent step captured and queryable |
| Adoption friction | Works with LangGraph, CrewAI, Flowise, Microsoft Agent Framework, and any OpenAI-compatible framework |

---

## Architecture

![Intel® AI for Enterprise Agent Toolkit Architecture](docs/pictures/Enterprise-Agent-Toolkit-Arch-Diagram.png)

The toolkit is organized into **seven pluggable provider blocks**, each with a default implementation and a defined interface. Customers can use the defaults on day one and swap or extend individual providers as their needs evolve — without touching any other layer.

---

## Provider Design Pattern

Each functional block in the toolkit follows a **Provider Design Pattern**: the block defines the capability contract (what it does), not the implementation (how it does it). The default provider is Intel-validated and optimized for Xeon out of the box. Any standard-compliant alternative can be substituted.

This means:
- **No big-bang replacements.** Swap one provider at a time.
- **No lock-in.** The toolkit never mandates a proprietary runtime.
- **Incremental adoption.** Start with all defaults; introduce your own components over time.

---

## Provider Blocks

Each functional block ships with an Intel-validated default. Because the toolkit is built on the Provider Design Pattern, any block can be swapped or extended independently — without touching the rest of the stack.

### API Gateway & Access Control
Unified, secure entry point for all agents, tools, and applications. Routes every request through a policy-driven layer that enforces authentication, authorization, and rate limiting before anything reaches a model or tool. Supports any OpenAI-compatible backend — cloud, on-premise, or hybrid.

**Default provider:** LiteLLM

---

### Intelligent Inference Routing
Automatically dispatches LLM inference workloads to the optimal compute target based on task intent. Reasoning and planning tasks are routed to GPU or cloud/MaaS endpoints; execution, encoding, and coordination tasks are routed to CPU on Xeon. Rules are configurable per application and model-agnostic — works with OpenAI, Anthropic Claude, Google Gemini, and any self-hosted model.

**Default provider:** LiteLLM Semantic Router · Intel Native Inferencing Service (vLLM, SGLang)

---

### Actions & Tools
Gives agents the ability to take actions in the world — call APIs, run code, query databases, and invoke external services — through a governed and extensible tool layer. MCP (Model Context Protocol) server templates let teams register domain-specific tools without modifying the core stack.

**Default provider:** Intel MCP (Model Context Protocol) · ETL / Ingestion Services

---

### Code Execution & Sandbox
Enables agents to safely execute code and run arbitrary actions in isolated environments, preventing runaway agents from affecting production systems. Each sandbox is a fully self-contained ephemeral Kubernetes pod with its own filesystem and process tree. Policy controls limit the blast radius of any single agent action.

**Default provider:** `kubernetes-sigs/agent-sandbox`

---

### Memory, State & Context
Maintains agent memory across the full lifecycle — short-term working context within a session and long-term knowledge across sessions and users. Enables RAG (Retrieval-Augmented Generation), semantic search over past interactions, and stateful multi-turn workflows. Agents maintain context across tasks, sessions, and workflows.

**Default provider:** Redis + RediSearch (short-term) · PostgreSQL + pgvector (long-term)

---

### Observability & Telemetry
Every token, latency measurement, and agent step is captured, stored, and queryable. Provides LLM-native tracing for debugging agent reasoning chains, out-of-the-box dashboards, and seamless integration with existing enterprise monitoring infrastructure — no custom instrumentation required.

**Default provider:** Langfuse · Prometheus · Grafana · Loki

---

### Deployment & Orchestration
Manages the full lifecycle of the stack — provisioning, scaling, updates, and teardown — across single-node and multi-node environments. Supports both production Kubernetes clusters and lightweight Docker Compose for development and demos, using the same configuration.

**Default provider:** Kubernetes · Helm · Docker Compose

---

## Infrastructure Core

All provider blocks run on a common infrastructure foundation:

| Layer | Details |
|---|---|
| **Operating System** | Ubuntu 24.04 LTS / RHEL |
| **CPU Configuration** | Intel® Xeon® — NUMA tuning, firmware, drivers, AMX enabled |
| **Compute & Runtime** | Intel® Xeon® · Intel® AI Accelerators · Intel® Arc™ |
| **Supported Model APIs** | OpenAI · Anthropic Claude · Google Gemini · SambaNova · local models via vLLM / SGLang |

---

## Validated Orchestration Frameworks

| Framework | Style |
|---|---|
| **LangGraph** | State-machine, multi-step agent workflows |
| **Flowise** | Low-code visual pipeline builder |
| **CrewAI** | Role-based multi-agent collaboration |
| **OpenClaw** | Intel-optimized agentic framework =Local gateway for multi-agent routing via chat apps |

---

## Example Business Use Cases (Not pre-bundled)

| Use Case | Description |
|---|---|
| **Coding Agent** | Automated code generation, review, test, and fix loops — accelerates developer productivity |
| **Deep Research Agent** | Multi-step web and knowledge base research with citation; replaces hours of analyst work |
| **Flowise Agents** | Low-code visual agent pipeline construction for business teams |
| **Customer Support Automation** | RAG-augmented, multi-turn resolution with memory — reduces ticket handle time |
| **Enterprise Data Analyst** | Natural language to SQL/report across internal databases — self-serve analytics |
| **IT Operations Agent** | Infrastructure monitoring, alerting, and self-healing workflows — reduces MTTR |

---

## Deployment Model

### Deployment Options

| Option | Stack | Best For |
|---|---|---|
| **Multi-node Kubernetes** | Kubespray + Helm + KubeRay (for Parallel Tool Calling) | Production, HA, scale-out |
| **Single-node Kubernetes** | K8s + Helm | Pilot, staging, edge |
| **Docker Compose** | Docker Compose | Development, demos, single machine |


## Deployment Platform

The Agentic AI Stack supports two deployment platforms:

### Kubernetes (Default)

Production-grade orchestration with Helm charts, designed for:
- **Multi-node clusters** 
- **High availability** 
- **Production workloads** 

**Deploy with:**
```bash
./deploy-agentic-stack.sh 
```

See [Kubernetes Deployment](#kubernetes-deployment) below for full setup.

### Docker Compose

Simplified single-node deployment with Docker containers, designed for:
- **Development and testing** 
- **Proof-of-concept** 
- **Resource-constrained environments** (no Kubernetes overhead)


**Deploy with:**
```bash
./deploy-agentic-stack.sh --docker
```

See [`docker/README.md`](docker/README.md) for comprehensive Docker deployment guide, including [Multi-Model Deployment](docker/README.md#multi-model-deployment).

### Decision Tree

| Your Need | Platform | Rationale |
|-----------|----------|-----------|
| Production deployment | Kubernetes | HA, scaling, resource management |
| Multi-node cluster | Kubernetes | Only K8s supports distributed execution |
| Local development | Docker | Faster setup, no K8s overhead |
| Testing multi-model | Docker | Easy config changes, faster iteration |
| CI/CD integration | Docker | Simpler automation, `--skip-confirmation` flag |
| SLA requirements | Kubernetes | Rolling updates, auto-healing, monitoring |
| Learning the stack | Docker | Lower complexity, direct container access |

---

### How to Deploy

### 1. Clone the repository

```bash
git clone https://github.com/intel/enterprise-agent-toolkit.git
cd enterprise-agent-toolkit
```

### 2. Complete prerequisites
Hardware requirements, SSH key setup, and DNS/TLS configuration are covered in **[Prerequisites Guide](docs/prerequisites.md)**.

### 3. Quick Start

The full step-by-step deployment guide — covering the base stack, semantic routing, Redis, pgvector, and Agent Sandbox — is in **[Quick Start Guide](docs/README.md)**.


**Estimated time to first running agent: hours, not months.**

---

## Backend Connection Reference

In-cluster URLs for all shared backends (Redis, Agent Sandbox, pgvector, KubeRay, Flowise). See **[Backend Connection Reference](docs/backend-connection-reference.md)** for the full reference.

---

## Decommission / Reset and Redeploy from Scratch

To tear down the cluster and redeploy from scratch, see **[Decommission and Redeploy Guide](docs/decommission-and-redeploy.md)**.

---

## Build vs. Build-from-Scratch

| Dimension | Build from Scratch | Intel® Toolkit |
|---|---|---|
| Time to production | 3–6 months | Hours to days |
| Vendor lock-in | None | None (Apache 2.0) |
| Component flexibility | Full (you build it) | Full (Provider Pattern) |
| GPU dependency | Your choice | Optional |
| Data residency | Full control | Full control |
| Enterprise governance | You build it | Built-in |
| Intel® Xeon® optimization | Manual | Native |
| Total cost of ownership | High | Low (open source + Xeon) |

---

## Frequently Asked Questions

**What is the Intel® AI for Enterprise Agent Toolkit?**
An open source, Kubernetes-based platform that gives enterprises everything they need to deploy, run, and govern production AI agents on Intel® Xeon® — including LLM gateway, inference routing, agent memory, sandboxed execution, MCP tool integration, and full observability.

**How is this different from LangChain, LangGraph, or CrewAI?**
LangGraph, CrewAI, and similar frameworks handle agent orchestration logic. This toolkit provides the production infrastructure underneath them — the API gateway, inference routing, memory store, sandbox, and observability layer. You use LangGraph or CrewAI *on top of* this toolkit.

**Does it require a GPU?**
No. The toolkit is designed to run AI agent workloads efficiently on Intel® Xeon® CPUs using AMX acceleration. GPU or cloud LLM endpoints (OpenAI, Anthropic, Google) can be added to the same gateway for reasoning-heavy tasks.

**Can I use it with OpenAI, Anthropic Claude, or Google Gemini?**
Yes. The LiteLLM API gateway is fully OpenAI-compatible and supports all major model providers — OpenAI, Anthropic Claude, Google Gemini, SambaNova, and any self-hosted model via vLLM or SGLang.

**Is this suitable for on-premise or air-gapped deployments?**
Yes. The full stack runs on bare metal or private cloud Intel® Xeon® servers with no external dependencies required. Ideal for regulated industries requiring data residency and private AI deployments.

**Can I replace individual components?**
Yes — this is the core design principle. The toolkit is built on the Provider Design Pattern: each block (gateway, memory, observability, etc.) has a default but can be swapped independently without touching other layers.

**What agent frameworks does it support?**
LangGraph, CrewAI, Flowwise, OpenClaw, and any Python-based or OpenAI-compatible orchestration framework.

**How do I get started?**
Clone the repo, run `./deploy-agentic-stack.sh`, and follow the [Quick Start Guide](docs/README.md).


**License:** Apache 2.0 · **Primary languages:** Shell (88%), Jinja (10%), Go Template (2%)

---

## Links

- [GitHub Repository](https://github.com/intel/enterprise-agent-toolkit)
- [Quick Start Guide](docs/README.md)
- [Prerequisites](docs/prerequisites.md)
- [Decommission & Redeploy](docs/decommission-and-redeploy.md)

---

*Intel®, Intel® Xeon®, and Intel® Arc™ are registered trademarks of Intel Corporation or its subsidiaries.*
*Licensed under the Apache License, Version 2.0.*
