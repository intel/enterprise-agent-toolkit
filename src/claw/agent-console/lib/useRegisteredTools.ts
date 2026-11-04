// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect, useState } from "react";

// A registered Tool, as GET /api/tools returns it.
export interface RegisteredTool {
  skill: string;
  requiresIdentity: boolean;
  alwaysOn: boolean;
  description: string;
}

interface State {
  tools: RegisteredTool[];
  loading: boolean;
  error: string;
}

// Read once per page; on failure the list is empty and the page still works.
export function useRegisteredTools(): State {
  const [state, setState] = useState<State>({ tools: [], loading: true, error: "" });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch("/api/tools", { cache: "no-store" });
        const data = await res.json();
        if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
        if (!cancelled) setState({ tools: data.tools ?? [], loading: false, error: "" });
      } catch (e: any) {
        if (!cancelled) setState({ tools: [], loading: false, error: String(e?.message ?? e) });
      }
    })();
    return () => { cancelled = true; };
  }, []);

  return state;
}
