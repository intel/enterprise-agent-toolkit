# KubeRay, Langfuse and OpenTelemetry from agent code

## KubeRay: parallel tool execution

Off by default. Turn it on with `kuberay_enabled: true` in `env/<env>/config.agent-toolkit.yaml`.

| | Value |
|---|---|
| Ray client | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` |
| Dashboard and jobs API | `http://ray-cluster-head-svc.ray-system.svc.cluster.local:8265`; externally `https://ray.<base_domain_name>/` |
| Dashboard login | Basic auth on the external route only. Secret `ray-dashboard-auth` in `ray-system`, keys `username` (`ray`) and `password`. The in-cluster `:8265` endpoint has no auth. |
| Cluster | RayCluster `ray-cluster`: head (runs no tasks) plus worker group `default-worker` that autoscales between 1 and 4 |

```python
import ray
ray.init("ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001")
```

- The client must match the cluster: `pip install "ray[default]==2.40.0"` on Python 3.12. A different Ray or Python version fails on connect.
- From a laptop: `kubectl port-forward -n ray-system svc/ray-cluster-head-svc 10001:10001`, then `ray.init("ray://localhost:10001")`.
- Ray workers can call LiteLLM; `ray-system` is in `litellm_allowed_namespaces`.
- Do not `kubectl scale raycluster` (it has no scale subresource). Set `kuberay_worker_replicas`, `kuberay_worker_min_replicas` or `kuberay_worker_max_replicas` and re-run `./es_auto_installer.sh install kuberay --only` **(changes the cluster)**. The autoscaler owns the replica count.

## Langfuse: LLM traces with no code change

When LiteLLM runs as the API gateway, it sends every call to Langfuse. Your agent gets traces without any SDK.

| | Value |
|---|---|
| UI | `https://langfuse.<base_domain_name>`. Main track: Keycloak sign-in. Admin login on either track: Secret `langfuse-secrets` in `langfuse` (`admin_email`, `admin_password`) |
| In-cluster API | `http://langfuse-web.langfuse.svc.cluster.local:3000` |
| SDK keys (for your own spans) | Secret `langfuse-api-keys` in `litellm`: `LANGFUSE_HOST`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` |

To group traces per agent or session, send LiteLLM metadata with the request, for example `"metadata": {"trace_user_id": "<agent>", "session_id": "<id>"}` in the OpenAI request body (`extra_body` in the OpenAI Python SDK).

If traces stop appearing, check Langfuse's ClickHouse pod for restarts: `kubectl get pods -n langfuse`. A ClickHouse pod that keeps getting OOMKilled drops traces without an error on the LiteLLM side.

## OpenTelemetry for agent spans and metrics

| Protocol | Endpoint |
|---|---|
| OTLP gRPC | `opentelemetry-collector.monitoring.svc.cluster.local:4317` |
| OTLP HTTP | `http://opentelemetry-collector.monitoring.svc.cluster.local:4318` |

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.monitoring.svc.cluster.local:4318
OTEL_SERVICE_NAME=<your-agent>
```

The collector feeds Tempo, viewed in Grafana (`https://grafana.<base_domain_name>`).

The Agent Sandbox SDK emits its own spans when you pass `tracer_config=SandboxTracerConfig(enable_tracing=True, trace_service_name="<your-agent>")` to `SandboxClient` (from `k8s_agent_sandbox.models`). It needs the extra, `pip install "k8s-agent-sandbox[tracing]==0.5.0"`; without it the SDK only logs `OpenTelemetry not installed`. Its exporter speaks **gRPC**, so point it at port 4317: `OTEL_EXPORTER_OTLP_ENDPOINT=http://opentelemetry-collector.monitoring.svc.cluster.local:4317`. If the rest of your app exports over HTTP, set `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` per exporter instead.
