// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useCallback, useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { dirToWorkspace, workspaceSummary } from "@/lib/workspace";
import FileDrop from "@/components/FileDrop";
import SecretInput from "@/components/SecretInput";
import Gated from "@/components/Gated";
import WebFetchAllowlist, { WebFetchAllowlistHint } from "@/components/WebFetchAllowlist";
import { useRegisteredTools } from "@/lib/useRegisteredTools";
import { useMe } from "@/lib/useMe";
import { useAdminRole, askReason, breakGlassHeaders } from "@/lib/breakGlass";
import { Button, ButtonLink } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle, CardDescription, CardFooter } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from "@/components/ui/table";
import { AlertTriangle, Check } from "lucide-react";
import { cn } from "@/lib/utils";

// What a grant may confer; `converse` opens the dashboard and chat.
const CAPS = ["view", "suspend-resume", "converse", "delete"] as const;

interface Grant {
  name: string;
  grantee: string;
  capabilities: string[];
  expiresAt: string;
}

function ErrorBanner({ error }: { error: string }) {
  if (!error) return null;
  return (
    <div className="flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
      <AlertTriangle size={14} /> {error}
    </div>
  );
}
function SuccessNote({ msg }: { msg: string }) {
  if (!msg) return null;
  return (
    <div className="flex items-center gap-2 text-xs text-success">
      <Check size={12} /> {msg}
    </div>
  );
}
function CheckboxRow({ checked, onChange, disabled, title, children }: { checked: boolean; onChange: () => void; disabled?: boolean; title?: string; children: React.ReactNode }) {
  return (
    <label
      title={title}
      className={cn(
        "inline-flex items-center gap-2 rounded-md border border-border bg-background px-3 py-1.5 text-sm transition-colors",
        disabled ? "cursor-not-allowed opacity-50" : "hover:border-primary/50"
      )}
    >
      <input type="checkbox" checked={checked} onChange={onChange} disabled={disabled} className="h-3.5 w-3.5 accent-[hsl(var(--primary))] disabled:cursor-not-allowed" />
      {children}
    </label>
  );
}

export default function AgentDetail() {
  const params = useParams<{ ns: string; name: string }>();
  const ns = decodeURIComponent(params.ns);
  const name = decodeURIComponent(params.name);
  const router = useRouter();

  const [agent, setAgent] = useState<any>(null);
  const [isOwner, setIsOwner] = useState(false);
  const [caps, setCaps] = useState<string[]>([]);
  const [grants, setGrants] = useState<Grant[]>([]);
  const [prov, setProv] = useState<{ phase: string; runtime: string; steps: any[] } | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState("");
  const me = useMe();
  const adminRole = useAdminRole(me?.roles);
  // The admin's reason for reading this page; every write asks for its own.
  const [bgReason, setBgReason] = useState("");

  const load = useCallback(async () => {
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        cache: "no-store",
        headers: breakGlassHeaders(bgReason),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setAgent(data.agent);
      setIsOwner(!!data.isOwner);
      setCaps(data.caps ?? []);
      setError("");
      if (data.isOwner) {
        const gr = await fetch(`/api/agents/${ns}/${name}/grants`, { cache: "no-store" });
        if (gr.ok) setGrants((await gr.json()).grants ?? []);
      }
    } catch (e: any) {
      setError(String(e?.message ?? e));
    }
  }, [ns, name, bgReason]);

  // No break-glass header: this polls, and each read with one is audited.
  const loadProvisioning = useCallback(async () => {
    try {
      const res = await fetch(`/api/agents/${ns}/${name}/provisioning`, { cache: "no-store" });
      if (res.ok) setProv(await res.json());
    } catch {
      /* non-fatal */
    }
  }, [ns, name]);

  // Offered when the ordinary read found nothing: for an admin, "not found" and "not
  // yours" are the same answer, and this is the only way to tell them apart.
  function readAsAdmin() {
    const reason = askReason(`read agent "${name}" in ${ns}`);
    if (reason) setBgReason(reason); // load() re-runs on the new reason
  }

  useEffect(() => {
    load();
    loadProvisioning();
    const t = setInterval(loadProvisioning, 4000); // live workflow polling
    return () => clearInterval(t);
  }, [load, loadProvisioning]);

  function openGateway() {
    // The platform gateway signs the user in and admits only the owner and converse grantees.
    window.open(`/gw/${ns}/${name}/`, "_blank", "noopener");
  }

  const has = (c: string) => isOwner || caps.includes(c);
  // This page is showing someone else's agent on admin authority — the caps above came
  // from the break-glass matrix, not from a grant.
  const viaBreakGlass = !isOwner && Boolean(bgReason);
  // One reason per write, never the read's reason reused. Returns undefined for an owner
  // or grantee (no header to send), and null when an admin cancelled the prompt.
  const writeReason = (what: string): string | null | undefined => {
    if (!viaBreakGlass) return undefined;
    return askReason(`${what} agent "${name}", owned by ${agent?.spec?.owner?.principal || "another user"}`);
  };

  async function lifecycle(action: "suspend" | "resume") {
    const reason = writeReason(action);
    if (reason === null) return;
    setBusy(action);
    try {
      const res = await fetch(`/api/agents/${ns}/${name}/${action}`, {
        method: "POST",
        headers: breakGlassHeaders(reason),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      await load();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy("");
    }
  }

  async function remove() {
    if (!confirm(`Delete agent "${name}"?`)) return;
    const reason = writeReason("delete");
    if (reason === null) return;
    setBusy("delete");
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, { method: "DELETE", headers: breakGlassHeaders(reason) });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      router.push("/agents");
    } catch (e: any) {
      setError(String(e?.message ?? e));
      setBusy("");
    }
  }



  if (!agent) {
    return (
      <div className="space-y-4">
        <h1 className="text-lg font-semibold">{name}</h1>
        {error ? <ErrorBanner error={error} /> : <p className="text-sm text-muted-foreground">Loading…</p>}
        {/* Same 404 whether the agent is missing or not theirs; an admin may retry with a reason. */}
        {error && adminRole && !bgReason && (
          <div className="space-y-1">
            <Button variant="outline" onClick={readAsAdmin}>Read as {adminRole} (break-glass)</Button>
            <p className="text-xs text-muted-foreground">
              If this agent exists but belongs to someone else, your admin role can read it
              with a reason. The read is audited under your name.
            </p>
          </div>
        )}
        <ButtonLink variant="outline" href={"/agents"}>← Back</ButtonLink>
      </div>
    );
  }

  const spec = agent.spec || {};
  const status = agent.status || {};
  // Prefer the PROVISIONING phase: load() runs once, that poll runs every 4s. Without
  // this, hitting Suspend leaves the buttons following a phase from page-load time.
  const phase = prov?.phase || status.phase;
  const suspended = phase === "IdleSuspended" || (spec.desiredState || "Running") === "Suspended";

  // Not ready until provisioning says so, so a button never opens a dashboard that is not there.
  const step = (key: string) => prov?.steps?.find((s: any) => s.key === key)?.state;
  const podReady = step("pod") === "ok";

  // One wording for both reasons, used by Chat and the gateway button. Suspended is
  // checked first: "resume it first" is the actionable half when both are true.
  const liveReason = suspended
    ? "Agent is suspended — resume it first"
    : !podReady
      ? "Waiting for the agent's pod to be ready"
      : "";

  return (
    <div className="space-y-6">
      <h1 className="text-lg font-semibold">
        {name}{" "}
        <span className="text-sm font-normal text-muted-foreground">
          {isOwner ? "· owner" : viaBreakGlass ? `· ${adminRole} break-glass` : "· shared with you"}
        </span>
      </h1>
      {/* Always shown: the admin is on someone else's agent, and every action is audited. */}
      {viaBreakGlass && (
        <div className="rounded-md border border-warning/30 bg-warning/10 px-3 py-2 text-xs text-warning">
          Viewing {spec.owner?.principal || "another user"}&apos;s agent as <strong>{adminRole}</strong>.
          Reason recorded: {bgReason}. Each action asks for its own reason.
        </div>
      )}
      <ErrorBanner error={error} />

      <Card>
        <CardContent className="pt-4">
          <dl className="grid grid-cols-1 gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
            <Kv k="Owner" v={spec.owner?.principal} />
            <Kv k="Namespace" v={ns} />
            <Kv k="Skills" v={(spec.skills || []).join(", ")} />
            <Kv k="Tools denied" v={(spec.toolsDeny || []).length ? (spec.toolsDeny || []).join(", ") : "—"} />
            <Kv
              k="Model"
              v={
                spec.model?.provider || spec.model?.id ? (
                  <>
                    {spec.model?.name || spec.model?.id}{" "}
                    <span className="text-muted-foreground">
                      ({spec.model?.provider || "?"}/{spec.model?.id || "?"})
                    </span>
                    {spec.model?.baseUrl && <div className="text-xs text-muted-foreground">{spec.model.baseUrl}</div>}
                    {spec.modelSecretRef && <div className="text-xs text-muted-foreground">key: {spec.modelSecretRef}</div>}
                  </>
                ) : (
                  <span className="text-muted-foreground">cluster default</span>
                )
              }
            />
            {/* `phase`, not status.phase — the polled value, so this line and the
                buttons below it never disagree. */}
            <Kv k="Phase" v={`${phase}${status.suspendReason ? ` (${status.suspendReason})` : ""}`} />
            <Kv k="Desired" v={spec.desiredState || "Running"} />
            <Kv k="Memory" v={status.memoryRef || "—"} />
            <Kv k="Backend" v={status.backendRef ? `${status.backendRef.kind}/${status.backendRef.name}` : "—"} />
          </dl>
        </CardContent>
        <CardFooter className="flex-wrap">
          {has("suspend-resume") &&
            (suspended ? (
              <Button variant="secondary" disabled={!!busy} onClick={() => lifecycle("resume")}>Resume</Button>
            ) : (
              <Button variant="secondary" disabled={!!busy} onClick={() => lifecycle("suspend")}>Suspend</Button>
            ))}
          {/* Grayed, not hidden, until the agent is up; a gated Chat link renders as a disabled button. */}
          {has("converse") &&
            (liveReason ? (
              <Gated reason={liveReason}>
                <Button disabled>Chat</Button>
              </Gated>
            ) : (
              <ButtonLink href={`/agents/${ns}/${name}/chat`}>Chat</ButtonLink>
            ))}
          {has("converse") && (
            <Gated reason={liveReason}>
              <Button variant="outline" disabled={!!busy || !!liveReason} onClick={openGateway}>
                Open dashboard ↗
              </Button>
            </Gated>
          )}
          {/* Not gated on readiness: an agent that never becomes ready must stay removable. */}
          {has("delete") && <Button variant="destructive" disabled={!!busy} onClick={remove}>Delete</Button>}
          <ButtonLink variant="outline" href={"/agents"}>← Back</ButtonLink>
        </CardFooter>
      </Card>

      <section className="space-y-2">
        <div>
          <h2 className="text-base font-semibold">Provisioning workflow</h2>
          <p className="text-xs text-muted-foreground">Live status of each component the operator provisions (polls every 4s).</p>
        </div>
        <Card>
          <CardContent className="pt-4">
            {!prov ? (
              <p className="text-sm text-muted-foreground">Loading status…</p>
            ) : (
              <div className="flex flex-col">
                {prov.steps.map((s: any, i: number) => (
                  <div key={s.key} className="relative flex items-center gap-3 py-1.5">
                    {i > 0 && <span className="absolute left-[6px] top-[-10px] h-2.5 w-px bg-border" />}
                    <span
                      className={cn(
                        "h-3 w-3 flex-none rounded-full border-2",
                        s.state === "ok" && "border-success bg-success shadow-[0_0_6px_hsl(var(--success)/0.6)]",
                        s.state === "pending" && "animate-pulse border-warning bg-transparent",
                        s.state === "error" && "border-destructive bg-destructive",
                        s.state === "na" && "border-border bg-border"
                      )}
                      title={s.state}
                    />
                    <span className="min-w-[160px] text-sm font-medium">{s.label}</span>
                    <span className="text-xs text-muted-foreground">{s.detail}</span>
                  </div>
                ))}
              </div>
            )}
          </CardContent>
        </Card>
      </section>

      {isOwner && (
        <ModelEditor ns={ns} name={name} model={spec.model || {}} modelSecretRef={spec.modelSecretRef} reload={load} />
      )}

      {isOwner && (
        <SkillsEditor ns={ns} name={name} skills={spec.skills || []} tools={spec.tools || []} reload={load} />
      )}

      {isOwner && (
        <ToolsDenyEditor ns={ns} name={name} toolsDeny={spec.toolsDeny || []} reload={load} />
      )}

      {isOwner && (spec.skills || []).includes("github") && (
        <GithubTokenEditor ns={ns} name={name} githubTokenSecretRef={spec.githubTokenSecretRef} reload={load} />
      )}

      {isOwner && (
        <WebFetchAllowlistEditor ns={ns} name={name} webFetchAllowlist={spec.webFetchAllowlist || []} reload={load} />
      )}

      {isOwner && (
        <WorkspaceEditor ns={ns} name={name} workspace={spec.workspace || {}} reload={load} />
      )}

      {isOwner && (
        <SharePanel ns={ns} name={name} grants={grants} reload={load} />
      )}
    </div>
  );
}

function Kv({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <>
      <dt className="text-muted-foreground">{k}</dt>
      <dd className="sm:col-start-2">{v}</dd>
    </>
  );
}

function ModelEditor({
  ns, name, model, modelSecretRef, reload,
}: {
  ns: string; name: string;
  model: { provider?: string; id?: string; name?: string; baseUrl?: string };
  modelSecretRef?: string; reload: () => void;
}) {
  const [provider, setProvider] = useState(model.provider || "");
  const [id, setId] = useState(model.id || "");
  const [dispName, setDispName] = useState(model.name || "");
  const [baseUrl, setBaseUrl] = useState(model.baseUrl || "");
  const [apiKey, setApiKey] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [msg, setMsg] = useState("");

  async function save() {
    setBusy(true); setError(""); setMsg("");
    try {
      const body: any = { model: { provider, id, name: dispName, baseUrl } };
      if (apiKey) body.modelApiKey = apiKey;
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Saved — operator is re-provisioning the backend (pod will roll).");
      setApiKey("");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">Model</h2>
        <p className="text-xs text-muted-foreground">
          Leave blank to use the cluster-default model. Changing any field re-provisions the backend
          (pod rolls). The API key is stored in a per-agent Secret and never appears here or in the
          agent resource.
        </p>
      </div>
      <ErrorBanner error={error} />
      <SuccessNote msg={msg} />
      <Card>
        <CardContent className="space-y-3 pt-4">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <Label htmlFor="m-provider">Provider</Label>
              <Input id="m-provider" type="text" placeholder="e.g. openai, auto_router" value={provider} onChange={(e) => setProvider(e.target.value)} />
            </div>
            <div>
              <Label htmlFor="m-id">Model id</Label>
              <Input id="m-id" type="text" placeholder="e.g. smart_router" value={id} onChange={(e) => setId(e.target.value)} />
            </div>
          </div>
          <div className="grid grid-cols-3 gap-3">
            <div>
              <Label htmlFor="m-name">Display name</Label>
              <Input id="m-name" type="text" placeholder="optional" value={dispName} onChange={(e) => setDispName(e.target.value)} />
            </div>
            <div className="col-span-2">
              <Label htmlFor="m-baseurl">Base URL</Label>
              <Input id="m-baseurl" type="text" placeholder="OpenAI-compatible; blank = default endpoint" value={baseUrl} onChange={(e) => setBaseUrl(e.target.value)} />
            </div>
          </div>
          <div>
            <Label htmlFor="m-key">API key / token</Label>
            <SecretInput id="m-key" value={apiKey} onChange={setApiKey}
              placeholder={modelSecretRef ? "leave blank to keep the current key" : "no key set"} />
            {modelSecretRef && <p className="mt-1 text-xs text-muted-foreground">Current key secret: {modelSecretRef}</p>}
          </div>
        </CardContent>
        <CardFooter>
          <Button disabled={busy} onClick={save}>{busy ? "Saving…" : "Save model"}</Button>
        </CardFooter>
      </Card>
    </section>
  );
}

function GithubTokenEditor({
  ns, name, githubTokenSecretRef, reload,
}: {
  ns: string; name: string; githubTokenSecretRef?: string; reload: () => void;
}) {
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [msg, setMsg] = useState("");

  async function save() {
    if (!token) return;
    setBusy(true); setError(""); setMsg("");
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ githubToken: token }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Saved — this agent now uses its own GitHub token.");
      setToken("");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  async function clear() {
    if (!confirm("Clear this agent's own GitHub token? It will fall back to the shared cluster-wide token.")) return;
    setBusy(true); setError(""); setMsg("");
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ clearGithubToken: true }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Cleared — this agent now uses the shared cluster-wide GitHub token.");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">GitHub token</h2>
        <p className="text-xs text-muted-foreground">
          Optional — give this agent its OWN GitHub PAT, distinct from every other agent&apos;s.
          Leave unset to use the shared cluster-wide token (mcp-github-server&apos;s default). The
          token is stored in a per-agent Secret and never appears here or in the agent resource.
        </p>
      </div>
      <ErrorBanner error={error} />
      <SuccessNote msg={msg} />
      <Card>
        <CardContent className="pt-4">
          <Label htmlFor="gh-token">Personal access token</Label>
          <SecretInput id="gh-token" value={token} onChange={setToken}
            placeholder={githubTokenSecretRef ? "leave blank to keep the current token" : "using shared cluster-wide token"} />
          {githubTokenSecretRef && <p className="mt-1 text-xs text-muted-foreground">Current token secret: {githubTokenSecretRef}</p>}
        </CardContent>
        <CardFooter>
          <Button disabled={busy || !token} onClick={save}>{busy ? "Saving…" : "Save token"}</Button>
          {githubTokenSecretRef && <Button variant="destructive" disabled={busy} onClick={clear}>Clear (use shared token)</Button>}
        </CardFooter>
      </Card>
    </section>
  );
}

function SkillsEditor({
  ns, name, skills, tools, reload,
}: { ns: string; name: string; skills: string[]; tools: { name: string; url: string }[]; reload: () => void }) {
  const [sel, setSel] = useState<string[]>(skills);
  const [mcp, setMcp] = useState<{ name: string; url: string }[]>(tools);
  const [tn, setTn] = useState("");
  const [tu, setTu] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [error, setError] = useState("");
  // Registered Tools the caller may use, selectable as skills.
  const { tools: mcpTools, loading: mcpLoading, error: mcpError } = useRegisteredTools();

  // OpenClaw capabilities that change its configuration; read and list are always on.
  const ALL_SKILLS = [
    "shell", "browser-automation", "diagram-maker", "canvas",
  ];

  function toggle(s: string) {
    setSel((c) => (c.includes(s) ? c.filter((x) => x !== s) : [...c, s]));
  }
  function addTool() {
    if (!tn || !tu) return;
    setMcp((c) => [...c.filter((t) => t.name !== tn), { name: tn, url: tu }]);
    setTn(""); setTu("");
  }
  function removeTool(n: string) {
    setMcp((c) => c.filter((t) => t.name !== n));
  }

  async function save() {
    setBusy(true); setError(""); setMsg("");
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ skills: sel, tools: mcp }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Saved — operator is re-provisioning the backend (pod will roll).");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">Skills &amp; MCP tools</h2>
        <p className="text-xs text-muted-foreground">
          Edit capabilities on a running agent. Saving re-provisions the backend (the operator
          re-renders config and rolls the pod), so changes go live.
        </p>
      </div>
      <ErrorBanner error={error} />
      <SuccessNote msg={msg} />
      <Card>
        <CardContent className="space-y-4 pt-4">
          <div>
            <Label>Skills</Label>
            <div className="flex flex-wrap gap-2">
              {ALL_SKILLS.map((s) => (
                <CheckboxRow key={s} checked={sel.includes(s)} onChange={() => toggle(s)}>
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
                  checked={sel.includes(t.skill)}
                  onChange={() => toggle(t.skill)}
                  title={t.description}
                >
                  <span>
                    {t.skill}
                    {t.alwaysOn ? " (always on)" : ""}
                  </span>
                </CheckboxRow>
              ))}
            </div>
          </div>

          <div>
            <Label>Custom MCP tools</Label>
            {mcp.length > 0 && (
              <Table>
                <TableHeader><TableRow><TableHead>Name</TableHead><TableHead>URL (SSE)</TableHead><TableHead /></TableRow></TableHeader>
                <TableBody>
                  {mcp.map((t) => (
                    <TableRow key={t.name}>
                      <TableCell>{t.name}</TableCell>
                      <TableCell className="text-xs text-muted-foreground">{t.url}</TableCell>
                      <TableCell><Button size="sm" variant="destructive" onClick={() => removeTool(t.name)}>Remove</Button></TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
            <div className="mt-2 flex gap-2">
              <Input type="text" placeholder="tool name" value={tn} onChange={(e) => setTn(e.target.value)} className="max-w-[200px]" />
              <Input type="text" placeholder="http://mcp-...svc:8000/sse" value={tu} onChange={(e) => setTu(e.target.value)} className="flex-1" />
              <Button variant="outline" onClick={addTool}>+ Add tool</Button>
            </div>
          </div>
        </CardContent>
        <CardFooter>
          <Button disabled={busy} onClick={save}>{busy ? "Saving…" : "Save & re-provision"}</Button>
        </CardFooter>
      </Card>
    </section>
  );
}

function WebFetchAllowlistEditor({
  ns, name, webFetchAllowlist, reload,
}: { ns: string; name: string; webFetchAllowlist: string[]; reload: () => void }) {
  const [domains, setDomains] = useState<string[]>(webFetchAllowlist);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [error, setError] = useState("");

  async function save() {
    setBusy(true); setError(""); setMsg("");
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ webFetchAllowlist: domains }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Saved — the agent's web_fetch proxy allowlist updates immediately, no pod restart needed.");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">web_fetch domain allowlist</h2>
        <WebFetchAllowlistHint />
      </div>
      <ErrorBanner error={error} />
      <SuccessNote msg={msg} />
      <Card>
        <CardContent className="pt-4">
          <WebFetchAllowlist domains={domains} onChange={setDomains} />
        </CardContent>
        <CardFooter>
          <Button disabled={busy} onClick={save}>{busy ? "Saving…" : "Save"}</Button>
        </CardFooter>
      </Card>
    </section>
  );
}

function ToolsDenyEditor({
  ns, name, toolsDeny, reload,
}: { ns: string; name: string; toolsDeny: string[]; reload: () => void }) {
  const [deny, setDeny] = useState<string[]>(toolsDeny);
  const [t, setT] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [error, setError] = useState("");

  function addTool() {
    // One name, or a comma-separated list.
    const vals = t.split(",").map((s) => s.trim()).filter(Boolean);
    if (!vals.length) return;
    setDeny((c) => [...c, ...vals.filter((v) => !c.includes(v))]);
    setT("");
  }
  function removeTool(v: string) {
    setDeny((c) => c.filter((x) => x !== v));
  }

  async function save() {
    setBusy(true); setError(""); setMsg("");
    try {
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ toolsDeny: deny }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Saved — operator is re-provisioning the backend (pod will roll).");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">Tools denied on this agent</h2>
        <p className="text-xs text-muted-foreground">
          Tool names or globs (e.g. <code className="rounded bg-muted px-1 py-0.5">github__list_issues</code>,{" "}
          <code className="rounded bg-muted px-1 py-0.5">github__*</code>) this agent may not call, on top of its skills.
        </p>
      </div>
      <ErrorBanner error={error} />
      <SuccessNote msg={msg} />
      <Card>
        <CardContent className="pt-4">
          {deny.length > 0 && (
            <Table>
              <TableHeader><TableRow><TableHead>Tool name / glob</TableHead><TableHead /></TableRow></TableHeader>
              <TableBody>
                {deny.map((v) => (
                  <TableRow key={v}>
                    <TableCell className="font-mono text-xs">{v}</TableCell>
                    <TableCell><Button size="sm" variant="destructive" onClick={() => removeTool(v)}>Remove</Button></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          <div className="mt-2 flex gap-2">
            <Input
              type="text" placeholder="github__list_issues, github__create_branch, execute_python" value={t}
              onChange={(e) => setT(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); addTool(); } }}
              className="flex-1"
            />
            <Button variant="outline" onClick={addTool}>+ Add denied tool</Button>
          </div>
        </CardContent>
        <CardFooter>
          <Button disabled={busy} onClick={save}>{busy ? "Saving…" : "Save & re-provision"}</Button>
        </CardFooter>
      </Card>
    </section>
  );
}

function WorkspaceEditor({
  ns, name, workspace, reload,
}: { ns: string; name: string; workspace: Record<string, string>; reload: () => void }) {
  // Start from the current CR workspace; uploading a folder REPLACES the map.
  const [ws, setWs] = useState<Record<string, string>>(workspace);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState("");
  const [error, setError] = useState("");

  async function onPick(files: FileList) {
    const { workspace: next } = await dirToWorkspace(files);
    setWs(next);
    setMsg("");
  }

  function removeFile(path: string) {
    setWs((c) => {
      const n = { ...c };
      delete n[path];
      return n;
    });
  }

  async function save() {
    setBusy(true); setError(""); setMsg("");
    try {
      // Empty map clears the workspace (full replace via merge-patch on the map).
      const res = await fetch(`/api/agents/${ns}/${name}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ workspace: ws }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setMsg("Saved — operator re-provisions the backend, rolls the pod, and re-seeds the workspace.");
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  const paths = Object.keys(ws).sort();

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">Workspace files</h2>
        <p className="text-xs text-muted-foreground">
          Files seeded into the agent&apos;s OpenClaw workspace (AGENTS.md, SOUL.md, TOOLS.md,
          skills/&lt;name&gt;/SKILL.md, projects/…). Uploading a folder replaces the current set.
          Saving rolls the pod and re-seeds the files.
        </p>
      </div>
      <ErrorBanner error={error} />
      <SuccessNote msg={msg} />
      <Card>
        <CardContent className="space-y-3 pt-4">
          {paths.length > 0 ? (
            <Table>
              <TableHeader><TableRow><TableHead>Path</TableHead><TableHead>Type</TableHead><TableHead /></TableRow></TableHeader>
              <TableBody>
                {paths.map((p) => (
                  <TableRow key={p}>
                    <TableCell className="text-xs">{p}</TableCell>
                    <TableCell className="text-xs text-muted-foreground">{ws[p].startsWith("base64:") ? "binary" : "text"}</TableCell>
                    <TableCell><Button size="sm" variant="destructive" onClick={() => removeFile(p)}>Remove</Button></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          ) : (
            <p className="text-sm text-muted-foreground">No workspace files.</p>
          )}
          <div>
            <Label>Upload / replace with a directory</Label>
            <FileDrop onPick={onPick} count={Object.keys(ws).length} names={Object.keys(ws)} />
          </div>
        </CardContent>
        <CardFooter>
          <Button disabled={busy} onClick={save}>{busy ? "Saving…" : "Save & re-seed"}</Button>
          <span className="text-xs text-muted-foreground">{workspaceSummary(ws)}</span>
        </CardFooter>
      </Card>
    </section>
  );
}

function SharePanel({
  ns, name, grants, reload,
}: { ns: string; name: string; grants: Grant[]; reload: () => void }) {
  const [grantee, setGrantee] = useState("");
  const [caps, setCaps] = useState<string[]>(["view"]);
  const [hours, setHours] = useState(24);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  function toggle(list: string[], set: (v: string[]) => void, v: string) {
    set(list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);
  }

  async function share(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const expiresAt = new Date(Date.now() + hours * 3600_000).toISOString();
      const res = await fetch(`/api/agents/${ns}/${name}/grants`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ grantee, capabilities: caps, expiresAt }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setGrantee("");
      setCaps(["view"]);
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  async function revoke(g: Grant) {
    if (!confirm(`Revoke access for ${g.grantee}?`)) return;
    try {
      const res = await fetch(`/api/agents/${ns}/${name}/grants/${g.name}`, { method: "DELETE" });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      reload();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    }
  }

  return (
    <section className="space-y-2">
      <div>
        <h2 className="text-base font-semibold">Share access</h2>
        <p className="text-xs text-muted-foreground">
          Give another user time-limited access. Sharing never transfers ownership.
        </p>
      </div>
      <ErrorBanner error={error} />

      {grants.length > 0 && (
        <Table>
          <TableHeader>
            <TableRow><TableHead>Grantee</TableHead><TableHead>Capabilities</TableHead><TableHead>Expires</TableHead><TableHead /></TableRow>
          </TableHeader>
          <TableBody>
            {grants.map((g) => (
              <TableRow key={g.name}>
                <TableCell>{g.grantee}</TableCell>
                <TableCell>
                  <div className="flex flex-wrap gap-1">
                    {g.capabilities.map((c) => <Badge key={c} variant="secondary">{c}</Badge>)}
                  </div>
                </TableCell>
                <TableCell className="text-muted-foreground">{new Date(g.expiresAt).toLocaleString()}</TableCell>
                <TableCell><Button size="sm" variant="destructive" onClick={() => revoke(g)}>Revoke</Button></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}

      <Card>
        <form onSubmit={share}>
          <CardContent className="space-y-3 pt-4">
            <div>
              <Label htmlFor="grantee">Grantee email</Label>
              <Input id="grantee" type="email" value={grantee} placeholder="bob@example.com" onChange={(e) => setGrantee(e.target.value)} required />
            </div>

            <div>
              <Label>Capabilities</Label>
              <div className="flex flex-wrap gap-2">
                {CAPS.map((c) => (
                  <CheckboxRow key={c} checked={caps.includes(c)} onChange={() => toggle(caps, setCaps, c)}>{c}</CheckboxRow>
                ))}
              </div>
              <p className="mt-2 text-xs text-muted-foreground">
                <strong>converse</strong> = chat with the agent and open its dashboard. Revoking a
                grant ends access within a minute.
              </p>
            </div>


            <div>
              <Label htmlFor="hours">Expires in (hours)</Label>
              <Input id="hours" type="text" value={hours}
                onChange={(e) => setHours(Math.max(1, parseInt(e.target.value || "1", 10)))} className="max-w-[160px]" />
            </div>
          </CardContent>
          <CardFooter>
            <Button type="submit" disabled={busy || !grantee || caps.length === 0}>
              {busy ? "Sharing…" : "Share"}
            </Button>
          </CardFooter>
        </form>
      </Card>
    </section>
  );
}
