# Stack Validation & Preflight Checks

Post-deploy health check and pre-install node readiness validation for the
Intel® AI for Enterprise Agent Toolkit. Produces a consolidated traffic-light
report (GREEN / AMBER / RED) covering every deployed layer — from kernel
settings to end-to-end inference.

> **Topology-aware:** Reads `rack-scale-flags.env` and `env/<name>/global_config.yaml`, `config.inference.yaml` and `config.agent-toolkit.yaml` to
> gate checks. Layers for components that are not deployed are skipped cleanly,
> not reported as failures. Works on both single-node and rack-scale deployments.

---

## Table of Contents

- [Overview](#overview)
- [Preflight Check — Pre-Install](#preflight-check--pre-install)
- [Validate Stack — Post-Deploy](#validate-stack--post-deploy)
- [Validation Layers](#validation-layers)
- [Burn Tests](#burn-tests)
- [Reports](#reports)
- [Integration with fresh-install.sh](#integration-with-fresh-installsh)
- [Customizing Thresholds](#customizing-thresholds)
- [Troubleshooting](#troubleshooting)

---

## Overview

The validation framework consists of two playbooks:

| Playbook | When | Purpose |
|---|---|---|
| `preflight-check.yml` | Before deployment | Validates node readiness — catches issues that would waste 30+ minutes in kubespray |
| `validate-stack.yml` | After deployment | Validates every deployed layer end-to-end, renders health report |

Both write results to the same cumulative report, giving the operator a single
unified health view across the entire deployment lifecycle.

---

## Preflight Check — Pre-Install

Validates node readiness **before** deployment begins.

**Hard stops** (exit non-zero): NTP out of sync, swap enabled, disk < 10% free,
DNS resolution failure, gateway unreachable.

**Warnings** (report only): CPU governor not `performance`, THP=`always`.

**Informational**: kernel/OS version, kubelet version, NUMA topology, NIC MTU/speed.

### Run standalone

```bash
ansible-playbook -i core/inventory/hosts.yaml core/playbooks/preflight-check.yml
```

> **Note:** not available in this release.

---

## Validate Stack — Post-Deploy

Validates every deployed layer and generates a consolidated health report.

Three result states:
- **GREEN (OK)** — verified working with evidence
- **AMBER (PENDING)** — expected transitional state (e.g., model still loading)
- **RED (FAIL)** — unexpected failure, needs attention

Exit code: `0` if no RED results (AMBER counts as pass), non-zero on any RED.

### Run all checks

```bash
./es_auto_installer.sh validate agent-toolkit
```

### Run a single layer

```bash
./es_auto_installer.sh validate platform --only
```

### Run with extended burn (opt-in)

```bash
ansible-playbook -i core/inventory/hosts.yaml core/playbooks/validate-stack.yml \
  --tags all,extended-burn -e burn_duration=10m
```

> **Note:** not available in this release.

---

## Validation Layers

Each layer maps to an Ansible tag and a separate task file under
`core/playbooks/validate-stack/`.

### Cluster-level checks (Play 1 — runs on localhost)

| Layer | Tag | What it checks | Gated by |
|---|---|---|---|
| End-to-end inference | `e2e` | Model serving via GenAI Gateway — sends a real inference request and validates the response | `auth_provider: "litellm"` |
| Kubernetes | `kubernetes` | API server, etcd, CoreDNS, node readiness, system pods | Always |
| Storage | `storage` | Ceph health, OSD status, pool configuration, PVC binding | `storage_backend: ceph` |
| AI Stack services | `ai-stack` | LiteLLM, Redis, pgvector, Langfuse, Grafana pod/service status | `auth_provider: "litellm"` |
| Inter-component wiring | `wiring` | Service connectivity between components — LiteLLM→vLLM, Gateway→Redis, etc. | `auth_provider: "litellm"` |
| GPU | `gpu` | GPU operator, device plugin, nvidia-smi / xpu-smi output, resource allocation | `rack_scale_gpu_vendor` set. **Note:** not available in this release. |
| KubeRay | `kuberay` | Ray operator, head node, worker pods, dashboard accessibility | `kuberay_enabled: true` |
| Agent Sandbox | `sandbox` | Sandbox controller, template and warmpool pod status | `agent_sandbox_enabled: true` |
| Flowise | `flowise` | Flowise deployment, service, and UI accessibility | `deploy_agenticai_plugin=on`. **Note:** not available in this release. |

### Host-level checks (Play 2 — runs on every node)

| Layer | Tag | What it checks | Gated by |
|---|---|---|---|
| Fabric | `fabric` | NIC link speed, MTU, BGP peering (Clos), latency between peers | `rack_scale_mode=on`. **Note:** not available in this release. |
| Network | `network` | Basic connectivity, DNS resolution, gateway reachability | Always |
| Proxy | `proxy` | HTTP/HTTPS proxy configuration, no_proxy correctness | Always |
| Platform health | `platform` | Kernel version, CPU governor, NUMA, THP, swap, disk space | Always |
| Quick burn | `burn` | Sustained throughput validation — catches thermal throttling, ECMP imbalance | Always |
| Extended burn | `extended-burn` | Longer-duration stress test for acceptance/pre-production sign-off | Opt-in only |

---

## Burn Tests

### Quick burn (mandatory, ~2-3 min)

Runs automatically as part of `validate-stack.yml`. Validates:
- Fabric link speed against expected thresholds
- NIC latency between peer nodes
- Storage I/O baseline (when Ceph is deployed)

### Extended burn (opt-in)

For acceptance testing, pre-production sign-off, or periodic validation. Runs
the same checks as quick burn but with configurable duration:

```bash
ansible-playbook -i core/inventory/hosts.yaml core/playbooks/validate-stack.yml \
  --tags all,extended-burn \
  -e burn_duration=10m
```

> **Note:** not available in this release.

---

## Reports

Validate-stack produces two report formats:

| Format | Location | Description |
|---|---|---|
| JSON | `core/inventory/metadata/health-report-latest.json` | Machine-readable, cumulative — each run replaces its layers, preserves others |
| HTML | `core/inventory/metadata/health-report-latest.html` | Visual traffic-light dashboard, served from the same directory |

> **Note:** not available in this release.

Timestamped archives are also written (e.g., `health-report-20260910-143022.json`)
so you can compare reports across runs.

The terminal output includes:
- A colour-coded traffic-light summary (GREEN/AMBER/RED per layer)
- Discovered endpoints (GenAI Gateway, Langfuse, Grafana, Flowise, Ray)
- A quick-start `curl` command for testing inference

---

## Integration with fresh-install.sh

When running a full deployment via `es_auto_installer.sh`, only the
**preflight check** runs automatically — before kubespray, if
`preflight-check.yml` exists and `--skip-check` is not set.

> **Note:** not available in this release.

Post-deploy validation (`validate-stack.yml`) is **not** run by the deployment.
Run it manually once the deployment has finished, as shown in
[Validate Stack — Post-Deploy](#validate-stack--post-deploy).

---

## Customizing Thresholds

Override default burn-test thresholds with extra vars:

```bash
ansible-playbook -i core/inventory/hosts.yaml core/playbooks/validate-stack.yml \
  -e burn_fabric_floor_gbps=40 \
  -e burn_storage_seq_write_gbps=2 \
  -e burn_gpu_temp_ceil=80
```

> **Note:** not available in this release.

| Variable | Default | Description |
|---|---|---|
| `burn_fabric_floor_gbps` | 20 | Minimum fabric throughput (Gbps) |
| `burn_pod_net_floor_pct` | 70 | Pod network throughput as % of fabric |
| `burn_storage_seq_write_gbps` | 1 | Minimum sequential write throughput (Gbps) |
| `burn_storage_iops_floor` | 20000 | Minimum random IOPS |
| `burn_gpu_temp_ceil` | 85 | Maximum GPU temperature (°C) |
| `burn_gpu_util_floor` | 95 | Minimum GPU utilization (%) |
| `burn_duration` | 2m | Duration for extended burn test |

---

## Troubleshooting

### Preflight fails on NTP sync

Ensure `chronyd` or `ntpd` is running and synchronized on all nodes:
```bash
ansible -i env/<name>/inventory/hosts.yaml all -b -m shell -a "chronyc tracking || ntpq -p"
```

### AMBER results for model loading

AMBER is expected during initial model loading (can take 5-15 minutes for large
models). Re-run validation after models are fully loaded:
```bash
./es_auto_installer.sh validate inference
```

### Silent checkpoints not producing output

Silent checkpoints (`_silent_checkpoint=true`) suppress terminal output by
design. Results are written to the cumulative JSON report. Check:
```bash
cat core/inventory/metadata/health-report-latest.json | python3 -m json.tool | head -20
```

> **Note:** not available in this release.

### Fabric checks skipped on single-node

Fabric layer checks only run when `rack_scale_mode=on`. This is expected
for single-node deployments.

> **Note:** not available in this release.
