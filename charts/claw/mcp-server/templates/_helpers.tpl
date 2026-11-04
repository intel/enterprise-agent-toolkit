{{/* Copyright (C) 2025-2026 Intel Corporation */}}
{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{- define "mcp-server.fullname" -}}
mcp-{{ required "name is required" .Values.name }}-server
{{- end }}

{{- define "mcp-server.labels" -}}
app.kubernetes.io/name: {{ include "mcp-server.fullname" . }}
app.kubernetes.io/component: mcp-server
app.kubernetes.io/part-of: enterprise-agent-toolkit
{{- end }}
