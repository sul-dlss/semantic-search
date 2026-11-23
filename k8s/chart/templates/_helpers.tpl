{{- define "semantic-search.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 52 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 52 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "semantic-search.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: web
{{- end -}}

{{- define "semantic-search.labels" -}}
{{ include "semantic-search.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "semantic-search.image" -}}
{{ .Values.image.repository }}:{{ required "image.tag is required: set it in values/<environment>.yaml" .Values.image.tag }}
{{- end -}}

{{/*
The header the gateway sets on /webauth/login after an OIDC login. It must
match Authentication::AUTHENTICATED_HEADER in the app.
*/}}
{{- define "semantic-search.authenticatedHeader" -}}
X-Oidc-Authenticated
{{- end -}}

{{/* Fails the render if a setting the app requires is missing or misplaced. */}}
{{- define "semantic-search.checkValues" -}}
{{- range list "SOLR_URL" "LITELLM_API_BASE" "LITELLM_EMBEDDING_MODEL" "LITELLM_CHAT_MODEL" "MCP_ALLOWED_HOSTS" -}}
{{- if not (index $.Values.env .) -}}
{{- fail (printf "env.%s is required" .) -}}
{{- end -}}
{{- end -}}
{{- range list "SECRET_KEY_BASE" "LITELLM_API_KEY" -}}
{{- if hasKey $.Values.env . -}}
{{- fail (printf "env.%s is a credential; put it in the %s Secret instead" . $.Values.secretName) -}}
{{- end -}}
{{- end -}}
{{- range list "THRUSTER_HTTP_PORT" "HTTP_PORT" "HOME" -}}
{{- if hasKey $.Values.env . -}}
{{- fail (printf "env.%s is set by the chart" .) -}}
{{- end -}}
{{- end -}}
{{- if .Values.oidc.enabled -}}
{{- if not .Values.route.enabled -}}
{{- fail "oidc.enabled requires route.enabled" -}}
{{- end -}}
{{- range list "issuer" "clientID" -}}
{{- if not (index $.Values.oidc .) -}}
{{- fail (printf "oidc.%s is required when oidc.enabled is true" .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Matches the user the Dockerfile creates. */}}
{{- define "semantic-search.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 1000
runAsGroup: 1000
fsGroup: 1000
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "semantic-search.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}
