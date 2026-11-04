// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { sanitizeWorkspace, normalizeWebFetchAllowlist } from "../lib/workspace.js";
import { validateAgentNaming, agentNamespace, validateRuntime, enabledRuntimes } from "../lib/k8s.js";
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

test("runtime: claw by default; openshell only when enabled, within 19 characters, on the cluster's model", () => {
  delete process.env.OPENSHELL_ENABLED;
  assert.deepEqual(enabledRuntimes(), ["claw"]);
  assert.equal(validateRuntime(undefined, "oss-solo", "vkumar4"), "claw");
  assert.throws(() => validateRuntime("openshell", "oss", "vkumar4"), (e: any) => e.status === 400 && /not available/.test(e.message));
  assert.throws(() => validateRuntime("hermes", "oss", "vkumar4"), (e: any) => e.status === 400);
  process.env.OPENSHELL_ENABLED = "true";
  try {
    assert.deepEqual(enabledRuntimes(), ["claw", "openshell"]);
    assert.equal(validateRuntime("openshell", "oss", "vkumar4"), "openshell");
    // agent-vkumar4-oss-solo is 22; agent-vkumar4- leaves 5.
    assert.throws(() => validateRuntime("openshell", "oss-solo", "vkumar4"),
      (e: any) => e.status === 400 && /is 22/.test(e.message) && /at most 5 characters/.test(e.message));
    assert.throws(() => validateRuntime("openshell", "a", "averyverylonguser"), (e: any) => /leaves no room/.test(e.message));
    assert.throws(() => validateRuntime("openshell", "oss", "vkumar4", { baseUrl: "http://x/v1" }), (e: any) => /not supported/.test(e.message));
    assert.throws(() => validateRuntime("openshell", "oss", "vkumar4", { apiKey: "k" }), (e: any) => /not supported/.test(e.message));
    assert.equal(validateRuntime("claw", "oss-solo", "vkumar4", { baseUrl: "http://x/v1" }), "claw");
    // Another model the gateway serves is fine: same endpoint, same key.
    assert.equal(validateRuntime("openshell", "oss", "vkumar4", { id: "qwen3-4b" }), "openshell");
  } finally {
    delete process.env.OPENSHELL_ENABLED;
  }
});
