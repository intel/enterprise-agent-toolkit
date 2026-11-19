# CPU model configuration

[← Docs index](../README.md)

Each served model has a catalog entry in `env/local/models.yaml`. That file sets the Hugging Face id, CPU request, tensor parallel size, environment, and vLLM arguments. `./model-manager deploy <name>` and `llm_services_autodeploy_models` both read it.

The Helm chart still looks up per-model tuning by Hugging Face id. Every `helm upgrade --install` sets `LLM_MODEL_ID` to that id, for example `Qwen/Qwen3-Coder-30B-A3B-Instruct`. The chart templates use the string as a key in `modelConfigs`:

```yaml
modelConfigs:
  "Qwen/Qwen3-Coder-30B-A3B-Instruct":
    optimal_cpu_cores: 64
    tensor_parallel_size: 4
    pipeline_parallel_size: 1
    configMapValues: { ... }
    extraCmdArgs: [ ... ]
```

- The chart ConfigMap template copies the matched entry's `configMapValues` into the pod.
- The Deployment template uses `extraCmdArgs` as the vLLM CLI arguments, `optimal_cpu_cores` as the CPU request and limit (or `optimal_balloon_config.workload_cpus` from the NRI balloon policy when `optimal_cpu_cores` is absent), and `tensor_parallel_size` / `pipeline_parallel_size` as the parallelism flags.

If `LLM_MODEL_ID` has no matching key, those lookups use `defaultModelConfigs` at the bottom of the values file. That generic entry can miss the tool-call parser or the chat template the model needs. Add a real entry for any model you serve.

## CPU cores and memory

CPU comes from the model's `env/local/models.yaml` entry:

- A number in `cpu` is the CPU request and limit.
- `cpu: auto` asks model-manager, under the NRI balloon policy, for the free physical cores of one NUMA node per tensor-parallel rank, on the smallest node that can schedule the pod.

On a node with one NUMA node, `cpu: auto` on the default model leaves no balloon cores for a second model. `./model-manager deploy` then stops with `NRI pre-flight failed: not enough physical cores`. Set an explicit `cpu:` for the first model, or undeploy it before deploying another.

When you pick `cpu` for a new entry, keep it a multiple of `--tensor-parallel-size` (vLLM shards evenly across ranks) and within one socket. Spanning NUMA nodes crashes CPU inference (`shm.cpp thread_num mismatch`) unless `tensor_parallel_size` is `1`.

Memory on the pod is calculated once per playbook run from `tensor_parallel_size`, and applied to every model in that run. It is separate from `modelConfigs`.

| `tensor_parallel_size` | Memory request | Memory limit |
|---|---|---|
| 1 | 128–200Gi, capped at the limit | 200Gi |
| 2–3 | 128–256Gi, capped at what the socket has and at 256Gi | 400Gi |
| 4 or more | 256Gi | 400Gi |

A `tensor_parallel_size: 1` pod is capped at 200Gi so its memory stays on the NUMA node its cores are pinned to (one such node is about 252 GiB). A larger limit makes NRI widen `cpuset.mems` to neighbouring nodes, and vLLM then fails to bind cores (`core ids=[]`). A model whose weights, KV cache, and overhead exceed 200Gi (about 60B parameters in BF16) is OOM-killed at TP=1. Give it `tensor_parallel_size` 2 or 4. That cap is not applied in this release.

The limit is a kernel cap. If the footprint (weights + `VLLM_CPU_KVCACHE_SPACE` + engine overhead) exceeds it, the pod is OOM-killed even when the node has free RAM. For a new model, especially at `tensor_parallel_size` of 4 or more, compare the footprint with the `memory` value on its `models.yaml` entry (or `--memory` on `./model-manager deploy`) before you treat the deploy as stable.

Approximate footprint, BF16. Base weights are total parameters times 2 bytes. For a mixture-of-experts model use total parameters, because every expert's weights sit in memory. KV cache is `tensor_parallel_size` times `VLLM_CPU_KVCACHE_SPACE`. Runtime and the IPC buffer are a fixed overhead that grows loosely with tensor parallel size.

| Model | TP | Base weights | Speculative draft | KV cache | Runtime / IPC | Approx. total |
|---|---|---|---|---|---|---|
| Llama-3.1-8B-Instruct | 1 | 16.8 GiB | — | 40 GiB (1×40) | 12 GiB | ~69 GiB |
| Llama-3.1-8B-Instruct-Specdec | 2 | 16.8 GiB | 2.6 GiB (1B) | 80 GiB (2×40) | 16 GiB | ~116 GiB |
| Qwen2.5-Coder-14B-Instruct | 4 | 30.8 GiB | — | 160 GiB (4×40) | 22 GiB | ~214 GiB |
| Qwen3-Coder-30B-A3B-Instruct | 4 | 64.0 GiB | — | 240 GiB (4×60) | 24 GiB | ~328 GiB |
| Qwen3-Coder-30B-A3B-Instruct-Specdec | 4 | 64.0 GiB | 1.3 GiB (0.6B) | 240 GiB (4×60) | 26 GiB | ~332 GiB |
| Qwen3-30B-A3B-Instruct-2507 | 4 | 64.0 GiB | — | 240 GiB (4×60) | 24 GiB | ~328 GiB |
| google/gemma-4-26B-A4B-it | 4 | 55.0 GiB | — | 160 GiB (4×40) | 22 GiB | ~238 GiB |
| Qwen3.6-35B-A3B | 4 | 73.5 GiB | — | 200 GiB (4×50) | 26 GiB | ~300 GiB |

These are estimates. Several of them (Qwen3-Coder-30B-A3B, Qwen3-30B-A3B, Qwen3.6-35B-A3B) are already above the 256Gi request the playbook assigns to every `tensor_parallel_size` of 4 or more. They stay up because the 400Gi limit still covers them and Burstable QoS lets the pod use more than its request when the node has it free. Raising that ceiling for a larger model at TP=4 is not available in this release.

A default install of `qwen2-5-coder-14b` plus the guard model, router, and platform requests about 131 GiB. On a 128 GB node, deploy `qwen2-5-coder-7b` or `llama-3-1-8b` instead. See [Choose a model](../getting-started/quickstart.md#3-choose-a-model).

## Add a model

1. Add an entry to `env/local/models.yaml` with a `name` and the exact Hugging Face `model_id`. Keep the `# Benchmarked:` or `# Estimated:` comment the other entries use, including the instance type and how `cpu` and `--tensor-parallel-size` were chosen.

2. Set sizing:

   - `cpu`: cores requested and limited per replica, or `auto` (free physical cores of one NUMA node per tensor-parallel rank).
   - `--tensor-parallel-size` in `args`, or `--tp N` on `./model-manager deploy`. The pre-flight script `validate-cpu-requirements.sh` reads the same value from `model_benchmark_config.yml`. Treat `models.yaml` as the sizing source.

   `tensor_parallel_size` is a ceiling. The playbook selects TP=1, 2, or 4 from the detected NUMA topology. TP=8 is not selected automatically. A mismatch fails with `CreateContainerError: no balloon for annotation`. That automatic selection is not available in this release.

3. `env` is injected into the pod:

   | Key | Meaning |
   |---|---|
   | `VLLM_CPU_KVCACHE_SPACE` | KV-cache size in GB reserved per replica. Raise it for longer contexts or more concurrent requests. That uses memory headroom |
   | `VLLM_CPU_NUM_OF_RESERVED_CPU` | Cores held back from the vLLM workload, for example a draft model under speculative decoding |
   | `VLLM_RPC_TIMEOUT`, `VLLM_ENGINE_ITERATION_TIMEOUT_S` | Internal vLLM timeouts. Leave the defaults the other entries use |
   | `VLLM_ALLOW_LONG_MAX_MODEL_LEN` | Lets `--max-model-len` exceed the model's trained context |
   | `HF_HUB_DISABLE_XET`, `TRITON_CACHE_DIR`, `USER` | Copy these from an existing entry |
   | `HF_HOME` | Set this for a large model whose weights should persist on the PVC (`/data`) rather than the ephemeral `/tmp` emptyDir. See the `Qwen/Qwen3.6-35B-A3B` entry |

4. `args` are the vLLM CLI flags. The ones that change per model:

   - `--tool-call-parser` matches the family: `llama3_json` (Llama 3.x), `hermes` (Qwen3, other than the coder), `qwen3_xml` (Qwen3-Coder and Qwen2.5-Coder), `gemma4`.
   - `--chat-template` (`chat_template_file` on the entry) is needed when the model does not ship a template that already produces the tool-call format its parser expects. Templates live in `ext/enterprise.ai-inference/model_manager/chat-templates/`. Add a `.jinja` file there when the model needs one.
   - `--trust-remote-code` is required for some architectures. The Qwen3-Coder-30B and Qwen3.6-35B entries set it.

5. Optional `draft_model_id`: the draft model's Hugging Face repo, fetched to `/mnt/models/draft`, plus `args` in dot notation:

   ```text
   "--speculative-config.method", "draft_model",
   "--speculative-config.model", "/mnt/models/draft",
   "--speculative-config.num_speculative_tokens", "N"
   ```

   Speculative decoding is its own catalog name (for example `qwen3-coder-30b-specdec`). The base entry stays deployed without it.

6. Deploy it. From the Toolkit Manager checkout:

   ```bash
   ./model-manager deploy <name>
   ```

   Or list the name in `llm_services_autodeploy_models` in `env/local/config.agent-toolkit.yaml` and run `./toolkit_manager.sh install agent-toolkit`. `./model-manager undeploy <name>` removes it.

## Next steps

- [Choose a model](../getting-started/quickstart.md#3-choose-a-model): catalog names for the default install
- [Configuration](configuration.md): where `models.yaml` sits next to the other env files
- [Guardrails](guardrails.md): the `qwen3guard` catalog entry
- Sizing references: [Intel AI Performance Advisor for cloud instances](https://xeonprocessoradvisor.intel.com/csp-ai-performance-advisor) and [for on-prem servers](https://xeonprocessoradvisor.intel.com/on-prem-ai-performance-advisor)
