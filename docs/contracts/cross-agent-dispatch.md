# Cross-Agent Dispatch Contract

This contract defines how a **lead** agent spawns **worker** agents and dispatches
tasks to them over a secure, attenuated-authority channel. It is the basis for the
multi-agent "research → fan-out → synthesize" topology (proposal Item 5).

Dispatch is mediated by the **`agent-dispatch` MCP server**
(`core/helm-charts/mcp-dispatch-server/`), which is auto-wired into every `role=lead`
agent by the operator. Workers and solo agents never receive it — a worker cannot
spawn workers.

---

## Topology

```
User ─▶ Lead agent (role=lead, dispatch MCP wired)
          │
          │ spawn_worker × N        (operator creates role=worker Agent CRs)
          ├─────────────▶ Worker A (own namespace, own identity)
          ├─────────────▶ Worker B
          └─────────────▶ Worker C
          │
          │ dispatch_task(worker, prompt, allowed_tools)
          │   1. attenuate authority (allowed_tools ⊆ lead skills) — else REJECT
          │   2. mint Keycloak token from the LEAD's client (proves identity)
          │   3. verify token signature via JWKS
          │   4. wake worker if auto-suspended, then exec `openclaw agent` in its pod
          │   5. return { granted_claims, result }
          │
          └─ collect_results()  ─▶ lead synthesizes final report
          └─ terminate_worker() ─▶ operator tears the worker down
```

---

## Tools

All tools take `lead` (the calling lead's agent name) as the first argument. The
operator wires the lead's own identity in, so a lead can only act as itself.

| Tool | Signature | Guarantee |
|------|-----------|-----------|
| `spawn_worker` | `(lead, worker_name, skills=[...])` | Creates a `role=worker` Agent CR owned by the lead's owner, labelled `intel-stack.io/managed-by-lead=<lead>`. **Worker skills are intersected with the lead's** (attenuation at spawn). Idempotent (existing worker → no-op). |
| `list_workers` | `(lead)` | Lists workers labelled `managed-by-lead=<lead>` with phase + skills. |
| `dispatch_task` | `(lead, worker, prompt, allowed_tools=None)` | Runs one synchronous worker turn over the secure channel (see below). Returns `{status, worker, granted_claims, result}`. |
| `collect_results` | `(lead)` | Returns every result gathered for this lead this session. |
| `terminate_worker` | `(lead, worker)` | Deletes the worker Agent CR; operator cleans up namespace, PVC, identity. |

---

## The secure channel (attenuated JWT)

`dispatch_task` enforces **authority attenuation**: a worker's authority is always a
subset of the lead's. Enforcement is both *checked* and *visible*.

1. **Attenuation check.** `allowed_tools` must be a subset of the lead's `spec.skills`.
   An over-scoped request is **rejected before any work runs**:
   ```json
   {"status": "rejected",
    "reason": "REJECTED: requested tools ['shell'] exceed lead authority ['read_file','summarize','memory']"}
   ```

2. **Identity mint.** The dispatch server reads the lead's Keycloak client credentials
   (`<lead>-keycloak-credentials` secret in `agent-<lead>`) and mints a real access
   token via the `client_credentials` grant. This proves the dispatch is acting on
   behalf of a genuine, registered lead identity.

3. **Signature verification.** The minted token is verified against Keycloak's JWKS
   (`/realms/<realm>/protocol/openid-connect/certs`, RS256). Only a token Keycloak
   actually signed passes.

4. **Granted claims.** The response carries the attenuated authority envelope so the
   caller (and demo UI) can display exactly what the worker ran with:
   ```json
   {"parent_id": "research-lead",
    "allowed_tools": ["read_file"],
    "allowed_models": ["Qwen/Qwen3-Coder-30B-A3B-Instruct"],
    "expires_at": "2026-07-02T18:13:16+00:00",
    "identity_token_verified": true}
   ```

If the lead's Keycloak client is unavailable, `identity_token_verified` is `false` and
the dispatch still runs with the attenuated claim set (degrades gracefully — the
subset check is the hard gate; the token is the identity proof).

---

## Worker turn execution (sync via OpenClaw gateway)

The worker reply path is **synchronous**. `dispatch_task`:

1. **Wakes the worker if suspended.** If the worker was auto-idle-suspended (scaled to
   zero), the dispatch server patches its Agent CR `desiredState=Running` and waits
   (bounded, 180s) for the pod to become Ready. This makes dispatch robust across the
   long idle windows of a live demo.
2. **Execs `openclaw agent`** in the worker's `openclaw` container:
   ```
   openclaw agent --agent main --message "<prompt>" --json --timeout <WORKER_TURN_TIMEOUT>
   ```
3. **Parses the reply.** The CLI emits a Python-repr-style envelope (single quotes,
   `None`/`True`/`False`), *not* strict JSON. The parser locates the first balanced
   `{...}` block and tries `json.loads` then `ast.literal_eval`, reading the answer from
   `result.payloads[].text`.

### RBAC required by the dispatch server (least-privilege exec)

The `mcp-dispatch-server` ServiceAccount holds a **ClusterRole** with only:

| Resource | Verbs | Why |
|----------|-------|-----|
| `agents.intel-stack.io` | get, list, watch, create, delete, **patch, update** | spawn/list/terminate workers; patch `desiredState` to wake them |
| `secrets` | get, list | read the lead's Keycloak client credentials |

**It has NO cluster-wide `pods` / `pods/exec`.** Instead, the operator creates a
**namespace-scoped `Role` + `RoleBinding` (`dispatch-exec`)** in each agent
namespace (`agent-<name>`) on creation, granting the dispatch ServiceAccount
`pods` (get/list) and `pods/exec` (get/create) **only there**. So the dispatch
server can exec into worker pods it manages — and is denied exec into any other
pod in the cluster (kube-system, other tenants, infra). This bounds the blast
radius: a compromised dispatch server cannot exec cluster-wide.

The operator can grant these verbs because it holds `pods/exec` itself (used for
lead workspace-seeding), so the RoleBinding is not a privilege escalation.

> **Gotcha:** the Kubernetes websocket exec (`connect_get_namespaced_pod_exec`)
> authorizes against the **`get`** verb on `pods/exec`, not only `create` — the
> scoped Role grants both.

> **Client version:** the dispatch server pins `kubernetes>=35,<36`. The 36.x client
> mishandles the None error body on a failed exec handshake
> (`'NoneType' object has no attribute 'decode'`), masking the real error.

---

## Failure modes

| Situation | Behaviour |
|-----------|-----------|
| `allowed_tools` exceeds lead skills | `{"status":"rejected", ...}` — no work runs |
| Lead not found | `{"error":"lead '<x>' not found"}` |
| Worker auto-suspended | Auto-resumed before exec (bounded wait) |
| Keycloak unavailable | Runs with `identity_token_verified:false` |
| Worker turn errors | `result: "(worker turn failed: <reason>)"` |

---

## Related

- [Agent Suspend / Resume Contract](agent-suspend-resume.md) — the lifecycle the
  auto-resume path drives.
- [Agent Memory Convention](../conventions/agent-memory.md) — where a lead persists
  synthesized findings.
- [Multi-Agent Research Demo](../demos/multi-agent-research.md) — the management-facing
  walkthrough of this contract in action.
