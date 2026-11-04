// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
import type { Metadata } from "next";
import "./globals.css";
import { ThemeProvider } from "@/components/theme-provider";
import { AppSidebar } from "@/components/app-sidebar";
import { AppTopbar } from "@/components/app-topbar";
import { SessionGuard } from "@/components/SessionGuard";

export const metadata: Metadata = {
  title: "Agent Console",
  description: "Create, share and talk to your persistent agents",
};

export const viewport = { width: "device-width", initialScale: 1 };
// Rendered per request, so deployment settings (GRAFANA_URL) are read at run time.
export const dynamic = "force-dynamic";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>
        <ThemeProvider>
          <SessionGuard />
          <div className="flex h-screen overflow-hidden">
            <AppSidebar />
            <div className="flex flex-1 flex-col overflow-hidden">
              <AppTopbar grafana={process.env.GRAFANA_URL || ""} />
              <main className="flex-1 overflow-y-auto p-4 md:p-6">
                <div className="mx-auto max-w-5xl">{children}</div>
              </main>
            </div>
          </div>
        </ThemeProvider>
      </body>
    </html>
  );
}
