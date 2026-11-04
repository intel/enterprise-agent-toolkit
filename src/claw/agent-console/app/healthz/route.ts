// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
// Liveness for the kubelet; /api belongs to the API on this host.
export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({ status: "ok" });
}
