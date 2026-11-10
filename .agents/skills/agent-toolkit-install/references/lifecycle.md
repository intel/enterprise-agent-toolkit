# Install, verify, update and remove

All commands run from the Toolkit Manager root. `--env <env>` defaults to `local`.

## Commands

| Goal | Command |
|---|---|
| Full install, or re-apply settings (safe to re-run) | `./es_auto_installer.sh install agent-toolkit --env <env>` |
| Only the toolkit layer, without the layers below or the dependency pull | `./es_auto_installer.sh install agent-toolkit --only --env <env>` |
| One component | `./es_auto_installer.sh install <component> --only --env <env>` (`redis_stack`, `pgvector`, `agent_sandbox`, `openshell`, `kuberay`, `keycloak_agent_config`, `litellm`, `vllm_sr`, ...) |
| Skip some components or layers | `--skip a,b` |
| Pass a variable for one run (wins over every file) | `... -- -e key=value` |
| Check health | `./es_auto_installer.sh validate agent-toolkit --env <env>` (add `--only` for the toolkit layer alone) |
| Show nodes, pods and URLs | `./es_auto_installer.sh status --env <env>` |
| List components and layers | `./es_auto_installer.sh show` |
| Verbose output | `ES_LOG_LEVEL=debug ./es_auto_installer.sh ...` |
| Node readiness report (main track; runs with sudo, may write `env/<env>/kubespray_extra.yml`) | `.venv/bin/ansible-playbook -i env/<env>/inventory/hosts.yaml ext/enterprise.agent-toolkit/playbooks/preflight-check.yml` (add `-K` if sudo needs a password) |

`./es_auto_installer.sh --help` lists the actions and flags of the installed version.

Logs: `env/<env>/logs/<action>-<target>-<timestamp>.log`, one per run, newest 30 kept.

## How long it takes

Observed in validation runs (single node, behind a proxy); expect variation with hardware and network.

| Operation | Observed time |
|---|---|
| Fresh `install agent-toolkit`, everything on, single node | 41-57 minutes |
| Two nodes on NFS | 52-57 minutes |
| Re-run with nothing changed | 5-8 minutes |
| `validate`, per layer | 12-95 seconds |
| One model deploy | 2-6 minutes; large models up to 20 minutes to load |
| `teardown kubernetes` / `teardown infrastructure` | 3-4 / 6-11 minutes |

`FAILED - RETRYING: ... (N retries left)` lines are polling. A run is stuck only when the log has not grown for longer than the longest wait in progress (`tail -f` the log).

## After install

1. `./es_auto_installer.sh validate agent-toolkit --env <env>`. If the install log warned that a model `did not become Ready`, wait until `kubectl get llminferenceservices -n llm-inference` shows it Ready, then validate again.
2. The read-only health checks in the agent-toolkit-troubleshoot skill (step 1), for what `validate` does not cover: restarting pods, mesh labels, the gateway address and client name resolution.
3. Client access: map these names under `.<base_domain_name>` to the gateway IP:
   - always: `litellm`, `langfuse`, `grafana`
   - main track: also `litellm-ui` and `keycloak`
   - with KubeRay: `ray`; with the semantic router: `vllm-sr`

   `kubectl get httproute -A -o jsonpath='{range .items[*]}{.spec.hostnames}{"\n"}{end}' | sort -u` lists every published host. Trust `env/<env>/logs/ai-solutions-ca.crt`. See the agent-toolkit-troubleshoot skill (`references/network.md`) for the exact commands.
4. Wire agents: agent-toolkit-components skill.

## Re-running install

- Re-running is the way to resume after a fix. Completed steps are skipped.
- LiteLLM is skipped when its release exists. Apply LiteLLM changes with `-- -e litellm_reconcile=true`.
- Helm-based platform components (cert-manager, Istio, Envoy Gateway, Keycloak, observability, CloudNativePG) are also skipped when their release exists, and they have no reconcile switch. Changing them means a teardown of that component and a reinstall (agent-toolkit-configuration skill, "Make the change take effect").
- A healthy re-run keeps the router token, the Redis and pgvector passwords and the OpenShell key.

## Teardown: what each target removes

| Target | Removes | Keeps |
|---|---|---|
| `teardown <component>` (for example `openshell`) | That component and the toolkit components that depend on it (`agent_sandbox` also removes `openshell`) | Everything else |
| `teardown agent-toolkit` | The toolkit components and their namespaces, in reverse order | The inference layer: models, LiteLLM, **virtual keys and spend**, guardrail, routers. LiteLLM's access policy still lists the toolkit namespaces. Also the Kata runtime, the env files, the KubeRay CRDs and the OpenShell CLI cache on the installer host. |
| `teardown inference` | Inference **and** the toolkit, including LiteLLM, its master key Secret and Langfuse | Platform and Kubernetes (virtual keys stay in the platform database) |
| `teardown platform` | Platform, inference and toolkit. **Deletes every platform database**, including LiteLLM keys and spend, and Langfuse traces. | Kubernetes |
| `teardown kubernetes`, `teardown infrastructure` | The whole cluster (Kubespray reset) and `env/<env>/kubeconfig.yaml` | Env files. Local volume data in `/opt/local-path-provisioner` (model weights included) unless the version purges it. |

Rules:
- Teardown asks for confirmation. Without a terminal it needs `--force`; add it only with the user's explicit OK.
- Only components that are switched **on** are torn down. To remove one that is switched off: `teardown <component> -- -e <component>_enabled=true`.
- A toolkit teardown deletes the component namespaces and their volumes. Redis data, pgvector data and every toolkit credential are gone, and new ones are generated on reinstall.
- Wait until `kubectl get ns` no longer shows the namespaces `Terminating` before reinstalling.
- On SSH or multi-node installs, `teardown kubernetes` deletes `/usr/local/bin/kubectl` and `helm`. Run `configure` again afterwards.

## Updating

- **Settings:** edit `env/<env>/` files and re-run install (agent-toolkit-configuration skill).
- **Toolkit or inference code.** Ask the user before each step; they change checkouts.
  1. Update Toolkit Manager itself: `git -C <root> pull`. This can change the branches it pins in `configs/repos/repos.agent-toolkit.yaml`.
  2. If a pin changed, `./es_auto_installer.sh init agent-toolkit --upgrade --env <env>` moves `ext/` to the new revision. It skips repos whose pin is unchanged (it prints `nothing to re-pin`), refuses if `ext/` has local changes, and reports new config keys without adding them.
  3. For newer commits on an unchanged branch: `git -C <root>/ext/<repo> pull --ff-only`.
  4. Compare the env files with this repo's `config.yaml` for new keys, then re-run install.
- **In-place upgrade from toolkit 1.1.0 (the classic `deploy-agentic-stack.sh` layout)** has not been tested. Install fresh.

## Record for support

```bash
git -C <root> log -1 --oneline; git -C <root> branch --show-current
git -C <root>/ext/enterprise.agent-toolkit log -1 --oneline
git -C <root>/ext/enterprise.ai-inference log -1 --oneline
```

The installer banner's version number is not enough. The pins are branches, so a fresh clone can get different code on different days, while an existing `ext/` stays where it was.
