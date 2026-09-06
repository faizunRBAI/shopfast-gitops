{{/*
Fail-fast guards. Invoked from each rendered template, so an invalid
combination is rejected by `helm lint` / `helm template` in CI and by Argo CD
at sync time — never discovered as a broken workload in the cluster.
*/}}
{{- define "shopfast.validate" -}}

{{- $valid := list "standard" "bluegreen" "canary" -}}
{{- if not (has .Values.strategy $valid) -}}
{{- fail (printf "shopfast: strategy must be one of %s (got %q)" (join ", " $valid) (.Values.strategy | toString)) -}}
{{- end -}}

{{/*
Immutable tags are a hard platform requirement: a mutable tag makes the
deployed revision unknowable and breaks rollback.
*/}}
{{- $tag := .Values.image.tag | toString -}}
{{- if or (eq $tag "latest") (eq $tag "") -}}
{{- fail "shopfast: image.tag must be an immutable tag (Git SHA); \"latest\" and empty are refused" -}}
{{- end -}}

{{- if not .Values.image.repository -}}
{{- fail "shopfast: image.repository must be set" -}}
{{- end -}}

{{/* An ALB ingress without a certificate cannot serve the required HTTPS. */}}
{{- if and .Values.ingress.enabled (eq .Values.ingress.className "alb") -}}
{{- if not .Values.ingress.certificateArn -}}
{{- fail "shopfast: ingress.certificateArn is required when the ALB ingress is enabled (HTTPS is mandatory)" -}}
{{- end -}}
{{- end -}}

{{- end -}}
