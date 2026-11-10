# Run an agent in its own namespace

The toolkit namespaces (`redis`, `pgvector`, `agent-sandbox-system`, `ray-system`, `litellm`, `langfuse`) are in the Istio **ambient** mesh, and mesh-wide mTLS is **STRICT**. A pod outside the mesh, or one the policy does not allow, gets a **connection reset**. There is no HTTP error and no message saying why.

Do these four steps for every namespace that runs agent code. Each one changes the cluster; show the user the commands first.

## 1. Join the mesh **(changes the cluster)**

```bash
kubectl label namespace <agent-ns> istio.io/dataplane-mode=ambient
```

Ambient mode picks up running pods without a restart. Check: `kubectl get ns <agent-ns> -L istio.io/dataplane-mode` shows `ambient`. If a pod still gets resets after a minute, restart it.

## 2. Allow the namespace to call LiteLLM **(changes the cluster)**

LiteLLM admits only the namespaces in `litellm_allowed_namespaces`. Add yours in `env/<env>/config.agent-toolkit.yaml`. The value **replaces** the default list, so keep the existing entries:

```yaml
litellm_allowed_namespaces:
  - "{{ gateway_namespace | default('envoy-gateway-system') }}"
  - "{{ litellm_namespace | default('litellm') }}"
  - "{{ agent_sandbox_namespace }}"
  - "{{ kuberay_namespace }}"
  - <agent-ns>
```

- Copy the shipped entries from `config.yaml` in this repo rather than from this page, in case they have changed.
- Main track: the inference layer's own default also lists the model-manager Jobs namespace (`"{{ llm_services_mm_namespace | default('model-manager') }}"`), and the toolkit list drops it. Add it back if model deploys are started from Headlamp.

Then apply from the Toolkit Manager root:

```bash
./es_auto_installer.sh install litellm --only --env <env>
```

The LiteLLM access policies are applied on every run, so no reconcile flag is needed. Check: `kubectl get authorizationpolicy litellm-ingress -n litellm -o jsonpath='{.spec.rules[*].from[*].source.namespaces}'`.

While OpenShell is on, LiteLLM also admits every pod IP in the cluster (`litellm_allow_pod_network` follows `openshell_enabled`). Still list your namespace. If OpenShell is later turned off, that wider rule goes away on the next LiteLLM run.

## 3. Bring the credentials **(changes the cluster)**

Secrets are namespaced. Copy what the agent needs into `<agent-ns>` without printing the values:

```bash
copy_secret() {  # copy_secret <name> <from-ns> <to-ns>   (needs jq)
  kubectl get secret "$1" -n "$2" -o json \
  | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.labels,.metadata.annotations,.metadata.managedFields)' \
  | kubectl apply -n "$3" -f -
}
copy_secret redis-stack-server-credentials redis <agent-ns>
copy_secret pgvector-credentials pgvector <agent-ns>
copy_secret sandbox-router-auth agent-sandbox-system <agent-ns>
```

For LiteLLM, mint a virtual key for the agent (`litellm.md`) and store only that key. Never copy `litellm-master-key`.

Copies do not follow changes. After a component is torn down and reinstalled (new password or token), copy again.

## 4. Sandbox access (only if the agent uses Agent Sandbox) **(changes the cluster)**

Create the Role and RoleBinding in `sandbox.md` for the agent's ServiceAccount.

## Who can reach what

| From | To | Allowed when |
|---|---|---|
| Ambient pod | Redis, pgvector, sandbox router, Ray, Langfuse | Always (mTLS) |
| Ambient pod | LiteLLM `:4000` | Its namespace is in `litellm_allowed_namespaces`, or OpenShell is on |
| Pod outside the mesh | Redis, pgvector, sandbox router, Ray, Langfuse | Never (reset). Label the namespace. |
| Pod outside the mesh | LiteLLM `:4000` | Only while OpenShell is on (LiteLLM then accepts plaintext from pod IPs) |
| Agent Sandbox pod | Anything in the cluster | Never, by design (`sandbox.md`) |
| OpenShell sandbox | LiteLLM `:4000`, cluster DNS, OpenShell gateway, public internet | By the OpenShell policy |
| Outside the cluster | `https://<service>.<base_domain_name>` | Through the shared gateway; see below |

Your own HTTPRoute on the shared gateway inherits the gateway-wide auth policy unless the route has its own SecurityPolicy. On the release track that policy checks a LiteLLM key; on the main track it requires a Keycloak JWT bearer token. Either send that credential, or give your route its own SecurityPolicy, the way the shipped `*-no-auth` policies do **(changes the cluster)**.

## When it still fails

```bash
kubectl get ns <agent-ns> -L istio.io/dataplane-mode
kubectl get authorizationpolicy -n litellm
kubectl get peerauthentication -A
kubectl logs -n istio-system -l app=ztunnel --tail=200 | grep -iE 'denied|policy|rbac'
```

`RBAC: access denied` in an HTTP 403 body comes from an L7 policy, which the toolkit does not create. Look for a waypoint or an AuthorizationPolicy with HTTP rules that someone added (`kubectl get authorizationpolicy -A -o yaml | grep -B3 -A10 -E 'methods|paths'`).
