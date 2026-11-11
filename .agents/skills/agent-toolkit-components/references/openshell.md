# OpenShell: policy-enforced sandboxes

OpenShell runs agents in sandboxes where egress is denied by default and allowed by policy (L7 rules, Landlock). The LLM key never enters the sandbox: the sandbox sees a placeholder `OPENAI_API_KEY`, and the OpenShell supervisor swaps in the real key on calls to LiteLLM.

It is off by default. Turn it on with `openshell_enabled: true` in `env/<env>/config.agent-toolkit.yaml`. It needs `agent_sandbox_enabled: true` (it uses the Agent Sandbox CRDs).

Side effect: with OpenShell on and Istio present, LiteLLM accepts connections from **every pod in the cluster** (`litellm_allow_pod_network` follows `openshell_enabled`). The API key check still applies.

## What is in the cluster

| Object | Name |
|---|---|
| Gateway | StatefulSet `openshell`, Service `openshell:8080` (gRPC, mTLS) in `openshell-system` |
| Admin client certificate | Secret `openshell-client-tls` (`ca.crt`, `tls.crt`, `tls.key`), in `openshell-system` **and** copied into `openshell-sandboxes`. This is **full gateway admin**. |
| LiteLLM key used by sandboxes | Secret `openshell-genai-key` (`api_key`), LiteLLM alias `openshell-sandboxes`, budget 50 |
| Provider | `genai-gateway` (profile `eat-genai-gateway`) pointing at `litellm.litellm.svc.cluster.local:4000` |
| Sandbox pods | Namespace `openshell-sandboxes` |
| CLI installed by the installer | `~/.cache/eat/openshell-cli-v<version>/openshell` on the installer host, for the installing user |

Access model (default): single admin. The gateway is ClusterIP-only. Whoever can `kubectl port-forward` in `openshell-system` and read `openshell-client-tls` (in either namespace) is the admin. OIDC (`openshell_oidc_issuer`) exists but is not validated.

## Connect the CLI

```bash
kubectl port-forward -n openshell-system svc/openshell 8080:8080 &
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost   # otherwise the CLI hangs behind a proxy
dir="${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/eat/mtls"; mkdir -p "$dir"
for k in ca.crt tls.crt tls.key; do
  kubectl get secret openshell-client-tls -n openshell-system -o jsonpath="{.data.${k//./\\.}}" | base64 -d > "$dir/$k"
done
chmod 600 "$dir"/*
openshell gateway add https://127.0.0.1:8080 --local --name eat
openshell provider list          # expect: genai-gateway  eat-genai-gateway
```

## Run an agent in a sandbox **(changes the cluster)**

```bash
openshell sandbox create --name demo --provider genai-gateway --detach \
  --env OPENAI_BASE_URL=http://litellm.litellm.svc.cluster.local:4000/v1
openshell logs demo --source sandbox | grep DENIED     # what the policy blocked
```

Agent code inside the sandbox calls `http://litellm.litellm.svc.cluster.local:4000/v1` with `$OPENAI_API_KEY` (the placeholder). Spend is booked to the alias `openshell-sandboxes`.

## Which programs may call the LLM

The provider profile allows only listed executables to reach LiteLLM: `charts/openshell/genai-gateway-provider.yaml` in this repo, field `binaries`. Shipped list:

- `/usr/bin/curl`
- `/usr/bin/python3`, `/usr/bin/python3.12`, `/usr/local/bin/python3`, `/usr/local/bin/python3.12`
- `/sandbox/.uv/python/**`
- `/usr/lib/node_modules/opencode-ai/bin/.opencode`

Matching uses the **resolved** path: a venv's python resolves to its base interpreter, and listed symlinks are resolved when the policy loads (globs are not).

- Error `policy_denied` or `binary ... not allowed in policy '_provider_genai_gateway'`: inside the sandbox, find the real path (`readlink -f "$(command -v node)"`), add it to `binaries`, then re-run `./es_auto_installer.sh install openshell --only` from the Toolkit Manager root **(changes the cluster)**. The profile is updated in place.
- A placeholder in a request **body** (not a header) fails with `credential_injection_failed`.
- The default sandbox image is the community `base:latest`, which can change binary paths. Pin an image (`--from <image>`) for repeatable runs.

## Things to know

- `kubectl exec` into a sandbox pod bypasses every policy. Restrict `pods/exec`, and `get`/`list` on Secrets (the admin certificate is there), in `openshell-sandboxes`.
- Policy decisions are written inside the pod. Fluent Bit and Loki do not collect them; use `openshell logs`.
- Reinstalling OpenShell issues new client certificates (old CLI configs stop working), a new LiteLLM key and a new provider.
- If someone revokes the `openshell-sandboxes` key in LiteLLM while the Secret still exists, the installer does not mint a new one. Fix **(changes the cluster)**: `openshell provider delete genai-gateway`, `kubectl delete secret openshell-genai-key -n openshell-system`, then `./es_auto_installer.sh install openshell --only`.

## Inspect

```bash
kubectl get pods,pvc,secret -n openshell-system
kubectl get pods,networkpolicy -n openshell-sandboxes
kubectl logs -n openshell-system openshell-0 | sed 's/\x1b\[[0-9;]*m//g'
```

The gateway log repeats `WARN ... Compute driver watch stream errored ... too old: Expired`. It is harmless.
