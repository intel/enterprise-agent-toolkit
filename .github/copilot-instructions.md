# Copilot instructions: Intel® Agent Toolkit

This repo is the agent layer of Toolkit Manager (`intel/enterprise-ai-solutions`). Toolkit Manager clones it into `ext/enterprise.agent-toolkit/` and installs it with `./es_auto_installer.sh install agent-toolkit`, run from the Toolkit Manager root.

Components:
- LiteLLM (OpenAI-compatible endpoint, virtual keys, guardrail)
- Redis Stack and pgvector (memory)
- Agent Sandbox (code execution, optionally in Kata microVMs)
- OpenShell (policy-enforced sandboxes)
- KubeRay
- Langfuse

When helping a user:
- **Settings** live in the environment's files, `env/<env>/config.agent-toolkit.yaml` and `global_config.yaml`, not in this repo's `config.yaml`. `global_config.yaml` loads after the layer files and wins over them.
- **Cluster access:** `export KUBECONFIG=<root>/env/<env>/kubeconfig.yaml`. Logs are in `<root>/env/<env>/logs/`.
- **Diagnose read-only first** with `kubectl get`, `describe` and `logs`, and the newest log in `<root>/env/<env>/logs/`. The agent-toolkit-troubleshoot skill lists the checks.
- **Never print secret values.** Name the Secret and key instead.
- **Ask before** install, teardown, `init`, git operations in `ext/`, `helm`, `kubectl apply|create|delete|patch|edit|scale|rollout|label|annotate|exec`, `./model-manager deploy|undeploy`, or edits to `env/` files.
- **Warn and get explicit confirmation before** any of these:
  - `teardown platform` deletes every database, including LiteLLM keys.
  - `teardown inference`, `teardown kubernetes` and `teardown infrastructure` remove everything above them; the last two remove the whole cluster.
  - `teardown agent-toolkit` or a toolkit component deletes its data and credentials.
  - `./model-manager undeploy all` also removes the guard model.
- **Toolkit services are in an Istio ambient mesh.** A pod outside the mesh, or not allowed by LiteLLM, gets a connection reset, not an error.
- **Agent Sandbox pods can reach public IP addresses only.** Cluster services, cluster DNS and proxies on private addresses are blocked, by design.

Full guidance: `AGENTS.md`. Detailed skills: `.agents/skills/agent-toolkit-{install,configuration,components,troubleshoot}/SKILL.md` (read the one that fits the task).
