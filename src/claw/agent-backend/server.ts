// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// agent-backend: the REST API over Agent and AgentGrant resources. It writes desired state only;
// the agent operator reconciles. Conversations go to each agent's gateway route, not through here. Each request passes, in order: request id, token verification,
// role (may this principal do the verb), scope (may this token), resource capability (owner,
// grant or break-glass; no access is 404), and an audit row for every write and denial.
import express, { Request, Response, NextFunction } from "express";
import { HttpError } from "./lib/identity.js";
import { errResponse, statusOf, parseIfMatch, etagFor } from "./lib/http.js";
import { requestIdMiddleware, crossSiteMiddleware, authenticate, requireCtx } from "./lib/security/context.js";
import { assertAuthnConfig, authnConfigSummary, authnConfigPublicSummary } from "./lib/security/authn.js";
import { audit, auditPreflight, auditPersistenceEnabled, type Outcome } from "./lib/audit.js";
import {
  requireCap, requireOwner, breakGlassReason, rawBreakGlassReason, breakGlassListingRole, auditDecisionFields,
  BREAK_GLASS_CAPS, GRANTABLE_CAPABILITIES, Capability,
} from "./lib/authz.js";
import { requireRole, roleConfig, ROLE_VIEWER, ROLE_EDITOR } from "./lib/security/roles.js";
import { filterToolsForCaller, assertSkillsEntitled, unknownRolesIn } from "./lib/security/tools.js";
import {
  requireScope, scopeConfig, stackScopesOf, SCOPE_READ, SCOPE_WRITE, SCOPE_GRANT,
} from "./lib/security/scopes.js";
import {
  listAgentsForUser, listAllAgents, createAgent, deleteAgent, setDesiredState, patchAgentCapabilities,
  updateAgentModel, updateAgentGithubToken, getAgentProvisioning, listGrantsForAgent, createGrant, revokeGrant,
  listRegisteredTools, resourceVersionOf, enabledRuntimes, type ModelFields,
} from "./lib/k8s.js";
import { sanitizeWorkspace, normalizeWebFetchAllowlist } from "./lib/workspace.js";
import { listGateways } from "./lib/models.js";

const PORT = Number(process.env.PORT || "3000");
const MAX_TTL_HOURS = Number(process.env.GRANT_MAX_TTL_HOURS || "720");
// The externally visible API path, for the Location a 202 returns.
const PUBLIC_API_BASE = (process.env.PUBLIC_API_BASE || "/api").replace(/\/+$/, "");
const REQUIRE_IF_MATCH = (process.env.REQUIRE_IF_MATCH || "").trim().toLowerCase() === "true";

const app = express();
app.set("etag", false); // ETags are resourceVersions, set per route
app.set("trust proxy", false);
app.disable("x-powered-by");
app.use(requestIdMiddleware);
app.use(crossSiteMiddleware);
app.use(express.json({ limit: "10mb" })); // workspace maps can be large

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      decision?: { decidedBy: string; breakGlassRole?: string; breakGlassReason?: string };
    }
  }
}

// Resource checks record the deciding layer on the request, for the audit row.
const recordOn = (req: Request) => (a: { decidedBy: string; breakGlassRole?: string; breakGlassReason?: string }) => {
  req.decision = { decidedBy: a.decidedBy, breakGlassRole: a.breakGlassRole, breakGlassReason: a.breakGlassReason };
};

function capOn(req: Request, cap: Capability) {
  return requireCap(requireCtx(req), String(req.params.ns), String(req.params.name), cap,
    { breakGlassReason: breakGlassReason(req) }, recordOn(req));
}

function ownerOn(req: Request, action: string) {
  return requireOwner(requireCtx(req), String(req.params.ns), String(req.params.name), action, recordOn(req));
}

// Fails closed: without the catalogue, a skill's entitlement cannot be decided.
async function entitledTools(action: string) {
  try {
    const tools = await listRegisteredTools();
    for (const t of tools) {
      const bad = unknownRolesIn(t);
      if (bad.length) console.warn(JSON.stringify({ level: "warn", msg: "tool allowedRoles names unknown roles; tool restricted to nobody", skill: t.skill, unknownRoles: bad }));
    }
    return tools;
  } catch (e: any) {
    throw new HttpError(503, `cannot validate skill entitlement for ${action}: ${e?.message ?? e}`);
  }
}

function auditRow(req: Request, action: string, resourceType: string, resourceId: string, outcome: Outcome, reason?: string) {
  const ctx = req.ctx;
  return audit({
    action, resourceType, resourceId, outcome, ...(reason ? { reason } : {}),
    actorSub: ctx?.subject ?? "", actorEmail: ctx?.email ?? "", authMethod: ctx?.authMethod, tenantId: ctx?.tenantId,
    requestId: req.requestId, ...auditDecisionFields(req),
  });
}

type Handler = (req: Request, res: Response) => Promise<void>;

function fail(res: Response, e: any) {
  if (!res.headersSent) errResponse(res, e);
  else res.end();
}

// Writes: one audit row on every path; 4xx is "denied", 5xx "error".
function audited(action: string, resourceType: string, id: (req: Request) => string, handler: Handler) {
  return async (req: Request, res: Response): Promise<void> => {
    try {
      await handler(req, res);
      await auditRow(req, action, resourceType, id(req), "allowed");
    } catch (e: any) {
      const status = statusOf(e);
      await auditRow(req, action, resourceType, id(req), status >= 500 ? "error" : "denied", `${status}: ${e?.message ?? e}`);
      fail(res, e);
    }
  };
}

// Reads: no row, except when break-glass was asserted (allowed or refused).
function handledRead(action: string, resourceType: string, id: (req: Request) => string, handler: Handler) {
  return async (req: Request, res: Response): Promise<void> => {
    const attempted = Boolean(rawBreakGlassReason(req));
    try {
      await handler(req, res);
      if (attempted || req.decision?.decidedBy === "break-glass") await auditRow(req, action, resourceType, id(req), "allowed");
    } catch (e: any) {
      const status = statusOf(e);
      if (attempted) await auditRow(req, action, resourceType, id(req), status >= 500 ? "error" : "denied", `${status}: ${e?.message ?? e}`);
      fail(res, e);
    }
  };
}

// Owner-scoped reads with no break-glass path: no audit row.
function handled(handler: Handler) {
  return async (req: Request, res: Response): Promise<void> => {
    try {
      await handler(req, res);
    } catch (e) {
      fail(res, e);
    }
  };
}
const agentId = (req: Request): string => `${req.params.ns}/${req.params.name}`;
const ifMatch = (req: Request) => parseIfMatch(req.headers["if-match"], REQUIRE_IF_MATCH);

function setETag(res: Response, obj: any): void {
  const rv = resourceVersionOf(obj);
  if (rv) res.setHeader("etag", etagFor(rv));
}

const str = (v: unknown) => (typeof v === "string" ? v.trim() : undefined);
const strList = (v: unknown) => (Array.isArray(v) ? v.map(String) : undefined);

function modelOf(body: any): ModelFields | undefined {
  const m = body?.model;
  return m && typeof m === "object" ? {
    provider: str(m.provider), id: str(m.id), name: str(m.name), baseUrl: str(m.baseUrl),
    contextWindow: Number.isInteger(m.contextWindow) ? m.contextWindow : undefined,
  } : undefined;
}

// ── Unauthenticated ──────────────────────────────────────────────────────────
app.get("/api/healthz", (_req, res) => {
  res.json({ status: "ok" });
});

// Which checks are on: booleans, counts and names, never the accepted client IDs.
app.get("/api/authz-config", (_req, res) => {
  res.json({
    ...authnConfigPublicSummary(), auditPersistence: auditPersistenceEnabled(), requireIfMatch: REQUIRE_IF_MATCH,
    roles: roleConfig(), scopes: scopeConfig(),
  });
});

app.use(authenticate());

// ── Caller ───────────────────────────────────────────────────────────────────
app.get("/api/me", handled(async (req, res) => {
  const ctx = requireCtx(req);
  res.json({
    email: ctx.email, username: ctx.username || ctx.subject, isAdmin: ctx.isAdmin, roles: ctx.roles,
    scopes: stackScopesOf(ctx), authMethod: ctx.authMethod, runtimes: enabledRuntimes(),
  });
}));

// The Tools this caller may use; the same check guards create and patch.
app.get("/api/tools", requireRole(ROLE_VIEWER), requireScope(SCOPE_READ), handled(async (req, res) => {
  res.json({ tools: filterToolsForCaller(requireCtx(req), await listRegisteredTools()) });
}));

// The model gateways openshell agents may use and their chat models, for the console's pickers.
app.get("/api/models", requireRole(ROLE_VIEWER), requireScope(SCOPE_READ), handled(async (_req, res) => {
  res.json({ defaultModel: process.env.DEFAULT_MODEL || "", gateways: await listGateways() });
}));

// ── Agents ───────────────────────────────────────────────────────────────────
// Owned and shared; with a break-glass reason, an admin also gets every agent (`all`).
app.get("/api/agents", requireRole(ROLE_VIEWER), requireScope(SCOPE_READ), handledRead("agent.list", "agent-collection", () => "*", async (req, res) => {
  const ctx = requireCtx(req);
  const reason = breakGlassReason(req);
  const role = breakGlassListingRole(ctx, reason);
  if (role) req.decision = { decidedBy: "break-glass", breakGlassRole: role, breakGlassReason: reason };
  const { owned, shared } = await listAgentsForUser(ctx.email);
  res.json({ owned, shared, ...(role ? { all: await listAllAgents(), adminRole: role, adminCaps: BREAK_GLASS_CAPS[role] } : {}) });
}));

// 202: the Agent records desired state; `href` is where to poll for the actual state.
app.post("/api/agents", requireRole(ROLE_EDITOR), requireScope(SCOPE_WRITE), audited("agent.create", "agent", (req) => String(req.body?.name ?? ""), async (req, res) => {
  const ctx = requireCtx(req);
  req.decision = { decidedBy: "role" }; // the caller becomes the owner
  const body = req.body ?? {};
  const skills = strList(body.skills);
  assertSkillsEntitled(ctx, skills, await entitledTools("agent.create"));
  const agent = await createAgent({
    name: String(body.name ?? "").trim(),
    owner: ctx.email,
    ownerUsername: ctx.username || undefined,
    requestId: req.requestId,
    skills,
    tools: Array.isArray(body.tools) ? body.tools : undefined,
    toolsDeny: strList(body.toolsDeny),
    workspace: sanitizeWorkspace(body.workspace),
    webFetchAllowlist: normalizeWebFetchAllowlist(body.webFetchAllowlist),
    githubToken: str(body.githubToken) || undefined,
    runtime: str(body.runtime) || undefined,
    model: modelOf(body) && { ...modelOf(body), apiKey: typeof body.model?.apiKey === "string" ? body.model.apiKey : undefined },
  });
  const href = `${PUBLIC_API_BASE}/agents/${agent?.metadata?.namespace ?? ""}/${agent?.metadata?.name ?? ""}`;
  setETag(res, agent);
  res.setHeader("location", href);
  res.status(202).json({ agent, desiredState: agent?.spec?.desiredState ?? "Running", actualState: agent?.status?.phase ?? "Pending", href });
}));

app.get("/api/agents/:ns/:name", requireRole(ROLE_VIEWER), requireScope(SCOPE_READ), handledRead("agent.read", "agent", agentId, async (req, res) => {
  const access = await capOn(req, "view");
  setETag(res, access.agent);
  res.json({ agent: access.agent, isOwner: access.isOwner, caps: [...access.caps] });
}));

// 202: the operator still removes the namespace, Keycloak client and memory.
app.delete("/api/agents/:ns/:name", requireRole(ROLE_EDITOR), requireScope(SCOPE_WRITE), audited("agent.delete", "agent", agentId, async (req, res) => {
  await capOn(req, "delete");
  await deleteAgent(String(req.params.ns), String(req.params.name));
  res.status(202).json({ ok: true, actualState: "Terminating" });
}));

// Owner only. A caller's If-Match applies to the first patch; later ones chain resourceVersions.
app.patch("/api/agents/:ns/:name", requireRole(ROLE_EDITOR), requireScope(SCOPE_WRITE), audited("agent.update", "agent", agentId, async (req, res) => {
  const ns = String(req.params.ns), name = String(req.params.name);
  await ownerOn(req, "edit skills/tools");
  let rv = ifMatch(req);
  const body = req.body ?? {};
  const caps = {
    skills: strList(body.skills),
    tools: Array.isArray(body.tools)
      ? body.tools.filter((t: any) => t?.name && t?.url).map((t: any) => ({ name: String(t.name), url: String(t.url) }))
      : undefined,
    toolsDeny: strList(body.toolsDeny),
    workspace: sanitizeWorkspace(body.workspace),
    webFetchAllowlist: normalizeWebFetchAllowlist(body.webFetchAllowlist),
  };
  const model = modelOf(body);
  const modelApiKey = typeof body.modelApiKey === "string" && body.modelApiKey ? body.modelApiKey : undefined;
  const githubToken = typeof body.githubToken === "string" && body.githubToken ? body.githubToken : undefined;
  const clearGithubToken = body.clearGithubToken === true;
  const hasCaps = Object.values(caps).some((v) => v !== undefined);
  if (!hasCaps && !model && !modelApiKey && !githubToken && !clearGithubToken) {
    throw new HttpError(400, "provide skills, tools, toolsDeny, workspace, webFetchAllowlist, model, modelApiKey, githubToken or clearGithubToken");
  }
  if (caps.skills) assertSkillsEntitled(requireCtx(req), caps.skills, await entitledTools("agent.update"));
  let updated: any;
  if (hasCaps) rv = resourceVersionOf(updated = await patchAgentCapabilities(ns, name, caps, rv)) || rv;
  if (model || modelApiKey) rv = resourceVersionOf(updated = await updateAgentModel(ns, name, model || {}, modelApiKey, rv)) || rv;
  if (githubToken || clearGithubToken) updated = await updateAgentGithubToken(ns, name, githubToken, rv);
  setETag(res, updated);
  res.json({ agent: updated });
}));

// 202: desired state recorded; the operator scales the agent after.
async function changeState(req: Request, res: Response, desired: "Running" | "Suspended") {
  await capOn(req, "suspend-resume");
  const updated = await setDesiredState(String(req.params.ns), String(req.params.name), desired, ifMatch(req));
  setETag(res, updated);
  res.status(202).json({ ok: true, desiredState: desired, actualState: updated?.status?.phase ?? "Unknown" });
}

app.post("/api/agents/:ns/:name/suspend", requireRole(ROLE_EDITOR), requireScope(SCOPE_WRITE), audited("agent.suspend", "agent", agentId, (req, res) => changeState(req, res, "Suspended")));
app.post("/api/agents/:ns/:name/resume", requireRole(ROLE_EDITOR), requireScope(SCOPE_WRITE), audited("agent.resume", "agent", agentId, (req, res) => changeState(req, res, "Running")));

app.get("/api/agents/:ns/:name/provisioning", requireRole(ROLE_VIEWER), requireScope(SCOPE_READ), handledRead("agent.provisioning.read", "agent", agentId, async (req, res) => {
  await capOn(req, "view");
  res.json(await getAgentProvisioning(String(req.params.ns), String(req.params.name)));
}));

// ── Grants (owner only) ──────────────────────────────────────────────────────
app.get("/api/agents/:ns/:name/grants", requireRole(ROLE_VIEWER), requireScope(SCOPE_READ), handled(async (req, res) => {
  await ownerOn(req, "view grants");
  res.json({ grants: await listGrantsForAgent(String(req.params.ns), String(req.params.name)) });
}));

app.post("/api/agents/:ns/:name/grants", requireRole(ROLE_EDITOR), requireScope(SCOPE_GRANT), audited("grant.create", "grant", agentId, async (req, res) => {
  const ctx = requireCtx(req);
  await ownerOn(req, "create grants");
  const body = req.body ?? {};
  const grantee = String(body.grantee ?? "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+$/.test(grantee)) throw new HttpError(400, "grantee must be a valid email");
  if (grantee === ctx.email) throw new HttpError(400, "cannot grant to yourself (you already own this agent)");
  const caps: string[] = Array.isArray(body.capabilities) ? body.capabilities.map(String) : [];
  if (!caps.length || caps.some((c) => !(GRANTABLE_CAPABILITIES as string[]).includes(c))) {
    throw new HttpError(400, `capabilities must be a non-empty subset of ${JSON.stringify(GRANTABLE_CAPABILITIES)}`);
  }
  const now = Date.now();
  const expiresAt = String(body.expiresAt ?? "").trim() || new Date(now + 3600_000).toISOString();
  const exp = new Date(expiresAt).getTime();
  if (!Number.isFinite(exp) || exp <= now) throw new HttpError(400, "expiresAt must be a future ISO timestamp");
  if (exp > now + MAX_TTL_HOURS * 3600_000) throw new HttpError(400, `expiresAt exceeds the maximum grant of ${MAX_TTL_HOURS}h`);
  const grant = await createGrant({
    agentNs: String(req.params.ns), agentName: String(req.params.name), grantor: ctx.email, grantee,
    capabilities: caps, expiresAt,
  });
  res.status(201).json({ grant });
}));

app.delete("/api/agents/:ns/:name/grants/:grant", requireRole(ROLE_EDITOR), requireScope(SCOPE_GRANT), audited("grant.revoke", "grant", (req) => `${req.params.ns}/${req.params.grant}`, async (req, res) => {
  await ownerOn(req, "revoke grants");
  const grant = String(req.params.grant);
  // Only a grant on this agent may be revoked through this agent's route.
  if (!(await listGrantsForAgent(String(req.params.ns), String(req.params.name))).some((g) => g.name === grant)) {
    throw new HttpError(404, `grant '${grant}' not found`);
  }
  await revokeGrant(String(req.params.ns), grant);
  res.json({ ok: true });
}));

// Guard denials (role, scope) never reach audited(), so they are recorded here; 401s have no layer.
app.use((e: any, req: Request, res: Response, _next: NextFunction) => {
  if (req.decision?.decidedBy) {
    const status = statusOf(e);
    void auditRow(req, "authz.denied", "route", `${req.method} ${req.route?.path ?? ""}`.trim(),
      status >= 500 ? "error" : "denied", `${status}: ${e?.message ?? e}`);
  }
  fail(res, e);
});

async function main(): Promise<void> {
  assertAuthnConfig();
  try {
    await auditPreflight();
  } catch (e: any) {
    console.error(JSON.stringify({ level: "error", msg: "audit persistence preflight FAILED: events are stdout-only until fixed", err: e?.message ?? String(e) }));
  }
  console.log(JSON.stringify({
    level: "info", msg: `agent-backend listening on :${PORT}`, auditPersistence: auditPersistenceEnabled(),
    roles: roleConfig(), scopes: scopeConfig(), ...authnConfigSummary(),
  }));
  app.listen(PORT, "0.0.0.0");
}

main().catch((e) => {
  console.error(JSON.stringify({ level: "fatal", msg: "startup failed", err: e?.message ?? String(e) }));
  process.exit(1);
});
