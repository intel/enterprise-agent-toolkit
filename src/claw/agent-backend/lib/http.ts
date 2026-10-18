// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Error-to-response mapping and the If-Match precondition.
import type { Response } from "express";
import { HttpError } from "./identity.js";

export function statusOf(e: any): number {
  if (e instanceof HttpError) return e.status;
  const s = e?.status; // ConflictError and API errors carry a status without extending HttpError
  return typeof s === "number" && s >= 400 && s <= 599 ? s : 500;
}

// 5xx details (API text, URLs) go to the log only; the caller correlates by x-request-id.
export function errResponse(res: Response, e: any): void {
  const status = statusOf(e);
  const message = e?.message ?? String(e);
  if (status >= 500) {
    console.error(JSON.stringify({
      level: "error", msg: "request failed", status, requestId: res.getHeader("x-request-id") ?? "", err: message,
    }));
    res.status(status).json({ error: status === 503 ? "service temporarily unavailable" : "internal error" });
    return;
  }
  res.status(status).json({ error: message });
}

// If-Match → resourceVersion. `*` asserts only existence (treated as absent); a list is refused.
export function parseIfMatch(raw: unknown, required: boolean): string | undefined {
  const first = Array.isArray(raw) ? raw[0] : raw;
  const v = (typeof first === "string" ? first : "").trim();
  if (!v || v === "*") {
    if (required) {
      throw new HttpError(428, 'precondition required: send If-Match: "<resourceVersion>" from the object you read');
    }
    return undefined;
  }
  if (v.includes(",")) throw new HttpError(400, "If-Match must carry exactly one resourceVersion");
  const rv = v.replace(/^W\//, "").replace(/^"|"$/g, "").trim();
  if (!rv) throw new HttpError(400, "If-Match is empty");
  return rv;
}

export function etagFor(resourceVersion: string): string {
  return `"${resourceVersion}"`;
}
