// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { sanitizeWorkspace, normalizeWebFetchAllowlist } from "../lib/workspace.js";
import { validateAgentNaming, agentNamespace } from "../lib/k8s.js";
import { ownerNamespace } from "../lib/identity.js";
import { parseIfMatch } from "../lib/http.js";
import { crossSiteRefusal } from "../lib/security/context.js";

test("workspace keys follow the Agent CRD rule; others are dropped", () => {
  const out = sanitizeWorkspace({
    "AGENTS.md": "a", "/notes/a.md": "b", "../x": "c", "a/./b": "d", "a//b": "e", 'x"$(id)': "f",
    "my notes.md": "g", "ok.txt": 7,
  });
  assert.deepEqual(out, { "AGENTS.md": "a", "notes/a.md": "b" });
  assert.equal(sanitizeWorkspace(["x"]), undefined);
  assert.deepEqual(sanitizeWorkspace({ "../x": "c" }), {});
});

test("the allowlist is trimmed and lowercased; no array leaves it alone", () => {
  assert.deepEqual(normalizeWebFetchAllowlist([" GitHub.com ", ""]), ["github.com"]);
  assert.equal(normalizeWebFetchAllowlist("github.com"), undefined);
});

test("names: DNS-1035 agent names, hyphen-free usernames, derived names within 63", () => {
  assert.equal(validateAgentNaming("lab-1", "alice"), "alice");
  for (const [name, user] of [["1lab", "alice"], ["Lab", "alice"], ["lab", "al-ice"], ["lab", "al_ice"], ["lab", ""], ["a".repeat(60), "alice"]]) {
    assert.throws(() => validateAgentNaming(name, user), (e: any) => e.status === 400, `${name}/${user}`);
  }
  assert.equal(agentNamespace("alice", "lab"), "agent-alice-lab");
  assert.equal(ownerNamespace("alice"), "user-alice");
});

test("If-Match: one strong or weak version; * and absent are none unless required", () => {
  assert.equal(parseIfMatch('W/"42"', false), "42");
  assert.equal(parseIfMatch("*", false), undefined);
  assert.throws(() => parseIfMatch(undefined, true), (e: any) => e.status === 428);
  assert.throws(() => parseIfMatch('"1", "2"', false), (e: any) => e.status === 400);
});

test("state changes from another site are refused; scripts and same-site calls pass", () => {
  const host = "agents.example.com";
  // A form on another site: the browser sends the session cookie and its own Origin.
  assert.match(crossSiteRefusal("POST", { host, origin: "https://evil.example" }) ?? "", /cross-site/);
  assert.match(crossSiteRefusal("DELETE", { host, origin: "null" }) ?? "", /cross-site/);
  assert.match(crossSiteRefusal("PATCH", { host, "sec-fetch-site": "cross-site" }) ?? "", /cross-site/);
  assert.equal(crossSiteRefusal("POST", { host, origin: `https://${host}` }), null); // the console
  assert.equal(crossSiteRefusal("POST", { host }), null); // a script: no Origin
  assert.equal(crossSiteRefusal("GET", { host, origin: "https://evil.example" }), null); // reads change nothing
});
