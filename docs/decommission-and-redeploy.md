# Decommission and Redeploy — Intel® Agent Toolkit

> **Warning:** Decommissioning destroys the entire Kubernetes cluster and all workloads, data, and secrets. It cannot be undone.

## Step 1 — Decommission via the interactive menu

```bash
./deploy-agentic-stack.sh --menu
# Select option 2 — "Decommission Existing Cluster"
# Confirm the prompt — this runs the full cluster purge playbook
```

What the decommission does:
- Runs Kubespray's `reset.yml` to remove all Kubernetes components from the node
- Removes all Helm releases and namespaces (`genai-gateway`, `redis`, `observability`, etc.)
- Cleans up container images injected into containerd
- Removes the generated `hosts.yaml` inventory

> The `core/inventory/agentic-config.cfg` file is **not** deleted — your settings are preserved for the next run.

## Step 2 — Redeploy from scratch

After decommission completes, set the components you want back to `on` in `agentic-config.cfg`, then run:

```bash
# Edit core/inventory/agentic-config.cfg and turn components back on:
#   deploy_kubernetes_fresh=on
#   deploy_ingress_controller=on
#   deploy_genai_gateway=on
#   deploy_observability=on
#   deploy_llm_models=on
#   deploy_redis=on
#   deploy_pgvector=off

./deploy-agentic-stack.sh
```

The script will deploy everything from scratch. Components are automatically set to `off` in the config once deployed, so subsequent re-runs skip already-running components.