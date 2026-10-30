// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Scope checks: may this token be used this way? Downgrade only (effective = role ∩ scope).
import type { Request, Response, NextFunction } from "express";
import { HttpError } from "../identity.js";
import type { SecurityContext } from "./authn.js";

export const SCOPE_READ = "agent:read";
export const SCOPE_WRITE = "agent:write";
export const SCOPE_CONVERSE = "agent:converse";
export const SCOPE_GRANT = "agent:grant";
export const STACK_SCOPES: readonly string[] = [SCOPE_READ, SCOPE_WRITE, SCOPE_CONVERSE, SCOPE_GRANT];

// RFC 6749 space-delimited string; the array form exists in the wild.
export function parseScopeClaim(raw: unknown): string[] {
  if (Array.isArray(raw)) return raw.filter((s): s is string => typeof s === "string");
  return typeof raw === "string" ? raw.split(/\s+/).filter(Boolean) : [];
}

export function stackScopesOf(ctx: SecurityContext): string[] {
  return ctx.scopes.filter((s) => STACK_SCOPES.includes(s));
}

// The denial reason, or "" when allowed.
export function scopeDenial(ctx: SecurityContext, need: string): string {
  if (!STACK_SCOPES.includes(need)) throw new HttpError(500, `internal: unknown scope '${need}' in a route guard`);
  return ctx.scopes.includes(need) ? "" : `insufficient_scope: scope '${need}' required`;
}

// 403 insufficient_scope with the RFC 6750 challenge; before any resource is looked up.
export function requireScope(need: string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    try {
      if (!req.ctx) throw new HttpError(500, "internal: requireScope is mounted outside authenticate()");
      const denial = scopeDenial(req.ctx, need);
      if (denial) {
        res.setHeader("www-authenticate", `Bearer error="insufficient_scope", scope="${need}"`);
        req.decision = { decidedBy: "scope" };
        throw new HttpError(403, denial);
      }
      next();
    } catch (e) {
      next(e);
    }
  };
}

export function scopeConfig() {
  return { enforcement: true, read: SCOPE_READ, write: SCOPE_WRITE, converse: SCOPE_CONVERSE, grant: SCOPE_GRANT };
}
