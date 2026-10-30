// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Kubernetes access: create, patch, delete and read Agent, AgentGrant and Tool resources. The agent
// operator does all reconciliation; authorization is decided by the routes (authz.ts), not here.
import * as k8s from "@kubernetes/client-node";
import { ownerNamespace } from "./identity.js";
import { expandCaps } from "./capabilities.js";
import { gatewayConfig } from "./models.js";

const GROUP = "intel-stack.io";
const VERSION = "v1alpha1";
const PLURAL = "agents";
const GRANT_PLURAL = "agentgrants";
const MANAGED = { "app.kubernetes.io/managed-by": "agent-backend" };
const MERGE_PATCH = k8s.setHeaderOptions("Content-Type", k8s.PatchStrategy.MergePatch);

// In a pod, always the ServiceAccount: a stray KUBECONFIG must not swap the API identity.
export function config(): k8s.KubeConfig {
  const kc = new k8s.KubeConfig();
  if (process.env.KUBERNETES_SERVICE_HOST) kc.loadFromCluster();
  else kc.loadFromDefault();
  return kc;
}

let kc: k8s.KubeConfig | null = null;
const customObjects = () => (kc ??= config()).makeApiClient(k8s.CustomObjectsApi);
const coreApi = () => (kc ??= config()).makeApiClient(k8s.CoreV1Api);

// The API status of a failed call: HTTP code, Status reason and message.
export function apiError(e: any): { code: number; reason: string; message: string } {
  let body = e?.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch { body = {}; }
  }
  return { code: Number(e?.code ?? body?.code ?? 0), reason: body?.reason ?? "", message: body?.message ?? e?.message ?? String(e) };
}

// ── Optimistic concurrency: metadata.resourceVersion in a merge patch makes a stale write a 409 ──
export class ConflictError extends Error {
  status = 409;
  constructor(kind: string, name: string) {
    super(`conflict: ${kind} '${name}' was modified by another writer since you read it; re-read it and re-apply your change`);
  }
}

export function resourceVersionOf(obj: any): string {
  return obj?.metadata?.resourceVersion ?? "";
}

async function patchAgent(namespace: string, name: string, spec: any, resourceVersion: string | undefined, what: string) {
  const body = { spec, ...(resourceVersion ? { metadata: { resourceVersion } } : {}) };
  try {
    return await customObjects().patchNamespacedCustomObject(
      { group: GROUP, version: VERSION, namespace, plural: PLURAL, name, body }, MERGE_PATCH);
  } catch (e: any) {
    const { code, reason, message } = apiError(e);
    if (code === 409 && (reason === "Conflict" || !reason)) throw new ConflictError("agent", name);
    throw Object.assign(new Error(`patch ${what} failed: ${message}`), { status: code >= 400 && code < 500 ? code : 500 });
  }
}

// ── Tools ────────────────────────────────────────────────────────────────────
export interface ToolEntry {
  skill: string;
  aliasSkills: string[];
  requiresIdentity: boolean;
  alwaysOn: boolean;
  allowedRoles: string[];
  description: string;
}

const strings = (v: unknown) => (Array.isArray(v) ? v.filter((x) => typeof x === "string" && x).map(String) : []);

// Registered Tools only (the operator rejects conflicting or off-cluster ones); no URLs.
export async function listRegisteredTools(): Promise<ToolEntry[]> {
  const res: any = await customObjects().listClusterCustomObject({ group: GROUP, version: VERSION, plural: "tools" });
  return (res?.items ?? [])
    .filter((t: any) => t?.spec?.skill && t?.status?.phase === "Registered")
    .map((t: any) => ({
      skill: String(t.spec.skill),
      aliasSkills: strings(t.spec.aliasSkills),
      requiresIdentity: !!t.spec.requiresIdentity,
      alwaysOn: !!t.spec.alwaysOn,
      allowedRoles: strings(t.spec.allowedRoles),
      description: typeof t.spec.description === "string" ? t.spec.description : "",
    }));
}

const badRequest = (message: string): never => {
  throw Object.assign(new Error(message), { status: 400 });
};

// ── Agents ───────────────────────────────────────────────────────────────────
// agent-<username>-<name>: the agent's own namespace (its Agent lives in user-<username>).
export function agentNamespace(username: string, name: string): string {
  return `agent-${username}-${name}`;
}

export interface AgentRow {
  name: string;
  namespace: string;
  owner: string;
  ownerUsername: string;
  skills: string[];
  runtime: string;
  desiredState: string;
  phase: string;
  suspendReason: string;
  lastActivity: string;
  memoryRef: string;
  age: string;
  podReady: boolean | null; // null while suspended
}

const condition = (obj: any, type: string) => (obj?.status?.conditions ?? []).find((c: any) => c?.type === type);

function toRow(obj: any): AgentRow {
  const spec = obj.spec || {};
  const status = obj.status || {};
  const desiredState = spec.desiredState ?? "Running";
  return {
    name: obj.metadata?.name ?? "",
    namespace: obj.metadata?.namespace ?? "",
    owner: spec.owner?.principal ?? "",
    ownerUsername: spec.owner?.username ?? "",
    skills: spec.skills ?? [],
    runtime: spec.runtime ?? "claw",
    desiredState,
    phase: status.phase ?? "Unknown",
    suspendReason: status.suspendReason ?? "",
    lastActivity: status.lastActivity ?? "",
    memoryRef: status.memoryRef ?? "",
    age: obj.metadata?.creationTimestamp ?? "",
    podReady: desiredState === "Running" ? condition(obj, "PodReady")?.status === "True" : null,
  };
}

// Cluster-wide and unfiltered: only for the scoped views below.
async function listAgents(): Promise<AgentRow[]> {
  const res: any = await customObjects().listClusterCustomObject({ group: GROUP, version: VERSION, plural: PLURAL });
  return (res?.items ?? []).map(toRow);
}

export async function getAgent(namespace: string, name: string): Promise<any> {
  return customObjects().getNamespacedCustomObject({ group: GROUP, version: VERSION, namespace, plural: PLURAL, name });
}

async function backendNamespaceOf(namespace: string, name: string): Promise<string> {
  const username = (await getAgent(namespace, name))?.spec?.owner?.username;
  if (!username) throw new Error(`agent '${name}' has no spec.owner.username`);
  return agentNamespace(username, name);
}

export async function setDesiredState(namespace: string, name: string, desired: "Running" | "Suspended", rv?: string) {
  return patchAgent(namespace, name, { desiredState: desired }, rv, "desiredState");
}

export async function deleteAgent(namespace: string, name: string): Promise<void> {
  await customObjects().deleteNamespacedCustomObject({ group: GROUP, version: VERSION, namespace, plural: PLURAL, name });
}

export interface CapabilitiesPatch {
  skills?: string[];
  tools?: { name: string; url: string }[];
  toolsDeny?: string[];
  workspace?: Record<string, string>; // replaces the whole map
  webFetchAllowlist?: string[];
}

export async function patchAgentCapabilities(namespace: string, name: string, patch: CapabilitiesPatch, rv?: string) {
  const spec = Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined));
  return patchAgent(namespace, name, spec, rv, "capabilities");
}

// Credentials live in per-agent Secrets the Agent only references. Each new value gets a new
// name, so the reference changes and the operator re-renders; the older Secrets are pruned.
async function writeAgentSecret(ns: string, agent: string, prefix: string, data: Record<string, string>): Promise<string> {
  const name = `${prefix}-${Date.now().toString(36)}`;
  await coreApi().createNamespacedSecret({
    namespace: ns,
    body: { metadata: { name, namespace: ns, labels: { "intel-stack.io/agent": agent, ...MANAGED } }, type: "Opaque", stringData: data },
  });
  return name;
}

// Only Secrets this backend wrote: the operator's own carry no managed-by=agent-backend label.
async function pruneAgentSecrets(ns: string, agent: string, prefix: string, keep: string): Promise<void> {
  let items: k8s.V1Secret[] = [];
  try {
    items = (await coreApi().listNamespacedSecret({
      namespace: ns, labelSelector: `intel-stack.io/agent=${agent},app.kubernetes.io/managed-by=agent-backend`,
    })).items;
  } catch (e) {
    console.warn(JSON.stringify({ level: "warn", msg: "secret prune: list failed", ns, err: apiError(e).message }));
    return;
  }
  for (const name of items.map((s) => s.metadata?.name ?? "")) {
    if (!name || name === keep || !name.startsWith(prefix)) continue;
    await coreApi().deleteNamespacedSecret({ name, namespace: ns }).catch((e) =>
      console.warn(JSON.stringify({ level: "warn", msg: "secret prune: delete failed", ns, name, err: apiError(e).message })));
  }
}

export interface ModelFields { provider?: string; id?: string; name?: string; baseUrl?: string; contextWindow?: number }

const modelSpecOf = (m: ModelFields) =>
  Object.fromEntries(Object.entries({
    provider: m.provider, id: m.id, name: m.name, baseUrl: m.baseUrl,
    contextWindow: Number.isInteger(m.contextWindow) && m.contextWindow! > 0 ? m.contextWindow : undefined,
  }).filter(([, v]) => v));

export async function updateAgentModel(namespace: string, name: string, model: ModelFields, apiKey?: string, rv?: string) {
  if ((model.baseUrl || apiKey) && (await getAgent(namespace, name))?.spec?.runtime === "openshell") {
    badRequest("openshell agents use the cluster's model gateway: a model base URL or API key is not supported");
  }
  const spec: any = {};
  if (Object.keys(modelSpecOf(model)).length) spec.model = modelSpecOf(model);
  const backendNs = apiKey ? await backendNamespaceOf(namespace, name) : "";
  if (apiKey) spec.modelSecretRef = await writeAgentSecret(backendNs, name, `${name}-model-credentials`, { apiKey });
  if (!Object.keys(spec).length) throw Object.assign(new Error("no model fields to update"), { status: 400 });
  const updated = await patchAgent(namespace, name, spec, rv, "model");
  if (apiKey) await pruneAgentSecrets(backendNs, name, `${name}-model-credentials`, spec.modelSecretRef);
  return updated;
}

// No token clears the reference, so the agent falls back to the shared GitHub token.
export async function updateAgentGithubToken(namespace: string, name: string, token?: string, rv?: string) {
  const backendNs = await backendNamespaceOf(namespace, name);
  const ref = token ? await writeAgentSecret(backendNs, name, `${name}-github-token`, { token }) : "";
  const updated = await patchAgent(namespace, name, { githubTokenSecretRef: ref }, rv, "github token");
  await pruneAgentSecrets(backendNs, name, `${name}-github-token`, ref);
  return updated;
}

// ── Create ─────────────────────────────────────────────────────────────────
export interface CreateAgentInput {
  name: string;
  owner: string;          // the caller's email, set by the route
  ownerUsername?: string; // the caller's username, set by the route
  skills?: string[];
  tools?: { name: string; url: string }[];
  toolsDeny?: string[];
  workspace?: Record<string, string>;
  webFetchAllowlist?: string[];
  githubToken?: string;
  model?: ModelFields & { apiKey?: string };
  runtime?: string;       // "claw" (default) or "openshell", when the cluster enables it
  requestId?: string;     // joins operator logs to this request and its audit row
}

// DNS-1035: the name becomes a Service name, which may not start with a digit.
const NAME_RE = /^[a-z]([-a-z0-9]*[a-z0-9])?$/;
// No '-' or '_', so agent-<username>-<name> names exactly one owner and agent.
const USERNAME_RE = /^[a-z0-9]{1,39}$/;
const MAX_DERIVED_NAME = 63;


// OpenShell workspace names (the agent namespace) are at most 19 characters.
export const OPENSHELL_MAX_NAMESPACE = 19;

/** The runtimes this cluster runs agents on; openshell only with the OpenShell component. */
export function enabledRuntimes(): string[] {
  return ["claw", ...((process.env.OPENSHELL_ENABLED || "").trim().toLowerCase() === "true" ? ["openshell"] : [])];
}

/** The Agent's runtime, refused here with the operator's reasons so the caller sees them at once. */
export function validateRuntime(runtime: string | undefined, name: string, ownerUsername: string,
                                model?: ModelFields & { apiKey?: string }): string {
  const rt = (runtime || "claw").trim();
  if (!enabledRuntimes().includes(rt)) badRequest(`runtime '${rt}' is not available on this cluster`);
  if (rt === "openshell") {
    const ns = agentNamespace(ownerUsername, name);
    if (ns.length > OPENSHELL_MAX_NAMESPACE) {
      const room = OPENSHELL_MAX_NAMESPACE - agentNamespace(ownerUsername, "").length;
      badRequest(`openshell agents need a namespace of at most ${OPENSHELL_MAX_NAMESPACE} characters: '${ns}' is ` +
        `${ns.length}; ${room > 0 ? `use an agent name of at most ${room} characters` : "this username leaves no room for an agent name"}`);
    }
    // The sandbox reaches models only through the cluster's gateways, which hold any key.
    if (model?.baseUrl || model?.apiKey) {
      badRequest("openshell agents use the cluster's model gateway: a model base URL or API key is not supported");
    }
    const gateways = gatewayConfig().map((g) => g.name);
    if (model?.provider && gateways.length && !gateways.includes(model.provider)) {
      badRequest(`openshell agents use model provider ${gateways.join(" or ")}, not '${model.provider}'`);
    }
  }
  return rt;
}

export function validateAgentNaming(name: string, ownerUsername?: string): string {
  if (!NAME_RE.test(name)) {
    badRequest("invalid agent name: start with a lowercase letter, then lowercase letters, digits or '-', ending alphanumeric");
  }
  if (!ownerUsername) badRequest("ownerUsername is required (agent naming is keyed by it)");
  if (!USERNAME_RE.test(ownerUsername!)) {
    badRequest(`invalid ownerUsername '${ownerUsername}': must match ${USERNAME_RE.source}`);
  }
  const derived = agentNamespace(ownerUsername!, name);
  if (derived.length > MAX_DERIVED_NAME) {
    badRequest(`agent name too long: '${derived}' is ${derived.length} characters, limit ${MAX_DERIVED_NAME}`);
  }
  return ownerUsername!;
}

async function ensureNamespace(name: string, labels: Record<string, string>): Promise<void> {
  try {
    await coreApi().readNamespace({ name });
    return;
  } catch (e) {
    if (apiError(e).code !== 404) throw e;
  }
  await coreApi().createNamespace({ body: { metadata: { name, labels } } }).catch((e) => {
    if (apiError(e).code !== 409) throw e; // created concurrently
  });
}

export async function ensureOwnerNamespace(username: string): Promise<string> {
  const ns = ownerNamespace(username);
  await ensureNamespace(ns, { ...MANAGED, "intel-stack.io/owner-namespace": "true" });
  return ns;
}

export async function createAgent(input: CreateAgentInput): Promise<any> {
  const username = validateAgentNaming(input.name, input.ownerUsername);
  const runtime = validateRuntime(input.runtime, input.name, username, input.model);
  const ns = await ensureOwnerNamespace(username);
  const spec: any = {
    runtime,
    owner: { principal: input.owner, username },
    desiredState: "Running",
    skills: input.skills?.length ? input.skills : ["shell", "read_file", "list_files"],
    ...(input.tools?.length ? { tools: input.tools } : {}),
    ...(input.toolsDeny?.length ? { toolsDeny: input.toolsDeny } : {}),
    ...(input.workspace && Object.keys(input.workspace).length ? { workspace: input.workspace } : {}),
    webFetchAllowlist: input.webFetchAllowlist ?? [],
  };
  if (input.model && Object.keys(modelSpecOf(input.model)).length) spec.model = modelSpecOf(input.model);
  // Secrets first, in the agent namespace, so the operator's first render already has them.
  if (input.model?.apiKey || input.githubToken) {
    const backendNs = agentNamespace(username, input.name);
    await ensureNamespace(backendNs, { "intel-stack.io/agent": input.name, "app.kubernetes.io/managed-by": "agent-operator" });
    if (input.model?.apiKey) {
      spec.modelSecretRef = await writeAgentSecret(backendNs, input.name, `${input.name}-model-credentials`, { apiKey: input.model.apiKey });
    }
    if (input.githubToken) {
      spec.githubTokenSecretRef = await writeAgentSecret(backendNs, input.name, `${input.name}-github-token`, { token: input.githubToken });
    }
  }
  const body = {
    apiVersion: `${GROUP}/${VERSION}`,
    kind: "Agent",
    metadata: {
      name: input.name,
      namespace: ns,
      labels: { "app.kubernetes.io/name": "agent", "app.kubernetes.io/instance": input.name, ...MANAGED },
      annotations: {
        ...(input.requestId ? { "intel-stack.io/request-id": input.requestId } : {}),
        "intel-stack.io/created-by": input.owner,
      },
    },
    spec,
  };
  try {
    return await customObjects().createNamespacedCustomObject({ group: GROUP, version: VERSION, namespace: ns, plural: PLURAL, body });
  } catch (e) {
    const { code, message } = apiError(e);
    throw Object.assign(new Error(`create agent failed: ${message}`), { status: code === 409 || code === 422 ? code : 500 });
  }
}

// ── Grants ─────────────────────────────────────────────────────────────────
export interface AgentGrantRow {
  name: string;
  namespace: string;
  agentRef: string;
  grantor: string;
  grantee: string;
  capabilities: string[];
  expiresAt: string;
}

function toGrant(obj: any): AgentGrantRow {
  const spec = obj.spec || {};
  return {
    name: obj.metadata?.name ?? "",
    namespace: obj.metadata?.namespace ?? "",
    agentRef: spec.agentRef ?? "",
    grantor: (spec.grantor ?? "").toLowerCase(),
    grantee: (spec.grantee ?? "").toLowerCase(),
    capabilities: spec.capabilities ?? [],
    expiresAt: spec.expiresAt ?? "",
  };
}

// Expiry is checked at read time; a status is never trusted.
export function grantIsLive(g: AgentGrantRow): boolean {
  const exp = new Date(g.expiresAt).getTime();
  return Boolean(g.expiresAt) && Number.isFinite(exp) && exp > Date.now();
}

export async function listGrantsForAgent(agentNs: string, agentName: string): Promise<AgentGrantRow[]> {
  const res: any = await customObjects().listNamespacedCustomObject({ group: GROUP, version: VERSION, namespace: agentNs, plural: GRANT_PLURAL });
  return (res?.items ?? []).map(toGrant).filter((g: AgentGrantRow) => g.agentRef === agentName);
}

async function listGrantsForGrantee(grantee: string): Promise<AgentGrantRow[]> {
  const res: any = await customObjects().listClusterCustomObject({ group: GROUP, version: VERSION, plural: GRANT_PLURAL });
  return (res?.items ?? []).map(toGrant).filter((g: AgentGrantRow) => g.grantee === grantee.toLowerCase());
}

export interface CreateGrantInput {
  agentNs: string;
  agentName: string;
  grantor: string;
  grantee: string;
  capabilities: string[];
  expiresAt: string;
}

export async function createGrant(input: CreateGrantInput): Promise<any> {
  const slug = input.grantee.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  const name = `${input.agentName}-${slug}-${Math.floor(Date.now() / 1000).toString(36)}`.slice(0, 63).replace(/-+$/, "");
  const body = {
    apiVersion: `${GROUP}/${VERSION}`,
    kind: "AgentGrant",
    metadata: { name, namespace: input.agentNs, labels: { ...MANAGED, "intel-stack.io/agent": input.agentName } },
    spec: {
      agentRef: input.agentName,
      grantor: input.grantor,
      grantee: input.grantee.toLowerCase(),
      capabilities: input.capabilities,
      expiresAt: input.expiresAt,
    },
  };
  return customObjects().createNamespacedCustomObject({ group: GROUP, version: VERSION, namespace: input.agentNs, plural: GRANT_PLURAL, body });
}

export async function revokeGrant(namespace: string, name: string): Promise<void> {
  await customObjects().deleteNamespacedCustomObject({ group: GROUP, version: VERSION, namespace, plural: GRANT_PLURAL, name });
}

// ── Scoped listing ───────────────────────────────────────────────────────────
export interface ScopedAgents {
  owned: AgentRow[];
  shared: (AgentRow & { grantedCaps: string[]; grantExpiresAt: string })[];
}

// Owned agents plus those shared by a live grant from their current owner (as authz.ts requires).
export async function listAgentsForUser(caller: string): Promise<ScopedAgents> {
  const email = caller.toLowerCase();
  const all = await listAgents();
  const byAgent = new Map<string, AgentGrantRow>();
  for (const g of (await listGrantsForGrantee(email)).filter(grantIsLive)) {
    const key = `${g.namespace}/${g.agentRef}`;
    const prev = byAgent.get(key);
    if (prev) prev.capabilities = [...new Set([...prev.capabilities, ...g.capabilities])];
    else byAgent.set(key, { ...g });
  }
  const shared: ScopedAgents["shared"] = [];
  for (const g of byAgent.values()) {
    const row = all.find((a) => a.namespace === g.namespace && a.name === g.agentRef
      && a.owner.toLowerCase() !== email && a.owner.toLowerCase() === g.grantor);
    if (row) shared.push({ ...row, grantedCaps: [...expandCaps(g.capabilities)], grantExpiresAt: g.expiresAt });
  }
  return { owned: all.filter((a) => a.owner.toLowerCase() === email), shared };
}

// Every agent, for an admin's break-glass listing only.
export async function listAllAgents(): Promise<AgentRow[]> {
  return (await listAgents()).sort((a, b) => a.owner.localeCompare(b.owner) || a.name.localeCompare(b.name));
}

// ── Provisioning: the operator's conditions, as steps ─────────────────────────
export type StepState = "ok" | "pending" | "error" | "na";
export interface ProvisioningStep {
  key: string;
  label: string;
  state: StepState;
  detail: string;
}

const STEPS: [string, string, string][] = [
  ["identity", "Keycloak identity", "IdentityReady"],
  ["memory", "Memory (pgvector)", "MemoryReady"],
  ["backend", "Backend", "BackendReady"],
  ["seeding", "Workspace files", "SeedingComplete"],
  ["pod", "Pod running", "PodReady"],
];

export async function getAgentProvisioning(crNs: string, name: string) {
  return provisioningSteps(await getAgent(crNs, name));
}

export function provisioningSteps(agent: any): { phase: string; runtime: string; steps: ProvisioningStep[] } {
  const crNs = agent?.metadata?.namespace ?? "", name = agent?.metadata?.name ?? "";
  const phase = agent?.status?.phase ?? "Pending";
  const steps = STEPS.map(([key, label, type]) => {
    const c = condition(agent, type);
    const state: StepState = !c ? "pending" : c.status === "True" ? "ok"
      : ["Disabled", "Suspended"].includes(c.reason) ? "na" : phase === "Failed" ? "error" : "pending";
    return { key, label, state, detail: c?.message ?? "" };
  });
  return { phase, runtime: agent?.spec?.runtime ?? "claw", steps: [{ key: "agent", label: "Agent", state: "ok", detail: `${crNs}/${name}` }, ...steps] };
}
