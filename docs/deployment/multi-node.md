# Multi-node deployment

[← Docs index](../README.md)

Use this guide when you have more than one host and you want the Agent Toolkit spread across them. A typical layout is one **control-plane** node that runs Kubernetes and the stack services, plus one or more **worker** nodes that take extra model pods when a single host is not enough CPU or memory.

Kubernetes itself is installed by Kubespray. The list of nodes is `env/local/inventory/hosts.yaml`: every host you put there is joined into the cluster.

If you only have one host, follow the [single-node quickstart](../getting-started/quickstart.md) instead.

> [!WARNING]
> **Not installed by Stack Manager yet.** [Rack-scale deployment](rack-scale.md) (100G/200G/400G fabric and NVMe Ceph) still describes the standalone stack. The team needs to review that page. Do not mix it with this multi-node guide until someone confirms it.

Complete **[Prerequisites](../getting-started/prerequisites.md)** on every node before you start: SSH from the installer host to all nodes, `/etc/hosts` (or DNS), and TLS.

## Topologies

Most teams start with a single control plane and add workers for inference. Three control-plane nodes are only needed if you cannot tolerate losing the Kubernetes API on one node.

| Layout | When to choose it |
|---|---|
| 1 control plane + N workers | Production that can scale models out. The control plane also runs as a worker unless you taint it. |
| 3 control planes + N workers | High availability for etcd and the API server. Put a load balancer in front and point `base_domain_name` at the load-balancer IP. |

The gateway (NGINX ingress or Envoy) binds to the control-plane node by default. With several control planes, traffic should land on the load balancer, not on a single node's IP.

## 1. Seed config, then list every node

Run these from the Stack Manager directory, on the host that will drive the install. [Meet the Agent Toolkit](../overview/meet.md) explains that Stack Manager installs, updates, and tears the toolkit down.

```bash
chmod +x stack-manager
./stack-manager configure
./stack-manager init agent-toolkit
```

`init` writes a **single-node** `env/local/inventory/hosts.yaml` that points at `localhost`. For a real cluster, edit that file so every node appears under the right Kubespray groups (`kube_control_plane`, `kube_node`, `etcd`). Alternatively, fill `nodes_control_plane` and `nodes_workers` in `config/defaults/nodes.yaml` and let the installer generate inventory.

Here is a control plane plus two workers. Replace IPs, the SSH user, and the key path with your values:

```yaml
all:
  hosts:
    master1:
      ansible_host: 10.0.0.1
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker1:
      ansible_host: 10.0.0.2
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
    worker2:
      ansible_host: 10.0.0.3
      ansible_user: ubuntu
      ansible_ssh_private_key_file: /home/ubuntu/.ssh/id_rsa
      ansible_become: true
  children:
    kube_control_plane:
      hosts:
        master1:
    kube_node:
      hosts:
        master1:
        worker1:
        worker2:
    etcd:
      hosts:
        master1:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
```

The host that runs `install` must be able to SSH to every `ansible_host` using the key in `ansible_ssh_private_key_file`. Password logins are not enough; Ansible will fail.

Open these ports between nodes: Kubernetes API `6443`, etcd `2379–2380`, Calico BGP `179`, kubelet `10250`. Keep the NodePort range `30000–32767` off the public internet. Redis in this stack is ClusterIP on purpose; do not publish it as NodePort.

## 2. DNS and TLS on every node

Each node needs to resolve the gateway names. If you do not have DNS yet, add `/etc/hosts` entries that point at the control-plane IP (or the load-balancer IP):

```bash
# 10.0.0.1 = control-plane or LB. api.example.com = your base_domain_name
sudo bash -c 'cat >> /etc/hosts <<EOF
10.0.0.1 api.example.com
10.0.0.1 trace-api.example.com
EOF'
```

On the **control-plane**, create a certificate that covers those names (or install one from your CA), then point `global_config.yaml` at the files:

```bash
DOMAIN="api.example.com"
mkdir -p ~/certs && cd ~/certs && \
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
  -subj "/CN=${DOMAIN}" \
  -addext "subjectAltName = DNS:${DOMAIN}, DNS:trace-${DOMAIN}, DNS:*.${DOMAIN}"
```

```yaml
# env/local/global_config.yaml
gateway_tls_mode: custom
gateway_tls_cert_file: /home/ubuntu/certs/cert.pem
gateway_tls_key_file: /home/ubuntu/certs/key.pem
```

The same `base_domain_name` must match DNS/`/etc/hosts` and the certificate. Details and the production CA path are in [Prerequisites](../getting-started/prerequisites.md#2-dns-and-tls).

## 3. The rest of the YAML

The files under `env/local/` are the same ones the [quickstart](../getting-started/quickstart.md) uses. On several nodes, the settings that usually change are the domain, TLS (already set above), and **storage**. `local-path` only works on one node; use `nfs` or `ceph` when pods can land on any worker.

```yaml
# env/local/global_config.yaml
base_domain_name: api.example.com
auth_provider: litellm
storage_backend: ceph
```

```yaml
# env/local/config.inference.yaml
llm_services_deploy_models: true
```

Choose models by setting `autodeploy: true` in `env/local/models.yaml`. The catalog names and a full table are in the [quickstart](../getting-started/quickstart.md#3-choose-a-model).

If a model is gated on Hugging Face (Llama, Gemma), export a token in the same shell as `install`:

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx
```

Qwen3-4B is ungated and does not need a token.

## 4. Install from the control plane

```bash
./stack-manager install agent-toolkit
```

Kubespray reads `hosts.yaml` and provisions Kubernetes first (often 20–30 minutes on a fresh set of nodes). After that, the installer deploys platform, inference, and the toolkit. The command is idempotent: if it stops part-way, run it again.

## 5. Confirm the cluster and the API

Wait until every node is Ready. The vLLM pod may stay in `ContainerCreating` for another 10–15 minutes while it downloads weights.

```bash
kubectl get nodes -o wide
kubectl get pods -A

export LITELLM_MASTER_KEY=$(kubectl get secret litellm-master-key -n litellm \
  -o jsonpath='{.data.master_key}' | base64 -d)

curl -k https://api.example.com/v1/models \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

curl -k https://api.example.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d '{
    "model": "Qwen/Qwen3-4B-Instruct-2507",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

Replace `api.example.com` with your `base_domain_name`. Redis, pgvector, and the sandbox are already running; in-cluster URLs and how to turn on Auto Router are in the [quickstart](../getting-started/quickstart.md#what-also-came-up).

## Add a worker later

To grow a running cluster:

1. Add the node under `all.hosts` and `kube_node` in `hosts.yaml` (or add it to `nodes_workers`).
2. Set up passwordless SSH from the control plane to the new node, the same way as [Prerequisites](../getting-started/prerequisites.md#1-ssh-keys).
3. Re-run `./stack-manager install agent-toolkit`. Kubespray joins the node; toolkit components that are already installed are left as-is.

## Notes

- **Redis** runs as a single StatefulSet in this release, shared by all agents. It is not a Redis Cluster. High availability is a chart-values change, not the default.
- **Model weights** are pulled onto whichever node the vLLM pod is scheduled. If you use a shared PVC, set `storage.pvc_name` in `models.yaml` so every worker can see the same store.
- **Firewall:** in addition to the ports above, do not expose `30000–32767` to the internet. Leave Redis as ClusterIP.

## Troubleshooting

| Symptom | What to try |
|---|---|
| Node `NotReady` | On that node, run `systemctl status kubelet` and check the kubelet logs. |
| Kubespray SSH refused | Confirm `ansible_host` IPs and `ansible_ssh_private_key_file` in `hosts.yaml`, and that you can `ssh` by hand with that key. |
| Pods stuck `Pending` | `kubectl describe node <node>`: usually CPU, memory, or a taint that blocks scheduling. |
| Model pod never lands on a worker | Same check on that worker: resources and taints. |

## Next steps

Once nodes are Ready and chat completions work, you can change YAML in [Configuration](../configuration/configuration.md), copy in-cluster URLs from the [backend connection reference](../reference/backend-connections.md), or [tear the stack down](decommission.md) and install again. The first-run path on one host is the [single-node quickstart](../getting-started/quickstart.md). Failures: [Troubleshooting](../faq-and-troubleshooting/troubleshooting.md).
