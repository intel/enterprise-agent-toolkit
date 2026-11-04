// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useState } from "react";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

// Password/secret input with a show/hide toggle. Masks by default; the eye
// button reveals the value.
export default function SecretInput({
  value,
  onChange,
  placeholder,
  id,
  className,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  id?: string;
  className?: string;
}) {
  const [show, setShow] = useState(false);
  return (
    <div className="relative flex items-center">
      <Input
        id={id}
        type={show ? "text" : "password"}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        autoComplete="off"
        className={cn("pr-16", className)}
      />
      <button
        type="button"
        onClick={() => setShow((s) => !s)}
        aria-label={show ? "Hide" : "Show"}
        tabIndex={-1}
        className="absolute right-1.5 rounded-md border border-border px-2 py-1 text-[11px] uppercase tracking-wide text-muted-foreground transition-colors hover:border-primary hover:text-foreground"
      >
        {show ? "hide" : "show"}
      </button>
    </div>
  );
}
