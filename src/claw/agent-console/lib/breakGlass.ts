// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect, useState } from "react";

// Break-glass in the console only chooses which buttons to offer; the API decides what is allowed.

// The header agent-backend reads (BREAK_GLASS_HEADER there). Node lowercases inbound
// header names, so the casing here is presentation only.
export const BREAK_GLASS_HEADER = "X-Break-Glass-Reason";
// Mirrors BREAK_GLASS_MIN_LEN. Checked here only to fail before the round trip — the
// backend 400s a short reason regardless, which is what actually enforces it.
export const MIN_REASON_LEN = 8;

// Asked PER ACTION, deliberately. An "admin mode" toggle would turn one mandatory reason
// into one reason for a hundred actions, which is the same as no reason at all.
export function askReason(what: string): string | null {
  const r = (
    window.prompt(
      `Admin access: ${what}.\n\n` +
        `You are acting outside your own agents. This is recorded in the audit log with ` +
        `your name and this reason (min ${MIN_REASON_LEN} characters — an incident id is ideal):`,
    ) || ""
  ).trim();
  if (!r) return null;
  if (r.length < MIN_REASON_LEN) {
    alert(`Reason must be at least ${MIN_REASON_LEN} characters. Nothing was done.`);
    return null;
  }
  return r;
}

export function breakGlassHeaders(reason?: string | null): Record<string, string> {
  return reason ? { [BREAK_GLASS_HEADER]: reason } : {};
}

// The caller's admin role, or "", by the names /api/authz-config reports.
export function useAdminRole(roles: string[] | undefined): string {
  const [adminRole, setAdminRole] = useState("");
  const key = (roles ?? []).join(",");

  useEffect(() => {
    if (!key) {
      setAdminRole("");
      return;
    }
    fetch("/api/authz-config", { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        const held = key.split(",");
        const names: string[] = [d?.roles?.platformAdmin, d?.roles?.agentAdmin].filter(Boolean);
        setAdminRole(names.find((n) => held.includes(n)) ?? "");
      })
      .catch(() => {});
  }, [key]);

  return adminRole;
}
