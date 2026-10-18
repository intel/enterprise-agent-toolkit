// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { SecurityContext } from "../lib/security/authn.js";

// dist-test/test → the sources, which the route-matrix tests read as text.
export const source = (rel: string) => readFileSync(join(import.meta.dirname, "..", "..", rel), "utf8");

export function ctx(roles: string[] = [], scopes: string[] = [], email = "alice@example.com"): SecurityContext {
  return { subject: "sub-1", email, username: email.split("@")[0], roles, scopes, isAdmin: false, tenantId: "", requestId: "req-1", authMethod: "jwt" };
}
