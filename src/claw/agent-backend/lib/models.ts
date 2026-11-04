// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// The model gateways an openshell agent may use, and the chat models each one serves, read live
// so a model registered in LiteLLM (or routed by the AI Gateway) shows up without a restart.

export interface GatewayModel { id: string; contextWindow?: number }
export interface Gateway { name: string; label: string; models: GatewayModel[]; error?: string }

interface GatewayConfig {
  name: string;
  label: string;
  url: string;              // the gateway's OpenAI-compatible base URL, ending in /v1
  kind: "litellm" | "openai";
}

type Fetch = (url: string, init?: { headers?: Record<string, string>; signal?: AbortSignal }) => Promise<{
  ok: boolean; status: number; json(): Promise<any>;
}>;

const CACHE_MS = 60_000;
// OpenClaw's system prompt alone is about 19,500 tokens a turn: a model serving less than this
// cannot hold a conversation, so it is not offered for agents (the operator uses the same figure).
export const MIN_CONTEXT_WINDOW = 32768;
let cache: { at: number; gateways: Gateway[] } | undefined;

/** MODEL_GATEWAYS, as the agent_backend role writes it; empty when OpenShell is off. */
export function gatewayConfig(env: NodeJS.ProcessEnv = process.env): GatewayConfig[] {
  try {
    const list = JSON.parse(env.MODEL_GATEWAYS || "[]");
    return Array.isArray(list) ? list.filter((g) => g?.name && g?.url && (g.kind === "litellm" || g.kind === "openai")) : [];
  } catch {
    return [];
  }
}

/** Models that are not for chat (the embedding and guardrail models), from MODEL_LIST_EXCLUDE. */
export function excludedModels(env: NodeJS.ProcessEnv = process.env): Set<string> {
  return new Set((env.MODEL_LIST_EXCLUDE || "").split(",").map((s) => s.trim()).filter(Boolean));
}

async function getJson(fetchImpl: Fetch, url: string, key?: string): Promise<any> {
  const res = await fetchImpl(url, {
    headers: key ? { Authorization: `Bearer ${key}` } : {},
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

/** The size a model server enforces (vLLM's max_model_len), asked with no key; 0 when it does not say. */
async function servedSize(fetchImpl: Fetch, apiBase: unknown): Promise<number> {
  if (typeof apiBase !== "string" || !/^https?:\/\//.test(apiBase)) return 0;
  try {
    const list = await getJson(fetchImpl, `${apiBase.replace(/\/+$/, "")}/models`);
    return Math.max(0, ...(list?.data ?? []).map((m: any) => Number(m?.max_model_len) || 0));
  } catch {
    return 0;
  }
}

// A model name as it may go into a URL path: never "..", "/" or anything to escape.
const MODEL_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

/** The size a model serves at its own URL (MODEL_SERVER_URL, "{model}" for its name): KServe
 *  serves each model at /<namespace>/<name>, also through the AI Gateway, so no LiteLLM is needed. */
async function ownServerSize(fetchImpl: Fetch, env: NodeJS.ProcessEnv, id: string): Promise<number> {
  const template = env.MODEL_SERVER_URL || "";
  return template && MODEL_ID_RE.test(id) ? servedSize(fetchImpl, template.replace("{model}", id)) : 0;
}

/** LiteLLM's model names and context sizes; it alone knows each model's server, so the AI Gateway
 *  reuses them. The server's own figure first: LiteLLM's max_input_tokens is empty for a newly
 *  registered model and can be the model's published size rather than the one it is served with. */
async function liteLlmModels(fetchImpl: Fetch, g: GatewayConfig, key: string): Promise<GatewayModel[]> {
  const info = await getJson(fetchImpl, `${g.url.replace(/\/v1\/?$/, "")}/model/info`, key);
  return Promise.all((info?.data ?? []).map(async (m: any) => {
    const size = await servedSize(fetchImpl, m?.litellm_params?.api_base) || Number(m?.model_info?.max_input_tokens) || 0;
    return { id: String(m?.model_name ?? ""), ...(size > 0 ? { contextWindow: size } : {}) };
  }));
}

async function openAiModels(fetchImpl: Fetch, g: GatewayConfig): Promise<GatewayModel[]> {
  const list = await getJson(fetchImpl, `${g.url.replace(/\/+$/, "")}/models`);
  return (list?.data ?? []).map((m: any) => ({ id: String(m?.id ?? "") }));
}

/** Every configured gateway with its chat models; a gateway that fails is listed with its error. */
export async function listGateways(fetchImpl: Fetch = fetch as unknown as Fetch, env: NodeJS.ProcessEnv = process.env,
                                   now: number = Date.now()): Promise<Gateway[]> {
  if (cache && now - cache.at < CACHE_MS) return cache.gateways;
  const exclude = excludedModels(env);
  const sizes = new Map<string, number>();
  const gateways: Gateway[] = [];
  const configs = gatewayConfig(env);
  // LiteLLM first, so the AI Gateway's models get its context sizes.
  for (const g of [...configs.filter((c) => c.kind === "litellm"), ...configs.filter((c) => c.kind === "openai")]) {
    try {
      const models = g.kind === "litellm"
        ? await liteLlmModels(fetchImpl, g, env.LITELLM_LIST_KEY || "")
        : await openAiModels(fetchImpl, g);
      for (const m of models) if (m.contextWindow) sizes.set(m.id, m.contextWindow);
      // Neither LiteLLM nor the gateway's list said: ask the model's own server, once per model.
      await Promise.all(models.filter((m) => !m.contextWindow && !sizes.has(m.id) && !exclude.has(m.id)).map(async (m) => {
        const size = await ownServerSize(fetchImpl, env, m.id);
        if (size) sizes.set(m.id, size);
      }));
      const seen = new Set<string>();
      gateways.push({
        name: g.name, label: g.label || g.name,
        models: models
          .filter((m) => m.id && !exclude.has(m.id) && !seen.has(m.id) && seen.add(m.id))
          .map((m) => (m.contextWindow || !sizes.has(m.id) ? m : { ...m, contextWindow: sizes.get(m.id) }))
          .sort((a, b) => a.id.localeCompare(b.id)),
      });
    } catch (e: any) {
      gateways.push({ name: g.name, label: g.label || g.name, models: [], error: String(e?.message ?? e) });
    }
  }
  // Keep the configured order for the response.
  gateways.sort((a, b) => configs.findIndex((c) => c.name === a.name) - configs.findIndex((c) => c.name === b.name));
  cache = { at: now, gateways };
  return gateways;
}

/** Why an openshell agent may not use this model, or undefined. No provider means the first LiteLLM
 *  gateway and no id the cluster default, as the operator does. A gateway that did not answer is
 *  not checked: the operator still caps the size at what the model serves. */
export function gatewayModelProblem(model: { provider?: string; id?: string; contextWindow?: number },
                                    gateways: Gateway[], defaultModel = ""): string | undefined {
  const configs = gatewayConfig();
  const provider = model.provider || (configs.find((c) => c.kind === "litellm") ?? configs[0])?.name;
  const id = model.id || defaultModel;
  const g = gateways.find((x) => x.name === provider);
  if (model.contextWindow && model.contextWindow < MIN_CONTEXT_WINDOW) {
    return `a context size of ${model.contextWindow} is too small for an agent: it needs at least ${MIN_CONTEXT_WINDOW}`;
  }
  if (!id || !g || g.error) return undefined;
  const served = g.models.find((m) => m.id === id);
  if (!served) {
    return `${g.label} does not serve '${id}'` +
      (g.models.length ? `; it serves ${g.models.map((m) => m.id).join(", ")}` : "");
  }
  if (served.contextWindow && served.contextWindow < MIN_CONTEXT_WINDOW) {
    return `'${id}' serves ${served.contextWindow} tokens, too few for an agent: it needs at least ${MIN_CONTEXT_WINDOW}`;
  }
  if (served.contextWindow && model.contextWindow && model.contextWindow > served.contextWindow) {
    return `a context size of ${model.contextWindow} is more than '${id}' serves (${served.contextWindow})`;
  }
  return undefined;
}

/** For tests: forget the cached lists. */
export function resetModelCache(): void {
  cache = undefined;
}
