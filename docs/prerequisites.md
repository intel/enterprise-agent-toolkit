# Prerequisites — Intel® AI for Enterprise Agent Toolkit

## Hardware

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 48 cores | 96+ cores |
| RAM | 32 GB | 64 GB |
| Disk | 150 GB  | 200 GB  |
| OS | Ubuntu 22.04 / 24.04 | Ubuntu 22.04 LTS |
| Architecture | x86_64 | x86_64 |

> **Note:** For tp1, tp2 system should have minimum 128Gi and for tp>=4 minimum 256Gi memory available for the model's pod.

## Access

- A [Hugging Face](https://huggingface.co) account with an API token that has **read** access to gated models.
- `sudo` privileges on the deployment node.
- Internet access from the node to pull Helm charts and container images.

## Node Kernel Settings

`fs.inotify.max_user_instances` is a per-UID limit shared by every container
running as that UID. The kernel default of 128 is exhausted on nodes running
many pods, after which file watchers fail with `too many open files` (e.g. the
vLLM-SR router loses config hot-reload). Raise it on every node:

```bash
sudo tee /etc/sysctl.d/90-inotify.conf > /dev/null <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
EOF
sudo sysctl --system
```

## SSH Key Setup

Log in as a non-root user with `sudo` privileges. Using `root` or a password-based account may cause unexpected behavior during deployment.

1. **Generate an SSH key pair** (or use an existing one):

   ```bash
   ssh-keygen -t rsa -b 4096
   ```

   Leave the password blank when prompted.

2. **Copy the public key** (`id_rsa.pub`) to every control plane and workload node that will be part of the cluster.

3. **Add the public key** to `~/.ssh/authorized_keys` on each node:

   ```bash
   echo "<PUBLIC_KEY_CONTENTS>" >> ~/.ssh/authorized_keys
   ```

4. **Verify SSH access** from the Ansible control machine to each node:

   ```bash
   chmod 600 <path_to_PRIVATE_KEY>
   ssh -i <path_to_PRIVATE_KEY> <USERNAME>@<IP_ADDRESS>
   ```

   If a bastion host is used, ensure the Ansible control machine can reach the cluster nodes through it.

5. **Configure the Ansible inventory** (`env/<name>/inventory/hosts.yaml`) with your node IPs and SSH user. Example templates are provided for both deployment topologies:

   | Topology | Example inventory |
   |---|---|
   | Single node (all-in-one) | [examples/single-node/hosts.yaml](examples/single-node/hosts.yaml) |
   | Multi-node (3 control-plane + N workers) | [examples/multi-node/hosts.yaml](examples/multi-node/hosts.yaml) |

   Copy the appropriate template to `env/<name>/inventory/hosts.yaml` and replace `ansible_user`, `ansible_host`, and `ansible_ssh_private_key_file` with your actual values.

## DNS and SSL/TLS Setup

### Production Environment

- Use a registered domain name with DNS records pointing to your server or load balancer.
- Obtain an SSL/TLS certificate from a trusted Certificate Authority (CA) and install it on your system.
- The certificate must cover the base domain **and all use-case subdomains**. For a `base_domain_name` of `api.example.com` the following FQDNs need to be covered:

  | FQDN | Purpose |
  |---|---|
  | `litellm.api.example.com` | GenAI Gateway (LiteLLM) |
  | `langfuse.api.example.com` | Langfuse trace UI |
  | `coding-agent-api.example.com` | Coding Agent UI. **Note:** not available in this release. |
  | `vllm-sr.api.example.com` | vLLM Semantic Router dashboard |


  Request a **multi-SAN** or **wildcard** (`*.api.example.com`) certificate from your CA that includes all of the above.
- Set up automatic renewal or calendar reminders before certificates expire.
- Ensure required firewall ports (e.g., port 80 for HTTP validation) are open during certificate issuance.

### Development Environment

For local testing, `litellm.api.example.com` can be mapped to the gateway IP.

1. **Add entries to `/etc/hosts`** for every subdomain the stack uses:

   ```bash
   # Get the private IP of the machine
   hostname -I

   # Add all stack subdomains to /etc/hosts (replace <GATEWAY_IP> with the gateway IP)
   # Replace api.example.com with your actual base_domain_name
   sudo bash -c 'cat >> /etc/hosts <<EOF
   <GATEWAY_IP> litellm.api.example.com
   <GATEWAY_IP> langfuse.api.example.com
   127.0.0.1 coding-agent-api.example.com
   <GATEWAY_IP> vllm-sr.api.example.com
   EOF'
   ```

   The subdomains follow this pattern for a `base_domain_name` of `api.example.com`:

   | Host entry | Service |
   |---|---|
   | `litellm.api.example.com` | GenAI Gateway (LiteLLM) |
   | `langfuse.api.example.com` | Langfuse trace UI |
   | `coding-agent-api.example.com` | Coding Agent UI. **Note:** not available in this release. |
   | `vllm-sr.api.example.com` | vLLM Semantic Router dashboard |


2. **Generate a self-signed SSL certificate** covering all subdomains:

   ```bash
   # Replace api.example.com with your actual base_domain_name
   DOMAIN="api.example.com"

   mkdir -p ~/certs && cd ~/certs && \
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes \
     -subj "/CN=${DOMAIN}" \
     -addext "subjectAltName = DNS:${DOMAIN}, DNS:litellm.${DOMAIN}, DNS:langfuse.${DOMAIN}, DNS:coding-agent-${DOMAIN}, DNS:vllm-sr.${DOMAIN}"
   ```

   > **Note:** The `-addext` option requires OpenSSL ≥ 1.1.1. If you add more use cases later, regenerate the cert with the additional `DNS:` entries.

   Files generated:
   - `cert.pem` — the self-signed certificate (contains SANs for all subdomains)
   - `key.pem` — the private key
