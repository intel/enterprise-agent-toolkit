# Quick Start — Intel® AI for Enterprise Agent Toolkit


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
| Agent Sandbox | Isolated, ephemeral pods for agent code execution, with templates, WarmPools and an SDK | [Agent Sandbox Guide](agent-sandbox.md) |
| OpenShell (optional) | NVIDIA OpenShell `0.0.116` on top of Agent Sandbox: per-sandbox egress and filesystem policy, GenAI Gateway key kept out of the sandbox. Off by default; validated in single-admin mode | [OpenShell Guide](openshell.md) |
