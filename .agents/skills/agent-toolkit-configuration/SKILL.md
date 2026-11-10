---
name: agent-toolkit-configuration
description: Find and change Intel Agent Toolkit configuration. Says which file holds a setting (env/<env>/config.agent-toolkit.yaml, global_config.yaml, config.inference.yaml, models.yaml), which file wins when a key is in several, and how a change takes effect (re-run install, litellm_reconcile, or teardown first). Use when the user asks how to turn a component on or off (OpenShell, KubeRay, Redis, pgvector, Agent Sandbox, Kata, guardrail, hybrid router, semantic router), change the default model, sizes, namespaces or the API access mode, or when a changed setting seems to have no effect.
---

# Configure Intel Agent Toolkit

## 1. Use the environment's files

Settings live in `<root>/env/<env>/` (see `AGENTS.md` to find `<root>` and `<env>`). `init` seeds these files once and never overwrites them. Do not edit `config.yaml` in this repo or `<root>/configs/defaults/`; those only seed new environments.

| File | Holds |
|---|---|
| `config.agent-toolkit.yaml` | Toolkit switches and sizes, the default model, and the LiteLLM settings the toolkit needs |
| `global_config.yaml` | Toolkit Manager settings: domain, proxy, TLS, storage, cluster, Kata, `routing_mode` |
| `config.inference.yaml` | Inference-only settings: `vllm_sr_enabled`, KServe, versions |
| `models.yaml` | The model catalog: CPU, memory and server per model |
| `nodes.yaml`, `inventory/hosts.yaml` | Nodes for multi-node and remote installs |

Never edit `.solutions.yaml`, `kubeconfig.yaml` or `kubespray_extra_auto.yml`.

## 2. Know which file wins

The installer passes every file as Ansible extra vars, in this order. A later file wins:

`config.inference.yaml` → `config.agent-toolkit.yaml` → `global_config.yaml` → `nodes.yaml` → `-- -e key=value` on the command line

So:
- A key in `config.agent-toolkit.yaml` overrides the same key in `config.inference.yaml`.
- A key already in `global_config.yaml` (for example `kata_containers_enabled`) cannot be changed from `config.agent-toolkit.yaml`. Change it in `global_config.yaml`.
- Lists **replace** the defaults; they do not merge. When you add to `litellm_allowed_namespaces` or `litellm_public_paths`, keep the existing entries.
- Extra vars beat every role default. Search all the env files before saying a value is "the default": `grep -n '<key>' env/<env>/*.yaml`. Do not grep this way for password or token keys; it prints their values.

## 3. Find the key

`references/toolkit-settings.md` lists every toolkit key, its default, when to change it, and keys that have no effect. Confirm defaults in this repo's `config.yaml` and `roles/<role>/defaults/main.yaml`; for inference keys, in `<root>/ext/enterprise.ai-inference/roles/<role>/defaults/main.yaml`.

| The user wants to... | Key and file |
|---|---|
| Turn on OpenShell | `openshell_enabled: true` (config.agent-toolkit). Needs Agent Sandbox. |
| Turn on KubeRay | `kuberay_enabled: true` (config.agent-toolkit) |
| Use Kata microVMs for sandboxes | `kata_containers_enabled: true`, `kata_runtime: kata-fc\|kata-qemu\|both` (global_config) |
| Change or remove the default model | `llm_services_autodeploy_models` (config.agent-toolkit); `[]` for none |
| Run on a 128 GB node | `llm_services_autodeploy_models: ["qwen2-5-coder-7b"]` before installing |
| Turn the guardrail on or off | `guardrails_enabled` (config.agent-toolkit); see section 4, it needs more than the switch |
| Turn on the semantic router | `vllm_sr_enabled: true` (config.inference) |
| Let another namespace call LiteLLM | add it to `litellm_allowed_namespaces` (config.agent-toolkit), keeping the shipped entries |
| Keep `litellm.<domain>` API-only | `litellm_public_paths: [...]` with API paths only. Main track: the admin UI stays on `litellm-ui.<domain>` behind Keycloak. Release track: a non-empty list also unpublishes the UI (port-forward only). |
| Move Redis or pgvector storage | `redis_stack_storage_class`, `pgvector_storage_class` (before the first install) |
| Set the proxy | `http_proxy`, `https_proxy`, `no_proxy` (global_config) |
| Give a model more CPU or memory | its entry in `models.yaml`, then `./model-manager deploy <name>` |

## 4. Make the change take effect

| Kind of setting | How it applies |
|---|---|
| Toolkit switch turned **on**, toolkit sizes | `./es_auto_installer.sh install agent-toolkit --env <env>` (or `install <component> --only`) |
| Toolkit switch turned **off** | Re-running install removes nothing. Run `teardown <component> --env <env>` **while the switch is still on**, then set it to `false`. If it is already `false`: `teardown <component> -- -e <component>_enabled=true`. |
| `litellm_allowed_namespaces` | Applied on every run: `install litellm --only` |
| Guardrail **on** | `install agent-toolkit` (not `install litellm --only`: the guard model `qwen3guard` is deployed by `llm_services`, and the guardrail blocks every request until it is Ready) |
| Guardrail **off**, main track | The switch alone does not unregister it. Set `false`, then delete the `content_safety` guardrail in the LiteLLM admin UI (Guardrails), with the user's OK. Do not run `litellm_reconcile` before it is deleted: that removes the guard host from LiteLLM's allowed hosts while the fail-closed guardrail is still registered, which blocks every request. |
| Guardrail **off**, release track | `install litellm --only` removes it and restarts LiteLLM |
| Other LiteLLM settings (hybrid router, tier candidates, version) | `install litellm --only -- -e litellm_reconcile=true`. Pass `litellm_reconcile` on the command line only; left `true` in a file, it upgrades LiteLLM on every run. |
| `routing_mode` (main track) | It changes every published URL: gateway, Keycloak, Grafana, LiteLLM. Re-run the full `install agent-toolkit -- -e litellm_reconcile=true`. Treat the change as untested on an installed cluster. |
| Semantic router routes after a new model | `install vllm_sr --only` |
| Model CPU, memory or server | `./model-manager deploy <name>` (from `<root>`) |
| Volume sizes, pgvector database or user names, namespaces | Fixed after the first install. Run `teardown <component>` **with the old value still in place** (it deletes the data; ask first), then change the value, then install. Changing the value first leaves the old release and namespace orphaned. |
| Kata on or off, `kata_runtime` | `install agent-toolkit` applies it on the running cluster (kata-deploy restarts containerd on every node, so ask first). Then the sandbox role adds the Kata template and pool. |
| Storage backend, Kubernetes settings | These are fixed when the cluster is built. They need `teardown kubernetes` and a reinstall, which destroys the cluster; only with the user's explicit OK. |

Install, teardown and model-manager change the cluster. Show the user the command and get an OK first.

## Auth switch

Find the track first (`AGENTS.md`, "Which track the installation is on").

- **Main track:** `auth_type` in `config.agent-toolkit.yaml`.
  - `litellm_vkey` (seeded by `init agent-toolkit`): LiteLLM with virtual keys, guardrail, hybrid router, Langfuse and the OpenShell provider.
  - `jwt`: Keycloak tokens straight to the AI gateway, without any of those.
  - Setting `auth_type` in `config.inference.yaml` has no effect in a toolkit environment, because the toolkit file loads later. The installer's deprecation message and the inference docs say "config.inference.yaml"; that advice is for inference-only environments.
  - An `auth_provider` line in `global_config.yaml` is deprecated. If present it must agree with `auth_type`, otherwise preflight stops; delete it.
  - Switching from `litellm_vkey` to `jwt` after install leaves LiteLLM running. `teardown litellm -- -e litellm_enabled=true` removes it, and also Langfuse, the master key Secret and the `litellm` namespace. Warn the user first.
- **Release track:** `auth_provider: litellm` (or `keycloak`) in `global_config.yaml`. `auth_type` is ignored.

Check which value is in effect: `grep -nE '^(auth_type|auth_provider):' env/<env>/{config.inference,config.agent-toolkit,global_config}.yaml`.
- Main track: the last file that sets `auth_type` wins, and `auth_provider` is only checked for agreement.
- Release track: only `auth_provider` counts.
- The comments seeded into `config.agent-toolkit.yaml` describe the release track ("This release reads auth_provider...").
