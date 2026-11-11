# Agent Sandbox and Kata from agent code

The toolkit installs upstream `kubernetes-sigs/agent-sandbox` (version in `agent_sandbox_version`, default `v0.5.0`). Agents run model-generated code in short-lived pods from a warm pool. The Python SDK is `k8s-agent-sandbox`. Pin it to the same version as the controller: `pip install k8s-agent-sandbox==0.5.0`. (The router image is a separate, unpinned staging tag, `sandbox-router:latest-main`, so router behaviour can change between installs.)

## What is in the cluster

| Object | Name | Namespace |
|---|---|---|
| Controller | Deployment `agent-sandbox-controller` | `agent-sandbox-system` |
| Router (proxy to sandbox pods) | Deployment `sandbox-router-deployment`, Service `sandbox-router-svc:8080` | `agent-sandbox-system` |
| Router token | Secret `sandbox-router-auth`, key `ROUTER_AUTH_TOKEN` | `agent-sandbox-system` |
| Python template and pool | SandboxTemplate `python-sandbox-template`, SandboxWarmPool `python-pool` (5 warm pods) | `agent-sandbox-system` |
| Kata template and pool (only when `kata_containers_enabled: true`) | SandboxTemplate `kata-sandbox-template`, SandboxWarmPool `kata-pool` (1 warm pod) | `agent-sandbox-system` |

The namespace is fixed. Upstream manifests and both templates hard-code `agent-sandbox-system`.

## Three things the SDK needs

1. **`namespace="agent-sandbox-system"` on every call.** The SDK defaults to `"default"`. With the default you get one of:
   - `TimeoutError("Could not resolve sandbox name from claim 'sandbox-claim-...' within 180 seconds.")`
   - `SandboxWarmPoolNotFoundError("SandboxWarmPool requested does not exist: ...")`
   - from a pod whose Role is only in `agent-sandbox-system`, an immediate 403 `cannot create resource "sandboxclaims" ... in the namespace "default"`. That is a namespace mistake, not missing RBAC.
2. **The router token.** The router rejects calls without `Authorization: Bearer <ROUTER_AUTH_TOKEN>` with HTTP 401.
3. **Kubernetes RBAC for the caller.** The SDK creates `SandboxClaim`s itself through the Kubernetes API, and the router does not do it for you. A laptop with an admin kubeconfig already has the access. An agent **pod** needs a Role and RoleBinding (below), otherwise it gets `403 ... cannot create resource "sandboxclaims"`.

## RBAC for an in-cluster agent **(changes the cluster)**

Replace `<agent-ns>` and `<agent-sa>`. This covers the API calls the 0.5.0 SDK makes (`patch` is used only by its GKE snapshot extension). It does not read pods.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: sandbox-client
  namespace: agent-sandbox-system
rules:
  - apiGroups: ["extensions.agents.x-k8s.io"]
    resources: ["sandboxclaims"]
    verbs: ["create", "get", "list", "watch", "patch", "delete"]
  - apiGroups: ["agents.x-k8s.io"]
    resources: ["sandboxes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: sandbox-client-<agent-ns>
  namespace: agent-sandbox-system
subjects:
  - kind: ServiceAccount
    name: <agent-sa>
    namespace: <agent-ns>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: sandbox-client
```

Check it: `kubectl auth can-i create sandboxclaims.extensions.agents.x-k8s.io -n agent-sandbox-system --as=system:serviceaccount:<agent-ns>:<agent-sa>`

## Code

In a pod, connect to the router Service directly:

```python
import os
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

client = SandboxClient(connection_config=SandboxDirectConnectionConfig(
    api_url="http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080"))
sandbox = client.create_sandbox(warmpool="python-pool", namespace="agent-sandbox-system")
sandbox.connector.session.headers["Authorization"] = f"Bearer {os.environ['ROUTER_AUTH_TOKEN']}"
try:
    result = sandbox.commands.run("python3 -c 'print(6*7)'")
    print(result.stdout)
finally:
    sandbox.terminate()
```

- `warmpool="kata-pool"` runs the same code in a Kata microVM. A comment in `charts/agent-sandbox/kata-templates.yaml` shows `create_sandbox(template=...)`, which is wrong for SDK 0.5.0: the argument is `warmpool`.
- `commands.run()` runs the command without a shell. Wrap pipes and `&&` in `sh -c '...'`.
- `SandboxClient()` with no config uses a `kubectl port-forward` tunnel. That is for laptops, not pods.
- `SandboxInClusterConnectionConfig` connects straight to the sandbox pod and times out: sandbox pods accept traffic only from the router.
- The Python runtime image serves `POST /execute {"command": "..."}` on port 8888 and returns `stdout`, `stderr` and `exit_code`.

Mount the token in the agent pod. Copy the Secret into `<agent-ns>` first **(changes the cluster)**; see `namespace-onboarding.md`:

```yaml
env:
  - name: ROUTER_AUTH_TOKEN
    valueFrom:
      secretKeyRef: {name: sandbox-router-auth, key: ROUTER_AUTH_TOKEN}
```

## What code inside a sandbox can and cannot do

| | Sandbox pod |
|---|---|
| Ingress | Only from the router (`app=sandbox-router`) |
| Egress | Public IPs only. Private ranges (RFC 1918), link-local and the cluster are blocked. |
| DNS | Public resolvers `8.8.8.8` and `1.1.1.1`; no cluster DNS |
| Proxy | None. On a network where the internet is reachable only through a proxy, sandboxes have no egress. |
| Limits | 1 CPU, 1 GiB, non-root (uid 1000), all capabilities dropped |

So code in a sandbox **cannot** reach LiteLLM, Redis, pgvector, internal package mirrors or the Kubernetes API. This is intentional. Pass inputs in with the command or files and read outputs back through the SDK. For egress that a policy controls, use OpenShell (`openshell.md`).

A custom SandboxTemplate must keep the pod label `istio.io/dataplane-mode: none`. Without it the pod joins the mesh and the egress NetworkPolicy no longer applies.

## Kata microVMs

Kata is an infrastructure component. Its switches `kata_containers_enabled` and `kata_runtime` (`kata-fc`, `kata-qemu` or `both`) live in `env/<env>/global_config.yaml`, not in the toolkit config. The sandbox role uses `kata-fc` when that RuntimeClass exists, else `kata-qemu`.

- Kata pods run only on nodes labelled `ei-kata-eligible=true`: `kubectl get nodes -L ei-kata-eligible`.
- Runtime of the warm pod: `kubectl get pod -n agent-sandbox-system -l sandbox=kata -o jsonpath='{.items[0].spec.runtimeClassName}'`.

## Inspect

```bash
kubectl get deploy,pods,svc -n agent-sandbox-system
kubectl get sandboxtemplate,sandboxwarmpool,sandboxclaim,sandbox -n agent-sandbox-system
kubectl logs -n agent-sandbox-system deploy/agent-sandbox-controller
kubectl logs -n agent-sandbox-system -l app=sandbox-router
```

`kubectl get sandboxwarmpool` shows only `NAME READY AGE`; there is no SIZE column in v0.5.0.
