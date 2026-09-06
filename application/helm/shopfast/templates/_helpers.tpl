{{/* Chart name, overridable. */}}
{{- define "shopfast.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "shopfast.fullname" -}}
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

{{- define "shopfast.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels applied to every object. */}}
{{- define "shopfast.labels" -}}
helm.sh/chart: {{ include "shopfast.chart" . }}
{{ include "shopfast.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: shopfast-platform
shopfast.xyz/strategy: {{ .Values.strategy | quote }}
{{- end -}}

{{/*
Selector labels.

IMPORTANT: these must NOT include the image tag or the release colour. Argo
Rollouts adds its own pod-template-hash to distinguish stable/canary/preview
pods; putting a mutable value in the selector makes the Rollout adopt the wrong
pods (and a Deployment selector is immutable after creation).
*/}}
{{- define "shopfast.selectorLabels" -}}
app.kubernetes.io/name: {{ include "shopfast.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "shopfast.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "shopfast.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
NOTE: there is deliberately NO "isRollout" helper.

The strategy guards in deployment.yaml and rollout.yaml are written as explicit
`eq .Values.strategy "..."` comparisons in the templates themselves. Hiding the
platform's most important invariant ("never render a Deployment alongside a
Rollout") behind a helper that returns a truthy STRING makes it depend on
whitespace-trim subtleties. Keep the comparisons explicit and local.
*/}}

{{/* Full image reference. */}}
{{- define "shopfast.image" -}}
{{- $tag := .Values.image.tag | toString -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{/*
The shared pod template, used identically by the Deployment and the Rollout.
Defining it once guarantees standard/bluegreen/canary run the SAME container
with the same probes, resources and security context.
*/}}
{{- define "shopfast.podTemplate" -}}
metadata:
  labels:
    {{- include "shopfast.selectorLabels" . | nindent 4 }}
    shopfast.xyz/color: {{ .Values.release.color | quote }}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: {{ .Values.service.targetPort | quote }}
    prometheus.io/path: {{ .Values.metrics.serviceScrape.path | quote }}
    {{- with .Values.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "shopfast.serviceAccountName" . }}
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  terminationGracePeriodSeconds: 45
  containers:
    - name: shopfast
      image: {{ include "shopfast.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      securityContext:
        {{- toYaml .Values.containerSecurityContext | nindent 8 }}
      ports:
        - name: http
          containerPort: {{ .Values.service.targetPort }}
          protocol: TCP
      env:
        - name: SHOPFAST_RELEASE_COLOR
          value: {{ .Values.release.color | quote }}
        - name: SHOPFAST_RELEASE_VERSION
          value: {{ .Values.image.tag | toString | quote }}
        {{- with .Values.env }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      livenessProbe:
        httpGet:
          path: {{ .Values.probes.liveness.path }}
          port: http
        initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
      readinessProbe:
        httpGet:
          path: {{ .Values.probes.readiness.path }}
          port: http
        initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
        periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
        timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
        failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      volumeMounts:
        # readOnlyRootFilesystem is enabled, so the JVM needs a writable /tmp.
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
