
#### HEAP Variable Warnings
{{- define "nifi.jvmCompat" -}}
{{- if .Values.jvmMemory }}
{{- $_ := set .Values.jvm "heapSize" .Values.jvmMemory -}}
{{- end }}
{{- end }}

{{- define "nifi.jvmDeprecationWarning" -}}
{{- if .Values.jvmMemory }}
################################################################################
# DEPRECATION WARNING:
# 'jvmMemory' is deprecated and will be removed in a future release.
# Please migrate to 'jvm.heapSize' in your values.yaml:
#
#   Old:
#     jvmMemory: {{ .Values.jvmMemory }}
#
#   New:
#     jvm:
#       heapSize: {{ .Values.jvmMemory }}
#
################################################################################
{{- end }}
{{- end }}
#### END HEAP Variable Warnings

{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "apache-nifi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{/*
Define required labels. These are used to help identify workloads and enhance monitoring data.
*/}}

{{- define "nifi.labelPrefix" -}}
{{- $p := required "labels.prefix must be set (ex: nifi.mycompany.org)" .Values.labels.prefix -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$" $p) -}}
{{- fail (printf "Invalid labels.prefix '%s' (must be DNS-compliant)" $p) -}}
{{- end -}}
{{- $p -}}
{{- end }}


{{/*
Define is cluster is using http or https
*/}}
{{- define "nifi.nodeOU" -}}
{{- if .Values.certManager.nodeOU -}}, OU={{ .Values.certManager.nodeOU }}{{- end -}}
{{- end -}}

{{- define "nifi.ingress.scheme" -}}
{{- if and .Values.ingress.tls (gt (len .Values.ingress.tls) 0) -}}
https
{{- else -}}
http
{{- end -}}
{{- end -}}


{{- define "nifi.commonLabels" -}}
{{- $prefix := include "nifi.labelPrefix" . -}}

{{ $prefix }}/appid: {{
  required "labels.appid must be set"
  .Values.labels.appid | quote
}}

{{ $prefix }}/environment: {{
  required "labels.environment must be set (e1|e2|e3...)"
  .Values.labels.environment | quote
}}

{{ $prefix }}/region: {{
  required "labels.region must be set (ipc1|icp2...)"
  .Values.labels.region | quote
}}

{{- with .Values.labels.owner }}
{{ $prefix }}/owner: {{ . | quote }}
{{- end }}

{{- end }} 

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "apache-nifi.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "apache-nifi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Form the Zookeeper Server part of the URL. If zookeeper is installed as part of this chart, use k8s service discovery,
else use user-provided server name
*/}}
{{- define "zookeeper.server" }}
{{- if .Values.zookeeper.enabled -}}
{{- printf "%s-zookeeper" .Release.Name }}
{{- else -}}
{{- printf "%s" .Values.zookeeper.url }}
{{- end -}}
{{- end -}}

{{/*
Form the Zookeeper URL and port. If zookeeper is installed as part of this chart, build a
comma-separated list of individual pod addresses via the headless service so NiFi connects
directly to each ZooKeeper node rather than the cluster service.
Otherwise use the user-provided URL and port.
*/}}
{{- define "zookeeper.url" }}
{{- if .Values.zookeeper.connectString -}}
{{- .Values.zookeeper.connectString }}
{{- else -}}
{{- $port := .Values.zookeeper.port | toString }}
{{- if .Values.zookeeper.enabled -}}
{{- $name := .Release.Name -}}
{{- $headless := printf "%s-zookeeper-headless" .Release.Name -}}
{{- $nodes := list -}}
{{- range until (int .Values.zookeeper.replicaCount) -}}
{{- $nodes = append $nodes (printf "%s-zookeeper-%d.%s:%s" $name . $headless $port) -}}
{{- end -}}
{{- join "," $nodes }}
{{- else -}}
{{- printf "%s:%s" .Values.zookeeper.url $port }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Set the service account name
*/}}
{{- define "apache-nifi.serviceAccountName" -}}
{{- if .Values.sts.serviceAccount.create }}
{{- default (include "apache-nifi.fullname" .) .Values.sts.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.sts.serviceAccount.name }}
{{- end }}
{{- end }}

{{- /*
Sanitize a name into a DNS-1123-compatible lowercase token:
  - lowercases
  - replace any run of non [a-z0-9] with '-'
  - collapse multiple '-' into single '-'
  - trim leading/trailing '-'
Usage:
  {{ include "secret.sanitizeName" "svc_E3_Some_SecretC1234" }}
Result:
  svc-e3-some-secretc1234
*/ -}}
{{- define "secret.sanitizeName" -}}
  {{- $raw := . | default "" -}}
  {{- $s := lower $raw -}}
  {{- /* Replace any non a-z0-9 with '-' */ -}}
  {{- $s = regexReplaceAll "[^a-z0-9]" $s "-" -}}
  {{- /* collapse multiple '-' to single '-' */ -}}
  {{- $s = regexReplaceAll "-+" $s "-" -}}
  {{- /* trim leading/trailing '-' */ -}}
  {{- $s = trimPrefix "-" $s -}}
  {{- $s = trimSuffix "-" $s -}}
  {{- /* ensure not empty; fallback to 'secret' if empty */ -}}
  {{- if eq $s "" }}secret{{- end -}}
  {{- printf "%s" $s -}}
{{- end -}}

{{/*
nifi.effectiveSecretsMode
Returns the active secretsMode string, with backward-compatibility for
deprecated boolean flags (evaluated in priority order):
  1. properties.secretsMode (non-empty string) — taken as-is.
  2. properties.UseK8sSecrets: true             — maps to "file-dir" (deprecated in 2.8.0).
  3. Otherwise returns "none".
*/}}
{{- define "nifi.effectiveSecretsMode" -}}
{{- $sm := default "" .Values.properties.secretsMode -}}
{{- if $sm -}}
{{- $sm -}}
{{- else if .Values.properties.UseK8sSecrets -}}
file-dir
{{- else -}}
none
{{- end -}}
{{- end -}}

{{/*
nifi.secretsInit
Emits a shell block that normalises runtime secrets into a consistent set of
environment variables at container startup.  All subsequent script logic can
then reference ${NIFI_TLS_KEYSTORE_PASSWORD}, ${NIFI_TLS_TRUSTSTORE_PASSWORD},
${NIFI_SENSITIVE_PROPS_KEY}, ${LDAP_MANAGER_DN}, ${LDAP_MANAGER_PASSWORD},
${INITIAL_ADMIN_IDENTITY}, ${S3_ACCESS_KEY_ID}, ${S3_SECRET_ACCESS_KEY}
regardless of how secrets are delivered.

Modes (properties.secretsMode):
  file-dir    – read individual files from properties.secretsFilePath/
  file-single – source the KEY=VALUE file at secretsFilePath/secretsFile
  env         – variables already set; nothing emitted
  none        – set from Helm values.yaml literals
*/}}
{{- define "nifi.secretsInit" -}}
{{- $sm := include "nifi.effectiveSecretsMode" . -}}
{{- $sp := .Values.properties.secretsFilePath -}}
{{- if eq $sm "file-dir" }}
          # ---- secrets: file-dir — load from {{ $sp }}/ ----
          _nifi_sp={{ $sp | quote }}
          NIFI_TLS_KEYSTORE_PASSWORD=$(tr -d '\r\n' < "$_nifi_sp/NIFI_TLS_KEYSTORE_PASSWORD" 2>/dev/null) || true
          NIFI_TLS_TRUSTSTORE_PASSWORD=$(tr -d '\r\n' < "$_nifi_sp/NIFI_TLS_TRUSTSTORE_PASSWORD" 2>/dev/null) || true
          NIFI_SENSITIVE_PROPS_KEY=$(tr -d '\r\n' < "$_nifi_sp/NIFI_SENSITIVE_PROPS_KEY" 2>/dev/null) || true
          LDAP_MANAGER_DN=$(tr -d '\r\n' < "$_nifi_sp/LDAP_MANAGER_DN" 2>/dev/null) || true
          LDAP_MANAGER_PASSWORD=$(tr -d '\r\n' < "$_nifi_sp/LDAP_MANAGER_PASSWORD" 2>/dev/null) || true
          INITIAL_ADMIN_IDENTITY=$(tr -d '\r\n' < "$_nifi_sp/INITIAL_ADMIN_IDENTITY" 2>/dev/null) || true
          S3_ACCESS_KEY_ID=$(tr -d '\r\n' < "$_nifi_sp/S3_ACCESS_KEY_ID" 2>/dev/null) || true
          S3_SECRET_ACCESS_KEY=$(tr -d '\r\n' < "$_nifi_sp/S3_SECRET_ACCESS_KEY" 2>/dev/null) || true
          export NIFI_TLS_KEYSTORE_PASSWORD NIFI_TLS_TRUSTSTORE_PASSWORD NIFI_SENSITIVE_PROPS_KEY
          export LDAP_MANAGER_DN LDAP_MANAGER_PASSWORD INITIAL_ADMIN_IDENTITY
          export S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY
          unset _nifi_sp
          # ---- end secrets ----
{{- else if eq $sm "file-single" }}
          # ---- secrets: file-single — source {{ $sp }}/{{ .Values.properties.secretsFile }} ----
          set -a
          . {{ printf "%s/%s" $sp .Values.properties.secretsFile | quote }}
          set +a
          # ---- end secrets ----
{{- else if eq $sm "env" }}
          # ---- secrets: env mode — variables expected already in environment ----
{{- else }}
          # ---- secrets: none mode — values from Helm values.yaml ----
          NIFI_TLS_KEYSTORE_PASSWORD={{ .Values.certManager.keystorePasswd | quote }}
          NIFI_TLS_TRUSTSTORE_PASSWORD={{ .Values.certManager.truststorePasswd | quote }}
          NIFI_SENSITIVE_PROPS_KEY={{ .Values.properties.sensitiveKey | quote }}
          LDAP_MANAGER_DN={{ .Values.auth.ldap.admin | default "" | quote }}
          LDAP_MANAGER_PASSWORD={{ .Values.auth.ldap.pass | default "" | quote }}
          INITIAL_ADMIN_IDENTITY={{ .Values.auth.admin | default "" | quote }}
          export NIFI_TLS_KEYSTORE_PASSWORD NIFI_TLS_TRUSTSTORE_PASSWORD NIFI_SENSITIVE_PROPS_KEY
          export LDAP_MANAGER_DN LDAP_MANAGER_PASSWORD INITIAL_ADMIN_IDENTITY
          # ---- end secrets ----
{{- end -}}
{{- end -}}