// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { listGateways, resetModelCache, gatewayConfig, gatewayModelProblem, MIN_CONTEXT_WINDOW, type Gateway } from "../lib/models.js";
import { validateRuntime, validateOpenShellModel, modelChange } from "../lib/k8s.js";

const LITELLM = "http://litellm.litellm.svc.cluster.local:4000/v1";
const AIGW = "http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1";
const ENV = {
  MODEL_GATEWAYS: JSON.stringify([
    { name: "genai-gateway", label: "GenAI Gateway (LiteLLM)", url: LITELLM, kind: "litellm" },
    { name: "ai-gateway", label: "AI Gateway (Envoy)", url: AIGW, kind: "openai" },
  ]),
  MODEL_LIST_EXCLUDE: "bge-base-en, qwen3guard",
  LITELLM_LIST_KEY: "sk-list",
};

function fakeFetch(calls: string[], aiGatewayFails = false) {
  return async (url: string, init?: any) => {
    calls.push(`${url} ${init?.headers?.Authorization ?? "-"}`);
    if (url.startsWith("http://litellm")) {
      return { ok: true, status: 200, json: async () => ({ data: [
        { model_name: "qwen3-coder-30b", model_info: { max_input_tokens: 262144 } },
        { model_name: "qwen3-4b", model_info: { max_input_tokens: 40960 } },
        { model_name: "bge-base-en", model_info: { max_input_tokens: 512 } },
        { model_name: "qwen3guard", model_info: {} },
        { model_name: "hybrid-router", model_info: {} },
      ] }) };
    }
    if (aiGatewayFails) return { ok: false, status: 503, json: async () => ({}) };
    return { ok: true, status: 200, json: async () => ({ data: [{ id: "qwen3-coder-30b" }, { id: "bge-base-en" }] }) };
  };
}

test("each gateway lists its chat models; sizes come from LiteLLM; the key goes to LiteLLM only", async () => {
  resetModelCache();
  const calls: string[] = [];
  const [genai, aigw] = await listGateways(fakeFetch(calls) as any, ENV as any, 1);
  assert.equal(genai.name, "genai-gateway");
  assert.deepEqual(genai.models.map((m) => m.id), ["hybrid-router", "qwen3-4b", "qwen3-coder-30b"]);
  assert.equal(genai.models.find((m) => m.id === "qwen3-4b")?.contextWindow, 40960);
  assert.equal(aigw.name, "ai-gateway");
  assert.deepEqual(aigw.models, [{ id: "qwen3-coder-30b", contextWindow: 262144 }]);
  assert.ok(calls.some((c) => c.startsWith("http://litellm.litellm.svc.cluster.local:4000/model/info Bearer sk-list")));
  assert.ok(calls.some((c) => c === `${AIGW}/models -`));
});

test("a gateway that fails is listed with its error; the others still answer", async () => {
  resetModelCache();
  const [genai, aigw] = await listGateways(fakeFetch([], true) as any, ENV as any, 1);
  assert.equal(genai.models.length, 3);
  assert.deepEqual(aigw.models, []);
  assert.match(aigw.error ?? "", /503/);
});

test("lists are cached for a minute", async () => {
  resetModelCache();
  const calls: string[] = [];
  await listGateways(fakeFetch(calls) as any, ENV as any, 1000);
  await listGateways(fakeFetch(calls) as any, ENV as any, 30_000);
  assert.equal(calls.length, 2);
  await listGateways(fakeFetch(calls) as any, ENV as any, 70_000);
  assert.equal(calls.length, 4);
});

test("bad gateway config is ignored; an openshell agent must name a configured gateway", () => {
  assert.deepEqual(gatewayConfig({ MODEL_GATEWAYS: "not json" } as any), []);
  assert.deepEqual(gatewayConfig({ MODEL_GATEWAYS: JSON.stringify([{ name: "x", url: "u", kind: "other" }]) } as any), []);
  const saved = { ...process.env };
  Object.assign(process.env, { OPENSHELL_ENABLED: "true", MODEL_GATEWAYS: ENV.MODEL_GATEWAYS });
  try {
    assert.equal(validateRuntime("openshell", "oss", "vkumar4", { provider: "ai-gateway", id: "qwen3-coder-30b" }), "openshell");
    assert.throws(() => validateRuntime("openshell", "oss", "vkumar4", { provider: "openai", id: "gpt" }),
      (e: any) => e.status === 400 && /genai-gateway or ai-gateway/.test(e.message));
  } finally {
    process.env = saved;
  }
});

test("a model change on an openshell agent: a configured gateway, no URL or key", () => {
  const saved = { ...process.env };
  Object.assign(process.env, { MODEL_GATEWAYS: ENV.MODEL_GATEWAYS });
  try {
    assert.doesNotThrow(() => validateOpenShellModel({ provider: "ai-gateway", id: "qwen3-4b", contextWindow: 262144 }));
    assert.throws(() => validateOpenShellModel({ provider: "openai", id: "gpt" }), (e: any) => e.status === 400);
    assert.throws(() => validateOpenShellModel({ provider: "genai-gateway", id: "x", baseUrl: "http://x/v1" }), (e: any) => e.status === 400);
    assert.throws(() => validateOpenShellModel({ provider: "genai-gateway", id: "x" }, "sk-own"), (e: any) => e.status === 400);
  } finally {
    process.env = saved;
  }
});

test("the served size comes from the model server, with no key; LiteLLM's figure is the fallback", async () => {
  resetModelCache();
  const calls: string[] = [];
  const Q06 = "http://ai-gateway/llm-inference/qwen3-0-6b/v1";
  const fetchImpl = async (url: string, init?: any) => {
    calls.push(`${url} ${init?.headers?.Authorization ?? "-"}`);
    if (url.endsWith("/model/info")) {
      return { ok: true, status: 200, json: async () => ({ data: [
        // Deployed with --max-model-len=16384: LiteLLM shows the published 40960.
        { model_name: "qwen3-0-6b", litellm_params: { api_base: Q06 }, model_info: { max_input_tokens: 40960 } },
        { model_name: "qwen3-1-7b", litellm_params: { api_base: "http://down/v1" }, model_info: { max_input_tokens: 40960 } },
        { model_name: "fresh", litellm_params: { api_base: "http://down/v1" }, model_info: { max_input_tokens: null } },
      ] }) };
    }
    if (url === `${Q06}/models`) return { ok: true, status: 200, json: async () => ({ data: [{ id: "qwen3-0-6b", max_model_len: 16384 }] }) };
    if (url.startsWith("http://down")) throw new Error("ECONNREFUSED");
    return { ok: true, status: 200, json: async () => ({ data: [] }) };
  };
  const [genai] = await listGateways(fetchImpl as any, ENV as any, 1);
  assert.deepEqual(genai.models, [{ id: "fresh" }, { id: "qwen3-0-6b", contextWindow: 16384 }, { id: "qwen3-1-7b", contextWindow: 40960 }]);
  assert.ok(calls.includes(`${Q06}/models -`));  // never the list key
});

const GWS: Gateway[] = [
  { name: "genai-gateway", label: "GenAI Gateway (LiteLLM)", models: [
    { id: "qwen3-0-6b", contextWindow: 16384 }, { id: "qwen3-1-7b", contextWindow: 40960 }, { id: "unsized" }] },
  { name: "ai-gateway", label: "AI Gateway (Envoy)", models: [], error: "HTTP 503" },
];

test("an openshell agent's model must be served, big enough, and its size within what is served", () => {
  const saved = { ...process.env };
  try {
    process.env.MODEL_GATEWAYS = ENV.MODEL_GATEWAYS;
    assert.equal(gatewayModelProblem({ provider: "genai-gateway", id: "qwen3-1-7b", contextWindow: 40960 }, GWS), undefined);
    assert.equal(gatewayModelProblem({ id: "qwen3-1-7b" }, GWS), undefined);  // no provider: the LiteLLM gateway
    assert.equal(gatewayModelProblem({ provider: "genai-gateway", id: "unsized" }, GWS), undefined);  // the operator falls back
    assert.match(gatewayModelProblem({ provider: "genai-gateway", id: "gone" }, GWS) ?? "", /does not serve 'gone'; it serves qwen3-0-6b/);
    assert.match(gatewayModelProblem({ provider: "genai-gateway", id: "qwen3-0-6b" }, GWS) ?? "", /16384 tokens, too few/);
    assert.match(gatewayModelProblem({ provider: "genai-gateway", id: "qwen3-1-7b", contextWindow: 262144 }, GWS) ?? "",
                 /more than 'qwen3-1-7b' serves \(40960\)/);
    assert.match(gatewayModelProblem({ provider: "genai-gateway", id: "unsized", contextWindow: 8192 }, GWS) ?? "",
                 new RegExp(`at least ${MIN_CONTEXT_WINDOW}`));
    assert.match(gatewayModelProblem({}, GWS, "gone") ?? "", /does not serve 'gone'/);  // the cluster default is checked too
    // A gateway that did not answer is not checked; the operator still caps the size.
    assert.equal(gatewayModelProblem({ provider: "ai-gateway", id: "anything" }, GWS), undefined);
  } finally {
    process.env = saved;
  }
});

test("a model change without a size drops the old model's size", () => {
  const old = { provider: "genai-gateway", id: "qwen3-coder-30b", contextWindow: 262144 };
  assert.deepEqual(modelChange(old, { provider: "genai-gateway", id: "qwen3-1-7b" }), {
    patch: { provider: "genai-gateway", id: "qwen3-1-7b", contextWindow: null },
    effective: { provider: "genai-gateway", id: "qwen3-1-7b" },
  });
  assert.deepEqual(modelChange(old, { id: "qwen3-1-7b", contextWindow: 40960 }).effective,
                   { provider: "genai-gateway", id: "qwen3-1-7b", contextWindow: 40960 });
  assert.deepEqual(modelChange(undefined, { id: "qwen3-1-7b" }), { patch: { id: "qwen3-1-7b" }, effective: { id: "qwen3-1-7b" } });
});

test("without LiteLLM, sizes come from each model's own URL; a name never changes the path", async () => {
  resetModelCache();
  const calls: string[] = [];
  const env = {
    MODEL_GATEWAYS: JSON.stringify([{ name: "ai-gateway", label: "AI Gateway (Envoy)", url: AIGW, kind: "openai" }]),
    MODEL_LIST_EXCLUDE: "bge-base-en",
    MODEL_SERVER_URL: "http://ai-gateway.envoy-gateway-system.svc.cluster.local/llm-inference/{model}/v1",
  };
  const fetchImpl = async (url: string) => {
    calls.push(url);
    if (url === `${AIGW}/models`) {
      return { ok: true, status: 200, json: async () => ({ data: [{ id: "qwen3-coder-30b" }, { id: "qwen3-0-6b" }, { id: "gone" }, { id: "bge-base-en" }, { id: "../key/generate" }] }) };
    }
    const m = url.match(/llm-inference\/([^/]+)\/v1\/models$/);
    const size = m && ({ "qwen3-coder-30b": 262144, "qwen3-0-6b": 16384 } as any)[m[1]];
    if (size) return { ok: true, status: 200, json: async () => ({ data: [{ id: m![1], max_model_len: size }] }) };
    return { ok: false, status: 404, json: async () => ({}) };
  };
  const [aigw] = await listGateways(fetchImpl as any, env as any, 1);
  assert.deepEqual(aigw.models.filter((m) => m.id !== "../key/generate"),
    [{ id: "gone" }, { id: "qwen3-0-6b", contextWindow: 16384 }, { id: "qwen3-coder-30b", contextWindow: 262144 }]);
  assert.ok(!calls.some((c) => c.includes("bge-base-en")));   // excluded models are not asked
  assert.ok(!calls.some((c) => c.includes("..")));            // an odd name is never put in a URL
  // The picker's checks then work without LiteLLM.
  const saved = { ...process.env };
  try {
    process.env.MODEL_GATEWAYS = env.MODEL_GATEWAYS;
    assert.match(gatewayModelProblem({ id: "qwen3-0-6b" }, [aigw]) ?? "", /16384 tokens, too few/);
    assert.match(gatewayModelProblem({ id: "qwen3-coder-30b", contextWindow: 524288 }, [aigw]) ?? "", /more than/);
  } finally {
    process.env = saved;
  }
});
