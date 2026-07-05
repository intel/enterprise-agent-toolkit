# Persistent Agents

Create isolated, identity-bearing AI agents with one command.
Each agent gets its own namespace, OpenClaw instance, gateway token, and Keycloak identity.

---

## Quick Start

```bash
# Create an agent
helm install my-agent core/helm-charts/agent-instance/ \
  --set owner=vkumar4@example.com \
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
| `owner` | Email/principal of the agent owner | `vkumar4@example.com` |

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
  --set owner=dev@example.com \
  --set "skills={shell,read_file,list_files,git,browser-automation}"

# Research agent (no shell access)
helm install research-bot core/helm-charts/agent-instance/ \
  --set owner=analyst@example.com \
  --set "skills={read_file,summarize,browser-automation}"

# Minimal agent
helm install helper core/helm-charts/agent-instance/ \
  --set owner=user@example.com
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
  --set owner=alice@example.com --set "skills={shell,git}"

# User B
helm install research-agent core/helm-charts/agent-instance/ \
  --set owner=bob@example.com --set "skills={read_file,summarize}"
```

They cannot see each other's agents, namespaces, or data.

---

## Suspend / Resume

Agents can be suspended (scaled to zero, saving CPU/memory) and resumed later
with all state intact. State survives on the retained PVC + Redis.

```bash
# Suspend (manual)
kubectl patch agent my-agent --type=merge -p '{"spec":{"desiredState":"Suspended"}}'
# → PHASE=IdleSuspended, pod scaled to zero, PVC retained

# Resume
kubectl patch agent my-agent --type=merge -p '{"spec":{"desiredState":"Running"}}'
# → PHASE=Running, workspace files and sessions intact
```

**Auto-idle suspend:** the operator auto-suspends agents idle longer than
`autoSuspend.idleMinutes` (default 30; set `0` to disable). Auto-suspended agents
show `suspendReason=auto-idle`. A manual resume always overrides.

Full contract — what survives, phase state machine, config, limitations:
[contracts/agent-suspend-resume.md](contracts/agent-suspend-resume.md)

---

## Persistent Memory

Agents created with the `memory` skill get **per-agent isolated memory** — their
own pgvector schema (`agent_{name}`) with three tiers (`claudemd`, `project`,
`auto`), plus semantic search. The operator provisions the schema on create and
drops it on delete; a shared, stateless MCP memory server (`mcp-memory-server`)
exposes `memory_write` / `memory_read` / `memory_list_tiers` to any runtime.

```bash
helm install my-agent core/helm-charts/agent-instance/ \
  --set owner=user@example.com --set "skills={memory}"
# → schema agent_my_agent provisioned, memory MCP auto-wired into the agent
```

Full convention — tiers, schema layout, read/write contract, credential gotcha:
[conventions/agent-memory.md](conventions/agent-memory.md)

---

## Agent Sandbox (Code Execution)

**Status: Working ✅** (verified end-to-end via Option B below)

The **Agent Sandbox** (`agent-sandbox` namespace) provides isolated, ephemeral
Kubernetes pods for safe code execution via the `k8s-agent-sandbox` SDK.

### How it works

OpenClaw has no built-in hook to redirect its own `exec` tool to an external sandbox.
Instead, it connects to an **MCP server** that exposes sandbox execution as MCP tools.
OpenClaw supports MCP servers natively (SSE transport, `mcp.servers` config).

Once connected, the agent gets 4 sandbox tools: `execute_python`, `execute_shell`,
`install_package`, `reset_sandbox`. Code runs in an isolated sandbox pod, not in the
OpenClaw pod.

```
OpenClaw Pod → MCP (SSE) → MCP Sandbox Server → k8s-agent-sandbox SDK
             → sandbox-router → isolated sandbox pod → result
```

### Verified test

In the OpenClaw Web UI, ask the agent:

> "Use execute_python to run: print('hello from sandbox')"

Expected result: `hello from sandbox` (executed in an isolated sandbox pod).

Direct in-cluster verification (bypasses OpenClaw):
```bash
kubectl exec -n agent-sandbox deploy/mcp-sandbox-server -- sh -c \
  "PYTHONPATH=/deps python3 -c \"
import asyncio
from fastmcp import Client
async def m():
    async with Client('http://localhost:8000/sse') as c:
        r = await c.call_tool('execute_python', {'code': \\\"print('hi')\\\"})
        print(r.data)
asyncio.run(m())\""
# Expected: hi
```

### Solution: MCP Server Bridge

Two sandbox options are available (deploy one, not both):

**Option A: `agent-sandbox/agent-sandbox`** (recommended — built-in MCP)

An open-source sandbox with a built-in MCP server at `/mcp`. Supports code execution,
browser use, and shell commands with automatic lifecycle management.

```bash
# Install
kubectl create namespace agent-sandbox
kubectl apply -n agent-sandbox -f https://raw.githubusercontent.com/agent-sandbox/agent-sandbox/main/install.yaml

# MCP endpoint for agents:
# http://agent-sandbox-server.agent-sandbox.svc.cluster.local/mcp
```

```bash
# Create agent with sandbox MCP tool
helm install my-agent core/helm-charts/agent-instance/ \
  --set owner=user@example.com \
  --set "skills={read_file,list_files}" \
  --set "tools[0].name=sandbox" \
  --set "tools[0].url=http://agent-sandbox-server.agent-sandbox.svc.cluster.local/mcp"
```

**Option B: Custom MCP bridge for `kubernetes-sigs/agent-sandbox`** (this toolkit's sandbox)

A custom MCP server (in `core/helm-charts/mcp-sandbox-server/`) that wraps the
`k8s-agent-sandbox` SDK and exposes tools: `execute_python`, `execute_shell`,
`install_package`, `reset_sandbox`. This is the tested, working option for the
sandbox deployed by this toolkit.

> **CRITICAL — SDK version must match the deployed sandbox.** The
> `k8s-agent-sandbox` Python SDK pin in `src/requirements.txt` MUST equal
> `agent_sandbox_version` in `core/inventory/metadata/agentic-metadata.cfg`
> (currently `v0.4.6` → `k8s-agent-sandbox==0.4.6`). A mismatch causes HTTP 404
> from the sandbox-router because the SDK's request contract changes between versions.

```bash
# Build and deploy
sudo nerdctl --namespace k8s.io build -t mcp-sandbox-server:0.1.0 core/helm-charts/mcp-sandbox-server/src/
helm install mcp-sandbox core/helm-charts/mcp-sandbox-server/ -n agent-sandbox

# Create agent with sandbox MCP tool
helm install my-agent core/helm-charts/agent-instance/ \
  --set owner=user@example.com \
  --set "skills={read_file,list_files}" \
  --set "tools[0].name=sandbox" \
  --set "tools[0].url=http://mcp-sandbox-server.agent-sandbox.svc.cluster.local:8000/sse"
```

**How agents connect to either:**

The operator injects the tool URL into OpenClaw's `mcp.servers` config (transport `sse`).
The agent discovers and calls the MCP tools automatically — no agent code changes.

```
OpenClaw Pod → MCP protocol (SSE) → Sandbox MCP Server → Isolated execution pod
```

**Notes:**
- The custom bridge requires RBAC (Role + RoleBinding) to `create/delete sandboxclaims`,
  `watch sandboxes`, and `get pods` — included in the chart's `templates/rbac.yaml`.
- After `openclaw mcp reload`, the very first tool call may hit a one-time
  "request before initialization" race; a retry succeeds. `FASTMCP_STATELESS_HTTP=1`
  mitigates this.
- Each `execute_python` call runs a fresh interpreter, so Python variables don't
  persist across calls. The sandbox *pod* persists (files, installed packages) until
  `reset_sandbox`.

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
| `mcp-sandbox-server/` | MCP bridge for isolated code execution | Manual (per cluster) |
| `mcp-memory-server/` | MCP per-agent persistent memory (pgvector) | Manual (per cluster) |

---

## Related Docs

| Doc | What it covers |
|-----|----------------|
| [Why the Extra Layers](why-the-extra-layers.md) | Management rationale — what Redis/pgvector/JWT/operator replaced or upgraded vs. what OpenClaw already provides |
| [Agent Suspend / Resume Contract](contracts/agent-suspend-resume.md) | What survives suspension and where it lives |
| [Cross-Agent Dispatch Contract](contracts/cross-agent-dispatch.md) | Attenuated-JWT secure channel for lead/worker collaboration |
| [Agent Memory Convention](conventions/agent-memory.md) | Per-agent pgvector schema model |
| [Agent Multi-Tenancy Primitives](conventions/agent-multi-tenancy.md) | NetworkPolicy + ResourceQuota + PodSecurity per agent (Item 10) |
| [Multi-Agent Research Demo](demos/multi-agent-research.md) | End-to-end lead/worker walkthrough |
| [Engineering Org Demo](demos/engineering-org.md) | Agent company doing a real refactor task (code → review → test) |
