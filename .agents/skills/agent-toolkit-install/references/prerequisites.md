# Prerequisites checklist

Check every row before the first install. Commands only read. Run them on each node unless noted.

## Hardware and OS

| Check | Command | Needed |
|---|---|---|
| CPU architecture and AMX | `lscpu \| grep -E 'Architecture\|Model name\|NUMA node\(s\)\|Core\(s\) per socket'`; `grep -o -m1 amx_bf16 /proc/cpuinfo` | x86_64. The model catalog requires AMX (4th-generation Xeon or later) unless `env/<env>/models.yaml` sets `require_amx: false` under `defaults:`. |
| Memory | `free -g` | About **131 GiB** for the default install: default model `qwen2-5-coder-14b` 96 GiB, guard model `qwen3guard` 16 GiB, and about 19 GiB for the rest. On 128 GB set `llm_services_autodeploy_models: ["qwen2-5-coder-7b"]` (64 GiB) before installing. `docs/prerequisites.md` lists too little. |
| CPU cores | `nproc` | The default model takes the free physical cores of one NUMA node (`cpu: auto`). On a small or single-NUMA host, set an explicit `cpu:` per model in `models.yaml`. |
| Disk | `df -h / /var/lib/containerd /opt` | 200 GB or more. Model weights go to `/opt/local-path-provisioner` with the default `local-path` storage. |
| OS | `cat /etc/os-release` | Ubuntu 24.04 is what the toolkit was validated on. Ubuntu 22.04 and RHEL 8 are listed as supported by Toolkit Manager but were not exercised with the toolkit. |
| Swap | `swapon --show` | Off |

## Host state

| Check | Command | Why |
|---|---|---|
| Docker | `systemctl is-active docker` | Kubespray removes a running Docker, and its reset wipes the image store Docker uses. Do not install on a Docker host, or `docker save` and stop Docker first. |
| Ports 80 and 443 | `ss -ltn '( sport = :80 or sport = :443 )'` | The gateway's LoadBalancer IP is the node IP. |
| DNS resolver | `systemctl is-active systemd-resolved` | Without systemd-resolved, `kubeadm init` times out unless `env/<env>/kubespray_extra.yml` sets `kube_resolv_conf: "/etc/resolv.conf"` and `resolvconf_mode: "none"`. |
| inotify limit | `sysctl fs.inotify.max_user_instances` | 128 is too low on busy nodes: file watchers fail with `too many open files` (`docs/prerequisites.md` names the vLLM-SR router; validation runs also saw Kata pods fail this way). Raise it to 8192 on every node. |
| Time sync | `timedatectl status \| grep synchronized` | Every node, for multi-node |
| Existing Kubernetes leftovers | `ls /etc/kubernetes /var/lib/kubelet 2>/dev/null` | Leftovers from a failed install break the next one. `teardown kubernetes` cleans them, but it runs a Kubespray reset on every inventory node: ask the user first. |

## Access

| Check | Command | Needed |
|---|---|---|
| sudo | `sudo -n true && echo nopasswd` | Passwordless sudo lets an assistant run the install. Otherwise the user runs it in a terminal and types the password. |
| Internet or proxy | `curl -sI https://github.com`; `env \| grep -ci '^https\?_proxy='` (counts, does not print values that may hold credentials) | Charts, images and manifests are pulled from the internet. Behind a proxy, put `http_proxy`, `https_proxy` and `no_proxy` in `env/<env>/global_config.yaml`. Write the URL with its port. `no_proxy` needs `localhost`, `127.0.0.1`, the node IPs and subnet, the cluster service and pod CIDRs (`kubernetes_service_cidr`, `kubernetes_cluster_cidr`), `.<base_domain_name>`, `.svc` and `.cluster.local`. The commented proxy block in `global_config.yaml` shows the full pattern. |
| Hugging Face | `[ -n "$HF_TOKEN" ] && echo set` | Needed for gated models. Export it in the shell that runs install and model-manager. |
| `git` | `git --version` | `configure` and `init` need it |
| Kata only | `ls -l /dev/kvm /dev/vhost-vsock; uname -r` | `/dev/kvm` on the nodes (VT-x, or nested virtualisation on a VM), the `vhost_vsock` module, and Linux 5.17 or newer for `kata-fc` on AMX CPUs |
| Multi-node | `ssh <user>@<node> true` from the installer host | Key-based SSH as a non-root sudo user to every node. On the main track, write `env/<env>/inventory/hosts.yaml` by hand with `ansible_connection: ssh` per remote node (`local` for the installer host); the inventory generated from `nodes.yaml` lacks it. |

## Not covered by validation

Treat these as untested and say so to the user:
- bring-your-own clusters
- Ceph or NetApp storage
- air-gapped sites
- non-AMX CPUs
- arm64 installer hosts
- upgrades from toolkit 1.1.0
- adding nodes after install (not supported)
