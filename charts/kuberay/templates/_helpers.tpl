{{/*
Copyright (C) 2025-2026 Intel Corporation
SPDX-License-Identifier: Apache-2.0

Helpers for the kuberay-cluster chart.
*/}}

{{/*
Cluster name — uses .Values.cluster.name with chart-release prefix when
the release name differs from the cluster name, so multiple clusters can
co-exist in the same namespace during testing.
*/}}
{{- define "kuberay-cluster.name" -}}
{{- .Values.cluster.name | default "ray-cluster" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard labels applied to every resource in this chart.
*/}}
{{- define "kuberay-cluster.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "kuberay-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
