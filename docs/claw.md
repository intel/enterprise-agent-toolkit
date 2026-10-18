<!-- Copyright (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Claw: persistent OpenClaw agents

Claw runs [OpenClaw](https://github.com/openclaw/openclaw) agents as long-lived Kubernetes
workloads on the Agent Toolkit, answered by the models the inference layer serves. It is
off by default (`claw_enabled: false`).

**Contents:** [Components](#components) · [Enable](#enable) · [Create an agent](#create-an-agent) ·
[Run an OpenClaw instance directly](#run-an-openclaw-instance-directly) ·
[Configuration](#configuration) · [Security](#security) · [Validate and remove](#validate-and-remove) ·
[Troubleshooting](#troubleshooting) · [Limitations](#limitations)

---

## Components

| Component | What it installs | Namespace |
|---|---|---|
| `openclaw_operator` | The upstream [OpenClaw operator](https://github.com/paperclipinc/openclaw-operator) `0.38.3`: CRDs `OpenClawInstance`, `OpenClawClusterDefaults`, `OpenClawSelfConfig`, and its controller | `openclaw-operator-system` |
| `agent_operator` | The `Agent` CRD (`intel-stack.io/v1alpha1`) and the agent operator, which turns each `Agent` into an isolated OpenClaw agent | `agent-operator-system` |

For every `Agent`, the agent operator creates:

- a namespace `agent-<username>-<name>` that enforces the `restricted` Pod Security Standard
  and joins the ambient mesh;
- a default-deny NetworkPolicy, a ResourceQuota and a LimitRange;
- a Keycloak client `agent-<username>-<name>` in the agent realm;
- a gateway token Secret and an `OpenClawInstance`, which the OpenClaw operator runs as a pod
  with a persistent volume;
- the workspace files listed in `spec.workspace`.

The operator image is built from this repository during install and pushed to the cluster's
image registry.

---

## Enable

Claw needs:

- the inference layer and a default model (`llm_services_autodeploy_models`);
- Keycloak (`auth_provider: keycloak`, the default);
- the cluster image registry (`kubernetes_registry_enabled: true`, set before the cluster is
  installed; the toolkit's default).

Install the toolkit first ([single-node deployment](single-node-deployment.md)), then turn
claw on in your environment's copy of the layer config, not in this repository:

```yaml
# env/<env>/config.agent-toolkit.yaml
claw_enabled: true
```

```bash
./es_auto_installer.sh install agent_operator --env <env>
```

This also installs `openclaw_operator`, which `agent_operator` depends on. A full layer install
(`install agent-toolkit`) includes both.

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
| `skills` | OpenClaw capabilities, for example `shell`, `read_file`, `list_files` |
| `workspace` | Files seeded into the agent's workspace, keyed by relative path |
| `model` | Per-agent model override (`provider`, `id`, `name`, `baseUrl`) |
| `modelSecretRef` | Secret in the agent namespace with key `apiKey`, for an overridden model |
| `toolsDeny` | Tool names or globs the agent may not call |

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
- **Identity.** Each agent gets its own Keycloak client. The operator manages clients with a
  service account that holds only `manage-clients` in the agent realm, and never hands out a
  client recorded as another owner's.
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
./es_auto_installer.sh validate agent_operator --only --env <env>
./es_auto_installer.sh teardown agent_operator --only --env <env> --force
./es_auto_installer.sh teardown openclaw_operator --only --env <env> --force
```

`validate` is read-only. `teardown agent_operator` deletes every `Agent` first, while the
operator can still clean each one up (namespace, Keycloak client, Secrets), then the operator,
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
| `openclaw_operator_digest is chart version …` | The OpenClaw operator version changed without its digests | Change the version and both digests together |

More symptoms are listed in [claw-e2e.md](claw-e2e.md#if-it-does-not-work).

---

## Limitations

- Agents and their gateways are reachable only through `kubectl` (including `port-forward`).
- On CPU inference the first token of each turn takes tens of seconds, because every turn sends
  the agent's ~19,500-token system prompt.
