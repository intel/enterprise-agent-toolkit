// Copyright (C) 2025-2026 Intel Corporation
// SPDX-License-Identifier: Apache-2.0
"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useParams } from "next/navigation";
import { ButtonLink, Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { AlertTriangle } from "lucide-react";

interface Msg {
  role: "user" | "assistant";
  content: string;
}

export default function ChatPage() {
  const params = useParams<{ ns: string; name: string }>();
  const ns = decodeURIComponent(params.ns);
  const name = decodeURIComponent(params.name);

  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const abortRef = useRef<AbortController | null>(null);
  const scrollRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight });
  }, [msgs]);

  const send = useCallback(async () => {
    const prompt = input.trim();
    if (!prompt || busy) return;
    setError("");
    setInput("");
    const history = [...msgs, { role: "user" as const, content: prompt }];
    setMsgs([...history, { role: "assistant", content: "" }]);
    setBusy(true);

    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      // The agent's own gateway, through the platform gateway, which signs in and authorizes the user.
      const res = await fetch(`/gw/${encodeURIComponent(ns)}/${encodeURIComponent(name)}/v1/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: "openclaw", stream: true, messages: history }),
        signal: ctrl.signal,
      });
      if (!res.ok || !res.body) {
        const d = await res.json().catch(() => ({}));
        throw new Error(d?.error?.message || d?.error || (res.status === 403 ? "you may not talk to this agent" : `HTTP ${res.status}`));
      }

      // Parse the OpenAI SSE stream: lines "data: {json}" / "data: [DONE]".
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = "";
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        const lines = buf.split("\n");
        buf = lines.pop() ?? "";
        for (const line of lines) {
          const t = line.trim();
          if (!t.startsWith("data:")) continue;
          const payload = t.slice(5).trim();
          if (payload === "[DONE]") continue;
          try {
            const chunk = JSON.parse(payload);
            const delta = chunk?.choices?.[0]?.delta?.content ?? "";
            if (delta) appendToLast(setMsgs, delta);
          } catch {
            // a keep-alive or partial line
          }
        }
      }
    } catch (e: any) {
      if (e?.name !== "AbortError") setError(String(e?.message ?? e));
    } finally {
      setBusy(false);
      abortRef.current = null;
    }
  }, [input, busy, msgs, ns, name]);

  function stop() {
    abortRef.current?.abort();
  }

  function onKey(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  }

  return (
    <div className="flex h-[calc(100vh-6.5rem)] flex-col gap-4">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold">
          Chat · {name} <span className="text-sm font-normal text-muted-foreground">{ns}</span>
        </h1>
        <ButtonLink variant="outline" href={`/agents/${params.ns}/${params.name}`}>
          ← Agent
        </ButtonLink>
      </div>
      {error && (
        <div className="flex items-center gap-2 rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">
          <AlertTriangle size={14} /> {error}
        </div>
      )}

      <div className="flex flex-1 flex-col overflow-hidden rounded-lg border border-border bg-card">
        <div ref={scrollRef} className="flex-1 space-y-4 overflow-y-auto p-4">
          {msgs.length === 0 && (
            <p className="text-sm text-muted-foreground">Send a message to start. Responses stream in live.</p>
          )}
          {msgs.map((m, i) => (
            <div key={i} className={cn("flex flex-col", m.role === "user" ? "items-end text-right" : "items-start")}>
              <div className="mb-1 text-[11px] uppercase tracking-wide text-muted-foreground">
                {m.role === "user" ? "You" : name}
              </div>
              <div
                className={cn(
                  "bubble-body inline-block max-w-[82%] rounded-2xl px-3.5 py-2.5 text-sm leading-relaxed",
                  m.role === "user"
                    ? "rounded-br-sm bg-primary text-primary-foreground"
                    : "rounded-bl-sm border border-border bg-background"
                )}
              >
                {m.content || (busy && i === msgs.length - 1 ? <span className="cursor-blink text-muted-foreground">▍</span> : "")}
              </div>
            </div>
          ))}
        </div>
        <div className="flex items-end gap-2 border-t border-border p-3">
          <Textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={onKey}
            placeholder="Message the agent…  (Enter to send, Shift+Enter for newline)"
            rows={2}
            className="flex-1 resize-y"
          />
          {busy ? (
            <Button variant="destructive" onClick={stop}>Stop</Button>
          ) : (
            <Button disabled={!input.trim()} onClick={send}>Send</Button>
          )}
        </div>
      </div>
    </div>
  );
}

// Append a streamed delta to the last (assistant) message immutably.
function appendToLast(setMsgs: React.Dispatch<React.SetStateAction<Msg[]>>, delta: string) {
  setMsgs((m) => {
    const next = m.slice();
    const last = next[next.length - 1];
    if (last && last.role === "assistant") next[next.length - 1] = { ...last, content: last.content + delta };
    return next;
  });
}
