// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { dirToWorkspace } from "@/lib/workspace";
import { useRegisteredTools } from "@/lib/useRegisteredTools";
import { useMe } from "@/lib/useMe";
import { cn } from "@/lib/utils";
import Field from "@/components/Field";
import FileDrop from "@/components/FileDrop";
import SecretInput from "@/components/SecretInput";
import WebFetchAllowlist, { WebFetchAllowlistHint } from "@/components/WebFetchAllowlist";
import { Button, ButtonLink } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { AlertTriangle } from "lucide-react";

// OpenClaw capabilities that change its configuration; read and list are always on.
const ALL_SKILLS = [
  "shell",
  "browser-automation",
  "diagram-maker",
  "canvas",
];

// The one tool with a per-agent credential (spec.githubTokenSecretRef).
const GITHUB_SKILL = "github";

// OpenShell workspace names (the agent namespace, agent-<username>-<name>) are at most 19 characters.
const OPENSHELL_MAX_NAMESPACE = 19;

// GET /api/models: the gateways an openshell agent may use and the chat models each serves.
interface GatewayModel { id: string; contextWindow?: number }
interface Gateway { name: string; label: string; models: GatewayModel[]; error?: string }

function CheckboxRow({ checked, onChange, disabled, title, children }: { checked: boolean; onChange: () => void; disabled?: boolean; title?: string; children: React.ReactNode }) {
  return (
    <label
      title={title}
      className={cn(
        "inline-flex items-center gap-2 rounded-md border border-border bg-background px-3 py-1.5 text-sm transition-colors",
        disabled ? "cursor-not-allowed opacity-50" : "hover:border-primary/50"
      )}
    >
      <input
        type="checkbox"
        checked={checked}
        onChange={onChange}
        disabled={disabled}
        className="h-3.5 w-3.5 accent-[hsl(var(--primary))] disabled:cursor-not-allowed"
      />
      {children}
    </label>
  );
}

export default function NewAgentPage() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [skills, setSkills] = useState<string[]>(["shell", "read_file", "list_files"]);
  // Tool names or globs this agent may not call, on top of its skills.
  const [toolsDeny, setToolsDeny] = useState<string[]>([]);
  const [tdInput, setTdInput] = useState("");
  // Files seeded into the agent's workspace (AGENTS.md, SKILL.md, …).
  const [workspace, setWorkspace] = useState<Record<string, string>>({});
  // Domains web_fetch may reach; empty means none.
  const [webFetchAllowlist, setWebFetchAllowlist] = useState<string[]>([]);
  // Per-agent model; blank uses the cluster's default.
  const [mProvider, setMProvider] = useState("");
  const [mId, setMId] = useState("");
  const [mName, setMName] = useState("");
  const [mBaseUrl, setMBaseUrl] = useState("");
  const [mApiKey, setMApiKey] = useState("");
  // The agent's own GitHub token, only while the github tool is selected.
  const [ghToken, setGhToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const me = useMe();
  const [runtime, setRuntime] = useState("claw");
  const openshell = runtime === "openshell";
  // Model gateways and their models, loaded when openshell is picked.
  const [gateways, setGateways] = useState<Gateway[] | null>(null);
  const [defaultModel, setDefaultModel] = useState("");
  const [gatewaysError, setGatewaysError] = useState("");
  useEffect(() => {
    if (!openshell || gateways) return;
    fetch("/api/models", { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => {
        const gws: Gateway[] = Array.isArray(d?.gateways) ? d.gateways : [];
        setGateways(gws);
        setDefaultModel(String(d?.defaultModel ?? ""));
        // Start on the first gateway, with the cluster default model when it serves it.
        if (gws.length) {
          setMProvider(gws[0].name);
          setMId(gws[0].models.some((m) => m.id === d?.defaultModel) ? d.defaultModel : gws[0].models[0]?.id ?? "");
        }
      })
      .catch((e) => setGatewaysError(String(e?.message ?? e)));
  }, [openshell, gateways]);
  const gateway = gateways?.find((g) => g.name === mProvider);
  const gatewayModel = gateway?.models.find((m) => m.id === mId);
  // The longest agent name an openshell namespace leaves room for; the API still decides.
  const maxOpenshellName = me ? OPENSHELL_MAX_NAMESPACE - `agent-${me.username}-`.length : 0;
  // Registered Tools the caller may use, selectable as skills.
  const { tools: mcpTools, loading: mcpLoading, error: mcpError } = useRegisteredTools();

  function toggleSkill(s: string) {
    setSkills((cur) => (cur.includes(s) ? cur.filter((x) => x !== s) : [...cur, s]));
    // Dropping the github tool drops its token too.
    if (s === GITHUB_SKILL && skills.includes(s)) setGhToken("");
  }

  function addToolsDeny() {
    // One name, or a comma-separated list.
    const vals = tdInput.split(",").map((s) => s.trim()).filter(Boolean);
    if (!vals.length) return;
    setToolsDeny((cur) => [...cur, ...vals.filter((v) => !cur.includes(v))]);
    setTdInput("");
  }
  function removeToolsDeny(v: string) {
    setToolsDeny((cur) => cur.filter((x) => x !== v));
  }

  async function onPickWorkspace(files: FileList) {
    const { workspace: ws } = await dirToWorkspace(files);
    setWorkspace(ws);
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      // An openshell agent reaches models only through the cluster's gateways: a gateway and a model it
      // serves, with the size the gateway reports; no URL or key.
      const model = openshell
        ? (mProvider && mId
          ? { provider: mProvider, id: mId, ...(gatewayModel?.contextWindow ? { contextWindow: gatewayModel.contextWindow } : {}) }
          : undefined)
        : mProvider || mId || mName || mBaseUrl || mApiKey
          ? { provider: mProvider, id: mId, name: mName, baseUrl: mBaseUrl, apiKey: mApiKey }
          : undefined;
      const res = await fetch("/api/agents", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        // The API makes the signed-in user the owner.
        body: JSON.stringify({
          name, skills,
          ...(openshell ? { runtime } : {}),
          ...(skills.includes(GITHUB_SKILL) && ghToken.trim() ? { githubToken: ghToken.trim() } : {}),
          ...(toolsDeny.length ? { toolsDeny } : {}),
          ...(webFetchAllowlist.length ? { webFetchAllowlist } : {}),
          ...(Object.keys(workspace).length ? { workspace } : {}),
          ...(model ? { model } : {}),
        }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      const a = data.agent;
      router.push(`/agents/${a.metadata.namespace}/${a.metadata.name}`);
    } catch (e: any) {
      setError(String(e?.message ?? e));
      setBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">Create agent</h1>
      {error && (
        <div className="flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          <AlertTriangle size={14} /> {error}
        </div>
      )}
      <form onSubmit={submit} className="space-y-4">
        <Card>
          <CardContent className="space-y-4 pt-4">
            {me?.runtimes.includes("openshell") && (
              <Field
                label="Runtime"
                hint={
                  openshell
                    ? "OpenClaw in an OpenShell sandbox: every connection the agent opens is checked against its " +
                      "policy, the model key never enters its pod, and code runs in the sandbox itself. " +
                      "Uses the cluster's model. Cannot be changed later."
                    : "OpenClaw as a pod of its own (the default). Cannot be changed later."
                }
              >
                <div className="flex flex-wrap gap-2">
                  {["claw", "openshell"].map((r) => (
                    <CheckboxRow key={r} checked={runtime === r} onChange={() => setRuntime(r)}>
                      {r === "openshell" ? "openshell (sandboxed)" : "claw"}
                    </CheckboxRow>
                  ))}
                </div>
              </Field>
            )}

            <Field
              label="Name"
              htmlFor="name"
              hint={
                "Must start with a lowercase letter, then lowercase letters, digits or '-'. " +
                "A leading digit is rejected because the name becomes the agent's Kubernetes " +
                "Service name, which may not start with one." +
                (openshell
                  ? maxOpenshellName > 0
                    ? ` For openshell, at most ${maxOpenshellName} characters (its namespace agent-${me?.username}-<name> may have 19).`
                    : " Your username leaves no room for an openshell agent name."
                  : "")
              }
            >
              <Input
                id="name"
                type="text"
                value={name}
                placeholder="my-agent"
                onChange={(e) => setName(e.target.value)}
                // The API's naming rule, checked here first; the API still decides.
                pattern="[a-z]([-a-z0-9]*[a-z0-9])?"
                maxLength={openshell && maxOpenshellName > 0 ? maxOpenshellName : undefined}
                title="Start with a lowercase letter, then lowercase letters, digits or '-' (e.g. my-agent)"
                required
              />
            </Field>

            <div>
              <Label>Skills</Label>
              <div className="flex flex-wrap gap-2">
                {ALL_SKILLS.map((s) => (
                  <CheckboxRow key={s} checked={skills.includes(s)} onChange={() => toggleSkill(s)}>
                    {s === "shell" ? (
                      <span title="Unrestricted local exec inside this agent's own pod — no sandboxing, no audit log. Use Tools denied below to scope it down.">
                        shell (unrestricted local exec)
                      </span>
                    ) : (
                      s
                    )}
                  </CheckboxRow>
                ))}
              </div>
            </div>

            <div>
              <Label>MCP server tools</Label>
              {mcpLoading && <p className="text-xs text-muted-foreground">Loading registered tools…</p>}
              {mcpError && <p className="text-xs text-destructive">Could not load tools: {mcpError}</p>}
              <div className="flex flex-wrap gap-2">
                {mcpTools.map((t) => (
                  <CheckboxRow
                    key={t.skill}
                    checked={skills.includes(t.skill)}
                    onChange={() => toggleSkill(t.skill)}
                    title={t.description}
                  >
                    <span>
                      {t.skill}
                      {t.alwaysOn ? " (always on)" : ""}
                    </span>
                  </CheckboxRow>
                ))}
              </div>
              {skills.includes(GITHUB_SKILL) && (
                <div className="mt-3 rounded-md border border-border bg-muted/30 px-3 py-3">
                  <Label htmlFor="gh-token">GitHub PAT (optional)</Label>
                  <SecretInput
                    id="gh-token"
                    value={ghToken}
                    onChange={setGhToken}
                    placeholder="ghp_… / github_pat_… — blank uses the shared cluster-wide token"
                    className="mt-1"
                  />
                  <p className="mt-1.5 text-xs text-muted-foreground">
                    Kept in a Secret only the agent&apos;s identity proxy reads; never in the agent itself.
                    Blank uses the shared token. You can change it later on the agent&apos;s page.
                  </p>
                </div>
              )}
            </div>

            <Field
              label="Tools denied (optional)"
              hint={'Tool names or globs (e.g. "github__list_issues", "github__*") this agent may not call.'}
            >
              <div className="flex flex-wrap gap-2">
                {toolsDeny.map((v) => (
                  <span key={v} className="inline-flex items-center gap-1 rounded-md border border-border bg-background px-2 py-1 text-xs font-mono">
                    {v}
                    <button type="button" onClick={() => removeToolsDeny(v)} className="text-muted-foreground hover:text-destructive">×</button>
                  </span>
                ))}
              </div>
              <div className="mt-2 flex gap-2">
                <Input
                  type="text" placeholder="github__list_issues, github__create_branch, execute_python" value={tdInput}
                  onChange={(e) => setTdInput(e.target.value)}
                  onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); addToolsDeny(); } }}
                  className="flex-1"
                />
                <Button type="button" variant="outline" onClick={addToolsDeny}>+ Add</Button>
              </div>
            </Field>

            <Field
              label="Workspace directory (optional)"
              hint="Persona & rules (AGENTS.md, SOUL.md, IDENTITY.md, TOOLS.md), skills/<name>/SKILL.md, projects/… — seeded into the OpenClaw workspace and loaded at session start."
            >
              <FileDrop onPick={onPickWorkspace} count={Object.keys(workspace).length} names={Object.keys(workspace)} />
            </Field>

            <Field label="web_fetch domain allowlist (optional)">
              <WebFetchAllowlistHint />
              <div className="mt-2">
                <WebFetchAllowlist domains={webFetchAllowlist} onChange={setWebFetchAllowlist} />
              </div>
            </Field>
          </CardContent>
        </Card>

        {openshell && (
          <Card>
            <CardHeader>
              <CardTitle>LLM model</CardTitle>
              <CardDescription>
                The sandbox reaches models only through the cluster&apos;s gateways, which hold any key.
                GenAI Gateway (LiteLLM) applies budgets and the content-safety guardrail; AI Gateway
                (Envoy) goes to the model directly. The lists show what each gateway serves now.
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-3">
              {gatewaysError && <p className="text-xs text-destructive">Could not load models: {gatewaysError}</p>}
              {!gateways && !gatewaysError && <p className="text-xs text-muted-foreground">Loading models…</p>}
              {gateways && (
                <div className="grid grid-cols-2 gap-3">
                  <Field label="Provider" htmlFor="m-provider">
                    <select
                      id="m-provider" value={mProvider}
                      onChange={(e) => {
                        const g = gateways.find((x) => x.name === e.target.value);
                        setMProvider(e.target.value);
                        setMId(g?.models.some((m) => m.id === defaultModel) ? defaultModel : g?.models[0]?.id ?? "");
                      }}
                      className="h-9 w-full rounded-md border border-border bg-background px-2 text-sm"
                    >
                      {gateways.map((g) => <option key={g.name} value={g.name}>{g.label}</option>)}
                    </select>
                  </Field>
                  <Field label="Model" htmlFor="m-model">
                    <select
                      id="m-model" value={mId} onChange={(e) => setMId(e.target.value)} disabled={!gateway?.models.length}
                      className="h-9 w-full rounded-md border border-border bg-background px-2 text-sm"
                    >
                      {gateway?.models.map((m) => (
                        <option key={m.id} value={m.id}>
                          {m.id}{m.id === defaultModel ? " (default)" : ""}{m.contextWindow ? ` · ${Math.round(m.contextWindow / 1024)}k context` : ""}
                        </option>
                      ))}
                    </select>
                  </Field>
                </div>
              )}
              {gateway?.error && <p className="text-xs text-destructive">{gateway.label} did not answer: {gateway.error}</p>}
              {gateway && !gateway.error && !gateway.models.length && (
                <p className="text-xs text-muted-foreground">{gateway.label} serves no chat models right now.</p>
              )}
            </CardContent>
          </Card>
        )}

        {!openshell && (
        <Card>
          <CardHeader>
            <CardTitle>LLM model (optional)</CardTitle>
            <CardDescription>
              Blank uses the cluster default. If set, overrides the model for this agent only. The
              API key is written to a Kubernetes Secret{" "}
              <code className="rounded bg-muted px-1 py-0.5">&lt;name&gt;-model-credentials</code> and
              referenced by the agent — it never appears in the Agent resource.
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <Input placeholder="provider (e.g. openai, auto_router)" value={mProvider} onChange={(e) => setMProvider(e.target.value)} />
              <Input placeholder="model id (e.g. smart_router)" value={mId} onChange={(e) => setMId(e.target.value)} />
            </div>
            <div className="grid grid-cols-3 gap-3">
              <Input placeholder="display name (optional)" value={mName} onChange={(e) => setMName(e.target.value)} className="col-span-1" />
              <Input
                placeholder="base URL (OpenAI-compatible; blank = default)"
                value={mBaseUrl}
                onChange={(e) => setMBaseUrl(e.target.value)}
                className="col-span-2"
              />
            </div>
            <SecretInput
              value={mApiKey}
              onChange={setMApiKey}
              placeholder="API key / token (stored in a per-agent Secret, never in the CR)"
            />
          </CardContent>
        </Card>
        )}

        <p className="text-xs text-muted-foreground">
          Owner is set to your signed-in identity automatically. The agent is created in your{" "}
          <code className="rounded bg-muted px-1 py-0.5">user-&lt;you&gt;</code> namespace.
        </p>

        <div className="flex gap-2">
          <Button type="submit" disabled={busy || !name}>
            {busy ? "Creating…" : "Create agent"}
          </Button>
          <ButtonLink variant="outline" href={"/agents"}>
            Cancel
          </ButtonLink>
        </div>
      </form>
    </div>
  );
}
