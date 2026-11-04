// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Role checks: may this principal perform this verb at all? No I/O, before any resource lookup.
import type { Request, Response, NextFunction } from "express";
import { HttpError } from "../identity.js";
import type { SecurityContext } from "./authn.js";

export const ROLE_VIEWER = "agent-viewer";
export const ROLE_EDITOR = "agent-editor";
export const ROLE_AGENT_ADMIN = "agent-admin";
export const ROLE_PLATFORM_ADMIN = "platform-admin";

// Ranked, so a higher role satisfies a lower one even if the realm's composites are incomplete.
const RANK: Record<string, number> = {
  [ROLE_VIEWER]: 1, [ROLE_EDITOR]: 2, [ROLE_AGENT_ADMIN]: 3, [ROLE_PLATFORM_ADMIN]: 4,
};

export type RoleName = string;

export function rankOf(role: string): number {
  return RANK[role] ?? 0;
}

export function highestRank(ctx: SecurityContext): number {
  return Math.max(0, ...ctx.roles.map(rankOf));
}

// Exact name, for break-glass: outranking a role is not holding it.
export function hasRole(ctx: SecurityContext, role: string): boolean {
  return ctx.roles.includes(role);
}

// The denial reason, or "" when allowed.
export function roleDenial(ctx: SecurityContext, min: RoleName): string {
  const need = rankOf(min);
  if (!need) throw new HttpError(500, `internal: unknown role '${min}' in a route guard`);
  return highestRank(ctx) >= need ? "" : `forbidden: role '${min}' required`;
}

// 403, not 404: a role denial reveals nothing about which agents exist.
export function requireRole(min: RoleName) {
  return (req: Request, _res: Response, next: NextFunction): void => {
    try {
      if (!req.ctx) throw new HttpError(500, "internal: requireRole is mounted outside authenticate()");
      const denial = roleDenial(req.ctx, min);
      if (denial) {
        req.decision = { decidedBy: "role" };
        throw new HttpError(403, denial);
      }
      next();
    } catch (e) {
      next(e);
    }
  };
}

export function roleConfig() {
  return {
    enforcement: true, viewer: ROLE_VIEWER, editor: ROLE_EDITOR, agentAdmin: ROLE_AGENT_ADMIN,
    platformAdmin: ROLE_PLATFORM_ADMIN,
  };
}
