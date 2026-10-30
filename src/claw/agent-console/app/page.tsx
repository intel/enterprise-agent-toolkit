// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect, useState } from "react";
import { ButtonLink } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { AlertTriangle } from "lucide-react";

export default function Home() {
  const [email, setEmail] = useState<string>("");
  const [err, setErr] = useState<string>("");

  useEffect(() => {
    fetch("/api/me", { cache: "no-store" })
      .then(async (r) => {
        const d = await r.json();
        if (!r.ok) throw new Error(d?.error || "not signed in");
        setEmail(d.email);
      })
      .catch((e) => setErr(String(e?.message ?? e)));
  }, []);

  return (
    <div className="space-y-4">
      <h1 className="text-lg font-semibold">Welcome</h1>
      {err && (
        <div className="flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          <AlertTriangle size={14} /> {err}
        </div>
      )}
      <Card>
        <CardContent className="pt-4">
          {email ? (
            <p className="text-sm">
              Signed in as <b>{email}</b>. You manage <b>your own</b> agents plus any shared with
              you.
            </p>
          ) : (
            <p className="text-sm text-muted-foreground">Resolving your identity…</p>
          )}
          <div className="mt-3 flex gap-2">
            <ButtonLink href={"/agents"}>Manage agents</ButtonLink>
            <ButtonLink variant="outline" href={"/agents/new"}>
              Create agent
            </ButtonLink>
          </div>
        </CardContent>
      </Card>
      <p className="text-xs text-muted-foreground">
        Each agent belongs to its owner; another user reaches it only through a time-limited share.
      </p>
    </div>
  );
}
