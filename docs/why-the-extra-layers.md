# Why the Extra Layers — OpenClaw vs. the Platform Around It

**Audience:** management / architecture review.
**Question this answers:** *"OpenClaw is already a persistent, first-class agent. Why did we add Redis, pgvector, an isolated code-execution sandbox, attenuated JWTs, and a Kubernetes operator on top of it? What did those replace or upgrade, and was it necessary?"*

---

## TL;DR

OpenClaw, unmodified, **is** a persistent, first-class agent. If we removed every
layer we added, a single OpenClaw agent would still remember its conversations,
keep its memory, and survive pod restarts — all on its own.

We did **not** add these layers to *make* it persistent. We added them to turn a
**single self-persisting agent** into a **centrally-managed, multi-tenant fleet**
with shared memory, cost controls, and secure agent-to-agent collaboration.

One capability is genuinely new (secure cross-agent delegation via attenuated
JWTs). The rest are **backend upgrades** — we swapped OpenClaw's local, single-node
stores for networked, multi-tenant equivalents that an enterprise fleet requires.

---

## What OpenClaw already gives us (verified, not assumed)

We confirmed this against a vanilla OpenClaw instance carrying **none** of our
additions (no Redis, pgvector, or JWT env vars):

| Capability | Where OpenClaw stores it natively | Persistent on its own? |
|------------|-----------------------------------|------------------------|
| Conversation history | `sessions/*.jsonl` on the pod's PVC | ✅ Yes |
| Agent state | `state/openclaw.sqlite` | ✅ Yes |
| Long-term memory | `memories_*.sqlite` + `MEMORY.md` / `DREAMS.md` (with `memory promote` ranking) | ✅ Yes |
| Working files | `workspace/` | ✅ Yes |
| Code execution / sandbox | native `openclaw sandbox` (local containers) + `exec-policy` security model | ✅ Yes |
| Identity / gateway | gateway service + token auth | ✅ Yes |

**Conclusion:** "persistent" and "first-class" are properties of OpenClaw itself.
They are not something our platform created.

---

## What we added, and why — the honest ledger

Each layer is classified as an **UPGRADE** (replaced a local OpenClaw store with a
fleet-grade one) or **NEW** (a capability OpenClaw does not have).

### 1. pgvector per-agent memory schemas — **UPGRADE**

- **Replaced:** OpenClaw's local `memories_*.sqlite`.
- **Why:** SQLite memory is per-pod and local. A fleet needs memory that is
  **centrally queryable, backed up with the database, and isolated per agent**
  (`agent_{name}` schemas) so tenants never see each other's data. It also lets
  memory outlive the pod entirely and be searched/administered from outside.
- **Was OpenClaw persistent without it?** Yes — locally. We traded *local* durability
  for *networked, multi-tenant, queryable* durability.
- **Isolation is enforced by construction, not just structural.** Separate schemas
  alone only *separate* data; they do not *authorize* access. The memory tools have
  **no target-agent parameter** — the schema is derived from the caller's verified
  Keycloak identity (injected as unforgeable transport headers), so reading another
  agent's memory is not even expressible. Cross-agent knowledge flows only through
  the secured dispatch channel. See
  [Agent Memory Convention → Authorization](conventions/agent-memory.md#authorization--private-only-inexpressible-cross-agent-access).

### 2. Redis live-context cache (`agent:{id}:ctx`) — **UPGRADE (additive)**

- **Added alongside:** OpenClaw's on-disk sessions.
- **Why:** an extra fast tier for live context with a TTL that we deliberately
  extend across a suspend window, so a scaled-to-zero agent resumes warm. Sessions
  on the PVC already survive; Redis makes resume *fast and seamless*.
- **Was OpenClaw persistent without it?** Yes — sessions were already on disk. Redis
  is a performance/UX tier, not the source of persistence.

### 3. Attenuated JWTs for agent-to-agent dispatch — **NEW capability**

- **Replaced:** nothing. OpenClaw has no native model for one agent to delegate
  scoped authority to another.
- **Why:** the lead/worker topology requires a **lead to spawn workers and hand them
  authority that is provably a subset of its own** (least privilege), with identity
  verified via Keycloak/JWKS and over-scoped requests rejected. This is a security
  boundary between agents that simply does not exist in single-agent OpenClaw.
- **This is the one layer that is a true addition, not an upgrade.** See
  [cross-agent-dispatch.md](contracts/cross-agent-dispatch.md).

### 4. agent-sandbox: Kubernetes-native code-execution isolation — **UPGRADE**

- **Replaced:** OpenClaw's native local sandbox (`openclaw sandbox`, which manages
  containers on the agent's own host) and the built-in `exec` tool.
- **Why:** running untrusted, model-generated code *inside* or *next to* the agent
  pod is a weak boundary for a shared cluster. Our agent-sandbox routes execution to
  a dedicated controller (`sandbox-router` + `agent-sandbox-controller`) that spawns
  **ephemeral, isolated pods per execution**, then tears them down — so an agent's
  code runs in a disposable, network-policied sandbox, not on the agent's own host.
  Delivered to the agent as the **`mcp-sandbox-server`** MCP tool
  (`execute_python` / `execute_shell`), so it plugs in like memory and dispatch.
- **Was OpenClaw sandboxed without it?** Yes — locally. We traded *local, host-level*
  execution for *cluster-native, per-run, disposable-pod* isolation with central
  policy. See [agent-sandbox.md](agent-sandbox.md).

### 5. Kubernetes operator: lifecycle, suspend/resume, provisioning — **UPGRADE**

- **Replaced:** manual, per-agent operation.
- **Why:** OpenClaw persists its own state on a PVC, but *someone* has to create the
  namespace, identity, memory schema, wire the tools, and scale idle agents to zero
  to save cost — then resume them with state intact. The operator automates that
  lifecycle across the whole fleet. The **persistence is OpenClaw's; the
  fleet-wide automation is ours.** See
  [agent-suspend-resume.md](contracts/agent-suspend-resume.md).

---

## The distinction in one line

> **OpenClaw's persistence** = *one agent remembers itself across restarts.*
> **Our platform's persistence** = *a governed fleet of agents with shared,
> queryable memory, cost-based suspension, and secure inter-agent collaboration.*

We built the second **on top of** — not **instead of** — the first.

---

## "Could we have shipped without the extra layers?"

Yes, for a **single agent on a single node**. It would still be persistent and
first-class. What we would lose at **fleet/enterprise** scale:

| Without our layer | Consequence |
|-------------------|-------------|
| pgvector | Memory trapped per-pod; no central query, no cross-agent knowledge, weaker backup/tenant isolation |
| Redis ctx | Cold, slower resumes after suspend |
| Attenuated JWT | **No safe way for agents to collaborate** — a worker could act with full authority; no least-privilege boundary |
| agent-sandbox | Model-generated code runs on the agent's own host, not a disposable isolated pod — weaker blast-radius control on a shared cluster |
| Operator | Manual provisioning; no idle-cost suspension; no state-preserving resume automation |

The layers are the difference between *"a persistent agent"* and *"a persistent,
multi-tenant, cost-controlled, securely-collaborating agent platform."*

---

## Backend-agnostic by design (the hedge)

Crucially, none of these layers are welded to OpenClaw:

- Memory, sandbox, and dispatch are delivered as **MCP servers** — a standard
  protocol any runtime can consume.
- The Agent CR carries a `runtime` field (`claw` today).

If we replace OpenClaw with another agent runtime tomorrow, the memory, dispatch,
and sandbox layers keep working unchanged. **OpenClaw is the current implementation
of the "agent" slot — not the platform.** That protects the investment in these
layers regardless of the underlying agent engine.

---

## Related

- [Cross-Agent Dispatch Contract](contracts/cross-agent-dispatch.md) — the attenuated-JWT secure channel (the NEW capability)
- [Agent Suspend / Resume Contract](contracts/agent-suspend-resume.md) — what survives suspension and where it lives
- [Agent Memory Convention](conventions/agent-memory.md) — the pgvector per-agent schema model
- [Agent Multi-Tenancy Primitives](conventions/agent-multi-tenancy.md) — NetworkPolicy/ResourceQuota/PodSecurity defense-in-depth (Item 10)
- [Persistent Agents](agent.md) — the end-to-end platform overview
