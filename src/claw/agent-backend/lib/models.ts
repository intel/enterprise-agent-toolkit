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

/** LiteLLM's model names and context sizes; it alone reports sizes, so the AI Gateway reuses them. */
async function liteLlmModels(fetchImpl: Fetch, g: GatewayConfig, key: string): Promise<GatewayModel[]> {
  const info = await getJson(fetchImpl, `${g.url.replace(/\/v1\/?$/, "")}/model/info`, key);
  return (info?.data ?? []).map((m: any) => ({
    id: String(m?.model_name ?? ""),
    ...(Number(m?.model_info?.max_input_tokens) > 0 ? { contextWindow: Number(m.model_info.max_input_tokens) } : {}),
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

/** For tests: forget the cached lists. */
export function resetModelCache(): void {
  cache = undefined;
}
