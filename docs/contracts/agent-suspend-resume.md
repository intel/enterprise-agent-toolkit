# Agent Suspend / Resume Contract

This contract defines what the Agent operator guarantees when an agent is
suspended (scaled to zero) and resumed. It is the basis for the "persistent"
claim — agents survive pod eviction, node failure, rolling updates, and
idle-cost suspension.

There is no separate session service: the operator's reconcile loop owns
lifecycle, and this contract is what that loop guarantees.

---

## Lifecycle phases

```
Pending ─▶ Running ─▶ IdleSuspended ─▶ Resuming ─▶ Running
                ▲                                      │
                └──────────────────────────────────────┘

Terminating (on delete)   Failed (on unrecoverable error)
```

| Phase | Meaning |
|-------|---------|
| `Pending` | Agent CR created; operator provisioning namespace/backend/identity |
| `Running` | OpenClaw pod up, agent reachable |
| `IdleSuspended` | Scaled to zero replicas; state retained on PVC + Redis |
| `Resuming` | Suspend lifted; waiting for pod to become Ready |
| `Terminating` | Being deleted; resources cleaned up |
| `Failed` | Unrecoverable error (documented in `status.conditions`) |

---

## Triggers

**Manual** — set `spec.desiredState`:
```bash
kubectl patch agent my-agent --type=merge -p '{"spec":{"desiredState":"Suspended"}}'
kubectl patch agent my-agent --type=merge -p '{"spec":{"desiredState":"Running"}}'
```

**Auto-idle** — the operator runs a timer (every 5 min) and suspends any
`Running` agent whose `status.lastActivity` is older than
`AUTO_SUSPEND_IDLE_MINUTES` (default 30; set `0` to disable). Auto-suspend sets
`status.suspendReason=auto-idle` and does **not** change `spec.desiredState`, so
operators can tell system-initiated sleep from user-initiated sleep. A manual
`desiredState=Running` always overrides and resumes the agent.

---

## What survives suspend

| State component | Where it lives | Survives suspend |
|---|---|---|
| Live LLM context buffer | Redis, key `agent:{id}:ctx` | Yes — TTL extended to `CONTEXT_TTL_SECONDS` (default 24h) on suspend |
| Working files / sessions / config | PVC `/home/openclaw/.openclaw/{workspace,agents,state}` | Yes — PVC retained across scale-to-zero |
| Gateway token | K8s Secret `{name}-gateway-token` | Yes |
| Keycloak credentials | K8s Secret `{name}-keycloak-credentials` | Yes |
| Tool / MCP connection state | Re-resolved by URL on resume | No — re-established from `mcp.servers` config |
| Long-term memory | pgvector `agent:{id}` namespaces (Item 6, when added) | Untouched — not part of the checkpoint |
| `runtimeContext` invariants (Claw PR #90101) | `status.runtimeContextSnapshot` | No-op today — see below |

### Underlying primitive

Suspend is implemented by patching the backend CR:
`OpenClawInstance.spec.suspended = true`. The OpenClaw operator scales the
workload to **zero replicas** while keeping the Service, ConfigMap, RBAC,
NetworkPolicy, and PVC fully managed. Setting it back to `false` resumes.

Because all OpenClaw state lives on the retained PVC, working files and sessions
survive automatically — no explicit checkpoint/restore is needed for them.

### `runtimeContext` invariants (graceful degradation)

OpenClaw PR #90101 adds a `runtimeContext` surface (`self`, `offload_targets`,
`cost_estimate`). A pod resuming on a different node could see a changed
environment. The contract calls for snapshotting a digest at suspend and
re-emitting a `runtime.self` delta on mismatch at resume.

**Current status:** the deployed OpenClaw image predates this surface, so the
snapshot/compare step is a documented **no-op**. When the runtime gains the
surface, the operator's `_snapshot_context` gains the digest logic without
changing the contract.

---

## Status fields

| Field | Meaning |
|-------|---------|
| `status.phase` | Current lifecycle phase |
| `status.lastActivity` | Timestamp used for idle detection (best-effort — see below) |
| `status.suspendedAt` | When the agent was last suspended |
| `status.resumedAt` | When the agent was last resumed |
| `status.suspendReason` | `manual` or `auto-idle` |
| `status.contextBufferKey` | Redis key for the live context buffer |

### `lastActivity` limitation (v1alpha1)

The operator cannot observe OpenClaw chat activity directly. `lastActivity` is
updated on create, resume, and spec change — a best-effort proxy. A future
enhancement will poll the OpenClaw gateway session API for true last-message
time. Until then, an actively-chatting-but-otherwise-untouched agent could be
auto-suspended; raise `AUTO_SUSPEND_IDLE_MINUTES` or set it to `0` to disable
if this matters for your deployment.

---

## Configuration

Operator Helm values (`core/helm-charts/agent-operator/values.yaml`):

| Value | Default | Env var | Purpose |
|-------|---------|---------|---------|
| `autoSuspend.idleMinutes` | `30` | `AUTO_SUSPEND_IDLE_MINUTES` | Idle window before auto-suspend; `0` disables |
| `redisUrl` | `redis://redis-stack-server.redis.svc.cluster.local:6379` | `REDIS_URL` | Live-context buffer store |
| `contextTtlSeconds` | `86400` | `CONTEXT_TTL_SECONDS` | TTL applied to `agent:{id}:ctx` on suspend |

---

## Verification

```bash
# Create (defaults to Running)
helm install life-agent core/helm-charts/agent-instance/ \
  --set owner=user@example.com --set "skills={shell,read_file}"
kubectl get agent life-agent            # DESIRED=Running PHASE=Running

# Write a marker to prove PVC survives
kubectl exec -n agent-life-agent life-agent-0 -c openclaw -- \
  sh -c 'echo hi > /home/openclaw/.openclaw/workspace/marker.txt'

# Suspend
kubectl patch agent life-agent --type=merge -p '{"spec":{"desiredState":"Suspended"}}'
kubectl get agent life-agent            # PHASE=IdleSuspended
kubectl get pods -n agent-life-agent    # 0 pods
kubectl get pvc  -n agent-life-agent    # retained

# Resume
kubectl patch agent life-agent --type=merge -p '{"spec":{"desiredState":"Running"}}'
kubectl get agent life-agent            # PHASE=Running
kubectl exec -n agent-life-agent life-agent-0 -c openclaw -- \
  cat /home/openclaw/.openclaw/workspace/marker.txt   # -> hi  (state survived)

# Auto-idle (short window for testing)
helm upgrade agent-operator core/helm-charts/agent-operator/ \
  -n agent-operator-system --set autoSuspend.idleMinutes=1 ...
# Leave the agent idle; within one timer tick (5 min) it auto-suspends:
kubectl get agent life-agent            # PHASE=IdleSuspended, suspendReason=auto-idle
```
