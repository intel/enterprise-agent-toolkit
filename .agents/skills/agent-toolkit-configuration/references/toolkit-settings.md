# Toolkit settings reference

All keys below go in `env/<env>/config.agent-toolkit.yaml` unless the table says otherwise. The shipped defaults are in `config.yaml` (seeded keys) and `roles/<role>/defaults/main.yaml` (everything else) of this repo. Read those files to confirm a default before quoting it.

"Before first install" means the value is baked into data or volumes. Changing it later needs a teardown of that component, which deletes its data.

## Seeded keys (`config.yaml`)

| Key | Default | Meaning and when to change |
|---|---|---|
| `node_preflight_enabled` | `true` | Release track: node readiness report at the start of `install` (report only, capped at 5 minutes); turn off for CI or a slow SSH fan-out. Main track: nothing reads it. Run the report by hand instead (agent-toolkit-install skill, step 5). |
| `auth_type` | `litellm_vkey` | API access mode. `litellm_vkey` = LiteLLM with virtual keys (what the toolkit needs). `jwt` = Keycloak tokens straight to the AI gateway, with no LiteLLM, guardrail, hybrid router, Langfuse or OpenShell provider. Main track only; see "Auth switch" in `../SKILL.md`. |
| `guardrails_enabled` | on with LiteLLM | Content-safety guard on every LiteLLM request. Fail-closed, and adds the `qwen3guard` CPU model. Set `false` to save CPU or for latency tests. How to apply on or off differs by track; see `../SKILL.md` section 4. |
| `hybrid_router_enabled` | `true` | Publishes the LiteLLM model `hybrid-router`. Changes on an installed LiteLLM need `-- -e litellm_reconcile=true`. |
| `litellm_public_paths` | `[]` | Paths published on `litellm.<base_domain_name>`. `[]` = every path, including the key-management API (LiteLLM still asks for a key). To restrict it, list API paths such as `/v1/chat/completions`, `/v1/embeddings` and `/v1/models`. Main track: the toolkit's `[]` replaces the inference layer's API-only default, and the admin UI is on `litellm-ui.<base_domain_name>` regardless. Release track: a non-empty list also unpublishes the UI. With `routing_mode: path` (main track), always set the list explicitly. |
| `llm_services_autodeploy_models` | `["qwen2-5-coder-14b"]` | Models deployed by `install`. They are **required**: if one fails, the install fails. `[]` installs no chat model. The first entry is also the hybrid-router and semantic-router default. Names must exist in `env/<env>/models.yaml`. |
| `vllm_sr_dashboard_enabled` | `true` | vLLM Semantic Router dashboard. Matters only with `vllm_sr_enabled: true` in `config.inference.yaml`. |
| `vllm_sr_litellm_model_name` | `vllm-sr/auto` | The model name clients use for semantic routing. |
| `redis_stack_namespace` | `redis` | Before first install. |
| `redis_stack_storage_class` | `""` (cluster default) | Pin a StorageClass, for example a local one for latency. Before first install. |
| `redis_stack_persistence_size` | `10Gi` | Before first install (the volume size is fixed). |
| `pgvector_namespace` | `pgvector` | Before first install. |
| `pgvector_database`, `pgvector_username` | `agentdb`, `agentuser` | Before first install. Changing them later breaks validation (`role ... does not exist`). |
| `pgvector_storage_size` | `20Gi` | Before first install. |
| `agent_sandbox_namespace` | `agent-sandbox-system` | **Do not change.** The upstream manifests and templates hard-code it. |
| `agent_sandbox_version` | `v0.5.0` | Upstream Agent Sandbox release. Clients must use the same SDK version. Delete `/tmp/agent-sandbox-router.yaml` on the installer host before upgrading. |
| `openshell_enabled` | `false` | Policy-enforced sandboxes. Needs `agent_sandbox_enabled: true`. With Istio it also lets every pod in the cluster reach LiteLLM's port. |
| `openshell_oidc_issuer` | `""` | Empty = single admin through `kubectl port-forward`. OIDC is not validated. |
| `litellm_allow_pod_network` | follows `openshell_enabled` | Admits the pod network on LiteLLM's port. On a bring-your-own cluster also set `kubernetes_cluster_cidr` to the real pod CIDR. |
| `kuberay_enabled` | `false` | Ray cluster for parallel work. |
| `kuberay_namespace` | `ray-system` | Also appears in `litellm_allowed_namespaces`. |
| `kuberay_operator_version` | `1.3.0` | KubeRay operator chart. Change together with `kuberay_ray_image`. |
| `litellm_allowed_namespaces` | gateway, litellm, agent-sandbox-system, ray-system | Namespaces whose pods may call LiteLLM in-cluster. Add your own **ambient** agent namespace. The value replaces the default list, so keep the shipped entries. Main track: the inference default also lists `model-manager` (used by model-manager Jobs started from Headlamp); add it back if you use Headlamp deploys. Applied on every run. |
| `keycloak_agent_realm` | `agent-toolkit` | Realm name. Used only when Keycloak is installed. |

## Other component switches (defaults in `components.yaml`, not seeded)

| Key | Default | Notes |
|---|---|---|
| `redis_stack_enabled` | `true` | |
| `pgvector_enabled` | `true` | |
| `agent_sandbox_enabled` | `true` | OpenShell needs it. |
| `keycloak_agent_config_enabled` | on wherever Keycloak runs (on by default on the main track) | Creates the `agent-toolkit` realm. Set `false` to skip the realm. Do not set `keycloak_enabled: false` on the main track: platform sign-in, the LiteLLM UI and Langfuse sign-in depend on it. Turning the realm on without Keycloak makes the install wait and fail. A leftover `auth_provider: litellm` in `global_config.yaml` turns the realm off by default. |

## Overridable role defaults (not seeded)

Add these to `env/<env>/config.agent-toolkit.yaml` only when needed. Check the exact name in the role's `defaults/main.yaml` first.

| Area | Keys |
|---|---|
| Redis | `redis_stack_auth_enabled` (`true`) |
| pgvector | `pgvector_storage_class`, `pgvector_resources`, `pgvector_parameters` (for example `{max_connections: 600}`) |
| Agent Sandbox | `agent_sandbox_python_warm_pool_size` (5; 0 disables the pool), `kata_warm_pool_size` (1), `agent_sandbox_router_image`, `agent_sandbox_python_runtime_image`, `agent_sandbox_core_manifest_url`, `agent_sandbox_extensions_manifest_url`, `agent_sandbox_router_manifest_url` (mirrors for air-gapped sites) |
| OpenShell | `openshell_release_name`, `openshell_workspace_storage_class`, `openshell_sandbox_egress_cidrs`, `openshell_sandbox_dns_cidrs`, `openshell_upstream_proxy_cidrs`, `openshell_genai_key_models` (`[]` = all models), `openshell_genai_key_max_budget` (50) |
| KubeRay | `kuberay_worker_replicas` / `kuberay_worker_min_replicas` / `kuberay_worker_max_replicas` (2 / 1 / 4), head and worker CPU and memory, `kuberay_dashboard_enabled`, `kuberay_dashboard_basic_auth` |

## Settings that have no effect

Nothing reads these, so changing them does nothing:
- `redis_stack_resources`
- `pgvector_version` (the image tag is fixed in the chart)
- `agent_sandbox_release_name`
- `keycloak_admin_secret`

## Keys that live in other files

| Key | File | Notes |
|---|---|---|
| `kata_containers_enabled`, `kata_runtime` (`kata-fc`, `kata-qemu`, `both`) | `global_config.yaml` | Infrastructure component. Needs `/dev/kvm` on the nodes. |
| `base_domain_name`, proxy settings (`http_proxy`, `https_proxy`, `no_proxy`), `gateway_tls_mode`, `existing_kubernetes`, `storage_backend` | `global_config.yaml` | Toolkit Manager settings |
| `routing_mode` (`subdomain` or `path`) | `global_config.yaml` | Main track only. Path mode serves LiteLLM at `https://<base_domain_name>/litellm/v1`. It changes every published URL (gateway, Keycloak, Grafana, LiteLLM); after install, re-run the full install with `-- -e litellm_reconcile=true`, and treat it as untested. |
| `auth_provider` | `global_config.yaml` | Release track switch (`litellm` or `keycloak`). Deprecated on the main track: if present it must agree with `auth_type`, else preflight stops. |
| `vllm_sr_enabled` | `config.inference.yaml` | vLLM Semantic Router (the toolkit sets its dashboard and model name) |
| Inference layer keys the toolkit sets (`guardrails_enabled`, `hybrid_router_enabled`, `litellm_*`, `llm_services_autodeploy_models`, `vllm_sr_*`) | `config.agent-toolkit.yaml` | Loaded after `config.inference.yaml`, so the toolkit file wins over the inference file, and `global_config.yaml` wins over both |
| Hybrid router tuning (`hybrid_router_tier_candidates`, `hybrid_router_default_model`), guardrail (`guardrail_model`, `guard_block_on_controversial`) | `config.agent-toolkit.yaml` | Inference role defaults. Check them in `<root>/ext/enterprise.ai-inference/roles/litellm/defaults/main.yaml`. Pass `litellm_reconcile=true` with `-- -e` for one run only; left `true` in a file it upgrades LiteLLM on every run. |
