# Agent sandbox

[← Docs index](../README.md)

Agent-generated code must not run on the host or inside the model-serving pod. **Agent sandbox** runs it in a short-lived Kubernetes pod with its own filesystem, process tree, and network. The agent calls a router service, and the router creates the pod. Use this page to configure the sandbox, check it, add runtimes, and call it from the Python SDK. The implementation is [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox).

The sandbox is installed with `install agent-toolkit` and is on by default. For the in-cluster URL only, see the [backend connection reference](backend-connections.md#agent-sandbox).

## How it works

```
Agent (e.g. Coding Agent)
        │  HTTP (in-cluster DNS)
        ▼
sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080
        │  creates a SandboxClaim through the Kubernetes API
        ▼
agent-sandbox-controller
        │  starts a pod from the SandboxTemplate
        ▼
sandbox-claim-<id>   (NetworkPolicy: ingress only from app=sandbox-router, same namespace)
        │
        ▼
python-runtime-sandbox: uvicorn on :8888
        POST /execute {"command": "..."} → {stdout, stderr, exit_code}
```

- Every component runs in the **`agent-sandbox-system`** namespace. The controller generates a NetworkPolicy that admits traffic only from `app=sandbox-router` pods in the same namespace, so templates and sandboxes must live there too.
- The router is the only component that calls the Kubernetes API. Client pods, such as the Coding Agent, need no RBAC of their own.
- All images come from published registries. No local build is required.

| Component | Kind | Namespace | Image or detail |
|---|---|---|---|
| `agent-sandbox-controller` | Deployment | `agent-sandbox-system` | `registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0` |
| CRDs | Cluster-scoped | | `sandboxes`, `sandboxtemplates`, `sandboxclaims`, `sandboxwarmpools` (v1beta1) |
| `sandbox-router-deployment` | Deployment (×2) | `agent-sandbox-system` | `us-central1-docker.pkg.dev/k8s-staging-images/agent-sandbox/sandbox-router:latest-main` (staging) |
| `sandbox-router-svc` | Service | `agent-sandbox-system` | ClusterIP :8080 |
| `sandbox-router-auth` | Secret | `agent-sandbox-system` | `ROUTER_AUTH_TOKEN`, generated at install and injected into the router |
| `python-sandbox-template` | SandboxTemplate | `agent-sandbox-system` | `registry.k8s.io/agent-sandbox/python-runtime-sandbox:v0.5.0` |
| `python-pool` | SandboxWarmPool | `agent-sandbox-system` | 5 pre-warmed pods from `python-sandbox-template` |

## 1. Configure

After `./stack-manager init agent-toolkit`, set these in `env/local/config.agent-toolkit.yaml`. The defaults need no change.

| Field | Default | What it means |
|---|---|---|
| `agent_sandbox_enabled` | `true` | Set `false` to skip the sandbox. |
| `agent_sandbox_namespace` | `agent-sandbox-system` | Namespace for every sandbox component. |
| `agent_sandbox_version` | `v0.5.0` | Upstream release. Selects the manifests fetched from GitHub and the runtime image tag. |
| `agent_sandbox_router_image` | `…/sandbox-router:latest-main` | Router image. Override to mirror it for air-gapped clusters. |
| `agent_sandbox_python_runtime_image` | `registry.k8s.io/agent-sandbox/python-runtime-sandbox:<version>` | Image for the default template. Override to mirror it. |
| `agent_sandbox_python_warm_pool_name` | `python-pool` | Name of the default warm pool. |
| `agent_sandbox_python_warm_pool_size` | `5` | Pre-warmed pods. `0` creates no warm pool. |

Cluster-wide settings that also apply (`auth_provider`, `base_domain_name`, `gateway_tls_mode`) are in `env/local/global_config.yaml`. See [Configuration](../configuration/configuration.md).

## 2. Install

```bash
./stack-manager configure              # one-time
./stack-manager init agent-toolkit     # writes env/local/
./stack-manager install agent-toolkit  # installs the sandbox with the layer
```

The installer:

1. Skips the sandbox if the `agent-sandbox-controller` Deployment already exists.
2. Creates the namespace and applies the upstream core manifest (CRDs and controller) and extensions manifest (template, claim, and warm-pool CRDs).
3. Waits for the controller, creates the `sandbox-router-auth` secret, and deploys the router.
4. Applies `python-sandbox-template` and creates the `python-pool` warm pool.

Re-run `install` to resume a failed run. Because of step 1, a re-run does not change a sandbox that is already installed.

> The default `--env` is `local`; pass a different `--env <name>` to target
> another environment. `teardown` and `validate <target>` verbs are also
> available.

## 3. Verify

```bash
kubectl get pods -n agent-sandbox-system                                    # all Running
kubectl get deployment -n agent-sandbox-system agent-sandbox-controller sandbox-router-deployment

kubectl get crd sandboxes.agents.x-k8s.io -o jsonpath='{.spec.versions[*].name}'
# Expected: v1alpha1 v1beta1

kubectl get sandboxtemplate -n agent-sandbox-system                         # python-sandbox-template
kubectl get sandboxwarmpool -n agent-sandbox-system python-pool             # 5 ready

kubectl port-forward -n agent-sandbox-system svc/sandbox-router-svc 8080:8080 &
curl -s http://localhost:8080/healthz
# {"status":"ok"}
```

## 4. Run code from the SDK

Install the SDK version that matches the deployment. v0.5.0 deployments require the v0.5.0 SDK because of API changes.

```bash
pip install k8s-agent-sandbox==0.5.0
```

SDK documentation: [agentic-sandbox-client](https://github.com/kubernetes-sigs/agent-sandbox/tree/main/clients/python/agentic-sandbox-client).

| Where the client runs | Connection |
|---|---|
| Agent pod in the cluster | Direct mode, `http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080`. No RBAC changes needed. |
| Workstation, automatic port-forward | Tunnel mode (`SandboxLocalTunnelConnectionConfig`) |
| Workstation, manual port-forward | Direct mode, `http://localhost:8080` |

**In the cluster (agent pods).** This is how an agent runs code:

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxDirectConnectionConfig

client = SandboxClient(
    connection_config=SandboxDirectConnectionConfig(
        api_url="http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox-system",
)
try:
    result = sandbox.commands.run("python3 -c \"print('Hello from in-cluster sandbox!')\"")
    print(result.stdout)
finally:
    sandbox.terminate()
```

**From a workstation, tunnel mode.** The SDK opens the `kubectl port-forward` itself:

```python
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxLocalTunnelConnectionConfig

client = SandboxClient(
    connection_config=SandboxLocalTunnelConnectionConfig(
        namespace="agent-sandbox-system"
    )
)

sandbox = client.create_sandbox(
    template="python-sandbox-template",
    namespace="agent-sandbox-system",
)
try:
    result = sandbox.commands.run("python3 --version")
    print(result.stdout)
finally:
    sandbox.terminate()
```

**From a workstation, direct mode.** Keep a port-forward running in another terminal:

```bash
kubectl port-forward -n agent-sandbox-system svc/sandbox-router-svc 8080:8080
```

Then use the in-cluster example with `api_url="http://localhost:8080"`.

**Session sandbox (state across calls).** To keep installed packages and files between tool calls, create the sandbox once and reuse it:

```python
_sandbox = None

def get_sandbox():
    global _sandbox
    if _sandbox is None or not _sandbox.is_active:
        _sandbox = client.create_sandbox(
            template="python-sandbox-template",
            namespace="agent-sandbox-system",
        )
    return _sandbox

get_sandbox().commands.run("pip install pandas")
result = get_sandbox().commands.run("python3 -c 'import pandas; print(pandas.__version__)'")
print(result.stdout)

get_sandbox().terminate()
_sandbox = None
```

## 5. Add a runtime template

Add one `SandboxTemplate` per runtime (Node.js, R, Java, and so on).

1. Build and push an image that serves the same API as `python-runtime-sandbox` on port 8888: `POST /execute` with `{"command": "<shell command>"}`, returning `{"stdout": "...", "stderr": "...", "exit_code": 0}`.

   ```bash
   docker build -t your-registry.io/my-node-sandbox:v1.0 ./path/to/dockerfile-dir
   docker push your-registry.io/my-node-sandbox:v1.0
   ```

   For local development without a registry, load the image instead: `kind load docker-image <image>` (Kind) or `minikube image load <image>` (Minikube).

2. Create the template in `agent-sandbox-system`, the namespace where sandboxes are created. This is the default template with a different name and image:

   ```yaml
   apiVersion: extensions.agents.x-k8s.io/v1beta1
   kind: SandboxTemplate
   metadata:
     name: node-sandbox-template
     namespace: agent-sandbox-system
   spec:
     service: true          # headless Service per pod: required for SDK DNS mode
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

3. Apply it and use it:

   ```bash
   kubectl apply -f node-sandbox-template.yaml
   kubectl get sandboxtemplate -n agent-sandbox-system
   ```

   ```python
   sandbox = client.create_sandbox(template="node-sandbox-template", namespace="agent-sandbox-system")
   ```

## 6. Add a warm pool

A warm pool keeps idle sandbox pods ready, so `create_sandbox` returns without waiting for scheduling or an image pull. The controller hands out a warm pod and refills the pool in the background. The installer creates `python-pool`; to size it, use `agent_sandbox_python_warm_pool_size` before install. For another template, apply a pool in the same namespace as the template:

```yaml
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxWarmPool
metadata:
  name: node-pool
  namespace: agent-sandbox-system
  labels:
    app: node-pool
spec:
  replicas: 3                          # pre-warmed pods to keep
  sandboxTemplateRef:
    name: node-sandbox-template        # must exist in the same namespace
```

```bash
kubectl apply -f warmpool.yaml
kubectl get sandboxwarmpool -n agent-sandbox-system
```

## Upgrading

The version is pinned by `agent_sandbox_version`. A re-run skips the sandbox while the controller exists, so a new version only takes effect on a fresh install: [tear the stack down](../deployment/decommission.md) and install again.

From v0.4.6 to v0.5.0 (breaking changes):

1. Back up existing resources:

   ```bash
   kubectl get sandboxes,sandboxclaims,sandboxtemplates,sandboxwarmpools -A -o yaml > backup.yaml
   ```

2. Install v0.5.0 as above.
3. Upgrade the SDK: `pip install --upgrade k8s-agent-sandbox==0.5.0`.
4. Change custom resources from `apiVersion: extensions.agents.x-k8s.io/v1alpha1` to `extensions.agents.x-k8s.io/v1beta1`. A conversion webhook converts existing v1alpha1 resources, so running sandboxes keep working.

For later versions, install the new version and upgrade the SDK to match.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pods not starting | `kubectl get pods -n agent-sandbox-system`, then `kubectl describe pod -n agent-sandbox-system <pod-name>` |
| Controller errors | `kubectl logs -n agent-sandbox-system -l app.kubernetes.io/name=agent-sandbox` |
| Router errors | `kubectl logs -n agent-sandbox-system -l app=sandbox-router` |
| Image pull errors | Test registry access: `kubectl run test --rm -it --restart=Never --image=registry.k8s.io/agent-sandbox/python-runtime-sandbox:v0.5.0 -- echo "success"`. For air-gapped clusters, mirror the images and set `agent_sandbox_router_image` and `agent_sandbox_python_runtime_image`. |
| SDK cannot connect | `kubectl get svc -n agent-sandbox-system sandbox-router-svc`, the `/healthz` check in [Verify](#3-verify), and `kubectl get networkpolicy -n agent-sandbox-system` |

## Next steps

- [Backend connection reference](backend-connections.md#agent-sandbox): in-cluster URL
- [Configuration](../configuration/configuration.md) and [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md)
- [Meet the Agent Toolkit](../overview/meet.md#toolkit-components)
- Upstream: [agent-sandbox docs](https://agent-sandbox.sigs.k8s.io/docs/), [v0.5.0 release notes](https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v0.5.0), [v0.5.0 migration guide](https://github.com/kubernetes-sigs/agent-sandbox/blob/v0.5.0/docs/api-migration-guide.md), [SDK README](https://github.com/kubernetes-sigs/agent-sandbox/tree/main/clients/python/agentic-sandbox-client/README.md), [PyPI: k8s-agent-sandbox](https://pypi.org/project/k8s-agent-sandbox/)
