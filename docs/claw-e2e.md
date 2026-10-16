<!-- Copyright (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# Claw end-to-end walkthrough

Step-by-step checks for claw, with the output to expect. Run them from the
root of your AI Solutions checkout. Background and configuration are in [claw.md](claw.md).

```bash
export KUBECONFIG=$PWD/env/<env>/kubeconfig.yaml
```

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
