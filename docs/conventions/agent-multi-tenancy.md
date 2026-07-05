# Agent Multi-Tenancy Primitives (Item 10)

Every agent runs in its own namespace (`agent-{name}`). This document defines the
**isolation boundary** the operator stamps on that namespace: network
micro-segmentation, resource caps, and a PodSecurity level. These are
**defense-in-depth** — they harden *reachability and blast radius*. They do **not**
replace the application-level memory authorization (see
[Agent Memory Convention → Authorization](agent-memory.md#authorization--private-only-inexpressible-cross-agent-access));
both layers stand.

All three primitives are applied by the operator during `on_create`
([configmap-controller.yaml](../../core/helm-charts/agent-operator/templates/configmap-controller.yaml))
and garbage-collected when the agent namespace is deleted. Enforcement is real: the
cluster CNI is **Calico**, which enforces `networking.k8s.io/v1` NetworkPolicy.

---

## 1. NetworkPolicy — default-deny + strict egress allowlist

Policy `agent-default-deny` in each agent namespace (`podSelector: {}` = all pods):

- **Ingress:** allowed only from the **same namespace** (OpenClaw gateway + sidecars
  talk intra-namespace). All cross-namespace ingress is denied → other tenants cannot
  reach an agent's pods directly.
- **Egress:** denied except an allowlist:
  - **DNS** — always allowed (kube-system `k8s-app=kube-dns`, UDP+TCP 53). Omitting
    this breaks all name resolution — the most common NetworkPolicy footgun.
  - Each entry in `multiTenancy.networkPolicy.egressAllow` (namespace + ports).
    Defaults: LiteLLM, memory MCP, dispatch MCP, Keycloak, sandbox router, vLLM.
  - The **public internet and everything unlisted is denied.**

> **Ports are pod/targetPorts, not Service ports.** Calico enforces against the
> destination pod's real port. Where a Service does `port ≠ targetPort` (e.g.
> Keycloak `80→8080`, vLLM `80→2080`), the allowlist entry must use the **targetPort**
> (8080 / 2080). Using the service port silently drops the traffic. Each default
> entry documents its `svc→pod` mapping.

To grant an agent a new dependency, add a `{namespace, ports}` entry to
`egressAllow` — no code change. Skills implying broad egress (e.g.
`browser-automation` needing the internet) require widening this list explicitly.

**Verified:** from an agent pod, allowlisted services (memory, LiteLLM, Keycloak) are
reachable; the public internet and non-allowlisted namespaces (e.g. Redis) time out.

---

## 2. ResourceQuota + LimitRange — per agent namespace

- `agent-quota` (ResourceQuota) caps `requests/limits.cpu/memory`, `pods`,
  `persistentvolumeclaims` from `multiTenancy.resourceQuota.hard`.
- `agent-limits` (LimitRange) sets default per-container requests/limits, so pods that
  declare no resources are still bounded — the operator does not set resources on the
  OpenClawInstance, so the LimitRange is what actually enforces per-pod sizing.

**Per-owner note (honest scope).** The design is one namespace **per agent**, so a
ResourceQuota is naturally per-agent. A ResourceQuota cannot span namespaces, so true
per-owner *resource pooling* is out of scope here. What we enforce instead is a
**per-owner agent-count cap** (`multiTenancy.maxAgentsPerOwner`, `0` = disabled): on
create, the operator counts Agent CRs with the same `spec.owner.principal` and marks
the agent `Failed` beyond the cap. Finer per-owner resource aggregation is a future
hierarchical-namespace concern.

**Verified:** quota shows live usage; a 2nd agent for an owner at cap 1 →
`Failed: owner '<x>' has 2 agents, exceeds cap 1`.

---

## 3. PodSecurity Standards

The operator stamps `pod-security.kubernetes.io/enforce|warn|audit =
multiTenancy.podSecurity.level` on the agent namespace (default **`restricted`**).

> **Validated:** OpenClaw agent pods (which use `shareProcessNamespace` and multiple
> sidecars) **do reach Running under `restricted`** in this environment — no admission
> failure. If a future image or sidecar violates `restricted`, set
> `multiTenancy.podSecurity.level: baseline` and redeploy; the level is a value.

The cluster has the PodSecurity admission plugin enabled but no cluster-wide default,
so enforcement is per-namespace via these labels — which is exactly what the operator
now sets.

---

## Configuration

`multiTenancy` in [agent-operator/values.yaml](../../core/helm-charts/agent-operator/values.yaml):

```yaml
multiTenancy:
  networkPolicy:
    enabled: true
    egressAllow:                 # ports = pod/targetPort (see note above)
      - { namespace: "genai-gateway",         ports: [4000] }
      - { namespace: "pgvector",              ports: [8000] }
      - { namespace: "agent-operator-system", ports: [8000] }
      - { namespace: "auth-apisix",           ports: [8080] }   # svc 80→pod 8080
      - { namespace: "agent-sandbox",         ports: [8080] }
      - { namespace: "default",               ports: [2080] }   # svc 80→pod 2080
  resourceQuota:
    enabled: true
    hard: { requests.cpu: "4", requests.memory: "8Gi", limits.cpu: "8", limits.memory: "16Gi", pods: "10", persistentvolumeclaims: "5" }
  limitRange:
    enabled: true
    defaultRequest: { cpu: "250m", memory: "256Mi" }
    default:        { cpu: "1",    memory: "1Gi" }
  podSecurity: { enabled: true, level: "restricted" }
  maxAgentsPerOwner: 0           # 0 = disabled
```

The operator ClusterRole grants `networkpolicies`, `resourcequotas`, and
`limitranges` (added for Item 10).

---

## Migration note

These primitives apply to **newly created** agent namespaces. Agents created before
Item 10 (e.g. `research-lead`) have no NetworkPolicy/quota/PSS labels until
**re-provisioned** (`helm uninstall` + `helm install`, or delete/recreate the Agent
CR) — the same migration caveat as the memory-auth change.

---

## Boundary vs. the memory auth layer

| Control | Layer | Governs | Stops the alice→bob memory read? |
|---------|-------|---------|----------------------------------|
| NetworkPolicy | Network (Calico) | Which pods/ports are reachable | No — narrows *who can connect*, not the request semantics |
| ResourceQuota / PSS | Node / admission | Resource use, pod security | No |
| **Memory identity auth** | **Application** | **Whose schema a call touches** | **Yes — the actual data-isolation control** |

NetworkPolicy is defense-in-depth: it shrinks the attack surface (only agent pods can
even reach the memory service) but the memory server's identity-derived schema is what
enforces per-tenant data isolation.

---

## Files

| File | Role |
|------|------|
| `core/helm-charts/agent-operator/templates/configmap-controller.yaml` | `_apply_network_policy`, `_apply_resource_quota`, per-owner cap, PSS labels in `_ensure_namespace` |
| `core/helm-charts/agent-operator/templates/clusterrole.yaml` | RBAC for networkpolicies/resourcequotas/limitranges |
| `core/helm-charts/agent-operator/values.yaml` | `multiTenancy` config |
| `docs/conventions/agent-multi-tenancy.md` | This document |
