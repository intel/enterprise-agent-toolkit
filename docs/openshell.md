# NVIDIA OpenShell (Policy-Enforced Sandboxes)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) adds a policy layer on top of
[Agent Sandbox](agent-sandbox.md). Its gateway creates sandboxes as `agents.x-k8s.io`
Sandbox CRs, and a supervisor inside every sandbox enforces:

- **Egress default-deny** with per-host / per-binary allow rules and L7 (HTTP method/path) policy
- **Filesystem restrictions** (Landlock, best effort: applied where the node kernel supports it) and seccomp
- **Credential isolation** — the sandbox only sees a placeholder; the supervisor injects the
  real credential into requests toward the allowed endpoint

The toolkit registers the **GenAI Gateway** (LiteLLM) as an OpenShell provider, so agents in
OpenShell sandboxes call models through LiteLLM with a dedicated, budgeted virtual key that
never enters the sandbox.

OpenShell is **optional** and **off by default** (`deploy_openshell=off`).

---

## Supported Configuration

| Component | Version |
|---|---|
| OpenShell Helm chart / images | `0.0.116` (`oci://ghcr.io/nvidia/openshell/helm-chart`) |
| OpenShell CLI (used by the deployment) | `v0.0.116` GitHub release |
| Agent Sandbox | `v0.5.0` (`deploy_agent_sandbox=on`) |
| GenAI Gateway | LiteLLM as deployed by `deploy_genai_gateway=on` (optional; provider is skipped if absent) |
| User authentication | Single-admin mode (ClusterIP gateway, access gated by Kubernetes RBAC) |
| CNI | Must enforce `NetworkPolicy` (e.g. Calico) |

---

## Architecture

Two different components are called "gateway" in this document:

- **OpenShell gateway** — the OpenShell control plane. It creates and deletes sandboxes and
  stores policies and provider credentials. It does not proxy LLM traffic.
- **GenAI Gateway (LiteLLM)** — the toolkit's existing model proxy (`deploy_genai_gateway=on`).
  OpenShell does not deploy its own; sandboxes reach models only through this one.

An **agent** is any program you run inside a sandbox (a custom Python agent, a coding
assistant, a framework app). OpenShell does not ship an agent. The **supervisor** is the
OpenShell process that runs in the same pod as the agent and enforces its policy.

Deployment installs the platform once; each agent run then gets its own sandbox, created on
demand with `openshell sandbox create` (or the gateway API) and removed with `sandbox delete`.

```
Admin / CI / orchestrator
   │  openshell CLI or API over kubectl port-forward (mTLS client cert)
   ▼
OpenShell gateway  (StatefulSet openshell-0, openshell-system)
   │ 1. creates Sandbox CR              ▲ 3. supervisor fetches policy and
   ▼                                    │    provider credentials (mTLS)
Agent Sandbox controller ── 2. creates pod ──┐
(deploy_agent_sandbox)                       ▼
┌─ sandbox pod default--<name> (openshell-sandboxes) ─────────┐
│  agent process (your code)  ──►  OpenShell supervisor       │
│                                  egress / L7 policy, Landlock│
│                                  placeholder → real key      │
└──────────────────────────────────────┬──────────────────────┘
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
| Kubernetes cluster (`ei-infra-eligible` node label) | Runs the gateway and sandbox pods; the gateway is placed on infra nodes | No |
| Agent Sandbox controller `v0.5.0` (`deploy_agent_sandbox`) | Turns OpenShell `Sandbox` CRs into pods | No |
| GenAI Gateway / LiteLLM (`deploy_genai_gateway`) | The only path from a sandbox to models | One additional virtual key |
| Model backends behind LiteLLM | Reached through LiteLLM only | No |
| Deployment framework (`agentic-config.cfg`, metadata pins, `fresh-install.sh`, Ansible, resume mode) | Installs and re-runs OpenShell like other components | New `deploy_openshell` switch |
| Proxy settings (`https_proxy`, `no_proxy`) | Sandbox egress is chained through the corporate proxy | No |
| CNI (e.g. Calico) | Enforces the sandbox NetworkPolicy | No |

Not used by OpenShell: the Agent Sandbox router, `SandboxTemplate`, `WarmPool` and the
`k8s-agent-sandbox` SDK. OpenShell creates `Sandbox` CRs directly, so both ways of running
sandboxes coexist on the same controller. Fluent Bit does not collect OpenShell policy events
on 0.0.116 (see [Known Limitations](#known-limitations-00116)).

### Added by OpenShell

| Component | Kind | Role |
|---|---|---|
| OpenShell gateway | StatefulSet + Service `openshell:8080` (mTLS) | Sandbox lifecycle API, policy and credential store |
| Supervisor | Process in every sandbox pod | Egress and L7 enforcement, Landlock, seccomp, credential injection |
| `openshell` CLI | Binary on the admin host | Administration; used by the playbook to register the provider |
| Provider `genai-gateway` (profile `eat-genai-gateway`) | Gateway record | LiteLLM host and port, bearer credential, allowed binaries |
| NetworkPolicy `eat-openshell-sandbox-pods` | Added by the toolkit | Pod-level network limits under the supervisor |

### Interfaces

| # | From | To | Interface | Configured by |
|---|---|---|---|---|
| 1 | Admin / CI | OpenShell gateway | gRPC over mTLS through `kubectl port-forward` (secret `openshell-client-tls`) | Chart; see [Verification](#verification) |
| 2 | OpenShell gateway | Kubernetes API | Creates `agents.x-k8s.io/v1beta1` `Sandbox` CRs in `openshell-sandboxes` | Chart RBAC |
| 3 | Agent Sandbox controller | Kubernetes API | Reconciles the CR into a pod | Toolkit, unchanged |
| 4 | Supervisor | OpenShell gateway | gRPC over mTLS: policy, credentials, events | Playbook copies the client TLS secret into the sandbox namespace |
| 5 | Agent | Supervisor | All pod egress passes through the supervisor | OpenShell |
| 6 | Supervisor | LiteLLM `:4000` | OpenAI-compatible HTTP; `Authorization: Bearer <placeholder>` rewritten to the virtual key | Provider profile; `providers_v2_enabled=true` (playbook) |
| 7 | Playbook | LiteLLM admin API | `kubectl exec` into the LiteLLM pod, `POST /key/generate` with the in-pod master key → Secret `openshell-genai-key` → provider credential | Playbook |
| 8 | LiteLLM | Model backends | Unchanged; the key's allowed models and budget apply | Toolkit, unchanged |
| 9 | Supervisor | External hosts | Only hosts in the sandbox policy, through the corporate proxy | `--policy` per sandbox; proxy from `agentic-config.cfg` |

### Where credentials live

| Credential | Location | Visible inside a sandbox |
|---|---|---|
| LiteLLM master key | LiteLLM pod only | No |
| Virtual key `openshell-sandboxes` | Secret `openshell-genai-key` and the OpenShell gateway | No — only a placeholder |
| Client certificate (`openshell-client-tls`) | `openshell-system` and `openshell-sandboxes` | Mounted for the supervisor; grants gateway admin, so restrict `pods/exec` |

---

## Deployed Components

| Component | Kind | Namespace | Notes |
|---|---|---|---|
| `openshell` | StatefulSet + Service (ClusterIP :8080, mTLS) | `openshell-system` | Upstream Helm chart with `core/helm-charts/openshell/values.yaml` |
| `openshell-client-tls` | Secret | `openshell-system`, `openshell-sandboxes` | Client mTLS bundle; copied into the sandbox namespace (supervisors mount it) |
| `openshell-genai-key` | Secret | `openshell-system` | LiteLLM virtual key minted inside the LiteLLM pod (master key never leaves it) |
| `eat-genai-gateway` | Provider profile | gateway | LiteLLM endpoint, bearer credential, allowed binaries |
| `genai-gateway` | Provider | gateway | Attach to sandboxes with `--provider genai-gateway` |
| `eat-openshell-sandbox-pods` | NetworkPolicy | `openshell-sandboxes` | Pod-level egress/ingress limits for sandbox pods (see below) |

---

## Configuration

### Enable in `core/inventory/agentic-config.cfg`

```ini
deploy_agent_sandbox=on
deploy_openshell=on
```

`deploy_openshell=on` requires `deploy_agent_sandbox=on` in the same run, or Agent Sandbox
CRDs already present on the cluster; otherwise the deployment exits before installing
anything. On re-runs, resume mode skips OpenShell only if the `openshell_release_name` release
in `openshell_namespace` (as set in `inference_openshell.yml`) is `deployed` and the last run
completed with the current version pins and settings (see [Deployment](#deployment)).

### Version pins in `core/inventory/metadata/agentic-metadata.cfg`

```ini
openshell_chart_version="0.0.116"
openshell_image_tag="0.0.116"
openshell_release_tag="v0.0.116"
```

### Settings in `core/inventory/metadata/vars/inference_openshell.yml`

| Variable | Default | Purpose |
|---|---|---|
| `openshell_release_name` | `openshell` | Helm release and gateway Service name |
| `openshell_namespace` | `openshell-system` | Gateway namespace (holds provider credentials) |
| `openshell_sandbox_namespace` | `openshell-sandboxes` | Sandbox pods |
| `openshell_allow_unauthenticated_clusterip_only` | `false` | Must be set to `true` to accept single-admin mode (see [Authentication](#authentication)) |
| `openshell_oidc_issuer` / `openshell_oidc_audience` | `""` / `openshell-cli` | OIDC user authentication (alternative to single-admin mode) |
| `openshell_genai_provider_enabled` | `true` | Register the GenAI Gateway provider |
| `openshell_genai_key_alias` | `openshell-sandboxes` | LiteLLM virtual key alias (spend tracking) |
| `openshell_genai_key_models` | `[]` | Models the key may use (empty = all) |
| `openshell_genai_key_max_budget` | `50` | LiteLLM budget for the key |
| `openshell_cli_dir` | `""` | Where the playbook keeps the CLI; empty = `~/.cache/eat/openshell-cli-<release tag>` (mode `0700`) |
| `openshell_sandbox_network_policy` | `true` | Apply `eat-openshell-sandbox-pods` |
| `openshell_upstream_proxy_cidrs` | RFC 1918 ranges | Where the corporate proxy may live (proxy port only) |
| `openshell_sandbox_egress_cidrs` | `[]` | Extra private CIDRs that sandbox policies may target |

The corporate proxy (`https_proxy` / `no_proxy` from `agentic-config.cfg`) is passed to the
gateway, which chains sandbox egress through it.

### Authentication

OpenShell on Kubernetes authenticates users with OIDC only; mTLS covers transport and
supervisors. Choose one mode explicitly — the playbook fails otherwise:

- **Single-admin (supported)**: set `openshell_allow_unauthenticated_clusterip_only: true`.
  The gateway stays `ClusterIP`; only users who can `kubectl port-forward` in
  `openshell-system` and read `openshell-client-tls` can reach it.
- **OIDC**: set `openshell_oidc_issuer` (for example a Keycloak realm URL, served over HTTPS).
  Not yet validated with the toolkit.

---

## Deployment

```bash
# core/inventory/agentic-config.cfg
deploy_agent_sandbox=on
deploy_openshell=on

# core/inventory/metadata/vars/inference_openshell.yml
openshell_allow_unauthenticated_clusterip_only: true

./deploy-agentic-stack.sh
```

The Ansible playbook (`core/playbooks/deploy-openshell.yml`) runs 4 task groups:

| Task Group | Action |
|---|---|
| 1 | Prerequisites — cluster connectivity, explicit auth mode, Agent Sandbox `v1beta1` API served |
| 2 | Namespaces, Helm install, client TLS copy into the sandbox namespace, sandbox NetworkPolicy, gateway rollout |
| 3 | GenAI Gateway provider — mint virtual key, register profile and provider via a temporary port-forward (CLI credentials removed afterwards) |
| 4 | Summary |

Re-running is safe: the virtual key is minted once, the provider profile is updated in place
(running sandboxes pick up changes), and an existing provider is kept.

The last task stores a fingerprint of the version pins, `inference_openshell.yml`,
`core/helm-charts/openshell/` and the playbook in ConfigMap `openshell-deploy-state`. On the
next `./deploy-agentic-stack.sh`, resume mode skips OpenShell only while that fingerprint
matches. To apply a changed pin, setting or provider profile, edit the file and re-run
`./deploy-agentic-stack.sh` with `deploy_openshell=on`; a failed or interrupted run is retried
the same way.

---

## Verification

```bash
kubectl get pods -n openshell-system
# NAME          READY   STATUS    RESTARTS
# openshell-0   1/1     Running   0

kubectl get secret openshell-genai-key -n openshell-system
kubectl get networkpolicy -n openshell-sandboxes
```

### Connect the CLI (admin, control plane)

Install the CLI from the [v0.0.116 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.0.116), then:

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

> The client certificate grants full control of the gateway. Keep it on the control plane.

### Run a sandbox that calls the GenAI Gateway

```bash
openshell sandbox create --name demo --provider genai-gateway --detach \
  --env OPENAI_BASE_URL=http://genai-gateway-service.genai-gateway.svc.cluster.local:4000/v1

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

Without `--from`, sandboxes use the OpenShell community base image. Pass
`--from <image>` for your own agent image, and `--policy <file>` to allow additional
endpoints (see the [OpenShell policy reference](https://github.com/NVIDIA/OpenShell/blob/v0.0.116/docs/reference/policy-schema.mdx)).

---

## Run OpenCode (coding agent) in a sandbox

[OpenCode](https://opencode.ai) is preinstalled in the community sandbox image. It runs entirely
inside the sandbox and reaches the model only through the `genai-gateway` provider — so the
LiteLLM key never enters the sandbox, and every other outbound connection stays denied. This
reuses the same sandbox setup as above; you only add a small OpenCode config, then start its TUI.

Pick a `MODEL` your GenAI Gateway serves that supports tool calling (from the `/models` list above).

### 1. Create the sandbox and add a minimal OpenCode config

```bash
MODEL=<your-deployed-model>          # a tool-calling model your GenAI Gateway serves

# Deny-all network policy: the sandbox's ONLY egress is the genai-gateway provider endpoint.
# Without it, the community image's default policy lets python/pip reach PyPI. Filesystem and
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

openshell sandbox create --name opencode --provider genai-gateway --policy /tmp/opencode-policy.yaml --detach \
  --env OPENAI_BASE_URL=http://genai-gateway-service.genai-gateway.svc.cluster.local:4000/v1

# OpenCode talks to the GenAI Gateway using the sandbox's injected env (placeholder key).
openshell sandbox exec -n opencode --no-tty -- sh -c 'mkdir -p ~/.config/opencode && cat > ~/.config/opencode/opencode.json' <<JSON
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
openshell sandbox exec -n opencode --tty -- bash -lc \
  'export OPENCODE_DISABLE_DEFAULT_PLUGINS=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
     OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_DISABLE_SHARE=1
   cd /sandbox && exec opencode'
```

In the TUI, enter these one at a time:

1. **Works:** `Write Python that prints the first 10 Fibonacci numbers, save it as fib.py and run it.`
   OpenCode writes the file and runs it; the model call goes out through the GenAI Gateway.
2. **Blocked by the sandbox:** `Install the pandas package with pip and create a small report.`
   `pip install` fails with `403 Forbidden` from the proxy — the deny-all policy allows only the
   gateway, so PyPI is unreachable. OpenCode reports the failure. (`pandas` is not in the
   community image; if you use another package, pick one that isn't preinstalled, or `pip` needs
   no download and succeeds.)

OpenCode also tries to reach `registry.npmjs.org` at startup; `openshell logs opencode` shows that
connection as `DENIED`. It is harmless.

Quit with `ctrl+c`, then clean up:

```bash
openshell sandbox delete opencode
```

> In the community image, `opencode` is a Node launcher that starts the bundled executable
> `/usr/lib/node_modules/opencode-ai/bin/.opencode`, which makes the model calls. That path is
> allowlisted in the `genai-gateway` provider profile
> (`core/helm-charts/openshell/genai-gateway-provider.yaml`). If a
> model call returns `binary ... not allowed in policy '_provider_genai_gateway'`, add OpenCode's
> resolved binary path there and re-run the deployment (or `openshell provider profile update`).

---

## End-to-End Example: Restricted Agent

**Scenario:** an LLM agent that runs arbitrary shell commands chosen by the model. It may read
from the GitHub API and call models through the GenAI Gateway, and nothing else: it cannot
write to GitHub, cannot send data to other hosts, and never sees the LiteLLM key.

The example uses the default community image and a standard-library-only Python agent, so no
image build is needed. Run it on the control plane after
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
# Tool output goes into the next LLM request, and OpenShell 0.0.116 rejects requests whose
# body contains a credential placeholder, so redact it.
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
  --env OPENAI_BASE_URL=http://genai-gateway-service.genai-gateway.svc.cluster.local:4000/v1 \
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
v0.0.116

$ curl -s -X POST https://httpbin.org/post -H "Content-Type: application/json" -d "{\"tag_name\": \"v0.0.116\"}"
exit=56

$ curl -s -o /dev/null -w "%{http_code}" -X POST https://api.github.com/gists -d "{}"
exit=0
403

[final] Step 1: completed ... Step 2: failed due to network/access restrictions ... Step 3: returned 403 ...
```

| Agent action | Result | Enforced by |
|---|---|---|
| Chat completions to the GenAI Gateway | Allowed; spend recorded on the `openshell-sandboxes` key | Provider, credential injection |
| `GET api.github.com/repos/...` | Allowed | `github_api` policy, `read-only` access |
| `POST httpbin.org/post` | Blocked (`curl` exit 56) | Egress default-deny |
| `POST api.github.com/gists` | Blocked (HTTP 403) | L7 rule: `POST` not permitted by `read-only` |
| `echo $OPENAI_API_KEY` | Placeholder only | Credential isolation |

### 5. Check the policy decisions

The model may guess why a step failed (for example, it may attribute the 403 to missing GitHub
authentication). The sandbox log records the actual decision:

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

---

## Sandbox NetworkPolicy

OpenShell `0.0.116` runs each sandbox as a single pod, which the chart's own NetworkPolicy
does not select. The toolkit applies `eat-openshell-sandbox-pods` to these pods as defense in
depth under the OpenShell egress policy:

- **Ingress**: only from `openshell-system`
- **Egress**: kube-dns, `openshell-system`, the GenAI Gateway on port `4000`, the proxy port on
  `openshell_upstream_proxy_cidrs`, `openshell_sandbox_egress_cidrs`, and public addresses
  (all private and link-local ranges excluded)

Pods labelled `openshell.ai/boundary-role` (split supervisor/workload pods of newer charts) are
not selected, so the chart's stricter policies stay in effect.

---

## Known Limitations (0.0.116)

- **Credential placeholder in a request body fails the request.** If an agent copies the
  placeholder into a request body (for example by pasting `env` output into its LLM context),
  the supervisor rejects the request with `credential_injection_failed`. Redact
  `openshell:resolve:env:*` from tool output before sending it to the model.
- **Sandbox pod logs show warnings only.** Policy decisions are written to a file inside the
  pod; read them with `openshell logs <sandbox>`. Fluent Bit does not collect them.
- **`kubectl exec` into a sandbox pod bypasses the sandbox policy.** Restrict `pods/exec` in
  `openshell-sandboxes` with Kubernetes RBAC.
- **One release name per cluster.** The chart creates a cluster-scoped ClusterRole named after
  the release (`openshell-node-reader` for release `openshell`). A second install with the same
  release name in another namespace fails with a Helm ownership error; set
  `openshell_release_name` to a different value.
- **NetworkPolicy enforcement depends on the CNI.** Some CNIs (for example kindnet) do not block
  traffic from a pod to its own node, such as the API server on a single-node cluster.

---

## Removal

The toolkit has no per-component uninstall. To remove OpenShell from a running cluster, set
`deploy_openshell=off` in `agentic-config.cfg` (so a later run does not reinstall it), then run
these steps on the control plane. They use the default names; if you changed them in
`inference_openshell.yml`, use yours.

```bash
# 1. Delete the sandboxes (with the CLI connected, see Verification)
openshell sandbox list
openshell sandbox delete <name>

# 2. Uninstall the gateway, then delete both namespaces. helm uninstall keeps the gateway
#    database PVC and the credential-encryption key Secret; deleting the namespaces removes
#    them, together with the Secrets and the NetworkPolicy the playbook created.
helm uninstall openshell -n openshell-system --wait
kubectl delete namespace openshell-sandboxes openshell-system

# 3. Revoke the LiteLLM virtual key (runs in the LiteLLM pod, which holds the master key)
kubectl exec -n genai-gateway deploy/genai-gateway-deployment -c litellm-container -- python -c '
import os, urllib.request
req = urllib.request.Request("http://127.0.0.1:4000/key/delete",
    b"{\"key_aliases\": [\"openshell-sandboxes\"]}",
    {"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"], "Content-Type": "application/json"})
print(urllib.request.urlopen(req).read().decode())'

# 4. Admin host: `gateway remove` keeps the client certificate files, so delete them too,
#    and the CLI the playbook downloaded
openshell gateway remove eat
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/eat" ~/.cache/eat/openshell-cli-v0.0.116
```

---

## Troubleshooting

```bash
kubectl get pods -n openshell-system
kubectl logs -n openshell-system statefulset/openshell
kubectl get sandbox,pods -n openshell-sandboxes
openshell logs <sandbox> --source sandbox
```

| Symptom | Cause / Fix |
|---|---|
| `deploy_openshell=on requires deploy_agent_sandbox=on` | Enable Agent Sandbox in the same run |
| `OpenShell on Kubernetes authenticates users via OIDC only` | Choose an auth mode in `inference_openshell.yml` |
| LLM call returns `policy_denied` | The calling binary is not in the provider profile `binaries` list (`core/helm-charts/openshell/genai-gateway-provider.yaml`); edit it and re-run `./deploy-agentic-stack.sh` with `deploy_openshell=on` |
| `transport error` / `Connection reset by peer`, or `--upload` fails with `ssh tar extract exited with status 255` | `kubectl port-forward` dropped a stream; retry the command (re-run `openshell sandbox upload <name> <file> <dest>` for a failed upload), and restart the port-forward if it exited |
| CLI hangs | Make sure `NO_PROXY` includes `127.0.0.1`, so the CLI does not send gateway traffic through a proxy |

---

## Configuration Files

- **Playbook**: `core/playbooks/deploy-openshell.yml`
- **Wrapper**: `core/lib/components/openshell-controller.sh`
- **Variables**: `core/inventory/metadata/vars/inference_openshell.yml`
- **Helm overlay**: `core/helm-charts/openshell/values.yaml`
- **Provider profile**: `core/helm-charts/openshell/genai-gateway-provider.yaml`

---

## References

- [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell)
- [OpenShell v0.0.116 release](https://github.com/NVIDIA/OpenShell/releases/tag/v0.0.116)
- [Agent Sandbox in this toolkit](agent-sandbox.md)
