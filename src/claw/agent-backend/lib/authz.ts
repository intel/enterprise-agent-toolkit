// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Resource authorization: what may this caller do on this agent? The owner may do everything;
// a grantee what its live AgentGrants confer; an admin, with a stated reason, a fixed subset.
import { Caller, HttpError } from "./identity.js";
import { getAgent, listGrantsForAgent, grantIsLive, AgentGrantRow } from "./k8s.js";
import { ROLE_AGENT_ADMIN, ROLE_PLATFORM_ADMIN, hasRole } from "./security/roles.js";
import { Capability, ALL_CAPABILITIES, GRANTABLE_CAPABILITIES, expandCaps } from "./capabilities.js";

export type { Capability };
export { ALL_CAPABILITIES, GRANTABLE_CAPABILITIES, expandCaps };

export type DecidingLayer = "owner" | "grant" | "break-glass";

export interface ResolvedAccess {
  isOwner: boolean;
  caps: Set<Capability>;
  agent: any;
  grant?: AgentGrantRow;
  decidedBy: DecidingLayer;
  breakGlassRole?: string;
  breakGlassReason?: string;
}

export interface ResolveOpts {
  breakGlassReason?: string; // from X-Break-Glass-Reason; without it admin roles confer nothing
}

// Admin access to agents the caller does not own.
export const BREAK_GLASS_CAPS: Record<string, Capability[]> = {
  [ROLE_AGENT_ADMIN]: ["view"],
  [ROLE_PLATFORM_ADMIN]: ["view", "suspend-resume", "delete", "converse"],
};
const ADMIN_ROLES = [ROLE_PLATFORM_ADMIN, ROLE_AGENT_ADMIN]; // highest first

// "Missing" and "no access" answer identically, so names cannot be probed.
export function notVisible(agentName: string): HttpError {
  return new HttpError(404, `agent '${agentName}' not found`);
}

// null when the caller is neither owner, live grantee nor admin with a reason; 404 when absent.
export async function resolveAccess(
  caller: Caller, agentNs: string, agentName: string, opts: ResolveOpts = {},
): Promise<ResolvedAccess | null> {
  let agent: any;
  try {
    agent = await getAgent(agentNs, agentName);
  } catch (e: any) {
    if ((e?.code ?? e?.statusCode) === 404) throw notVisible(agentName);
    throw e;
  }
  return decideAccess(caller, agent, () => listGrantsForAgent(agentNs, agentName), opts);
}

// The decision itself, given the agent and a way to read its grants.
export async function decideAccess(
  caller: Caller, agent: any, grantsOf: () => Promise<AgentGrantRow[]>, opts: ResolveOpts = {},
): Promise<ResolvedAccess | null> {
  const owner = (agent?.spec?.owner?.principal ?? "").toLowerCase();
  if (owner && owner === caller.email) {
    return { isOwner: true, caps: new Set(ALL_CAPABILITIES), agent, decidedBy: "owner" };
  }
  // After owner and grant, so an admin who is also a grantee is recorded as the grantee.
  const breakGlass = (): ResolvedAccess | null => {
    const role = opts.breakGlassReason ? ADMIN_ROLES.find((r) => hasRole(caller, r)) : undefined;
    return role ? {
      isOwner: false, caps: new Set(BREAK_GLASS_CAPS[role]), agent,
      decidedBy: "break-glass", breakGlassRole: role, breakGlassReason: opts.breakGlassReason,
    } : null;
  };
  if (!owner) return breakGlass();
  // The grantor must be the current owner, so a stale or forged grant confers nothing.
  const live = (await grantsOf())
    .filter((g) => g.grantee === caller.email && g.grantor === owner && grantIsLive(g));
  if (!live.length) return breakGlass();
  return {
    isOwner: false,
    caps: new Set(live.flatMap((g) => [...expandCaps(g.capabilities)])),
    agent,
    grant: live[0],
    decidedBy: "grant",
  };
}

export const BREAK_GLASS_HEADER = "x-break-glass-reason";
export const BREAK_GLASS_MIN_LEN = 8;
// decided_by when the header was sent but admin authority was not used.
export const BREAK_GLASS_REFUSED = "break-glass-refused";

// One line, at most 500 characters, so it cannot forge lines in the stdout audit log.
export function rawBreakGlassReason(req: { headers: Record<string, any> }): string | undefined {
  const raw = req.headers[BREAK_GLASS_HEADER];
  const v = (Array.isArray(raw) ? raw[0] : raw ?? "").toString().replace(/[\r\n]+/g, " ").trim();
  return v ? v.slice(0, 500) : undefined;
}

// Too short to be a reason is a 400, not silently ignored.
export function breakGlassReason(req: { headers: Record<string, any> }): string | undefined {
  const v = rawBreakGlassReason(req);
  if (v && v.length < BREAK_GLASS_MIN_LEN) {
    throw new HttpError(400, `${BREAK_GLASS_HEADER} must be at least ${BREAK_GLASS_MIN_LEN} characters`);
  }
  return v;
}

export function highestBreakGlassRole(caller: Caller): string {
  return ADMIN_ROLES.find((r) => hasRole(caller, r)) ?? "";
}

// Listing every agent is the one deliberate existence oracle: admin role, reason and audit row.
export function breakGlassListingRole(caller: Caller, reason?: string): string | null {
  if (!reason) return null;
  return ADMIN_ROLES.find((r) => hasRole(caller, r) && BREAK_GLASS_CAPS[r].includes("view")) ?? null;
}

export interface DecisionSource {
  decision?: { decidedBy: string; breakGlassRole?: string; breakGlassReason?: string };
  headers: Record<string, any>;
  ctx?: Caller;
}

// The deciding layer for an audit row; a refused break-glass attempt is recorded as such.
export function auditDecisionFields(req: DecisionSource): { decidedBy: string; metadata?: Record<string, unknown> } {
  const d = req.decision;
  if (d) {
    return {
      decidedBy: d.decidedBy,
      ...(d.breakGlassRole ? { metadata: { breakGlassRole: d.breakGlassRole, breakGlassReason: d.breakGlassReason } } : {}),
    };
  }
  const reason = rawBreakGlassReason(req);
  if (!reason) return { decidedBy: "" };
  return {
    decidedBy: BREAK_GLASS_REFUSED,
    metadata: { breakGlassRole: req.ctx ? highestBreakGlassRole(req.ctx) : "", breakGlassReason: reason },
  };
}

// No access → 404; access without the capability → 403 (existence is already known).
// `record` sees the resolved access first, so a refusal is audited with its deciding layer.
export async function requireCap(
  caller: Caller, agentNs: string, agentName: string, cap: Capability, opts: ResolveOpts = {},
  record: (a: ResolvedAccess) => void = () => {},
): Promise<ResolvedAccess> {
  const access = await resolveAccess(caller, agentNs, agentName, opts);
  if (!access) throw notVisible(agentName);
  record(access);
  if (!access.caps.has(cap)) throw new HttpError(403, `forbidden: missing capability '${cap}' on agent '${agentName}'`);
  return access;
}

// Break-glass never satisfies an owner-only action.
export async function requireOwner(
  caller: Caller, agentNs: string, agentName: string, action: string, record: (a: ResolvedAccess) => void = () => {},
): Promise<ResolvedAccess> {
  const access = await resolveAccess(caller, agentNs, agentName);
  if (!access) throw notVisible(agentName);
  record(access);
  if (!access.isOwner) throw new HttpError(403, `forbidden: only the owner may ${action}`);
  return access;
}
