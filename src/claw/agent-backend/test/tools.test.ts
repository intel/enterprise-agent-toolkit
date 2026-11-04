// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { toolDenial, skillIndex, assertSkillsEntitled, filterToolsForCaller, unknownRolesIn } from "../lib/security/tools.js";
import { ctx } from "./helpers.js";

const SANDBOX = { skill: "sandbox", aliasSkills: ["shell"], allowedRoles: ["agent-editor"] };
const MEMORY = { skill: "memory", alwaysOn: true };

test("no allowedRoles is unrestricted; the ladder admits higher roles; unknown names admit nobody", () => {
  assert.equal(toolDenial(ctx(), MEMORY), "");
  assert.equal(toolDenial(ctx(["agent-admin"]), SANDBOX), "");
  assert.notEqual(toolDenial(ctx(["agent-viewer"]), SANDBOX), "");
  assert.notEqual(toolDenial(ctx(["platform-admin"]), { skill: "x", allowedRoles: ["agent-editorr"] }), "");
  assert.deepEqual(unknownRolesIn({ skill: "x", allowedRoles: ["agent-editorr", "agent-viewer"] }), ["agent-editorr"]);
});

test("an alias reaches its tool, and never shadows another tool's skill", () => {
  const idx = skillIndex([SANDBOX, { skill: "shell" }]);
  assert.equal(idx.get("shell")?.skill, "shell");
  assert.equal(skillIndex([SANDBOX]).get("shell")?.skill, "sandbox");
});

test("asking for a restricted tool by its alias is refused, as is an alwaysOn tool", () => {
  assert.throws(() => assertSkillsEntitled(ctx(["agent-viewer"]), ["shell"], [SANDBOX]), /skill 'shell' grants tool 'sandbox'/);
  assert.throws(() => assertSkillsEntitled(ctx(["agent-viewer"]), [], [{ ...MEMORY, allowedRoles: ["agent-admin"] }]), /alwaysOn/);
  assert.doesNotThrow(() => assertSkillsEntitled(ctx(["agent-viewer"]), ["read_file"], [SANDBOX]));
  assert.deepEqual(filterToolsForCaller(ctx(["agent-viewer"]), [SANDBOX, MEMORY]).map((t) => t.skill), ["memory"]);
});
