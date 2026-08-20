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

The following models have optimized configurations in `docker/model-configs.yaml`:

| Model | Type |
|-------|------|
| `Qwen/Qwen2.5-Coder-14B-Instruct` | LLM |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | LLM |
| `meta-llama/Llama-3.1-8B-Instruct` | LLM |
| `google/gemma-4-26B-A4B-it` | LLM |
| `BAAI/bge-base-en-v1.5` | Embedding |
| `BAAI/bge-reranker-base` | Reranker |

**Note:** You can deploy any HuggingFace model, but the vLLM image may not support all models. Models not listed above use default configuration (see `docker/model-configs.yaml`). Verify model compatibility with vLLM before deployment.

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
| Model fails to start | Check logs: `docker compose -f docker/docker-compose.vllm.yml logs vllm-<name>` |
| Model not found in LiteLLM | Verify `docker/litellm/config.yaml` has correct model ID |
| Generator script fails | Install `yq`: `yq --version`, validate YAML: `yq eval '.' docker/model-configs.yaml` |
| Port binding error | Check running containers: `docker ps`, ensure no duplicate model entries in `config.cfg` |

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
models=Qwen/Qwen2.5-Coder-14B-Instruct
tool_call_parser=qwen3_coder

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
| vLLM | 2080+ | Model inference |
| LiteLLM | 4000 | API Gateway |
| Flowise | 3000 | Agent builder |
| Langfuse | 3002 | LLM tracing (optional) |

---

## Access URLs

| Service | URL |
|---|---|
| Flowise | `http://localhost:3000` |
| LiteLLM | `http://localhost:4000` |
| vLLM | `http://localhost:2080/v1` |
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

**Note:** `docker-compose.vllm.yml` and `litellm/config.yaml` are auto-generated — do not edit manually.

### Default Configuration

Models not in `docker/model-configs.yaml` use default settings:
- `--dtype bfloat16`, `--block-size 128`, `--enable-prefix-caching`
- Memory: 80GB, KV cache: 40GB, shm: 16GB

A warning appears during generation (expected, not an error):
```
[WARN] Model 'org/model-name' not found in model-configs.yaml, using default configuration
```

### Tool Call Parser

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
| Memory limit exceeded | Reduce model count in `config.cfg` |
| Port binding error (2080 already allocated) | **Option 1:** Add both models to `config.cfg` (recommended - auto-increments ports)<br>**Option 2:** Stop old container: `docker stop <container-name> && docker rm <container-name>`<br>**Option 3:** Manual fix: Edit `docker/docker-compose.vllm.yml`, change `ports: - "2080:8000"` to `"2081:8000"` (or next available port) |
| Model not found | Verify model ID in `litellm/config.yaml` |

---

## Cleanup

```bash
# Stop (keep data)
./deploy-agentic-stack.sh --platform=docker --down

# Stop and delete all data
docker compose -f docker/docker-compose.yml -f docker/docker-compose.vllm.yml down --volumes
```
