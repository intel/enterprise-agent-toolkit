# Agent Sandbox

Agent Sandbox provides **isolated, ephemeral Kubernetes pod environments** for
safe code execution by AI agents. Each sandbox is a fully isolated pod with its
own filesystem, network namespace, and process tree — the agent can run
arbitrary code, install packages, and write files without ever touching the host
or other workloads.

The implementation is based on
[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox).

---

## Architecture

```
Agent (e.g. Coding Agent)
        │
        │  HTTP  (in-cluster DNS)
        ▼
sandbox-router-svc.agent-sandbox.svc.cluster.local:8080
        │
        │  creates SandboxClaim CR via Kubernetes API
        ▼
  agent-sandbox-controller  (agent-sandbox namespace)
        │
        │  spawns pod from SandboxTemplate spec
        ▼
  sandbox-claim-<id>  (pod in agent-sandbox namespace)
        │
        │  NetworkPolicy: allows ingress from app=sandbox-router
        │  in the SAME namespace only
        ▼
  python-runtime-sandbox — uvicorn on :8888
        POST /execute  {"command": "..."}  →  {stdout, stderr, exit_code}
```

**Key design points:**

- All components live in the **`agent-sandbox`** namespace so the
  controller-generated `NetworkPolicy` (which allows ingress only from pods
  labelled `app=sandbox-router` in the same namespace) applies correctly.
- The **sandbox-router** is the only component that calls the Kubernetes API —
  client pods (like the Coding Agent) need no RBAC of their own.
- All images are pulled from **published registries** — no local builds required.

---

## Deployed Components

| Component | Kind | Namespace | Image Source |
|---|---|---|---|
| `agent-sandbox-controller` | Deployment | `agent-sandbox` | `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0` |
| CRDs | ClusterScoped | — | `sandboxes`, `sandboxtemplates`, `sandboxclaims`, `sandboxwarmpools` (v1beta1) |
| `sandbox-router-deployment` | Deployment (×2) | `agent-sandbox` | `us-central1-docker.pkg.dev/.../sandbox-router:latest-main` (staging) |
| `sandbox-router-svc` | Service | `agent-sandbox` | ClusterIP :8080 |
| `python-sandbox-template` | SandboxTemplate CR | `agent-sandbox` | Uses `registry.k8s.io/agent-sandbox/python-runtime-sandbox:v0.5.0` |

---

## Configuration

### Enable in `core/inventory/agentic-config.cfg`

```ini
deploy_agent_sandbox=on
```

Set to `off` to skip deployment. On re-runs, if the `agent-sandbox` namespace
already exists the deployment is automatically skipped (resume mode).

### Version pin in `core/inventory/metadata/agentic-metadata.cfg`

```ini
agent_sandbox_version="v0.5.0"
```

This controls the version of official release manifests fetched from GitHub and
the image tags used for the runtime components. Update the version here to upgrade.

---

## Deployment

Agent Sandbox is deployed as part of the standard stack run using **Ansible**:

```bash
# core/inventory/agentic-config.cfg
deploy_agent_sandbox=on

./deploy-agentic-stack.sh
```

The Ansible playbook runs 7 task groups:

| Task Group | Action |
|---|---|
| 1 | Prerequisites — Verify kubectl and cluster connectivity |
| 2 | Install core components via official manifest (CRDs + controller) |
| 3 | Wait for controller readiness |
| 4 | Deploy sandbox-router with staging image |
| 5 | Apply default SandboxTemplate and create default WarmPool (`python-pool`, size 5) |
| 6 | Final verification (pods ready, v1beta1 API available) |
| 7 | Cleanup temporary files |


## Verification

```bash
# All components should be Running
kubectl get pods -n agent-sandbox

# Confirm CRDs are registered (should show v1alpha1 and v1beta1)
kubectl get crd sandboxes.agents.x-k8s.io -o jsonpath='{.spec.versions[*].name}'
# Expected: v1alpha1 v1beta1

# Check the SandboxTemplate exists
kubectl get sandboxtemplate -n agent-sandbox
# Expected: python-sandbox-template

# Check default WarmPool exists
kubectl get sandboxwarmpool -n agent-sandbox python-pool
# Expected: SIZE=5 and READY=5

# Verify controller deployment
kubectl get deployment -n agent-sandbox agent-sandbox-controller

# Verify router deployment
kubectl get deployment -n agent-sandbox sandbox-router-deployment

# Quick end-to-end health check via the router
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080 &
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

---

## Default SandboxTemplate

The stack ships one template out of the box:
`core/helm-charts/agent-sandbox/default-templates.yaml`

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: python-sandbox-template
  namespace: agent-sandbox
spec:
  service: true          # headless Service created per pod — required for SDK DNS mode
  podTemplate:
    spec:
      containers:
      - name: runtime
        image: registry.k8s.io/agent-sandbox/python-runtime-sandbox:v0.5.0
        imagePullPolicy: IfNotPresent
        ports:
        - name: api
          containerPort: 8888
          protocol: TCP
        resources:
          requests: { cpu: "250m", memory: "256Mi" }
          limits:   { cpu: "1000m", memory: "1Gi" }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1000
          capabilities:
            drop: [ALL]
```

The `python-runtime-sandbox` image exposes a FastAPI server on port 8888:

```
POST /execute
Body: {"command": "<shell command>"}
Response: {"stdout": "...", "stderr": "...", "exit_code": 0}
```

---

## Adding a Custom SandboxTemplate

You can add any number of templates for different runtimes (Node.js, R, Java,
etc.) by creating a new `SandboxTemplate` CR.

### 1. Build and push your runtime image

The runtime image must expose:
- `POST /execute` → `{stdout, stderr, exit_code}` — same API as `python-runtime-sandbox`

For production deployments, push to your registry:

```bash
docker build -t your-registry.io/my-node-sandbox:v1.0 ./path/to/dockerfile-dir
docker push your-registry.io/my-node-sandbox:v1.0
```

For local (no-registry) development with Kind/Minikube, load into cluster:

```bash
# Kind
kind load docker-image your-registry.io/my-node-sandbox:v1.0

# Minikube
minikube image load your-registry.io/my-node-sandbox:v1.0
```

### 2. Create the SandboxTemplate manifest

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: node-sandbox-template
  namespace: agent-sandbox   # must match the namespace where sandboxes will be created
spec:
  service: true
  podTemplate:
    spec:
      containers:
      - name: runtime
        image: your-registry.io/my-node-sandbox:v1.0
        imagePullPolicy: IfNotPresent   # or Always for frequent updates
        ports:
        - name: api
          containerPort: 8888
          protocol: TCP
        resources:
          requests: { cpu: "250m", memory: "256Mi" }
          limits:   { cpu: "1000m", memory: "1Gi" }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1000
          capabilities:
            drop: [ALL]
```

### 3. Apply it

```bash
kubectl apply -f node-sandbox-template.yaml
kubectl get sandboxtemplate -n agent-sandbox
```

### 4. Use it from the SDK

```python
sandbox = client.create_sandbox(
    template="node-sandbox-template",
    namespace="agent-sandbox",
)
```

---

## Using the SDK (`k8s-agent-sandbox`)

Install the **v0.5.0** SDK:

```bash
pip install k8s-agent-sandbox==0.5.0
```

> **Note**: v0.5.0 SDK is required for v0.5.0 agent-sandbox deployments due to API changes.

Official documentation: https://github.com/kubernetes-sigs/agent-sandbox/tree/main/clients/python/agentic-sandbox-client

### From outside the cluster (development / local testing)

Use **Tunnel Mode** — the SDK opens a `kubectl port-forward` automatically, or
you can port-forward manually and use **Direct Mode**.

**Option A — Tunnel Mode (auto port-forward):**

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxLocalTunnelConnectionConfig

client = SandboxClient(
    connection_config=SandboxLocalTunnelConnectionConfig(
        namespace="agent-sandbox"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox",
)
try:
    result = sandbox.commands.run("python3 --version")
    print(result.stdout)
finally:
    sandbox.terminate()
```

**Option B — Direct Mode (manual port-forward):**

```bash
# Terminal 1 — keep port-forward running
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080
```

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://localhost:8080"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox",
)
try:
    result = sandbox.commands.run("echo 'Hello from Agent Sandbox!'")
    print(result.stdout)    # Hello from Agent Sandbox!

    result = sandbox.commands.run("pip install requests && python3 -c 'import requests; print(requests.__version__)'")
    print(result.stdout)
finally:
    sandbox.terminate()
```

### From inside the cluster (agent pods)

Use **Direct Mode** with the sandbox-router's in-cluster DNS URL.
No RBAC changes are needed — the router handles all Kubernetes API calls.

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox",
)
try:
    result = sandbox.commands.run("python3 -c \"print('Hello from in-cluster sandbox!')\"")
    print(result.stdout)
finally:
    sandbox.terminate()
```

This is exactly how an agent using the sandbox executes code.

### Session sandbox pattern (stateful across calls)

For agents that need state to persist across multiple tool invocations
(installed packages, defined variables), create the sandbox once and reuse it:

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

_client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://sandbox-router-svc.agent-sandbox.svc.cluster.local:8080"
    )
)
_sandbox = None

def get_sandbox():
    global _sandbox
    if _sandbox is None or not _sandbox.is_active:
        _sandbox = _client.create_sandbox(
            template="python-sandbox-template",
            namespace="agent-sandbox",
        )
    return _sandbox

# First call — installs package
get_sandbox().commands.run("pip install pandas")

# Second call — package is still available
result = get_sandbox().commands.run("python3 -c 'import pandas; print(pandas.__version__)'")
print(result.stdout)

# Clean up
get_sandbox().terminate()
_sandbox = None
```

---

## WarmPools (pre-warmed sandboxes)

WarmPools keep a set of sandbox pods pre-created and idle so agents receive a
sandbox instantly without waiting for pod scheduling and image pull.

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxWarmPool
metadata:
  name: python-pool
  namespace: agent-sandbox
  labels:
    app: python-pool
spec:
  size: 3                          # number of pre-warmed pods to maintain
  templateRef:
    name: python-sandbox-template  # must exist in the same namespace
```

Apply:

```bash
kubectl apply -f warmpool.yaml
kubectl get sandboxwarmpool -n agent-sandbox
# NAME           SIZE   READY
# python-pool    5      5
```

When an agent calls `create_sandbox`, the controller assigns a pre-warmed pod
immediately and refills the pool in the background.

> WarmPool support is enabled by default via the official extensions manifest.

---

## Re-run Safety

| Operation | Behaviour |
|---|---|
| `deploy_agent_sandbox=on` on a running stack | Ansible playbook is idempotent; manifests are re-applied with `kubectl apply` (safe for upgrades) |
| Namespace already exists | Ansible creates namespace with `state: present` (idempotent) |
| Controller already running | Kubernetes applies manifests declaratively (no duplication) |
| Resume mode | If `agent-sandbox` namespace exists, `_auto_skip_deployed_components()` sets `deploy_agent_sandbox=off` for that run |

---

## Upgrading

### From v0.4.6 → v0.5.0 (Breaking Changes)

1. **Backup existing resources** (if upgrading existing deployment):
   ```bash
   kubectl get sandboxes,sandboxclaims,sandboxtemplates,sandboxwarmpools -A -o yaml > backup.yaml
   ```

2. **Update version** in `core/inventory/metadata/agentic-metadata.cfg`:
   ```ini
   agent_sandbox_version="v0.5.0"
   ```

3. **Re-run deployment**:
   ```bash
   ./deploy-agentic-stack.sh
   ```

4. **Update client SDK**:
   ```bash
   pip install --upgrade k8s-agent-sandbox==0.5.0
   ```

5. **Update code to use v1beta1 API** (if creating custom resources):
   ```yaml
   # Old (v0.4.6)
   apiVersion: extensions.agents.x-k8s.io/v1alpha1

   # New (v0.5.0)
   apiVersion: extensions.agents.x-k8s.io/v1beta1
   ```

> **Note**: v1alpha1 resources are automatically converted to v1beta1 via conversion webhook.
> Existing sandboxes continue to work without manual intervention.

### Future Version Upgrades

1. Update `agent_sandbox_version` in `core/inventory/metadata/agentic-metadata.cfg`
2. Re-run `./deploy-agentic-stack.sh`
3. Upgrade client SDK to matching version

The Ansible playbook handles all deployment updates automatically.

---

## Troubleshooting

### Pods not starting

```bash
# Check pod status
kubectl get pods -n agent-sandbox

# Check controller logs
kubectl logs -n agent-sandbox -l app.kubernetes.io/name=agent-sandbox

# Check router logs
kubectl logs -n agent-sandbox -l app=sandbox-router

# Describe failed pod
kubectl describe pod -n agent-sandbox <pod-name>
```

### Image pull errors

If using published images, ensure cluster has internet access:

```bash
# Test image pull
kubectl run test --rm -it --restart=Never --image=registry.k8s.io/agent-sandbox/python-runtime-sandbox:v0.5.0 -- echo "success"
```

For air-gapped environments, mirror images to your private registry and update variables in `core/inventory/metadata/vars/inference_agent_sandbox.yml`.

### SDK connection errors

```bash
# Verify router is running
kubectl get svc -n agent-sandbox sandbox-router-svc

# Test router health
kubectl port-forward -n agent-sandbox svc/sandbox-router-svc 8080:8080 &
curl http://localhost:8080/healthz

# Check NetworkPolicy
kubectl get networkpolicy -n agent-sandbox
```

---

## Configuration Files

### Variables

`core/inventory/metadata/vars/inference_agent_sandbox.yml`:
```yaml
agent_sandbox_namespace: "agent-sandbox"
sandbox_router_image: "us-central1-docker.pkg.dev/.../sandbox-router:latest-main"
python_runtime_sandbox_image: "registry.k8s.io/agent-sandbox/python-runtime-sandbox:v0.5.0"
```

### Deployment Script

- **Playbook**: `core/playbooks/deploy-agent-sandbox.yml` (Ansible)
- **Wrapper**: `core/lib/components/agent-sandbox-controller.sh` (calls Ansible)

### Templates

- **Default SandboxTemplate**: `core/helm-charts/agent-sandbox/default-templates.yaml`

---

## References

- [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) — upstream controller
- [v0.5.0 Release Notes](https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v0.5.0)
- [v0.5.0 Migration Guide](https://github.com/kubernetes-sigs/agent-sandbox/blob/v0.5.0/docs/api-migration-guide.md)
- [k8s-agent-sandbox Python SDK README](https://github.com/kubernetes-sigs/agent-sandbox/tree/main/clients/python/agentic-sandbox-client/README.md)
- [PyPI: k8s-agent-sandbox](https://pypi.org/project/k8s-agent-sandbox/)
- [Agent Sandbox Documentation](https://agent-sandbox.sigs.k8s.io/docs/)
