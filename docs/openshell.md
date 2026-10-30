# NVIDIA OpenShell (Policy-Enforced Sandboxes)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) adds a policy layer on top of
[Agent Sandbox](agent-sandbox.md). Its gateway creates sandboxes as `agents.x-k8s.io`
Sandbox CRs, and a supervisor paired with every sandbox enforces:

- **Egress default-deny** with per-host / per-binary allow rules and L7 (HTTP method/path) policy
- **Filesystem restrictions** (Landlock, best effort: applied where the node kernel supports it) and seccomp
- **Credential isolation** — the sandbox only sees a placeholder; the supervisor injects the
  real credential into requests toward the allowed endpoint

The toolkit registers the **GenAI Gateway** (LiteLLM) as an OpenShell provider, so agents in
OpenShell sandboxes call models through LiteLLM with a dedicated, budgeted virtual key that
never enters the sandbox.

OpenShell is **optional** and **off by default** (`openshell_enabled: false`).

---

## Supported Configuration

| Component | Version |
|---|---|
| OpenShell Helm charts / images | `0.1.6` (`oci://ghcr.io/nvidia/openshell/helm-chart` and `oci://ghcr.io/nvidia/openshell/openshell-workspace`) |
| OpenShell CLI (used by the deployment) | `v0.1.6` GitHub release |
| Workspace mode | `operator`: a workspace is a labeled namespace of the same name |
| Agent Sandbox | `v0.5.0` (`agent_sandbox_enabled: true`) |
| GenAI Gateway | LiteLLM as deployed by `auth_provider: "litellm"` (optional; provider is skipped if absent) |
| User authentication | mTLS client certificate (ClusterIP gateway, reached with `kubectl port-forward`); OIDC optional |
| CNI | Must enforce `NetworkPolicy` (e.g. Calico) |

---

## Architecture

Two different components are called "gateway" in this document:

- **OpenShell gateway** — the OpenShell control plane. It creates and deletes sandboxes and
  stores policies and provider credentials. It does not proxy LLM traffic.
- **GenAI Gateway (LiteLLM)** — the toolkit's existing model proxy (`auth_provider: "litellm"`).
  OpenShell does not deploy its own; sandboxes reach models only through this one.

An **agent** is any program you run inside a sandbox (a custom Python agent, a coding
assistant, a framework app). OpenShell does not ship an agent. Each sandbox is two pods: the
**workload** pod runs the agent, and the **supervisor** pod next to it enforces its policy.
The workload pod can reach only its own supervisor; all of its traffic goes through it.

A **workspace** is a namespace that OpenShell may place sandboxes in. It carries the label
`openshell_operator_namespace_label` and the objects of the `openshell-workspace` chart (the
sandbox ServiceAccount, the gateway's Role and an SSH NetworkPolicy), and its name is the
workspace name (at most 19 characters). The deployment creates one admin workspace,
`openshell-sandboxes`.

Deployment installs the platform once; each agent run then gets its own sandbox, created on
demand with `openshell sandbox create --workspace <name>` (or the gateway API) and removed with
`sandbox delete`.

```
Admin / CI / orchestrator
   │  openshell CLI or API over kubectl port-forward (mTLS client cert)
   ▼
OpenShell gateway  (StatefulSet openshell-0, openshell-system)
   │ 1. creates Sandbox CR              ▲ 3. supervisor fetches policy and provider
   ▼                                    │    credentials (its own sandbox token)
Agent Sandbox controller ── 2. creates pods ─┐
(agent_sandbox_enabled)                      ▼
┌─ workspace namespace (e.g. openshell-sandboxes) ─────────────────────┐
│  workload pod <name>              supervisor pod os-supervisor-<id>  │
│  agent process (your code) ─────► egress / L7 policy, Landlock       │
│  reaches only its supervisor      placeholder → real key             │
└─────────────────────────────────────────────┬────────────────────────┘
                                              │ 4. allowed traffic only
          ┌────────────────────────────┴──────────────────┐
          ▼                                               ▼
GenAI Gateway (LiteLLM, :4000)                   hosts allowed by the sandbox
  virtual key → model backends                   policy (via the corporate proxy)
```

---

## How OpenShell Connects to the Toolkit

### Reused toolkit components

| Toolkit component | Used by OpenShell for | Changed |
|---|---|---|
| Kubernetes cluster | Runs the gateway and sandbox pods | No |
| Agent Sandbox controller `v0.5.0` (`agent_sandbox_enabled`) | Turns OpenShell `Sandbox` CRs into pods | No |
| GenAI Gateway / LiteLLM (`auth_provider: "litellm"`) | The only path from a sandbox to models | One additional virtual key |
| Model backends behind LiteLLM | Reached through LiteLLM only | No |
| Deployment framework (`config.agent-toolkit.yaml`, `es_auto_installer.sh`, Ansible) | Installs and re-runs OpenShell like other components | New `openshell_enabled` switch |
| Proxy settings (`https_proxy`, `no_proxy`) | Sandbox egress is chained through the corporate proxy | No |
| CNI (e.g. Calico) | Enforces OpenShell's per-sandbox NetworkPolicies and the gateway NetworkPolicy | No |

Not used by OpenShell: the Agent Sandbox router, `SandboxTemplate`, `WarmPool` and the
`k8s-agent-sandbox` SDK. OpenShell creates `Sandbox` CRs directly, so both ways of running
sandboxes coexist on the same controller. Fluent Bit does not collect OpenShell policy events
(see [Known Limitations](#known-limitations-016)).

### Added by OpenShell

| Component | Kind | Role |
|---|---|---|
| OpenShell gateway | StatefulSet + Service `openshell:8080` (TLS) | Sandbox lifecycle API, policy and credential store |
| Supervisor | Pod paired with every sandbox | Egress and L7 enforcement, Landlock, seccomp, credential injection |
| `openshell-workspace` chart | Helm release per workspace namespace | Sandbox ServiceAccount, the gateway's Role, SSH NetworkPolicy |
| `openshell` CLI | Binary on the admin host | Administration; used by the playbook to register the provider |
| Provider profile `eat-genai-gateway` (global), provider `genai-gateway` (admin workspace) | Gateway records | LiteLLM host and port, bearer credential, allowed binaries |
| NetworkPolicy `openshell-gateway-ingress` | Added by the toolkit | Only supervisors and listed namespaces reach the gateway port |

### Interfaces

| # | From | To | Interface | Configured by |
|---|---|---|---|---|
| 1 | Admin / CI | OpenShell gateway | gRPC over TLS with the client certificate (secret `openshell-client-tls`), through `kubectl port-forward` | Chart; see [Verification](#verification) |
| 2 | OpenShell gateway | Kubernetes API | Creates `agents.x-k8s.io/v1beta1` `Sandbox` CRs, supervisor pods and per-sandbox NetworkPolicies in labeled workspace namespaces | Chart ClusterRole; `openshell-workspace` chart Role |
| 3 | Agent Sandbox controller | Kubernetes API | Reconciles the CR into the workload pod | Toolkit, unchanged |
| 4 | Supervisor | OpenShell gateway | gRPC over TLS with the sandbox's own token: policy, credentials, events | OpenShell; allowed by `openshell-gateway-ingress` |
| 5 | Agent (workload pod) | Supervisor pod | Port `5500` only; all workload egress passes through the supervisor | OpenShell's per-sandbox NetworkPolicies |
| 6 | Supervisor | LiteLLM `:4000` | OpenAI-compatible HTTP; `Authorization: Bearer <placeholder>` rewritten to the virtual key | Provider profile |
| 7 | Playbook | LiteLLM admin API | `kubectl exec` into the LiteLLM pod, `POST /key/generate` with the in-pod master key → Secret `openshell-genai-key` → provider credential | Playbook |
| 8 | LiteLLM | Model backends | Unchanged; the key's allowed models and budget apply | Toolkit, unchanged |
| 9 | Supervisor | External hosts | Only hosts in the sandbox policy, through the corporate proxy | `--policy` per sandbox; proxy from `global_config.yaml` |

### Where credentials live

| Credential | Location | Visible inside a sandbox |
|---|---|---|
| LiteLLM master key | LiteLLM pod only | No |
| Virtual key `openshell-sandboxes` | Secret `openshell-genai-key` and the OpenShell gateway | No — only a placeholder |
| Client certificate (`openshell-client-tls`) | `openshell-system` only | No. It is the gateway admin credential; workspaces get only the CA certificate |
| Sandbox token | Supervisor pod of that sandbox | No. The workload pod has no ServiceAccount token and cannot read the supervisor's bootstrap files |

---

## Deployed Components

| Component | Kind | Namespace | Notes |
|---|---|---|---|
| `openshell` | StatefulSet + Service (ClusterIP :8080, TLS) | `openshell-system` | Upstream Helm chart with `charts/openshell/values.yaml`, operator workspace mode |
| `openshell-client-tls` | Secret | `openshell-system` | Client certificate: the gateway admin credential |
| `openshell-genai-key` | Secret | `openshell-system` | LiteLLM virtual key minted inside the LiteLLM pod (master key never leaves it) |
| `openshell-gateway-ingress` | NetworkPolicy | `openshell-system` | Gateway port open to sandbox supervisors and `openshell_gateway_client_namespaces` only (see [Network isolation](#network-isolation)) |
| `openshell-sandboxes` | Namespace + `openshell-workspace` release | `openshell-sandboxes` | The admin workspace |
| `eat-genai-gateway` | Provider profile | gateway (global) | LiteLLM endpoint, bearer credential, allowed binaries |
| `genai-gateway` | Provider | admin workspace | Attach to sandboxes with `--workspace openshell-sandboxes --provider genai-gateway` |

---

## Configuration

### Enable in `env/<name>/config.agent-toolkit.yaml`

```yaml
agent_sandbox_enabled: true
openshell_enabled: true
```

`openshell_enabled: true` requires `agent_sandbox_enabled: true` in the same run, or Agent Sandbox
CRDs already present on the cluster; otherwise the deployment exits before installing
anything. On re-runs, resume mode skips OpenShell only if the `openshell_release_name` release
in `openshell_namespace` (as set in `config.agent-toolkit.yaml`) is `deployed` and the last run
completed with the current version pins and settings (see [Deployment](#deployment)).

> **Note:** resume mode is not available in this release.

### Version pins in `env/<name>/config.agent-toolkit.yaml`

```yaml
openshell_chart_version: "0.1.6"
openshell_image_tag: "0.1.6"
openshell_release_tag: "v0.1.6"
```

OpenShell 0.0.x cannot be upgraded in place: delete its sandboxes, uninstall it (see
[Removal](#removal)), then install 0.1.6.

### Settings in `env/<name>/config.agent-toolkit.yaml`

| Variable | Default | Purpose |
|---|---|---|
| `openshell_release_name` | `openshell` | Helm release and gateway Service name |
| `openshell_namespace` | `openshell-system` | Gateway namespace (holds provider credentials) |
| `openshell_sandbox_namespace` | `openshell-sandboxes` | The admin workspace (at most 19 characters) |
| `openshell_operator_namespace_label` | `openshell.ai/workspace=eat` | Label that makes a namespace a workspace |
| `openshell_allow_unauthenticated_clusterip_only` | `false` | Must be set to `true` to accept client-certificate mode (see [Authentication](#authentication)) |
| `openshell_oidc_issuer` / `openshell_oidc_audience` | `""` / `openshell-cli` | OIDC user authentication (alternative to client-certificate mode) |
| `openshell_genai_provider_enabled` | `true` | Register the GenAI Gateway provider |
| `openshell_genai_key_alias` | `openshell-sandboxes` | LiteLLM virtual key alias (spend tracking) |
| `openshell_genai_key_models` | `[]` | Models the key may use (empty = all) |
| `openshell_genai_key_max_budget` | `50` | LiteLLM budget for the key |
| `openshell_cli_dir` | `""` | Where the playbook keeps the CLI; empty = `~/.cache/eat/openshell-cli-<release tag>` (mode `0700`) |
| `openshell_workspace_storage_class` | `""` | StorageClass for sandbox workspace volumes; empty = `local-path` when the cluster has it, else the default class. Multi-node NFS clusters get a non-default `local-path` class for this: seeding a workspace on NFS takes about 16 minutes |
| `openshell_gateway_network_policy` | `true` | Apply `openshell-gateway-ingress` |
| `openshell_gateway_client_namespaces` | `[]` | Namespaces besides the supervisors that may connect to the gateway port |

> **Note:** `openshell_allow_unauthenticated_clusterip_only` is not available in this release.

The corporate proxy (`https_proxy` / `no_proxy` from `global_config.yaml`) is passed to the
gateway, which chains sandbox egress through it.

### Authentication

OpenShell 0.1.6 refuses to start without user authentication. Choose one mode:

- **Client certificate (supported)**: leave `openshell_oidc_issuer` empty (the default).
  The chart's client certificate (`openshell-client-tls`) authenticates as a platform admin.
  The gateway stays `ClusterIP`; only users who can `kubectl port-forward` in
  `openshell-system` and read `openshell-client-tls` can use it.
- **OIDC**: set `openshell_oidc_issuer` (for example a Keycloak realm URL, served over HTTPS).
  Not yet validated with the toolkit.

Sandboxes do not use the client certificate: each supervisor authenticates with its own
sandbox token.

---

## Deployment

```bash
# env/<name>/config.agent-toolkit.yaml
agent_sandbox_enabled: true
openshell_enabled: true
openshell_oidc_issuer: ""   # empty = client certificate via kubectl port-forward

./es_auto_installer.sh install agent-toolkit
```

The `openshell` role runs 4 task groups:

| Task Group | Action |
|---|---|
| 1 | Prerequisites — cluster connectivity, explicit auth mode, Agent Sandbox `v1beta1` API served |
| 2 | Namespaces (the admin workspace labeled), gateway Helm install, `openshell-workspace` release in the admin workspace, gateway NetworkPolicy, gateway rollout |
| 3 | GenAI Gateway provider — mint virtual key; through a temporary port-forward, import the global profile, create the admin workspace and its provider (CLI credentials removed afterwards) |
| 4 | Summary |

Re-running is safe: the virtual key is minted once, the provider profile is updated in place
(running sandboxes pick up changes), and an existing provider is kept.

The last task stores a fingerprint of the version pins, `inference_openshell.yml`,
`charts/openshell/` and the playbook in ConfigMap `openshell-deploy-state`. On the
next `./es_auto_installer.sh install agent-toolkit`, resume mode skips OpenShell only while that fingerprint
matches. To apply a changed pin, setting or provider profile, edit the file and re-run
`./es_auto_installer.sh install agent-toolkit` with `openshell_enabled: true`; a failed or interrupted run is retried
the same way.

> **Note:** the `openshell-deploy-state` fingerprint is not available in this release.

---

## Verification

```bash
kubectl get pods -n openshell-system
# NAME          READY   STATUS    RESTARTS
# openshell-0   1/1     Running   0

kubectl get secret openshell-genai-key -n openshell-system
kubectl get networkpolicy openshell-gateway-ingress -n openshell-system
kubectl get namespace openshell-sandboxes --show-labels   # openshell.ai/workspace=eat
```

### Connect the CLI (admin, control plane)

Install the CLI from the [v0.1.6 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.6), then
write the certificate files before adding the gateway:

```bash
kubectl port-forward -n openshell-system svc/openshell 8080:8080 &
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost

MTLS=${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/eat/mtls
mkdir -p "$MTLS" && chmod 700 "$MTLS"
for k in ca.crt tls.crt tls.key; do
  kubectl get secret openshell-client-tls -n openshell-system \
    -o jsonpath="{.data.${k//./\\.}}" | base64 -d > "$MTLS/$k"
done
chmod 600 "$MTLS"/*

openshell gateway add https://127.0.0.1:8080 --local --name eat
openshell whoami                                   # Provider: mtls
openshell workspace list                           # default, openshell-sandboxes
openshell provider list --workspace openshell-sandboxes
# NAME           TYPE               CREDENTIAL_KEYS  CONFIG_KEYS
# genai-gateway  eat-genai-gateway  1                0
```

If `~/.local/state/openshell/tls` exists, `gateway add --local` copies it over these files;
set `OPENSHELL_LOCAL_TLS_DIR` to an empty directory to prevent that.

> The client certificate grants full control of the gateway. Keep it on the control plane.

### Run a sandbox that calls the GenAI Gateway

The commands below run in the admin workspace. The community image's built-in policy is
rejected by 0.1.6, so always pass `--policy`; this one allows nothing beyond the provider:

```bash
cat > /tmp/deny-all.yaml <<'YAML'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
network_policies: {}
YAML

export OPENSHELL_WORKSPACE=openshell-sandboxes     # or pass --workspace to every command
openshell sandbox create --name demo --provider genai-gateway --policy /tmp/deny-all.yaml --detach \
  --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
  --env OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1

openshell sandbox exec -n demo --no-tty -- sh -c 'echo $OPENAI_API_KEY'
# openshell:resolve:env:..._OPENAI_API_KEY    <- placeholder, not the key

openshell sandbox exec -n demo --no-tty -- sh -c \
  'curl -s $OPENAI_BASE_URL/models -H "Authorization: Bearer $OPENAI_API_KEY"'
# {"data":[{"id":"<model>", ...}]}            <- key injected by the supervisor

openshell sandbox exec -n demo --no-tty -- \
  curl -s -m 10 -o /dev/null -w '%{http_code}\n' https://example.com
# 000                                          <- denied: not allowed by any policy

openshell logs demo --source sandbox | grep DENIED
openshell sandbox delete demo
```

Without `--from`, 0.1.6 uses `nvcr.io/nvidia/base/ubuntu:24.04`, which has no Python or
OpenCode; the examples here use the community image above. Pass `--from <image>` for your own
agent image, and `--policy <file>` to allow additional endpoints (see the
[OpenShell policy reference](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/how-it-works/policies/schema.mdx)).

---

## Run OpenCode (coding agent) in a sandbox

[OpenCode](https://opencode.ai) is preinstalled in the community sandbox image
(`ghcr.io/nvidia/openshell-community/sandboxes/base`). It runs entirely
inside the sandbox and reaches the model only through the `genai-gateway` provider — so the
LiteLLM key never enters the sandbox, and every other outbound connection stays denied. This
reuses the same sandbox setup as above; you only add a small OpenCode config, then start its TUI.

Pick a `MODEL` your GenAI Gateway serves that supports tool calling (from the `/models` list above).

### 1. Create the sandbox and add a minimal OpenCode config

```bash
MODEL=<your-deployed-model>          # a tool-calling model your GenAI Gateway serves

# Deny-all network policy: the sandbox's ONLY egress is the genai-gateway provider endpoint.
# The community image's own policy is rejected by 0.1.6, so a policy is required. Filesystem and
# landlock are applied at startup, so this MUST be passed to `sandbox create` (it cannot be
# changed later with `policy set`).
cat > /tmp/opencode-policy.yaml <<'YAML'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
network_policies: {}
YAML

openshell sandbox create --workspace openshell-sandboxes --name opencode --provider genai-gateway \
  --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
  --policy /tmp/opencode-policy.yaml --detach \
  --env OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1

# OpenCode talks to the GenAI Gateway using the sandbox's injected env (placeholder key).
openshell sandbox exec --workspace openshell-sandboxes -n opencode --no-tty -- sh -c 'mkdir -p ~/.config/opencode && cat > ~/.config/opencode/opencode.json' <<JSON
{ "\$schema": "https://opencode.ai/config.json",
  "model": "gw/$MODEL",
  "provider": { "gw": { "npm": "@ai-sdk/openai-compatible",
    "options": { "baseURL": "{env:OPENAI_BASE_URL}", "apiKey": "{env:OPENAI_API_KEY}" },
    "models": { "$MODEL": { "tool_call": true } } } },
  "autoupdate": false, "share": "disabled", "formatter": false, "tools": { "webfetch": false } }
JSON
```

### 2. Open the OpenCode TUI and try two prompts

```bash
openshell sandbox exec --workspace openshell-sandboxes -n opencode --tty -- bash -lc \
  'export OPENCODE_DISABLE_DEFAULT_PLUGINS=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
     OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_SHARE=1
   cd /sandbox && exec opencode'
```

In the TUI, enter these one at a time:

1. **Works:** `Write Python that prints the first 10 Fibonacci numbers, save it as fib.py and run it.`
   OpenCode writes the file and runs it; the model call goes out through the GenAI Gateway.
2. **Blocked by the sandbox:** `Install the pandas package with pip and create a small report.`
   `pip install` fails with `No matching distribution found` — the deny-all policy allows only
   the gateway, so the supervisor refuses even the DNS lookup for PyPI. OpenCode reports the failure. (`pandas` is not in the
   community image; if you use another package, pick one that isn't preinstalled, or `pip` needs
   no download and succeeds.)

OpenCode also tries to reach `opencode.ai` and `registry.npmjs.org` at startup;
`openshell logs --workspace openshell-sandboxes opencode` shows those connections as `DENIED`. It is harmless.

Quit with `ctrl+c`, then clean up:

```bash
openshell sandbox delete --workspace openshell-sandboxes opencode
```

> In the community image, `opencode` is a Node launcher that starts the bundled executable
> `/usr/lib/node_modules/opencode-ai/bin/.opencode`, which makes the model calls. That path is
> allowlisted in the `genai-gateway` provider profile
> (`charts/openshell/genai-gateway-provider.yaml` in the agent toolkit, `ext/enterprise.agent-toolkit/` in the
> enterprise-ai-solutions checkout). If a
> model call returns `binary ... not allowed in policy '_provider_genai_gateway'`, add OpenCode's
> resolved binary path there and re-run the deployment (or `openshell provider profile update`).

---

## End-to-End Example: Restricted Agent

**Scenario:** an LLM agent that runs arbitrary shell commands chosen by the model. It may read
from the GitHub API and call models through the GenAI Gateway, and nothing else: it cannot
write to GitHub, cannot send data to other hosts, and never sees the LiteLLM key.

The example uses the community image and a standard-library-only Python agent, so no
image build is needed. Commands use the admin workspace (`export OPENSHELL_WORKSPACE=openshell-sandboxes`). Run it on the control plane after
[connecting the CLI](#connect-the-cli-admin-control-plane).

### 1. Write the sandbox policy

`github-readonly.yaml` allows `curl` to reach `api.github.com` with read-only methods. The
GenAI Gateway endpoint is added by the `genai-gateway` provider, so it is not listed here.

```yaml
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/bin, /usr, /lib, /proc, /dev/urandom, /etc, /var/log]
  read_write: [/tmp, /dev/null]
landlock:
  compatibility: best_effort
network_policies:
  github_api:
    name: github-api-readonly
    endpoints:
      - host: api.github.com
        port: 443
        protocol: rest
        enforcement: enforce
        access: read-only
    binaries:
      - path: /usr/bin/curl
```

### 2. Write the agent

`agent.py` gives the model one tool, `run_shell`, and loops until the model answers without
a tool call:

```python
"""Minimal tool-calling agent: the LLM gets one tool that runs shell commands in the sandbox."""
import json, os, re, subprocess, sys, urllib.request

MODEL = os.environ["MODEL"]  # a model id from GET /v1/models
# Tool output goes into the next LLM request; keep credential placeholders out of the
# model's context, so redact them.
PLACEHOLDER = re.compile(r"openshell:resolve:env:[A-Za-z0-9_]+")
TOOLS = [{"type": "function", "function": {
    "name": "run_shell", "description": "Run a bash command and return its output.",
    "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}}}]


def chat(messages):
    req = urllib.request.Request(
        os.environ["OPENAI_BASE_URL"] + "/chat/completions",
        json.dumps({"model": MODEL, "messages": messages, "tools": TOOLS}).encode(),
        {"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"], "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))["choices"][0]["message"]


def run_shell(cmd):
    p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)
    return PLACEHOLDER.sub("[credential]", f"exit={p.returncode}\n{p.stdout}{p.stderr}")[-2000:]


messages = [{"role": "system", "content": "You are an agent in a Linux sandbox. Use run_shell (curl is "
             "available). Run each step once. If a step fails, report the error and move on; do not try workarounds."},
            {"role": "user", "content": sys.argv[1]}]
for _ in range(10):
    msg = chat(messages)
    messages.append({k: v for k, v in msg.items() if v is not None})
    if not msg.get("tool_calls"):
        print("[final]", msg.get("content"))
        break
    for call in msg["tool_calls"]:
        cmd = json.loads(call["function"]["arguments"])["cmd"]
        out = run_shell(cmd)
        print(f"$ {cmd}\n{out[:300]}\n")
        messages.append({"role": "tool", "tool_call_id": call["id"], "content": out})
```

### 3. Create the sandbox

```bash
openshell sandbox create --name agent-demo --provider genai-gateway \
  --from ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
  --policy github-readonly.yaml --upload agent.py:/sandbox/agent.py --detach \
  --env OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1 \
  --env MODEL=<model-id>

openshell sandbox get agent-demo
# Phase: Ready
```

Use a model id returned by `GET /v1/models` (see
[Run a sandbox that calls the GenAI Gateway](#run-a-sandbox-that-calls-the-genai-gateway)).

### 4. Run the agent

```bash
openshell sandbox exec -n agent-demo --no-tty -- python3 /sandbox/agent.py \
  '1) Get the tag name of the latest NVIDIA/OpenShell release from https://api.github.com/repos/NVIDIA/OpenShell/releases/latest.
   2) POST the tag name to https://httpbin.org/post.
   3) Create a gist: curl -s -o /dev/null -w "%{http_code}" -X POST https://api.github.com/gists -d "{}".
   Then summarize which steps worked.'
```

Output (abridged; the model chooses the exact commands):

```
$ curl -s https://api.github.com/repos/NVIDIA/OpenShell/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4
exit=0
v0.1.6

$ curl -s -X POST https://httpbin.org/post -d "tag_name=v0.1.6"
exit=7

$ curl -s -o /dev/null -w "%{http_code}" -X POST https://api.github.com/gists -d "{}"
exit=0
403

[final] Step 1: completed ... Step 2: failed due to network/access restrictions ... Step 3: returned 403 ...
```

| Agent action | Result | Enforced by |
|---|---|---|
| Chat completions to the GenAI Gateway | Allowed; spend recorded on the `openshell-sandboxes` key | Provider, credential injection |
| `GET api.github.com/repos/...` | Allowed | `github_api` policy, `read-only` access |
| `POST httpbin.org/post` | Blocked (`curl` exit 7: the DNS lookup is refused) | Egress default-deny |
| `POST api.github.com/gists` | Blocked (HTTP 403) | L7 rule: `POST` not permitted by `read-only` |
| `echo $OPENAI_API_KEY` | Placeholder only | Credential isolation |

### 5. Check the policy decisions

The model may guess why a step failed (for example, it may attribute the 403 to missing GitHub
authentication). The sandbox log records the actual decision:

```bash
openshell logs agent-demo --source sandbox | grep DENIED
# ... NET:REFUSE [MED] DENIED httpbin.org [reason:policy_dns_ineligible]
# ... NET:OPEN [MED] DENIED /usr/bin/curl(426) -> httpbin.org:443 [reason:transparent_tcp_policy_denied]
# ... HTTP:POST [MED] DENIED POST https://api.github.com/gists [policy:github_api engine:l7]
#     [reason:L7_REQUEST deny POST api.github.com:443/gists reason=POST /gists not permitted by policy]
```

### 6. Clean up

```bash
openshell sandbox delete agent-demo
```

---

## Network isolation

OpenShell creates the sandbox NetworkPolicies itself:

- **Workload pods** (`openshell.ai/boundary-role: workload`) accept traffic only from their
  supervisor and send traffic only to it, on port `5500`.
- **Supervisor pods** may send anywhere at the Kubernetes level; the sandbox policy they
  enforce is what limits the agent's egress.
- **SSH** (`openshell sandbox connect`/`exec`) reaches sandbox pods only from the gateway
  (`openshell-workspace` chart).

The toolkit adds `openshell-gateway-ingress` on the gateway. In 0.1.x client certificates are
optional on the gateway port and only the RPCs check identity, while sandbox service routes
(`openshell service expose`) do no authentication: anything that can connect to the port
reaches every exposed sandbox service. The policy admits only sandbox supervisors and the
namespaces in `openshell_gateway_client_namespaces`. `kubectl port-forward` enters through the
kubelet, which NetworkPolicy does not filter, so admin access keeps working.

---

## Known Limitations (0.1.6)

- **Sandbox service routes are unauthenticated.** Whoever can connect to the gateway port can
  call any service exposed with `openshell service expose`, and services see no caller
  identity. Keep `openshell_gateway_network_policy` on, and authenticate in the service itself.
- **Credential placeholders in request bodies reach the model as plain text.** The supervisor
  injects the real key into the `Authorization` header only; a placeholder an agent copies into
  a request body (for example `env` output in its LLM context) is sent as-is. Redact
  `openshell:resolve:env:*` from tool output anyway.
- **Community image policies are rejected.** Sandboxes from images whose built-in policy uses
  the 0.0.x format stay in `ConfigurationInvalid` unless `--policy` is passed.
- **No `**` in binary paths.** A provider profile or policy whose binaries contain `**` leaves
  every sandbox that uses it in `ConfigurationInvalid`; use `*` within one path segment.
- **Workspace names are at most 19 characters**, because they become part of service
  hostnames.
- **Policy decisions are not in the pod logs.** Read them with `openshell logs <sandbox>`;
  Fluent Bit does not collect them.
- **`kubectl exec` bypasses the sandbox policy.** In the workload pod it skips Landlock (its
  network stays limited to the supervisor); the supervisor pod holds the sandbox's token and
  has unrestricted egress. Restrict `pods/exec` in workspace namespaces with Kubernetes RBAC.
- **NetworkPolicy enforcement depends on the CNI.** Some CNIs (for example kindnet) do not block
  traffic from a pod to its own node, such as the API server on a single-node cluster.

---

## Removal

The toolkit has no per-component uninstall. To remove OpenShell from a running cluster, set
`openshell_enabled: false` in `config.agent-toolkit.yaml` (so a later run does not reinstall it), then run
these steps on the control plane. They use the default names; if you changed them in
`config.agent-toolkit.yaml`, use yours.

```bash
# 1. Delete the sandboxes (with the CLI connected, see Verification), in every workspace
openshell workspace list
openshell sandbox list --workspace <workspace>
openshell sandbox delete --workspace <workspace> <name>

# 2. Uninstall both releases, then delete both namespaces. helm uninstall keeps the gateway
#    database PVC and the credential-encryption key Secret; deleting the namespaces removes
#    them, together with the Secrets and the NetworkPolicy the playbook created.
helm uninstall openshell-workspace -n openshell-sandboxes --wait
helm uninstall openshell -n openshell-system --wait
kubectl delete namespace openshell-sandboxes openshell-system

# 3. Revoke the LiteLLM virtual key (runs in the LiteLLM pod, which holds the master key)
kubectl exec -n litellm deploy/litellm -c litellm -- python -c '
import os, urllib.request
req = urllib.request.Request("http://127.0.0.1:4000/key/delete",
    b"{\"key_aliases\": [\"openshell-sandboxes\"]}",
    {"Authorization": "Bearer " + os.environ["PROXY_MASTER_KEY"], "Content-Type": "application/json"})
print(urllib.request.urlopen(req).read().decode())'

# 4. Admin host: `gateway remove` keeps the client certificate files, so delete them too,
#    and the CLI the playbook downloaded
openshell gateway remove eat
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/eat" ~/.cache/eat/openshell-cli-v0.1.6
```

---

## Troubleshooting

```bash
kubectl get pods -n openshell-system
kubectl logs -n openshell-system statefulset/openshell
kubectl get sandbox,pods -n openshell-sandboxes
openshell sandbox get --workspace openshell-sandboxes <sandbox>   # conditions explain Error
openshell logs --workspace openshell-sandboxes <sandbox> --source sandbox
```

| Symptom | Cause / Fix |
|---|---|
| `openshell \| Check Agent Sandbox API is served (agent_sandbox)` fails | Enable Agent Sandbox in the same run |
| `OpenShell on Kubernetes authenticates users via OIDC only` | Choose an auth mode in `config.agent-toolkit.yaml` |
| LLM call returns `policy_denied` | The calling binary is not in the provider profile `binaries` list (`charts/openshell/genai-gateway-provider.yaml` in the agent toolkit); edit it and re-run `./es_auto_installer.sh install agent-toolkit` with `openshell_enabled: true` |
| `transport error` / `Connection reset by peer`, or `--upload` fails with `ssh tar extract exited with status 255` | `kubectl port-forward` dropped a stream; retry the command (re-run `openshell sandbox upload <name> <file> <dest>` for a failed upload), and restart the port-forward if it exited |
| CLI hangs | Make sure `NO_PROXY` includes `127.0.0.1`, so the CLI does not send gateway traffic through a proxy |
| Sandbox in `Error` with `ConfigurationInvalid` (`Image policy is invalid`) | No policy reached the supervisor: pass `--policy`, and check that no attached provider profile lists a `**` binary path |
| `Unknown gateway 'eat'` after `gateway add` | The certificate files were missing when the gateway was added; write them first (see [Connect the CLI](#connect-the-cli-admin-control-plane)), then re-run `gateway add` |
| `sandbox create` fails for a workspace | The namespace must exist, carry `openshell_operator_namespace_label`, have the `openshell-workspace` release, and be registered with `openshell workspace create --name <namespace>` |

---

## Configuration Files

- **Role**: `roles/openshell/tasks/install.yaml`
- **Variables**: `roles/openshell/defaults/main.yaml` (override them in `env/<name>/config.agent-toolkit.yaml`)
- **Helm overlay**: `charts/openshell/values.yaml`
- **Provider profile**: `charts/openshell/genai-gateway-provider.yaml`

---

## References

- [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)
- [OpenShell v0.1.6 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.6)
- [Upgrading from 0.0.x](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/upgrade/0-1-0.mdx)
- [Agent Sandbox in this toolkit](agent-sandbox.md)
