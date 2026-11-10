---
name: agent-toolkit-install
description: Plan, install, verify, update or remove Intel Agent Toolkit through Toolkit Manager (enterprise-ai-solutions, es_auto_installer.sh). Checks host prerequisites first (memory for the default models, AMX CPU, proxy, DNS resolver, Docker, ports, Hugging Face token, Kata needs), then walks configure, init agent-toolkit, environment settings, install, validate and client access, and explains what each teardown target deletes. Use for a first install, a reinstall, adding nodes or components, moving to a new version, or tearing the toolkit or the cluster down.
---

# Install Intel Agent Toolkit

Intel Agent Toolkit is not installed from this repository. Toolkit Manager (`intel/enterprise-ai-solutions`) clones it into `ext/enterprise.agent-toolkit/` and installs it with the layers below it. All commands run from the Toolkit Manager root. See `AGENTS.md` to find the root, the environment and the track.

Ask before running anything that changes the host or cluster. Steps that need a terminal or a sudo password are the user's to run.

## 1. Check prerequisites

Go through `references/prerequisites.md` and report every row that fails before going on. The usual blockers:
- **Memory.** The default install requests about 131 GiB. On 128 GB, change the default model first (step 4).
- **Docker on the host.** Kubespray removes it and its images.
- **Proxy.** Without `http_proxy`, `https_proxy` and `no_proxy` in `global_config.yaml`, preflight stops with `No internet connectivity`.
- **No systemd-resolved.** `kubeadm init` then times out unless `kubespray_extra.yml` is set (steps 4 and 5).

## 2. Get Toolkit Manager

```bash
git clone https://github.com/intel/enterprise-ai-solutions.git && cd enterprise-ai-solutions
```

This is the main track. For the release track use `git clone -b release-1.2 ...`. The toolkit and inference branches that `init` will clone are pinned in `configs/repos/repos.agent-toolkit.yaml`: `yq '.repos[] | [.layer,.rev]' configs/repos/repos.agent-toolkit.yaml`.

## 3. Prepare the host (user runs this)

```bash
./es_auto_installer.sh configure
```

It installs Python, yq, kubectl and helm and builds `.venv`. It asks for confirmation and needs a terminal; the user runs it. An existing kubectl or helm is kept whatever its version (warning only).

## 4. Create the environment and set it up

```bash
./es_auto_installer.sh init agent-toolkit            # add --env <name> for anything other than "local"
```

This clones the inference and toolkit repos into `ext/` and seeds `env/<env>/`. Then edit:
- `env/<env>/global_config.yaml`: `base_domain_name` (default `solutions.ai`), the proxy settings, `gateway_tls_mode`, `storage_backend`, and Kata (`kata_containers_enabled`, `kata_runtime`).
- `env/<env>/config.agent-toolkit.yaml`: components (`openshell_enabled`, `kuberay_enabled`, ...) and `llm_services_autodeploy_models`. For 128 GB set `["qwen2-5-coder-7b"]`.
- Only without systemd-resolved: `env/<env>/kubespray_extra.yml` needs `kube_resolv_conf: "/etc/resolv.conf"` and `resolvconf_mode: "none"`, plus `upstream_dns_servers` when only some nodes lack systemd-resolved. The readiness report in step 5 writes these lines for you.
- Multi-node or remote: write `env/<env>/inventory/hosts.yaml` by hand in Kubespray format. Give every remote node `ansible_connection: ssh` and the installer host `ansible_connection: local`, and leave `nodes_control_plane` in `nodes.yaml` empty. The inventory generated from `nodes.yaml` has no `ansible_connection` on the main track, so node tasks would run on the installer host. Adding nodes after install is not supported.
- Export `HF_TOKEN` if any model is gated.

The agent-toolkit-configuration skill explains every key.

## 5. Check the nodes (main track)

On the main track `install` does not run the toolkit's node readiness report, so run it first (ask the user):

```bash
.venv/bin/ansible-playbook -i env/<env>/inventory/hosts.yaml ext/enterprise.agent-toolkit/playbooks/preflight-check.yml   # add -K if sudo needs a password
```

- It does not change the node configuration (it writes only a temporary results file in `/tmp`) and does not stop on failures. It runs with sudo and writes its reports to `env/<env>/logs/health-report-latest.{txt,json,html}`.
- It may create or edit `env/<env>/kubespray_extra.yml` to fix the kubelet DNS file.
- It checks the hosts in `inventory/hosts.yaml`. Before the first install that is only the installer host, unless you wrote the inventory by hand (step 4).

Fix every FAIL using its hint. On the release track this report runs at the start of `install`.

## 6. Install

```bash
./es_auto_installer.sh install agent-toolkit --env <env>
```

- It installs infrastructure (Kubernetes, storage), platform, inference (LiteLLM, the guard model and the default model) and the toolkit. Validation runs on a fresh single node took 41-57 minutes.
- Progress and errors go to `env/<env>/logs/install-agent-toolkit-<timestamp>.log`.
- If it fails, use the agent-toolkit-troubleshoot skill, fix the cause, and run the same command again. Re-running resumes.

## 7. Verify and connect

```bash
export KUBECONFIG=$PWD/env/<env>/kubeconfig.yaml
./es_auto_installer.sh validate agent-toolkit --env <env>
```

- The install waits for the guard and default models. If a wait timed out (a `did not become Ready` warning in the log), the model may still be loading; check `kubectl get llminferenceservices -n llm-inference` and validate again once it is Ready.
- For client access (hosts entries, the CA in `env/<env>/logs/ai-solutions-ca.crt`, the LiteLLM UI), see `references/lifecycle.md` "After install".
- For agent code, use the agent-toolkit-components skill.

## Update, remove, start over

`references/lifecycle.md` has:
- every command
- the timings
- what each teardown target deletes and keeps
- how to move to new toolkit or inference revisions (`init --upgrade`)

Warn the user before:
- `teardown agent-toolkit` or a toolkit component, which deletes that component's data and credentials
- `teardown inference`, which also removes the toolkit, LiteLLM and its master key
- `teardown platform`, which deletes every database, including LiteLLM keys and spend
- `teardown kubernetes` or `teardown infrastructure`, which delete the whole cluster
