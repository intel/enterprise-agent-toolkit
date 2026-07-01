# Profile: `--persistent-agents`

Deploys the Enterprise Agent Toolkit with all components required for
persistent agents as first-class Kubernetes objects.

## Usage

```bash
./deploy-agentic-stack.sh --persistent-agents
```

## What it enables

| Component | Config Toggle | Purpose |
|-----------|---------------|---------|
| Keycloak | `deploy_keycloak=on` | Per-agent identity (SA-per-agent) |
| pgvector | `deploy_pgvector=on` | Per-agent memory isolation (RAG namespaces) |
| Agent Sandbox | `deploy_agent_sandbox=on` | Per-agent isolated execution |
| OpenClaw Operator | `deploy_openclaw=on` | Backend runtime for agent instances |

These are in addition to the base stack (Kubernetes, Ingress, LiteLLM, Redis,
Observability, vLLM models) which is always deployed.

## What stays off (opt-in within profile)

| Component | Toggle | When to enable |
|-----------|--------|----------------|
| KubeRay | `deploy_kuberay=on` | Ray-based distributed agent workloads |
| Agent Operator | `deploy_agent_operator=on` | Stack-level Agent CRD (future — Item 2) |

## Equivalent manual config

Instead of using the flag, set these in `core/inventory/agentic-config.cfg`:

```cfg
deploy_keycloak=on
deploy_pgvector=on
deploy_agent_sandbox=on
deploy_openclaw=on
```

Then run `./deploy-agentic-stack.sh` without the flag.

## After deployment

Deploy an OpenClaw instance manually (requires model endpoint configuration):

```bash
helm install openclaw-enhanced core/helm-charts/openclaw-instance/ \
  --namespace openclaw --create-namespace \
  --set model.id="Qwen/Qwen3-Coder-30B-A3B-Instruct" \
  --set model.baseUrl="http://vllm-qwen3-coder-30b-cpu-service.default.svc.cluster.local:80/v1"
```

## Future additions

As items from the persistent-agents proposal land, this profile will expand to include:
- `deploy_agent_operator=on` — Stack-level `Agent` CRD + facade operator
- `deploy_agent_registry=on` — MCP/tool registry for restart-survival
- `deploy_agent_budget_controller=on` — Per-agent cost enforcement
