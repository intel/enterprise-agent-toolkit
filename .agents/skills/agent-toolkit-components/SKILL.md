---
name: agent-toolkit-components
description: Connect agent code to the components of an installed Intel Agent Toolkit. Covers the LiteLLM endpoint and per-agent virtual keys, Redis Stack and pgvector memory, Agent Sandbox code execution (Python SDK, router token, RBAC, Kata microVMs), OpenShell policy sandboxes, KubeRay, Langfuse tracing and OpenTelemetry. Use when writing or deploying an agent (LangGraph, CrewAI, OpenAI SDK or custom) against the toolkit, wiring credentials into a pod, giving a new namespace access to the toolkit services, or when agent code gets connection resets, 401s, WRONGPASS, vector dimension errors or sandbox SDK timeouts.
---

# Use the Intel Agent Toolkit components from agent code

## 1. See what is installed

```bash
kubectl get ns litellm redis pgvector agent-sandbox-system openshell-system ray-system langfuse --ignore-not-found
```

A component that was never installed has no namespace. One switched off after install keeps running until it is torn down. The switches live in `env/<env>/config.agent-toolkit.yaml`; see the agent-toolkit-configuration skill. `kubectl` must point at the cluster (`export KUBECONFIG=<root>/env/<env>/kubeconfig.yaml`; see `AGENTS.md`).

## 2. Pick endpoints and credentials

| Service | In-cluster endpoint | Credential: Secret (namespace) → key |
|---|---|---|
| LiteLLM (OpenAI API) | `http://litellm.litellm.svc.cluster.local:4000/v1` | Mint a virtual key with `litellm-master-key` (litellm) → `master_key` |
| Redis Stack | `redis-stack-server.redis.svc.cluster.local:6379` | `redis-stack-server-credentials` (redis) → `REDIS_URL` |
| pgvector | `pgvector.pgvector.svc.cluster.local:5432`, db `agentdb` | `pgvector-credentials` (pgvector) → `DATABASE_URL`, `POSTGRES_DSN` |
| Agent Sandbox router | `http://sandbox-router-svc.agent-sandbox-system.svc.cluster.local:8080` | `sandbox-router-auth` (agent-sandbox-system) → `ROUTER_AUTH_TOKEN` |
| OpenShell gateway | `openshell.openshell-system.svc.cluster.local:8080` (mTLS, through the CLI) | `openshell-client-tls` (openshell-system), full admin |
| Ray | `ray://ray-cluster-head-svc.ray-system.svc.cluster.local:10001` | Dashboard: `ray-dashboard-auth` (ray-system) |
| Langfuse | `http://langfuse-web.langfuse.svc.cluster.local:3000` | `langfuse-api-keys` (litellm) → `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` |
| OpenTelemetry | `opentelemetry-collector.monitoring.svc.cluster.local:4317` (gRPC), `:4318` (HTTP) | none |

Read a value into a variable, never to the screen: `VAL=$(kubectl get secret <name> -n <ns> -o jsonpath='{.data.<key>}' | base64 -d)`. To see which keys a Secret has: `kubectl get secret <name> -n <ns> -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`.

## 3. Put the agent where it can reach them

The toolkit services are in an Istio ambient mesh with STRICT mTLS, and LiteLLM admits only listed namespaces. A pod outside the mesh, or one the policy does not allow, gets a **connection reset** and no error message. Follow `references/namespace-onboarding.md`:
1. label the namespace `istio.io/dataplane-mode=ambient`;
2. add it to `litellm_allowed_namespaces`;
3. copy the Secrets;
4. add sandbox RBAC if needed.

## 4. Wire each service

Steps marked **(changes the cluster)** in the references create or change objects. Show the user the command and get an OK first.

| Service | Reference |
|---|---|
| LiteLLM: keys, URLs, model names, guardrail responses | `references/litellm.md` |
| Redis and pgvector: URLs, schema, the 1536-dimension tables | `references/memory.md` |
| Agent Sandbox and Kata: SDK code, RBAC, router token, isolation | `references/sandbox.md` |
| OpenShell: CLI, sandboxes, allowed binaries | `references/openshell.md` |
| KubeRay, Langfuse, OpenTelemetry | `references/ray-and-tracing.md` |

## Rules

- One virtual key per agent, limited to its models, with a budget. Never give agent code the master key.
- Mount credentials from Secrets (`secretKeyRef`). Never paste them into code, chat or logs.
- Tearing a component down and installing it again makes new credentials: Redis and pgvector passwords, the router token, OpenShell certificates and key, and the Ray dashboard password. Re-read or re-copy them afterwards. A plain re-run of install keeps them, and LiteLLM virtual keys survive both.
- Code inside an Agent Sandbox reaches only the public internet. It cannot reach LiteLLM, Redis, pgvector, cluster DNS or the Kubernetes API, by design. Pass data in and out through the SDK.
- Behind a proxy, set `NO_PROXY=.svc,.cluster.local,localhost,127.0.0.1` in agent pods.
- Use model names from `GET /v1/models`, not from examples.

## Fast answers

| Symptom | Cause | Fix |
|---|---|---|
| Connection reset to any toolkit service | Namespace not in the mesh, or not allowed by LiteLLM | `references/namespace-onboarding.md` |
| LiteLLM 400, 401, 403 or 429 about the key | Read `error.type` in the body: `budget_exceeded`, `expired_key`, `key_model_access_denied` or `auth_error`. The status code for each differs between LiteLLM versions. | Check the key with `/key/info`; `references/litellm.md` |
| LiteLLM 500 `Blocked by the content-safety guardrail: ...` | Guardrail decision (or the guard is down) | Read the reason; agent-toolkit-troubleshoot skill, GRD-1 |
| `WRONGPASS invalid username-password pair` | An old password (Redis was reinstalled), or a client that sends an empty username | Use the current `REDIS_URL` |
| `expected 1536 dimensions, not N` | The pre-created pgvector tables are 1536-d | Create a table with your dimension |
| Sandbox SDK `TimeoutError("Could not resolve sandbox name from claim ...")`, `SandboxWarmPoolNotFoundError`, or 403 `... in the namespace "default"` | Wrong namespace (the SDK default is `default`) or wrong warm pool name | `namespace="agent-sandbox-system"`, `warmpool="python-pool"` |
| Sandbox SDK 403 `cannot create resource "sandboxclaims"` | No RBAC for the pod's ServiceAccount | Role in `references/sandbox.md` |
| `SandboxRequestError` with `status_code` 401 | Missing or old router token | `Authorization: Bearer <ROUTER_AUTH_TOKEN>` |
| OpenShell `policy_denied` | The calling program is not in the provider's `binaries` | `references/openshell.md` |

Anything else: use the agent-toolkit-troubleshoot skill.
