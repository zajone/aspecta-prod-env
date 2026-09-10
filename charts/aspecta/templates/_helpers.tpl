{{/*
Naming and labelling helpers.

Every object in this chart is named <release>-aspecta-<component> and carries
the standard app.kubernetes.io labels, so kubectl, Argo CD and Prometheus can
all select the same resources without any bespoke label scheme.
*/}}

{{- define "aspecta.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aspecta.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "aspecta.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels shared by every object in the release. */}}
{{- define "aspecta.labels" -}}
helm.sh/chart: {{ include "aspecta.chart" . }}
app.kubernetes.io/name: {{ include "aspecta.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/part-of: aspecta
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels for a component. Deployment selectors are immutable, so this
set must stay minimal and never include version or chart labels.
Usage: include "aspecta.selectorLabels" (dict "root" . "component" "backend")
*/}}
{{- define "aspecta.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aspecta.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "aspecta.componentLabels" -}}
{{ include "aspecta.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "aspecta.componentName" -}}
{{- printf "%s-%s" (include "aspecta.fullname" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aspecta.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "aspecta.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Fully qualified image reference for a component. The tag falls back to the
chart appVersion, which CI keeps in step with the published image tag.
Usage: include "aspecta.image" (dict "root" . "component" .Values.backend)
*/}}
{{- define "aspecta.image" -}}
{{- $registry := .root.Values.global.image.registry -}}
{{- $owner := required "global.image.owner must be set" .root.Values.global.image.owner -}}
{{- $tag := default .root.Chart.AppVersion .component.image.tag -}}
{{- printf "%s/%s/%s:%s" $registry $owner .component.image.repository $tag -}}
{{- end -}}

{{- define "aspecta.secretName" -}}
{{- if .Values.secret.create -}}
{{/*
  A Secret the chart creates gets its own name. Returning existingSecret here
  meant `secret.create: true` rendered a Secret called aspecta-admin - exactly
  the name bootstrap.sh creates out of band - so a chart-managed object and a
  hand-provisioned one fought over the same key.
*/}}
{{- printf "%s-token" (include "aspecta.fullname" .) -}}
{{- else if .Values.secret.existingSecret -}}
{{- .Values.secret.existingSecret -}}
{{- else -}}
{{- printf "%s-admin" (include "aspecta.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
The admin token is never rendered from git unless an operator passes it in
explicitly. In every normal install the Secret is created out of band (see
scripts/bootstrap.sh and docs/security.md) and the containers reference it with
optional: true, so a missing Secret leaves the privileged endpoint closed
instead of breaking the pod.
*/}}
{{- define "aspecta.adminToken" -}}
{{- required "secret.adminToken must be set when secret.create is true" .Values.secret.adminToken | b64enc -}}
{{- end -}}

{{/* Pod-level hardening applied to every workload in the chart. */}}
{{- define "aspecta.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "aspecta.containerSecurityContext" -}}
allowPrivilegeEscalation: false
privileged: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end -}}
