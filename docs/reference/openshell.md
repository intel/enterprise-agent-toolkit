# OpenShell

[← Docs index](../README.md)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) adds a policy layer on top of the [agent sandbox](agent-sandbox.md). Its gateway creates sandboxes as `agents.x-k8s.io` Sandbox custom resources. A supervisor inside every sandbox enforces:

- Egress default-deny, with per-host and per-binary allow rules, and HTTP method and path policy
- Filesystem restrictions (Landlock, where the node kernel provides it) and seccomp
- Credential isolation: the sandbox sees a placeholder. The supervisor injects the real credential on requests to the allowed endpoint

The install registers LiteLLM as an OpenShell provider named `genai-gateway`. Agents in OpenShell sandboxes call models through LiteLLM with a budgeted virtual key. That key never enters the sandbox.

OpenShell is off by default (`openshell_enabled: false`). It needs `agent_sandbox_enabled: true`.

## Supported configuration

| Component | Version |
|---|---|
| OpenShell Helm chart and images | `0.1.6` (`oci://ghcr.io/nvidia/openshell/helm-chart`) |
| OpenShell CLI | `v0.1.6` GitHub release |
| Agent sandbox | `v0.5.0` (`agent_sandbox_enabled: true`) |
| Model proxy | LiteLLM when `auth_provider: "litellm"`. The provider step is skipped when LiteLLM is absent |
| User authentication | Single-admin mode. The gateway is ClusterIP. Kubernetes RBAC gates access |
| CNI | A CNI that enforces `NetworkPolicy` (Calico does) |

### Upgrading from OpenShell 0.0.x

OpenShell 0.1.0 changed the install. Before you run this deployment against an existing 0.0.x installation, follow the upstream [0.1.0 upgrade guide](https://docs.nvidia.com/openshell/v0.1.6/upgrade/0-1-0). Back up the gateway database and the credential-encryption material. Match the gateway, driver, supervisor, CLI, and SDK versions. Remove and recreate existing sandboxes. Preserve or re-import provider profiles and credentials. Changing the version pin alone does not migrate a 0.0.x install.

## Architecture

Two components in this page are called a gateway:

- **OpenShell gateway.** The OpenShell control plane. It creates and deletes sandboxes and stores policies and provider credentials. It does not proxy model traffic.
- **LiteLLM.** The toolkit's model proxy (`auth_provider: "litellm"`). OpenShell does not deploy a second one. Sandboxes reach models only through LiteLLM.

An agent is any program you run inside a sandbox. OpenShell does not ship an agent. The supervisor is the OpenShell process in the same pod. It enforces the policy.

The install brings the platform up once. Each run then gets its own sandbox, created with `openshell sandbox create` (or the gateway API) and removed with `sandbox delete`.

```
Admin / CI / orchestrator
   │  openshell CLI or API over kubectl port-forward (mTLS client cert)
   ▼
OpenShell gateway  (StatefulSet openshell-0, openshell-system)
   │ 1. creates Sandbox CR              ▲ 3. supervisor fetches policy and
   ▼                                    │    provider credentials (mTLS)
Agent Sandbox controller ── 2. creates pod ──┐
(agent_sandbox_enabled)                      ▼
┌─ sandbox pod default--<name> (openshell-sandboxes) ─────────┐
│  agent process (your code)  ──►  OpenShell supervisor       │
│                                  egress / L7 policy, Landlock│
│                                  placeholder → real key      │
└──────────────────────────────────────┬──────────────────────┘
                                       │ 4. allowed traffic only
          ┌────────────────────────────┴──────────────────┐
          ▼                                               ▼
LiteLLM (:4000)                                  hosts allowed by the sandbox
  virtual key → model backends                   policy (via the corporate proxy)
```

## How OpenShell connects to the toolkit

### Reused components

| Component | Used for | Changed |
|---|---|---|
| Kubernetes cluster | Gateway and sandbox pods | No |
| Agent sandbox controller `v0.5.0` | Turns OpenShell `Sandbox` resources into pods | No |
| LiteLLM (`auth_provider: "litellm"`) | The only path from a sandbox to models | One additional virtual key |
| Model backends behind LiteLLM | Reached through LiteLLM only | No |
| Toolkit Manager (`config.agent-toolkit.yaml`, `./toolkit_manager.sh`) | Installs and re-runs OpenShell | New `openshell_enabled` switch |
| Proxy settings (`https_proxy`, `no_proxy`) | Sandbox egress is chained through the corporate proxy | No |
| CNI (Calico) | Enforces the sandbox NetworkPolicy | No |

OpenShell does not use the agent-sandbox router, `SandboxTemplate`, `WarmPool`, or the `k8s-agent-sandbox` SDK. It creates `Sandbox` resources directly, so both ways of running sandboxes share the same controller. For the Fluent Bit limitation on legacy 0.0.116 deployments, see [Legacy 0.0.116 limitations](#legacy-00116-limitations).

### Added by OpenShell

| Component | Kind | Role |
|---|---|---|
| OpenShell gateway | StatefulSet + Service `openshell:8080` (mTLS) | Sandbox lifecycle API, policy and credential store |
| Supervisor | Process in every sandbox pod | Egress and HTTP enforcement, Landlock, seccomp, credential injection |
| `openshell` CLI | Binary on the admin host | Administration. The playbook uses it to register the provider |
| Provider `genai-gateway` (profile `eat-genai-gateway`) | Gateway record | LiteLLM host and port, bearer credential, allowed binaries |
| NetworkPolicy `eat-openshell-sandbox-pods` | Added by the toolkit | Pod-level network limits under the supervisor |

### Interfaces

| # | From | To | Interface | Configured by |
|---|---|---|---|---|
| 1 | Admin / CI | OpenShell gateway | gRPC over mTLS through `kubectl port-forward` (secret `openshell-client-tls`) | Chart. See [Verification](#verification) |
| 2 | OpenShell gateway | Kubernetes API | Creates `agents.x-k8s.io/v1beta1` `Sandbox` resources in `openshell-sandboxes` | Chart RBAC |
| 3 | Agent sandbox controller | Kubernetes API | Reconciles the resource into a pod | Toolkit, unchanged |
| 4 | Supervisor | OpenShell gateway | gRPC over mTLS: policy, credentials, events | Playbook copies the client TLS secret into the sandbox namespace |
| 5 | Agent | Supervisor | All pod egress passes through the supervisor | OpenShell |
| 6 | Supervisor | LiteLLM `:4000` | OpenAI-compatible HTTP. `Authorization: Bearer <placeholder>` is rewritten to the virtual key | Provider profile. `providers_v2_enabled=true` (playbook) |
| 7 | Playbook | LiteLLM admin API | `kubectl exec` into the LiteLLM pod, `POST /key/generate` with the in-pod master key, then Secret `openshell-genai-key` | Playbook |
| 8 | LiteLLM | Model backends | Unchanged. The key's allowed models and budget apply | Toolkit, unchanged |
| 9 | Supervisor | External hosts | Only hosts in the sandbox policy, through the corporate proxy | `--policy` per sandbox. Proxy from `global_config.yaml` |

### Where credentials live

| Credential | Location | Visible inside a sandbox |
|---|---|---|
| LiteLLM master key | LiteLLM pod only | No |
| Virtual key `openshell-sandboxes` | Secret `openshell-genai-key` and the OpenShell gateway | No. The sandbox sees a placeholder |
| Client certificate (`openshell-client-tls`) | `openshell-system` and `openshell-sandboxes` | Mounted for the supervisor. It grants gateway admin, so restrict `pods/exec` |

## Deployed components

| Component | Kind | Namespace | Notes |
|---|---|---|---|
| `openshell` | StatefulSet + Service (ClusterIP :8080, mTLS) | `openshell-system` | Upstream Helm chart with `charts/openshell/values.yaml` |
| `openshell-client-tls` | Secret | `openshell-system`, `openshell-sandboxes` | Client mTLS bundle. Copied into the sandbox namespace |
| `openshell-genai-key` | Secret | `openshell-system` | LiteLLM virtual key minted inside the LiteLLM pod |
| `eat-genai-gateway` | Provider profile | gateway | LiteLLM endpoint, bearer credential, allowed binaries |
| `genai-gateway` | Provider | gateway | Attach with `--provider genai-gateway` |
| `eat-openshell-sandbox-pods` | NetworkPolicy | `openshell-sandboxes` | Pod-level limits for sandbox pods |

## Configuration

In `env/local/config.agent-toolkit.yaml`:

```yaml
agent_sandbox_enabled: true
openshell_enabled: true
```

`openshell_enabled: true` requires `agent_sandbox_enabled: true` in the same run, or agent-sandbox CRDs already on the cluster. Otherwise the deployment exits before it installs anything.

Resume mode, which would skip OpenShell when the release is already `deployed` at the current pins, is not available in this release. Re-run `./toolkit_manager.sh install agent-toolkit` to apply a change.

### Version pins

```yaml
openshell_chart_version: "0.1.6"
openshell_image_tag: "0.1.6"
openshell_release_tag: "v0.1.6"
```

### Settings

| Variable | Default | Purpose |
|---|---|---|
| `openshell_release_name` | `openshell` | Helm release and gateway Service name |
| `openshell_namespace` | `openshell-system` | Gateway namespace. Holds provider credentials |
| `openshell_sandbox_namespace` | `openshell-sandboxes` | Sandbox pods |
| `openshell_allow_unauthenticated_clusterip_only` | `false` | Set `true` to accept single-admin mode. This setting is not available in this release |
| `openshell_oidc_issuer` / `openshell_oidc_audience` | `""` / `openshell-cli` | OIDC user authentication, as an alternative to single-admin mode |
| `openshell_genai_provider_enabled` | `true` | Register the LiteLLM provider |
| `openshell_genai_key_alias` | `openshell-sandboxes` | LiteLLM virtual key alias, used for spend tracking |
| `openshell_genai_key_models` | `[]` | Models the key may use. Empty means all |
| `openshell_genai_key_max_budget` | `50` | LiteLLM budget for the key |
| `openshell_cli_dir` | `""` | Where the playbook keeps the CLI. Empty means `~/.cache/eat/openshell-cli-<release tag>` (mode `0700`) |
| `openshell_workspace_storage_class` | `""` | StorageClass for sandbox workspace volumes. Empty means `local-path` when the cluster has it, otherwise the default class. Multi-node NFS clusters get a non-default `local-path` class for this. Seeding a workspace on NFS takes about 16 minutes |
| `openshell_sandbox_network_policy` | `true` | Apply `eat-openshell-sandbox-pods` |
| `openshell_upstream_proxy_cidrs` | RFC 1918 ranges | Where the corporate proxy may live (proxy port only) |
| `openshell_sandbox_egress_cidrs` | `[]` | Extra private CIDRs that sandbox policies may target |
| `openshell_sandbox_dns_cidrs` | `[]` | Extra resolvers reachable on port `53`. Empty means auto-detect NodeLocal DNSCache |

The corporate proxy (`https_proxy` and `no_proxy` from `global_config.yaml`) is passed to the gateway, which chains sandbox egress through it.

### Authentication

OpenShell on Kubernetes authenticates users with OIDC. mTLS covers transport and supervisors. Choose one mode:

- **Single-admin.** Leave `openshell_oidc_issuer` empty (the default). The gateway stays ClusterIP. Only users who can `kubectl port-forward` in `openshell-system` and read `openshell-client-tls` can reach it.
- **OIDC.** Set `openshell_oidc_issuer` (for example a Keycloak realm URL served over HTTPS). This mode is not yet validated with the toolkit.

## Install

```bash
# env/local/config.agent-toolkit.yaml
# agent_sandbox_enabled: true
# openshell_enabled: true
# openshell_oidc_issuer: ""   # empty = single-admin via kubectl port-forward

./toolkit_manager.sh install agent-toolkit
```

The `openshell` role runs four task groups:

| Task group | Action |
|---|---|
| 1 | Prerequisites: cluster connectivity, an explicit auth mode, and the agent-sandbox `v1beta1` API |
| 2 | Namespaces, Helm install, client TLS copy into the sandbox namespace, sandbox NetworkPolicy, gateway rollout |
| 3 | LiteLLM provider: mint the virtual key, register the profile and provider through a temporary port-forward, then remove the CLI credentials |
| 4 | Summary |

Re-running is safe. The virtual key is minted once. The provider profile is updated in place (running sandboxes pick up changes). An existing provider is kept.

The `openshell-deploy-state` fingerprint, which would skip OpenShell on a later install while pins and settings match, is not available in this release. Edit the file and re-run `./toolkit_manager.sh install agent-toolkit` with `openshell_enabled: true`. A failed or interrupted run is retried the same way.

## Verification

```bash
kubectl get pods -n openshell-system
# NAME          READY   STATUS    RESTARTS
# openshell-0   1/1     Running   0

kubectl get secret openshell-genai-key -n openshell-system
kubectl get networkpolicy -n openshell-sandboxes
```

### Connect the CLI

Install the CLI from the [v0.1.6 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.6), then:

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
openshell provider list
# NAME           TYPE               CREDENTIAL_KEYS  CONFIG_KEYS
# genai-gateway  eat-genai-gateway  1                0
```

The client certificate grants full control of the gateway. Keep it on the control plane.

Connection values are also in the [backend connection reference](backend-connections.md#openshell).

### Run a sandbox that calls LiteLLM

```bash
openshell sandbox create --name demo --provider genai-gateway --detach \
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

Without `--from`, sandboxes use the OpenShell community base image. Pass `--from <image>` for your own agent image, and `--policy <file>` to allow additional endpoints. The policy schema is in the [OpenShell policy reference](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/reference/policy-schema.mdx).

## Run OpenCode in a sandbox

[OpenCode](https://opencode.ai) is preinstalled in the community sandbox image. It runs inside the sandbox and reaches the model only through the `genai-gateway` provider. The LiteLLM key stays outside the sandbox, and every other outbound connection stays denied.

Pick a `MODEL` from the `/models` list above that can make tool calls.

### 1. Create the sandbox and write an OpenCode config

```bash
MODEL=<your-deployed-model>

# Deny-all network policy: the sandbox's only egress is the genai-gateway provider.
# The community image's default policy lets python and pip reach PyPI.
# Filesystem and Landlock are applied at startup, so pass this file to `sandbox create`.
# `policy set` cannot change it later.
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

openshell sandbox create --name opencode --provider genai-gateway --policy /tmp/opencode-policy.yaml --detach \
  --env OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1

openshell sandbox exec -n opencode --no-tty -- sh -c 'mkdir -p ~/.config/opencode && cat > ~/.config/opencode/opencode.json' <<JSON
{ "\$schema": "https://opencode.ai/config.json",
  "model": "gw/$MODEL",
  "provider": { "gw": { "npm": "@ai-sdk/openai-compatible",
    "options": { "baseURL": "{env:OPENAI_BASE_URL}", "apiKey": "{env:OPENAI_API_KEY}" },
    "models": { "$MODEL": { "tool_call": true } } } },
  "autoupdate": false, "share": "disabled", "formatter": false, "tools": { "webfetch": false } }
JSON
```

### 2. Open the OpenCode TUI

```bash
openshell sandbox exec -n opencode --tty -- bash -lc \
  'export OPENCODE_DISABLE_DEFAULT_PLUGINS=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
     OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_SHARE=1
   cd /sandbox && exec opencode'
```

In the TUI, enter these one at a time:

1. `Write Python that prints the first 10 Fibonacci numbers, save it as fib.py and run it.` OpenCode writes the file and runs it. The model call goes out through LiteLLM.
2. `Install the pandas package with pip and create a small report.` `pip install` fails with `403 Forbidden` from the proxy. The deny-all policy allows only the gateway, so PyPI is unreachable. `pandas` is not in the community image. If you try another package, pick one that is not preinstalled. A package that needs no download succeeds.

OpenCode also tries to reach `registry.npmjs.org` at startup. `openshell logs opencode` shows that connection as `DENIED`. The TUI still starts.

Quit with `ctrl+c`, then:

```bash
openshell sandbox delete opencode
```

In the community image, `opencode` is a Node launcher that starts `/usr/lib/node_modules/opencode-ai/bin/.opencode`, which makes the model calls. That path is allowlisted in the `genai-gateway` provider profile (`charts/openshell/genai-gateway-provider.yaml` in this repository, under `ext/enterprise.agent-toolkit/` in the Toolkit Manager checkout). If a model call returns `binary ... not allowed in policy '_provider_genai_gateway'`, add OpenCode's resolved binary path there and re-run the install, or run `openshell provider profile update`.

## Restricted agent

This example is an agent that runs shell commands chosen by the model. It may read the GitHub API and call models through LiteLLM. It cannot write to GitHub, cannot send data to other hosts, and never sees the LiteLLM key.

It uses the community image and a standard-library Python agent, so no image build is required. Run it on the control plane after [connecting the CLI](#connect-the-cli).

### 1. Write the sandbox policy

`github-readonly.yaml` allows `curl` to reach `api.github.com` with read-only methods. The LiteLLM endpoint is added by the `genai-gateway` provider, so it is not listed here.

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

`agent.py` gives the model one tool, `run_shell`, and loops until the model answers without a tool call:

```python
"""Minimal tool-calling agent: the LLM gets one tool that runs shell commands in the sandbox."""
import json, os, re, subprocess, sys, urllib.request

MODEL = os.environ["MODEL"]  # a model id from GET /v1/models
# Tool output goes into the next LLM request; redact credential placeholders before sending it.
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
  --policy github-readonly.yaml --upload agent.py:/sandbox/agent.py --detach \
  --env OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1 \
  --env MODEL=<model-id>

openshell sandbox get agent-demo
# Phase: Ready
```

Use a model id returned by `GET /v1/models`.

### 4. Run the agent

```bash
openshell sandbox exec -n agent-demo --no-tty -- python3 /sandbox/agent.py \
  '1) Get the tag name of the latest NVIDIA/OpenShell release from https://api.github.com/repos/NVIDIA/OpenShell/releases/latest.
   2) POST the tag name to https://httpbin.org/post.
   3) Create a gist: curl -s -o /dev/null -w "%{http_code}" -X POST https://api.github.com/gists -d "{}".
   Then summarize which steps worked.'
```

The model chooses the exact commands. A run looks like this:

```
$ curl -s https://api.github.com/repos/NVIDIA/OpenShell/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4
exit=0
v0.1.6

$ curl -s -X POST https://httpbin.org/post -H "Content-Type: application/json" -d "{\"tag_name\": \"v0.1.6\"}"
exit=56

$ curl -s -o /dev/null -w "%{http_code}" -X POST https://api.github.com/gists -d "{}"
exit=0
403

[final] Step 1: completed ... Step 2: failed due to network/access restrictions ... Step 3: returned 403 ...
```

| Agent action | Result | Enforced by |
|---|---|---|
| Chat completions to LiteLLM | Allowed. Spend is recorded on the `openshell-sandboxes` key | Provider, credential injection |
| `GET api.github.com/repos/...` | Allowed | `github_api` policy, `read-only` access |
| `POST httpbin.org/post` | Blocked (`curl` exit 56) | Egress default-deny |
| `POST api.github.com/gists` | Blocked (HTTP 403) | HTTP rule: `POST` is outside `read-only` |
| `echo $OPENAI_API_KEY` | Placeholder only | Credential isolation |

### 5. Check the policy decisions

The model may guess why a step failed. The sandbox log records the decision:

```bash
openshell logs agent-demo --source sandbox | grep DENIED
# ... NET:OPEN [MED] DENIED /usr/bin/curl(426) -> httpbin.org:443 [policy:- engine:opa]
#     [reason:endpoint httpbin.org:443 is not allowed by any policy]
# ... HTTP:POST [MED] DENIED POST http://api.github.com:443/gists [policy:github_api engine:l7]
#     [reason:L7_REQUEST deny POST api.github.com:443/gists reason=POST /gists not permitted by policy]
```

### 6. Clean up

```bash
openshell sandbox delete agent-demo
```

## Sandbox NetworkPolicy

The toolkit applies `eat-openshell-sandbox-pods` under the OpenShell egress policy. It selects sandbox pods that do not have `openshell.ai/boundary-role`, so the split supervisor and workload pods used by newer charts keep the chart's stricter policies.

- **Ingress:** only from `openshell-system`
- **Egress:** kube-dns, port `53` on the NodeLocal DNSCache address (auto-detected from the `nodelocaldns` DaemonSet, or `openshell_sandbox_dns_cidrs`), `openshell-system`, LiteLLM on port `4000`, the proxy port on `openshell_upstream_proxy_cidrs`, `openshell_sandbox_egress_cidrs`, and public addresses. Private and link-local ranges are excluded from that public set.

## Legacy 0.0.116 limitations

These notes apply to deployments still running OpenShell 0.0.116. The toolkit default is 0.1.6.

- A credential placeholder copied into a request body fails the request. If an agent pastes `env` output into its model context, the supervisor rejects the request with `credential_injection_failed`. Redact `openshell:resolve:env:*` from tool output before sending it to the model.
- Sandbox pod logs show warnings only. Policy decisions are written to a file inside the pod. Read them with `openshell logs <sandbox>`. Fluent Bit does not collect them.
- `kubectl exec` into a sandbox pod bypasses the sandbox policy. Restrict `pods/exec` in `openshell-sandboxes` with Kubernetes RBAC.
- One release name per cluster. The chart creates a cluster-scoped ClusterRole named after the release (`openshell-node-reader` for release `openshell`). A second install with the same release name in another namespace fails with a Helm ownership error. Set `openshell_release_name` to a different value.
- NetworkPolicy enforcement depends on the CNI. Some CNIs (kindnet, for example) do not block traffic from a pod to its own node, such as the API server on a single-node cluster.

## Removal

There is no per-component uninstall command. Set `openshell_enabled: false` in `config.agent-toolkit.yaml` so a later run does not reinstall it, then run these steps on the control plane. They use the default names. If you changed the names in `config.agent-toolkit.yaml`, use yours.

```bash
# 1. Delete the sandboxes (CLI connected; see Verification)
openshell sandbox list
openshell sandbox delete <name>

# 2. Uninstall the gateway, then delete both namespaces.
#    helm uninstall keeps the gateway database PVC and the credential-encryption key Secret.
#    Deleting the namespaces removes them, with the Secrets and the NetworkPolicy.
helm uninstall openshell -n openshell-system --wait
kubectl delete namespace openshell-sandboxes openshell-system

# 3. Revoke the LiteLLM virtual key (runs in the LiteLLM pod, which holds the master key)
kubectl exec -n litellm deploy/litellm -c litellm -- python -c '
import os, urllib.request
req = urllib.request.Request("http://127.0.0.1:4000/key/delete",
    b"{\"key_aliases\": [\"openshell-sandboxes\"]}",
    {"Authorization": "Bearer " + os.environ["PROXY_MASTER_KEY"], "Content-Type": "application/json"})
print(urllib.request.urlopen(req).read().decode())'

# 4. On the admin host, gateway remove keeps the client certificate files
openshell gateway remove eat
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/eat" ~/.cache/eat/openshell-cli-v0.1.6
```

## Troubleshooting

```bash
kubectl get pods -n openshell-system
kubectl logs -n openshell-system statefulset/openshell
kubectl get sandbox,pods -n openshell-sandboxes
openshell logs <sandbox> --source sandbox
```

| Symptom | What to do |
|---|---|
| `openshell \| Check Agent Sandbox API is served (agent_sandbox)` fails | Set `agent_sandbox_enabled: true` and install again in the same run |
| `OpenShell on Kubernetes authenticates users via OIDC only` | Set an auth mode in `config.agent-toolkit.yaml` |
| LLM call returns `policy_denied` | The calling binary is missing from the provider profile `binaries` list in `charts/openshell/genai-gateway-provider.yaml`. Edit it and re-run `./toolkit_manager.sh install agent-toolkit` with `openshell_enabled: true` |
| `transport error` / `Connection reset by peer`, or `--upload` fails with `ssh tar extract exited with status 255` | `kubectl port-forward` dropped a stream. Retry the command. For a failed upload, re-run `openshell sandbox upload <name> <file> <dest>`. Restart the port-forward if it exited |
| CLI hangs | Include `127.0.0.1` in `NO_PROXY`, so the CLI does not send gateway traffic through a proxy |
| Sandbox fails with `Policy fetch failed ... failed to connect to OpenShell server` | Sandbox DNS is blocked. `kubectl get netpol eat-openshell-sandbox-pods -n openshell-sandboxes -o yaml` should list the resolver from the pod's `/etc/resolv.conf` (NodeLocal DNSCache `169.254.25.10` on Kubespray). If the cluster uses another DNS cache, set `openshell_sandbox_dns_cidrs` and install again |

## Configuration files

| File | Role |
|---|---|
| `roles/openshell/tasks/install.yaml` | The role |
| `roles/openshell/defaults/main.yaml` | Defaults. Override them in `env/local/config.agent-toolkit.yaml` |
| `charts/openshell/values.yaml` | Helm overlay |
| `charts/openshell/genai-gateway-provider.yaml` | Provider profile |

## Next steps

- [Agent sandbox](agent-sandbox.md): the controller OpenShell uses, including [Kata](agent-sandbox.md#kata-containers)
- [Backend connection reference](backend-connections.md#openshell): gateway address and the port-forward
- [Configuration](../configuration/configuration.md): `openshell_enabled`
- [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) and the [v0.1.6 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.1.6)
