// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Request id and the verified caller, resolved once per request; handlers read req.ctx.
import type { Request, Response, NextFunction } from "express";
import type { IncomingHttpHeaders } from "node:http";
import { randomUUID } from "node:crypto";
import { HttpError, type Caller } from "../identity.js";
import { extractToken, verifyToken, contextFromClaims } from "./authn.js";

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      ctx?: Caller;
      requestId?: string;
    }
  }
}

// Reaches logs, audit rows and annotations, so a client value must be bounded and plain.
const REQUEST_ID_RE = /^[A-Za-z0-9._-]{1,128}$/;

export function resolveRequestId(raw: unknown): string {
  const v = Array.isArray(raw) ? raw[0] : raw;
  return typeof v === "string" && REQUEST_ID_RE.test(v) ? v : randomUUID();
}

const UNSAFE_METHODS = new Set(["POST", "PUT", "PATCH", "DELETE"]);

// The browser attaches the session cookie to a form posted from any site, so a state change
// must come from this host. Scripts send no Origin and pass.
export function crossSiteRefusal(method: string, headers: IncomingHttpHeaders): string | null {
  if (!UNSAFE_METHODS.has(method.toUpperCase())) return null;
  if (headers["sec-fetch-site"] === "cross-site") return "cross-site request";
  if (headers.origin === undefined) return null;
  try {
    if (new URL(String(headers.origin)).host === String(headers.host ?? "")) return null;
  } catch { /* "null" or not a URL */ }
  return `cross-site request from origin '${headers.origin}'`;
}

export function crossSiteMiddleware(req: Request, _res: Response, next: NextFunction): void {
  const reason = crossSiteRefusal(req.method, req.headers);
  next(reason ? new HttpError(403, `forbidden: ${reason}`) : undefined);
}

export function requestIdMiddleware(req: Request, res: Response, next: NextFunction): void {
  req.requestId = resolveRequestId(req.headers["x-request-id"]);
  res.setHeader("x-request-id", req.requestId);
  next();
}

export async function resolveCaller(req: Request): Promise<Caller> {
  const token = extractToken(req.headers);
  if (!token) {
    throw new HttpError(401, "unauthenticated: send Authorization: Bearer <access_token>");
  }
  return contextFromClaims(await verifyToken(token), req.requestId || resolveRequestId(undefined));
}

// Mounted once, so no route can run unauthenticated.
export function authenticate() {
  return async (req: Request, _res: Response, next: NextFunction): Promise<void> => {
    try {
      req.ctx = await resolveCaller(req);
      next();
    } catch (e) {
      next(e);
    }
  };
}

// A missing context is a wiring bug (route outside authenticate()), hence 500, not 401.
export function requireCtx(req: Request): Caller {
  if (!req.ctx) throw new HttpError(500, "internal: route is not mounted behind authenticate()");
  return req.ctx;
}
