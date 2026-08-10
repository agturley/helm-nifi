
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

{{/*
Per-node certificate Common Name, also used as the NiFi cluster node identity.
Kept short (pod name only) to stay within the X.509 CN 64-character limit. The
full headless FQDN is still carried in the certificate SANs (dnsNames) for TLS
hostname verification, so this does not affect node-to-node TLS validation.
This value MUST stay identical between the per-node Certificate's commonName and
the Node/User Identity entries in authorizers.xml, so both call this helper.
Call with a dict: (dict "ctx" $ "node" <index>).
*/}}
{{- define "nifi.nodeCN" -}}
{{ include "apache-nifi.fullname" .ctx }}-{{ .node }}
{{- end -}}

{{/*
Number of node identity slots (Node Identity / Initial User Identity entries in
authorizers.xml) to pre-provision. Defaults to replicaCount. Set
maxReplicaCount higher than replicaCount to reserve extra slots so that
changing replicaCount later, up or down within that ceiling, does not change
the rendered text of the shared StatefulSet pod template - which would
otherwise force Kubernetes to roll every existing node, not just the one being
added or removed. Call with the root context ($).
*/}}
{{- define "nifi.identityPoolSize" -}}
{{- $current := int .Values.replicaCount -}}
{{- $pool := int (.Values.maxReplicaCount | default .Values.replicaCount) -}}
{{- if lt $pool $current -}}
{{- fail (printf "maxReplicaCount (%d) must be >= replicaCount (%d)" $pool $current) -}}
{{- end -}}
{{- $pool -}}
{{- end -}}

{{/*
Worst-case seconds the preStop drain hook can consume: the DISCONNECTED wait,
the OFFLOADED wait, and the queue-drain ceiling. The kubelet's
terminationGracePeriodSeconds budget covers preStop AND the container's own
SIGTERM handling, so the pod must be given this much plus headroom for
`nifi.sh stop` - otherwise the drain is guaranteed to be SIGKILLed partway
through, stranding un-relocated content on the PVC with no visible error.
Call with the root context ($).
*/}}
{{- define "nifi.drainWorstCaseSeconds" -}}
{{- $p := .Values.properties -}}
{{- add (mul 2 (int $p.drainStateWaitSeconds)) (int $p.drainQueueTimeoutSeconds) -}}
{{- end -}}

{{/*
Fail rendering when terminationGracePeriodSeconds cannot cover the drain the
operator has asked for. Only meaningful when scaleDownGuard.enabled, since
that is what arms the drain in the first place. Call with the root context ($).
*/}}
{{- define "nifi.validateDrainBudget" -}}
{{- if .Values.scaleDownGuard.enabled -}}
{{- $worst := int (include "nifi.drainWorstCaseSeconds" .) -}}
{{- $reserve := int (default 30 .Values.properties.drainShutdownReserveSeconds) -}}
{{- $need := add $worst $reserve -}}
{{- $have := int .Values.terminationGracePeriodSeconds -}}
{{- if lt $have $need -}}
{{- fail (printf "terminationGracePeriodSeconds (%d) is too small for the scale-down drain: the preStop hook can need up to %ds (2 x drainStateWaitSeconds=%d, plus drainQueueTimeoutSeconds=%d) and `nifi.sh stop` needs a further ~%ds. Set terminationGracePeriodSeconds to at least %d, or lower properties.drainQueueTimeoutSeconds / properties.drainStateWaitSeconds." $have $worst (int .Values.properties.drainStateWaitSeconds) (int .Values.properties.drainQueueTimeoutSeconds) $reserve $need) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
values.yaml-derived initial admin identity, used as the lowest-precedence
fallback for ${INITIAL_ADMIN_IDENTITY} (a Secret or Vault value still wins - see
nifi.secretsInit). Which value is meaningful depends on the active auth mode:
an OIDC deployment identifies its admin by an IdP claim (auth.oidc.admin, e.g.
an email address), while every other mode uses auth.admin. This cannot collapse
to "auth.admin if set" because auth.admin carries a non-empty chart default
(CN=admin, OU=NIFI), which would silently outrank a real auth.oidc.admin.
Call with the root context ($).
*/}}
{{- define "nifi.initialAdminFallback" -}}
{{- if .Values.auth.oidc.enabled -}}
{{- .Values.auth.oidc.admin | default "" -}}
{{- else -}}
{{- .Values.auth.admin | default "" -}}
{{- end -}}
{{- end -}}

{{/*
issuerRef body for cert-manager Certificate resources.
When certManager.issuerRef.name is set, reference that existing
Issuer/ClusterIssuer; otherwise reference the chart-managed CA Issuer.
Call with the root context ($).
*/}}
{{/*
Default shared identity common name for NiFi authorization mapping.
Defaults to <namespace>-<releaseName>, with auth.nodeIdentity.shared.identityDomain
appended as a domain suffix when set.
*/}}
{{- define "nifi.clusterCommonName" -}}
{{- $base := printf "%s-%s" .Release.Namespace (include "apache-nifi.fullname" .) -}}
{{- $domain := default "" .Values.auth.nodeIdentity.shared.identityDomain -}}
{{- if $domain -}}{{ printf "%s.%s" $base $domain }}{{- else -}}{{ $base }}{{- end -}}
{{- end -}}

{{/*
Effective shared-node identity mapping enabled flag.
Driven by auth.nodeIdentity.shared.enabled.
*/}}
{{- define "nifi.sharedNodeIdentityMappingEnabled" -}}
{{- $auth := default (dict) .Values.auth -}}
{{- $nodeIdentity := default (dict) $auth.nodeIdentity -}}
{{- $shared := default (dict) $nodeIdentity.shared -}}
{{- if not $shared -}}
{{- $legacyIdentityMapping := default (dict) $auth.identityMapping -}}
{{- $shared = default (dict) $legacyIdentityMapping.sharedNode -}}
{{- end -}}
{{- ternary "true" "false" (default false $shared.enabled) -}}
{{- end -}}

{{/*
Effective shared-node identity CN (without CN= prefix).
Uses auth.nodeIdentity.shared.identity, then cluster default.
*/}}
{{- define "nifi.sharedNodeIdentityCommonName" -}}
{{- $auth := default (dict) .Values.auth -}}
{{- $nodeIdentity := default (dict) $auth.nodeIdentity -}}
{{- $shared := default (dict) $nodeIdentity.shared -}}
{{- if not $shared -}}
{{- $legacyIdentityMapping := default (dict) $auth.identityMapping -}}
{{- $shared = default (dict) $legacyIdentityMapping.sharedNode -}}
{{- end -}}
{{- if and (hasKey $shared "identity") (ne (default "" $shared.identity) "") -}}
{{- $shared.identity -}}
{{- else -}}
{{- include "nifi.clusterCommonName" . -}}
{{- end -}}
{{- end -}}

{{/* Effective shared-node identity DN used in NiFi policies and mapping value. */}}
{{- define "nifi.sharedNodeIdentity" -}}
CN={{ include "nifi.sharedNodeIdentityCommonName" . }}{{ include "nifi.nodeOU" . }}
{{- end -}}

{{- define "apache-nifi.certManagerIssuerRef" -}}
{{- $ext := default (dict) .Values.certManager.issuerRef -}}
{{- if ne (default "" $ext.name) "" -}}
name: {{ $ext.name }}
kind: {{ default "ClusterIssuer" $ext.kind }}
group: {{ default "cert-manager.io" $ext.group }}
{{- else -}}
name: {{ template "apache-nifi.fullname" . }}-ca
kind: Issuer
{{- end -}}
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
Returns the active secretsMode string (evaluated in priority order):
  1. properties.secretsMode (non-empty string) — taken as-is.
  2. properties.UseK8sSecrets: true             — hard-fails (removed in 2.10).
  3. Otherwise returns "none".
*/}}
{{- define "nifi.effectiveSecretsMode" -}}
{{- $sm := default "" .Values.properties.secretsMode -}}
{{- if .Values.properties.UseK8sSecrets -}}
{{- fail "properties.UseK8sSecrets was removed in 2.10. Use properties.secretsMode: directory instead." -}}
{{- else if eq $sm "env" -}}
{{- fail "properties.secretsMode=env was removed in 2.10. Use directory or singlefile." -}}
{{- else if and $sm (not (has $sm (list "none" "directory" "singlefile" "file-dir" "file-single"))) -}}
{{- fail (printf "properties.secretsMode=%q is invalid. Allowed values: none, directory, singlefile (legacy aliases: file-dir, file-single)." $sm) -}}
{{- else if eq $sm "file-dir" -}}
directory
{{- else if eq $sm "file-single" -}}
singlefile
{{- else if $sm -}}
{{- $sm -}}
{{- else -}}
none
{{- end -}}
{{- end -}}

{{/*
nifi.secretSyncEnabled
Returns "true" when the S3 -> Kubernetes secret-sync (the config-sync
Deployment, its RBAC, and the synced-secret volumes) should be rendered:
  s3Sync.enabled                                  AND
  s3Sync.secretSync.enabled (default true)        AND
  at least one enabled syncPath has pathType != fs
The non-fs check makes the Deployment auto-skip when there are no secrets to
sync; the toggle is the explicit off-switch. Returns "" otherwise.
*/}}
{{- define "nifi.secretSyncEnabled" -}}
{{- $ns := .Values.NiFiSync -}}
{{- $s3 := $ns.s3Sync -}}
{{- $ss := $s3.secretSync | default dict -}}
{{- $toggle := true -}}
{{- if hasKey $ss "enabled" -}}{{- $toggle = $ss.enabled -}}{{- end -}}
{{- $hasSecretPath := false -}}
{{- range $ns.syncPaths -}}
{{- if and (default true .enabled) (ne .pathType "fs") -}}
{{- $hasSecretPath = true -}}
{{- end -}}
{{- end -}}
{{- if and $s3.enabled $toggle $hasSecretPath -}}true{{- end -}}
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
  directory   – read individual files from properties.secretsFilePath/
  singlefile  – source the KEY=VALUE file at secretsFilePath/secretsFile
  none        – set from Helm values.yaml literals
*/}}
{{/*
nifi.syncPaths
Returns the combined list of NiFiSync.syncPaths and NiFiSync.additionalSyncPaths
as a JSON array so callers can do:
  {{- range (include "nifi.syncPaths" . | fromJsonArray) }}
This lets override values.yaml add entries via additionalSyncPaths without
needing to repeat all the chart-default syncPaths.
*/}}
{{- define "nifi.syncPaths" -}}
{{- concat (.Values.NiFiSync.syncPaths | default list) (.Values.NiFiSync.additionalSyncPaths | default list) | toJson -}}
{{- end -}}

{{/*
nifi.awsSecretsSyncWait
Emits a shell block that blocks until the awsSecretsSync sidecar has written
its readiness sentinel file (outputPath/.aws-secrets-ready).  Only emitted
when awsSecretsSync.enabled=true and the effective secretsMode is "directory",
because that is the only case where containers read files from outputPath.
*/}}
{{- define "nifi.awsSecretsSyncWait" -}}
{{- if and .Values.awsSecretsSync.enabled (eq (include "nifi.effectiveSecretsMode" .) "directory") }}
          # Wait for awsSecretsSync to complete its initial fetch before reading credential files
          _aws_sentinel={{ printf "%s/.aws-secrets-ready" .Values.awsSecretsSync.outputPath | quote }}
          _aws_timeout=${AWS_SECRETS_WAIT_TIMEOUT:-120}
          _aws_start=$(date +%s)
          echo "[{{ .Template.Name | base | trimSuffix ".tpl" }}] Waiting for AWS secrets sentinel: $_aws_sentinel (timeout ${_aws_timeout}s)"
          while [ ! -f "$_aws_sentinel" ]; do
            _aws_now=$(date +%s)
            if [ $(( _aws_now - _aws_start )) -ge "$_aws_timeout" ]; then
              echo "[{{ .Template.Name | base | trimSuffix ".tpl" }}] Timed out waiting for AWS secrets sentinel: $_aws_sentinel" >&2
              exit 1
            fi
            sleep 2
          done
          echo "[{{ .Template.Name | base | trimSuffix ".tpl" }}] AWS secrets ready."
          unset _aws_sentinel _aws_timeout _aws_start _aws_now
{{- end }}
{{- end -}}

{{- define "nifi.secretsInit" -}}
{{- $sm := include "nifi.effectiveSecretsMode" . -}}
{{- $sp := .Values.properties.secretsFilePath -}}
{{- if eq $sm "directory" }}
          # ---- secrets: file-dir — load from {{ $sp }}/ ----
          _nifi_sp={{ $sp | quote }}
          # Assign only when the file actually yields a value. A missing or
          # empty file must fall through to whatever is already in the
          # environment (an `envFrom` secretRef) and then to the values.yaml
          # fallback at the end of this block - the previous unconditional
          # assignment blanked those instead, so a credential supplied by any
          # route other than this directory was silently wiped.
          _nifi_load() {
            _nifi_lv=$(tr -d '\r\n' < "$_nifi_sp/$1" 2>/dev/null) || true
            if [ -n "$_nifi_lv" ]; then export "$1=$_nifi_lv"; fi
            unset _nifi_lv
            return 0
          }
          for _nifi_k in NIFI_TLS_KEYSTORE_PASSWORD NIFI_TLS_TRUSTSTORE_PASSWORD \
                         NIFI_SENSITIVE_PROPS_KEY LDAP_MANAGER_DN \
                         LDAP_MANAGER_PASSWORD INITIAL_ADMIN_IDENTITY; do
            _nifi_load "$_nifi_k"
          done
          {{- if not .Values.NiFiSync.s3Sync.useIRSA }}
          for _nifi_k in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
            _nifi_load "$_nifi_k"
          done
          {{- end }}
          {{- $hasAwsCredSecret := false }}
          {{- if and .Values.VaultNiFiSecrets.enabled (eq (default "" .Values.VaultNiFiSecrets.secretProvider) "vaultSidecar") }}
          {{- range .Values.VaultNiFiSecrets.secrets }}
          {{- if eq (default "" .secretMode) "aws-credential" }}
          {{- $hasAwsCredSecret = true }}
          {{- end }}
          {{- end }}
          {{- end }}
          {{- if $hasAwsCredSecret }}
          # Export AWS credential discovery files from Vault aws-credential mode.
          # Sanitize filenames (replace dots and dashes with underscores) for valid bash variable names.
          for _aws_var_file in \
            "$_nifi_sp/AWS_SHARED_CREDENTIALS_FILE" \
            "$_nifi_sp/AWS_REGION" \
            "$_nifi_sp/AWS_CREDENTIAL_TTL" \
            "$_nifi_sp/AWS_SHARED_CREDENTIALS_FILE_"* \
            "$_nifi_sp/AWS_REGION_"* \
            "$_nifi_sp/AWS_CREDENTIAL_TTL_"*; do
            [ -f "$_aws_var_file" ] || continue
            _aws_var_name=$(basename "$_aws_var_file" | tr '.-' '__')
            _aws_var_val=$(tr -d '\r\n' < "$_aws_var_file" 2>/dev/null) || true
            [ -n "$_aws_var_val" ] || continue
            export "${_aws_var_name}=${_aws_var_val}"
          done
          unset _aws_var_file _aws_var_name _aws_var_val
          {{- end }}
          unset _nifi_sp _nifi_k
          # ---- end secrets source (file-dir) ----
{{- else if eq $sm "singlefile" }}
          # ---- secrets: file-single — source {{ $sp }}/{{ .Values.properties.secretsFile }} ----
          set -a
          . {{ printf "%s/%s" $sp .Values.properties.secretsFile | quote }}
          set +a
          # ---- end secrets source (file-single) ----
{{- end }}
          # ---- values.yaml fallback (applies in every secretsMode) ----
          # Precedence, lowest last:
          #   1. the mode-specific source above (Vault / AWS files, or the
          #      single sourced env file)
          #   2. the process environment - typically an `envFrom` secretRef
          #   3. these values.yaml literals
          # Assigned via a temporary rather than inlining the literal into
          # ${VAR:-...} so that values containing braces or quotes cannot break
          # out of the expansion. Kept POSIX (no ${!name}, no `local`) because
          # this block is also emitted into the /bin/sh s3-sync container.
          _d={{ .Values.certManager.keystorePasswd | quote }};       NIFI_TLS_KEYSTORE_PASSWORD="${NIFI_TLS_KEYSTORE_PASSWORD:-$_d}"
          _d={{ .Values.certManager.truststorePasswd | quote }};     NIFI_TLS_TRUSTSTORE_PASSWORD="${NIFI_TLS_TRUSTSTORE_PASSWORD:-$_d}"
          _d={{ .Values.properties.sensitiveKey | quote }};          NIFI_SENSITIVE_PROPS_KEY="${NIFI_SENSITIVE_PROPS_KEY:-$_d}"
          _d={{ .Values.auth.ldap.admin | default "" | quote }};     LDAP_MANAGER_DN="${LDAP_MANAGER_DN:-$_d}"
          _d={{ .Values.auth.ldap.pass | default "" | quote }};      LDAP_MANAGER_PASSWORD="${LDAP_MANAGER_PASSWORD:-$_d}"
          _d={{ include "nifi.initialAdminFallback" . | quote }};          INITIAL_ADMIN_IDENTITY="${INITIAL_ADMIN_IDENTITY:-$_d}"
          unset _d
          export NIFI_TLS_KEYSTORE_PASSWORD NIFI_TLS_TRUSTSTORE_PASSWORD NIFI_SENSITIVE_PROPS_KEY
          export LDAP_MANAGER_DN LDAP_MANAGER_PASSWORD INITIAL_ADMIN_IDENTITY
          # ---- end secrets ----
{{- end -}}