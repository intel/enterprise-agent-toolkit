# Agentic AI Stack — Docker Compose Deployment

A complete Docker Compose solution for the Agentic AI Stack that mirrors the Kubernetes deployment without requiring a cluster. All components run as containers with ports exposed directly to the host.

---

## Prerequisites

| Requirement | Minimum |
|---|---|
| Docker Engine | 24.0+ |
| Docker Compose | v2.20+ |
| RAM | 128 GB |
| Disk | 80 GB free |
| CPU | 96+ cores |
| HuggingFace token | Required |

---

## Quick Start

**Step 1:** Edit `docker/config.cfg`:

```ini
hugging_face_token=hf_your_token_here
serving_engine=vllm            # vllm (default) or openvino
models=Qwen/Qwen2.5-Coder-14B-Instruct
```

**Step 2:** Deploy from repository root:

```bash
./deploy-agentic-stack.sh --platform=docker
```

---

### Configuration

Edit `docker/config.cfg` with **comma-separated** HuggingFace model IDs (no spaces around commas):

```ini
# Single model
models=Qwen/Qwen2.5-Coder-14B-Instruct

# Multiple models (comma-separated, no spaces)
models=Qwen/Qwen2.5-Coder-14B-Instruct,meta-llama/Llama-3.1-8B-Instruct
```

Then deploy:

```bash
./deploy-agentic-stack.sh --platform=docker
```

> **Note:** Any model container that is already running and unchanged will **not** be restarted. Only new models added to the list will be created.

### Model Serving Engine

`serving_engine` in `docker/config.cfg` selects the runtime that serves the models in `models=`. The rest of the stack (LiteLLM, Flowise, Postgres, Redis, Langfuse) is identical either way, and applications always talk to LiteLLM on port 4000 — so switching engines does not change any client code.

```ini
serving_engine=vllm       # default
# serving_engine=openvino
```

| | `vllm` | `openvino` |
|---|---|---|
| Image | `vllm/vllm-openai-cpu:v0.24.0` | `openvino/model_server:2025.4.1` (+ `-py` for runtime conversion) |
| Model config library | `docker/model-configs.yaml` | `docker/ovms-model-configs.yaml` |
| Generated compose file | `docker/docker-compose.vllm.yml` | `docker/docker-compose.ovms.yml` |
| Containers | `agentic-vllm-<served_name>` | `agentic-ovms-<served_name>` |
| Model API path | `/v1` | `/v3` |
| Health endpoint | `/health` | `/v2/health/ready` |
| Speech-to-text (`openai/whisper-small`) | supported | **not supported** (no such task in OVMS 2025.4) |

Switching the engine and redeploying is safe: the generator deletes the other engine's compose file and `deploy.sh` force-removes its leftover model containers so the model ports are freed. Model caches live in named volumes and are **not** deleted, so switching back does not re-download anything.

#### OpenVINO specifics

* **Pre-converted models start fast.** Model IDs under the `OpenVINO/` organization (e.g. `OpenVINO/Qwen3-8B-int4-ov`) are already in OpenVINO IR format — OVMS downloads and serves them directly, in minutes and on a fraction of the memory. Check that the repo actually exists before using it: the org mirrors permissively-licensed models only, so there are **no `OpenVINO/Llama-3.x-*-ov` repos**. For gated families like Llama, use the upstream `meta-llama/...` ID and let OVMS convert it.
* **Everything else is converted on first start.** Any other HuggingFace checkpoint is exported and quantized with `optimum-cli` inside the container. That can take **30+ minutes** and temporarily needs roughly the memory of the original fp16 checkpoint, which is why memory limits in `ovms-model-configs.yaml` stay high even for `int4` output. Converted weights are cached in the per-model Docker volume, so later starts only load the model. The container healthcheck allows a 30-minute grace period for this.
* **Tool calling** covers the `llama3`, `hermes3`, and `phi4` templates in OVMS 2025.4. Models without a matching parser still serve chat completions, just without automatic `tool_calls` extraction. (The `tool_call_parser` setting in `config.cfg` applies to vLLM only.)

```bash
# Fastest OpenVINO path: pre-converted IR weights, no runtime conversion
serving_engine=openvino
models=OpenVINO/Qwen3-8B-int4-ov
```

### Accessing Models

All models are accessible via LiteLLM Gateway at `http://localhost:4000/ui`

```bash
# List models
export LITELLM_MASTER_KEY=$(grep LITELLM_MASTER_KEY docker/.env | cut -d= -f2 | tr -d '"')
curl http://localhost:4000/v1/models -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"

# Call a model (use full HuggingFace ID)
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen2.5-Coder-14B-Instruct", "messages": [{"role": "user", "content": "Hello"}]}'
```

### Supported Models

The following models have optimized configurations in `docker/model-configs.yaml` (vLLM):

| Model | Type |
|-------|------|
| `Qwen/Qwen2.5-Coder-14B-Instruct` | LLM |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | LLM |
| `meta-llama/Llama-3.1-8B-Instruct` | LLM |
| `google/gemma-4-26B-A4B-it` | LLM |
| `Qwen/Qwen3.6-35B-A3B` | LLM |
| `BAAI/bge-base-en-v1.5` | Embedding |
| `BAAI/bge-reranker-base` | Reranker |

**Note:** You can deploy any HuggingFace model, but the vLLM image may not support all models. Models not listed above use default configuration (see `docker/model-configs.yaml`). Verify model compatibility with vLLM before deployment.

With `serving_engine=openvino`, tuned configurations live in `docker/ovms-model-configs.yaml`:

| Model | Task | Notes |
|-------|------|-------|
| `OpenVINO/TinyLlama-1.1B-Chat-v1.0-int4-ov` | text_generation | Pre-converted IR — smallest, best smoke test |
| `OpenVINO/Qwen2.5-1.5B-Instruct-int4-ov` | text_generation | Pre-converted IR — fast start |
| `OpenVINO/Qwen3-1.7B-int4-ov` | text_generation | Pre-converted IR — fast start |
| `OpenVINO/Qwen3-8B-int4-ov` | text_generation | Pre-converted IR — fastest start at 8B |
| `meta-llama/Llama-3.2-1B-Instruct` | text_generation | int4, `llama3` tool parser |
| `Qwen/Qwen2.5-Coder-14B-Instruct` | text_generation | int4, `hermes3` tool parser |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | text_generation | int4, `hermes3` tool parser |
| `Qwen/Qwen3-30B-A3B-Instruct-2507` | text_generation | int4, `hermes3` tool parser |
| `meta-llama/Llama-3.1-8B-Instruct` | text_generation | int4, `llama3` tool parser |
| `meta-llama/Llama-3.2-3B-Instruct` | text_generation | int4, `llama3` tool parser |
| `google/gemma-4-26B-A4B-it` | text_generation | int4 |
| `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` | text_generation | int4 |
| `deepseek-ai/DeepSeek-R1-Distill-Llama-8B` | text_generation | int4 |
| `Qwen/Qwen3-1.7B`, `Qwen/Qwen3-4B-Instruct-2507` | text_generation | int4 |
| `nvidia/Llama-3.1-Nemotron-Nano-4B-v1.1` | text_generation | int4, `llama3` tool parser |
| `BAAI/bge-base-en-v1.5` | embeddings | int8 |
| `BAAI/bge-reranker-base` | rerank | int8 |

The `-Specdec` suffixed entries (e.g. `Qwen/Qwen2.5-Coder-14B-Instruct-Specdec`) serve the same base model with a small draft model for speculative decoding. Unlisted models fall back to the `default:` block (text_generation, int8).

### Resource Requirements

| Models | Total Memory |
|--------|--------------|
| 1      | 128GB        |
| 2+     | 256GB        |


### Troubleshooting Multi-Model Deployments

| Issue | Solution |
|-------|----------|
| Memory limit exceeded | Reduce model count in `config.cfg` or upgrade RAM |
| Invalid model ID format | Use `org/model-name` format (e.g., `Qwen/Qwen2.5-Coder-14B-Instruct`) |
| Model fails to start | Check logs: `docker logs agentic-vllm-<name>` (or `agentic-ovms-<name>`) |
| Model not found in LiteLLM | Verify `docker/litellm/config.yaml` has correct model ID |
| Generator script fails | Install `yq`: `yq --version`, validate YAML: `yq eval '.' docker/model-configs.yaml` (or `docker/ovms-model-configs.yaml`) |
| Port binding error | Check running containers: `docker ps`, ensure no duplicate model entries in `config.cfg` |
| OpenVINO model stuck "starting" for a long time | Expected on first start — the checkpoint is being converted to IR. Watch progress: `docker logs -f agentic-ovms-<name>`. Use an `OpenVINO/*` model ID to skip conversion. |
| OpenVINO model OOM-killed during first start | Conversion needs ~fp16-checkpoint memory. Raise `resources.memory` in `ovms-model-configs.yaml`, deploy fewer models at once, or use a pre-converted `OpenVINO/*` model. |
| `openai/whisper-small` never becomes healthy | Speech-to-text is not an OVMS 2025.4 task — set `serving_engine=vllm` for speech models. |

### Custom Model Configuration

Add model-specific vLLM parameters by editing `docker/model-configs.yaml`:

```yaml
models:
  "your-org/your-model-name":
    served_name: "your-model-safe-name"  # Optional: URL-safe name
    environment:
      VLLM_CPU_KVCACHE_SPACE: "40"
      # ... other env vars
    command_args:
      - "--block-size"
      - "128"
      - "--dtype"
      - "bfloat16"
      # ... vLLM CLI args
    resources:
      memory: "80g"
      shm_size: "16g"
```

For `serving_engine=openvino`, edit `docker/ovms-model-configs.yaml` instead:

```yaml
models:
  "your-org/your-model-name":
    served_name: "your-model-safe-name"  # Optional: URL-safe name
    source_model: "OpenVINO/your-ir-repo" # Optional: pull IR weights instead of converting
    task: text_generation                 # text_generation | embeddings | rerank | image_generation
    weight_format: int4                   # optimum-cli export precision
    tool_parser: hermes3                  # Optional: llama3 | hermes3 | phi4
    environment:
      OVMS_LOG_LEVEL: "INFO"
    extra_args:                           # OVMS CLI args
      - "--cache_size"
      - "16"
      - "--max_num_seqs"
      - "256"
    resources:
      memory: "96g"
```

Then add to `config.cfg` and deploy:
```ini
models=your-org/your-model-name
```

```bash
./deploy-agentic-stack.sh --platform=docker
```

---

## Configuration

Edit `docker/config.cfg`:

```ini
hugging_face_token=hf_xxx

# Model serving runtime: vllm (default) or openvino
serving_engine=vllm

models=Qwen/Qwen2.5-Coder-14B-Instruct
tool_call_parser=qwen3_coder   # vLLM only

# Install Docker + Docker Compose automatically if not already present
deploy_docker_fresh=off

# Optional services
deploy_agenticai_plugin=off   # Flowise agent builder
deploy_observability=off      # Langfuse LLM tracing (ClickHouse + MinIO)

# Proxy (if needed)
http_proxy=<http_proxy>
https_proxy=<https_proxy>
no_proxy=localhost,127.0.0.1,.genai-gateway,.redis,.postgres,.flowise
```

Secrets are auto-generated and stored in `docker/vault.yml`.

---


## Services

| Service | Port | Purpose |
|---|---|---|
| vLLM **or** OpenVINO Model Server | 2080+ | Model inference (one container per model, `serving_engine` selects which) |
| LiteLLM | 4000 | API Gateway |
| Flowise | 3000 | Agent builder |
| Langfuse | 3002 | LLM tracing (optional) |

---

## Access URLs

| Service | URL |
|---|---|
| Flowise | `http://localhost:3000` |
| LiteLLM | `http://localhost:4000` |
| vLLM (`serving_engine=vllm`) | `http://localhost:2080/v1` |
| OpenVINO Model Server (`serving_engine=openvino`) | `http://localhost:2080/v3` |
| Langfuse | `http://localhost:3002` |

Service credentials (databases, API keys) are in `docker/.env`, generated from
`docker/vault.yml`.

### Flowise First-Time Setup

Flowise has no environment-based admin bootstrap: the first administrator is created in the
browser on the **Setup Account** page, and that creation request is *unauthenticated* —
whoever submits it first becomes the sole organization owner, and everyone after them is
rejected with `You can only have one organization`.

So port 3000 is published on **loopback only**. Open `http://localhost:3000` on the Docker
host and complete Setup Account. Browsing from another machine? Tunnel rather than
publishing the port:

```bash
ssh -L 3000:127.0.0.1:3000 <user>@<docker-host>
```

Once the owner exists, any later `deploy.sh` run detects it and sets
`DENYLIST_URLS=/api/v1/account/register`, closing the endpoint for good. No manual step is
required, and nothing is lost: in open-source mode that endpoint only ever succeeds for the
first organization.

To publish the port on all interfaces anyway — only after Setup Account is done, and only
if the host is on a trusted network — set in `docker/.env`:

```properties
FLOWISE_BIND_ADDR=0.0.0.0
```

> ⚠ Clear `FLOWISE_DENYLIST_URLS` in `docker/.env` if you ever set
> `FLOWISE_EE_LICENSE_KEY`. Flowise Enterprise reuses that same endpoint to let invited
> users complete their signup with an invite code.

---

## Database Access

Postgres and Redis are exposed directly on the host, each with its own least-privilege credential.

| Endpoint | Port |
|---|---|
| Postgres | `localhost:5432` |
| Redis | `localhost:6379` |

Per-service users/passwords are auto-generated into `docker/.env` (source: `docker/postgres/init.sql` and `docker/redis/acl.conf`):

```bash
source docker/.env

# Postgres (swap PGVECTOR_* for LITELLM_DB_*, FLOWISE_DB_*, LANGFUSE_DB_*, or POSTGRES_ADMIN_PASSWORD)
psql "postgresql://${PGVECTOR_USER}:${PGVECTOR_PASSWORD}@localhost:5432/${PGVECTOR_DB}"

# Redis (swap REDIS_PASSWORD/user "admin" for LITELLM_REDIS_PASSWORD, FLOWISE_REDIS_PASSWORD, or LANGFUSE_REDIS_PASSWORD)
redis-cli -h localhost -p 6379 -a "${REDIS_PASSWORD}"
```

---


---

## Adding Models

Edit `docker/config.cfg` with comma-separated HuggingFace model IDs:

```ini
models=Qwen/Qwen2.5-Coder-14B-Instruct,meta-llama/Llama-3.1-8B-Instruct
```

Then redeploy:
```bash
./deploy-agentic-stack.sh --platform=docker
```

**Note:** `docker-compose.vllm.yml`, `docker-compose.ovms.yml`, and `litellm/config.yaml` are auto-generated — do not edit manually.

### Default Configuration

Models not in `docker/model-configs.yaml` use default settings:
- `--dtype bfloat16`, `--block-size 128`, `--enable-prefix-caching`
- Memory: 80GB, KV cache: 40GB, shm: 16GB

A warning appears during generation (expected, not an error):
```
[WARN] Model 'org/model-name' not found in model-configs.yaml, using default configuration
```

With `serving_engine=openvino`, models not in `docker/ovms-model-configs.yaml` use: task `text_generation`, `--weight-format int8`, `--cache_size 12`, `--max_num_seqs 256`, memory 80GB.

### Tool Call Parser

Applies to `serving_engine=vllm`. For OpenVINO, set `tool_parser` per model in `docker/ovms-model-configs.yaml` (`llama3`, `hermes3`, or `phi4`).

For models using default config, enable tool calling in `docker/config.cfg`:

```ini
tool_call_parser=qwen3_coder  # Set to 'none' to disable
```

**Parsers for pre-configured models:**

| Model | Parser |
|---|---|
| Qwen Coder (2.5/3) | `qwen3_coder` or `qwen3_xml` |
| Llama 3.1 | `llama3_json` |
| Gemma 4 | `gemma4` |

---


## Troubleshooting

| Issue | Solution |
|-------|----------|
| Docker service fails to start ("start-limit-hit") | **Cause:** Docker starts but gets stopped repeatedly, triggering systemd's rate limit.<br>**Fix:** Reset the failed state: `sudo systemctl reset-failed docker.service`, then start: `sudo systemctl start docker.service`, verify: `docker ps`<br>**Debug:** Check logs: `journalctl -xeu docker.service --no-pager -n 100` |
| `apt-get` hangs during Docker install | **Cause:** APT is configured with a proxy that is unreachable or requires authentication, causing the package download to stall indefinitely.<br>**Fix:** Ensure `http_proxy` and `https_proxy` are set correctly in `docker/config.cfg`. If the process is stuck, kill it manually: `sudo pkill -f apt-get`. |
| vLLM slow startup | First run downloads model (~28GB), wait 5-10 min |
| OpenVINO slow startup | First run downloads **and converts** the model — 30+ min is normal. Pre-converted `OpenVINO/*` model IDs skip conversion. |
| Memory limit exceeded | Reduce model count in `config.cfg` |
| Port binding error (2080 already allocated) | **Option 1:** Add both models to `config.cfg` (recommended - auto-increments ports)<br>**Option 2:** Stop old container: `docker stop <container-name> && docker rm <container-name>`<br>**Option 3:** Manual fix: Edit the generated `docker/docker-compose.vllm.yml` / `docker-compose.ovms.yml`, change `ports: - "2080:8000"` to `"2081:8000"` (or next available port) |
| Model not found | Verify model ID in `litellm/config.yaml` |
| Permission errors writing to `/models` (OpenVINO) | The one-shot `agentic-ovms-model-store-init` container chowns the model volumes to uid 5000 before the servers start. Check it succeeded: `docker logs agentic-ovms-model-store-init` |
| OpenVINO restart loop with `FATAL Too many open files` | OVMS sizes its REST thread pool from the host core count, which exhausts the container's file descriptors on many-core servers. The generator pins `--rest_workers 32` and raises `nofile` to 65536; override per model with `rest_workers:` in `ovms-model-configs.yaml`. |

---

## Cleanup

```bash
# Stop (keep data)
./deploy-agentic-stack.sh --platform=docker --down

# Stop and delete all data, including cached/converted model weights
# (use docker-compose.ovms.yml when serving_engine=openvino)
docker compose -f docker/docker-compose.yml -f docker/docker-compose.vllm.yml down --volumes
```
