// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// HTTP errors, header access and the owner-namespace rule shared by the API.
import type { SecurityContext } from "./security/authn.js";

export type Caller = SecurityContext;

// An error carrying the HTTP status a handler should answer with.
export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

// Fetch Headers, or Express's object of lowercased header names.
export type HeaderSource =
  | { get(name: string): string | null }
  | Record<string, string | string[] | undefined>;

export function headerGet(h: HeaderSource, name: string): string {
  if (h && typeof (h as any).get === "function") return ((h as any).get(name) || "").toString();
  const v = (h as Record<string, string | string[] | undefined>)[name.toLowerCase()];
  return ((Array.isArray(v) ? v[0] : v) || "").toString();
}

// user-<username>: the namespace an owner's Agents live in (the operator enforces the same).
export function ownerNamespace(username: string): string {
  const slug = username.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return `user-${slug}`.slice(0, 63).replace(/-+$/, "");
}
