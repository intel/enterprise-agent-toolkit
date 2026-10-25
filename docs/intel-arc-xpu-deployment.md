# Intel® Arc™ (XPU) GPU Deployment Guide

> **Note:** not available with the unified installer in this release.

<!-- Copyright (C) 2025-2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

## Overview

This guide describes how to deploy the Intel® AI for Enterprise Agent Toolkit on nodes
with Intel® discrete GPUs (Arc Battlemage B-series cards such as B60/B70) using the vLLM XPU backend. This is a third compute platform alongside the
existing CPU (Xeon) and GPU (NVIDIA) paths, selected via `compute_platform=xpu`.

## Supported Models

Selectable from the interactive menu (`31`–`36`) or by setting `models=` directly in
`core/inventory/agentic-config.cfg`. `Tensor Parallel` indicates how many GPUs a single
model replica is sharded across.

| Menu # | Model ID | `models=` value | Tensor Parallel |
|--------|----------|------------------|:---:|
| 31 | Qwen/Qwen3-Coder-30B-A3B-Instruct | `xpu-qwen3-coder-30b` | 4 |
| 32 | Qwen/Qwen2.5-Coder-14B-Instruct | `xpu-qwen2-5-coder-14b` | 2 |
| 33 | meta-llama/Llama-3.1-8B-Instruct | `xpu-llama-8b` | 1 |
| 34 | Qwen/Qwen3-Coder-Next | `xpu-qwen3-coder-next` | 4 |
| 35 | google/gemma-4-31B-it *(default)* | `xpu-gemma4-31b` | 4 |
| 36 | Qwen/Qwen3.6-27B | `xpu-qwen36-27b` | 4 |

These map 1:1 to the `modelConfigs` entries in
[`core/helm-charts/vllm/xpu-values.yaml`](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/helm-charts/vllm/xpu-values.yaml), which
holds the per-model vLLM flags, tool-call parser, and tensor-parallel size. Update that file
if you need to change memory utilization, context length, or add a new model.

> **Note:** `compute_platform=g` is a separate path for NVIDIA GPU deployments
> (e.g. `gpu-nvidia-b300-llama-70b`) and is unrelated to the Intel XPU backend described here.

## Prerequisites

Complete the general [prerequisites](./prerequisites.md) first, then the following
XPU-specific items on **every worker node that has an Intel discrete GPU**:

### 1. Hardware

- Intel® Arc™ / Flex / Max discrete GPU (this guide has been exercised on Battlemage B-series
  cards).
- Confirm the render node is visible on the host:
  ```bash
  ls /dev/dri/
  # Expect renderD1xx entries, e.g. renderD128
  ```

### 2. GPU driver and Level Zero runtime

Install the Intel GPU driver/compute runtime for your kernel (Xe or i915) so that
`libze_intel_gpu.so.1` and `libze_loader.so.1` exist under
`/usr/lib/x86_64-linux-gnu/`. The vLLM XPU container image does **not** ship these — the
Helm chart mounts them from the host via `hostPath` volumes (see
`extraVolumes`/`extraVolumeMounts` in `xpu-values.yaml`), so they must already be present
on the node before you deploy.

### 3. Intel GPU Plugin for Kubernetes (automated)

When `compute_platform=xpu`, `fresh-install.sh` automatically runs
`run_deploy_intel_gpu_plugin_playbook` (from `core/lib/components/intel-gpu-plugin.sh`)
right after the cluster configuration playbook and before any model is deployed. It
applies the "base" overlay manifest from
[intel/intel-device-plugins-for-kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes)
— no NFD or node labeling required — and waits for the resulting DaemonSet to roll out:

```
core/playbooks/deploy-intel-gpu-plugin.yml
```

The branch/tag it deploys from defaults to `main` and is controlled by
`intel_gpu_plugin_ref` in `core/inventory/metadata/agentic-metadata.cfg`; pin it to a
specific release tag there for reproducible deployments.

After the run, confirm the resource is advertised on your node:

```bash
kubectl describe node <node-name> | grep -A2 'Allocatable:' | grep gpu.intel.com
```

You should see `gpu.intel.com/xe` (newer Xe kernel driver, e.g. Ubuntu 24.04+/25.10 on
Arc B-series) or `gpu.intel.com/i915` (legacy i915 driver) listed with a count. If it's
missing, re-run manually to see the failure:

```bash
ansible-playbook -i "${INVENTORY_PATH}" --become --become-user=root \
  playbooks/deploy-intel-gpu-plugin.yml --extra-vars "intel_gpu_plugin_ref=main" \
  --vault-password-file "$vault_pass_file"
```

### 4. Driver resource name override (`xe` vs `i915`)

`xpu-values.yaml` defaults to `xpuDeviceResource: "gpu.intel.com/xe"`. If your node plugin
exposes `gpu.intel.com/i915` instead, change it before deploying:

```yaml
# core/helm-charts/vllm/xpu-values.yaml
#xpuDeviceResource: "gpu.intel.com/i915"
xpuDeviceResource: "gpu.intel.com/xe"
```

### 5. Supplemental group IDs

`podSecurityContext.supplementalGroups: [990, 44]` in `xpu-values.yaml` grants the
non-root vLLM container access to `/dev/dri`. These GIDs are host-specific — verify and
adjust them if pods fail with a GPU permission error:

```bash
getent group render video   # e.g. render:x:990 video:x:44
stat -c '%g %G' /dev/dri/renderD128
```

## Configuration (`agentic-config.cfg`)

Set `compute_platform=xpu` (or the short form `x`) and pick a model, either by number or
by name, in `core/inventory/agentic-config.cfg`:

```ini
cluster_url=api.example.com
cert_file=~/certs/cert.pem
key_file=~/certs/key.pem
hugging_face_token=<your_hugging_face_token>
compute_platform=xpu
models=xpu-gemma4-31b          # or a menu number, e.g. models=35
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=off
deploy_llm_models=on
deploy_agenticai_plugin=off
deploy_redis=off
deploy_pgvector=off
deploy_kuberay=off
deploy_agent_sandbox=off
deploy_ceph=off
rack_scale_mode=off
deploy_guardrails=off
deploy_vllm_sr=off
```

If `models=` is left blank and you run the toolkit interactively, `model-selection.sh`
will print the "Available Models for XPU Deployment" menu (31–36) and prompt for a choice.

## Deploying

```bash
# Fresh cluster + XPU model deployment
./es_auto_installer.sh install agent-toolkit

# Add or remove models on an already-deployed cluster
./model-manager deploy <name>     # or: ./model-manager undeploy <name>
```

Internally, `install-model.sh` detects `compute_platform=xpu`, sets `xpu_playbook=true`,
and passes `xpu_values_file=<remote>/vllm/xpu-values.yaml` to the
`playbooks/deploy-inference-models.yml` Ansible run, which then executes
`helm upgrade --install vllm-<model>-xpu ... --values <xpu_values_file>` for the tasks
tagged `install-xpu-<model>`.


## Verifying the Deployment

```bash
# Confirm the release is up
helm list -A | grep xpu

# Watch pod status
kubectl get pods -l app.kubernetes.io/name=vllm | grep xpu

# Test inference through the GenAI Gateway (adjust model name/path per the table above)
curl -k https://${BASE_URL}/v1/completions \
  -X POST \
  -d '{"model": "google/gemma-4-31B-it", "prompt": "What is Deep Learning?", "max_tokens": 50, "temperature": 0}' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN"
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Pod stuck `Pending`, event shows `Insufficient gpu.intel.com/xe` | Intel GPU Plugin not installed, or wrong `xpuDeviceResource` | Install the plugin (see Prerequisites §3) and confirm the resource name matches your driver (§4) |
| `libze_loader.so.1: cannot open shared object file` | Host is missing the Level Zero runtime | Install Intel GPU compute runtime on the node so the libs exist under `/usr/lib/x86_64-linux-gnu/` |
| `CreateContainerConfigError` / permission denied on `/dev/dri` | `supplementalGroups` GIDs don't match the host's `render`/`video` groups | Re-check with `getent group render video` and update `xpu-values.yaml` |
| Config validation fails with `Invalid value for compute_platform` | Older/uninstalled fix — ensure `read-config-file.sh` accepts `xpu`/`x` | Confirm you're on a build where `compute_platform=xpu` is accepted (see `core/lib/system/precheck/read-config-file.sh`) |
| Model deploys but never appears behind the GenAI Gateway | `xpu_playbook`/`xpu_values_file` not passed to Ansible | Confirm `install-model.sh`'s `ansible-playbook --extra-vars` includes `xpu_playbook=true xpu_values_file=...` |

## References

- [Intel GPU Plugin for Kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes)
- [vLLM XPU Backend Documentation](https://docs.vllm.ai/en/latest/getting_started/xpu-installation.html)
- [Intel discrete GPU driver installation guides](https://dgpu-docs.intel.com/driver/client/overview.html)
