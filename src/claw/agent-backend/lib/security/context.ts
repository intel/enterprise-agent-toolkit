// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Request id and the verified caller, resolved once per request; handlers read req.ctx.
import type { Request, Response, NextFunction } from "express";
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
