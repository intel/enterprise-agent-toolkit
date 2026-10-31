// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { listGateways, resetModelCache, gatewayConfig } from "../lib/models.js";
import { validateRuntime, validateOpenShellModel } from "../lib/k8s.js";

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
