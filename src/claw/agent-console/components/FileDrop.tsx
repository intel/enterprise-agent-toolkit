// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useRef, useState } from "react";
import { Check, Upload } from "lucide-react";
import { cn } from "@/lib/utils";

// Folder upload with drag and drop; the parent turns the files into workspace entries.
export default function FileDrop({
  onPick,
  count = 0,
  names = [],
}: {
  onPick: (files: FileList) => void;
  count?: number;
  names?: string[];
}) {
  const ref = useRef<HTMLInputElement>(null);
  const [drag, setDrag] = useState(false);

  function handle(files: FileList | null) {
    if (files && files.length) onPick(files);
  }

  return (
    <div
      className={cn(
        "cursor-pointer rounded-lg border border-dashed border-border bg-muted/30 p-4 transition-colors",
        drag && "border-primary bg-primary/5",
        count > 0 && "border-solid border-success/50"
      )}
      onClick={() => ref.current?.click()}
      onDragOver={(e) => { e.preventDefault(); setDrag(true); }}
      onDragLeave={() => setDrag(false)}
      onDrop={(e) => { e.preventDefault(); setDrag(false); handle(e.dataTransfer.files); }}
    >
      <input
        ref={ref}
        type="file"
        hidden
        onChange={(e) => handle(e.target.files)}
        {...({ webkitdirectory: "", directory: "", mozdirectory: "" } as any)}
        multiple
      />
      <div className="flex items-center gap-3">
        <span
          className={cn(
            "grid h-8 w-8 flex-none place-items-center rounded-lg bg-primary/10 text-primary",
            count > 0 && "bg-success/15 text-success"
          )}
        >
          {count > 0 ? <Check size={16} /> : <Upload size={16} />}
        </span>
        {count > 0 ? (
          <div>
            <strong className="text-sm font-semibold">
              {count} file{count === 1 ? "" : "s"} staged
            </strong>
            <p className="mt-0.5 text-xs text-muted-foreground">
              {names.slice(0, 6).join(", ")}{names.length > 6 ? " …" : ""}
            </p>
            <p className="mt-0.5 text-xs text-muted-foreground">Click to replace</p>
          </div>
        ) : (
          <div>
            <strong className="text-sm font-semibold">Drop a folder here, or click to browse</strong>
            <p className="mt-0.5 text-xs text-muted-foreground">The top-level folder is stripped.</p>
          </div>
        )}
      </div>
    </div>
  );
}
