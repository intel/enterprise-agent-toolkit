# Install, re-install and teardown failures

Commands run from the Toolkit Manager root (`<root>`). Fixes marked **(changes the cluster)** change the cluster, a host or an env file; **(deletes data)** loses data. Get the user's OK, and explicit confirmation for data loss.

## Read the log first

The newest file in `env/<env>/logs/` is the last run: `<action>-<target>-<timestamp>.log`. One file holds every pass of that run.

```bash
log=$(ls -t env/<env>/logs/*.log | head -1)
sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -n -A4 'PLAY RECAP' | tail -20      # which pass failed
# real errors only: fatal lines not followed by "...ignoring", with the 8 lines after each
sed 's/\x1b\[[0-9;]*m//g' "$log" | awk '{l[NR]=$0} END{for(i=1;i<=NR;i++) if(l[i]~/fatal:/ && l[i+1]!~/ignoring/ && l[i+2]!~/ignoring/) {for(j=i-2;j<=i+8&&j<=NR;j++) if(j>0) print j": "l[j]; print "--"}}' | tail -60
```

- A `fatal:` followed by `...ignoring` is harmless. Kubespray probes things on a fresh install (`etcd --version`, `calicoctl.sh get ...`).
- `FAILED - RETRYING: ... (N retries left)` is polling.
- `the output has been hidden due to the fact that 'no_log: true'` hides secret-handling tasks. Debug them from the pod side (logs, Secret present or not). Never turn `no_log` off.
- `ES_LOG_LEVEL=debug ./es_auto_installer.sh install ...` gives verbose Ansible output.

## Before or at the start of the install

### INS-1 `configure` refuses: `Refusing: stdin is not a terminal and --force was not passed.`
- **Why:** `configure` asks for confirmation and needs a terminal. Some versions also reject `configure --force`.
- **Fix:** the user runs `./es_auto_installer.sh configure` in a real terminal. Check whether the version accepts `--force`: `./es_auto_installer.sh --help | grep -n configure`.

### INS-2 Preflight: `No internet connectivity — cannot reach https://google.com ...`
- **Fix:** set `http_proxy`, `https_proxy` and `no_proxy` in `env/<env>/global_config.yaml` **(changes the cluster)**. `no_proxy` needs `localhost`, `127.0.0.1`, the node IPs and subnet, the cluster service and pod CIDRs (`kubernetes_service_cidr`, `kubernetes_cluster_cidr`), `.<base_domain_name>`, `.svc` and `.cluster.local`. Always write the proxy URL with its port.

### INS-3 Preflight stops on the auth setting: `auth_type must be jwt or litellm_vkey (got '...'); the deprecated auth_provider ('...'), if set, must agree with it.`
- **Why (main track):** `env/<env>/global_config.yaml` still has an `auth_provider:` line from an older environment, and it disagrees with `auth_type` in `config.agent-toolkit.yaml`.
- **Check:** `grep -nE '^(auth_type|auth_provider):' env/<env>/{config.inference,config.agent-toolkit,global_config}.yaml`
- **Fix:** delete the `auth_provider` line from `global_config.yaml` **(changes the cluster)**.

### INS-4 Docker containers and images on the host are gone
- **Why:** Kubespray uninstalls a running Docker and its reset wipes the containerd image store that Docker uses.
- **Check:** `systemctl is-active docker`
- **Fix:** do not install on a host that runs Docker workloads. Otherwise `docker save` what you need and stop Docker first **(changes the cluster)**.

### INS-5 Ports 80 and 443 are already in use on the node
- **Why:** the gateway's LoadBalancer IP is the node IP.
- **Check:** `sudo ss -ltnp '( sport = :80 or sport = :443 )'`
- **Fix:** stop whatever listens there before installing **(changes the cluster)**.

## Kubernetes (Kubespray / kubeadm)

### INS-6 `kubeadm init` times out: `wait-control-plane ... kube-apiserver check failed ... connection refused`
- **Why:** the host has no systemd-resolved. Kubespray tells the kubelet to read `/run/systemd/resolve/resolv.conf`, which does not exist. The kubelet log shows `open /run/systemd/resolve/resolv.conf: no such file or directory`. About 16 minutes are lost before it fails.
- **Check:** `systemctl is-active systemd-resolved; ls /run/systemd/resolve/resolv.conf`
- **Fix:** add these two lines to `env/<env>/kubespray_extra.yml` (create it if missing), then `./es_auto_installer.sh teardown kubernetes --env <env>` and install again **(changes the cluster)**:
  ```yaml
  kube_resolv_conf: "/etc/resolv.conf"
  resolvconf_mode: "none"
  ```
  When only some nodes lack systemd-resolved, also set `upstream_dns_servers`. The toolkit's node readiness playbook writes all of these lines for you (INS-20); on the release track it runs at the start of every install.

### INS-7 Re-run after a failed kubeadm: `secrets is forbidden: User "kubernetes-admin" cannot create resource "secrets" ... "kube-system"`
- **Why:** a half-initialised control plane (`/var/lib/kubelet/config.yaml` exists, but `env/<env>/kubeconfig.yaml` was never written).
- **Fix:** `./es_auto_installer.sh teardown kubernetes --env <env>`, then `install` **(changes the cluster)**.

### INS-8 `etcd : Configure | Ensure etcd is running` fails after an earlier teardown on the same host
- **Check:** `sudo journalctl -u etcd -n 50 --no-pager; ls /var/lib/etcd`
- **Fix:** `teardown kubernetes` again (twice has been needed), then reinstall **(changes the cluster; rebuilds the cluster)**.

### INS-9 `ERROR: kubectl missing. Run './es_auto_installer.sh configure' ...` after a teardown
- **Why:** on SSH or multi-node installs, the Kubespray reset deletes `/usr/local/bin/kubectl` and `helm`.
- **Fix:** the user runs `./es_auto_installer.sh configure` again.

### INS-10 `No such file or directory: b'.../.kubespray/venv/bin/pip3'`
- **Why:** the checkout was moved or renamed; the Kubespray virtualenv is not relocatable.
- **Fix:** move it back. Otherwise remove `.kubespray/venv` and re-run **(changes the cluster)**.

## Platform and inference layers

### INS-11 A changed platform setting has no effect on re-run
- **Why:** Helm-based platform components (cert-manager, Istio, Envoy Gateway, Keycloak, observability, CloudNativePG) are skipped when their release already exists, even a failed one. LiteLLM is skipped too: `LiteLLM already deployed in litellm — skipping install (litellm_reconcile: true upgrades it with the current settings).`
- **Fix:** for LiteLLM, re-run with `-- -e litellm_reconcile=true`. For a platform component, tear that component down and install it again **(changes the cluster; check what depends on it first)**.

### INS-12 The install fails while deploying the default or guard model, and the summary blames `a gated model without HF_TOKEN`
- **Why:** the hint is generic. Look at the model's real error: `grep -n 'Deploy solution-requested default models' -A30 "$log"`. Common causes are memory (INS-13), CPU placement (INS-14) or a gated model (INS-15).

### INS-13 Not enough memory for the default models
- **Why:** the default install requests about 131 GiB: `qwen2-5-coder-14b` 96 GiB, the `qwen3guard` guard model 16 GiB, and about 19 GiB for the rest. A 128 GB node does not fit it.
- **Check:** `kubectl get pods -n llm-inference`; `kubectl describe node | grep -A8 'Allocated resources'`.
- **Fix:** before installing, set `llm_services_autodeploy_models: ["qwen2-5-coder-7b"]` (64 GiB) in `env/<env>/config.agent-toolkit.yaml` **(changes the cluster)**.

### INS-14 `NRI pre-flight failed: not enough physical cores to place <m> ...`
- **Why:** the default model uses `cpu: auto` and takes the free physical cores of one NUMA node. On a small or single-NUMA node, a second model does not fit.
- **Check:** `lscpu | grep -E 'NUMA node\(s\)|Core\(s\)'`
- **Fix:** set an explicit `cpu:` for the models in `env/<env>/models.yaml`, then deploy again **(changes the cluster)**. `MM_NRI_PREFLIGHT=warn` lets a deploy continue anyway.

### INS-15 `Model '<repo>' is gated. Set HF_TOKEN with an authorized token.`
- **Fix:** `export HF_TOKEN=<token>` in the shell that runs `install` or `./model-manager`, then deploy again **(changes the cluster)**. The token must have access to that repository on Hugging Face. Never echo the token.

### INS-16 Langfuse web keeps restarting on NFS storage: `Dirty database version ... Applying clickhouse migrations failed`
- **Why:** the liveness probe (60 s on the main track) kills the first-start migrations on slow storage. The release track raised it to 600 s.
- **Check:** `kubectl get deploy langfuse-web -n langfuse -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}'`
- **Fix:** there is no verified recovery for a database left dirty. Report it, and prefer local storage for first installs on the main track.

## Toolkit layer

Component-level failures (Agent Sandbox, Kata, OpenShell, Redis, pgvector, KubeRay) are in `components.md`.

### INS-17 `init agent-toolkit` fails: `rev '<branch>' does not resolve in ext/enterprise.agent-toolkit`
- **Why:** the toolkit branch pinned in `configs/repos/repos.agent-toolkit.yaml` no longer exists.
- **Check:** `yq '.repos[] | [.layer,.rev]' configs/repos/repos.agent-toolkit.yaml`; `git ls-remote --heads https://github.com/intel/enterprise-agent-toolkit`.
- **Fix:** update the Toolkit Manager checkout (`git pull`) **(changes the cluster)**, or ask its maintainers to fix the pin.

### INS-18 `Layer 'agent-toolkit' was provisioned at '<old>' but repos.agent-toolkit.yaml now pins '<new>'. Re-run with --upgrade...`
- **Fix:** `./es_auto_installer.sh init agent-toolkit --upgrade --env <env>` **(changes the cluster)**. It refuses when `ext/` has local changes, and it reports new config keys but does not add them to your env files.

### INS-19 Re-running `init` prints `WARN: exists, skipping: ...`
- **Why:** env files are seeded once and never overwritten.
- **Fix:** add new keys by hand **(changes the cluster)**. Compare with this repo's `config.yaml` to see what is new.

### INS-20 The node readiness report is missing (main track)
- **Why:** on the main track, `install` does not run the toolkit's node preflight, and `node_preflight_enabled` is not read.
- **Fix:** run it by hand, with the user's OK. It runs with sudo on the nodes (add `-K` if sudo needs a password; then the user runs it), writes a temporary results file in `/tmp` on each node, and may create or edit `env/<env>/kubespray_extra.yml` to fix the kubelet DNS file. It checks only the hosts already in `inventory/hosts.yaml`.
  ```bash
  .venv/bin/ansible-playbook -i env/<env>/inventory/hosts.yaml ext/enterprise.agent-toolkit/playbooks/preflight-check.yml
  ```
  Reports: `env/<env>/logs/health-report-latest.{txt,json,html}`. It checks time sync, the kubelet DNS file, unfinished Kubernetes installs, node connection, swap, disk headroom, gateway reachability and external DNS, and prints a fix hint for each.

## Multi-node and remote installs

### INS-21 Node tasks ran on the installer host instead of the node
- **You see:** Kata failures on workers (`snapshotter devmapper was not found`), `The module interpreter '.../.venv/bin/python3.12' was not found`, or checks that pass suspiciously fast.
- **Why:** a node in `env/<env>/inventory/hosts.yaml` has no `ansible_connection`.
- **Fix:** add `ansible_connection: ssh` to every remote node, and `local` to the installer host **(changes the cluster)**. On the main track, an inventory generated from `nodes.yaml` cannot carry it; write `inventory/hosts.yaml` by hand and leave `nodes_control_plane` in `nodes.yaml` empty.

### INS-22 Preflight `NTP not synced` on a node
- **Fix:** enable chrony or systemd-timesyncd on every node (`timedatectl status`) **(changes the cluster)**.

### INS-23 `init --env <name>` for a remote install seeds a localhost inventory
- **Fix:** write the real nodes into `env/<env>/inventory/hosts.yaml`, each with `ansible_connection: ssh` **(changes the cluster)**.

### INS-24 Adding a node to a running cluster
- Not supported. List every node before the first install.

### INS-25 `fs.inotify.max_user_instances` is 128 on workers
- See KATA-2 in `components.md`. On the main track the installer raises it on the installer host only.

## Teardown and re-install

### INS-26 `Refusing: stdin is not a terminal and --force was not passed.` on teardown
- **Fix:** with the user's explicit OK, add `--force`.

### INS-27 A component that is switched off cannot be torn down
- **Why:** the enable switches filter teardown too. Setting `<component>_enabled: false` and re-running install does not remove anything.
- **Fix:** `./es_auto_installer.sh teardown <component> --env <env> -- -e <component>_enabled=true`, then set the switch to `false` **(changes the cluster)**.

### INS-28 `teardown infrastructure` after a failed install stops at `vllm_sr | List LLMInferenceServices`: `Invalid kube-config file. No configuration found.`
- **Why (only with `vllm_sr_enabled: true`):** the semantic-router teardown needs a working cluster API. The release track guards against this in newer inference revisions; the main track does not.
- **Fix:** add `--skip vllm_sr` to the teardown (untested workaround) **(changes the cluster)**.

### INS-29 After teardown, ports 80 and 443 on the node are dead
- **Why:** kube-proxy's nftables rules survive the reset.
- **Check:** `sudo nft list tables | grep kube-proxy`
- **Fix:** `sudo nft delete table ip kube-proxy; sudo nft delete table ip6 kube-proxy`, or reboot **(changes the cluster)**.

### INS-30 Disk fills up after several install and teardown cycles
- **Why:** local volume data in `/opt/local-path-provisioner` (including downloaded model weights) is kept.
- **Check:** `sudo du -sh /opt/local-path-provisioner`
- **Fix:** after teardown, clear that directory when the data is no longer needed **(deletes data: every local volume and the downloaded model weights)**.

### INS-31 A namespace is still `Terminating` right after `teardown agent-toolkit`
- **Fix:** wait until `kubectl get ns` no longer lists it, then reinstall.

### INS-32 Harmless noise during teardown
- `rmtree failed: [Errno 1] Operation not permitted: 'io.prio.class'` and `plugin type="calico" failed (delete): ... connection refused`.
