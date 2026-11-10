# Network: reaching the stack from outside, and the mesh inside

## From a laptop or the installer host (`https://<service>.<base_domain_name>`)

Every external URL goes through one gateway, Envoy Gateway `eg-gateway`, on one LoadBalancer IP:

```bash
GW=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gateway \
     -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
D=$(yq '.base_domain_name' env/<env>/global_config.yaml)
```

### NET-1 The browser or curl cannot reach `https://litellm.<domain>` (timeout, proxy error page, wrong host)
Check the three things a client needs, in this order:
1. **Name resolution.** `getent hosts litellm.$D` must return `$GW`. Without DNS, map the names in `/etc/hosts` (a host change; ask first): `litellm`, `litellm-ui` (main track), `keycloak`, `langfuse` and `grafana`, plus `vllm-sr` and `ray` when those are on. All map to `$GW`.
2. **Proxy.** With `https_proxy` set in the client shell or browser, `no_proxy` must include `.$D` (and the node IPs for kubectl). Test without the proxy: `curl --noproxy '*' ...`.
3. **Trust.** With `gateway_tls_mode: selfsigned`, use the CA: `curl --cacert env/<env>/logs/ai-solutions-ca.crt https://litellm.$D/v1/models -H "Authorization: Bearer <key>"`. Import that file into the browser or OS trust store, or set `REQUESTS_CA_BUNDLE` and `SSL_CERT_FILE` for Python clients. Do not use `-k` in instructions.

To test the gateway alone, without DNS or proxy: `curl --noproxy '*' --cacert env/<env>/logs/ai-solutions-ca.crt --resolve "litellm.$D:443:$GW" "https://litellm.$D/v1/models" -H "Authorization: Bearer <key>"`. If this works and the plain URL does not, the problem is on the client side (1 or 2).

With `routing_mode: path` (main track) the API is `https://$D/litellm/v1` instead. With the toolkit default `litellm_public_paths: []`, path mode may publish no API route at all (untested). If API calls redirect to a sign-in page, set `litellm_public_paths` to the API paths and re-run install **(changes the cluster)**.

### NET-2 kubectl says `Unable to connect to the server: Forbidden`, or `couldn't get current server API group list ... Forbidden`
- **Why:** the shell's `https_proxy` sends API server traffic to the corporate proxy. The installer uses `global_config.yaml` and is not affected.
- **Fix:** `export no_proxy=$no_proxy,<every node IP>,.<domain> NO_PROXY=$no_proxy`

### NET-3 kubectl says `The connection to the server localhost:8080 was refused`
- **Fix:** `export KUBECONFIG=<root>/env/<env>/kubeconfig.yaml`

### NET-4 Your own HTTPRoute on the gateway answers 401 or 403
- **Why:** routes without their own SecurityPolicy inherit the gateway-wide one. On the release track it checks the request against LiteLLM's key API; on the main track it requires a Keycloak JWT bearer token.
- **Check:** `kubectl get securitypolicy -A`
- **Fix:** send the expected credential, or give your route its own SecurityPolicy the way the shipped `*-no-auth` policies do **(changes the cluster)**.

### NET-5 The apiserver service proxy fails with `ServiceUnavailable` for a toolkit Service
- **Why:** the Service's namespace is in the mesh.
- **Fix:** use `kubectl port-forward` instead.

## Inside the cluster (Istio ambient mesh)

Toolkit namespaces are in the ambient mesh with STRICT mTLS. **A policy denial is a TCP reset, not an HTTP error.** For the onboarding steps see the agent-toolkit-components skill (`references/namespace-onboarding.md`).

| Symptom in the client | Most likely cause | Check |
|---|---|---|
| `Connection reset by peer`, curl `(56) Recv failure`, Python `ConnectionResetError: [Errno 104]`, httpx `RemoteProtocolError: Server disconnected`, to LiteLLM `:4000` | Namespace not in `litellm_allowed_namespaces`, or not in the mesh | `kubectl get ns <ns> -L istio.io/dataplane-mode`; `kubectl get authorizationpolicy litellm-ingress -n litellm -o jsonpath='{.spec.rules[0].from[0].source.namespaces}'` |
| Same reset to Redis, pgvector, the sandbox router, Ray or Langfuse | Client namespace not ambient. (LiteLLM alone also accepts non-mesh pods while OpenShell is on.) | `kubectl get ns <ns> -L istio.io/dataplane-mode` |
| ztunnel log `policy rejection ... istio_converted_static_strict` | Plaintext from outside the mesh | `kubectl logs -n istio-system -l app=ztunnel --tail=200 \| grep -i 'policy rejection'` |
| Timeout (not reset) from code **inside an Agent Sandbox** | By design: sandbox egress is public internet only | agent-toolkit-components skill, `references/sandbox.md` |
| `Connection refused` | Nothing listening: wrong port, pod restarting, or a port-forward ended | `kubectl get endpointslices -n <ns> -l kubernetes.io/service-name=<svc>`. Ports: LiteLLM 4000, router 8080, Ray client 10001, Postgres 5432, Redis 6379 |
| HTTP 403 with body `RBAC: access denied` | An L7 policy. The toolkit creates none, so someone added a waypoint or an AuthorizationPolicy with HTTP rules. | `kubectl get authorizationpolicy -A -o yaml \| grep -B3 -A10 -E 'methods\|paths'`; `kubectl get gateway -A` |
| `403 ... cannot create resource "sandboxclaims"` | Kubernetes RBAC, not the mesh | `components.md` SBX-5 |
| OpenShell sandbox: `403 Forbidden` from the proxy, curl exit 56 or `000` | The OpenShell policy blocked that host | `openshell logs <name> --source sandbox \| grep DENIED` |
