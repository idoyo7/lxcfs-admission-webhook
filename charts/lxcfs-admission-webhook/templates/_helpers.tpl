{{/*
Expand the name of the chart.
*/}}
{{- define "lxcfs-admission-webhook.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "lxcfs-admission-webhook.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label value (chart name + version).
*/}}
{{- define "lxcfs-admission-webhook.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "lxcfs-admission-webhook.labels" -}}
helm.sh/chart: {{ include "lxcfs-admission-webhook.chart" . }}
{{ include "lxcfs-admission-webhook.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (used in matchLabels and pod template labels).
*/}}
{{- define "lxcfs-admission-webhook.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lxcfs-admission-webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full name for webhook (controller) resources: {release}-{webhook.componentName}.
*/}}
{{- define "lxcfs-admission-webhook.webhookFullname" -}}
{{- $component := default "controller" .Values.webhook.componentName }}
{{- printf "%s-%s" .Release.Name $component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name for the LXCFS DaemonSet: {release}-{lxcfs.componentName}.
*/}}
{{- define "lxcfs-admission-webhook.lxcfsFullname" -}}
{{- $component := default "daemonset" .Values.lxcfs.componentName }}
{{- printf "%s-%s" .Release.Name $component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Render a container image reference.
Usage: {{ include "lxcfs-admission-webhook.image" (dict "image" .Values.webhook.image "defaultTag" .Chart.AppVersion) }}
*/}}
{{- define "lxcfs-admission-webhook.image" -}}
{{- $tag := .image.tag | default .defaultTag }}
{{- printf "%s:%s" .image.repository $tag }}
{{- end }}
