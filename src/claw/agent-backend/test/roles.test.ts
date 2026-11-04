// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { ROLE_VIEWER, ROLE_EDITOR, ROLE_AGENT_ADMIN, ROLE_PLATFORM_ADMIN, roleDenial, hasRole, requireRole } from "../lib/security/roles.js";
import { ctx } from "./helpers.js";

const LADDER = [ROLE_VIEWER, ROLE_EDITOR, ROLE_AGENT_ADMIN, ROLE_PLATFORM_ADMIN];

test("each role satisfies itself and every role below it, nothing above", () => {
  LADDER.forEach((held, i) => LADDER.forEach((need, j) =>
    assert.equal(roleDenial(ctx([held]), need) === "", j <= i, `${held} → ${need}`)));
});

test("no role of ours denies every guard; a typo in a guard is a 500, not an allow", () => {
  for (const need of LADDER) assert.notEqual(roleDenial(ctx(["offline_access"]), need), "");
  assert.throws(() => roleDenial(ctx([ROLE_PLATFORM_ADMIN]), "agent-editorr"), /unknown role/);
});

test("hasRole is exact: outranking a role is not holding it", () => {
  assert.equal(hasRole(ctx([ROLE_PLATFORM_ADMIN]), ROLE_AGENT_ADMIN), false);
});

test("a role denial is 403 and records the deciding layer", () => {
  const req: any = { ctx: ctx([ROLE_VIEWER]) };
  let err: any;
  requireRole(ROLE_EDITOR)(req, {} as any, (e?: any) => { err = e; });
  assert.equal(err?.status, 403);
  assert.equal(req.decision.decidedBy, "role");
});
