# Persistent Agents

Create isolated, identity-bearing AI agents with one command.
Each agent gets its own namespace, OpenClaw instance, gateway token, and Keycloak identity.

---

## Quick Start

```bash
# Create an agent
helm install my-agent core/helm-charts/agent-instance/ \
  --set owner=vkumar4@intel.com \
  --set "skills={shell,read_file,git,browser-automation}"

# Check status
kubectl get agents -A

# Access Web UI
kubectl port-forward -n agent-my-agent svc/my-agent 18789:18789
# Token:
kubectl get secret my-agent-gateway-token -n agent-my-agent -o jsonpath='{.data.token}' | base64 -d

# Delete
helm uninstall my-agent
```

---

## What Happens When You Create an Agent

```
helm install my-agent ...
    │
    ▼
Agent CR created (kind: Agent, intel-stack.io/v1alpha1)
    │
    ▼ (Agent Operator reconciles)
    │
    ├── 1. Creates namespace: agent-my-agent
    │
    ├── 2. Creates OpenClawInstance (connects to vLLM)
    │       └── Pod: my-agent-0 (3 containers: openclaw, proxy, otel)
    │       └── Service: my-agent:18789
    │       └── PVC: 10Gi workspace
    │
    ├── 3. Creates gateway token secret (random 24-byte hex)
    │
    ├── 4. Creates Keycloak OIDC client (if Keycloak enabled)
    │       └── clientId: agent-my-agent
    │       └── serviceAccountsEnabled: true
    │       └── Credentials stored in: my-agent-keycloak-credentials secret
    │
    └── 5. Injects skills config into OpenClaw (tools + plugins)

Agent status → Ready
```

On delete (`helm uninstall my-agent`), all of the above is cleaned up:
Keycloak client revoked → OpenClaw instance deleted → Namespace deleted.

---

## Configuration

### Required

| Flag | Description | Example |
|------|-------------|---------|
| `owner` | Email/principal of the agent owner | `vkumar4@intel.com` |

### Optional

| Flag | Default | Description |
|------|---------|-------------|
| `skills` | `[shell, read_file, list_files]` | Agent capabilities |

### Available Skills

| Skill | What it enables |
|-------|-----------------|
| `shell` | Full terminal/command execution |
| `read_file` | Read files (built-in, always available) |
| `list_files` | List directory contents (built-in) |
| `summarize` | Text summarization (built-in) |
| `git` | Git operations (requires `shell`) |
| `browser-automation` | Web page control, multi-step flows |
| `diagram-maker` | SVG/HTML diagram generation |
| `memory` | Persistent memory across sessions |
| `canvas` | HTML canvas rendering |

### Examples

```bash
# Coding agent with full capabilities
helm install code-bot core/helm-charts/agent-instance/ \
  --set owner=dev@intel.com \
  --set "skills={shell,read_file,list_files,git,browser-automation}"

# Research agent (no shell access)
helm install research-bot core/helm-charts/agent-instance/ \
  --set owner=analyst@intel.com \
  --set "skills={read_file,summarize,browser-automation}"

# Minimal agent
helm install helper core/helm-charts/agent-instance/ \
  --set owner=user@intel.com
```

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  User: helm install my-agent ...                     │
└──────────────────────────────────────────────────────┘
          │
          ▼
┌──────────────────────────────────────────────────────┐
│  Agent CR (intel-stack.io/v1alpha1)                   │
│  spec: owner + skills                                │
└──────────────────────────────────────────────────────┘
          │
          ▼ (Agent Operator - kopf)
┌──────────────────────────────────────────────────────┐
│  Provisions:                                         │
│  ├── Namespace (agent-{name})                        │
│  ├── OpenClawInstance → OpenClaw Operator → Pod      │
│  ├── Gateway Token Secret                            │
│  ├── Keycloak OIDC Client                            │
│  └── Skills → tools/plugins config                   │
└──────────────────────────────────────────────────────┘
          │
          ▼
┌──────────────────────────────────────────────────────┐
│  OpenClaw Pod                                        │
│  ├── Model: vLLM (Qwen3-Coder-30B)                  │
│  ├── Shell: built-in (runs in pod directly)          │
│  ├── Tools/Plugins: configured from skills           │
│  └── Web UI: port 18789                              │
└──────────────────────────────────────────────────────┘
```

---

## Multi-User Isolation

Each agent is fully isolated:

| Resource | Scope |
|----------|-------|
| Kubernetes namespace | `agent-{name}` — unique per agent |
| PVC (workspace) | Per-agent, not shared |
| Gateway token | Unique random secret |
| Keycloak client | Per-agent OIDC identity |
| Network | Separate pod, own service |

Two users on the same cluster:
```bash
# User A
helm install coding-agent core/helm-charts/agent-instance/ \
  --set owner=alice@intel.com --set "skills={shell,git}"

# User B
helm install research-agent core/helm-charts/agent-instance/ \
  --set owner=bob@intel.com --set "skills={read_file,summarize}"
```

They cannot see each other's agents, namespaces, or data.

---

## Agent Sandbox (Code Execution)

The **Agent Sandbox** (`agent-sandbox` namespace) provides isolated, ephemeral
Kubernetes pods for safe code execution via the `k8s-agent-sandbox` SDK.

### Current Limitation

**OpenClaw does NOT natively integrate with agent-sandbox.** When an agent has
the `shell` skill and you ask it to run code, it executes directly inside the
OpenClaw pod using its built-in shell tool — not in an isolated sandbox pod.

The `AGENT_SANDBOX_ENDPOINT` env var is injected into the agent pod but OpenClaw
ignores it. There is no built-in plugin or hook in OpenClaw to redirect `exec`
calls to an external sandbox API.

### Current behavior

```
You: "Run this Python code"
  → OpenClaw's built-in shell tool
  → Executes inside the OpenClaw pod directly
  → Returns output
```

This works functionally but without the isolation boundary that the sandbox provides.

### Planned solution: MCP Server Bridge

The recommended path to integrate agent-sandbox with OpenClaw is an **MCP server**
that wraps the `k8s-agent-sandbox` SDK. OpenClaw supports connecting to MCP servers
natively.

```
OpenClaw → MCP server (sidecar/pod) → sandbox-router → isolated sandbox pod
```

The MCP server would expose tools:
- `execute_python` — runs code in a sandbox pod
- `install_package` — pip install in the sandbox
- `reset_sandbox` — terminate and recreate fresh environment

Implementation uses the existing `k8s-agent-sandbox` Python SDK (`k8s-agent-sandbox==0.0.30`)
which connects to `sandbox-router-svc.agent-sandbox.svc.cluster.local:8080`.

**Status:** Not yet implemented. Tracked as a future enhancement.

### Alternative: Standalone Coding Agent

The `usecases/coding-agent/` in the innersource repo deploys a separate Python
service (using `agent-framework` + `DevUI`) that integrates directly with the
sandbox SDK. This is a standalone deployment, not part of the OpenClaw-based
agent flow.

### Reference

Full sandbox documentation: [agent-sandbox.md](agent-sandbox.md)

---

## Infrastructure Requirements

| Component | Required | Purpose |
|-----------|----------|---------|
| Agent Operator | Yes | Reconciles Agent CRs |
| OpenClaw Operator | Yes | Manages OpenClaw pods |
| vLLM model | Yes | LLM inference |
| Keycloak | Optional | Per-agent identity (OIDC client per agent) |
| Agent Sandbox | Optional | Isolated code execution (security boundary) |

Deploy all requirements with:
```bash
./deploy-agentic-stack.sh --persistent-agents
```

---

## Operator Configuration

The Agent Operator is configured via its Helm values:

```bash
helm upgrade agent-operator core/helm-charts/agent-operator/ \
  --namespace agent-operator-system \
  --set adapters.claw.vllmServiceName=vllm-qwen3-coder-30b-cpu-service \
  --set adapters.claw.modelId="Qwen/Qwen3-Coder-30B-A3B-Instruct" \
  --set adapters.claw.sandboxEndpoint="http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080" \
  --set keycloak.enabled=true \
  --set keycloak.url="http://keycloak.auth-apisix.svc.cluster.local:80"
```

| Value | Default | Description |
|-------|---------|-------------|
| `adapters.claw.vllmServiceName` | `vllm-qwen3-coder-30b-cpu-service` | vLLM service name |
| `adapters.claw.vllmNamespace` | `default` | vLLM namespace |
| `adapters.claw.modelId` | `Qwen/Qwen3-Coder-30B-A3B-Instruct` | Model ID |
| `adapters.claw.sandboxEndpoint` | `http://sandbox-router-svc...:8080` | Sandbox URL |
| `keycloak.enabled` | `false` | Enable per-agent identity |
| `keycloak.url` | `http://keycloak.auth-apisix...:80` | Keycloak URL |

---

## Useful Commands

```bash
# List all agents
kubectl get agents -A

# Agent details
kubectl describe agent my-agent

# Agent pod logs
kubectl logs -n agent-my-agent my-agent-0 -c openclaw --tail=20

# Get gateway token
kubectl get secret my-agent-gateway-token -n agent-my-agent \
  -o jsonpath='{.data.token}' | base64 -d

# Get Keycloak credentials
kubectl get secret my-agent-keycloak-credentials -n agent-my-agent \
  -o jsonpath='{.data.client_id}' | base64 -d

# Check OpenClaw config (skills applied)
kubectl exec -n agent-my-agent my-agent-0 -c openclaw -- \
  cat /home/openclaw/.openclaw/openclaw.json | jq '.tools, .plugins'

# Port-forward to agent
kubectl port-forward -n agent-my-agent svc/my-agent 18789:18789
```

---

## Helm Charts Reference

| Chart | Purpose | Deployed by |
|-------|---------|-------------|
| `agent-operator-crds/` | Agent CRD definition | `deploy-agentic-stack.sh` |
| `agent-operator/` | Operator controller (kopf) | `deploy-agentic-stack.sh` |
| `agent-instance/` | Create one agent (user-facing) | User (`helm install`) |
| `openclaw-instance/` | Standalone OpenClaw (no operator) | Manual |
