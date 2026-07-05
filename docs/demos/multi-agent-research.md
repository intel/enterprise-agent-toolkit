# Demo: Multi-Agent Research over a Secure Channel

A management-facing walkthrough of the lead/worker topology: a **lead** agent
decomposes a research question, **spawns worker agents on demand**, dispatches
sub-topics to them over an **attenuated-JWT secured channel**, collects their
findings, and synthesizes a final report. Workers are torn down when done.

This exercises proposal **Item 5** on top of the persistent-agent MVP.

> Contract reference: [Cross-Agent Dispatch Contract](../contracts/cross-agent-dispatch.md).

---

## What the audience sees

1. A single lead agent, then **three worker agents appear** in real time.
2. Each dispatch prints the **attenuated authority** the worker was granted, and
   `identity_token_verified: true` (a real Keycloak-signed token).
3. An **over-scoped request is rejected** before any work runs.
4. The workers answer in parallel; the lead **synthesizes** one report.
5. The workers are **terminated** and their namespaces disappear.

---

## Prerequisites (already deployed)

- Agent operator with role branching (`role=lead` auto-wires the dispatch MCP).
- `mcp-dispatch-server` running in `agent-operator-system`.
- Keycloak enabled on the operator (per-agent clients for identity).
- A lead agent with the `memory` skill for synthesis (e.g. `research-lead`).

Create the lead if needed:

```bash
helm install research-lead core/helm-charts/agent-instance/ \
  --set owner=vkumar4@example.com \
  --set role=lead \
  --set "skills={read_file,summarize,memory}"
```

---

## Watch pane

In a side terminal, watch the fleet grow and shrink live:

```bash
watch -n2 kubectl get agents -A
```

---

## Run it

The lead drives these tools through its wired `dispatch` MCP server. For the demo you
can drive them directly against the dispatch server (what the lead does under the hood):

```bash
./run-multi-agent-demo.sh
```

Or step through manually with an in-cluster MCP client:

```bash
kubectl exec -n agent-operator-system deploy/mcp-dispatch-server -- sh -c 'PYTHONPATH=/deps python3 - <<PY
import asyncio, json
from fastmcp import Client

LEAD = "research-lead"
TASKS = {
  "w-kubernetes": "In 2 sentences, the role of Kubernetes in scaling cloud-native apps?",
  "w-serverless": "In 2 sentences, key benefits of serverless computing for cloud-native apps?",
  "w-edge":       "In 2 sentences, why edge computing matters for cloud-native architectures?",
}

async def main():
    async with Client("http://localhost:8000/sse") as c:
        # 1. Fan out: spawn a worker per sub-topic (skills attenuated to a subset of the lead)
        for w in TASKS:
            print(await c.call_tool("spawn_worker",
                {"lead": LEAD, "worker_name": w, "skills": ["read_file","summarize"]}))
        # (wait for worker pods to become Ready — see run-multi-agent-demo.sh)

        # 2. Secure dispatch: over-scoped request is REJECTED
        bad = await c.call_tool("dispatch_task",
            {"lead": LEAD, "worker": "w-edge", "prompt": "hi", "allowed_tools": ["shell"]})
        print("OVER-SCOPE:", bad.data)   # -> {"status":"rejected", ...}

        # 3. Valid dispatch in parallel; each returns verified attenuated claims
        async def one(w, p):
            r = await c.call_tool("dispatch_task",
                {"lead": LEAD, "worker": w, "prompt": p, "allowed_tools": ["read_file"]})
            return w, r.data
        for w, d in await asyncio.gather(*[one(w,p) for w,p in TASKS.items()]):
            print(w, "verified=", d["granted_claims"]["identity_token_verified"])
            print("   ", d["result"][:200])

        # 4. Collect for synthesis
        print("COLLECTED:", len(await c.call_tool("collect_results", {"lead": LEAD}).data))

        # 5. Teardown
        for w in TASKS:
            print(await c.call_tool("terminate_worker", {"lead": LEAD, "worker": w}))

asyncio.run(main())
PY'
```

---

## Talking points for the room

- **On-demand fan-out.** Workers are real, isolated OpenClaw agents (own namespace,
  own identity, own PVC) created at runtime by the lead — not pre-provisioned.
- **Least privilege, enforced.** A worker never exceeds its lead's authority. The
  over-scope rejection is the visible proof: the platform refuses to widen authority.
- **Verifiable identity.** Every dispatch carries a Keycloak-signed token, verified
  against JWKS. `identity_token_verified: true` is not a claim we make — it's checked.
- **Resilient.** Workers auto-suspend when idle to save cost; dispatch transparently
  wakes them. State survives on the PVC (see the suspend/resume contract).
- **Backend-agnostic.** Dispatch is an MCP server. Swap OpenClaw for another runtime
  and the coordination surface is unchanged.

---

## Expected result

```
w-kubernetes appears ... w-serverless appears ... w-edge appears   (watch pane)
OVER-SCOPE: {'status': 'rejected', 'reason': "REJECTED: requested tools ['shell'] ..."}
w-kubernetes verified= True
    Kubernetes automates deployment, scaling, and management of containerized ...
w-serverless verified= True
    Serverless computing offers automatic scaling and pay-per-execution pricing ...
w-edge verified= True
    Edge computing is crucial ... reduces latency by processing data closer ...
COLLECTED: 3
Terminated worker 'w-kubernetes' / 'w-serverless' / 'w-edge'
```

The watch pane returns to just the lead and any pre-existing agents.
