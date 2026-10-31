// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect, useState } from "react";
import Field from "@/components/Field";

// GET /api/models: the gateways an openshell agent may use and the chat models each serves, live.
interface GatewayModel { id: string; contextWindow?: number }
interface Gateway { name: string; label: string; models: GatewayModel[]; error?: string }

export interface ModelChoice { provider: string; id: string; contextWindow?: number }

const SELECT = "h-9 w-full rounded-md border border-border bg-background px-2 text-sm";
// OpenClaw's system prompt alone is about 19,500 tokens; the API refuses models serving less.
const MIN_CONTEXT_WINDOW = 32768;
const tooSmall = (m: GatewayModel) => Boolean(m.contextWindow && m.contextWindow < MIN_CONTEXT_WINDOW);

function sizeLabel(m: GatewayModel): string {
  if (!m.contextWindow) return " · size unknown";
  return ` · ${Math.round(m.contextWindow / 1024)}k context${tooSmall(m) ? ", too small for agents" : ""}`;
}

/** Provider and model dropdowns for an openshell agent. Starts on `initial` when the gateway still
 *  serves it, else on the first gateway with the cluster default model. */
export default function GatewayModelPicker({ initial, onChange }: {
  initial?: { provider?: string; id?: string };
  onChange: (choice: ModelChoice | undefined) => void;
}) {
  const [gateways, setGateways] = useState<Gateway[] | null>(null);
  const [defaultModel, setDefaultModel] = useState("");
  const [error, setError] = useState("");
  const [provider, setProvider] = useState("");
  const [id, setId] = useState("");

  const pick = (gws: Gateway[], p: string, m: string) => {
    const g = gws.find((x) => x.name === p);
    const model = g?.models.find((x) => x.id === m && !tooSmall(x));
    setProvider(p);
    setId(m);
    onChange(g && model ? { provider: p, id: m, ...(model.contextWindow ? { contextWindow: model.contextWindow } : {}) } : undefined);
  };
  const firstModel = (g: Gateway | undefined, dflt: string) =>
    g?.models.some((m) => m.id === dflt && !tooSmall(m)) ? dflt : g?.models.find((m) => !tooSmall(m))?.id ?? "";

  useEffect(() => {
    fetch("/api/models", { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => {
        const gws: Gateway[] = Array.isArray(d?.gateways) ? d.gateways : [];
        const dflt = String(d?.defaultModel ?? "");
        setGateways(gws);
        setDefaultModel(dflt);
        const current = gws.find((g) => g.name === initial?.provider && g.models.some((m) => m.id === initial?.id));
        if (current) pick(gws, current.name, initial!.id!);
        else if (gws.length) pick(gws, gws[0].name, firstModel(gws[0], dflt));
      })
      .catch((e) => setError(String(e?.message ?? e)));
    // Load once; the parent remounts the picker to reload.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const gateway = gateways?.find((g) => g.name === provider);
  if (error) return <p className="text-xs text-destructive">Could not load models: {error}</p>;
  if (!gateways) return <p className="text-xs text-muted-foreground">Loading models…</p>;
  return (
    <div className="space-y-2">
      <div className="grid grid-cols-2 gap-3">
        <Field label="Provider" htmlFor="m-provider">
          <select id="m-provider" value={provider} className={SELECT}
            onChange={(e) => pick(gateways, e.target.value, firstModel(gateways.find((g) => g.name === e.target.value), defaultModel))}>
            {gateways.map((g) => <option key={g.name} value={g.name}>{g.label}</option>)}
          </select>
        </Field>
        <Field label="Model" htmlFor="m-model">
          <select id="m-model" value={id} className={SELECT} disabled={!gateway?.models.length}
            onChange={(e) => pick(gateways, provider, e.target.value)}>
            {gateway?.models.map((m) => (
              <option key={m.id} value={m.id} disabled={tooSmall(m)}>
                {m.id}{m.id === defaultModel ? " (default)" : ""}{sizeLabel(m)}
              </option>
            ))}
          </select>
        </Field>
      </div>
      {gateway?.models.find((m) => m.id === id && !m.contextWindow) && (
        <p className="text-xs text-muted-foreground">
          The gateway does not report this model&apos;s context size; the agent assumes {MIN_CONTEXT_WINDOW} tokens.
        </p>
      )}
      {gateway?.models.find((m) => m.id === id && tooSmall(m)) && (
        <p className="text-xs text-destructive">
          This model serves fewer than {MIN_CONTEXT_WINDOW} tokens, too few for an agent; pick another.
        </p>
      )}
      {gateway?.error && <p className="text-xs text-destructive">{gateway.label} did not answer: {gateway.error}</p>}
      {gateway && !gateway.error && !gateway.models.length && (
        <p className="text-xs text-muted-foreground">{gateway.label} serves no chat models right now.</p>
      )}
      {initial?.id && !gateways.some((g) => g.name === initial.provider && g.models.some((m) => m.id === initial.id)) && (
        <p className="text-xs text-muted-foreground">
          The agent&apos;s current model ({initial.provider || "?"}/{initial.id}) is not served now; pick another.
        </p>
      )}
    </div>
  );
}
