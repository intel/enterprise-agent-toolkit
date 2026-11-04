// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import { test } from "node:test";
import assert from "node:assert/strict";
import { AUDIT_DDL, AUDIT_TABLE, AUDIT_DEFAULT_PARTITION, AUDIT_ENSURE_FN } from "../lib/audit.js";
import { source } from "./helpers.js";

test("audit_events is partitioned by month, with a default partition and the CronJob's function", () => {
  assert.match(AUDIT_DDL, /PARTITION BY RANGE \(ts\)/);
  assert.match(AUDIT_DDL, new RegExp(`${AUDIT_DEFAULT_PARTITION} PARTITION OF ${AUDIT_TABLE} DEFAULT`));
  assert.match(AUDIT_DDL, new RegExp(`CREATE OR REPLACE FUNCTION ${AUDIT_ENSURE_FN}\\(`));
});

test("the backend has no statement that removes or rewrites an audit row", () => {
  const code = source("lib/audit.ts").split("\n").map((l) => l.replace(/(^|\s)(\/\/|--).*$/, "$1")).join("\n");
  for (const forbidden of [/\bDELETE\s+FROM\b/i, /\bDROP\s+TABLE\b/i, /\bTRUNCATE\b/i, /\bUPDATE\s+\w*audit/i]) {
    assert.doesNotMatch(code, forbidden);
  }
});
