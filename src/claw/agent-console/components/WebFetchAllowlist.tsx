// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

// The web_fetch allowlist editor for the create and detail pages; the caller saves it.
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";

// One copy of the explanation, so the create form and the detail page can't
// describe the same field differently.
export function WebFetchAllowlistHint() {
  return (
    <p className="text-xs text-muted-foreground">
      Domains this agent&apos;s built-in web_fetch tool may reach.{" "}
      <strong>Until you add one, web_fetch reaches nothing</strong> — the tool is still wired, but
      every request is refused. Egress is opt-in per agent. Adding a domain (e.g.{" "}
      <code className="rounded bg-muted px-1 py-0.5">github.com</code>) also allows its subdomains
      (e.g. <code className="rounded bg-muted px-1 py-0.5">api.github.com</code>) — no separate entry
      needed. Enforced by a per-agent proxy, not by the agent pod itself.
    </p>
  );
}

export default function WebFetchAllowlist({
  domains, onChange,
}: { domains: string[]; onChange: (next: string[]) => void }) {
  const [d, setD] = useState("");
  const openInternet = domains.includes("*");

  function add(raw: string) {
    // Lowercased and trimmed, as the proxy compares lowercase hosts.
    const v = raw.trim().toLowerCase();
    if (!v || domains.includes(v)) return;
    onChange([...domains, v]);
    setD("");
  }
  function remove(v: string) {
    onChange(domains.filter((x) => x !== v));
  }

  return (
    <>
      {domains.length > 0 && (
        <Table>
          <TableHeader><TableRow><TableHead>Domain</TableHead><TableHead /></TableRow></TableHeader>
          <TableBody>
            {domains.map((v) => (
              <TableRow key={v}>
                <TableCell>{v === "*" ? "* (every destination)" : v}</TableCell>
                <TableCell>
                  <Button type="button" size="sm" variant="destructive" onClick={() => remove(v)}>Remove</Button>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      <div className="mt-2 flex gap-2">
        <Input
          type="text" placeholder="github.com" value={d}
          onChange={(e) => setD(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); add(d); } }}
          className="flex-1"
        />
        <Button type="button" variant="outline" onClick={() => add(d)}>+ Add domain</Button>
        {/* "*" is reachable in one click but never preselected: it is a
            deliberate widening to the whole internet, not a starting point. */}
        {!openInternet && (
          <Button type="button" variant="outline" onClick={() => add("*")}>Allow all (*)</Button>
        )}
      </div>
      {openInternet && (
        <p className="mt-2 text-xs text-destructive">
          <strong>*</strong> lets this agent fetch any destination on the internet. Still routed
          through its own proxy, so it is not a NetworkPolicy bypass — but nothing is filtered.
          Remove it and list the domains the agent actually needs.
        </p>
      )}
    </>
  );
}
