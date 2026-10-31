// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// The route matrix, checked against server.ts itself: a route shipped without its role, scope,
// resource gate or audit fails here, not in production.
import { test } from "node:test";
import assert from "node:assert/strict";
import { source } from "./helpers.js";

const SRC = source("server.ts");
const PUBLIC = ["GET /api/healthz", "GET /api/authz-config", "GET /api/me"];
// route → [role, scope, gate in its handler, audited]
const MATRIX: Record<string, [string, string, RegExp, boolean]> = {
  "GET /api/tools": ["ROLE_VIEWER", "SCOPE_READ", /filterToolsForCaller/, false],
  "GET /api/models": ["ROLE_VIEWER", "SCOPE_READ", /listGateways/, false],
  "GET /api/agents": ["ROLE_VIEWER", "SCOPE_READ", /listAgentsForUser\(ctx\.email\)/, false],
  "POST /api/agents": ["ROLE_EDITOR", "SCOPE_WRITE", /assertSkillsEntitled/, true],
  "GET /api/agents/:ns/:name": ["ROLE_VIEWER", "SCOPE_READ", /capOn\(req, "view"\)/, false],
  "DELETE /api/agents/:ns/:name": ["ROLE_EDITOR", "SCOPE_WRITE", /capOn\(req, "delete"\)/, true],
  "PATCH /api/agents/:ns/:name": ["ROLE_EDITOR", "SCOPE_WRITE", /ownerOn\(req[\s\S]*assertSkillsEntitled/, true],
  "POST /api/agents/:ns/:name/suspend": ["ROLE_EDITOR", "SCOPE_WRITE", /changeState/, true],
  "POST /api/agents/:ns/:name/resume": ["ROLE_EDITOR", "SCOPE_WRITE", /changeState/, true],
  "GET /api/agents/:ns/:name/provisioning": ["ROLE_VIEWER", "SCOPE_READ", /capOn\(req, "view"\)/, false],
  "GET /api/agents/:ns/:name/grants": ["ROLE_VIEWER", "SCOPE_READ", /ownerOn\(req/, false],
  "POST /api/agents/:ns/:name/grants": ["ROLE_EDITOR", "SCOPE_GRANT", /ownerOn\(req/, true],
  "DELETE /api/agents/:ns/:name/grants/:grant": ["ROLE_EDITOR", "SCOPE_GRANT", /ownerOn\(req/, true],
};

const ROUTE_RE = /^app\.(get|post|patch|delete|all)\("([^"]+)",(.*)$/gm;
const routes = [...SRC.matchAll(ROUTE_RE)].map((m) => ({
  key: `${m[1].toUpperCase()} ${m[2]}`, head: m[3],
  body: SRC.slice(m.index!, SRC.indexOf("\napp.", m.index! + 1) >>> 0 || undefined),
}));

test("every route is public by name or in the matrix, and vice versa", () => {
  assert.deepEqual(routes.map((r) => r.key).filter((k) => !PUBLIC.includes(k)).sort(), Object.keys(MATRIX).sort());
});

test("routes are mounted after authenticate(), except the two probes", () => {
  const auth = SRC.indexOf("app.use(authenticate())");
  for (const m of SRC.matchAll(ROUTE_RE)) {
    const key = `${m[1].toUpperCase()} ${m[2]}`;
    assert.equal(m.index! > auth, !["GET /api/healthz", "GET /api/authz-config"].includes(key), key);
  }
});

for (const [key, [role, scope, gate, auditedWrite]] of Object.entries(MATRIX)) {
  test(`${key}: ${role}, ${scope}, its resource gate and ${auditedWrite ? "an audit row" : "read handling"}`, () => {
    const r = routes.find((x) => x.key === key)!;
    assert.match(r.head, new RegExp(`requireRole\\(${role}\\), requireScope\\(${scope}\\)`));
    assert.match(r.body, gate);
    assert.equal(/\baudited\(/.test(r.head), auditedWrite);
    if (key.includes("suspend") || key.includes("resume")) assert.match(SRC, /async function changeState[\s\S]*?capOn\(req, "suspend-resume"\)/);
  });
}

test("the API holds no agent gateway credential", () => {
  assert.doesNotMatch(SRC + source("lib/k8s.ts"), /gateway-token|getGatewayToken|x-gw-/);
});
