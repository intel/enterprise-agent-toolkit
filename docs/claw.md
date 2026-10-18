<!-- Copyright (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Claw: persistent OpenClaw agents

Claw runs [OpenClaw](https://github.com/openclaw/openclaw) agents as long-lived Kubernetes
workloads on the Agent Toolkit, answered by the models the inference layer serves. It is
off by default (`claw_enabled: false`).

**Contents:** [Components](#components) · [Enable](#enable) · [Create an agent](#create-an-agent) ·
[Memory](#memory) · [Tools](#tools) · [Sandbox, GitHub and web access](#sandbox-github-and-web-access) ·
[REST API](#rest-api) ·
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
| `agent_backend` | The REST API at `https://agents.<base_domain_name>/api`, the `AgentGrant` resource for sharing, realm roles and scopes, and an API client for scripts | `agent-operator-system` |

For every `Agent`, the agent operator creates:

- a namespace `agent-<username>-<name>` that enforces the `restricted` Pod Security Standard
  and joins the ambient mesh;
- a default-deny NetworkPolicy, a ResourceQuota and a LimitRange;
- a Keycloak client `agent-<username>-<name>` in the agent realm, and an identity proxy that
  holds its secret and calls the agent's tools with a token;
- a web-fetch proxy that lets `web_fetch` reach only the domains in `spec.webFetchAllowlist`;
- a pgvector schema `agent_<username>_<name>` for the agent's memory;
- a gateway token Secret and an `OpenClawInstance`, which the OpenClaw operator runs as a pod
  with a persistent volume;
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
./es_auto_installer.sh install agent_backend --only --env <env>
```

The first also installs `openclaw_operator` and `agent_operator`, which `mcp_servers` depends
on. A full layer install (`install agent-toolkit`) includes all four. On a cluster installed before
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
| `desiredState` | `Running` (default) or `Suspended` |
| `skills` | OpenClaw capabilities, for example `shell`, `read_file`, `list_files`, and the [tools](#tools) to wire |
| `workspace` | Files seeded into the agent's workspace, keyed by relative path |
| `model` | Per-agent model override (`provider`, `id`, `name`, `baseUrl`) |
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

OpenClaw's built-in memory search uses the same embedding model through the inference gateway.

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

## REST API

`https://agents.<base_domain_name>/api` takes a Keycloak access token from realm
`agent-toolkit` for audience `agent-backend`; the gateway and the API both verify it. For
scripts, the installer creates the confidential client `agent-api`. Its secret is in
`agent-operator-system/agent-api-client`, and the agents it creates are owned by user
`automation`.

```bash
TOKEN=$(curl -s https://keycloak.<base_domain_name>/realms/agent-toolkit/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=agent-api --data-urlencode client_secret=<redacted> \
  --data-urlencode 'scope=agent:read agent:write' | jq -r .access_token)
curl -s https://agents.<base_domain_name>/api/agents -H "Authorization: Bearer $TOKEN"
```

| Method and path | Needs | Does |
|---|---|---|
| `GET /api/agents` | viewer, `agent:read` | Agents you own and agents shared with you |
| `POST /api/agents` | editor, `agent:write` | Create an agent owned by you; `202` with the `href` to poll |
| `GET` / `PATCH` / `DELETE /api/agents/<ns>/<name>` | `view` / owner / `delete` | Read, edit (skills, tools, workspace, model, keys, allowlist) or delete |
| `POST /api/agents/<ns>/<name>/suspend`, `/resume` | `suspend-resume` | Change the desired state |
| `GET /api/agents/<ns>/<name>/provisioning` | `view` | The operator's provisioning steps |
| `GET`, `POST`, `DELETE /api/agents/<ns>/<name>/grants[/<grant>]` | owner, `agent:grant` to change | Share the agent with another user, for a limited time |
| `POST /api/chat/<ns>/<name>` | `converse`, `agent:converse` | One chat turn, streamed as server-sent events |
| `POST /api/agents/<ns>/<name>/token` | owner, `agent:token` | Rotate the agent's gateway token |
| `GET /api/tools`, `/api/me`, `/api/authz-config` | viewer / any | The tools you may use, who you are, which checks are on |

Each request passes four checks:

- **Role:** realm roles `agent-viewer` < `agent-editor` < `agent-admin` < `platform-admin`; new
  users get the first two.
- **Scope:** the token's `agent:*` scopes cap what it may do, whatever the roles.
- **Resource:** the owner may do everything; a grantee only what a live `AgentGrant` from the
  owner confers (`view`, `suspend-resume`, `converse`, `credential`, `delete`, `delegate`).
  Without access, an agent is `404`, the same as one that does not exist.
- **Break-glass:** an admin who sends `X-Break-Glass-Reason` may view (`agent-admin`), or also
  suspend, converse with and delete (`platform-admin`), agents they do not own.

Every write, every denial and every break-glass use is audited, to the API log and to the
`audit_events` table in pgvector (monthly partitions, kept `agent_backend_audit_retention_months`).
`GET /api/tools` lists only the tools the caller may use. A `Tool` can restrict itself to roles
with `spec.allowedRoles`.

---

## Run an OpenClaw instance directly

Without the agent operator, an `OpenClawInstance` can be applied by hand:
[`examples/openclaw-instance.yaml`](examples/openclaw-instance.yaml) runs one in namespace
`claw-demo`. It shows the settings the platform requires: the ambient-mesh label, egress on
port `15008` to the inference gateway, and the model's context window. The walkthrough is in
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
| `claw_model_context_window` | `32768` | The model's served `max_model_len`; `0` lets OpenClaw assume 200000 |
| `claw_embedding_model`, `claw_embedding_dim` | `bge-base-en`, `768` | Embedding model for memory and its vector size |
| `claw_web_fetch_proxy_enabled` | `true` | Per-agent web-fetch proxy; `false` leaves `web_fetch` without internet access |
| `mcp_servers_github_token_secret` | `mcp-github-token` | Secret (key `token`) with the shared GitHub token |
| `agent_backend_hostname` | `agents.<base_domain_name>` | Host of the REST API on the platform gateway |
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
  namespace only, egress to DNS and the inference gateway only. In the ambient mesh, egress to
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
  own Opaque Secrets in agent namespaces. Only the gateway can reach it, and no route returns an
  agent's gateway token.
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
./es_auto_installer.sh validate agent_backend --only --env <env>
./es_auto_installer.sh validate mcp_servers --only --env <env>
./es_auto_installer.sh validate agent_operator --only --env <env>
./es_auto_installer.sh teardown agent_backend --only --env <env> --force
./es_auto_installer.sh teardown mcp_servers --only --env <env> --force
./es_auto_installer.sh teardown agent_operator --only --env <env> --force
./es_auto_installer.sh teardown openclaw_operator --only --env <env> --force
```

`validate` is read-only. `teardown agent_backend` removes the API, its route, the API client and
the realm roles and scopes; agents and grants stay. `teardown mcp_servers` removes the servers and their `Tool`s, which
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
| Chat answers `Context overflow` | The inference gateway rejects large requests (`413`), or the context window does not match the model | `install agent_operator` raises the gateway limit; set `claw_model_context_window` |
| Agent `Running` with reason `degraded: MemoryReady` | The operator cannot reach pgvector | Check `pgvector` is running; re-run `install agent_operator` |
| `kubectl get tools` shows `Conflicting` | Another `Tool` already registers the skill | Delete one of them |
| Agent answers but never calls `memory_read` / `memory_write` | Small models call tools unreliably | Name the tool in the request, or use a larger model |
| `web_fetch` gets `403 … not in this agent's web_fetch allowlist` | The domain is not allowlisted | Add it to `spec.webFetchAllowlist` |
| GitHub tools answer `no GitHub token` | Neither the agent's PAT nor the shared token is set | Set `githubTokenSecretRef`, or create `mcp-github-token` |
| API answers `401 … not issued for this API` | The token lacks audience `agent-backend` | Use `agent-api`, or add an audience mapper to your client |
| API answers `403 insufficient_scope` | The token was requested without that `agent:*` scope | Request it in `scope=` |
| API answers `404` for an agent that exists | You neither own it nor hold a live grant | Ask the owner for a grant |
| `install_package` hangs | The sandbox cannot reach the package index | Set `http_proxy` / `https_proxy` for the platform and re-run `install mcp_servers` |
| `openclaw_operator_digest is chart version …` | The OpenClaw operator version changed without its digests | Change the version and both digests together |

More symptoms are listed in [claw-e2e.md](claw-e2e.md#if-it-does-not-work).

---

## Limitations

- Agents are reachable through the REST API and `kubectl`; there is no browser console yet.
- On CPU inference the first token of each turn takes tens of seconds, because every turn sends
  the agent's ~19,500-token system prompt.
