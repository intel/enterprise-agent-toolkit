// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { BarChart3 } from "lucide-react";
import { ThemeToggle } from "@/components/theme-toggle";
import { useMe } from "@/lib/useMe";
import TopbarUser from "@/app/TopbarUser";

export function AppTopbar({ grafana }: { grafana: string }) {
  const me = useMe();

  return (
    <header className="flex h-14 items-center justify-between gap-4 border-b border-border bg-card/60 px-4 backdrop-blur md:px-6">
      <div className="flex items-center gap-1 md:hidden">
        <span className="text-sm font-semibold">Agent Console</span>
      </div>
      {/* Observability is for operators, not every agent owner. */}
      {me?.isAdmin && grafana && (
        <a
          href={grafana}
          target="_blank"
          rel="noreferrer"
          className="hidden items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm text-muted-foreground transition-colors hover:bg-accent hover:text-foreground md:inline-flex"
        >
          <BarChart3 size={14} /> Grafana
        </a>
      )}
      <div className="ml-auto flex items-center gap-3">
        <ThemeToggle />
        <TopbarUser />
      </div>
    </header>
  );
}
