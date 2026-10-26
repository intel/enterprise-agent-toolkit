# Stack Validation & Preflight Checks

Pre-install node readiness and post-deploy health checks for the
Intel® AI for Enterprise Agent Toolkit.

---

## Table of Contents

- [Overview](#overview)
- [Preflight Check — Pre-Install](#preflight-check--pre-install)
- [Validate Stack — Post-Deploy](#validate-stack--post-deploy)
- [What validate checks](#what-validate-checks)
- [Troubleshooting](#troubleshooting)

---

## Overview

| Check | When | Command | Output |
|---|---|---|---|
| Preflight | At the start of `./es_auto_installer.sh install`; standalone at any time | `ext/enterprise.agent-toolkit/playbooks/preflight-check.yml` | Report in `env/<name>/logs/health-report-latest.{json,html}` plus a terminal summary |
| Validate | After the install | `./es_auto_installer.sh validate <layer>` | Per-component checks in the run output; any failure stops the run with its reason |

Components that are not enabled are skipped, not reported as failures.

---

## Preflight Check — Pre-Install

Checks node readiness on every host in the inventory. It only reports: no result stops the install.

| Status | Checks | Meaning |
|---|---|---|
| **FAIL** | Time sync, swap in use, root and containerd disk < 10% free, external DNS, gateway reachable | Fix these; they are also listed in the `PREFLIGHT WARNING` block |
| **WARN** | CPU governor not `performance`, THP=`always`, Hugging Face token invalid | Tuning or model access; the install works |
| **PENDING** | Node resource pressure before the cluster exists; Hugging Face token not set | Checked on a later run: after the install, or with `HF_TOKEN` exported |
| **OK** | Kernel and OS version, kubelet version (`not installed` before the cluster exists), NUMA topology | Informational, recorded in the report |

Example, on a node with the CPU governor on `powersave`:

```text
  Network connectivity                  [ OK ]  (reachable via ICMP ping <gateway>)
  Platform health                       [ WARN ] governor=powersave freq=3343MHz max=3900MHz
  WARNING: [platform-health] CPU governor on node1
          Hint: Set performance: cpupower frequency-set -g performance
  RESULT: 2 layers — 1 PASSED, 1 WARNING
```

### Runs with the install

In an env inited for `agent-toolkit`, `./es_auto_installer.sh install` runs the preflight first: on a new cluster before Kubespray, otherwise before the components.
Runs with `--only` skip it. To turn it off, set `node_preflight_enabled: false` in `env/<name>/config.agent-toolkit.yaml`.
The checks are capped at 5 minutes; past that the install continues. The run output is saved to `env/<name>/logs/preflight-check.log`.

### Run standalone

From the `enterprise-ai-solutions` checkout, after `init agent-toolkit`. For multi-node, list the nodes in `env/<name>/inventory/hosts.yaml` first ([Multi-Node Deployment, Step 1](multi-node-deployment.md#step-1--configure-hostsyaml)):

```bash
export HF_TOKEN=<token>   # optional: also checks the token for gated models
.venv/bin/ansible-playbook -i env/<name>/inventory/hosts.yaml \
  ext/enterprise.agent-toolkit/playbooks/preflight-check.yml
```

Report: `env/<name>/logs/health-report-latest.json` and `.html`; a summary is printed at the end of the run.

---

## Validate Stack — Post-Deploy

`validate` runs the validate checks of every enabled component in the target and its dependencies; `--only` limits it to the target.
A healthy stack ends with `failed=0` in the run's recap.

### Run all checks

```bash
./es_auto_installer.sh validate agent-toolkit
```

### Run a single layer or component

```bash
./es_auto_installer.sh validate platform --only
./es_auto_installer.sh validate inference --only
./es_auto_installer.sh validate litellm --only
```

---

## What validate checks

| Layer | Component | Checks |
|---|---|---|
| Infrastructure | kubernetes | kubectl and kubeconfig, API server reachable, node readiness, server version |
| | storage (NFS, Ceph, Trident) | CSI driver and node plugin, StorageClass, exactly one default class; Ceph health and OSDs |
| | kata_containers | kata-deploy rollout, requested RuntimeClasses |
| Platform | cert-manager, MetalLB, Envoy Gateway | Releases, controllers ready, IP pool, GatewayClass and Gateway accepted, TLS secret |
| | Istio | istiod, ztunnel on every node, mesh-wide mTLS |
| | PostgreSQL, SeaweedFS | Database cluster ready, S3 gateway ready |
| | observability | Prometheus Operator, Grafana, Node Exporter, Loki, Tempo, OTel Collector |
| | NRI balloons, NFD | Policy and DaemonSet ready, CPU feature labels on nodes |
| | Keycloak (when enabled) | Operator and instances ready |
| Inference | KServe, model services | CRDs and controllers, serving runtimes, deployed models, CPU policy |
| | LiteLLM | Deployment ready, readiness endpoint, master key; a request through the content-safety guardrail and a chat request through LiteLLM |
| | Langfuse, vLLM Semantic Router | Web and worker deployments; router and dashboard routed |
| Agent toolkit | Redis Stack, pgvector | Pods, Redis PING and RediSearch, pgvector extension and credentials |
| | Agent Sandbox | Controller, router, CRDs, templates, warm pools (and the Kata template) |
| | OpenShell, KubeRay | Gateway ready; operator and head pod |

Not in this release: burn tests, the proxy checks and a post-deploy report file. Node-level checks (time sync, disk, swap, CPU governor, THP, DNS, gateway) are in the [preflight](#preflight-check--pre-install).

---

## Troubleshooting

### Preflight fails on NTP sync

Ensure `chronyd` or `systemd-timesyncd` is running and synchronized on all nodes:
```bash
.venv/bin/ansible -i env/<name>/inventory/hosts.yaml all -b -m shell -a "timedatectl status | grep synchronized"
```

### A model is still loading

Large models can take 5-15 minutes to load. Re-run validation once they are Ready:
```bash
kubectl get llminferenceservices,inferenceservices -n llm-inference
./es_auto_installer.sh validate inference
```
