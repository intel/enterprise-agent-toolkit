# Intel® Arc™ (GPU)

[← Docs index](../README.md)

This path serves models with the vLLM XPU backend on nodes that have an Intel® discrete GPU (Arc Battlemage B-series, such as B60 or B70, and Arc, Flex, or Max). It sits next to the CPU path. You select it with `compute_platform=xpu`.

## Models

These ids come from the interactive menu (`31`–`36`) or from `models=` in `core/inventory/agentic-config.cfg`. Tensor parallel is how many GPUs one replica is sharded across.

| Menu | Model id | `models=` value | Tensor parallel |
|---|---|---|---|
| 31 | Qwen/Qwen3-Coder-30B-A3B-Instruct | `xpu-qwen3-coder-30b` | 4 |
| 32 | Qwen/Qwen2.5-Coder-14B-Instruct | `xpu-qwen2-5-coder-14b` | 2 |
| 33 | meta-llama/Llama-3.1-8B-Instruct | `xpu-llama-8b` | 1 |
| 34 | Qwen/Qwen3-Coder-Next | `xpu-qwen3-coder-next` | 4 |
| 35 | google/gemma-4-31B-it (default) | `xpu-gemma4-31b` | 4 |
| 36 | Qwen/Qwen3.6-27B | `xpu-qwen36-27b` | 4 |

They match `modelConfigs` in `core/helm-charts/vllm/xpu-values.yaml`, which holds the vLLM flags, the tool-call parser, and the tensor-parallel size. Change memory utilization, context length, or add a model in that file.

## Prerequisites

Finish the [general prerequisites](../getting-started/prerequisites.md) first. Then, on every worker that has an Intel discrete GPU:

### Hardware

Confirm the render node is visible:

```bash
ls /dev/dri/
# renderD1xx entries, for example renderD128
```

### GPU driver and Level Zero

Install the Intel GPU driver and compute runtime for the kernel (Xe or i915) so `libze_intel_gpu.so.1` and `libze_loader.so.1` exist under `/usr/lib/x86_64-linux-gnu/`. The vLLM XPU image does not ship these libraries. The Helm chart mounts them from the host (`extraVolumes` and `extraVolumeMounts` in `xpu-values.yaml`), so they have to be on the node before you deploy.

### Intel GPU plugin

When `compute_platform=xpu`, the install runs `run_deploy_intel_gpu_plugin_playbook` (`core/lib/components/intel-gpu-plugin.sh`) after the cluster configuration playbook and before any model. It applies the base overlay from [intel/intel-device-plugins-for-kubernetes](https://github.com/intel/intel-device-plugins-for-kubernetes). No NFD labels are required. It waits for the DaemonSet:

```text
core/playbooks/deploy-intel-gpu-plugin.yml
```

The branch or tag defaults to `main`. Pin it with `intel_gpu_plugin_ref` in `core/inventory/metadata/agentic-metadata.cfg`.

After the run, the node advertises the resource:

```bash
kubectl describe node <node-name> | grep -A2 'Allocatable:' | grep gpu.intel.com
```

You should see `gpu.intel.com/xe` (Xe kernel driver, for example Ubuntu 24.04 or 25.10 on Arc B-series) or `gpu.intel.com/i915` (legacy i915), with a count. If it is missing, re-run the playbook and read the failure:

```bash
ansible-playbook -i "${INVENTORY_PATH}" --become --become-user=root \
  playbooks/deploy-intel-gpu-plugin.yml --extra-vars "intel_gpu_plugin_ref=main" \
  --vault-password-file "$vault_pass_file"
```

### Driver resource name

`xpu-values.yaml` defaults to `xpuDeviceResource: "gpu.intel.com/xe"`. If the plugin exposes `gpu.intel.com/i915`, change it before deploying:

```yaml
# core/helm-charts/vllm/xpu-values.yaml
xpuDeviceResource: "gpu.intel.com/xe"
# xpuDeviceResource: "gpu.intel.com/i915"
```

### Supplemental groups

`podSecurityContext.supplementalGroups: [990, 44]` in `xpu-values.yaml` lets the non-root vLLM container open `/dev/dri`. Those GIDs are host-specific. Check them when a pod fails with a GPU permission error:

```bash
getent group render video   # for example render:x:990 video:x:44
stat -c '%g %G' /dev/dri/renderD128
```

## Configuration

Set `compute_platform=xpu` (short form `x`) and a model in `core/inventory/agentic-config.cfg`:

```ini
cluster_url=api.example.com
cert_file=~/certs/cert.pem
key_file=~/certs/key.pem
hugging_face_token=<your_hugging_face_token>
compute_platform=xpu
models=xpu-gemma4-31b          # or a menu number, for example models=35
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

If `models=` is empty and you run the toolkit interactively, `model-selection.sh` prints the GPU menu (31–36) and waits for a choice.

The YAML names Toolkit Manager uses for the other flags are in [Configuration](../configuration/configuration.md#if-you-used-the-old-ini-file).

## Deploy

```bash
# Fresh cluster and a GPU model
./toolkit_manager.sh install agent-toolkit

# Add or remove a model on a cluster that is already up
./model-manager deploy <name>
./model-manager undeploy <name>
```

`install-model.sh` sees `compute_platform=xpu`, sets `xpu_playbook=true`, and passes `xpu_values_file=<remote>/vllm/xpu-values.yaml` to `playbooks/deploy-inference-models.yml`. That run executes `helm upgrade --install vllm-<model>-xpu ... --values <xpu_values_file>` for the tasks tagged `install-xpu-<model>`.

## Verify

```bash
helm list -A | grep xpu
kubectl get pods -l app.kubernetes.io/name=vllm | grep xpu

curl -k https://${BASE_URL}/v1/completions \
  -X POST \
  -d '{"model": "google/gemma-4-31B-it", "prompt": "What is Deep Learning?", "max_tokens": 50, "temperature": 0}' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN"
```

Use the model id from the table for the model you deployed. `BASE_URL` is `litellm.<base_domain_name>`.

## Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| Pod stuck `Pending`, event `Insufficient gpu.intel.com/xe` | Intel GPU plugin is missing, or `xpuDeviceResource` does not match the driver | Install the plugin and confirm the resource name (`xe` or `i915`) |
| `libze_loader.so.1: cannot open shared object file` | The host has no Level Zero runtime | Install the Intel GPU compute runtime so the libraries exist under `/usr/lib/x86_64-linux-gnu/` |
| `CreateContainerConfigError` or permission denied on `/dev/dri` | `supplementalGroups` does not match the host `render` and `video` groups | `getent group render video`, then update `xpu-values.yaml` |
| `Invalid value for compute_platform` | Value is not `xpu` / `x` (or another accepted GPU value) | Set `compute_platform=xpu` (or `x`) and re-run the precheck |
| Model deploys and never appears in LiteLLM | `xpu_playbook` or `xpu_values_file` was not passed to Ansible | `install-model.sh` should pass `xpu_playbook=true` and `xpu_values_file=...` as `--extra-vars` |

## Next steps

- [CPU model configuration](../configuration/xeon-models.md): the CPU path next to this one
- [Configuration](../configuration/configuration.md): YAML flags and the old INI mapping
- [Intel GPU plugin](https://github.com/intel/intel-device-plugins-for-kubernetes), [vLLM XPU](https://docs.vllm.ai/en/latest/getting_started/xpu-installation.html), [Intel discrete GPU drivers](https://dgpu-docs.intel.com/driver/client/overview.html)
