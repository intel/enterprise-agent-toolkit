// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useEffect } from "react";

// API calls are marked as such, so the gateway answers an expired session with a 401 instead of a
// sign-in page; the guard then reloads the page, which signs the user in again.
let reloading = false;

export function SessionGuard() {
  useEffect(() => {
    const original = window.fetch;
    window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.pathname : input.url;
      const path = url.startsWith(window.location.origin) ? url.slice(window.location.origin.length) : url;
      const api = path.startsWith("/api/") || path.startsWith("/gw/");
      const headers = new Headers(init?.headers);
      if (api) headers.set("x-requested-with", "XMLHttpRequest");
      const res = await original(input, { ...init, headers });
      if (api && res.status === 401 && !reloading) {
        reloading = true;
        window.location.reload();
      }
      return res;
    };
    return () => {
      window.fetch = original;
    };
  }, []);
  return null;
}
