{{/*
Copyright (C) 2025-2026 Intel Corporation
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Common labels
*/}}
{{- define "openclaw-instance.labels" -}}
app.kubernetes.io/name: openclaw
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
