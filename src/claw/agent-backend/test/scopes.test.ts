// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { SCOPE_READ, SCOPE_WRITE, parseScopeClaim, scopeDenial, requireScope, stackScopesOf } from "../lib/security/scopes.js";
import { ctx } from "./helpers.js";

test("the scope claim is parsed from a string or an array", () => {
  assert.deepEqual(parseScopeClaim("openid  agent:read email"), ["openid", "agent:read", "email"]);
  assert.deepEqual(parseScopeClaim(["agent:read", 7]), ["agent:read"]);
  assert.deepEqual(parseScopeClaim(undefined), []);
});

test("a token is limited to its scopes, whatever the caller's roles; no scope means no access", () => {
  assert.equal(scopeDenial(ctx(["platform-admin"], [SCOPE_READ]), SCOPE_READ), "");
  assert.notEqual(scopeDenial(ctx(["platform-admin"], [SCOPE_READ]), SCOPE_WRITE), "");
  assert.notEqual(scopeDenial(ctx(["platform-admin"], ["openid"]), SCOPE_READ), "");
  assert.throws(() => scopeDenial(ctx(), "agent:reed"), /unknown scope/);
  assert.deepEqual(stackScopesOf(ctx([], ["openid", SCOPE_READ])), [SCOPE_READ]);
});

test("a scope denial is 403 with an RFC 6750 challenge", () => {
  const headers: Record<string, string> = {};
  const req: any = { ctx: ctx([], [SCOPE_READ]) };
  let err: any;
  requireScope(SCOPE_WRITE)(req, { setHeader: (k: string, v: string) => { headers[k] = v; } } as any, (e?: any) => { err = e; });
  assert.equal(err?.status, 403);
  assert.match(headers["www-authenticate"], /insufficient_scope.*agent:write/);
});
