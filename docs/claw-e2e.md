<!-- Copyright (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Claw end-to-end walkthrough

Step-by-step checks for claw, with the output to expect. Run them from the
root of your AI Solutions checkout. Background and configuration are in [claw.md](claw.md).

```bash
export KUBECONFIG=$PWD/env/<env>/kubeconfig.yaml
```

---

## Create an agent

**You need:** the Agent Toolkit installed with its default model, `claw_enabled: true` in
`env/<env>/config.agent-toolkit.yaml`, and the claw components installed:

```bash
./es_auto_installer.sh install mcp_servers --env <env>
./es_auto_installer.sh validate mcp_servers --only --env <env>
kubectl get tools        # memory   memory   true   true   Registered
```

### 1. Create the agent

```bash
kubectl apply -f ext/enterprise.agent-toolkit/docs/examples/agent.yaml
kubectl -n user-alice wait agent/demo --for=jsonpath='{.status.phase}'=Running --timeout=10m
kubectl -n user-alice get agent demo -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
```

```text
IdentityReady=True
MemoryReady=True
BackendReady=True
SeedingComplete=True
```

### 2. Look at what was provisioned

```bash
kubectl get namespace agent-alice-demo --show-labels
kubectl -n agent-alice-demo get openclawinstance,pod,networkpolicy,resourcequota,limitrange
kubectl -n agent-alice-demo exec demo-0 -c openclaw -- cat /home/openclaw/.openclaw/workspace/AGENTS.md
```

### 3. Chat with the agent

```bash
kubectl -n agent-alice-demo port-forward svc/demo 18789:18789 &
TOKEN=$(kubectl -n agent-alice-demo get secret demo-gateway-token -o jsonpath='{.data.token}' | base64 -d)
curl -s localhost:18789/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"openclaw","messages":[{"role":"user","content":"What is the capital of France?"}]}'
```

The answer (`Paris`) arrives after about 30 seconds on CPU inference. Without the token the
request returns `401`.

### 4. Use memory

With the port-forward from step 3 still running:

```bash
ask() { curl -s localhost:18789/v1/chat/completions -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg m "$1" '{model:"openclaw",messages:[{role:"user",content:$m}]}')" |
  jq -r '.choices[0].message.content'; }
ask 'Use your memory_write tool to store this fact in your long-term memory: the release codename is BLUEFIN. Then confirm.'
kubectl -n agent-operator-system logs deploy/mcp-memory-server | grep AUDIT
```

```text
AUDIT memory_write azp=agent-alice-demo schema=agent_alice_demo tier=auto
```

Each request is a new session, so `ask 'Use your memory_read tool to look up the release
codename.'` answers from memory, not from the conversation. Small models do not always call
the tool; if the answer does not mention `BLUEFIN`, ask again.
### 5. Run code and fetch a page

```bash
ask 'Use your sandbox__execute_python tool to run print(2**100) and tell me the output.'
kubectl -n user-alice patch agent demo --type merge -p '{"spec":{"webFetchAllowlist":["example.com"]}}'
sleep 60   # the proxy re-reads its allowlist; the file syncs within a minute
kubectl -n agent-alice-demo exec demo-0 -c openclaw -- curl -s -o /dev/null -w '%{http_code}\n' https://example.com/
kubectl -n agent-alice-demo exec demo-0 -c openclaw -- curl -s -o /dev/null -w '%{http_code}\n' https://www.wikipedia.org/
kubectl -n agent-alice-demo logs deploy/web-fetch-proxy --tail=4
```

The sandbox answers `1267650600228229401496703205376`. `example.com` returns `200`;
`wikipedia.org` returns `000`, and the proxy log shows
`403 … not in this agent's web_fetch allowlist`. Stop the port-forward with `kill %1`.

### 6. Suspend and resume

```bash
kubectl -n agent-alice-demo exec demo-0 -c openclaw -- sh -c 'echo kept > /home/openclaw/.openclaw/workspace/marker.txt'
kubectl -n user-alice patch agent demo --type merge -p '{"spec":{"desiredState":"Suspended"}}'
kubectl -n agent-alice-demo get pods                    # no pods
kubectl -n user-alice patch agent demo --type merge -p '{"spec":{"desiredState":"Running"}}'
kubectl -n agent-alice-demo wait pod/demo-0 --for=condition=Ready --timeout=5m
kubectl -n agent-alice-demo exec demo-0 -c openclaw -- cat /home/openclaw/.openclaw/workspace/marker.txt
```

The file written before the suspend is still there (`kept`).

### 7. Delete the agent

```bash
kubectl -n user-alice delete agent demo
kubectl get namespace agent-alice-demo user-alice    # both are removed
```

The agent's Keycloak client, memory schema and sandbox are deleted with it, and `user-alice` is removed
once its last agent is gone.

---

## Run an OpenClaw instance

**You need:** the Agent Toolkit installed with its default model (`qwen2-5-coder-14b`),
and `claw_enabled: true` in `env/<env>/config.agent-toolkit.yaml`.

### 1. Install the operator

```bash
./es_auto_installer.sh install openclaw_operator --only --env <env>
./es_auto_installer.sh validate openclaw_operator --only --env <env>
```

The validate summary ends with:

```text
- 'Release: openclaw-operator-0.38.3 (deployed)'
- 'CRDs: OK'
- 'Controller: Available, image sha256:ca7ad419…'
```

### 2. Check the inference gateway

The agent calls the in-cluster `ai-gateway`. From any pod in a mesh-enrolled namespace:

```bash
curl -s http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1/models
# {"data":[{"id":"qwen2-5-coder-14b", …}],"object":"list"}
```

### 3. Create the instance

```bash
kubectl apply -f ext/enterprise.agent-toolkit/docs/examples/openclaw-instance.yaml
kubectl -n claw-demo wait openclawinstance/demo --for=jsonpath='{.status.phase}'=Running --timeout=10m
kubectl -n claw-demo get openclawinstance demo
```

```text
NAME   PHASE     READY   GATEWAY                    AGE
demo   Running   True    demo.claw-demo.svc:18789   1m
```

The first start pulls the OpenClaw image (about 360 MB).

### 4. Chat with the agent

The operator generated a gateway token in the Secret `demo-gateway-token`.

```bash
kubectl -n claw-demo port-forward svc/demo 18789:18789 &
TOKEN=$(kubectl -n claw-demo get secret demo-gateway-token -o jsonpath='{.data.token}' | base64 -d)

curl -s localhost:18789/v1/chat/completions \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"openclaw","messages":[{"role":"user","content":"In one short sentence: what is 17 times 3?"}]}'
```

```text
{"id":"chatcmpl_…","object":"chat.completion","model":"openclaw",
 "choices":[{"index":0,"message":{"role":"assistant","content":"17 times 3 is 51."},"finish_reason":"stop"}],
 "usage":{"prompt_tokens":19507,"completion_tokens":11,"total_tokens":19518}}
```

The first word takes about 30 seconds on CPU inference: the model reads the agent's
roughly 19,500-token prompt before it answers. To watch the answer arrive, add
`"stream": true` to the request body and pass `-N` to `curl`; the response is a stream of
`data:` chunks ending with `data: [DONE]`.

The same request without the `Authorization` header returns `401`.

### 5. Clean up

```bash
kill %1                                   # the port-forward
kubectl delete namespace claw-demo        # the instance and its data
```

Deleting only the `OpenClawInstance` keeps its volume (`spec.storage.persistence.orphan`
defaults to `true`), so the agent's files survive and a new instance of the same name
can reuse them.

### If it does not work

| Symptom | Cause | Fix |
|---|---|---|
| The chat answer is `Context overflow: prompt too large for the model`, and the `openclaw` container log shows `rawError=413 Payload Too Large` | The inference gateway's request buffer is Envoy's 32 KiB default. An agent request is larger than that | Use an inference layer whose `ai-gateway` has a raised `bufferLimit` (`ai_gateway_buffer_limit`, see [claw.md](claw.md#limitations)) |
| The chat answer is `Context overflow` and the log shows a token-length error | `contextWindow` in the example does not match the model's served length | Set it to the served `max_model_len` |
| `curl` to `ai-gateway` gets `Connection reset by peer` | The calling namespace is not in the ambient mesh, and the platform enforces STRICT mTLS | Label the namespace `istio.io/dataplane-mode=ambient` |
| The pod starts but model calls time out | The instance's network policy does not admit the gateway | Keep the `additionalEgress` rule from the example; in the mesh the port is `15008` |
