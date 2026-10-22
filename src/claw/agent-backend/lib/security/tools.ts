// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Tool entitlement: may this caller have this Tool (Tool.spec.allowedRoles)? Enforced on
// create and patch; it bounds API users, not running agents.
import { HttpError } from "../identity.js";
import type { SecurityContext } from "./authn.js";
import { rankOf, roleDenial } from "./roles.js";

export interface ToolEntitlement {
  skill: string;
  allowedRoles?: string[];
  aliasSkills?: string[];
  alwaysOn?: boolean;
}

// Names in allowedRoles that are not roles here; reported, never fatal to a listing.
export function unknownRolesIn(tool: ToolEntitlement): string[] {
  return (tool.allowedRoles ?? []).filter((r) => rankOf(String(r)) === 0);
}

// "" when allowed. No allowedRoles = unrestricted; only unknown names = nobody (a typo fails closed).
export function toolDenial(ctx: SecurityContext, tool: ToolEntitlement): string {
  const declared = tool.allowedRoles ?? [];
  if (!declared.length) return "";
  const known = declared.filter((r) => rankOf(String(r)) > 0);
  if (!known.length) return `forbidden: tool '${tool.skill}' names no known role in allowedRoles`;
  // Ranked like requireRole: listing agent-editor also admits the roles above it.
  if (known.some((r) => roleDenial(ctx, r) === "")) return "";
  return `forbidden: tool '${tool.skill}' requires one of: ${known.join(", ")}`;
}

export function filterToolsForCaller<T extends ToolEntitlement>(ctx: SecurityContext, tools: T[]): T[] {
  return tools.filter((t) => toolDenial(ctx, t) === "");
}

// Skill → the tool it wires, aliases included; a primary skill always beats an alias.
export function skillIndex(tools: ToolEntitlement[]): Map<string, ToolEntitlement> {
  const idx = new Map<string, ToolEntitlement>();
  for (const t of tools) if (!idx.has(t.skill)) idx.set(t.skill, t);
  for (const t of tools) for (const a of t.aliasSkills ?? []) if (a && !idx.has(String(a))) idx.set(String(a), t);
  return idx;
}

// 403 for a skill (or alias) reaching a tool the caller may not have, and for any alwaysOn
// tool the caller may not have. Skills without a Tool are OpenClaw built-ins and pass.
export function assertSkillsEntitled(ctx: SecurityContext, skills: string[] | undefined, tools: ToolEntitlement[]): void {
  for (const t of tools.filter((t) => t.alwaysOn)) {
    const denial = toolDenial(ctx, t);
    if (denial) throw new HttpError(403, `${denial}; it is attached to every agent (alwaysOn)`);
  }
  const bySkill = skillIndex(tools);
  for (const asked of (skills ?? []).map(String)) {
    const tool = bySkill.get(asked);
    const denial = tool ? toolDenial(ctx, tool) : "";
    if (!denial) continue;
    throw new HttpError(403, tool!.skill === asked ? denial
      : `forbidden: skill '${asked}' grants tool '${tool!.skill}', which ${denial.replace(/^forbidden: tool '[^']*' /, "")}`);
  }
}
