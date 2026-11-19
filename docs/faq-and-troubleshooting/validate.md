# Validate the stack

[← Docs index](../README.md)

Two checks cover a Toolkit Manager install. **Preflight** looks at every host before components are installed. **Validate** checks the components that the install actually enabled.

Run both from the Toolkit Manager checkout, after `./toolkit_manager.sh init agent-toolkit`.

| Check | When | Command | Output |
|---|---|---|---|
| Preflight | At the start of `./toolkit_manager.sh install`. You can also run it on its own | `ext/enterprise.agent-toolkit/playbooks/preflight-check.yml` | `env/local/logs/health-report-latest.json`, `.html`, and `.txt`. The `.txt` summary is also printed |
| Validate | After the install | `./toolkit_manager.sh validate <layer>` | Per-component checks in the run output. A failure stops the run and prints the reason |

Components that are not enabled are skipped. They are not reported as failures.

## Preflight

Preflight checks node readiness on every host in the inventory. No result stops the install. The only change it makes is the Kubelet DNS setting. See [Preflight fails on the Kubelet DNS file](#preflight-fails-on-the-kubelet-dns-file).

| Status | Checks | Meaning |
|---|---|---|
| **FAIL** | Time sync, Kubelet DNS file, unfinished Kubernetes install, node connection, swap in use, root and containerd disk under 10% free, external DNS, gateway reachable | Fix these. They are also listed in the `PREFLIGHT WARNING` block |
| **WARN** | CPU governor is not `performance`, THP is `always`, Hugging Face token is invalid | Tuning or model access. The install continues |
| **PENDING** | Node resource pressure before the cluster exists. Hugging Face token is not set | Checked on a later run: after the install, or with `HF_TOKEN` exported |
| **OK** | Kernel and OS version, kubelet version (`not installed` before the cluster exists), NUMA topology | Recorded in the report |

On a node whose CPU governor is `powersave`:

```text
  Network connectivity                  [ OK ]  (reachable via ICMP ping <gateway>)
  Platform health                       [ WARN ] governor=powersave freq=3343MHz max=3900MHz
  WARNING: [platform-health] CPU governor on node1
          Hint: Set performance: cpupower frequency-set -g performance
  RESULT: 2 layers — 1 PASSED, 1 WARNING
```

### Runs with the install

In an environment created with `init agent-toolkit`, `./toolkit_manager.sh install` runs the preflight first: on a new cluster before Kubespray, otherwise before the components. Runs with `--only` skip it. To turn it off, set `node_preflight_enabled: false` in `env/local/config.agent-toolkit.yaml`. The checks are capped at 5 minutes. Past that, the install continues. The run output is saved to `env/local/logs/preflight-check.log`.

### Run it on its own

From the Toolkit Manager checkout, after `init agent-toolkit`. For several nodes, list them in `env/local/inventory/hosts.yaml` first. See [Multi-node deployment](../deployment/multi-node.md#1-seed-config-then-list-every-node).

```bash
export HF_TOKEN=<token>   # optional: also checks the token for gated models
.venv/bin/ansible-playbook -i env/local/inventory/hosts.yaml \
  ext/enterprise.agent-toolkit/playbooks/preflight-check.yml
```

The report is `env/local/logs/health-report-latest.json` and `.html`. A summary is printed at the end of the run.

## Validate

`validate` runs the checks of every enabled component in the target and its dependencies. `--only` limits the run to that target. A healthy stack ends with `failed=0` in the recap.

```bash
./toolkit_manager.sh validate agent-toolkit
```

One layer or component:

```bash
./toolkit_manager.sh validate platform --only
./toolkit_manager.sh validate inference --only
./toolkit_manager.sh validate litellm --only
```

## What validate checks

| Layer | Component | Checks |
|---|---|---|
| Infrastructure | kubernetes | kubectl and kubeconfig, API server reachable, node readiness, server version |
| | storage (NFS, Ceph, Trident) | CSI driver and node plugin, StorageClass, exactly one default class. Ceph health and OSDs |
| | kata_containers | kata-deploy rollout, requested RuntimeClasses |
| Platform | cert-manager, MetalLB, Envoy Gateway | Releases, controllers ready, IP pool, GatewayClass and Gateway accepted, TLS secret |
| | Istio | istiod, ztunnel on every node, mesh-wide mTLS |
| | PostgreSQL, SeaweedFS | Database cluster ready, S3 gateway ready |
| | observability | Prometheus Operator, Grafana, Node Exporter, Loki, Tempo, OTel Collector |
| | NRI balloons, NFD | Policy and DaemonSet ready, CPU feature labels on nodes |
| | Keycloak (when enabled) | Operator and instances ready |
| Inference | KServe, model services | CRDs and controllers, serving runtimes, deployed models, CPU policy |
| | LiteLLM | Deployment ready, readiness endpoint, master key. A request through the content-safety guardrail and a chat request through LiteLLM |
| | Langfuse, vLLM Semantic Router | Web and worker deployments. Router and dashboard routed |
| Agent toolkit | Redis Stack, pgvector | Pods, Redis PING and RediSearch, pgvector extension and credentials |
| | Agent sandbox | Controller, router, CRDs, templates, warm pools, and the Kata template |
| | OpenShell, KubeRay | Gateway ready. Operator and head pod |

Burn tests, the proxy checks, and a post-deploy report file are not in this release. Node-level checks (time sync, disk, swap, CPU governor, THP, DNS, gateway) are in [Preflight](#preflight).

## Troubleshooting

### Preflight fails on NTP sync

`chronyd` or `systemd-timesyncd` needs to be running and synchronized on every node:

```bash
.venv/bin/ansible -i env/local/inventory/hosts.yaml all -b -m shell -a "timedatectl status | grep synchronized"
```

### Preflight fails on the Kubelet DNS file

On Ubuntu and Fedora, Kubespray points kubelet at `/run/systemd/resolve/resolv.conf`, which exists while `systemd-resolved` runs. Without it, Kubernetes does not start. When no node runs `systemd-resolved`, the preflight writes `kube_resolv_conf: "/etc/resolv.conf"` and `resolvconf_mode: "none"` to `env/local/kubespray_extra.yml` (reported as **Kubelet DNS setting**) and the install continues. It reports FAIL when some nodes run `systemd-resolved` and others do not. Make the nodes the same, then install again. With the preflight off (`node_preflight_enabled: false`), write those two lines yourself on such hosts.

### Preflight fails on an unfinished Kubernetes install

An install that stopped during `kubeadm` leaves `/var/lib/kubelet/config.yaml` on the node. A plain re-run then skips `kubeadm init` and fails later (`secrets is forbidden` on `kubeadm token create`). Reset the nodes, then install again:

```bash
./toolkit_manager.sh teardown kubernetes
./toolkit_manager.sh install agent-toolkit
```

### Preflight fails on a node connection

The playbook runs on the installer machine and runs some steps on each node (Kata setup, CPU pinning). A node with no `ansible_connection` gets those steps on the installer machine, so they configure the wrong host. In `env/local/inventory/hosts.yaml`, set `ansible_connection: ssh` on every node reached over SSH, and `ansible_connection: local` on the machine running the installer. Then install again.

### A model is still loading

Large models can take 5–15 minutes to load. Re-run validation once they are Ready:

```bash
kubectl get llminferenceservices,inferenceservices -n llm-inference
./toolkit_manager.sh validate inference
```

## Next steps

- [Single-node quickstart](../getting-started/quickstart.md): the install these checks follow
- [Troubleshooting](troubleshooting.md): installer, API, Redis, and model-pod failures
- [Decommission](../deployment/decommission.md): tear down after a failed Kubernetes install
