---
name: agent-toolkit-troubleshoot
description: Diagnose and fix Intel Agent Toolkit problems. Covers failed installs or teardowns (es_auto_installer.sh, Kubespray, kubeadm, preflight), unhealthy components (Agent Sandbox, Kata, OpenShell, Redis, pgvector, KubeRay, Keycloak realm), LiteLLM errors (401, 403, 400 invalid model, 500 guardrail blocks, 413, timeouts), model pods Pending, OOMKilled or never Ready, mesh connection resets, and client access (DNS, proxy, self-signed CA, LiteLLM UI). Starts with the installer's validate command, a short set of read-only kubectl checks and the install log, then matches the symptom to a catalog of known failures with the exact check and fix. Use when anything in the stack fails or behaves unexpectedly.
---

# Troubleshoot Intel Agent Toolkit

Diagnose read-only first. In the references, fixes that change the cluster, a host or an env file are marked **(changes the cluster)**, and fixes that lose data are marked **(deletes data)**. Show the command and get the user's OK first, and explicit confirmation for data loss. Never print secret values.

## 1. Get the facts

1. Find `<root>`, `<env>` and the track (`AGENTS.md`).
2. Check health. From `<root>`, `./es_auto_installer.sh validate agent-toolkit --env <env>` checks each installed component. It changes nothing lasting, but it sends one test request through LiteLLM and, on NFS, creates and deletes a probe volume, so tell the user first. Then run these read-only checks, which cover what `validate` does not:
   ```bash
   kubectl get nodes; kubectl get pvc -A | grep -v Bound                 # nodes Ready, volumes Bound
   kubectl get pods -A --no-headers | awk '{split($3,a,"/"); if (!($4=="Completed" || ($4=="Running" && a[1]==a[2])) || $5+0>5) print}'   # not ready, or restarting
   kubectl get llminferenceservices -n llm-inference                     # models Ready, the guard model too (OVMS models: inferenceservices)
   kubectl get ns -L istio.io/dataplane-mode                              # which namespaces are in the mesh
   kubectl get authorizationpolicy litellm-ingress -n litellm -o jsonpath='{.spec.rules[*].from[*].source.namespaces}'
   kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'
   getent hosts litellm.<base_domain_name>                               # does this client resolve the gateway?
   ```
   Point kubectl at this environment first: `export KUBECONFIG=<root>/env/<env>/kubeconfig.yaml`. A `KUBECONFIG` inherited from the shell may point at another cluster. Then map what you see to the catalog:
   - pods not ready or restarting: that component's entries (`references/components.md`; for `llm-inference`, `litellm` and `langfuse`, `references/inference.md`)
   - a namespace missing from the mesh or from LiteLLM's list: `references/network.md`
   - no gateway address, or a name that does not resolve: NET-1
3. If an install or teardown failed, read the newest log, `<root>/env/<env>/logs/<action>-<target>-<timestamp>.log`. `references/install.md` "Read the log first" shows how to find the real error among the harmless ones.
4. Ask the user for the exact error text and what they ran, if you do not have it.

## 2. Match the symptom

| Area | Reference | IDs |
|---|---|---|
| Install, Kubespray, preflight, teardown, multi-node | `references/install.md` | INS-* |
| Agent Sandbox, Kata, OpenShell, Redis, pgvector, KubeRay, Keycloak realm | `references/components.md` | SBX, KATA, OSH, RDS, PGV, RAY, KCR |
| LiteLLM errors, guardrail, routers, models | `references/inference.md` | LLM, GRD, MOD |
| Reaching the stack from a client; mesh resets inside the cluster | `references/network.md` | NET-* |
| A page in `docs/` that gave wrong instructions | `references/known-doc-errors.md` | |

Search the references for the exact error text first, for example `grep -rn 'too many open files' references/`. Entries quote messages as the user sees them.

## 3. The most common problems

| Symptom | Cause | Entry |
|---|---|---|
| Preflight `No internet connectivity`, or kubectl `Forbidden` | Proxy not set in `global_config.yaml`, or `no_proxy` too narrow | INS-2, NET-2 |
| Model pod Pending, or the install fails at the default model | The default install needs about 131 GiB of memory | INS-13 |
| `The connection to the server localhost:8080 was refused` | `KUBECONFIG` not exported | NET-3 |
| Re-install fails with `secrets is forbidden` at `kubeadm token create` | Half-built cluster from an earlier failure | INS-7 |
| LiteLLM 400, 401, 403 or 429 about a key | Over budget, expired, model not allowed, or invalid key; read `error.type` in the body | LLM-1 |
| `kubeadm init` times out after about 16 minutes | No systemd-resolved on the host | INS-6 |
| `https://litellm.<domain>` does not open | DNS or hosts entry, proxy, self-signed CA, or the UI URL | NET-1, LLM-7 |
| HTTP 500 `Blocked by the content-safety guardrail: ...` | Usually a correct block; or the guard model is not Ready | GRD-1, GRD-2 |
| Agent gets connection reset, or the sandbox SDK fails with 401 or 403 | Namespace not in the mesh or not allowed; router token; RBAC | NET table, SBX-5, SBX-6 |
| Docker images on the node are gone | Kubespray removes Docker | INS-4 |
| Multi-node: Kata fails on workers, or preflight FAILs | `ansible_connection` missing, or time not in sync | INS-21, INS-22 |

## 4. Fix, then confirm

- Apply the smallest fix in the entry. Re-run the failed command (`install` resumes where it can), then run the checks in step 1 again.
- When the code and `docs/` disagree, trust the code (`roles/`, `config.yaml`, `components.yaml`) and name the wrong doc page to the user.
- If nothing matches, collect the following for an issue report:
  - the output of the step 1 checks
  - the failing task and error from the log
  - `kubectl describe` of the failing pod
  - the revisions from the agent-toolkit-install skill (`references/lifecycle.md`, "Record for support")
