// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// What an AgentGrant may confer. `converse` admits the grantee to the agent's gateway route.
export type Capability = "view" | "suspend-resume" | "converse" | "delete";
export const ALL_CAPABILITIES: Capability[] = ["view", "suspend-resume", "converse", "delete"];
export const GRANTABLE_CAPABILITIES = ALL_CAPABILITIES;

// Unknown values are dropped, so a capability added by a newer operator cannot lock out a grant.
export function expandCaps(caps: Iterable<string>): Set<Capability> {
  return new Set([...caps].filter((c): c is Capability => (ALL_CAPABILITIES as string[]).includes(c)));
}
