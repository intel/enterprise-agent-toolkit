# KubeRay

[← Docs index](../README.md)

KubeRay runs [Ray](https://www.ray.io/) inside the cluster: the KubeRay operator plus one Ray cluster with a head pod and autoscaled worker pods. Use it when an agent must distribute Python tasks, run actors, or scale workers on demand. It is off by default and not required for a first chat request.

Stack Manager installs two components when KubeRay is enabled:

1. **KubeRay operator**: a Kubernetes controller that manages `RayCluster` custom resources. Installed from the upstream `kuberay/kuberay-operator` Helm chart.
2. **RayCluster**: a head pod (coordinator) and worker pods (task executors), deployed from this repository's `charts/kuberay` chart and reconciled by the operator.

## How it works

```
                  ┌──────────────────────────────────────┐
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
                  │  worker pods (default-worker group)  │
                  └──────────────────────────────────────┘
```

- The head pod starts with `num-cpus=0`, so Ray schedules no user tasks on it. All work runs on workers.
- In-tree autoscaling is on. The Ray autoscaler adds or removes workers between `minReplicas` and `maxReplicas` based on pending tasks.
- Ray pods tolerate the control-plane taints, so they can run on control-plane nodes.

| Resource | Kind | Namespace |
|---|---|---|
| `kuberay-operator` | Helm release and Deployment | `ray-system` |
| `rayclusters.ray.io` | CRD (cluster-scoped, installed by the operator chart) | — |
| `ray-cluster` | Helm release and RayCluster | `ray-system` |
| `ray-cluster-head-svc` | Service (ClusterIP) | `ray-system` |
| Head pod | Pod (`ray.io/node-type=head`) | `ray-system` |
| Worker pods | Pods (`ray.io/node-type=worker`), autoscaled | `ray-system` |

## Settings

All keys are flat and live in `env/local/config.agent-toolkit.yaml`. The defaults come from `roles/kuberay/defaults/main.yaml`. Add only the keys you want to change.

| Field | Default | What it means |
|---|---|---|
| `kuberay_enabled` | `false` | Install KubeRay on the next `install`. |
| `kuberay_namespace` | `ray-system` | Namespace for the operator and the Ray cluster. The addresses on this page assume the default. |
| `kuberay_operator_version` | `1.3.0` | Version of the upstream `kuberay-operator` chart. |
| `kuberay_release_name` | `ray-cluster` | Helm release and RayCluster name. The head Service is `<name>-head-svc`. |
| `kuberay_ray_image` | `rayproject/ray:2.9.0-py310` | Image for head and workers. Clients must use the same Ray version and Python minor version. |
| `kuberay_worker_replicas` | `2` | Initial worker count. |
| `kuberay_worker_min_replicas` | `1` | Autoscaler floor. |
| `kuberay_worker_max_replicas` | `4` | Autoscaler ceiling. |
| `kuberay_worker_cpu_request` / `_limit` | `500m` / `2` | CPU per worker. |
| `kuberay_worker_memory_request` / `_limit` | `2Gi` / `4Gi` | Memory per worker. |

Example with the defaults written out:

```yaml
# env/local/config.agent-toolkit.yaml
kuberay_enabled: true
kuberay_ray_image: rayproject/ray:2.9.0-py310
kuberay_worker_replicas: 2
kuberay_worker_min_replicas: 1
kuberay_worker_max_replicas: 4
kuberay_worker_cpu_request: "500m"
kuberay_worker_cpu_limit: "2"
kuberay_worker_memory_request: "2Gi"
kuberay_worker_memory_limit: "4Gi"
```

Worker sizing profiles:

| Profile | CPU request | CPU limit | Memory request | Memory limit |
|---|---|---|---|---|
| Light (development, one node) | `500m` | `2` | `1Gi` | `2Gi` |
| Medium (default) | `500m` | `2` | `2Gi` | `4Gi` |
| Heavy (multi-node, batch) | `2` | `8` | `8Gi` | `16Gi` |

Limitations of the current role:

- **Head pod:** uses the chart defaults (CPU `500m` / `1`, memory `2Gi` / `4Gi`). The role defines `kuberay_head_*` keys but does not pass them to the chart, so setting them has no effect.
- **`rayVersion`:** the RayCluster's `rayVersion` comes from the chart's `appVersion` (`2.9.0`). Changing `kuberay_ray_image` does not change it.
- **Re-runs:** settings apply only when KubeRay is first installed. If the `kuberay-operator` Helm release exists, `install` skips all of KubeRay, including the RayCluster. To apply changed settings, [remove KubeRay](#6-remove-kuberay) and install again.

## 1. Enable KubeRay

Set the flag, plus any settings from the table, before the first `install` that enables KubeRay:

```yaml
# env/local/config.agent-toolkit.yaml
kuberay_enabled: true
```

From the Stack Manager directory:

```bash
./stack-manager install agent-toolkit
```

For KubeRay, the installer:

1. Creates the `ray-system` namespace.
2. Adds the `kuberay` Helm repository and installs the operator.
3. Deploys the RayCluster from `charts/kuberay`.
4. Waits until the head pod is `Running`.

If the install stops, rerun the same command to resume.

## 2. Verify

```bash
# Operator, head, and worker pods should be Running
kubectl get pods -n ray-system

# RayCluster status
kubectl get raycluster -n ray-system

# Cluster status from inside the head pod
kubectl exec -n ray-system -it \
  $(kubectl get pod -n ray-system -l ray.io/node-type=head -o name) -- ray status

# Ray Dashboard at http://localhost:8265
kubectl port-forward svc/ray-cluster-head-svc 8265:8265 -n ray-system
```

Expect one `kuberay-operator` pod, one head pod, and `kuberay_worker_replicas` worker pods (2 by default).

In-cluster addresses, valid from any pod:

| Endpoint | Address |
|---|---|
| Ray Client API | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` |
| Ray Dashboard | `http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265` |
| GCS (internal) | `ray-cluster-head-svc.ray-system.svc.cluster.local:6379` |

From outside the cluster, use `kubectl port-forward`.

## 3. Connect a Python client

Install the Ray version that matches the cluster image (`2.9.0` by default), on the same Python minor version (`py310` means Python 3.10). A mismatch causes connection errors.

```bash
pip install "ray[default]==2.9.0"
```

From a pod in the cluster:

```python
import ray

ray.init("ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001")

@ray.remote
def hello():
    return "Hello from Ray worker!"

print(ray.get(hello.remote()))  # Hello from Ray worker!
```

From outside the cluster, forward the client port first, then connect to `localhost`:

```bash
kubectl port-forward svc/ray-cluster-head-svc 10001:10001 -n ray-system &
```

```python
import ray
ray.init("ray://localhost:10001")
```

## 4. Scale workers

### Change the live cluster

The autoscaler manages the worker count, so set its bounds rather than the replica count. This example keeps between 5 and 8 workers:

```bash
kubectl patch raycluster ray-cluster -n ray-system --type json -p '[
  {"op":"replace","path":"/spec/workerGroupSpecs/0/maxReplicas","value":8},
  {"op":"replace","path":"/spec/workerGroupSpecs/0/minReplicas","value":5}
]'
```

`kubectl scale` does not work on a RayCluster. The change lasts until the RayCluster is redeployed.

### Change the configuration

To keep a new size across reinstalls, set it in `env/local/config.agent-toolkit.yaml`:

```yaml
kuberay_worker_replicas: 5
kuberay_worker_max_replicas: 8
```

Re-running `install` skips KubeRay once it is installed. To apply the values, [remove KubeRay](#6-remove-kuberay), then run `./stack-manager install agent-toolkit`.

## 5. Upgrade Ray

1. Choose a tag from [Ray on Docker Hub](https://hub.docker.com/r/rayproject/ray/tags).
2. Set it in `env/local/config.agent-toolkit.yaml`:

   ```yaml
   kuberay_ray_image: rayproject/ray:2.41.0-py312
   ```

3. If the new Ray version needs a newer operator, set `kuberay_operator_version` as well.
4. [Remove KubeRay](#6-remove-kuberay), then run `./stack-manager install agent-toolkit`. The installer does not upgrade existing Helm releases in place.
5. Update clients to the same version, for example `pip install "ray[default]==2.41.0"` on Python 3.12.

## 6. Remove KubeRay

```bash
helm uninstall ray-cluster -n ray-system        # RayCluster
helm uninstall kuberay-operator -n ray-system   # operator
kubectl delete namespace ray-system             # remaining resources
```

Helm does not delete CRDs, so `rayclusters.ray.io` and the other `ray.io` CRDs stay in the cluster. They are reused on the next install.

To keep later installs from adding KubeRay again, set `kuberay_enabled: false`.

## Next steps

- [Configuration](../configuration/configuration.md#configagent-toolkityaml): `kuberay_enabled` and the other toolkit flags
- [Backend connection reference](backend-connections.md#kuberay-optional): in-cluster URLs
- [Single-node quickstart](../getting-started/quickstart.md): leave KubeRay off for the first request
- [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md)
