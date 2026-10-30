// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// A picked folder as spec.workspace: text as-is, binary as "base64:<data>", top folder stripped.

// Extensions we treat as text; everything else is base64-encoded as binary.
const TEXT_EXT = new Set([
  "md", "txt", "json", "yaml", "yml", "toml", "ini", "cfg", "conf",
  "js", "ts", "tsx", "jsx", "py", "sh", "bash", "go", "rs", "rb", "java",
  "c", "h", "cpp", "hpp", "css", "html", "xml", "csv", "env", "gitignore",
  "sql", "properties", "mjs", "cjs",
]);

function isTextPath(path: string): boolean {
  const base = path.split("/").pop() || "";
  if (!base.includes(".")) return true; // extensionless (AGENTS, Dockerfile…) → text
  const ext = base.split(".").pop()!.toLowerCase();
  return TEXT_EXT.has(ext);
}

function arrayBufferToBase64(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

export interface DirToWorkspaceResult {
  workspace: Record<string, string>;
  skipped: string[]; // paths dropped for path-traversal / empty rel
}

// Convert a FileList from an <input webkitdirectory> into the workspace map.
export async function dirToWorkspace(files: FileList | File[]): Promise<DirToWorkspaceResult> {
  const list = Array.from(files);
  const workspace: Record<string, string> = {};
  const skipped: string[] = [];
  for (const f of list) {
    // webkitRelativePath = "<topdir>/a/b/file"; strip the top dir.
    const full = (f as any).webkitRelativePath || f.name;
    const rel = full.split("/").slice(1).join("/") || f.name;
    if (!rel || rel.split("/").includes("..")) {
      skipped.push(full);
      continue;
    }
    if (isTextPath(rel)) {
      workspace[rel] = await f.text();
    } else {
      workspace[rel] = "base64:" + arrayBufferToBase64(await f.arrayBuffer());
    }
  }
  return { workspace, skipped };
}

// Human-readable summary of a workspace map for the UI.
export function workspaceSummary(ws: Record<string, string>): string {
  const n = Object.keys(ws).length;
  if (!n) return "no files";
  return `${n} file${n === 1 ? "" : "s"}`;
}
