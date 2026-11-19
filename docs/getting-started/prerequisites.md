# Prerequisites

[← Docs index](../README.md)

Do this once, on every server that will be part of the cluster, **before** the first `install`. When SSH and DNS (or `/etc/hosts`) are in place, go to the [single-node quickstart](quickstart.md). If you already know you will use several servers, still finish this page, then follow [multi-node deployment](../deployment/multi-node.md) instead of the single-node path.

## Hardware

These are the host minimums. The default model (`qwen2-5-coder-14b`) needs more RAM than the 32 GB row: a default install requests about 131 GiB. On a 128 GB node, choose `qwen2-5-coder-7b` or `llama-3-1-8b` in the [quickstart](quickstart.md#3-choose-a-model).

| Requirement | Minimum | Comfortable |
|---|---|---|
| **CPU** | 48 cores, x86_64 | 96+ cores |
| **RAM** | 32 GB | 64 GB |
| **Disk** | 150 GB free | 200 GB |
| **OS** | Ubuntu 22.04 or 24.04 | Ubuntu 22.04 LTS |
| **Processor** | Intel® x86_64 | Intel® Xeon® (validated) |

The CPU, RAM, and disk rows are the sizing. Intel® Xeon® is the processor family this default path is validated on.

> Tensor-parallel models need more memory in the model pod: about 128 GiB for `tp1`/`tp2`, 256 GiB for `tp >= 4`.

You also need:

- `sudo` on the host that runs the installer
- Network access to pull container images and Helm charts
- A [Hugging Face](https://huggingface.co) token with read access when a model is gated (Llama, Gemma). The default `qwen2-5-coder-14b` is not gated.

## Node kernel settings

`fs.inotify.max_user_instances` is a per-UID limit shared by every container running as that UID. The kernel default of 128 is exhausted on a node with many pods, and file watchers then fail with `too many open files` (the vLLM semantic router loses config reload). Raise it on every node before install:

```bash
sudo tee /etc/sysctl.d/90-inotify.conf > /dev/null <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
EOF
sudo sysctl --system
```

## 1. SSH keys

Log in as a **non-root** user with `sudo`. Do not run the installer as `root`. Password-only logins cause Ansible to fail later.

The installer talks to every cluster node over SSH, including a single-node install (it SSHs to itself).

1. Create a key if you do not have one. Leave the passphrase empty when prompted:

   ```bash
   ssh-keygen -t rsa -b 4096
   ```

2. Put the **public** key on every node that will be in the cluster (control plane and workers):

   ```bash
   echo "<contents of ~/.ssh/id_rsa.pub>" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

3. From the host that will run the installer, confirm you can log in without a password:

   ```bash
   chmod 600 ~/.ssh/id_rsa
   ssh -i ~/.ssh/id_rsa <USERNAME>@<IP_ADDRESS>
   ```

   If you use a bastion, the installer host must still reach the nodes through it.

4. After `init`, the inventory is `env/local/inventory/hosts.yaml`. For one server, `init` already writes a localhost inventory: leave it. For several servers, replace it with the layout in [multi-node deployment](../deployment/multi-node.md#1-seed-config-then-list-every-node).

## 2. DNS and TLS
<a id="dns-and-ssltls"></a>

The gateway is HTTPS. Browsers and `curl` need a name that matches the certificate.

`base_domain_name` is that name. If you set it to `api.example.com`, these hostnames must resolve:

| Hostname | What it is |
|---|---|
| `litellm.api.example.com` | LiteLLM UI and API |
| `langfuse.api.example.com` | Langfuse tracing UI |
| `vllm-sr.api.example.com` | vLLM Semantic Router dashboard |
| `coding-agent-api.example.com` | Coding Agent UI. Not in this release |

### Production

- Point DNS (or a load balancer) at the control-plane IP.
- Use a certificate from your CA that covers the base name **and** the subdomains (a wildcard `*.api.example.com`, or a multi-SAN cert).
- Plan renewal before expiry. Port 80 may need to be open if your CA uses HTTP validation.

### Development (one server)

Map the names to this host. The default `gateway_tls_mode: selfsigned` creates the certificate during install, so step 1 is all you need. Step 2 applies only if you want to supply your own certificate.

1. Add `/etc/hosts` entries. Use `127.0.0.1` if you only call the API on this server, or the node's private IP (`hostname -I`) if other hosts will call it:

   ```bash
   # Replace <GATEWAY_IP> with the IP from step 5 of the quickstart
   # (kubectl get svc ... loadBalancer.ingress). 127.0.0.1 works only for local curl
   # before that IP exists.
   sudo bash -c 'cat >> /etc/hosts <<EOF
   <GATEWAY_IP> litellm.api.example.com
   <GATEWAY_IP> langfuse.api.example.com
   <GATEWAY_IP> vllm-sr.api.example.com
   127.0.0.1 coding-agent-api.example.com
   EOF'
   ```

2. Optional: generate your own certificate instead of using `selfsigned`. OpenSSL 1.1.1 or later is required for `-addext`:

   ```bash
   DOMAIN="api.example.com"
   mkdir -p ~/certs && cd ~/certs && \
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
     -subj "/CN=${DOMAIN}" \
     -addext "subjectAltName = DNS:${DOMAIN}, DNS:litellm.${DOMAIN}, DNS:langfuse.${DOMAIN}, DNS:vllm-sr.${DOMAIN}, DNS:coding-agent-${DOMAIN}"
   ```

   That writes `cert.pem` and `key.pem`. After `init`, set them in `env/local/global_config.yaml`:

   ```yaml
   gateway_tls_mode: custom
   gateway_tls_cert_file: /home/<user>/certs/cert.pem
   gateway_tls_key_file: /home/<user>/certs/key.pem
   ```

If you add more hostnames later, regenerate the cert with extra `DNS:` entries.

## Next steps

When SSH and `/etc/hosts` (or DNS) are in place, continue with the **[single-node quickstart](quickstart.md)** to install and send a chat request.

If this host cannot reach the internet directly, set the proxy keys in [corporate proxy](../deployment/proxy.md) before you run `install`. For more than one server, use [multi-node deployment](../deployment/multi-node.md). [Meet the Agent Toolkit](../overview/meet.md) is the overview of what you are about to install; [Configuration](../configuration/configuration.md) lists every YAML field you can change later. Terms: [glossary](../reference/glossary.md).
