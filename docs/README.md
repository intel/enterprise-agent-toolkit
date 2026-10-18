# Quick Start — Intel® AI for Enterprise Agent Toolkit


> **Installing this release.** The Agent Toolkit installs through the [Intel® AI for Enterprise Solutions](https://github.com/intel/enterprise-ai-solutions) installer. Run the commands in these docs from an `enterprise-ai-solutions` checkout:
>
> ```bash
> git clone https://github.com/intel/enterprise-ai-solutions.git && cd enterprise-ai-solutions
> ./es_auto_installer.sh configure
> ./es_auto_installer.sh init agent-toolkit       # creates env/local/
> ./es_auto_installer.sh install agent-toolkit
> export KUBECONFIG=$PWD/env/local/kubeconfig.yaml   # the kubectl commands in these docs use it
> ```
>
> The `agentic-config.cfg` switches these docs mention are settings in `env/<name>/`:
>
> | Classic switch | Setting | File |
> |---|---|---|
> | `deploy_agent_sandbox`, `deploy_redis`, `deploy_pgvector` | `agent_sandbox_enabled`, `redis_stack_enabled`, `pgvector_enabled` (on) | `config.agent-toolkit.yaml` |
> | `deploy_openshell`, `deploy_kuberay` | `openshell_enabled`, `kuberay_enabled` (off) | `config.agent-toolkit.yaml` |
> | `deploy_genai_gateway`, `deploy_guardrails` | `auth_provider: "litellm"` (set by `init agent-toolkit`); `guardrails_enabled` | `global_config.yaml`; `config.agent-toolkit.yaml` |
> | `deploy_vllm_sr` | `vllm_sr_enabled` | `config.inference.yaml` |
> | `deploy_kata_containers` | `kata_containers_enabled`, `kata_runtime` | `global_config.yaml` |
> | `deploy_llm_models`, `models=` | `llm_services_autodeploy_models`; `./model-manager deploy <name>` | `config.agent-toolkit.yaml` |
> | `deploy_istio`, `deploy_observability`, `deploy_ceph`, `deploy_kubernetes_fresh` | `istio_enabled`, `observability_enabled`, `storage_backend`, `existing_kubernetes` | `global_config.yaml` |
>
> Remove the toolkit with `./es_auto_installer.sh teardown agent-toolkit`, or the whole cluster with `teardown infrastructure`. Not in this release: the Flowise plugin, Intel® Arc™ (XPU) deployment and rack-scale networking.

## Prerequisites
Complete all [prerequisites](./prerequisites.md).

## Deployment Options

| Deployment Option | Description | Guide |
|---|---|---|
| Single Node | Quick start for testing or lightweight workloads on a single Intel® Xeon® server | [Single Node Guide](single-node-deployment.md) |
| Single Master, Multiple Workers | For higher throughput workloads with one control-plane and N worker nodes | [Multi-Node Guide](multi-node-deployment.md) |
| Docker Compose | Simplified single-node deployment for development, demos, and resource-constrained environments | [Docker Guide](../docker/README.md) |

## Feature Guides

| Feature | Description | Guide |
|---|---|---|
| Hybrid Router | Complexity-aware, cost/latency-optimizing inference routing for the GenAI Gateway | [Hybrid Router Guide](hybrid-router.md) |
| Intel® Arc™ (XPU) GPU | Deploy vLLM models on Intel discrete GPUs (Arc/Flex/Max, incl. Battlemage) via `compute_platform=xpu`. **Note:** not available in this release. | [Intel Arc XPU Guide](intel-arc-xpu-deployment.md) |
| Stack Validation | Post-deploy health checks, preflight node readiness, burn tests, and traffic-light reporting | [Validate Stack Guide](validate-stack.md) |
| Claw (persistent OpenClaw agents) | Isolated, long-lived OpenClaw agents with memory, tools, a browser console and a REST API, with an end-to-end walkthrough. Disabled by default (`claw_enabled`) | [Claw Guide](claw.md) · [Walkthrough](claw-e2e.md) |
