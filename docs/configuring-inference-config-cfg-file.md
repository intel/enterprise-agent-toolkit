An example and Explaination of the `agentic-config.cfg` file:
`````
cluster_url=api.example.com
cert_file=/path/to/cert/file.pem
key_file=/path/to/key/file.pem
hugging_face_token=
hugging_face_token_falcon3=
models=cpu-qwen2-5-coder-7b
compute_platform=cpu
deploy_kubernetes_fresh=on
deploy_ingress_controller=on
deploy_genai_gateway=on
deploy_observability=on
deploy_llm_models=on
deploy_ceph=off
deploy_istio=off
uninstall_ceph=off
deploy_agenticai_plugin=off
deploy_redis=on
deploy_pgvector=off
deploy_kuberay=off
deploy_agent_sandbox=off
http_proxy=
https_proxy=
no_proxy=

`````
Make sure to update the values in the agentic-config.cfg file according to your requirements before running the Intel AI for Enterprise Agent Toolkit.


>
> - If `deploy_kubernetes_fresh` is set to `on`, a fresh Kubernetes cluster will be initialized as per the deployment configuration.
> - If `deploy_ingress_controller` is set to `on`, ingress controller will be configured to route external traffic to the cluster
> - If `deploy_genai_gateway` is set to `on`, the GenAI Gateway will be deployed.
> - If `deploy_observability` is set to `on`, the observability stack will be deployed for monitoring.
> - If `deploy_llm_models` is set to `on`, the selected models will be deployed for inferencing
> - The `cert_file` and `key_file` paths should be set according to the instructions for generating certificates for development and production environments, as documented.
> - The `models` value corresponds to the pre-validated LLM models listed in the documentation.
> - The `hugging_face_token` is the token used for pulling LLM models from Hugging Face. 
> - If `deploy_llm_models` is set to `off`, the `hugging_face_token` value will be ignored.
> - The `cpu` value specifies whether to deploy models for CPU or Intel® AI Accelerator.
> - If `deploy_redis` is set to `on` , Redis will be deployed which is the default memory backend, giving agents persistent session state, semantic search over past interactions, and cross-request continuity. Redis is password-protected (credentials generated into `vault.yml` and exposed via the `redis-stack-server-credentials` Secret) and reachable only from inside the cluster — see [backend-connection-reference.md](./backend-connection-reference.md#redis-session-memory--caching).
> - If `deploy_pgvector` is set to `on`, PostgreSQL 16 with the pgvector extension will be deployed as a vector store and long-term memory backend.
> - If `deploy_kuberay` is set to `on`, KubeRay will be deployed to provide Ray distributed computing inside the cluster. Tuning parameters (namespace, worker replicas, CPU/memory limits, Ray image) are configured separately in `core/inventory/kuberay-config.yaml` — see [docs/kuberay.md](./kuberay.md) for the full guide.
> - If `deploy_agent_sandbox` is set to `on`, the Agent Sandbox controller will be deployed for isolated pod-based code execution.

---

## KubeRay Tuning Parameters

KubeRay resource settings are **not** part of `agentic-config.cfg`. They live in a dedicated file:

```
core/inventory/kuberay-config.yaml
```

This file is created automatically on the first run with safe defaults. Edit it to tune the Ray cluster before re-running the deploy script:

```yaml
namespace: ray-system

cluster:
  name: ray-cluster
  rayImage: rayproject/ray:2.40.0-py312

  head:
    cpuRequest: "500m"
    cpuLimit: "1"
    memoryRequest: "2Gi"
    memoryLimit: "4Gi"

  worker:
    replicas: 2
    minReplicas: 1
    maxReplicas: 4
    cpuRequest: "500m"
    cpuLimit: "2"
    memoryRequest: "2Gi"
    memoryLimit: "4Gi"
```

See [docs/kuberay.md](./kuberay.md) for the full configuration reference and deployment guide.

For running behind corporate proxy, please refer to this [guide](./running-behind-proxy.md)
