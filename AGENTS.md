# AGENTS.md: Intel® Agent Toolkit

Guidance for AI coding assistants (GitHub Copilot, Claude Code, Codex, Cursor and others) helping people install, use and debug Intel® Agent Toolkit. People can read it too; the user documentation is in `README.md` and `docs/`.

## What this repository is

The agent layer of **Toolkit Manager** (`intel/enterprise-ai-solutions`). It is not installed on its own. Toolkit Manager clones it into `ext/enterprise.agent-toolkit/` and installs it with `./es_auto_installer.sh install agent-toolkit`, together with the layers it depends on: infrastructure → platform → inference → agent-toolkit.

| Path | Contents |
|---|---|
| `components.yaml` | The layer's components, their enable switches and order |
| `config.yaml` | Defaults. `init agent-toolkit` copies it to `env/<env>/config.agent-toolkit.yaml`, which is the file to edit |
| `roles/<component>/` | Ansible roles; each has `install`, `teardown` and `validate` task files |
| `charts/` | Helm charts the roles install |
| `playbooks/preflight-check.yml` | Node readiness report. It runs at the start of `install` on the release track only. |
| `docs/` | User documentation (some pages disagree with the code; see `agent-toolkit-troubleshoot`) |
| `docker/` | A Docker Compose variant, not covered here |

## What each component is for

| Component | Use it for | Switch (default) | Namespace |
|---|---|---|---|
| LiteLLM (inference layer) | One OpenAI-compatible endpoint, virtual keys per agent, budgets, guardrail, tracing | `auth_type: litellm_vkey` (see tracks below) | `litellm` |
| `redis_stack` | Short-term memory: sessions, checkpoints, semantic cache, vector search | `redis_stack_enabled` (on) | `redis` |
| `pgvector` | Long-term memory, RAG vectors, agent event log | `pgvector_enabled` (on) | `pgvector` |
| `agent_sandbox` | Run model-written code in throwaway pods, optionally in Kata microVMs | `agent_sandbox_enabled` (on) | `agent-sandbox-system` |
| `openshell` | Sandboxes with policy-controlled egress; the LLM key never enters the sandbox | `openshell_enabled` (off) | `openshell-system` |
| `kuberay` | Fan out tool calls and parallel work with Ray | `kuberay_enabled` (off) | `ray-system` |
| `keycloak_agent_config` | OIDC realm `agent-toolkit` for agents and apps | `keycloak_agent_config_enabled` (on wherever Keycloak runs) | `keycloak` |
| Kata Containers (infrastructure) | MicroVM isolation for sandboxes | `kata_containers_enabled` (off), in `global_config.yaml` | `kube-system` |
| Langfuse (inference layer) | A trace of every LiteLLM call, with no code change | on with LiteLLM | `langfuse` |
| Grafana, OpenTelemetry (platform) | Metrics, logs and OTLP traces from your agents | `observability_enabled` (on) | `monitoring` |

## Find the installation before doing anything

1. **Toolkit Manager root.** If `../../es_auto_installer.sh` exists, this repo sits inside a Toolkit Manager checkout, and its root is `../..`. If `./es_auto_installer.sh` exists, you are already at the root and this repo is `ext/enterprise.agent-toolkit/`. Otherwise this is a standalone clone. Ask whether the user already has a Toolkit Manager checkout and use its path as `<root>`; if not, use the `agent-toolkit-install` skill.
2. **Environment.** Each directory under `<root>/env/` is one environment (`local` unless `--env` was used at `init`). Ask which one if there are several.
3. **Cluster access.** `export KUBECONFIG=<root>/env/<env>/kubeconfig.yaml`. On a bring-your-own cluster, the user's own kubeconfig is used instead.
4. **Settings.** Edit the files in `<root>/env/<env>/`, never the copies in this repo or in `configs/defaults/`. The installer loads `global_config.yaml` after the `config.<layer>.yaml` files, so it wins when a key is in both (only `nodes.yaml` and `-- -e` on the command line load later).
5. **Logs.** `<root>/env/<env>/logs/<action>-<target>-<timestamp>.log`. Read the newest one first.

Run every `./es_auto_installer.sh` and `./model-manager` command from the Toolkit Manager root. With more than one environment, prefix model-manager with `ES_ENV=<env>`.

## Which track the installation is on

The toolkit code is the same on both tracks, but the Toolkit Manager and inference layer around it differ. Check before giving instructions:
- `git -C <root> branch --show-current`
- `ls <root>/playbooks/includes/agent_toolkit_preflight.yaml` (exists only on the release track)

| | Main track (Toolkit Manager `main`) | Release track (Toolkit Manager `release-1.2`) |
|---|---|---|
| API access switch | `auth_type: litellm_vkey` in `env/<env>/config.agent-toolkit.yaml` | `auth_provider: litellm` in `env/<env>/global_config.yaml`; `auth_type` is ignored |
| Keycloak | Installed by default; the `agent-toolkit` realm is created | Not installed in LiteLLM mode |
| LiteLLM admin UI | `https://litellm-ui.<base_domain_name>/ui/` (path mode: `https://<base_domain_name>/litellm/ui/`), Keycloak sign-in as `platform-admin` (first password in Secret `platform-bootstrap-admin`, key `value`, namespace `keycloak`) | `https://litellm.<base_domain_name>/ui/`, user `admin`, password = the master key |
| Node readiness report | Not run by `install`; run `playbooks/preflight-check.yml` by hand (`agent-toolkit-install`, step 5) | Runs at the start of `install`; output in `env/<env>/logs/health-report-latest.*` |
| model-manager | `list`, `deploy`, `undeploy`, `--hfid` | `deploy`, `undeploy` |
| URL layout | `routing_mode: subdomain` (default) or `path` in `global_config.yaml` | Subdomains only |

The docs in `docs/` were written for the release track. On the main track, apply the differences above.

## Rules for assistants

- **Never show secret values** (keys, passwords, tokens, kubeconfig contents, certificates) in chat, files or logs. Name the Secret and key instead. When a command needs one, read it into a shell variable in the same command and do not echo it.
- **Diagnose read-only first**: `kubectl get`, `describe`, `logs`, `auth can-i`; `helm list` and `status`; reading files under `env/`. The agent-toolkit-troubleshoot skill lists the checks to run.
- **Ask the user before changing anything**:
  - `install`, `teardown`, `init` (including `--upgrade`), and `git` operations in `<root>` or `ext/`
  - `helm`, and `kubectl apply|create|delete|patch|edit|scale|rollout|label|annotate|exec`
  - `./model-manager deploy|undeploy`
  - edits to `env/` files
  - `playbooks/preflight-check.yml` (it can write `env/<env>/kubespray_extra.yml`)
- **Warn and get explicit confirmation** before:
  - `teardown platform`, `teardown inference`, `teardown kubernetes` or `teardown infrastructure`. These remove everything above them, and platform teardown deletes every database, including LiteLLM keys and spend.
  - `./model-manager undeploy all`, which also removes the guard model so that every LiteLLM request is blocked.
  - `teardown agent-toolkit` or `teardown redis_stack|pgvector|agent_sandbox|openshell|kuberay`. These delete the component's namespace, data and credentials.
  - Deleting PVCs or toolkit namespaces (data loss).
- **Hand interactive steps to the user.** `./es_auto_installer.sh configure` and password prompts from `sudo` need a terminal; tell the user what to run. `teardown` asks for confirmation; only add `--force` when the user asked for it.
- **`-- --check` is not a dry run**. Parts of the install run for real.
- **Trust the code over the docs.** When they disagree, check `roles/`, `config.yaml` and `components.yaml`, and tell the user which doc is wrong.
- **Check facts that change between versions in the checkout itself**: the installer's commands (`./es_auto_installer.sh --help`), which repos and branches it pins (`<root>/configs/repos/repos.agent-toolkit.yaml`), and the auth switch in `env/<env>/config.agent-toolkit.yaml`.

## Skills

The skills live in `.agents/skills/`, the shared location of the open Agent Skills format. Copilot, Cursor, Antigravity, Gemini CLI, Codex and Junie load them from there automatically. If your assistant does not list them (for example Claude Code or Cline), open the `SKILL.md` that fits the task before answering, and follow it.

| Skill | Use it to | Path |
|---|---|---|
| `agent-toolkit-install` | Check prerequisites, install, upgrade or remove the toolkit | `.agents/skills/agent-toolkit-install/SKILL.md` |
| `agent-toolkit-configuration` | Find which file and key controls something, and how a change takes effect | `.agents/skills/agent-toolkit-configuration/SKILL.md` |
| `agent-toolkit-components` | Connect agent code to LiteLLM, Redis, pgvector, Agent Sandbox, OpenShell, Ray and tracing | `.agents/skills/agent-toolkit-components/SKILL.md` |
| `agent-toolkit-troubleshoot` | Diagnose a failed install, a broken component or an agent error | `.agents/skills/agent-toolkit-troubleshoot/SKILL.md` |

## Working on this repository

- Roles follow one pattern: `tasks/main.yaml` includes `install.yaml`, `teardown.yaml` or `validate.yaml`; only install is gated on the enable switch. Defaults live in `roles/<role>/defaults/main.yaml`; user-facing ones are also listed in `config.yaml`.
- CI runs ansible-lint, ShellCheck, Checkov, Bandit and Trivy on pull requests.
- Sign off commits (`git commit -s`).
- Changing a default, a switch, a Secret name, a namespace or an error message changes what users see. Update the matching skill under `.agents/skills/` in the same pull request.
