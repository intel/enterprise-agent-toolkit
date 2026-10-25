<!-- Copyright (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Claw: persistent OpenClaw agents

Claw runs [OpenClaw](https://github.com/openclaw/openclaw) agents as long-lived Kubernetes
workloads on the Agent Toolkit, answered by the models the inference layer serves. It is
off by default (`claw_enabled: false`).

This is the reference for platform operators: what claw installs, how to enable and
configure it, and its security model. To check an install step by step, with the expected
output, follow [claw-e2e.md](claw-e2e.md).

**Contents:** [Components](#components) · [Enable](#enable) ·
[Run an OpenClaw instance](#run-an-openclaw-instance) · [Configuration](#configuration) ·
[Security](#security) · [Validate and remove](#validate-and-remove) ·
[Troubleshooting](#troubleshooting) · [Limitations](#limitations)

---

## Components

| Component | What it installs | Namespace |
|---|---|---|
| `openclaw_operator` | The upstream [OpenClaw operator](https://github.com/paperclipinc/openclaw-operator) `0.38.3`: CRDs `OpenClawInstance`, `OpenClawClusterDefaults`, `OpenClawSelfConfig`, and the controller | `openclaw-operator-system` |

The operator turns each `OpenClawInstance` into a StatefulSet with a persistent volume, a
Service on port `18789` (the OpenClaw gateway), a gateway token Secret and a NetworkPolicy.

---

## Enable

Claw needs the inference layer, because agents call its `ai-gateway` for model answers.
Install the toolkit first ([single-node deployment](single-node-deployment.md)), then turn
claw on in your environment's copy of the layer config, not in this repository:

```yaml
# env/<env>/config.agent-toolkit.yaml
claw_enabled: true
```

Install only the operator:

```bash
./es_auto_installer.sh install openclaw_operator --only --env <env>
```

Or include it in a full layer install: `./es_auto_installer.sh install agent-toolkit --env <env>`.

---

## Run an OpenClaw instance

[`examples/openclaw-instance.yaml`](examples/openclaw-instance.yaml) is a complete,
working instance. It creates the namespace `claw-demo` and one `OpenClawInstance` that:

- runs the pinned OpenClaw image (`2026.7.1-1`, by digest) under the `restricted` Pod
  Security Standard;
- uses the in-cluster inference gateway,
  `http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1`, and the model
  `qwen2-5-coder-14b` with its served context window (32768 tokens);
- joins the ambient mesh, which the platform requires for in-cluster traffic;
- adds one egress rule to the operator's network policy, for the gateway pods;
- shows, commented out, how to place the agent on particular nodes by node label
  (`availability.nodeSelector`, `affinity`, `tolerations`).

Run from the root of your AI Solutions checkout:

```bash
kubectl apply -f ext/enterprise.agent-toolkit/docs/examples/openclaw-instance.yaml
kubectl -n claw-demo wait openclawinstance/demo --for=jsonpath='{.status.phase}'=Running --timeout=10m
```

The step-by-step walkthrough, including a chat request, is in
[claw-e2e.md](claw-e2e.md#run-an-openclaw-instance).

To use another model, change the provider's `models[].id` and `agents.defaults.model.primary`,
and set `contextWindow` to that model's served `max_model_len`. OpenClaw's system prompt
and tool definitions take about 19,500 tokens per turn, so the model needs a context window
well above that. Keep `compaction.reserveTokens` small enough that
`contextWindow - reserveTokens` stays above that prompt; otherwise OpenClaw summarises the
conversation after every turn, which costs one extra model call each time.

**Response time.** Each turn sends the full agent prompt to the model, so the first word
waits until the model has read it; how long that takes depends on the model and the
hardware. Send `"stream": true` to see the answer arrive.

---

## Configuration

Set these in `env/<env>/config.agent-toolkit.yaml`. Every other value has a working
default in [`roles/openclaw_operator/defaults/main.yaml`](../roles/openclaw_operator/defaults/main.yaml).

| Variable | Default | Meaning |
|---|---|---|
| `claw_enabled` | `false` | Turns claw on |
| `openclaw_operator_version` | `0.38.3` | Operator release. Checked against what the chart digest resolves to |
| `openclaw_operator_digest` | `sha256:a5c71a40…` | Digest of the operator Helm chart. The chart is installed by this digest |
| `openclaw_operator_image_digest` | `sha256:ca7ad419…` | Digest of the operator container image |
| `openclaw_operator_cosign_required` | `false` | `true` makes the signature check mandatory (fails when `cosign` is missing) |

To move to another operator release, change the version and both digests together. The
defaults file shows how to read the digests.

---

## Security

- **Pinned by digest.** The operator chart and image are third-party artifacts, and OCI tags
  are mutable. The installer installs the chart by digest, pins the image digest, and fails
  if the digest and the configured version disagree.
- **Signature check.** When `cosign` is on the installer host's `PATH`, the installer verifies
  the keyless signatures of the chart and the image against the upstream release workflow
  (`paperclipinc/openclaw-operator`, `release.yaml` at the release tag). A signature that does
  not verify stops the install.
- **Namespace hardening.** With `enforce_pss: true` the operator namespace enforces the
  `restricted` Pod Security Standard. With `istio_enabled: true` it joins the ambient mesh,
  like the platform namespaces.
- **Instance network policy.** Each instance gets a default-deny NetworkPolicy from the
  operator: egress to DNS and HTTPS (`443`) only. The example adds one rule for the
  inference gateway pods. Inside the ambient mesh, pod-to-pod traffic is carried on the
  HBONE port `15008`, so an egress rule to a mesh workload names port `15008`, not the
  workload's own port. A connection that is already open survives a tightened policy;
  restart the pod to apply a stricter one.
- **Gateway token.** The operator generates a random token per instance, in the Secret
  `<instance>-gateway-token`. Requests without it get `401`.
- **Process isolation.** The example sets `shareProcessNamespace: false`. The CRD defaults
  it to `true`, which would let containers running as the same user read each other's
  environment, including credentials.

---

## Validate and remove

```bash
./es_auto_installer.sh validate openclaw_operator --only --env <env>
./es_auto_installer.sh teardown openclaw_operator --only --env <env> --force
```

`validate` is read-only. It checks the release version, the three CRDs, that the controller
is available, and that the running image is the pinned digest.

`teardown` deletes every `OpenClawInstance` first (while the operator can still process its
finalizers), then the chart, the CRDs, and the namespace. It succeeds when nothing is
installed.

Instance volumes are kept: `spec.storage.persistence.orphan` defaults to `true`, so an
agent's files outlive its `OpenClawInstance`. Delete the instance's namespace to remove
them.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `install` skips `openclaw_operator` | `claw_enabled` is not `true` in `env/<env>/config.agent-toolkit.yaml` | Set it there; edits to this repository's `config.yaml` are not read after `init` |
| `openclaw_operator_digest is chart version …, but openclaw_operator_version is …` | The version was changed without the digests. The install stops before changing anything | Change the version and both digests together |
| `cosign verify` fails | The artifact at that digest is not signed by the upstream release workflow | Do not override; re-check the pinned digests |
| Chat answers `Context overflow`; the `openclaw` log shows `rawError=413 Payload Too Large` | The inference gateway's request buffer is too small for agent requests | See [Limitations](#limitations) |
| Model calls fail with `Connection reset by peer` | The instance namespace is not in the ambient mesh | Label it `istio.io/dataplane-mode=ambient` |

More symptoms are listed in [claw-e2e.md](claw-e2e.md#if-it-does-not-work).

---

## Limitations

- Instances are created by hand from a manifest; each one is managed individually with
  `kubectl`.
- The instance's gateway is reachable only through `kubectl port-forward`.
- **Inference gateway request size.** The inference layer's `ai-gateway` must accept request
  bodies larger than Envoy's 32 KiB default; an agent request is about 65 KB. An
  inference layer that sets `ai_gateway_buffer_limit` (a `ClientTrafficPolicy` with
  `bufferLimit` on the `ai-gateway` Gateway) is required. On an inference layer without it,
  apply the same policy by hand:

  ```yaml
  apiVersion: gateway.envoyproxy.io/v1alpha1
  kind: ClientTrafficPolicy
  metadata:
    name: ai-gateway
    namespace: llm-inference
  spec:
    targetRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: ai-gateway
    connection:
      bufferLimit: 50Mi
  ```
