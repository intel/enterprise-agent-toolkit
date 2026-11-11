# Toolkit component failures

Each entry: what you see, why it happens, how to confirm it (read-only), and the fix. Fixes that change the cluster, a host or an env file are marked **(changes the cluster)**; fixes that lose data are marked **(deletes data)**. Ask the user before running them, and get explicit confirmation for data loss.

`--only` re-runs a single component without its dependencies. Run the installer from the Toolkit Manager root: `./es_auto_installer.sh install <component> --only --env <env>`.

Install output lines like `FAILED - RETRYING: ... Wait for ... (N retries left)` are polling, not failures. Look at the final `fatal:` line.

## Agent Sandbox (`agent-sandbox-system`)

### SBX-1 Install stops at `Wait for Agent Sandbox pods to be ready`
- **Why:** the task waits for **every** pod in `agent-sandbox-system`, not only the controller. One stuck pod is enough: a Kata pool pod, an image pull, or a user's claim that stays Pending.
- **Check:** `kubectl get pods -n agent-sandbox-system`, then `kubectl describe pod -n agent-sandbox-system <pod> | tail -20`.
- **Fix:** follow the pod's events. Kata pods: KATA-1 to KATA-3. Image pulls: registry access or proxy.

### SBX-2 Install fails at `Apply core manifest`, `Apply extensions manifest` or `Download sandbox-router manifest`
- **Why:** these are fetched from github.com and raw.githubusercontent.com when the install runs. A blocked proxy, no internet, or GitHub rate limiting (HTTP 429) breaks them.
- **Check:** from the installer host, `curl -sI https://github.com` and `curl -sI https://raw.githubusercontent.com`.
- **Fix:** fix the proxy settings in `env/<env>/global_config.yaml`, or re-run later after a 429 **(changes the cluster)**. Air-gapped sites must mirror the manifests and override `agent_sandbox_core_manifest_url`, `agent_sandbox_extensions_manifest_url` and `agent_sandbox_router_manifest_url`, plus `agent_sandbox_router_image` and `agent_sandbox_python_runtime_image`, in `env/<env>/config.agent-toolkit.yaml`. The controller image is set inside the core manifest, so the mirrored manifest must point at the mirrored image.

### SBX-3 `agent_sandbox_version` was raised but the router still runs the old manifest
- **Why:** the router manifest is cached at `/tmp/agent-sandbox-router.yaml` on the installer host and is not downloaded again when the file exists.
- **Check:** `ls -l /tmp/agent-sandbox-router.yaml` (an old date means a stale copy).
- **Fix:** delete the file, then `install agent_sandbox --only` **(changes the cluster)**.

### SBX-4 SDK `TimeoutError("Could not resolve sandbox name from claim ... within 180 seconds.")`, `SandboxWarmPoolNotFoundError`, or 403 `... in the namespace "default"`
- **Why:** the SDK looked in the wrong namespace (its default is `"default"`), the warm pool name is wrong, or the pool has no ready pods. The 403 in `default` is a namespace mistake, not missing RBAC. (`Sandbox resolution exceeded the ready timeout.` is rarer: the claim resolved but the sandbox did not become ready in time; see SBX-1.)
- **Check:** `kubectl get sandboxwarmpool -n agent-sandbox-system`; `kubectl get sandboxclaim -A`.
- **Fix:** pass `namespace="agent-sandbox-system"` and `warmpool="python-pool"` (or `"kata-pool"`).

### SBX-5 SDK or API `403 ... cannot create resource "sandboxclaims"`
- **Why:** Kubernetes RBAC. The SDK creates claims with the caller's own credentials, so an agent pod needs a Role.
- **Check:** `kubectl auth can-i create sandboxclaims.extensions.agents.x-k8s.io -n agent-sandbox-system --as=system:serviceaccount:<ns>:<sa>`
- **Fix:** apply the Role and RoleBinding from the agent-toolkit-components skill (`references/sandbox.md`) **(changes the cluster)**.

### SBX-6 HTTP 401 from the router, or `SandboxRequestError: Failed to communicate with the sandbox at .../execute`
- **Why:** the SDK raises `SandboxRequestError` for any failed request. Look at the exception's `status_code`:
  - `401`: a missing or old router token. The token survives a re-run of install and changes only when Agent Sandbox is torn down and installed again.
  - None: a connection error (wrong `api_url`) or a timeout. `commands.run` defaults to 60 s.
  - 5xx or 404: the router or the sandbox pod failed (SBX-1).
- **Check:** `kubectl get secret sandbox-router-auth -n agent-sandbox-system` (exists?), and whether the agent reads it from a copy made before the last reinstall.
- **Fix (401):** set `sandbox.connector.session.headers["Authorization"] = f"Bearer {token}"` with the current `ROUTER_AUTH_TOKEN`. Copy the Secret again if the agent uses a copy **(changes the cluster)**. Re-running install does not change the token.

### SBX-7 Code in a sandbox cannot reach LiteLLM, Redis, an internal mirror or any private address (timeout)
- **Why:** by design. Sandbox egress allows public IPs only, and DNS is public resolvers only. Behind a proxy-only network, sandboxes have no egress at all.
- **Check:** `kubectl get networkpolicy eat-sandbox-pool-egress -n agent-sandbox-system -o yaml`
- **Fix:** do not open it up. Pass data through the SDK, or use OpenShell for egress controlled by policy.

### SBX-8 A custom SandboxTemplate's pods escape the egress rules
- **Why:** the template lacks the pod label `istio.io/dataplane-mode: none`. The pod joins the mesh, and ambient traffic is not subject to the NetworkPolicy.
- **Fix:** add the label to the template's pod metadata, as both shipped templates have **(changes the cluster)**.

### SBX-9 `kubectl get sandboxes` fails with a conversion webhook error
- **Why:** the PeerAuthentication `agent-sandbox-controller-webhook` (port 9443 PERMISSIVE) is missing or changed, so the API server cannot reach the webhook through the mesh.
- **Check:** `kubectl get peerauthentication -n agent-sandbox-system`
- **Fix:** `install agent_sandbox --only` **(changes the cluster)**.

### SBX-10 `kubectl get --raw /api/v1/namespaces/agent-sandbox-system/services/sandbox-router-svc:8080/proxy/...` fails with `ServiceUnavailable`
- **Why:** the namespace is meshed; the API server proxy cannot speak mTLS to it.
- **Fix:** use `kubectl port-forward -n agent-sandbox-system svc/sandbox-router-svc 8080:8080`.

## Kata Containers (infrastructure component, switches in `global_config.yaml`)

### KATA-1 Install stops with a Kata host check
| Message (start) | Fix |
|---|---|
| `kata_containers_enabled is set, but this is a BYO cluster (existing_kubernetes)` | Kata is supported only on clusters the installer builds. |
| `kata_runtime='<x>' is not valid` | Use `kata-fc`, `kata-qemu` or `both`. |
| `... no cluster node exposes /dev/kvm` | Enable virtualisation (VT-x) in the BIOS, or nested virtualisation on a VM. |
| `/dev/vhost-vsock is missing on: ...` | `sudo modprobe vhost_vsock` on those nodes. |
| `kata-fc (Firecracker) cannot start microVMs on these AMX-capable nodes ... requires Linux >= 5.17` | Upgrade the kernel, or use `kata_runtime: kata-qemu`. |
| `... needs Firecracker, but no node has containerd's devmapper snapshotter in 'ok' state` | See KATA-3. |

### KATA-2 Kata pool pod stuck `ContainerCreating` with `FailedCreatePodSandBox ... too many open files`
- **Why:** `fs.inotify.max_user_instances` is too low (128) on that node.
- **Check:** `sysctl fs.inotify.max_user_instances` on the node; `kubectl get events -A --field-selector reason=FailedCreatePodSandBox`.
- **Fix:** raise `fs.inotify.max_user_instances` and `fs.inotify.max_user_watches` on every node, as `docs/prerequisites.md` describes **(changes the cluster)**. A plain re-run of the install has also cleared it once.

### KATA-3 `FailedCreatePodSandBox ... snapshotter devmapper was not found` on a worker (kata-fc)
- **Why:** the node's tasks ran on the installer host instead, because the node has no `ansible_connection` in the inventory. The worker never got the devmapper thin-pool.
- **Check:** `grep -n ansible_connection env/<env>/inventory/hosts.yaml`. On the node: `sudo ctr plugins ls | grep devmapper` (should be `ok`).
- **Fix:** add `ansible_connection: ssh` to every remote node (`local` for the installer host), then re-run the install **(changes the cluster)**.

### KATA-4 After `teardown kubernetes`, the next Kata install fails on leftovers
- **You see:** `/opt/kata`, `nydus-for-kata-tee.service` or `containerd-devmapper.service` still present, or a thin-pool on deleted loop files.
- **Check:** `ls /opt/kata; systemctl list-units | grep -E 'kata|devmapper'; sudo dmsetup ls`
- **Fix:** check whether your Toolkit Manager version purges Kata on teardown (`grep -n kata roles/kubernetes/tasks/teardown.yaml` in the Toolkit Manager checkout). If it does not, remove the leftovers by hand before reinstalling **(changes the cluster)**.

Info: the Kata Helm release gets a new revision on every run. That is harmless.

## OpenShell (`openshell-system`, `openshell-sandboxes`)

### OSH-1 Install fails at the CRD check
- **Why:** OpenShell needs the Agent Sandbox CRDs (`sandboxes.agents.x-k8s.io`, version `v1beta1`).
- **Fix:** set `agent_sandbox_enabled: true` and install both **(changes the cluster)**.

### OSH-2 `kubectl port-forward to svc/openshell did not start:`
- **Check:** `kubectl get pods -n openshell-system` (gateway ready?), and whether the installing user may port-forward.

### OSH-3 `Gateway 'eat' already exists` during `Register profile and provider`
- **Why:** the installer keeps OpenShell CLI state per user in `~/.cache/eat/openshell-cli-<version>/`. Two installs at once from the same account, or manual CLI use in that directory, collide.
- **Fix:** run one install at a time per account, then re-run **(changes the cluster)**.

### OSH-4 `Error: × No active gateway. Set one with: openshell gateway select <name>`
- **Why:** your own CLI is not registered; the install's registration is private to the installer.
- **Fix:** connect as in the agent-toolkit-components skill (`references/openshell.md`, "Connect the CLI").

### OSH-5 LLM call fails with `policy_denied` or `binary ... not allowed in policy '_provider_genai_gateway'`
- **Why:** the program calling LiteLLM is not in the provider profile's `binaries` list.
- **Fix:** add its resolved path to `charts/openshell/genai-gateway-provider.yaml` in this repo and run `install openshell --only` **(changes the cluster)**.

### OSH-6 Sandbox LLM calls get 401 after the `openshell-sandboxes` key was revoked
- **Why:** the installer mints a key only when Secret `openshell-genai-key` is missing.
- **Fix:** `openshell provider delete genai-gateway`, `kubectl delete secret openshell-genai-key -n openshell-system`, then `install openshell --only` **(changes the cluster)**.

### OSH-7 Sandbox log shows `Policy fetch failed ... failed to connect to OpenShell server`
- **Why:** sandbox DNS is blocked by NetworkPolicy `eat-openshell-sandbox-pods` (unusual DNS setup).
- **Fix:** set `openshell_sandbox_dns_cidrs` to your DNS server addresses and re-run `install openshell --only` **(changes the cluster)**.

### OSH-8 Sandbox stuck in `Provisioning`
- **Check:** `kubectl get pods,pvc -n openshell-sandboxes`; `kubectl describe pod -n openshell-sandboxes <pod> | tail -20`. Normal time to Ready is under about a minute.
- **Fix:** a Pending PVC points at storage. NFS-backed workspaces are slow; the shipped default is `local-path`.

### OSH-9 `openshell logs <name> --source sandbox | grep DENIED` is empty although a request was blocked
- **Why:** the log lags.
- **Fix:** retry for about 30 seconds.

### OSH-10 `transport error`, `Connection reset by peer` or `ssh tar extract exited with status 255`
- **Why:** the `kubectl port-forward` stream dropped.
- **Fix:** restart the port-forward and retry.

### OSH-11 Helm ownership error about ClusterRole `openshell-node-reader` on a second install
- **Fix:** use a different `openshell_release_name` for the second install **(changes the cluster)**.

## Redis Stack (`redis`)

### RDS-1 `Redis Stack Helm install failed: <message>`
- **Check:** read the Helm message. `kubectl get pvc -n redis` (Pending means no default StorageClass).
- **Fix:** set `redis_stack_storage_class`, or fix image pulls, then re-run **(changes the cluster)**. A failed release is removed automatically on the next run.

### RDS-2 Client `WRONGPASS invalid username-password pair`
- **Why:** usually the password changed when Redis was torn down and reinstalled. Some clients also fail when the URL has an empty username; the stored URL uses `default:`.
- **Fix:** use `REDIS_URL` from the current Secret.

### RDS-3 Changing `redis_stack_persistence_size` fails with `updates to statefulset spec for fields other than ... are forbidden`
- **Why:** the volume claim template is fixed after the first install, and `local-path` volumes cannot grow.
- **Fix:** keep the size, or tear down Redis and reinstall **(deletes data)**.

### RDS-4 Data written since the last snapshot is gone after a Redis pod restart
- **Why:** append-only persistence is off, so writes since the last RDB snapshot are lost on restart (vector indexes too).
- **Fix:** avoid casual restarts; keep anything that must survive in pgvector.

## pgvector (`pgvector`)

### PGV-1 `pgvector Helm install failed: <message>`
- **Why:** usually a timeout on slow storage (first start can take about 5 minutes on NFS), or a Pending PVC.
- **Fix:** re-run **(changes the cluster)**; a failed release is removed first.

### PGV-2 Validate fails at `Check pgvector extension`, or `FATAL: role "<name>" does not exist`
- **Why:** `pgvector_username` or `pgvector_database` was changed after the first install.
- **Fix:** restore the original values, or tear down pgvector with the original values still set, then change them and reinstall **(deletes data)**.

### PGV-3 App error `expected 1536 dimensions, not N`
- **Why:** the tables created at install use `VECTOR(1536)`.
- **Fix:** create your own table with your embedding model's dimension.

## KubeRay (`ray-system`)

### RAY-1 Install stops at `Wait for Ray head pod` or `Wait for the Ray workers`
- **Why:** not enough CPU or memory (head 0.5 CPU / 2 GiB, each worker 0.5 CPU / 2 GiB), or the large `rayproject/ray` image is still pulling. A few retries are normal.
- **Check:** `kubectl get pods -n ray-system`; `kubectl describe pod -n ray-system <pod> | tail -20`.
- **Fix:** free capacity or lower the `kuberay_*` resource settings, then re-run **(changes the cluster)**.

### RAY-2 `kubectl scale raycluster ...` fails
- **Why:** RayCluster has no scale subresource; the autoscaler owns replicas.
- **Fix:** set `kuberay_worker_replicas`, `kuberay_worker_min_replicas` or `kuberay_worker_max_replicas` and run `install kuberay --only` **(changes the cluster)**.

### RAY-3 Client fails on connect with a version mismatch
- **Fix:** the client must use `ray[default]==2.40.0` on Python 3.12.

### RAY-4 Dashboard returns 401
- **Why:** basic auth on the external route. User `ray`, password from Secret `ray-dashboard-auth` in `ray-system`. It is not the LiteLLM key.

## Keycloak agent realm (`keycloak_agent_config`)

### KCR-1 `Wait for Keycloak to be ready` times out
- **Why:** `keycloak_agent_config_enabled: true` while Keycloak itself is not installed.
- **Check:** `kubectl get statefulset -n keycloak`
- **Fix:** enable Keycloak, or leave `keycloak_agent_config_enabled` at its default, then re-run **(changes the cluster)**.

### KCR-2 `Realm import 'agent-toolkit' failed: <condition message>`
- **Check:** `kubectl get keycloakrealmimport agent-toolkit -n keycloak -o jsonpath='{.status.conditions}'`
