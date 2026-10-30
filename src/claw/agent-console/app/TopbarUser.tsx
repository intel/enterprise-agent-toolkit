// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useMe } from "@/lib/useMe";

export default function TopbarUser() {
  const me = useMe();

  if (!me) return null;
  return (
    <span className="flex items-center gap-2 text-xs text-muted-foreground">
      <span className="hidden font-medium text-foreground sm:inline">{me.email}</span>
      {/* Served by the platform gateway, which ends the sign-in session. */}
      <a
        href="/oauth2/logout"
        title="Sign out"
        className="rounded-md border border-border px-2 py-1 transition-colors hover:border-primary hover:text-foreground"
      >
        Sign out
      </a>
    </span>
  );
}
