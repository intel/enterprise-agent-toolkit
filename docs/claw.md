<!-- Copyright (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Claw: persistent OpenClaw agents

Claw runs [OpenClaw](https://github.com/openclaw/openclaw) agents as long-lived Kubernetes
workloads on the Agent Toolkit, answered by the models the inference layer serves. It is
off by default (`claw_enabled: false`).

This is the reference for platform operators: what claw installs, how to enable and
configure it, and its security model. To check an install step by step, with the expected
output, follow [claw-e2e.md](claw-e2e.md).

**Contents:** [Components](#components) · [Enable](#enable) · [Create an agent](#create-an-agent) ·
[Memory](#memory) · [Tools](#tools) · [Sandbox, GitHub and web access](#sandbox-github-and-web-access) ·
[OpenShell runtime](#openshell-runtime) ·
[Console and dashboards](#console-and-dashboards) · [REST API](#rest-api) ·
[Run an OpenClaw instance directly](#run-an-openclaw-instance-directly) ·
[Configuration](#configuration) · [Security](#security) · [Validate and remove](#validate-and-remove) ·
[Troubleshooting](#troubleshooting) · [Limitations](#limitations)

---

## Components

| Component | What it installs | Namespace |
|---|---|---|
| `openclaw_operator` | The upstream [OpenClaw operator](https://github.com/paperclipinc/openclaw-operator) `0.38.3`: CRDs `OpenClawInstance`, `OpenClawClusterDefaults`, `OpenClawSelfConfig`, and its controller | `openclaw-operator-system` |
| `agent_operator` | The `Agent` and `Tool` CRDs (`intel-stack.io/v1alpha1`) and the agent operator, which turns each `Agent` into an isolated OpenClaw agent | `agent-operator-system` |
| `mcp_servers` | The MCP servers agents call, each registered as a `Tool`: `memory` (long-term memory on pgvector), `sandbox` (code execution on agent-sandbox, when installed) and `github` | `agent-operator-system` |
| `agent_backend` | The REST API at `https://agents.<base_domain_name>/api`, the `AgentGrant` resource for sharing, realm roles and scopes, the sign-in for browsers, and an API client for scripts | `agent-operator-system` |
| `agent_console` | The browser console at `https://agents.<base_domain_name>/` | `agent-operator-system` |

For every `Agent`, the agent operator creates:

- a namespace `agent-<username>-<name>` that enforces the `restricted` Pod Security Standard
  and joins the ambient mesh;
- a default-deny NetworkPolicy, a ResourceQuota and a LimitRange;
- a Keycloak client `agent-<username>-<name>` in the agent realm, and an identity proxy that
  holds its secret and calls the agent's tools with a token;
- a web-fetch proxy that lets `web_fetch` reach only the domains in `spec.webFetchAllowlist`;
- a pgvector schema `agent_<username>_<name>` for the agent's memory;
- an `OpenClawInstance`, which the OpenClaw operator runs as a pod with a persistent volume;
- a route to the agent's dashboard and chat at `https://agents.<base_domain_name>/gw/<owner ns>/<name>/`;
- the workspace files listed in `spec.workspace`.

One image, built from this repository during install and pushed to the cluster's image
registry, runs the operator, the identity proxies and the MCP servers.

---

## Enable

Claw needs:

- the inference layer and a default model (`llm_services_autodeploy_models`); with claw on,
  the embedding model `bge-base-en` is deployed with it;
- Keycloak (`auth_provider: keycloak`, the default) and pgvector (the default);
- the cluster image registry (`kubernetes_registry_enabled: true`, set before the cluster is
  installed; the toolkit's default).

Install the toolkit first ([single-node deployment](single-node-deployment.md)), then turn
claw on in your environment's copy of the layer config, not in this repository:

```yaml
# env/<env>/config.agent-toolkit.yaml
claw_enabled: true
```

```bash
./es_auto_installer.sh install mcp_servers --env <env>
./es_auto_installer.sh install agent_console --env <env>
```

The first also installs `openclaw_operator` and `agent_operator`; the second also installs
`agent_backend`. A full layer install (`install agent-toolkit`) includes all six. Users sign in
with accounts of the `agent-toolkit` realm, which get the `agent-viewer` and `agent-editor`
roles by default. On a cluster installed before
claw was turned on, deploy the embedding model with `./model-manager deploy bge-base-en`.

---

## Create an agent

An `Agent` lives in its owner's namespace, `user-<username>`.
[`examples/agent.yaml`](examples/agent.yaml) creates that namespace and one agent. Run from
the root of your AI Solutions checkout:

```bash
kubectl apply -f ext/enterprise.agent-toolkit/docs/examples/agent.yaml
kubectl -n user-alice get agent demo
```

```text
NAME   OWNER               DESIRED   PHASE     AGE
demo   alice@example.com   Running   Running   40s
```

| Task | Command |
|---|---|
| See provisioning details | `kubectl -n user-alice get agent demo -o jsonpath='{.status.conditions}'` |
| Suspend (scale to zero, keep state) | `kubectl -n user-alice patch agent demo --type merge -p '{"spec":{"desiredState":"Suspended"}}'` |
| Resume | `kubectl -n user-alice patch agent demo --type merge -p '{"spec":{"desiredState":"Running"}}'` |
| Change workspace files or skills | Edit `spec.workspace` or `spec.skills`; the agent is updated in place |
| Delete (namespace, Keycloak client and data) | `kubectl -n user-alice delete agent demo` |

Agents that are idle for `claw_auto_suspend_idle_minutes` (default 240) are suspended
automatically. The chat walkthrough is in [claw-e2e.md](claw-e2e.md#create-an-agent).

### Agent fields

| Field | Meaning |
|---|---|
| `owner.principal`, `owner.username` | Required. The username (`[a-z0-9]{1,39}`) keys every derived name |
| `runtime` | `claw` (default) or `openshell` ([OpenShell runtime](#openshell-runtime)); cannot be changed later |
| `desiredState` | `Running` (default) or `Suspended` |
| `skills` | OpenClaw capabilities, for example `shell`, `read_file`, `list_files`, and the [tools](#tools) to wire |
| `workspace` | Files seeded into the agent's workspace, keyed by relative path |
| `model` | Per-agent model override (`provider`, `id`, `name`, `baseUrl`, `contextWindow`); see [Context size](#context-size) |
| `modelSecretRef` | Secret in the agent namespace with key `apiKey`, for an overridden model |
| `githubTokenSecretRef` | Secret in the agent namespace with key `token`: the agent's own GitHub PAT |
| `webFetchAllowlist` | Domains `web_fetch` may reach, subdomains included; `*` allows any public site; empty (default) allows none |
| `toolsDeny` | Tool names or globs the agent may not call |

---

## Memory

Every agent has long-term memory: the `memory` tool (`memory_write`, `memory_read`,
`memory_list_tiers`) stores text with its embedding in the agent's own pgvector schema and
searches it by meaning. It survives sessions, restarts and suspends, and is deleted with the
agent.

The agent never holds a credential. Its identity proxy mints a Keycloak token for the memory
server, and the server takes the schema from the token's `memory_schema` claim, so an agent can
reach only its own memory. Calls without a valid token are refused, and agent pods cannot reach
the server except through their proxy. Each call is logged with the caller, for example
`AUDIT memory_read azp=agent-alice-demo schema=agent_alice_demo tier=auto hits=1`.

OpenClaw's built-in memory search uses the same embedding model. Both reach it at
`claw_embedding_base_url`: by default, the embedding model's own KServe URL through the AI
Gateway (`…/llm-inference/bge-base-en/v1`). The AI Gateway's shared `/v1` serves only models
that have an AI Gateway route, and an embedding model deployed for LiteLLM has none, so there
`memory_write` would fail with `404`. `openshell` agents with LiteLLM embed through LiteLLM
instead, with their own key.

---

## Tools

A `Tool` registers an MCP server for agents. It is cluster-scoped and created by the installer
(`kubectl get tools`):

| Field | Meaning |
|---|---|
| `skill` | The `spec.skills` entry that wires the tool; the oldest `Tool` for a skill wins and later ones are `Conflicting` |
| `aliasSkills` | More skills that wire it; an alias never shadows another tool's skill |
| `url` | In-cluster Service URL (`*.svc` or `*.svc.cluster.local`); anything else is rejected |
| `requiresIdentity` | Calls go through the agent's identity proxy with a token for audience `mcp-<skill>` |
| `alwaysOn` | Wired into every agent, whatever its skills |

Creating, changing or deleting a `Tool` re-wires running agents within seconds. A `Tool` with
`requiresIdentity` receives agents' tokens, so only cluster administrators should create one.

---

## Sandbox, GitHub and web access

**Sandbox** (skill `sandbox`, or `shell`, which aliases it): `execute_python`, `execute_shell`,
`install_package` and `reset_sandbox` run in the agent's own agent-sandbox pod, never shared
with another agent. A sandbox is created on first use from the `claw-agent-pool` pool, renewed
while in use, ended after 30 idle minutes, and deleted when the agent is suspended or deleted.
Sandboxes reach DNS and public HTTP(S), or the platform's corporate proxy, so `pip install`
works; they cannot reach cluster services. The `sandbox` server is installed only when the
`agent_sandbox` component is.

**GitHub** (skill `github`): issues, branches, commits and pull requests. Pull requests always
open as drafts; only `mark_pr_ready` makes one ready for review. Calls use the agent's own PAT
(`spec.githubTokenSecretRef`), which only its identity proxy can read, else a shared token:

```bash
kubectl -n agent-operator-system create secret generic mcp-github-token --from-literal=token=<redacted>
kubectl -n agent-operator-system rollout restart deploy/mcp-github-server
```

**Web.** OpenClaw's `web_fetch` goes through the agent's web-fetch proxy, which allows only
`spec.webFetchAllowlist` and refuses names that resolve to private or cluster addresses. The
proxy reaches the internet through the platform proxy (`http_proxy`, `https_proxy`) when one
is set. An allowlist edit takes effect within a minute, without a restart.

---

## OpenShell runtime

An `Agent` with `runtime: openshell` runs the same OpenClaw agent inside an
[NVIDIA OpenShell](openshell.md) sandbox instead of an `OpenClawInstance`. Its memory,
tools, identity proxy, Keycloak client, console and `/gw/` route are the same; what changes
is how the agent process is confined:

- **Every connection is checked.** The agent runs in a workload pod that can reach only its
  supervisor pod, and the supervisor allows only the agent's identity-proxy ports, the
  `spec.webFetchAllowlist` domains (for OpenClaw itself) and PyPI (`pypi.org`, `files.pythonhosted.org`,
  for Python).
  Everything else, including other cluster services, is refused.
- **The model key never enters the pod.** Each agent namespace gets an OpenShell provider
  that holds the key; the agent sees a placeholder, and the supervisor adds the key only to
  requests to the GenAI Gateway. With `claw_openshell_agent_keys` (on), that key is the
  agent's own LiteLLM key (alias `agent-<username>-<name>`), owned by its user in LiteLLM, so
  LiteLLM records tokens per agent and per user; deleting the agent deletes its key.
  - The supervisor adds the key to any request from the sandbox to LiteLLM, so the key may call
    only model routes (chat, completions, responses, embeddings, model list). Code in the sandbox
    can't use it to mint or list keys.
  - Memory embeddings go through LiteLLM with the same key.
  - Only agents whose provider is `ai-gateway` may reach the AI Gateway. Their chats bypass
    LiteLLM and are not counted there.
- **Code runs in the agent's own pod.** OpenClaw's `exec` is always on and runs inside the
  sandbox, so the `sandbox` MCP is not used; the agent installs packages into a venv under
  `/sandbox`.
- **The agent namespace is the sandbox's namespace** (an OpenShell workspace). Its quota,
  LimitRange and Pod Security level apply to the sandbox pods too. In the ambient mesh, the
  sandbox stays meshed but opts out of DNS capture, and may use the mesh tunnel between its
  two pods (see [Network isolation](openshell.md#network-isolation)).

Enable it with OpenShell (which needs Agent Sandbox) and claw:

```yaml
# env/<env>/config.agent-toolkit.yaml
claw_enabled: true
agent_sandbox_enabled: true
openshell_enabled: true
```

Then pick **openshell** as the runtime when creating an agent in the console (shown only when
the cluster offers it, with the longest name your username allows), send `"runtime": "openshell"`
to `POST /api/agents`, or create an `Agent` with `runtime: openshell`. The API refuses a
name that is too long, or a model base URL or key, before the agent is created. Differences
from `claw`:

| | `openshell` |
|---|---|
| Agent namespace | At most 19 characters (`agent-<username>-<name>`), an OpenShell limit; a longer one makes the agent `Failed` with the longest name allowed |
| Model | A gateway and one of its models (`spec.model.provider`, `spec.model.id`; the console lists both live): `genai-gateway` (LiteLLM: budgets and the content-safety guardrail, key injected by the supervisor) or `ai-gateway` (Envoy AI Gateway, no key; `claw_openshell_ai_gateway_enabled`, on by default). A model registered in LiteLLM appears in the list without a restart. `spec.model.baseUrl` and `spec.modelSecretRef` are not supported |
| `spec.webFetchAllowlist` | Each domain and its subdomains, on ports 80 and 443, for OpenClaw's own requests; `*` is not granted. Edits apply to the running sandbox |
| Suspend | Stops the sandbox (its pods go away, the workspace volume stays) and starts it again on resume |
| A stopped sandbox | OpenShell stops a sandbox whose pods died, for example when the agent ran out of memory, and doesn't start it again. The operator starts it again, about 30 s later, then backing off up to 15 minutes between tries. The count and time are in `status.sandboxRestarts`, and each start is a warning in the operator's log. It can't tell that from `openshell sandbox stop`, so to keep an agent stopped, suspend it (`desiredState: Suspended`) |
| Workspace files | Written through the OpenShell gateway, not `kubectl exec` |

**Without LiteLLM.** The inference layer runs LiteLLM (the GenAI Gateway) only with
`auth_type: litellm_vkey` or `litellm_enabled: true`. When the install finds no LiteLLM, the AI
Gateway is the only gateway, whatever `claw_openshell_ai_gateway_enabled` says:
- Agents get no OpenShell provider and no key.
- Chat goes to the AI Gateway, which their policy allows. Memory embeddings go to the embedding
  model's own URL through it (`claw_embedding_base_url`): the AI Gateway's shared `/v1` serves
  only models that have an AI Gateway route, which the embedding model may not have.
- An agent whose `spec.model.provider` is `genai-gateway` fails, with a message to switch it
  to `ai-gateway`, rather than silently losing LiteLLM's accounting and guardrail.
- The console offers only the AI Gateway.
- There are no per-agent keys, no usage per agent or user, no limits, and no content-safety
  guardrail.
- Context sizes are still read, from each model's own URL (`claw_model_server_url`), and
  checked as with LiteLLM. Only a model KServe doesn't serve has an unknown size, and agents on
  it assume `32768`.

The fence is the same: the agent reaches only the AI Gateway, its identity proxy, its allowlist
and PyPI.

**Adding LiteLLM later.** Each component reads whether LiteLLM is there when it is installed, so
after deploying LiteLLM (`litellm_enabled: true`, then `install postgresql` and `install litellm`):

1. Register the models already running: model-manager registers a model only when it deploys
   it, and reads `auth_type` from the inference config, so
   `MM_LITELLM_ENABLED=true ./model-manager deploy <model> --wait` for each. With an unchanged
   spec this only registers it.
2. Re-install `openshell`, `agent_operator` and `agent_backend` (`--only`).

The console then offers the GenAI Gateway. Each existing agent gets its own LiteLLM key, and the
GenAI Gateway provider is attached to its sandbox. That restarts the sandbox once, and its
workspace stays. Its memory embeddings then go through LiteLLM, and its chat stays on the gateway
its spec names.

Users reach an `openshell` agent at the same `/gw/<owner ns>/<name>/` path. The route goes to
the OpenShell gateway, which relays to the agent's sandbox; OpenClaw listens on loopback only
and trusts the user name only from that relay. The gateway's port accepts only the
supervisors, the agent operator and the platform gateway (`openshell-gateway-ingress`). The
platform gateway reaches it through an Envoy Gateway `Backend` (TLS checked against the OpenShell
CA, HTTP/1.1 only, which the dashboard's WebSocket needs), so Envoy Gateway's Backend API must
be enabled, as the platform's `envoy_gateway` role does.


### Context size

OpenClaw plans each conversation for a context size and compacts it only near that size. Unset,
it assumes 200000 tokens, more than most self-hosted models serve: a long conversation would
then fail at the model instead of being compacted. The operator gives OpenClaw:

1. the agent's `spec.model.contextWindow` (the console sends the size the gateway lists), else
2. `claw_model_context_window` for the cluster's own model, else
3. for `openshell` agents, the size the model serves, else
4. `32768`.

The served size is the model server's own `max_model_len`:
- It's read at the server LiteLLM lists for the model, else at the model's own URL,
  `claw_model_server_url`. KServe serves each model at `/<namespace>/<name>`, also through the
  AI Gateway, so this works without LiteLLM.
- LiteLLM's own figure is used only when neither server says.

It never gives more than the model serves, where it can read that. The agent's `ModelContext`
condition shows the size, and is `False` (reason `SizeAdjusted`) when the size was assumed,
capped, or is under `32768`. That is a warning: the agent still runs.

OpenClaw's own system prompt is about 19,500 tokens a turn, so an agent needs at least `32768`.
For `openshell` agents, the API refuses a model the gateway does not serve, a model serving
less than that, and a `contextWindow` under `32768` or over what the model serves. The console
shows such models greyed out, and marks models whose size the gateway does not report.
Changing an agent's model without a size drops the old model's size.

---

## Console and dashboards

Open `https://agents.<base_domain_name>/` and sign in with Keycloak. The console lists your
agents and the ones shared with you; creates, edits, suspends, resumes and deletes them; shares
them for a limited time; and opens each agent's chat and OpenClaw dashboard.

The dashboard and chat are the agent's own gateway, at `/gw/<owner ns>/<name>/` on the same
host. The platform gateway signs the user in, verifies the token, and admits only the owner and
users with a live `converse` grant, and only while they hold the `agent-viewer` role or higher;
everyone else gets `403`. It passes the verified email to the agent as `x-gw-user`, and never
forwards the user's token or cookies. A grant or revocation takes effect on the next request
within seconds, and an expired grant within half a minute; a dashboard already open is closed
within `claw_dashboard_session` (5 minutes by default) and must reconnect. Scripts can call
`/gw/<owner ns>/<name>/v1/chat/completions` with a bearer token from the `agent-api` client (for
agents it owns).

---

## REST API

`https://agents.<base_domain_name>/api` takes a Keycloak access token from realm
`agent-toolkit` for audience `agent-backend`; the gateway and the API both verify it. For
scripts, the installer creates the confidential client `agent-api`. Its secret is in
`agent-operator-system/agent-api-client`, and the agents it creates are owned by user
`automation`. Owners and grantees are matched by the token's email, so the API refuses a token
whose `email_verified` is not `true`: verify users' emails, or turn on email verification in the realm.

```bash
TOKEN=$(curl -s https://keycloak.<base_domain_name>/realms/agent-toolkit/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=agent-api --data-urlencode client_secret=<redacted> \
  --data-urlencode 'scope=agent:read agent:write' | jq -r .access_token)
curl -s https://agents.<base_domain_name>/api/agents -H "Authorization: Bearer $TOKEN"
```

| Method and path | Needs | Does |
|---|---|---|
| `GET /api/agents` | viewer, `agent:read` | Agents you own and agents shared with you |
| `POST /api/agents` | editor, `agent:write` | Create an agent owned by you; `202` with the `href` to poll. `"runtime": "openshell"` picks the [OpenShell runtime](#openshell-runtime) where the cluster offers it (`GET /api/me` lists `runtimes`) |
| `GET` / `PATCH` / `DELETE /api/agents/<ns>/<name>` | `view` / owner / `delete` | Read, edit (skills, tools, workspace, model, keys, allowlist) or delete |
| `POST /api/agents/<ns>/<name>/suspend`, `/resume` | `suspend-resume` | Change the desired state |
| `GET /api/agents/<ns>/<name>/provisioning` | `view` | The operator's provisioning steps |
| `GET`, `POST`, `DELETE /api/agents/<ns>/<name>/grants[/<grant>]` | owner, `agent:grant` to change | Share the agent with another user, for a limited time |
| `GET /api/tools`, `/api/me`, `/api/authz-config` | viewer / any | The tools you may use, who you are, which checks are on |

Each request passes four checks:

- **Role:** realm roles `agent-viewer` < `agent-editor` < `agent-admin` < `platform-admin`; new
  users get the first two.
- **Scope:** the token's `agent:*` scopes cap what it may do, whatever the roles.
- **Resource:** the owner may do everything; a grantee only what a live `AgentGrant` from the
  owner confers (`view`, `suspend-resume`, `converse`, `delete`).
  Without access, an agent is `404`, the same as one that does not exist.
- **Break-glass:** an admin who sends `X-Break-Glass-Reason` may view (`agent-admin`), or also
  suspend and delete (`platform-admin`), agents they do not own. It applies to the API, not to
  other users' dashboards.

Every write, every denial and every break-glass use is audited, to the API log and to the
`audit_events` table in pgvector (monthly partitions, kept `agent_backend_audit_retention_months`).
`GET /api/tools` lists only the tools the caller may use. A `Tool` can restrict itself to roles
with `spec.allowedRoles`.

---

## Run an OpenClaw instance directly

Without the agent operator, an `OpenClawInstance` can be applied by hand:
[`examples/openclaw-instance.yaml`](examples/openclaw-instance.yaml) runs one in namespace
`claw-demo`. It shows the settings the platform requires: the ambient-mesh label, egress on
port `15008` to the inference gateway, and the model's context window. It also shows,
commented out, how to place the instance on particular nodes by node label
(`availability.nodeSelector`, `affinity`, `tolerations`); agents created through the operator
have no such setting yet. The walkthrough is in
[claw-e2e.md](claw-e2e.md#run-an-openclaw-instance).

---

## Configuration

Set these in `env/<env>/config.agent-toolkit.yaml`. Every other value has a working default
in the role defaults ([`openclaw_operator`](../roles/openclaw_operator/defaults/main.yaml),
[`agent_operator`](../roles/agent_operator/defaults/main.yaml)).

| Variable | Default | Meaning |
|---|---|---|
| `claw_enabled` | `false` | Turns claw on |
| `claw_model_id` | first of `llm_services_autodeploy_models` | Model every agent uses unless its `spec.model` overrides it |
| `claw_model_context_window` | `32768` | Tokens OpenClaw plans a conversation for with `claw_model_id`: at least `32768` and at most what the model serves, both checked by the install; `0` for the served size (see [Context size](#context-size)) |
| `claw_embedding_model`, `claw_embedding_dim` | `bge-base-en`, `768` | Embedding model for memory and its vector size |
| `claw_embedding_base_url` | The embedding model's own URL (`claw_model_server_url`) | Where memory embeddings are made, by OpenClaw and the memory server |
| `claw_web_fetch_proxy_enabled` | `true` | Per-agent web-fetch proxy; `false` leaves `web_fetch` without internet access |
| `openshell_enabled` | `false` | Also enables the [`openshell` runtime](#openshell-runtime), with the OpenShell component |
| `claw_openshell_agent_keys` | `true` | A LiteLLM key per `openshell` agent, owned by its user (usage per agent and user); `false` shares one key |
| `claw_openshell_agent_tpm_limit`, `claw_openshell_agent_rpm_limit`, `claw_openshell_user_tpm_limit`, `claw_openshell_user_rpm_limit` | `0` | LiteLLM tokens and requests per minute, per agent key and per user; `0` = no limit. Dollar budgets need model prices set in LiteLLM |
| `claw_openshell_ai_gateway_enabled` | `true` | Offer `openshell` agents the Envoy AI Gateway as well as the GenAI Gateway (LiteLLM). The AI Gateway skips LiteLLM's budgets and guardrail |
| `mcp_servers_github_token_secret` | `mcp-github-token` | Secret (key `token`) with the shared GitHub token |
| `claw_console_hostname` | `agents.<base_domain_name>` | Host of the console, the REST API and the agent dashboards |
| `claw_console_enabled` | `true` | Browser sign-in and per-agent dashboard routes; `false` leaves only the API |
| `agent_console_grafana_url` | empty | Grafana link shown to admins in the console |
| `agent_backend_api_client`, `agent_backend_api_owner` | `agent-api`, `automation` | The scripts' client and the user that owns their agents |
| `agent_backend_audit_retention_months` | `12` | Months of audit events kept; set it to your policy |
| `claw_auto_suspend_idle_minutes` | `240` | Idle time before an agent is suspended; `0` disables |
| `claw_max_agents_per_owner` | `0` | Cap on agents per owner; `0` disables |
| `openclaw_operator_version`, `openclaw_operator_digest`, `openclaw_operator_image_digest` | `0.38.3` and its digests | OpenClaw operator release; change all three together |
| `openclaw_operator_cosign_required` | `false` | `true` makes the operator signature check mandatory |

---

## Security

- **Tenancy.** An `Agent` is accepted only in `user-<owner.username>`; one placed elsewhere is
  marked `Failed` and nothing is provisioned. Usernames exclude `-` and `_`, so
  `agent-<username>-<name>` names exactly one owner and agent. Teardown deletes only the
  namespace the operator created for that agent.
- **Isolation.** Each agent namespace enforces the `restricted` Pod Security Standard, a
  ResourceQuota and a LimitRange, and a default-deny NetworkPolicy: ingress from the same
  namespace and, to the agent gateway, from the platform gateway; egress to DNS and the
  inference gateway only. In the ambient mesh, egress to
  a mesh workload uses the HBONE port `15008`.
- **Identity.** Each agent gets its own Keycloak client. Its secret is mounted only into the
  agent's identity proxy, which attaches a short-lived token scoped to one tool per call and
  strips any credential header the agent sends. The operator manages clients with a service
  account that holds only `manage-clients` in the agent realm, and never hands out a client
  recorded as another owner's.
- **Tools.** MCP servers verify each token's signature, issuer, audience and scopes. Only
  identity proxies may reach them, and a `Tool` must name an in-cluster Service. The operator
  can read `Tool`s and set their status, never create or change one.
- **API.** Tokens are verified at the gateway and again in the API (signature, issuer,
  audience, expiry). The API reads an agent's Secrets only through a Role the operator binds in
  that agent's namespace. An admission policy limits its cluster-wide Secret creation to its
  own Opaque Secrets in agent namespaces. Only the platform gateway can reach the API and the
  console, and the API holds no agent credential.
- **Browsers and dashboards.** Sign-in is the platform gateway's OpenID Connect flow (PKCE, one
  client, encrypted session cookies). Each agent's route admits only its owner and `converse`
  grantees whose token carries `agent:converse` and the `agent-viewer` role or higher. The agent gateway runs in trusted-proxy mode:
  it takes the user from `x-gw-user`, which the platform gateway sets from the verified token.
  Its relay only accepts traffic the NetworkPolicy admits: the platform gateway and the agent's
  own namespace.
- **Egress.** An agent pod reaches the internet only through its web-fetch proxy, which
  enforces the allowlist. Sandboxes are separate pods that cannot reach cluster services. The
  GitHub server never returns or logs a token, and opens pull requests only as drafts.
- **Credentials.** Model keys and GitHub tokens are referenced by Secret name; they are never
  written into the `Agent` or the `OpenClawInstance`. The cluster's default model key is never
  sent to an endpoint an agent chose itself.
- **Least privilege.** The operator cannot list Secrets and holds no cluster-wide exec: it
  binds exec in each agent namespace, only for seeding workspace files. Workspace paths are
  validated at admission and passed to the container as arguments, never as shell text.
- **Supply chain.** The OpenClaw operator chart and images are pinned by digest and their
  signatures are verified when `cosign` is installed. The agent operator image is built from
  this repository with its tests as a build gate, and deployed by digest.

---

## Validate and remove

```bash
./es_auto_installer.sh validate agent_console --only --env <env>
./es_auto_installer.sh validate agent_backend --only --env <env>
./es_auto_installer.sh validate mcp_servers --only --env <env>
./es_auto_installer.sh validate agent_operator --only --env <env>
./es_auto_installer.sh teardown agent_console --only --env <env> --force
./es_auto_installer.sh teardown agent_backend --only --env <env> --force
./es_auto_installer.sh teardown mcp_servers --only --env <env> --force
./es_auto_installer.sh teardown agent_operator --only --env <env> --force
./es_auto_installer.sh teardown openclaw_operator --only --env <env> --force
```

`validate` is read-only. `teardown agent_console` removes the console. `teardown agent_backend`
removes the API, its route and sign-in, both clients and the realm roles and scopes; agents and
grants stay. `teardown mcp_servers` removes the servers and their `Tool`s, which
unwires them from every agent, and the sandbox template and pool. `teardown agent_operator` deletes every `Agent` first, while the
operator can still clean each one up (namespace, Keycloak client, Secrets, memory schema), then the operator,
the CRDs, its Keycloak service account and the image registry configuration on the nodes.
`teardown openclaw_operator` removes the OpenClaw operator and any remaining instances. Both
succeed when nothing is installed.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `install` skips the claw components | `claw_enabled` is not `true` in `env/<env>/config.agent-toolkit.yaml` | Set it there; this repository's `config.yaml` is not read after `init` |
| Agent `Failed`: `must be created in namespace 'user-…'` | The `Agent` is not in its owner's namespace | Create it in `user-<owner.username>` |
| Agent `Running` with reason `degraded: IdentityReady` | The operator cannot reach Keycloak or its credentials are wrong | Check the operator log; re-run `install agent_operator` |
| Agent pod `ImagePullBackOff` on `registry.kube-system…` | The node does not trust the cluster registry | Re-run `install agent_operator`, which configures every node |
| Chat answers `Context overflow` | The inference gateway rejects large requests (`413`), or the context window does not match the model | `install agent_operator` raises the gateway limit; check the agent's `ModelContext` condition and set `claw_model_context_window` or `spec.model.contextWindow` |
| Agent `Running` with reason `degraded: MemoryReady` | The operator cannot reach pgvector | Check `pgvector` is running; re-run `install agent_operator` |
| `kubectl get tools` shows `Conflicting` | Another `Tool` already registers the skill | Delete one of them |
| Agent answers but never calls `memory_read` / `memory_write` | Small models call tools unreliably | Name the tool in the request, or use a larger model |
| `web_fetch` gets `403 … not in this agent's web_fetch allowlist` | The domain is not allowlisted | Add it to `spec.webFetchAllowlist` |
| GitHub tools answer `no GitHub token` | Neither the agent's PAT nor the shared token is set | Set `githubTokenSecretRef`, or create `mcp-github-token` |
| Console or dashboard loops back to the sign-in page | The browser blocks the gateway's cookies, or the clock is off | Allow cookies for the agents host; check the nodes' time |
| Dashboard answers `403 RBAC: access denied` | The user neither owns the agent nor holds a live `converse` grant | Ask the owner for a grant |
| API answers `401 … not issued for this API` | The token lacks audience `agent-backend` | Use `agent-api`, or add an audience mapper to your client |
| API answers `403 insufficient_scope` | The token was requested without that `agent:*` scope | Request it in `scope=` |
| API answers `404` for an agent that exists | You neither own it nor hold a live grant | Ask the owner for a grant |
| `install_package` hangs | The sandbox cannot reach the package index | Set `http_proxy` / `https_proxy` for the platform and re-run `install mcp_servers` |
| `openclaw_operator_digest is chart version …` | The OpenClaw operator version changed without its digests | Change the version and both digests together |

More symptoms are listed in [claw-e2e.md](claw-e2e.md#if-it-does-not-work).

---

## Limitations

- The dashboards of all agents share one browser origin, so OpenClaw Control UI settings kept in
  the browser apply to every agent's dashboard.
- Break-glass covers the API only; an admin cannot open another user's dashboard.
- Every turn sends the agent's ~19,500-token system prompt, so the first token of each turn is
  slow on a model that reads long prompts slowly.
- `openshell` agents: the agent namespace is limited to 19 characters; all of them share the
  cluster's model key and its budget; `PodReady` turns true a few seconds before OpenClaw
  answers; and the agent can edit its own `openclaw.json` (as with `claw`), which changes its
  behaviour but not what its sandbox policy allows.
