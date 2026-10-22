// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { provisioningSteps } from "../lib/k8s.js";

const agent = (phase: string, conditions: object[]) => ({ metadata: { namespace: "user-alice", name: "lab" }, status: { phase, conditions } });

test("provisioning comes from the operator's conditions", () => {
  const { steps, phase } = provisioningSteps(agent("Running", [
    { type: "IdentityReady", status: "True", message: "Keycloak client agent-alice-lab" },
    { type: "MemoryReady", status: "False", reason: "Disabled" },
    { type: "PodReady", status: "False", reason: "NotReady" },
  ]));
  const state = Object.fromEntries(steps.map((s) => [s.key, s.state]));
  assert.equal(phase, "Running");
  assert.deepEqual(state, { agent: "ok", identity: "ok", memory: "na", backend: "pending", seeding: "pending", pod: "pending" });
});

test("a failed agent marks its false conditions as errors", () => {
  const { steps } = provisioningSteps(agent("Failed", [{ type: "BackendReady", status: "False", reason: "ProvisioningFailed" }]));
  assert.equal(steps.find((s) => s.key === "backend")?.state, "error");
});
