# Rack-scale AI fabric

[← Docs index](../README.md)

> [!WARNING]
> **Not installed by Stack Manager yet.** The team needs to review this page before anyone follows it.
>
> Commands, paths, and flags below still describe the **standalone** stack (`deploy-agentic-stack.sh`, `core/inventory/agentic-config.cfg`, `rack_scale_mode=on`). They will **not** run if you only cloned Stack Manager and used `stack-manager init agent-toolkit`.
>
> Until this path is wired into `stack-manager`, use [multi-node deployment](multi-node.md) on a normal Ethernet cluster.

Use this guide when the rack has a **high-speed AI fabric** (100G, 200G, 400G, or 800G), dual-homed NICs (Intel® E810-C or compatible), and NVMe Ceph. A single `rack-profile.yaml` is meant to generate Kubernetes and Ceph config so you do not hand-edit `hosts.yaml` or `ceph-storage.yml`.

> **Speed-agnostic design:** The deployment stack (Kubespray, Calico BGP, Rook/Ceph, and the
> rack-profile parser) does not depend on link speed. Migrating from 100G to 400G or 800G
> requires only updating NIC names and fabric IPs in `rack-profile.yaml` and adjusting the
> `mtu` field to match your switch configuration. No code changes are needed.
>
> **Validated on:** Intel® Lab201: Arista Clos fabric, Intel® E810-C NICs, 100G uplinks.

In rack-scale mode, a single declarative file (`rack-profile.yaml`) describes
your entire hardware topology. The parser generates all derived Kubernetes and
Ceph config from it automatically. You do not hand-edit `hosts.yaml` or
`ceph-storage.yml`.

---

## Table of Contents

- [When to Use This Guide](#when-to-use-this-guide)
- [Architecture Overview](#architecture-overview)
- [Hardware Reference: Intel Lab201](#hardware-reference-intel-lab201)
- [How It Works](#how-it-works)
- [Fabric Topologies: Clos and Star](#fabric-topologies-clos-and-star)
- [Step 1: Prerequisites](#step-1-prerequisites)
- [Step 2: Edit rack-profile.yaml](#step-2-edit-rack-profileyaml)
- [Step 3: Run the Parser](#step-3-run-the-parser)
- [Step 4: Configure agentic-config.cfg](#step-4-configure-agentic-configcfg)
- [Step 5: Deploy](#step-5-deploy)
- [Step 6: Verify Fabric Networking](#step-6-verify-fabric-networking)
- [Step 7: Verify Ceph on Fabric](#step-7-verify-ceph-on-fabric)
- [rack-profile.yaml Reference](#rack-profileyaml-reference)
- [Network Design Decisions](#network-design-decisions)
- [Validated Performance](#validated-performance)
- [Troubleshooting](#troubleshooting)

---

## When to Use This Guide

Use this guide when your rack has:

- A **high-speed Ethernet AI fabric** (100G, 200G, 400G, or 800G): either a switched
  Clos fabric with BGP routing, or a **switchless star** where nodes are cabled
  directly to one another (see [Fabric Topologies](#fabric-topologies-clos-and-star))
- Intel® **E810-C** or compatible high-speed NICs in compute/storage nodes
- **Dual-homed nodes**: a high-speed fabric NIC for data plane + a 1G/10G management NIC
- **NVMe storage nodes** for Ceph OSD placement
- Multiple node families (e.g. Intel® GNR-AP compute + minfra control plane + mstore storage)

For standard single-NIC multi-node deployments, see [multi-node-deployment.md](multi-node.md).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Management Network                        │
│                      172.18.x.x  (1G/10G)                       │
│    master1/2/3          ceph1/2/3           gnr01–gnr06          │
│   172.18.168.x        172.18.168.x         172.18.148/158.x      │
└────────────┬───────────────┬────────────────────┬───────────────┘
             │ SSH / Ansible │                    │
             │               │                    │
┌────────────▼───────────────▼────────────────────▼───────────────┐
│             High-Speed AI Fabric (Arista Clos or equivalent)             │
│            Leaf-C (10.202.0.0/16)  Leaf-D (10.201.0.0/16)        │
│                                                                   │
│  ceph1: 10.201.2.1   gnr01: 10.201.148.1 + 10.202.148.1          │
│  ceph2: 10.201.2.2   gnr02: 10.201.148.5 + 10.202.148.5          │
│  ceph3: 10.201.2.3   gnr0N: ...                                   │
│                                                                   │
│  Pod-to-pod traffic:  native BGP, zero encapsulation, MTU 9000   │
│  Ceph OSD traffic:    10.201.2.x ↔ 10.201.148.x (same fabric)    │
└─────────────────────────────────────────────────────────────────┘
```

**Key design points:**

- **Control plane on management** (`control_plane_on_fabric: false`): kube-apiserver and etcd bind to `172.18.x.x`. Safe for sites where master nodes have only 1G management NICs.
- **Workers and storage on fabric**: kubelet `ip`/`access_ip` = fabric IP. All pod and Ceph traffic uses the high-speed fabric NIC.
- **Calico native BGP**: no IPIP or VXLAN overlay. Pods route directly via leaf switches at wire speed.
- **Ceph OSD bind address** = fabric IP. OSD-to-OSD replication and client traffic both flow over the fabric NIC.

---

## Hardware Reference: Intel Lab201

| Node | Hostname | Role | Mgmt IP | Fabric IP(s) | NIC |
|---|---|---|---|---|---|
| master1–3 | minfra01–03 | control-plane, etcd | 172.18.168.1–5 | 10.201.1.1–3 | ens786f0np0 |
| ceph1–3 | mstore01–03 | storage (Ceph OSD) | 172.18.168.7–11 | 10.201.2.1–3 | ens786f0np0 |
| gnr01–03 | m6972m01–03 | compute (GNR-AP) | 172.18.148.1–9 | 10.201.148.x + 10.202.148.x | ens6f0 + ens28f0 |
| gnr04–06 | m6980m05–07 | compute (GNR-AP) | 172.18.158.17–30 | 10.201.158.x + 10.202.158.x | ens6f0 + ens28f0 |

> GNR-AP compute nodes are **dual-homed** across both Arista leaf switches -
> `ens6f0` (Leaf-D, `10.201.x.x`) is the primary Kubernetes `access_ip`;
> `ens28f0` (Leaf-C, `10.202.x.x`) is reserved for RDMA/Multus secondary networks (Phase 3).

---

## How It Works

```
rack-profile.yaml          (you edit this: one file per site)
        │
        ▼
rack-profile-parser.sh     (generates all derived config)
        │
        ├──▶ core/inventory/hosts.yaml             (Kubespray inventory)
        ├──▶ core/inventory/metadata/k8s-net-fabric.yml  (Calico BGP vars)
        ├──▶ core/inventory/netplan/<hostname>.yaml         (fabric IPs + routes)
        ├──▶ core/inventory/metadata/bgp-peers/*.yaml      (per-node BGPPeer CRDs)
        └──▶ core/inventory/metadata/vars/ceph-storage.yml  (Ceph OSD vars)
                │
                ▼
        ./stack-manager install agent-toolkit
                │
                ├──▶ deploy-netplan.yml     → applies fabric IPs to the NICs
                ├──▶ deploy-ecmp-sysctl.yml → star hub forwarding (star only)
                ├──▶ verify-fabric.yml      → fabric reachability precheck
                ├──▶ Kubespray  → Kubernetes cluster (BGP, MTU 9000, dual-homed)
                ├──▶ Calico     → Native BGP peering, no encapsulation
                ├──▶ deploy-ecmp-sysctl.yml → ECMP hashing (post-Calico, BGP sites)
                ├──▶ Rook/Ceph  → OSDs on fabric IPs, NVMe raw devices
                └──▶ AI Stack   → LiteLLM, Langfuse, Redis, pgvector, Sandbox
```

The parser is the only place topology is interpreted. Everything downstream -
netplan, Ansible groups, sysctl targets: is derived from the profile, so the
deployment scripts contain no site-specific assumptions.

---

## Fabric Topologies: Clos and Star

`network.topology` selects how the parser wires the fabric. It defaults to `clos`,
so existing profiles that omit the key are unaffected.

### `topology: clos` (default)

Leaf/spine. Every fabric NIC declares the `leaf:` it is cabled to, and each leaf
declares its `peer_ip` (the switch SVI) and `fabric_subnet`. Nodes share a flat
subnet per leaf: `network.fabric_prefix` (default `16`) is the on-link prefix.

The parser generates, per NIC:
- the address at `fabric_prefix`
- a gateway of the leaf's `peer_ip`
- static routes to every *other* leaf's `fabric_subnet` via that gateway

With `calico_mode: bgp`, each secondary NIC also gets a `BGPPeer` CRD using
`sourceAddress`, so bird dials that leaf from the correct local IP.

Leaves whose `peer_ip` is still `TBD` are skipped: no gateway, no routes, no peer.

### `topology: star` (switchless)

No switches. Each spoke is cabled directly to one hub node, and every cable is
its own point-to-point subnet: declare `prefix: 30` on each NIC and `peer:` the
inventory name of the node at the far end. Exactly one node sets
`fabric_router: true`.

The parser:
- derives the **fabric supernet**: the smallest network containing every
  `fabric_ip` in the profile
- gives each spoke a static route to that supernet via the hub IP that shares the
  spoke's own /30 (the next-hop is on-link, so no ARP-for-a-stranger problem)
- gives the hub only its connected legs: no routes, since every /30 is local
- puts the hub in the `fabric_routers` inventory group, which
  `deploy-ecmp-sysctl.yml` uses to set `net.ipv4.ip_forward=1`

```
              master1 ──── 10.201.1.1/30 ──┐
                                            │  10.201.1.2/30
              master2 ──── 10.201.1.5/30 ──┼── hpe690  (fabric_router: true)
                                            │  10.201.1.6/30
              master3 ──── 10.201.1.9/30 ──┘  10.201.1.10/30

  spoke route: 10.201.1.0/28 via <the hub IP inside my own /30>
  hub:         forwards between legs (ip_forward=1)
```

> **Do not put a star fabric on one flat subnet.** Every node would believe its
> peers are on-link and ARP for them; the hub does not answer for addresses it
> does not own, so nothing resolves and etcd never forms a quorum. The /30-per-cable
> model is what makes the hub a router instead of a bystander.

`calico_mode: vxlan` is the right choice for star: there are no switches to peer
with, so there is no BGP next-hop to program.

### ECMP is derived, not labelled

`deploy-ecmp-sysctl.yml` no longer targets a hardware label. The parser computes
the `ecmp_nodes` group: any node with **two or more fabric NICs whose leaf has a
real `peer_ip`**, when `calico_mode: bgp`. Those nodes get
`fib_multipath_hash_policy=1` and loose reverse-path filtering.

Star nodes are excluded by construction: a star has no equal-cost paths to hash
across, only point-to-point legs.

Both `ecmp_nodes` and `fabric_routers` are omitted from the inventory when no node
qualifies, so the playbook is a no-op on a single-homed Clos site.

---

## Step 1: Prerequisites

Same as the standard deployment, plus:

- All nodes reachable from the bastion (master1) via SSH on the **management network** (`172.18.x.x`)
- Fabric NICs physically cabled and **up**. Their IPs do not need to be set by hand -
  the parser generates a netplan file per node from `rack-profile.yaml` and
  `deploy-netplan.yml` applies it. The generated file is named `99-fabric.yaml` so it
  outranks `50-cloud-init.yaml`.
- Interface names recorded accurately per node: they vary across node families.
  Confirm with `ip -br link` on each node; do not assume they match.
- Clos only: leaf switches already configured with BGP and SVI gateway IPs
- NVMe devices on storage nodes wiped and unpartitioned (e.g. `nvme1n1`, `nvme2n1`, `nvme3n1`: **never `nvme0n1`** which is the OS disk)

See [prerequisites.md](../getting-started/prerequisites.md) for SSH key and TLS setup.

---

## Step 2: Edit rack-profile.yaml

`core/inventory/rack-profile.yaml` is the **single source of truth** for your rack hardware. Edit it to match your site. Do not edit `hosts.yaml` or `ceph-storage.yml` directly: they are generated.

### Site metadata

```yaml
site:
  name: lab201
  location: "Your site name"
  description: "Brief description"
```

### Network fabric

```yaml
network:
  calico_mode: bgp         # 'bgp' for switched fabric | 'vxlan' for dev/switchless
  topology: clos           # 'clos' (default) | 'star': see Fabric Topologies
  pod_cidr: 10.244.0.0/16  # must not overlap fabric or mgmt subnets
  service_cidr: 10.96.0.0/12
  mtu: 9000                # set to match your switch configuration

  fabric_prefix: 16        # default on-link prefix; override per NIC with `prefix:`
  netplan_renderer: networkd   # or NetworkManager: must match the host's renderer

  # false = masters/etcd stay on management network (recommended for most sites)
  # true  = masters also have fabric NICs and bind to fabric IPs
  control_plane_on_fabric: false

  leafs:
    - name: leaf1
      model: "Arista DCS-7170-64C"
      asn: 65005
      peer_ip: 10.202.0.1       # Arista SVI gateway IP for this leaf's subnet
      fabric_subnet: 10.202.0.0/16
    - name: leaf2
      model: "Arista DCS-7170-64C"
      asn: 65004
      peer_ip: 10.201.0.1
      fabric_subnet: 10.201.0.0/16

  bgp:
    cluster_asn: 65100          # AS number assigned to all cluster nodes
```

For `topology: star`, delete the `leafs:` block entirely and see
[Star topology](#star-topology-example) below.

### SSH access

Defaults applied to every non-bastion node. Both are overridable per node.

```yaml
access:
  ansible_user: ubuntu
  ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### Racks and nodes

Each node entry maps its management IP, fabric NICs, and roles:

```yaml
racks:
  rack-infra:
    nodes:
      master1:
        hostname: minfra01
        mgmt_ip: 172.18.168.1
        local: true                   # marks the Ansible bastion node
        roles: [kube_control_plane, etcd]
        fabric_nics:
          - nic: ens786f0np0
            fabric_ip: 10.201.1.1
            leaf: leaf2

      ceph1:
        hostname: mstore01
        mgmt_ip: 172.18.168.7
        roles: [kube_node, storage]   # 'storage' role → Ceph OSD node
        fabric_nics:
          - nic: ens786f0np0
            fabric_ip: 10.201.2.1
            leaf: leaf2

  rack-compute:
    nodes:
      gnr01:
        hostname: m6972m01
        mgmt_ip: 172.18.148.1
        roles: [kube_node, gnr_ap]
        fabric_nics:
          - nic: ens6f0              # primary: used as access_ip
            fabric_ip: 10.201.148.1
            leaf: leaf2
          - nic: ens28f0             # secondary: dual-homed, so joins ecmp_nodes
            fabric_ip: 10.202.148.1
            leaf: leaf1
```

**Role reference:**

| Role | Effect |
|---|---|
| `kube_control_plane` | Added to `kube_control_plane` Kubespray group |
| `etcd` | Added to `etcd` group |
| `kube_node` | Added to `kube_node` (worker) group |
| `storage` | Added to `ceph_storage_nodes`; Ceph OSD devices assigned |
| `gnr_ap` | Added to `gnr_ap` group; NRI CPU policy applied |

Roles outside this table produce a warning and no inventory group: the parser
lists what it recognises so a typo does not silently drop a node from a group.

A node may combine roles. `[kube_control_plane, etcd, storage]` colocates the
control plane with Ceph OSDs; the Rook chart already carries the tolerations for
the control-plane taint (operator, mon/mgr placement, provisioner, plugin, and
discover). Adding `kube_node` to a master also schedules general workloads there
- a valid choice on a small cluster, but the control-plane taint no longer
protects it.

#### Star topology example

Set `topology: star`, drop `leafs:` and every `leaf:` key, then declare each cable
as its own /30 with `peer:` naming the far end. Exactly one node sets
`fabric_router: true`.

```yaml
network:
  calico_mode: vxlan
  topology: star
  control_plane_on_fabric: true

racks:
  rack-infra:
    nodes:
      master1:
        hostname: gigabyte01
        mgmt_ip: 172.26.38.228
        local: true
        roles: [kube_control_plane, etcd, storage]
        fabric_nics:
          - nic: enp167s0np0
            fabric_ip: 10.201.1.1
            prefix: 30
            peer: worker1

  rack-compute:
    nodes:
      worker1:                       # the hub: one NIC per spoke
        hostname: hpe690
        mgmt_ip: 172.26.38.103
        roles: [kube_node]
        fabric_router: true
        fabric_nics:
          - nic: enp151s0np0
            fabric_ip: 10.201.1.2
            prefix: 30
            peer: master1
```

The parser rejects a star profile that has no `fabric_router`, has more than one,
or whose `peer:` names a node that is not defined. It also warns if a spoke's /30
contains no hub IP: that combination cannot produce a working route and almost
always means the addresses or the cabling map are wrong.

### Storage

```yaml
storage:
  ceph_fabric_nic: ens786f0np0      # NIC used for Ceph public + cluster network
  ceph_public_network: 10.201.0.0/16
  ceph_cluster_network: 10.201.0.0/16

  nodes:
    - name: ceph1
      devices: [nvme1n1, nvme2n1, nvme3n1]   # raw NVMe devices for OSD: NOT nvme0n1
    - name: ceph2
      devices: [nvme1n1, nvme2n1, nvme3n1]
    - name: ceph3
      devices: [nvme1n1, nvme2n1, nvme3n1]
```

> **Important:** `nvme0n1` is the OS disk on all storage nodes: never list it.
> Ceph will wipe any device listed here. Verify with `lsblk` on each storage node before proceeding.

---

## Step 3: Run the Parser

```bash
cd /home/ubuntu/rack-scale/applications.ai.enterprise.agentic-ai-stack-rack-scale

# Dry-run first: shows what would be generated without writing files
./core/lib/rack-profile-parser.sh --dry-run

# Generate all derived files
./core/lib/rack-profile-parser.sh
```

**What gets generated:**

```
core/inventory/hosts.yaml
  └─ All nodes with correct ip/access_ip (fabric IPs for workers/storage,
     mgmt IPs for control-plane when control_plane_on_fabric=false)
  └─ Ceph OSD nodes include their devices: list

core/inventory/metadata/k8s-net-fabric.yml
  └─ calico_mode, pod_cidr, service_cidr, mtu, BGP peer list

core/inventory/metadata/vars/ceph-storage.yml
  └─ ceph_fabric_nic, ceph_public/cluster_network, ceph_storage_nodes list
```

**Verify the output:**

```bash
# Workers should have fabric IPs as ip/access_ip
grep -A3 "gnr01:" core/inventory/hosts.yaml
# ip: 10.201.148.1
# access_ip: 10.201.148.1

# Control plane should have mgmt IPs (when control_plane_on_fabric=false)
grep -A3 "master1:" core/inventory/hosts.yaml
# ip: 172.18.168.1
# access_ip: 172.18.168.1

# Ceph nodes should have fabric IPs and devices listed
grep -A6 "ceph1:" core/inventory/hosts.yaml
# ip: 10.201.2.1
# access_ip: 10.201.2.1
# devices: ['nvme1n1', 'nvme2n1', 'nvme3n1']
```

---

## Step 4: Configure agentic-config.cfg

> [!WARNING]
> **Not installed by Stack Manager yet.** `agentic-config.cfg` and `rack_scale_mode=on` belong to the standalone stack. There is no equivalent flag in `env/local/*.yaml` today. Do not mix these steps with `stack-manager` until the team confirms how Stack Manager should map them.

Open `core/inventory/agentic-config.cfg` and set:

```ini
cluster_url=your-cluster-fqdn.example.com
cert_file=~/certs/cert.pem
key_file=~/certs/key.pem
hugging_face_token=hf_xxxxxxxxxxxxxxxxxxxx

# Model: MoE models recommended for CPU inference (lower latency than dense)
models=cpu-qwen3-30b-a3b

# Core deployment flags
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_agenticai_plugin=on
deploy_redis=on
deploy_pgvector=on
deploy_agent_sandbox=on

# Ceph distributed storage: requires storage-role nodes in rack-profile.yaml
deploy_ceph=on

# Enables rack-scale mode: activates fabric-aware Kubespray config,
# Calico BGP, and Ceph-on-fabric deployment paths
rack_scale_mode=on
```

> **`rack_scale_mode=on`** is the key flag. It activates:
> - Kubespray reading `k8s-net-fabric.yml` for BGP and MTU config
> - Calico deploying in native BGP mode (no IPIP/VXLAN)
> - Ceph reading `ceph-storage.yml` to bind OSDs to fabric IPs
> - Node labeling for `ei-inference-eligible` and `ei-infra-eligible`

### Model selection for CPU inference

| Model value | Parameters | Active params | Recommended for |
|---|---|---|---|
| `cpu-llama-8b` | 8B dense | 8B | Fastest, lowest latency |
| `cpu-llama-8b-specdec` | 8B + speculative | 8B | Faster with speculative decoding |
| `cpu-qwen3-30b-a3b` | 30B MoE | ~3B | **Best CPU trade-off**: large model quality, low cost |
| `cpu-gemma4-26b-a4b` | 26B MoE | ~4B | Google Gemma4 alternative |
| `cpu-qwen2-5-coder-14b` | 14B dense | 14B | Coding-specialized, higher latency |
| `cpu-qwen3-coder-30b` | 30B dense | 30B | Highest quality, slowest |

MoE (Mixture of Experts) models activate only a fraction of parameters per token, giving near-large-model quality at small-model inference cost. **`cpu-qwen3-30b-a3b` is the recommended default for CPU deployments.**

---

## Step 5: Deploy

```bash
chmod +x stack-manager
./stack-manager install agent-toolkit
```

Expected phases:
1. **Kubespray** (~20–35 min): provisions Kubernetes across all nodes, configures Calico BGP, sets MTU 9000
2. **Ingress + Gateway** (~5 min): NGINX ingress, LiteLLM
3. **Observability** (~5 min): Prometheus, Grafana, Langfuse
4. **Ceph** (~10 min): Rook operator, CephCluster, StorageClass
5. **LLM models** (~5–15 min depending on model weight download)
6. **Redis, pgvector, Agent Sandbox** (~5 min)

Total: approximately 50–70 minutes for a fresh 12-node cluster.

---

## Step 6: Verify Fabric Networking

After deployment, confirm pod traffic is running over the fabric:

```bash
# All nodes Ready, workers on fabric IPs, masters on mgmt IPs
kubectl get nodes -o wide

# BGP sessions: all cluster nodes should show Established
# SSH to a worker node and run:
ssh ubuntu@<worker-mgmt-ip> "sudo birdc show protocols | grep -E 'Mesh|Established'"
# Expected: Mesh_10_201_x_x   BGP  ...  Established

# Pod-to-pod route uses fabric NIC (not mgmt NIC)
ssh ubuntu@<worker-mgmt-ip> "ip route show 10.244.0.0/16"
# 10.244.x.x via 10.201.x.x dev ens6f0   ← fabric NIC ✅

# Cross-leaf pod latency
kubectl run ping-test --image=busybox --rm -it --restart=Never -- \
  ping -c4 <pod-ip-on-other-leaf>
# Expected: < 1ms RTT
```

**Validated performance (Intel Lab201, Arista Clos, 100G E810-C NICs):**

```
iperf3 4-stream cross-leaf (gnr01 → gnr04):
  [SUM] 0.00-10.00 sec  96.7 GBytes  83.1 Gbits/sec  ✅
```

> On 200G/400G/800G links, expected throughput scales proportionally -
> no configuration changes required beyond `mtu` and NIC interface names in `rack-profile.yaml`.

---

## Step 7: Verify Ceph on Fabric

Confirm Ceph OSD traffic uses fabric IPs:

```bash
# All OSDs up and on fabric IPs
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd find 0
# "addr": "10.201.2.x:6800"   ← fabric IP ✅
# "host": "ceph1"

kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
# osd: 3 osds: 3 up, 3 in
# HEALTH_OK

# Run a quick block storage write test
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-verify-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ceph-verify
spec:
  restartPolicy: Never
  containers:
  - name: fio
    image: ljishen/fio
    command:
    - fio
    - --name=seqwrite
    - --filename=/data/testfile
    - --rw=write
    - --bs=1M
    - --size=4G
    - --numjobs=4
    - --iodepth=32
    - --ioengine=libaio
    - --direct=1
    - --group_reporting
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ceph-verify-pvc
EOF

kubectl wait pod/ceph-verify --for=condition=Ready=False --timeout=300s
kubectl logs ceph-verify | grep "WRITE:"
# WRITE: bw=XXXX MiB/s  ← should be >500 MiB/s on NVMe fabric

kubectl delete pod ceph-verify && kubectl delete pvc ceph-verify-pvc
```

**Validated performance (Intel Lab201, 3×NVMe nodes, 100G fabric, concurrent workloads):**

| Test | Result |
|---|---|
| Sequential write (isolated) | **1.42 GB/s** |
| Random 4K read IOPS (concurrent) | **29,000 IOPS** |
| Random 4K write IOPS (concurrent) | **12,500 IOPS** |
| Fabric NIC utilization under load | ~18–20 Gbps (validated on 100G; NVMe is the bottleneck, not the fabric) |

---

## rack-profile.yaml Reference

### `network` fields

| Field | Type | Description |
|---|---|---|
| `calico_mode` | `bgp` \| `vxlan` | CNI mode. `bgp` = native L3 via the switches, `vxlan` = overlay for dev/switchless |
| `topology` | `clos` \| `star` | Fabric wiring model. Default `clos`. See [Fabric Topologies](#fabric-topologies-clos-and-star) |
| `pod_cidr` | CIDR | Pod network. Must not overlap `10.201.x.x` fabric or `172.18.x.x` mgmt |
| `service_cidr` | CIDR | Kubernetes service network |
| `mtu` | int | Fabric MTU. Set to match switch config (9000 for jumbo frames) |
| `fabric_prefix` | int | Default on-link prefix for fabric NICs. Default `16`. Override per NIC with `prefix:` |
| `netplan_renderer` | `networkd` \| `NetworkManager` | Renderer written into the generated netplan. Default `networkd`. Must match the host |
| `control_plane_on_fabric` | bool | `false` = masters bind to mgmt IP (etcd/apiserver on management). `true` = masters also use fabric IPs |
| `leafs[].peer_ip` | IP | Switch SVI gateway IP: Calico BGP peer target. `TBD` skips gateway, routes, and peering |
| `leafs[].fabric_subnet` | CIDR | That leaf's subnet: used to generate cross-leaf routes |
| `leafs[].asn` | int | Leaf switch BGP ASN |
| `bgp.cluster_asn` | int | BGP AS number for all cluster nodes |

### `access` fields

| Field | Type | Description |
|---|---|---|
| `ansible_user` | string | SSH user for non-bastion nodes. Default `ubuntu`. Override per node |
| `ansible_ssh_private_key_file` | path | SSH key for non-bastion nodes. Default `~/.ssh/id_ed25519`. Override per node |

### `node` fields

| Field | Type | Description |
|---|---|---|
| `hostname` | string | Actual system hostname |
| `mgmt_ip` | IP | Management network IP (used for SSH/Ansible). Must be unique |
| `local` | bool | Mark the Ansible bastion node (`ansible_connection: local`) |
| `roles` | list | Kubespray groups this node joins. See role table above |
| `fabric_router` | bool | **Star only.** Marks the hub. Exactly one node must set it |
| `ceph_fabric_nic` | string | Overrides `storage.ceph_fabric_nic` for this node |
| `ansible_user` | string | Overrides `access.ansible_user` for this node |
| `ansible_ssh_private_key_file` | path | Overrides `access.ansible_ssh_private_key_file` for this node |
| `fabric_nics[].nic` | string | Kernel interface name (e.g. `ens6f0`) |
| `fabric_nics[].fabric_ip` | IP | IP to configure on this NIC. Must be unique |
| `fabric_nics[].prefix` | int | Overrides `network.fabric_prefix` for this NIC (e.g. `30` for a star cable) |
| `fabric_nics[].leaf` | string | **Clos only.** Leaf name from `network.leafs` this NIC connects to |
| `fabric_nics[].peer` | string | **Star only.** Inventory name of the node at the other end of the cable |

The first entry in `fabric_nics` is the primary: it becomes `ip`/`access_ip`.
A node with no `fabric_nics` falls back to `mgmt_ip`.

### `storage` fields

| Field | Type | Description |
|---|---|---|
| `ceph_fabric_nic` | string | Site-wide NIC name carrying Ceph traffic. Its presence enables Rook's `provider: host`; the name itself is not passed to Rook but is validated against each storage node's real NICs. Override per node with `ceph_fabric_nic` |
| `ceph_public_network` | CIDR | Client-to-OSD network. Applied via Rook `network.addressRanges.public` |
| `ceph_cluster_network` | CIDR | OSD-to-OSD replication network. Applied via Rook `network.addressRanges.cluster` |
| `nodes[].name` | string | Node name (must match a node key in `racks`) |
| `nodes[].devices` | list | Raw block device names for OSD. **Never include the OS disk.** |

### Derived inventory groups

The parser computes these from the profile: they are never declared directly.

| Group | Membership |
|---|---|
| `ecmp_nodes` | `calico_mode: bgp` nodes with ≥2 fabric NICs on leaves that have a real `peer_ip`. Gets ECMP flow hashing + loose RPF |
| `fabric_routers` | The `fabric_router: true` node in a star. Gets `ip_forward=1` |
| `cp_mgmt_nodes` | Control-plane nodes on the management network, when they share one NIC name |
| `cp_mgmt_<nic>_nodes` | One group per distinct mgmt NIC name, when control-plane nodes differ |

A group with no members is omitted from `hosts.yaml`, which is what makes the
sysctl playbook a safe no-op on a plain single-homed Clos site.

### Validation

The parser exits non-zero without writing any files when it finds: an unknown
`topology`; a duplicate `mgmt_ip` or `fabric_ip`; a star with zero or multiple
`fabric_router` nodes; or a `peer:` that names an undefined node. It warns (and
continues) on an unrecognised role, a `storage` node whose `fabric_nics` contain no
NIC matching its effective `ceph_fabric_nic`, `fabric_router` set outside a star,
and a star spoke that shares no subnet with any hub NIC.

Run `./core/lib/rack-profile-parser.sh --dry-run` to see every generated file
without touching the filesystem.

---

## Network Design Decisions

### Why native BGP instead of VXLAN?

VXLAN adds ~50 bytes of encapsulation overhead per packet and requires the host
kernel to encap/decap every packet. On a high-speed AI fabric with jumbo frames, this
wastes bandwidth and CPU cycles: and the penalty grows with link speed.

With native BGP (`calico_mode: bgp`), Calico programs per-pod host routes via
bird and the Arista leaf switches forward pod traffic at L3 wire speed. No
encapsulation, no kernel overhead: packets go fabric NIC → Arista → fabric NIC.

### Why control_plane_on_fabric=false?

kube-apiserver and etcd are sensitive to network partitions. At most customer
sites, master nodes have only 1G management NICs. Binding etcd to a fabric IP
that could be unreachable during NIC or switch maintenance risks split-brain.
The management network is the safe choice for control-plane communication.

Workers use fabric IPs as `access_ip`: kubelet and pod traffic go over 100G -
but kube-apiserver is still reachable on `172.18.x.x` from all nodes.

### Why Ceph public and cluster networks on the same fabric subnet?

For simplicity on a two-leaf Clos: all nodes can reach `10.201.0.0/16` via the
fabric. A separate cluster network is only needed if you want to isolate
OSD-to-OSD replication from client traffic. With high-speed fabric available, sharing the
subnet is not a bottleneck: the NVMe drives saturate before the network does.

---

## Validated Performance

All results measured on Intel Lab201: Arista Clos fabric, Intel® E810-C NICs at **100G**,
3× control-plane, 3× NVMe storage, 6× GNR-AP compute nodes.

The stack is speed-agnostic. Results on 200G/400G/800G fabrics will scale with link speed
- NVMe drive throughput and Ceph OSD count are the expected bottleneck, not the network.

| Metric | Result |
|---|---|
| BGP sessions established | 11/11 ✅ |
| Cross-leaf iperf3 (4 streams, 100G links) | **83.1 Gbits/sec** |
| Cross-leaf pod RTT | **0.7ms** |
| Encapsulation overhead | **None** (native BGP: applies at any link speed) |
| Ceph sequential write (isolated, fio 4-job) | **1.42 GB/s** |
| Ceph random 4K read IOPS (concurrent burn) | **29,000** |
| Ceph random 4K write IOPS (concurrent burn) | **12,500** |
| Ceph fabric NIC utilization under burn | ~18–20 Gbps (NVMe-limited, not fabric-limited) |
| Cluster stability under burn | ✅ No errors, all OSDs up |

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Workers show mgmt IP as `INTERNAL-IP` instead of fabric IP | Parser generated incorrect `ip`/`access_ip`. Re-run `rack-profile-parser.sh` and verify `control_plane_on_fabric` setting |
| BGP sessions not `Established` | Verify Arista SVI IPs match `leafs[].peer_ip` in `rack-profile.yaml`. Check `sudo birdc show protocols` on a worker node |
| Ceph OSDs bound to mgmt IP instead of fabric IP | `ceph_fabric_nic` in `rack-profile.yaml` does not match actual NIC name on storage nodes. Verify with `ip link show` on a storage node |
| Ceph `HEALTH_WARN: too many PGs per OSD` | Benign with small OSD count. Fix: `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph config set global mon_max_pg_per_osd 300` |
| Pod-to-pod traffic going over mgmt NIC | Calico IP autodetection picked wrong interface. Check `calico_ip_auto_method` in `k8s-net-fabric.yml`: should be set to match the fabric NIC |
| NVMe device not used by Ceph | Device may have existing partitions. Wipe with `wipefs -a /dev/nvmeXn1` on the storage node, then re-run Ceph deployment |
| `rack-profile-parser.sh` reports missing node | Node name in `storage.nodes` does not match a node key in `racks`. Names must match exactly |
| `verify-fabric.yml` says a master's fabric IP is unreachable, but cabling is fine | On a **star**, spoke-to-spoke traffic transits the hub, so check the hub (`fabric_routers`) first: `sudo iptables -S FORWARD`. A bare `-P FORWARD DROP` with no `star fabric transit` ACCEPT rules blackholes spoke-to-spoke traffic while hub-to-spoke pings still succeed: so the fabric looks healthy. Both `reset.yml` and Kubespray's reset role flush the filter table, so this is the normal state after a reset. Fix: `ansible-playbook -i core/inventory/hosts.yaml core/playbooks/deploy-ecmp-sysctl.yml` |

## Related pages

- [Multi-node deployment](multi-node.md): Ethernet cluster layout that Stack Manager installs
- [Prerequisites](../getting-started/prerequisites.md)
- [Configuration](../configuration/configuration.md)
- [Docs index](../README.md)
