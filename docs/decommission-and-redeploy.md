# Decommission and Redeploy — Intel® AI for Enterprise Agent Toolkit

> **Warning:** Decommissioning destroys the entire Kubernetes cluster and all workloads, data, and secrets. It cannot be undone.

## Step 1 — Decommission the cluster

```bash
./es_auto_installer.sh teardown infrastructure
# removes the cluster and everything on it
```

What the decommission does:
- Runs Kubespray's `reset.yml` to remove all Kubernetes components from the node
- Removes all Helm releases and namespaces (`litellm`, `redis`, `monitoring`, etc.)
- Cleans up container images injected into containerd
- Removes the generated `hosts.yaml` inventory
  > **Note:** not available in this release.

> The `env/<name>/global_config.yaml`, `config.agent-toolkit.yaml` and `config.inference.yaml` files are **not** deleted — your settings are preserved for the next run.

## Step 2 — Redeploy from scratch

After decommission completes, set the components you want back to `true` in `env/<name>/global_config.yaml` and `env/<name>/config.agent-toolkit.yaml`, then run:

```bash
# Edit env/<name>/global_config.yaml and env/<name>/config.agent-toolkit.yaml and turn components back on:
#   auth_provider: "litellm"                                (global_config.yaml)
#   observability_enabled: true                             (global_config.yaml)
#   llm_services_autodeploy_models: ["qwen2-5-coder-14b"]   (config.agent-toolkit.yaml)
#   redis_stack_enabled: true                               (config.agent-toolkit.yaml)
#   pgvector_enabled: false                                 (config.agent-toolkit.yaml)

./es_auto_installer.sh install agent-toolkit
```

The script will deploy everything from scratch. Re-running `install agent-toolkit` is idempotent and applies config changes.