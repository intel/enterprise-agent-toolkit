An example and Explaination of the `agentic-config.cfg` settings, as set in the `env/<name>/` files of this release:
`````
# env/<name>/global_config.yaml
base_domain_name: "example.com"            # cluster_url: APIs on https://litellm.<base_domain_name>/v1
gateway_tls_mode: "selfsigned"             # cert_file / key_file: set "custom" and the two lines below
# gateway_tls_cert_file: "/path/to/cert/file.pem"
# gateway_tls_key_file: "/path/to/key/file.pem"
# existing_kubernetes: /path/to/kubeconfig # unset = fresh Kubernetes cluster (deploy_kubernetes_fresh=on)
auth_provider: "litellm"                   # deploy_genai_gateway=on (set by init agent-toolkit)
observability_enabled: true                # deploy_observability
storage_backend: local-path                # deploy_ceph: ceph
istio_enabled: false                       # deploy_istio
kata_containers_enabled: false             # deploy_kata_containers
kata_runtime: "kata-fc"
http_proxy: ""
https_proxy: ""
no_proxy: ""

# env/<name>/config.agent-toolkit.yaml
llm_services_autodeploy_models: ["qwen2-5-coder-7b"]   # deploy_llm_models, models
redis_stack_enabled: true                  # deploy_redis
pgvector_enabled: false                    # deploy_pgvector
kuberay_enabled: false                     # deploy_kuberay
agent_sandbox_enabled: false               # deploy_agent_sandbox
guardrails_enabled: true                   # deploy_guardrails
openshell_enabled: false                   # deploy_openshell

# env/<name>/config.inference.yaml
vllm_sr_enabled: false                     # deploy_vllm_sr

# hugging_face_token: export HF_TOKEN=hf_... before install / model-manager
# not available in this release: hugging_face_token_falcon3, compute_platform=g (GPU models),
# uninstall_ceph, deploy_agenticai_plugin, rack_scale_mode, air_gapped
# deploy_ingress_controller: none (the platform gateway is always installed)

`````
Make sure to update the values in `env/<name>/global_config.yaml`, `config.agent-toolkit.yaml` and `config.inference.yaml` according to your requirements before running the Intel® AI for Enterprise Agent Toolkit.


>
> - If `existing_kubernetes` is not set, a fresh Kubernetes cluster will be initialized as per the deployment configuration.
> - The platform gateway is always installed to route external traffic to the cluster
> - If `auth_provider` is set to `"litellm"`, the GenAI Gateway will be deployed.
> - If `observability_enabled` is set to `true`, the observability stack (Grafana) will be deployed. The Langfuse LLM tracing stack is deployed with the GenAI Gateway.
> - The models in `llm_services_autodeploy_models` will be deployed for inferencing; deploy others with `./model-manager deploy <name>`
> - With `gateway_tls_mode: "custom"`, the `gateway_tls_cert_file` and `gateway_tls_key_file` paths should be set according to the instructions for generating certificates for development and production environments, as documented.
> - The `llm_services_autodeploy_models` values correspond to the model names in the catalog, `env/<name>/models.yaml`.
> - The Hugging Face token used for pulling LLM models from Hugging Face is set with `export HF_TOKEN=hf_...` before install / model-manager.
> - If `llm_services_autodeploy_models` is set to `[]`, the `HF_TOKEN` value will be ignored.
> - The `cpu` value specifies whether to deploy models for CPU or Intel® AI Accelerator.
>   > **Note:** not available in this release.
> - If `redis_stack_enabled` is set to `true` , Redis will be deployed which is the default memory backend, giving agents persistent session state, semantic search over past interactions, and cross-request continuity. Redis is password-protected (credentials generated into the `redis-stack-server-credentials` Secret) and reachable only from inside the cluster — see [backend-connection-reference.md](./backend-connection-reference.md#redis-session-memory--caching).
> - If `pgvector_enabled` is set to `true`, PostgreSQL 16 with the pgvector extension will be deployed as a vector store and long-term memory backend.
> - If `kuberay_enabled` is set to `true`, KubeRay will be deployed to provide Ray distributed computing inside the cluster. Tuning parameters (namespace, worker replicas, CPU/memory limits, Ray image) are the `kuberay_*` settings in `config.agent-toolkit.yaml` — see [docs/kuberay.md](./kuberay.md) for the full guide.
> - If `agent_sandbox_enabled` is set to `true`, the Agent Sandbox controller will be deployed for isolated pod-based code execution.
> - If `kata_containers_enabled` is set to `true`, Kata Containers is installed so sandboxes can run as microVMs with their own guest kernel, and `kata_runtime` selects the runtime (`kata-fc` for Firecracker, `kata-qemu` for QEMU, or `both`). This requires `agent_sandbox_enabled: true` — otherwise a warning is printed and Kata is skipped. Nodes need KVM (`/dev/kvm`), and `kata-fc` additionally needs containerd's devmapper snapshotter; missing prerequisites warn and skip instead of failing the run — see [agent-sandbox.md](./agent-sandbox.md#microvm-isolation-with-kata-containers-kata-fc--kata-qemu).
> - To deploy on GPU instead of CPU, set `compute_platform=g` and select a GPU model in `models` (e.g. `gpu-nvidia-b300-llama-70b`), as shown in the commented GPU example above.
>   > **Note:** not available in this release.
> - If `rack_scale_mode` is set to `on`, the toolkit deploys using the rack-scale fabric topology (BGP, dual-homed nodes, Ceph-on-fabric) instead of the standard single/multi-node path — see [rack-scale-deployment.md](./rack-scale-deployment.md).
>   > **Note:** not available in this release.
> - If `air_gapped` is set to `on`, the internet connectivity precheck is skipped for isolated/local-mirror sites; leave it commented out (or `off`) when the cluster has internet access.
>   > **Note:** not available in this release.
> - `guardrails_enabled` (default: on with LiteLLM) deploys the safety content-moderation guardrail in front of the main LLM — see [guardrails.md](./guardrails.md).
> - If `vllm_sr_enabled` is set to `true` (in `config.inference.yaml`), vLLM Semantic Router is deployed to route requests across models by cost/latency/safety signals — see [vllm-semantic-router.md](./vllm-semantic-router.md).
> - If `openshell_enabled` is set to `true`, NVIDIA OpenShell will be deployed for policy-enforced sandboxes on top of Agent Sandbox, with the GenAI Gateway registered as a provider. Requires `agent_sandbox_enabled: true` — see [docs/openshell.md](./openshell.md).

---

## KubeRay Tuning Parameters

KubeRay resource settings are role settings next to the switches above. They live in:

```
env/<name>/config.agent-toolkit.yaml
```

This file is created by `./es_auto_installer.sh init agent-toolkit`; the values below are the defaults. Edit it to tune the Ray cluster before re-running the deploy script:

```yaml
kuberay_namespace: ray-system

kuberay_release_name: ray-cluster
kuberay_ray_image: rayproject/ray:2.40.0-py312

kuberay_head_cpu_request: "500m"
kuberay_head_cpu_limit: "2"
kuberay_head_memory_request: "2Gi"
kuberay_head_memory_limit: "4Gi"

kuberay_worker_replicas: 2
kuberay_worker_min_replicas: 1
kuberay_worker_max_replicas: 4
kuberay_worker_cpu_request: "500m"
kuberay_worker_cpu_limit: "2"
kuberay_worker_memory_request: "2Gi"
kuberay_worker_memory_limit: "4Gi"
```

See [docs/kuberay.md](./kuberay.md) for the full configuration reference and deployment guide.

For running behind corporate proxy, please refer to this [guide](./running-behind-proxy.md)
