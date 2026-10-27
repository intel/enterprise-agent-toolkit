# Xeon (CPU) vLLM Model Configuration

This guide covers the `modelConfigs` structure in
[`core/helm-charts/vllm/xeon-values.yaml`](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/helm-charts/vllm/xeon-values.yaml) — how
per-model tuning is defined for CPU/Xeon deployments, and how to add a new model to it.

## How the lookup works

Every `helm upgrade --install` sets `LLM_MODEL_ID` to the exact Hugging Face model ID
(e.g. `--set LLM_MODEL_ID="Qwen/Qwen3-Coder-30B-A3B-Instruct"`). The chart templates use
that string as a key into the `modelConfigs` map:

```yaml
modelConfigs:
  "Qwen/Qwen3-Coder-30B-A3B-Instruct":
    optimal_cpu_cores: 64
    tensor_parallel_size: 4
    pipeline_parallel_size: 1
    configMapValues: { ... }
    extraCmdArgs: [ ... ]
```

- **[`configmap.yaml`](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/helm-charts/vllm/templates/configmap.yaml)** copies the
  matched entry's `configMapValues` into the pod's ConfigMap (env vars).
- **[`deployment.yaml`](https://github.com/intel/enterprise-agent-toolkit/blob/release-1.1.0/core/helm-charts/vllm/templates/deployment.yaml)** uses
  `extraCmdArgs` for the vLLM CLI args, `optimal_cpu_cores` as the CPU request/limit
  (or falls back to `optimal_balloon_config.workload_cpus` from the NRI balloon policy if
  not defined), and `tensor_parallel_size`/`pipeline_parallel_size` for the parallelism flags.

If `LLM_MODEL_ID` has **no matching key** in `modelConfigs`, every one of those lookups
silently falls through to **`defaultModelConfigs`** (bottom of the file) instead — a
generic, untuned config. This is a safety net, not a substitute for adding a real entry:
an unmatched model gets generic `VLLM_CPU_KVCACHE_SPACE`/CPU sizing/CLI args that may be
wrong for its architecture (missing tool-call parser, wrong chat template, etc).

## CPU cores and memory limits (avoiding OOM)

**CPU core allocation:**
- **If `cpu` is a number** in the model's `env/<name>/models.yaml` entry → use that value as the CPU request/limit
- **If `cpu: auto`** → under the NRI balloon policy, model-manager takes the free physical cores of one NUMA node per TP rank on the smallest schedulable node and uses that instead

This lets smaller models (like Llama-8B with `tp=1`) use a full NUMA node's worth of cores instead of a hardcoded minimum.

On a node with a single NUMA node (for example one 36-core socket), `cpu: auto` on the default model leaves no balloon cores for further models, and `model-manager deploy` stops with `NRI pre-flight failed: not enough physical cores`. To deploy more models there, set an explicit `cpu:` for the default model in `env/<name>/models.yaml`.

When picking `cpu` for a new entry, keep it a multiple of
`--tensor-parallel-size` (vLLM shards evenly across TP ranks) and within a single socket's
core count — spanning multiple NUMA nodes is unsupported for CPU deployments and can crash
(`shm.cpp thread_num mismatch`) unless `tensor_parallel_size` is explicitly forced to `1`.

Memory (`resources.requests.memory` / `resources.limits.memory` on the pod) is **not**
derived from anything in `modelConfigs` — it's calculated once per playbook run in
`deploy-inference-models.yml`, based on `tensor_parallel_size` alone, and applied to every
model deployed in that run:

| `tensor_parallel_size` | Memory **request** | Memory **limit** |
|---|---|---|
| 1 | 128–200Gi (capped at the limit) | fixed at 200Gi |
| 2–3 | 128–256Gi (whatever the detected socket has, capped at 256Gi) | fixed at 400Gi |
| ≥ 4 | fixed at 256Gi, regardless of actual socket size | fixed at 400Gi |

> **TP=1 limit:** a `tensor_parallel_size: 1` pod is capped at 200Gi so its memory stays on
> the single NUMA node its cores are pinned to (one node has about 252 GiB). A larger limit
> makes NRI widen `cpuset.mems` to neighbouring nodes, and vLLM then fails to bind cores
> (`core ids=[]`). A model whose weights + KV cache + overhead exceed 200Gi (roughly 60B+
> parameters in BF16) is OOM-killed at TP=1, so give it a higher `tensor_parallel_size`
> (2 or 4).

> **Note:** not available in this release.

The limit is a hard cap enforced by the kernel — if a model's real footprint (weights +
`VLLM_CPU_KVCACHE_SPACE` + engine overhead) exceeds it, the pod gets OOM-killed no matter
how much physical memory the node has. When adding a new model — especially a large one at
`tensor_parallel_size >= 4` — check that its expected footprint fits under its `memory`
value before assuming the deployment will be stable; a model that needs more gets a larger
`memory` on its `env/<name>/models.yaml` entry (or `--memory` on `./model-manager deploy`).

**Approximate footprint per model** (BF16 weights, `Base weights = total params × 2 bytes`
— use *total* params for MoE models, not active params, since every expert's weights sit
in memory regardless; `KV cache = tensor_parallel_size × VLLM_CPU_KVCACHE_SPACE`; runtime
+ IPC buffer is a rough fixed overhead that scales loosely with TP):

| Model | TP | Base weights | Spec draft | KV cache | Runtime/IPC buffer | Approx. total |
|---|---|---|---|---|---|---|
| Llama-3.1-8B-Instruct | 1 | 16.8 GiB | — | 40 GiB (1×40) | 12 GiB | ~69 GiB |
| Llama-3.1-8B-Instruct-Specdec | 2 | 16.8 GiB | 2.6 GiB (1B) | 80 GiB (2×40) | 16 GiB | ~116 GiB |
| Qwen2.5-Coder-14B-Instruct | 4 | 30.8 GiB | — | 160 GiB (4×40) | 22 GiB | ~214 GiB |
| Qwen3-Coder-30B-A3B-Instruct | 4 | 64.0 GiB | — | 240 GiB (4×60) | 24 GiB | ~328 GiB |
| Qwen3-Coder-30B-A3B-Instruct-Specdec | 4 | 64.0 GiB | 1.3 GiB (0.6B) | 240 GiB (4×60) | 26 GiB | ~332 GiB |
| Qwen3-30B-A3B-Instruct-2507 | 4 | 64.0 GiB | — | 240 GiB (4×60) | 24 GiB | ~328 GiB |
| google/gemma-4-26B-A4B-it | 4 | 55.0 GiB | — | 160 GiB (4×40) | 22 GiB | ~238 GiB |
| Qwen3.6-35B-A3B | 4 | 73.5 GiB | — | 200 GiB (4×50) | 26 GiB | ~300 GiB |

These are estimates, not guarantees — but note that several of them (Qwen3-Coder-30B-A3B,
Qwen3-30B-A3B, Qwen3.6-35B-A3B) already exceed the **256Gi** fixed request the playbook
gives every `tensor_parallel_size >= 4` model today; they only stay stable because the
**400Gi** limit still covers them and Burstable QoS lets the pod use more than its request
when the node has it free. There's no margin left for anything bigger at TP=4 without
raising that ceiling.

> **Note:** not available in this release.

## Adding a new model

1. **Add an entry to `env/<name>/models.yaml`** with a `name` and the exact Hugging Face `model_id`. Keep the
   `# Benchmarked: ...` or `# Estimated: ...` comment convention already used by the other
   entries, noting the instance type and how `cpu`/`--tensor-parallel-size`
   were derived.

2. **Sizing fields:**
   - `cpu` — CPU cores requested/limited per replica, or `auto`: the free physical cores of
     one NUMA node per TP rank, based on detected NUMA topology. See
     [CPU cores and memory limits](#cpu-cores-and-memory-limits-avoiding-oom) for details.
   - `--tensor-parallel-size` in `args` (or `--tp N` on `./model-manager deploy`) — vLLM
     parallelism. These are also
     read by the Ansible pre-flight validator (`validate-cpu-requirements.sh`, via a
     mirrored `model_benchmark_config.yml`), so treat this file as the source of truth for
     sizing, not just the Helm chart.

     > **Note:** `tensor_parallel_size` is a ceiling — the playbook auto-selects TP=1, 2,
     > or 4 based on detected NUMA topology (TP=8 isn't auto-selected today, even on
     > hardware that could back it). A mismatch fails with `CreateContainerError: no
     > balloon for annotation`.

     > **Note:** not available in this release.

3. **`env`** — environment variables injected into the pod. Common knobs:
   | Key | Meaning |
   |---|---|
   | `VLLM_CPU_KVCACHE_SPACE` | KV-cache size in GB reserved per replica — raise for longer contexts/more concurrent requests, at the cost of memory headroom |
   | `VLLM_CPU_NUM_OF_RESERVED_CPU` | Cores held back from the vLLM workload (e.g. for a draft model under speculative decoding) |
   | `VLLM_RPC_TIMEOUT`, `VLLM_ENGINE_ITERATION_TIMEOUT_S` | Internal vLLM timeouts, generally left at the defaults used by every other entry |
   | `VLLM_ALLOW_LONG_MAX_MODEL_LEN` | Lets `--max-model-len` exceed the model's default trained context |
   | `HF_HUB_DISABLE_XET`, `TRITON_CACHE_DIR`, `USER` | Boilerplate — copy as-is unless you know you need to change them |
   | `HF_HOME` | Only set for large models where weights should persist on the PVC (`/data`) rather than the ephemeral `/tmp` emptyDir — see the `Qwen/Qwen3.6-35B-A3B` entry for why |

4. **`args`** — the vLLM CLI flags. The most model-specific ones:
   - `--tool-call-parser` must match the model family: `llama3_json` (Llama-3.x),
     `hermes` (Qwen3 non-coder), `qwen3_xml` (Qwen3-Coder / Qwen2.5-Coder), `gemma4`.
   - `chat_template_file` (vLLM `--chat-template`) — only needed if the model doesn't ship a template that already
     produces the tool-call format its parser expects. Templates live in
     `ext/enterprise.ai-inference/model_manager/chat-templates/`; add a new `.jinja` there if the model
     needs one.
   - `--trust-remote-code` — required for some custom model architectures (see the
     Qwen3-Coder-30B and Qwen3.6-35B entries).

5. **`draft_model_id`** (optional) — the draft model's Hugging Face repo, fetched to
   `/mnt/models/draft`, plus `args` in dot notation:
   `"--speculative-config.method", "draft_model", "--speculative-config.model", "/mnt/models/draft", "--speculative-config.num_speculative_tokens", "N"`.
   Speculative decoding is a separate catalog entry (e.g. `qwen3-coder-30b-specdec`), so the
   base entry stays deployed without speculative decoding.

6. **Wire it into the deploy tooling.** The catalog entry is deployable end-to-end as is:
   `./model-manager deploy <name>` from the `enterprise-ai-solutions` checkout (or list it in
   `llm_services_autodeploy_models` in `config.agent-toolkit.yaml` to deploy it on install);
   `./model-manager undeploy <name>` removes it.
