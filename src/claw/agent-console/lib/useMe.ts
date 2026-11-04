// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect, useState } from "react";

interface Me {
  email: string;
  username: string;
  isAdmin: boolean;
  // Realm roles, for break-glass; isAdmin (platform-admin) only shows operator links.
  roles: string[];
}

// The signed-in user, from /api/me.
export function useMe(): Me | null {
  const [me, setMe] = useState<Me | null>(null);

  useEffect(() => {
    fetch("/api/me", { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => d?.email && setMe({
        email: d.email,
        username: d.username,
        isAdmin: !!d.isAdmin,
        roles: Array.isArray(d.roles) ? d.roles : [],
      }))
      .catch(() => {});
  }, []);

  return me;
}
