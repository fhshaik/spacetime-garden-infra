{{/* ─────────────────────────────────────────────────────────────────────────
     Service-name & label helpers
     ───────────────────────────────────────────────────────────────────────── */}}

{{- define "microservice.name" -}}
{{- default .Release.Name .Values.serviceName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "microservice.fullname" -}}
{{- include "microservice.name" . -}}
{{- end -}}

{{- define "microservice.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{- define "microservice.labels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: microservice
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ (include "microservice.merged" . | fromYaml).image.tag | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
garden.alaris.security/env: {{ .Values.envName | default "" | quote }}
garden.alaris.security/service: {{ include "microservice.name" . | quote }}
{{- end -}}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "microservice.serviceAccountName" -}}
{{- $v := include "microservice.merged" . | fromYaml -}}
{{- if $v.serviceAccount.create -}}
{{- include "microservice.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{/* ─────────────────────────────────────────────────────────────────────────
     Per-service value merge.

     Env values file (gitops/envs/<env>/values.yaml) uses the locked format:
       genome-service:
         image: { repository, tag }
         database: { enabled: true }
       breeding-service:
         image: ...
     ...because the app-repo's promote-{uat,prod}.yaml CI bumps
     <service>.image.tag in that file, and we cannot change the app repo.

     This helper merges the chart defaults with the per-service block
     selected by .Values.serviceName, so templates can reference fields
     uniformly via $v (e.g. $v.image.tag, $v.canary.enabled).
     ───────────────────────────────────────────────────────────────────────── */}}
{{- define "microservice.merged" -}}
{{- $svcName := required "serviceName must be set via ApplicationSet parameter" .Values.serviceName -}}
{{- $svcBlock := index .Values $svcName | default dict -}}
{{- $merged := mergeOverwrite (deepCopy .Values) (deepCopy ($svcBlock | toYaml | fromYaml)) -}}
{{- $merged | toYaml -}}
{{- end -}}
