// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decideAccess, breakGlassReason, breakGlassListingRole, auditDecisionFields, BREAK_GLASS_HEADER, BREAK_GLASS_REFUSED,
} from "../lib/authz.js";
import { expandCaps } from "../lib/capabilities.js";
import type { AgentGrantRow } from "../lib/k8s.js";
import { ctx } from "./helpers.js";

const AGENT = { spec: { owner: { principal: "alice@example.com", username: "alice" } } };
const BOB = ctx([], [], "bob@example.com");
const grant = (over: Partial<AgentGrantRow> = {}): AgentGrantRow => ({
  name: "g", namespace: "user-alice", agentRef: "lab", grantor: "alice@example.com", grantee: "bob@example.com",
  capabilities: ["view", "converse"], tools: [], expiresAt: new Date(Date.now() + 60_000).toISOString(), ...over,
});
const decide = (caller = BOB, grants: AgentGrantRow[] = [], reason?: string) =>
  decideAccess(caller, AGENT, async () => grants, { breakGlassReason: reason });

test("the owner may do everything", async () => {
  const a = await decide(ctx());
  assert.equal(a?.decidedBy, "owner");
  assert.ok(a?.caps.has("delete") && a.caps.has("credential"));
});

test("a live grant from the owner confers exactly its capabilities", async () => {
  const a = await decide(BOB, [grant()]);
  assert.deepEqual([...a!.caps].sort(), ["converse", "view"]);
  assert.equal(a?.decidedBy, "grant");
});

test("expired, foreign-grantor or other-grantee grants confer nothing", async () => {
  for (const g of [grant({ expiresAt: new Date(Date.now() - 1000).toISOString() }), grant({ expiresAt: "" }),
    grant({ grantor: "mallory@example.com" }), grant({ grantee: "carol@example.com" })]) {
    assert.equal(await decide(BOB, [g]), null);
  }
});

test("break-glass needs an admin role and a reason, and never confers credential or delegate", async () => {
  assert.equal(await decide(ctx(["platform-admin"], [], "op@example.com")), null);
  const a = await decide(ctx(["platform-admin"], [], "op@example.com"), [], "incident 4711 review");
  assert.equal(a?.decidedBy, "break-glass");
  assert.ok(!a!.caps.has("credential") && !a!.caps.has("delegate"));
  const v = await decide(ctx(["agent-admin"], [], "op@example.com"), [], "incident 4711 review");
  assert.deepEqual([...v!.caps], ["view"]);
  assert.equal(await decide(ctx(["agent-editor"], [], "op@example.com"), [], "incident 4711 review"), null);
});

test("a break-glass reason is one bounded line, and too short is a 400", () => {
  const req = (v: string) => ({ headers: { [BREAK_GLASS_HEADER]: v } });
  assert.equal(breakGlassReason(req("line one\r\nforged: row")), "line one forged: row");
  assert.throws(() => breakGlassReason(req("short")), (e: any) => e.status === 400);
  assert.equal(breakGlassListingRole(ctx(["agent-admin"]), "incident review"), "agent-admin");
  assert.equal(breakGlassListingRole(ctx(["agent-admin"])), null);
});

test("a refused break-glass attempt is recorded as such", () => {
  const f = auditDecisionFields({ headers: { [BREAK_GLASS_HEADER]: "incident review" }, ctx: ctx(["agent-editor"]) });
  assert.equal(f.decidedBy, BREAK_GLASS_REFUSED);
  assert.deepEqual(auditDecisionFields({ headers: {} }), { decidedBy: "" });
});

test("unknown capabilities in a grant are dropped", () => {
  assert.deepEqual([...expandCaps(["view", "root", "token"])], ["view"]);
});
