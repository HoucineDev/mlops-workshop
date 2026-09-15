{{- define "model-inference.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "model-inference.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- .Values.inferenceService.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "model-inference.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "model-inference.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/*
The in-cluster address of the predictor. In RawDeployment mode KServe names the
Service "<isvc>-predictor" and exposes it on port 80. Exported so NOTES.txt and
the litellm-gateway chart agree on one definition.
*/}}
{{- define "model-inference.predictorURL" -}}
{{- printf "http://%s-predictor.%s.svc.cluster.local" (include "model-inference.fullname" .) .Release.Namespace -}}
{{- end -}}
