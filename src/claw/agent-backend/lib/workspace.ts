// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Client-supplied Agent spec fields, filtered the same way on create and patch.

// The Agent CRD's rule: relative paths of plain segments, no "." or "..".
const SAFE_KEY = /^[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/;
const MAX_KEY_LEN = 255;

// undefined when no map was sent; `{}` (replace with nothing) when every key was dropped.
export function sanitizeWorkspace(input: unknown): Record<string, string> | undefined {
  if (!input || typeof input !== "object" || Array.isArray(input)) return undefined;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(input as Record<string, unknown>)) {
    const rel = String(k).replace(/^\/+/, "");
    if (typeof v !== "string" || rel.length > MAX_KEY_LEN || !SAFE_KEY.test(rel)) continue;
    if (rel.split("/").some((s) => s === "." || s === "..")) continue;
    out[rel] = v;
  }
  return out;
}

// Lowercased and trimmed; undefined (leave alone) unless an array was sent.
export function normalizeWebFetchAllowlist(input: unknown): string[] | undefined {
  if (!Array.isArray(input)) return undefined;
  return input.map((d) => String(d).trim().toLowerCase()).filter(Boolean);
}
