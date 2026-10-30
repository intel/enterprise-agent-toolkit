// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useCallback, useEffect, useState } from "react";
import { useMe } from "@/lib/useMe";
import { useAdminRole, askReason, breakGlassHeaders } from "@/lib/breakGlass";
import { Button, ButtonLink } from "@/components/ui/button";
import Gated from "@/components/Gated";
import { Badge } from "@/components/ui/badge";
import { Table, TableHeader, TableBody, TableRow, TableHead, TableCell } from "@/components/ui/table";
import { Card, CardContent } from "@/components/ui/card";
import { AlertTriangle, PawPrint, RefreshCw, ShieldAlert } from "lucide-react";

interface AgentRow {
  name: string;
  namespace: string;
  owner: string;
  skills: string[];
  runtime: string;
  role: string;
  desiredState: string;
  phase: string;
  suspendReason: string;
  age: string;
  // Live pod-readiness (see agent-backend's attachPodReadiness): null while
  // desiredState=Suspended (no pod expected) or not yet checked.
  podReady: boolean | null;
}
interface SharedRow extends AgentRow {
  grantedCaps: string[];
  grantExpiresAt: string;
}

// podReady (the operator's PodReady condition) tracks start-up; the phase alone does not.
function phaseDisplay(a: { phase: string; desiredState: string; podReady: boolean | null }): {
  label: string;
  variant: "success" | "warning" | "default" | "muted";
  spinning: boolean;
} {
  if (a.phase === "Failed") return { label: "Failed", variant: "muted", spinning: false };
  if (a.desiredState === "Suspended") return { label: a.phase || "IdleSuspended", variant: "warning", spinning: false };
  if (a.podReady === true) return { label: "Running", variant: "success", spinning: false };
  const label = a.phase && a.phase !== "Unknown" && a.phase !== "IdleSuspended" ? a.phase : "Starting";
  return { label, variant: "default", spinning: true };
}
function ageOf(ts: string): string {
  if (!ts) return "";
  const secs = Math.max(0, (Date.now() - new Date(ts).getTime()) / 1000);
  if (secs < 3600) return `${Math.floor(secs / 60)}m`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h`;
  return `${Math.floor(secs / 86400)}d`;
}

function PhasePill({ a }: { a: { phase: string; desiredState: string; podReady: boolean | null } }) {
  const pd = phaseDisplay(a);
  return (
    <Badge variant={pd.variant}>
      {pd.spinning && <span className="spinner" aria-hidden="true" />}
      {pd.label}
    </Badge>
  );
}

export default function AgentsPage() {
  const [owned, setOwned] = useState<AgentRow[]>([]);
  const [shared, setShared] = useState<SharedRow[]>([]);
  const [error, setError] = useState<string>("");
  const [busy, setBusy] = useState<string>("");
  // The realm-wide list, only ever populated by an explicit break-glass click.
  // null = never asked for, which is a different thing from "asked and empty".
  const [all, setAll] = useState<AgentRow[] | null>(null);
  const [allAt, setAllAt] = useState<string>("");
  // What break-glass actually confers on someone else's agent, straight from the
  // backend's own matrix — never a copy of it in here.
  const [adminCaps, setAdminCaps] = useState<string[]>([]);
  const me = useMe();
  const adminRole = useAdminRole(me?.roles);

  const load = useCallback(async () => {
    try {
      const res = await fetch("/api/agents", { cache: "no-store" });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      setOwned(data.owned ?? []);
      setShared(data.shared ?? []);
      setError("");
    } catch (e: any) {
      setError(String(e?.message ?? e));
    }
  }, []);

  useEffect(() => {
    load();
    const t = setInterval(load, 10000);
    return () => clearInterval(t);
  }, [load]);

  // Every agent, on demand only: each listing is one audit row under the admin's reason.
  async function loadAll() {
    const reason = askReason("list every agent in the realm");
    if (!reason) return;
    setBusy("admin:list");
    try {
      const res = await fetch("/api/agents", {
        cache: "no-store",
        headers: breakGlassHeaders(reason),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      // Without the admin role the API returns the normal list, so a missing `all` is a refusal.
      if (!Array.isArray(data.all)) {
        throw new Error("admin listing was not granted for this session — your token holds no admin role, or role enforcement is off");
      }
      setAll(data.all);
      setAdminCaps(data.adminCaps ?? []);
      setAllAt(new Date().toLocaleTimeString());
      setError("");
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy("");
    }
  }

  async function act(a: AgentRow, action: "suspend" | "resume", reason?: string) {
    setBusy(`${a.name}:${action}`);
    try {
      const res = await fetch(`/api/agents/${a.namespace}/${a.name}/${action}`, { method: "POST", headers: breakGlassHeaders(reason) });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      await load();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy("");
    }
  }

  async function remove(a: AgentRow, reason?: string) {
    if (!confirm(`Delete agent "${a.name}"? This removes its namespace, PVC and identity.`)) return;
    setBusy(`${a.name}:delete`);
    try {
      const res = await fetch(`/api/agents/${a.namespace}/${a.name}`, { method: "DELETE", headers: breakGlassHeaders(reason) });
      const data = await res.json();
      if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
      await load();
    } catch (e: any) {
      setError(String(e?.message ?? e));
    } finally {
      setBusy("");
    }
  }

  // The dashboard, through the platform gateway, which signs the user in and authorizes them.
  function openClaw(a: AgentRow) {
    window.open(`/gw/${a.namespace}/${a.name}/`, "_blank", "noopener");
  }

  // No caps = the caller owns it; admin rows come from break-glass and prompt per action.
  function lifecycleButtons(a: AgentRow, caps?: string[], admin?: boolean) {
    const canLifecycle = !caps || caps.includes("suspend-resume");
    const canDelete = !caps || caps.includes("delete");
    // Not offered on admin rows: a browser navigation cannot carry a break-glass reason.
    const canOpen = !admin && (!caps || caps.includes("converse"));
    const suspended = a.phase === "IdleSuspended" || a.desiredState === "Suspended";
    // null = suspended or not yet known: not ready either way.
    const liveReason = suspended
      ? "Agent is suspended — resume it first"
      : a.podReady === true
        ? ""
        : "Waiting for the agent's pod to be ready";
    // One reason per action (see lib/breakGlass.ts). null = the operator cancelled the
    // prompt, so nothing is sent.
    const withReason = (what: string, run: (reason?: string) => void) => () => {
      if (!admin) return run();
      const reason = askReason(`${what} ${a.owner || "another user"}'s agent "${a.name}"`);
      if (reason) run(reason);
    };
    return (
      <div className="flex flex-wrap gap-1.5">
        {canLifecycle &&
          (suspended ? (
            <Button size="sm" variant="secondary" disabled={!!busy}
              onClick={withReason("resume", (r) => act(a, "resume", r))}>
              Resume
            </Button>
          ) : (
            <Button size="sm" variant="secondary" disabled={!!busy}
              onClick={withReason("suspend", (r) => act(a, "suspend", r))}>
              Suspend
            </Button>
          ))}
        {/* Grayed with the reason rather than hidden, and gated on podReady — same
            rule as the detail page's gateway button. */}
        {canOpen && (
          <Gated reason={liveReason}>
            <Button size="sm" variant="outline" disabled={!!busy || !!liveReason} onClick={() => openClaw(a)}
              title={liveReason ? undefined : "Open dashboard"}>
              <PawPrint size={13} /> Claw ↗
            </Button>
          </Gated>
        )}
        {canDelete && (
          <Button size="sm" variant="destructive" disabled={!!busy}
            onClick={withReason("delete", (r) => remove(a, r))}>
            Delete
          </Button>
        )}
      </div>
    );
  }

  function rows(list: AgentRow[], sharedList?: SharedRow[]) {
    const items: any[] = sharedList ?? list;
    return items.map((a: any) => (
      <TableRow key={`${a.namespace}/${a.name}`}>
        <TableCell>
          <a className="font-medium text-primary hover:underline" href={`/agents/${a.namespace}/${a.name}`}>
            {a.name}
          </a>
          <div className="text-xs text-muted-foreground">{a.namespace}</div>
        </TableCell>
        {sharedList && <TableCell className="text-muted-foreground">{a.owner}</TableCell>}
        <TableCell>{a.runtime}</TableCell>
        <TableCell className="text-xs text-muted-foreground">{a.skills.join(", ")}</TableCell>
        <TableCell>
          <PhasePill a={a} />
          {a.suspendReason && <div className="mt-1 text-[11px] text-muted-foreground">{a.suspendReason}</div>}
        </TableCell>
        {sharedList && (
          <TableCell className="text-xs text-muted-foreground">
            <div className="flex flex-wrap gap-1">
              {a.grantedCaps.map((c: string) => (
                <Badge key={c} variant="secondary">{c}</Badge>
              ))}
            </div>
            <div className="mt-1">until {new Date(a.grantExpiresAt).toLocaleString()}</div>
          </TableCell>
        )}
        <TableCell className="text-muted-foreground">{ageOf(a.age)}</TableCell>
        <TableCell>{lifecycleButtons(a, sharedList ? a.grantedCaps : undefined)}</TableCell>
      </TableRow>
    ));
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold">
          My agents <span className="text-sm font-normal text-muted-foreground">({owned.length})</span>
        </h1>
        <div className="flex gap-2">
          <ButtonLink href={"/agents/new"}>+ Create</ButtonLink>
          <Button variant="outline" size="icon" onClick={load} title="Refresh">
            <RefreshCw size={14} />
          </Button>
        </div>
      </div>

      {error && (
        <div className="flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          <AlertTriangle size={14} /> {error}
        </div>
      )}

      {owned.length === 0 ? (
        <Card>
          <CardContent className="pt-4 text-sm text-muted-foreground">
            You have no agents.{" "}
            <a className="text-primary hover:underline" href={"/agents/new"}>
              Create one →
            </a>
          </CardContent>
        </Card>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Name</TableHead>
              <TableHead>Runtime</TableHead>
              <TableHead>Skills</TableHead>
              <TableHead>Phase</TableHead>
              <TableHead>Age</TableHead>
              <TableHead>Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>{rows(owned)}</TableBody>
        </Table>
      )}

      {shared.length > 0 && (
        <div className="space-y-2">
          <div>
            <h2 className="text-base font-semibold">
              Shared with me <span className="text-sm font-normal text-muted-foreground">({shared.length})</span>
            </h2>
            <p className="text-xs text-muted-foreground">
              Agents another user has shared with you (scoped, time-boxed).
            </p>
          </div>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Name</TableHead>
                <TableHead>Owner</TableHead>
                <TableHead>Runtime</TableHead>
                <TableHead>Skills</TableHead>
                <TableHead>Phase</TableHead>
                <TableHead>Granted</TableHead>
                <TableHead>Age</TableHead>
                <TableHead>Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>{rows([], shared)}</TableBody>
          </Table>
        </div>
      )}

      {/* Admins only, and empty until clicked: the one view of agents the caller has no relation to. */}
      {adminRole && (
        <div className="space-y-2">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="flex items-center gap-1.5 text-base font-semibold">
                <ShieldAlert size={15} className="text-warning" />
                All agents
                <Badge variant="warning">{adminRole}</Badge>
                {all && <span className="text-sm font-normal text-muted-foreground">({all.length})</span>}
              </h2>
              <p className="text-xs text-muted-foreground">
                Break-glass: every agent in the realm, including other people&apos;s. Each
                read and each action is written to the audit log with your name and the
                reason you give. Not refreshed automatically — one click, one audit row.
                {allAt && <> Taken at {allAt}.</>}
              </p>
            </div>
            <Button variant="outline" size="sm" disabled={!!busy} onClick={loadAll}>
              {all ? "Re-read" : "List all agents"}
            </Button>
          </div>

          {all && (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Owner</TableHead>
                  <TableHead>Runtime</TableHead>
                  <TableHead>Phase</TableHead>
                  <TableHead>Age</TableHead>
                  <TableHead>Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {all.map((a) => (
                  <TableRow key={`all:${a.namespace}/${a.name}`}>
                    <TableCell>
                      <a className="font-medium text-primary hover:underline"
                        href={`/agents/${a.namespace}/${a.name}`}>
                        {a.name}
                      </a>
                      <div className="text-xs text-muted-foreground">{a.namespace}</div>
                    </TableCell>
                    <TableCell className="text-muted-foreground">
                      {a.owner}
                      {me?.email && a.owner.toLowerCase() === me.email.toLowerCase() && (
                        <Badge variant="secondary" className="ml-1.5">you</Badge>
                      )}
                    </TableCell>
                    <TableCell>{a.runtime}</TableCell>
                    <TableCell>
                      {/* The admin listing shows the phase only. */}
                      <Badge variant={a.desiredState === "Suspended" ? "warning" : "default"}>
                        {a.phase || "Unknown"}
                      </Badge>
                    </TableCell>
                    <TableCell className="text-muted-foreground">{ageOf(a.age)}</TableCell>
                    <TableCell>{lifecycleButtons(a, adminCaps, true)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </div>
      )}
    </div>
  );
}
