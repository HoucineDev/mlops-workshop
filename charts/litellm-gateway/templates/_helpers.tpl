{{- define "litellm-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "litellm-gateway.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "litellm-gateway.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "litellm-gateway.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "litellm-gateway.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "litellm-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "litellm-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "litellm-gateway.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "litellm-gateway.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Namespace the InferenceServices live in. */}}
{{- define "litellm-gateway.kserveNamespace" -}}
{{- default .Release.Namespace .Values.kserve.namespace -}}
{{- end -}}

{{- define "litellm-gateway.masterKeySecretName" -}}
{{- if .Values.masterKey.create -}}
{{- printf "%s-masterkey" (include "litellm-gateway.fullname" .) -}}
{{- else -}}
{{- required "masterKey.existingSecret is required when masterKey.create is false" .Values.masterKey.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels for postgres.

These MUST NOT overlap with litellm-gateway.selectorLabels. Reusing those plus
an extra app.kubernetes.io/component label does not work: the proxy's Service
and Deployment select on name+instance ONLY, so a postgres pod carrying those
two labels is matched by both — the Service then load-balances HTTP requests
onto the postgres port, and roughly half of all API calls fail. A distinct
`name` is what actually separates them.
*/}}
{{- define "litellm-gateway.postgresqlSelectorLabels" -}}
app.kubernetes.io/name: {{ include "litellm-gateway.name" . }}-postgresql
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
