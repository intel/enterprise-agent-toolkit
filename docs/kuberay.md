# KubeRay — Distributed Computing for Agentic Workloads

**KubeRay** brings [Ray](https://www.ray.io/) — the Python-native distributed computing framework — into the Agentic AI Stack as a first-class component. It enables agent workloads to fan out tasks across multiple CPU cores in parallel, run stateful actors, and use Ray's built-in autoscaler to match resource consumption to demand.

The implementation deploys two components into the cluster:

1. **KubeRay Operator** — a Kubernetes controller that manages `RayCluster` custom resources.
2. **RayCluster** — a head pod (scheduler/coordinator) and one or more worker pods (task executors) managed by the operator.

---

## Architecture

```
                  ┌─────────────────────────────────────┐
                  │          ray-system namespace        │
                  │                                      │
  Agent / client  │  kuberay-operator                    │
  ─────────────►  │    watches RayCluster CR             │
  ray://...       │         │                            │
                  │         ▼                            │
                  │  ray-cluster-head-svc  (:10001)      │
                  │         │                            │
                  │         │ schedules tasks            │
                  │         ▼                            │
                  │  ray-cluster-worker-pod-0            │
                  │  ray-cluster-worker-pod-1  ...       │
                  └─────────────────────────────────────┘

  Ray Dashboard   : http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265
  Ray Client API  : ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001
```

**Key design points:**

- The head pod runs with `num-cpus=0` so no user tasks are scheduled on it — all workloads run on workers.
- The Ray autoscaler reads `minReplicas` / `maxReplicas` from the cluster spec and adds or removes worker pods automatically based on pending task load.
- Worker count and resource limits are controlled entirely via **`env/<name>/config.agent-toolkit.yaml`**. The operator version is pinned in `env/<name>/config.agent-toolkit.yaml`.

---

## Deployed Components

| Component | Kind | Namespace |
|---|---|---|
| `kuberay-operator` | Deployment | `ray-system` |
| RayCluster CRD | ClusterScoped | — |
| `ray-cluster` | RayCluster CR | `ray-system` |
| `ray-cluster-head-svc` | Service (ClusterIP) | `ray-system` |
| Ray head pod | Pod | `ray-system` |
| Ray worker pods | Pods (autoscaled) | `ray-system` |

---

## Configuration

KubeRay uses **two separate groups of settings** to keep concerns clearly separated:

| File | What to set |
|---|---|
| `env/<name>/config.agent-toolkit.yaml` | `kuberay_enabled: true` / `kuberay_enabled: false` — the deployment toggle |
| `env/<name>/config.agent-toolkit.yaml` | All tuning: namespace, Ray image, worker replicas, CPU/memory limits |

### Enable deployment — `config.agent-toolkit.yaml`

```yaml
kuberay_enabled: true
```

Set to `false` to skip KubeRay during the next run. If the `ray-system` namespace
already exists from a previous run, deployment is automatically skipped (resume mode).

> **Note:** resume mode is not available in this release.

### Tune the cluster — `config.agent-toolkit.yaml`

```yaml
# Kubernetes namespace for all Ray resources
kuberay_namespace: "ray-system"

kuberay_release_name: "ray-cluster"

# Ray image — must match the ray[default] version used by connecting clients
kuberay_ray_image: "rayproject/ray:2.40.0-py312"

kuberay_head_cpu_request: "500m"
kuberay_head_cpu_limit: "2"
kuberay_head_memory_request: "2Gi"
kuberay_head_memory_limit: "4Gi"

kuberay_worker_replicas: 2        # initial worker count
kuberay_worker_min_replicas: 1    # autoscaler floor
kuberay_worker_max_replicas: 4    # autoscaler ceiling
kuberay_worker_cpu_request: "500m"
kuberay_worker_cpu_limit: "2"
kuberay_worker_memory_request: "2Gi"
kuberay_worker_memory_limit: "4Gi"
```

This file is created automatically with safe defaults on the first run of
`./es_auto_installer.sh init agent-toolkit`. Edit it before re-running to apply custom values.

#### Worker resource sizing guide

| Profile | `kuberay_worker_cpu_request` | `kuberay_worker_cpu_limit` | `kuberay_worker_memory_request` | `kuberay_worker_memory_limit` |
|---|---|---|---|---|
| Light (dev / single node) | `500m` | `2` | `1Gi` | `2Gi` |
| Medium *(default)* | `500m` | `2` | `2Gi` | `4Gi` |
| Heavy (multi-node / batch) | `2` | `8` | `8Gi` | `16Gi` |

### Operator version pin — `config.agent-toolkit.yaml`

```yaml
kuberay_operator_version: "1.3.0"
```

Update this value to upgrade the KubeRay operator. The Ray image in
`config.agent-toolkit.yaml` should be updated to match the corresponding Ray version.

---

## Deployment

```bash
# 1. Set the toggle in env/<name>/config.agent-toolkit.yaml
#    kuberay_enabled: true

# 2. (Optional) edit env/<name>/config.agent-toolkit.yaml to tune resources

# 3. Run the deploy script
./es_auto_installer.sh install agent-toolkit
```

The deploy script runs 4 steps for KubeRay:

| Step | Action |
|---|---|
| 1 | Create the `ray-system` namespace (idempotent) |
| 2 | Add the KubeRay Helm repo and install the operator |
| 3 | Deploy the RayCluster CR via the bundled `core/helm-charts/kuberay` chart |
| 4 | Poll until the head pod is Running and Ready |

---

## Verify the Deployment

```bash
# All pods should be Running
kubectl get pods -n ray-system

# Expected output:
# NAME                                READY   STATUS    RESTARTS
# kuberay-operator-xxx                1/1     Running   0
# ray-cluster-head-xxx                1/1     Running   0
# ray-cluster-worker-small-xxx        1/1     Running   0
# ray-cluster-worker-small-xxx        1/1     Running   0

# Check the RayCluster CR status
kubectl get raycluster -n ray-system

# View the Ray Dashboard: https://ray.<base_domain_name>/ (basic auth user ray, password below)
kubectl get secret ray-dashboard-auth -n ray-system -o jsonpath='{.data.password}' | base64 -d

# Or port-forward from your local machine
kubectl port-forward svc/ray-cluster-head-svc 8265:8265 -n ray-system
# Then open: http://localhost:8265
```

---

## In-Cluster Access Points

| Endpoint | Address |
|---|---|
| **Ray Client API** | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` |
| **Ray Dashboard** | `http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265` |
| **GCS (internal)** | `ray-cluster-head-svc.ray-system.svc.cluster.local:6379` |

These addresses are valid from any pod running in the cluster whose namespace is labelled
`istio.io/dataplane-mode=ambient`. From outside the cluster, open the Dashboard at
`https://ray.<base_domain_name>/` (user `ray`, password in Secret `ray-dashboard-auth`), or use
`kubectl port-forward` to reach the Dashboard or Client API.

---

## Connecting a Python Client

Install Ray on the client side with the same version as the cluster image:

```bash
pip install "ray[default]==2.40.0"
```

Connect from within the cluster (e.g. from the Coding Agent pod):

```python
import ray

ray.init("ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001")

@ray.remote
def hello():
    return "Hello from Ray worker!"

result = ray.get(hello.remote())
print(result)  # Hello from Ray worker!
```

Connect from outside the cluster via port-forward:

```bash
kubectl port-forward svc/ray-cluster-head-svc 10001:10001 -n ray-system &
```

```python
import ray
ray.init("ray://localhost:10001")
```

---

## Scaling Workers

### Manual scale

```bash
# Scale to 5 workers immediately
kubectl scale raycluster ray-cluster -n ray-system --replicas=5
```

### Via config (persistent)

Edit `env/<name>/config.agent-toolkit.yaml`:

```yaml
kuberay_worker_replicas: 5
kuberay_worker_max_replicas: 8
```

Then re-run:

```bash
./es_auto_installer.sh install agent-toolkit
```

---

## Upgrading Ray

1. Choose a target version from the [Ray Docker Hub tags](https://hub.docker.com/r/rayproject/ray/tags).
2. Update `config.agent-toolkit.yaml`:
   ```yaml
   kuberay_ray_image: "rayproject/ray:2.41.0-py312"
   ```
3. Update the operator version (`kuberay_operator_version`) in `config.agent-toolkit.yaml` if required.
4. Re-run `./es_auto_installer.sh install agent-toolkit` — the script upgrades the Helm releases in place.
5. Update `pip install "ray[default]==2.41.0"` in any client code.

> **Note:** The Ray client version must match the cluster image version exactly.
> Mismatches cause connection errors.

---

## Removing KubeRay

```bash
# Uninstall the RayCluster
helm uninstall ray-cluster -n ray-system

# Uninstall the operator
helm uninstall kuberay-operator -n ray-system

# Delete the namespace (removes all remaining resources)
kubectl delete namespace ray-system
```

Set `kuberay_enabled: false` in `config.agent-toolkit.yaml` so subsequent deploy runs skip it.
